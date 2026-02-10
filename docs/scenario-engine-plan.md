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

---

## 2. Архитектура

### 2.1 Модель данных (JSON DSL)

Сценарий = JSON-документ из **триггера**, **шагов** и **переменных**.

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

| Тип | Описание | Параметры |
|-----|----------|-----------|
| `send_telegram` | Отправить сообщение в TG | `message`, `buttons[]`, `chatId` (опц.) |
| `http_request` | HTTP-запрос к любому API | `method`, `url`, `headers`, `body` |
| `delay` | Задержка | `duration` (1m, 1h, 1d) |
| `condition` | Условный переход | `if`, `then`, `else` |
| `set_variable` | Установить переменную | `name`, `value` |
| `unibee_api` | Вызов UniBee API | `action`, `params` |
| `send_email` | Отправка email | `to`, `subject`, `body` |
| `log` | Запись в лог | `message`, `level` |

### 2.4 UniBee API Actions

```
create_invoice      — выставить счёт
send_payment_link   — отправить ссылку на оплату
cancel_subscription — отменить подписку
change_plan         — сменить план
create_discount     — создать промокод
apply_discount      — применить скидку
freeze_user         — заморозить пользователя
send_email          — отправить email
get_subscription    — получить данные подписки
get_user            — получить данные пользователя
get_invoice_list    — получить список счетов
```

---

## 3. Backend (Go)

### 3.1 Структура пакетов

```
internal/logic/scenario/
├── engine.go            — основной движок: парсинг, запуск, управление
├── executor.go          — выполнение отдельных шагов
├── trigger.go           — регистрация и матчинг триггеров
├── actions/
│   ├── telegram.go      — send_telegram (с кнопками, callback)
│   ├── http.go          — http_request
│   ├── delay.go         — delay (через Redis delayed queue)
│   ├── condition.go     — condition (expression evaluator)
│   ├── unibee.go        — unibee_api (вызовы internal API)
│   ├── email.go         — send_email
│   └── variable.go      — set_variable
├── expression.go        — парсер выражений для condition
├── bot_handler.go       — обработка команд и callback от TG бота
└── store.go             — CRUD сценариев (DB)
```

### 3.2 Таблицы БД

```sql
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
```

### 3.3 API Endpoints

```
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

### 4.2 Предустановленные шаблоны

1. **Payment Failed Recovery** — платёж не прошёл → напоминание → эскалация
2. **Subscription Expiring** — подписка заканчивается → предупреждение → кнопка продления
3. **New User Welcome** — новый пользователь → приветствие → ссылка на оплату
4. **Churn Prevention** — отмена подписки → предложение скидки → промокод
5. **Admin Alerts** — критические события → уведомление в Slack/Telegram

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

### Phase 5: Visual Flow Editor — n8n-style (Frontend) — ~5-6 дней
- [ ] React Flow v12 + @dagrejs/dagre для auto-layout
- [ ] n8n-style кастомные ноды (цветная полоса слева, иконка, статус)
- [ ] 4 типа нод: TriggerNode, ActionNode, ConditionNode, DelayNode
- [ ] Custom edge с кнопкой удаления + animated smoothstep
- [ ] Context menu (правый клик) — duplicate, delete, disable
- [ ] Dagre auto-layout (вертикальный/горизонтальный) с кнопкой "Arrange"
- [ ] Drag-and-drop палитра (8 action types) по образцу n8n
- [ ] Unified NodePanel — настройка параметров выбранной ноды (Ant Design формы)
- [ ] Bidirectional converter DSL ↔ Flow (dslToFlow + flowToDsl)
- [ ] Connection validation (source→target, без self-loop)
- [ ] Execution state visualization (подсветка нод при запуске: running/success/failed)
- [ ] Интеграция в detail.tsx — Segmented toggle JSON/Visual
- [ ] Keyboard shortcuts: Delete, Backspace для удаления нод/рёбер

### Phase 6: Advanced Features — ~3-4 дня
- [ ] Schedule-триггеры (cron) — backend cron worker + UI cron input
- [ ] Параллельные ветки — `type: "parallel"` step с массивом sub-step arrays
- [ ] Loops / retry — `type: "loop"` step с max_iterations и break condition
- [ ] Webhook для внешних систем (принимать события извне через endpoint)
- [ ] Execution replay — повторный запуск с сохранёнными trigger_data
- [ ] Версионирование сценариев — snapshot JSON при каждом сохранении
- [ ] Import/Export сценариев в JSON файл
- [ ] Расширение DSL: `on_error` handler для каждого шага (retry, skip, abort)

**Совместимость Phase 5 ↔ Phase 6:**
- DSL поддерживает вложенные шаги: condition.then/else содержат массивы StepDSL
- Converter работает с DAG (не только линейные цепочки)
- nodeTypes экспортируются из отдельного registry → легко добавить `parallel`, `loop`
- Execution visualization через WebSocket в будущем (Phase 6)
- Context menu расширяемый через registry паттерн

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

## 7. Пример сценария: Churn Prevention

```
Триггер: subscription.cancelled

Шаг 1: Отправить TG сообщение
   "😔 Жаль, что вы отменили подписку {{plan_name}}.
    Может, дать скидку 20%?"
   [Кнопка: "Да, хочу скидку"] [Кнопка: "Нет, спасибо"]

Шаг 2: Ожидание нажатия кнопки (timeout: 24h)

Шаг 3: Условие — какая кнопка нажата?
   → "Да" → Шаг 4
   → "Нет" / timeout → Шаг 6

Шаг 4: UniBee API → create_discount (20%, code: SAVE20)
Шаг 5: TG сообщение "Вот ваш промокод: SAVE20 🎉"
Шаг 6: Log "User declined retention offer"
```
