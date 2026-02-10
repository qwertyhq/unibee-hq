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

### 4.1 Визуальный конструктор

Используем **React Flow** (reactflow.dev) — библиотека для drag-and-drop node-based редакторов.

```
Компоненты:
├── ScenarioList/         — список сценариев с CRUD
├── ScenarioEditor/       — визуальный редактор
│   ├── Canvas.tsx        — React Flow canvas
│   ├── nodes/
│   │   ├── TriggerNode.tsx
│   │   ├── ActionNode.tsx
│   │   ├── ConditionNode.tsx
│   │   ├── DelayNode.tsx
│   │   └── EndNode.tsx
│   ├── panels/
│   │   ├── TriggerPanel.tsx    — настройка триггера
│   │   ├── TelegramPanel.tsx   — настройка TG сообщения
│   │   ├── HttpPanel.tsx       — настройка HTTP запроса
│   │   ├── ConditionPanel.tsx  — настройка условия
│   │   ├── DelayPanel.tsx      — настройка задержки
│   │   └── UniBeeApiPanel.tsx  — настройка UniBee действия
│   └── Toolbar.tsx       — панель инструментов
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

### Phase 1: Scenario Engine Core (Backend) — ~3-4 дня
- [ ] Модель данных + миграции SQL
- [ ] CRUD сценариев (store.go)
- [ ] Движок выполнения (engine.go, executor.go)
- [ ] Базовые действия: send_telegram, delay, condition, set_variable
- [ ] Интеграция с InternalWebhookListener (триггер webhook_event)
- [ ] API endpoints
- [ ] Delayed task worker

### Phase 2: Telegram Bot Interactive (Backend) — ~2-3 дня
- [ ] Bot long polling handler
- [ ] Команды /start, /status, /invoices, /plans
- [ ] Inline-кнопки + callback handling
- [ ] User ↔ Chat ID mapping
- [ ] Триггеры bot_command и button_click

### Phase 3: HTTP + UniBee Actions (Backend) — ~2 дня
- [ ] http_request action
- [ ] unibee_api action (internal API calls)
- [ ] send_email action
- [ ] Expression evaluator для condition

### Phase 4: Admin UI — Scenario List + JSON Editor (Frontend) — ~2 дня
- [ ] Список сценариев (CRUD)
- [ ] JSON-редактор сценариев
- [ ] История выполнений
- [ ] Предустановленные шаблоны

### Phase 5: Visual Flow Editor (Frontend) — ~4-5 дней
- [ ] React Flow интеграция
- [ ] Кастомные ноды (trigger, action, condition, delay)
- [ ] Панели настройки для каждого типа ноды
- [ ] Конвертация Flow ↔ JSON DSL
- [ ] Drag-and-drop из палитры действий
- [ ] Валидация и превью

### Phase 6: Advanced Features — ~2-3 дня
- [ ] Schedule-триггеры (cron)
- [ ] Параллельные ветки
- [ ] Loops (повтор шагов)
- [ ] Webhook для внешних систем (принимать события извне)
- [ ] Логирование и мониторинг

**Итого: ~15-20 дней разработки**

---

## 6. Зависимости

### Backend (Go)
- `github.com/go-telegram/bot` — уже добавлен
- `github.com/expr-lang/expr` — expression evaluator для conditions
- Остальное — стандартная библиотека Go + GoFrame

### Frontend (React)
- `@xyflow/react` (React Flow) — visual flow editor
- `@monaco-editor/react` — JSON editor (опционально)
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
