# UniBee Scenario Engine — Architecture Plan

## 1. Обзор

Универсальный движок сценариев, встроенный в UniBee, для автоматизации бизнес-процессов через Telegram, HTTP API и внутренние действия billing-системы.

### Ключевые возможности
- **Интерактивные команды** — бот отвечает на `/status`, `/invoices`, `/plans`
- **Воронки** — цепочки действий с задержками (платёж не прошёл → напомнить → эскалировать)
- **Inline-кнопки** — «Продлить» / «Отменить» / «Сменить план» прямо в Telegram
- **Визуальный конструктор** — drag-and-drop редактор сценариев в админке
- **Произвольные задачи** — выставить счёт, создать промокод, сменить план через бота
- **Универсальные API** — отправка HTTP-запросов к любым внешним сервисам

### Разделение ответственности: Settings vs Scenarios

> **Принцип:** Настройки подключений живут в Settings (`/configuration`),
> рабочие процессы (флоу) строятся в Scenarios.

| Область | Где настраивается | Что содержит |
|---|---|---|
| **Settings → Integrations** (`/configuration?tab=integrations`) | Страница настроек | Токены, ключи, URL-ы подключений (Telegram bot token, Slack webhook URL, SMTP, custom HTTP API endpoints) |
| **Settings → Telegram** (`/configuration?tab=telegram`) | Страница настроек | Telegram bot token, default chat, bot name — **только подключение** |
| **Scenarios** (`/scenario`) | Визуальный конструктор | Workflows/flows: какой триггер → какие шаги → какие интеграции использовать. Ссылается на integration_id из Settings |

**Было (проблема):** Telegram-настройки в `/configuration?tab=telegram` дублировали сценарии — и подключение, и логику отправки настраивали в одном месте.

**Стало (решение):**
- `/configuration?tab=telegram` — только настройка бота (token, имя, дефолтный чат)
- `/configuration?tab=integrations` — все внешние подключения (Telegram, Slack, Discord, HTTP API, email SMTP)
- `/scenario` — визуальный конструктор workflow-процессов, использующих настроенные интеграции

---

## 2. Архитектура

### 2.1 Модель данных (JSON DSL)

Сценарий = JSON-документ из **триггера**, **шагов** и **переменных**.
Шаги, использующие внешние сервисы, ссылаются на `integration_id` из таблицы `merchant_scenario_integration`.

```json
{
  "id": "sc_001",
  "name": "Payment Failed Reminder",
  "enabled": true,
  "trigger": {
    "type": "webhook_event",
    "event": "payment.failure"
  },
  "variables": {
    "user_email": "{{userEmail}}",
    "plan_name": "{{planName}}",
    "amount": "{{amountFormatted}}"
  },
  "steps": [
    {
      "id": "step_1",
      "type": "send_telegram",
      "integration_id": 1,
      "params": {
        "message": "⚠️ Платёж не прошёл\nПлан: {{plan_name}}\nСумма: {{amount}}",
        "buttons": [
          {"text": "Повторить оплату", "action": "retry_payment"},
          {"text": "Сменить карту", "action": "change_card"}
        ]
      }
    },
    {
      "id": "step_2",
      "type": "delay",
      "params": {"duration": "1h"}
    },
    {
      "id": "step_3",
      "type": "condition",
      "params": {
        "if": "{{payment_status}} != 'success'",
        "then": "step_4",
        "else": "end"
      }
    },
    {
      "id": "step_4",
      "type": "send_telegram",
      "params": {
        "message": "🔔 Напоминание: платёж всё ещё не проведён\nПлан: {{plan_name}}"
      }
    },
    {
      "id": "step_5",
      "type": "delay",
      "params": {"duration": "24h"}
    },
    {
      "id": "step_6",
      "type": "http_request",
      "params": {
        "method": "POST",
        "url": "https://hooks.slack.com/services/xxx",
        "headers": {"Content-Type": "application/json"},
        "body": {"text": "Payment failed for {{user_email}} - needs attention"}
      }
    }
  ]
}
```

### 2.2 Типы триггеров

| Тип | Описание | Пример |
|-----|----------|--------|
| `webhook_event` | Событие billing-системы | `payment.failure`, `subscription.cancelled` |
| `bot_command` | Команда Telegram-бота | `/status`, `/invoices`, `/help` |
| `button_click` | Нажатие inline-кнопки | `retry_payment`, `change_plan` |
| `schedule` | Крон-расписание | `0 9 * * *` (каждый день в 9:00) |
| `manual` | Ручной запуск из админки | — |

### 2.3 Типы шагов (Actions)

| Тип | Описание | Параметры | Требует integration |
|-----|----------|-----------|---------------------|
| `send_telegram` | Отправить сообщение в TG | `message`, `buttons[]`, `chatId` (опц.) | Да (type=telegram) |
| `http_request` | HTTP-запрос к любому API | `method`, `url`, `headers`, `body` | Опционально (type=http_api) |
| `delay` | Задержка | `duration` (1m, 1h, 1d) | Нет |
| `condition` | Условный переход | `if`, `then`, `else` | Нет |
| `set_variable` | Установить переменную | `name`, `value` | Нет |
| `unibee_api` | Вызов UniBee API | `action`, `params` | Нет (внутренний) |
| `send_email` | Отправка email | `to`, `subject`, `body` | Опционально (type=email) |
| `send_slack` | Отправить в Slack | `message`, `channel` | Да (type=slack) |
| `send_discord` | Отправить в Discord | `message`, `channel_id` | Да (type=discord) |
| `log` | Запись в лог | `message`, `level` | Нет |

> **integration_id** — ссылка на запись в `merchant_scenario_integration`.
> Шаг берёт credentials/URL из интеграции, а не хранит их в DSL.
> Это позволяет менять токены в Settings без редактирования сценариев.

### 2.4 UniBee API Actions

Полный список доступных billing actions для шага `unibee_api`.
Документация API: https://docs.unibee.dev/api-reference/

```
-- Подписки
get_subscription       — получить данные подписки
cancel_subscription    — отменить подписку
change_plan            — сменить план
suspend_subscription   — приостановить подписку
resume_subscription    — возобновить подписку

-- Счета и платежи
create_invoice         — выставить счёт
get_invoice_list       — получить список счетов
send_payment_link      — отправить ссылку на оплату
create_payment         — создать платёж

-- Пользователи
get_user               — получить данные пользователя
freeze_user            — заморозить пользователя
update_user            — обновить данные пользователя

-- Промокоды
create_discount        — создать промокод
apply_discount         — применить скидку
get_discount_list      — список промокодов

-- Планы
get_plan               — получить данные плана
get_plan_list          — список доступных планов

-- Email
send_email             — отправить email через внутреннюю систему

-- Кредиты
add_credit             — начислить кредит
get_credit_balance     — получить баланс кредитов

-- Метрики (usage-based billing)
get_metric_usage       — получить использование метрики
report_metric_event    — отправить событие метрики
```

---

## 3. Backend (Go)

### 3.1 Структура пакетов

```
internal/logic/scenario/
├── engine.go            — основной движок: парсинг, запуск, управление
├── executor.go          — выполнение отдельных шагов
├── trigger.go           — регистрация и матчинг триггеров
├── integration.go       — CRUD интеграций (merchant_scenario_integration)
├── actions/
│   ├── telegram.go      — send_telegram (с кнопками, callback)
│   ├── slack.go         — send_slack (webhook)
│   ├── discord.go       — send_discord (webhook)
│   ├── http.go          — http_request
│   ├── delay.go         — delay (через Redis delayed queue)
│   ├── condition.go     — condition (expression evaluator)
│   ├── unibee.go        — unibee_api (вызовы internal API)
│   ├── email.go         — send_email
│   └── variable.go      — set_variable
├── expression.go        — парсер выражений для condition
├── bot_handler.go       — обработка команд и callback от TG бота
├── store.go             — CRUD сценариев (DB)
└── template_store.go    — CRUD шаблонов сценариев (DB)
```

### 3.2 Таблицы БД

```sql
-- Интеграции с внешними сервисами (настраиваются в Settings)
CREATE TABLE merchant_scenario_integration (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL,
    integration_type VARCHAR(50) NOT NULL,        -- telegram, slack, discord, webhook, http_api, email
    name            VARCHAR(255) NOT NULL,         -- "My Slack Workspace", "TG Bot Production"
    config_json     TEXT,                          -- encrypted JSON: tokens, urls, credentials
    is_active       TINYINT DEFAULT 1,
    last_tested_at  BIGINT DEFAULT 0,
    test_status     VARCHAR(20) DEFAULT '',         -- untested, success, failed
    create_time     BIGINT DEFAULT 0,
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    is_deleted      INT DEFAULT 0,
    INDEX idx_merchant_type (merchant_id, integration_type)
);

-- Шаблоны сценариев (системные + мерчант-кастомные)
CREATE TABLE merchant_scenario_template (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL,      -- 0 = системный шаблон
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    category        VARCHAR(50) NOT NULL,           -- payment, subscription, onboarding, retention, notification
    scenario_json   LONGTEXT NOT NULL,
    icon            VARCHAR(100) DEFAULT '',
    is_system       TINYINT DEFAULT 0,
    create_time     BIGINT DEFAULT 0,
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    is_deleted      INT DEFAULT 0,
    INDEX idx_merchant (merchant_id),
    INDEX idx_category (category)
);

-- Сценарии
CREATE TABLE merchant_scenario (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL,
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    scenario_json   LONGTEXT NOT NULL,          -- JSON DSL
    enabled         TINYINT DEFAULT 0,
    trigger_type    VARCHAR(50) NOT NULL,        -- для быстрого поиска
    trigger_value   VARCHAR(255),                -- event name / command / cron
    template_id     BIGINT UNSIGNED DEFAULT 0,  -- source template id
    version         INT DEFAULT 1,               -- incremented on each save
    last_run_at     BIGINT DEFAULT 0,
    run_count       BIGINT DEFAULT 0,
    create_time     BIGINT DEFAULT 0,
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    is_deleted      INT DEFAULT 0,
    INDEX idx_merchant_trigger (merchant_id, trigger_type, trigger_value)
);

-- Выполнения сценариев
CREATE TABLE merchant_scenario_execution (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL,
    scenario_id     BIGINT UNSIGNED NOT NULL,
    scenario_version INT DEFAULT 1,
    trigger_data    TEXT,                        -- входные данные триггера
    status          VARCHAR(20) NOT NULL,        -- running, completed, failed, waiting
    current_step    VARCHAR(100),                -- ID текущего шага
    variables       TEXT,                        -- JSON текущих переменных
    started_at      BIGINT DEFAULT 0,
    finished_at     BIGINT DEFAULT 0,
    error_message   TEXT,
    create_time     BIGINT DEFAULT 0,
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_merchant_scenario (merchant_id, scenario_id),
    INDEX idx_status (status)
);

-- Логи шагов
CREATE TABLE merchant_scenario_step_log (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    execution_id    BIGINT UNSIGNED NOT NULL,
    step_id         VARCHAR(100) NOT NULL,
    step_type       VARCHAR(50) NOT NULL,
    input_data      TEXT,
    output_data     TEXT,
    status          VARCHAR(20) NOT NULL,        -- success, failed, skipped
    duration_ms     INT DEFAULT 0,
    error_message   TEXT,
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_execution (execution_id)
);

-- Управление задержками (delayed steps)
CREATE TABLE merchant_scenario_delayed_task (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    execution_id    BIGINT UNSIGNED NOT NULL,
    step_id         VARCHAR(100) NOT NULL,
    execute_at      BIGINT NOT NULL,             -- Unix timestamp
    status          VARCHAR(20) DEFAULT 'pending', -- pending, executed, cancelled
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_execute_at (status, execute_at)
);

-- Маппинг Telegram chat_id → UniBee user
CREATE TABLE merchant_telegram_user (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL,
    user_id         BIGINT UNSIGNED NOT NULL,
    telegram_chat_id VARCHAR(50) NOT NULL,
    telegram_username VARCHAR(100) DEFAULT '',
    first_name      VARCHAR(100) DEFAULT '',
    last_name       VARCHAR(100) DEFAULT '',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP,
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    is_deleted      INT DEFAULT 0,
    create_time     BIGINT DEFAULT 0,
    UNIQUE INDEX idx_merchant_chat (merchant_id, telegram_chat_id),
    INDEX idx_merchant_user (merchant_id, user_id)
);
```

### 3.3 API Endpoints

```
-- Сценарии
POST   /merchant/scenario/new              — создать сценарий
POST   /merchant/scenario/edit             — изменить сценарий
POST   /merchant/scenario/delete           — удалить
POST   /merchant/scenario/toggle           — вкл/выкл
GET    /merchant/scenario/list             — список сценариев
GET    /merchant/scenario/detail           — детали сценария
POST   /merchant/scenario/test_run         — тестовый запуск
GET    /merchant/scenario/execution_list   — история выполнений
GET    /merchant/scenario/execution_detail — детали выполнения с логами шагов
GET    /merchant/scenario/action_list      — список доступных действий
GET    /merchant/scenario/trigger_list     — список доступных триггеров
GET    /merchant/scenario/variable_list    — список доступных переменных
POST   /merchant/scenario/validate         — валидация JSON сценария

-- Интеграции (настраиваются в Settings → Integrations)
POST   /merchant/scenario/integration/new      — создать интеграцию
POST   /merchant/scenario/integration/edit     — изменить интеграцию
POST   /merchant/scenario/integration/delete   — удалить интеграцию
GET    /merchant/scenario/integration/list     — список интеграций
GET    /merchant/scenario/integration/detail   — детали интеграции
POST   /merchant/scenario/integration/test     — тест подключения

-- Шаблоны
GET    /merchant/scenario/template/list        — список шаблонов (системные + свои)
GET    /merchant/scenario/template/detail      — детали шаблона
POST   /merchant/scenario/template/create_from — создать сценарий из шаблона
```

### 3.4 Telegram Bot Handler

Бот должен работать в режиме **long polling** (не webhook — для простоты деплоя).

```
Инициализация:
1. При старте API — запускаем горутину Telegram Bot Polling для каждого merchant с настроенным ботом
2. Получаем Update → матчим с триггерами bot_command / button_click
3. Запускаем соответствующий сценарий

Команды:
/start          → приветствие, список команд
/status         → статус подписки пользователя (по chat_id → user mapping)
/invoices       → последние 5 счетов
/plans          → доступные планы
/help           → справка
+ любые кастомные команды из сценариев мерчанта
```

### 3.5 Delayed Tasks (воронки)

Для шагов `delay` используем таблицу `merchant_scenario_delayed_task`:
1. При достижении шага `delay` — записываем задачу с `execute_at`
2. Фоновый воркер каждые 30 секунд проверяет таблицу
3. Выполняет просроченные задачи — продолжает сценарий с нужного шага

---

## 4. Frontend (React)

### 4.1 Визуальный конструктор (n8n-style)

Используем **@xyflow/react v12** (React Flow) + **@dagrejs/dagre** — n8n-style node editor с auto-layout.

```
Компоненты:
├── ScenarioList/         — список сценариев с CRUD
├── ScenarioDetail/       — JSON editor + Visual toggle
├── flowEditor/           — визуальный редактор (n8n-style)
│   ├── FlowEditor.tsx    — главный canvas (ReactFlowProvider + DnD + layout)
│   ├── converter.ts      — DSL ↔ Flow bidirectional converter с dagre layout
│   ├── flowEditor.css    — стили: n8n-ноды, палитра, context menu
│   ├── CustomEdge.tsx    — animated smoothstep edge с delete button
│   ├── ContextMenu.tsx   — right-click меню (duplicate, delete, disable)
│   ├── NodePanel.tsx     — unified панель настройки (формы по типу ноды)
│   ├── nodes/
│   │   ├── TriggerNode.tsx   — n8n-style: зелёная полоса, иконка trigger type
│   │   ├── ActionNode.tsx    — цвет по stepType, превью параметров
│   │   ├── ConditionNode.tsx — два выхода (Yes/No), preview condition
│   │   └── DelayNode.tsx     — оранжевый, показывает duration
│   └── index.ts
├── ScenarioExecutions/   — история выполнений
└── ScenarioTemplates/    — предустановленные шаблоны сценариев
```

### 4.2 Settings → Integrations (НЕ в Scenarios)

Интеграции настраиваются на странице настроек:

```
src/components/settings/
├── integrations/
│   ├── IntegrationList.tsx       — список подключённых интеграций
│   ├── IntegrationForm.tsx       — форма добавления/редактирования
│   ├── TelegramConfig.tsx        — настройка Telegram бота (token, name, default chat)
│   ├── SlackConfig.tsx           — настройка Slack (webhook URL, channel)
│   ├── DiscordConfig.tsx         — настройка Discord (webhook URL)
│   ├── HttpApiConfig.tsx         — настройка HTTP API (base URL, headers, auth)
│   ├── EmailConfig.tsx           — настройка Email (SMTP или SendGrid API key)
│   └── IntegrationTestButton.tsx — кнопка "Test Connection"
```

> **Важно:** Текущие настройки Telegram в `/configuration?tab=telegram` 
> мигрируют в общий раздел `/configuration?tab=integrations`.
> Telegram — просто один из типов интеграций.
> В сценариях мерчант выбирает интеграцию из dropdown (по integration_id).

### 4.3 Предустановленные шаблоны

1. **Payment Failed Recovery** — платёж не прошёл → TG напоминание → задержка → эскалация в Slack
2. **Subscription Expiring** — подписка заканчивается → TG предупреждение → кнопка продления
3. **New User Welcome** — новый пользователь → приветствие TG → ссылка на оплату
4. **Churn Prevention** — отмена подписки → предложение скидки → промокод через UniBee API
5. **Admin Alerts** — критические события → уведомление в Slack/Discord + TG админу
6. **Invoice Reminder** — неоплаченный счёт → email → TG → Slack эскалация
7. **Plan Upgrade Nudge** — пользователь на бесплатном плане 30 дней → предложение апгрейда
8. **Usage Limit Warning** — метрика приближается к лимиту → TG уведомление + email

---

## 5. Фазы реализации

### Phase 1: Scenario Engine Core (Backend) — ~3-4 дня ✅ DONE
- [x] Модель данных + миграции SQL (5 таблиц, entity, DAO — 3 слоя)
- [x] CRUD сценариев (store.go)
- [x] Движок выполнения (engine.go — парсинг DSL, запуск, resume, template rendering)
- [x] Базовые действия: send_telegram, delay, condition, set_variable, log
- [x] Интеграция с InternalWebhookListener (триггер webhook_event)
- [x] API endpoints (12 эндпоинтов + контроллеры)
- [x] Delayed task worker (30s polling loop)
- [x] Валидация DSL
- [x] Компиляция проверена ✅

### Phase 2: Telegram Bot Interactive (Backend) — ~2-3 дня ✅ DONE
- [x] Bot long polling handler (bot_handler.go)
- [x] Команда /start (с фолбэком на дефолтное приветствие)
- [x] Команды /status, /invoices, /plans (встроенные, с вызовом UniBee API)
- [x] Команда /help
- [x] Inline-кнопки + callback handling (sc_{merchantId}_{action})
- [x] User ↔ Chat ID mapping (merchant_telegram_user + UpsertTelegramUser)
- [x] Триггеры bot_command и button_click
- [x] InitAllBotPolling при старте приложения

### Phase 3: HTTP + UniBee Actions (Backend) — ~2 дня ✅ DONE
- [x] http_request action (GET/POST/PUT/DELETE, JSON body, headers, 30s timeout)
- [x] unibee_api action (get_subscription, get_user, get_invoice_list, cancel_subscription, create_discount, get_plan)
- [x] send_email action (через email.Send + SendgridEmailReq)
- [x] Expression evaluator: ==, !=, >, <, >=, <=, contains(), starts_with(), ends_with(), &&, ||, !, числовые сравнения

### Phase 4: Admin UI — Scenario List + JSON Editor (Frontend) — ~2 дня ✅ DONE
- [x] Список сценариев (CRUD) — list.tsx с таблицей, фильтрами, toggle, delete
- [x] JSON-редактор сценариев — detail.tsx с TextArea, валидацией, форматированием, preview-панелью
- [x] История выполнений — executions.tsx с таблицей + Drawer + Timeline для step logs
- [x] Предустановленные шаблоны (5 шаблонов: Payment Recovery, Churn Prevention, Welcome, Expiring, Bot Command)
- [x] API request functions (12 endpoints в requests/index.ts)
- [x] TypeScript типы (types.ts)
- [x] Маршруты + sidebar menu (routes.tsx, sideMenu.tsx)
- [x] СVG иконка + NavLink routing
- [x] Vite build проверен ✅

### Phase 5: Visual Flow Editor + Integrations (Frontend) — ~5-6 дней
- [ ] React Flow v12 + @dagrejs/dagre для auto-layout
- [ ] n8n-style кастомные ноды (цветная полоса слева, иконка, статус)
- [ ] 4 типа нод: TriggerNode, ActionNode, ConditionNode, DelayNode
- [ ] Custom edge с кнопкой удаления + animated smoothstep
- [ ] Context menu (правый клик) — duplicate, delete, disable
- [ ] Dagre auto-layout (вертикальный/горизонтальный) с кнопкой "Arrange"
- [ ] Drag-and-drop палитра (10 action types включая slack, discord) по образцу n8n
- [ ] Unified NodePanel — настройка параметров выбранной ноды (Ant Design формы)
- [ ] **Integration selector в NodePanel** — dropdown выбора интеграции (из Settings)
- [ ] Bidirectional converter DSL ↔ Flow (dslToFlow + flowToDsl)
- [ ] Connection validation (source→target, без self-loop)
- [ ] Execution state visualization (подсветка нод при запуске: running/success/failed)
- [ ] Интеграция в detail.tsx — Segmented toggle JSON/Visual
- [ ] Keyboard shortcuts: Delete, Backspace для удаления нод/рёбер
- [ ] **Settings → Integrations** UI (CRUD интеграций, test connection)
- [ ] **Миграция Telegram настроек** из `/configuration?tab=telegram` в `/configuration?tab=integrations`

### Phase 6: Advanced Features — ~3-4 дня
- [ ] Schedule-триггеры (cron) — backend cron worker + UI cron input
- [ ] Параллельные ветки — `type: "parallel"` step с массивом sub-step arrays
- [ ] Loops / retry — `type: "loop"` step с max_iterations и break condition
- [ ] Webhook для внешних систем (принимать события извне через endpoint)
- [ ] Execution replay — повторный запуск с сохранёнными trigger_data
- [ ] Версионирование сценариев — snapshot JSON при каждом сохранении (уже `version` колонка)
- [ ] Import/Export сценариев в JSON файл
- [ ] Расширение DSL: `on_error` handler для каждого шага (retry, skip, abort)
- [ ] **Marketplace шаблонов** — поиск и установка шаблонов из каталога

**Совместимость Phase 5 ↔ Phase 6:**
- DSL поддерживает вложенные шаги: condition.then/else содержат массивы StepDSL
- Converter работает с DAG (не только линейные цепочки)
- nodeTypes экспортируются из отдельного registry → легко добавить `parallel`, `loop`
- Execution visualization через WebSocket в будущем (Phase 6)
- Context menu расширяемый через registry паттерн
- Integration system — новые типы интеграций добавляются через config_json schema

**Итого: ~15-20 дней разработки**

---

## 6. Зависимости

### Backend (Go)
- `github.com/go-telegram/bot` — уже добавлен
- `github.com/expr-lang/expr` — expression evaluator для conditions
- Остальное — стандартная библиотека Go + GoFrame

### Frontend (React)
- `@xyflow/react` (React Flow v12) — visual flow editor
- `@dagrejs/dagre` — автоматический граф-layout (dagre algorithm)
- Остальное — уже есть (Ant Design, React Router)

---

## 7. Интеграции — config_json schemas

Каждый тип интеграции хранит свои настройки в `config_json`. Ниже — схемы для каждого типа.

### 7.1 Telegram
```json
{
  "bot_token": "123456:ABC-DEF...",
  "bot_name": "MyBillingBot",
  "default_chat_id": "-1001234567890",
  "parse_mode": "HTML",
  "disable_web_page_preview": true
}
```

### 7.2 Slack
```json
{
  "webhook_url": "https://hooks.slack.com/services/T.../B.../xxx",
  "default_channel": "#billing-alerts",
  "bot_name": "UniBee Bot",
  "icon_emoji": ":moneybag:"
}
```

### 7.3 Discord
```json
{
  "webhook_url": "https://discord.com/api/webhooks/123/xxx",
  "bot_name": "UniBee",
  "default_channel_id": "1234567890"
}
```

### 7.4 HTTP API (Custom Webhook)
```json
{
  "base_url": "https://api.example.com",
  "auth_type": "bearer",
  "auth_token": "sk-xxx...",
  "default_headers": {
    "Content-Type": "application/json",
    "X-Custom-Header": "value"
  },
  "timeout_seconds": 30
}
```

### 7.5 Email (SMTP / SendGrid)
```json
{
  "provider": "sendgrid",
  "api_key": "SG.xxx...",
  "from_email": "billing@example.com",
  "from_name": "Billing Team",
  "reply_to": "support@example.com"
}
```

---

## 8. Пример сценария: Churn Prevention

```
Триггер: subscription.cancelled

Шаг 1: send_telegram (integration_id: 1)
   "😔 Жаль, что вы отменили подписку {{plan_name}}.
    Может, дать скидку 20%?"
   [Кнопка: "Да, хочу скидку"] [Кнопка: "Нет, спасибо"]

Шаг 2: Ожидание нажатия кнопки (timeout: 24h)

Шаг 3: Условие — какая кнопка нажата?
   → "Да" → Шаг 4
   → "Нет" / timeout → Шаг 6

Шаг 4: unibee_api → create_discount (20%, code: SAVE20)

Шаг 5: send_telegram (integration_id: 1)
   "Вот ваш промокод: SAVE20 🎉"

Шаг 6: send_slack (integration_id: 2)
   "User {{user_email}} declined retention offer for {{plan_name}}"

Шаг 7: Log "Churn prevention flow completed"
```

## 9. Пример сценария: Multi-channel Invoice Reminder

```
Триггер: webhook_event → invoice.overdue

Шаг 1: send_email (integration_id: 3)
   Тема: "Invoice #{{invoice_id}} is overdue"
   Тело: стандартный шаблон с кнопкой оплаты

Шаг 2: delay (duration: 24h)

Шаг 3: condition (if: {{invoice_status}} != 'paid')
   → then: step_4
   → else: end

Шаг 4: send_telegram (integration_id: 1)
   "⚠️ Напоминание: счёт #{{invoice_id}} не оплачен ({{amount}})"
   [Кнопка: "Оплатить сейчас"]

Шаг 5: delay (duration: 48h)

Шаг 6: condition (if: {{invoice_status}} != 'paid')
   → then: step_7
   → else: end

Шаг 7: send_slack (integration_id: 2)
   "#billing-alerts: Overdue invoice #{{invoice_id}} for {{user_email}} — needs manual attention"

Шаг 8: http_request (integration_id: 4)
   POST https://crm.example.com/api/tickets
   {"subject": "Overdue invoice", "user": "{{user_email}}", "amount": "{{amount}}"}
```
