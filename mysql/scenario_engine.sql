-- =====================================================
-- UniBee Scenario Engine — Database Migration
-- =====================================================

-- Integration connections (configured in Settings, used by Scenarios)
-- Stores credentials and endpoints for external services.
-- Telegram bot token, Slack webhook, custom HTTP APIs, etc.
-- Settings page manages these; Scenarios reference them by id.
CREATE TABLE IF NOT EXISTS merchant_scenario_integration (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'merchantId',
    integration_type VARCHAR(50) NOT NULL DEFAULT ''      COMMENT 'telegram, slack, webhook, http_api, email, discord',
    name            VARCHAR(255) NOT NULL DEFAULT ''      COMMENT 'display name, e.g. My Slack Workspace',
    config_json     TEXT                                  COMMENT 'encrypted JSON: credentials, tokens, urls',
    is_active       TINYINT NOT NULL DEFAULT 1            COMMENT '0-inactive, 1-active',
    last_tested_at  BIGINT NOT NULL DEFAULT 0             COMMENT 'last connection test utc time',
    test_status     VARCHAR(20) NOT NULL DEFAULT ''       COMMENT 'untested, success, failed',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
    is_deleted      INT NOT NULL DEFAULT 0                COMMENT '0-UnDeleted, 1-Deleted',
    create_time     BIGINT NOT NULL DEFAULT 0             COMMENT 'create utc time',
    INDEX idx_merchant_type (merchant_id, integration_type),
    INDEX idx_merchant_active (merchant_id, is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='external service integrations configured in settings';

-- Scenario templates (prebuilt and merchant-custom)
CREATE TABLE IF NOT EXISTS merchant_scenario_template (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'merchantId, 0 = system-wide template',
    name            VARCHAR(255) NOT NULL DEFAULT ''      COMMENT 'template name',
    description     TEXT                                  COMMENT 'template description',
    category        VARCHAR(50) NOT NULL DEFAULT ''       COMMENT 'payment, subscription, onboarding, retention, notification',
    scenario_json   LONGTEXT NOT NULL                     COMMENT 'template JSON DSL',
    icon            VARCHAR(100) NOT NULL DEFAULT ''      COMMENT 'template icon identifier',
    is_system       TINYINT NOT NULL DEFAULT 0            COMMENT '0-merchant template, 1-system built-in',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
    is_deleted      INT NOT NULL DEFAULT 0                COMMENT '0-UnDeleted, 1-Deleted',
    create_time     BIGINT NOT NULL DEFAULT 0             COMMENT 'create utc time',
    INDEX idx_merchant (merchant_id),
    INDEX idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='scenario templates for quick creation';

-- Scenarios (the JSON DSL definitions)
CREATE TABLE IF NOT EXISTS merchant_scenario (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'merchantId',
    name            VARCHAR(255) NOT NULL DEFAULT ''      COMMENT 'scenario name',
    description     TEXT                                  COMMENT 'scenario description',
    scenario_json   LONGTEXT NOT NULL                     COMMENT 'scenario JSON DSL',
    enabled         TINYINT NOT NULL DEFAULT 0            COMMENT '0-disabled, 1-enabled',
    trigger_type    VARCHAR(50) NOT NULL DEFAULT ''        COMMENT 'trigger type: webhook_event, bot_command, button_click, schedule, manual',
    trigger_value   VARCHAR(255) NOT NULL DEFAULT ''       COMMENT 'trigger value: event name, command, cron expression',
    template_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'source template id, 0 = from scratch',
    version         INT NOT NULL DEFAULT 1                COMMENT 'scenario version, incremented on each save',
    last_run_at     BIGINT NOT NULL DEFAULT 0             COMMENT 'last execution utc time',
    run_count       BIGINT NOT NULL DEFAULT 0             COMMENT 'total execution count',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
    is_deleted      INT NOT NULL DEFAULT 0                COMMENT '0-UnDeleted, 1-Deleted',
    create_time     BIGINT NOT NULL DEFAULT 0             COMMENT 'create utc time',
    INDEX idx_merchant_trigger (merchant_id, trigger_type, trigger_value),
    INDEX idx_merchant_enabled (merchant_id, enabled)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='merchant automation scenarios';

-- Scenario executions (running instances)
CREATE TABLE IF NOT EXISTS merchant_scenario_execution (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'merchantId',
    scenario_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'scenario id',
    scenario_version INT NOT NULL DEFAULT 1               COMMENT 'scenario version at execution time',
    trigger_data    TEXT                                  COMMENT 'trigger input data JSON',
    status          VARCHAR(20) NOT NULL DEFAULT 'pending' COMMENT 'pending, running, completed, failed, waiting',
    current_step    VARCHAR(100) NOT NULL DEFAULT ''       COMMENT 'current step id',
    variables       TEXT                                  COMMENT 'current variables JSON',
    started_at      BIGINT NOT NULL DEFAULT 0             COMMENT 'start utc time',
    finished_at     BIGINT NOT NULL DEFAULT 0             COMMENT 'finish utc time',
    error_message   TEXT                                  COMMENT 'error message if failed',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
    create_time     BIGINT NOT NULL DEFAULT 0             COMMENT 'create utc time',
    INDEX idx_merchant_scenario (merchant_id, scenario_id),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='scenario execution instances';

-- Step logs (audit trail for each step execution)
CREATE TABLE IF NOT EXISTS merchant_scenario_step_log (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    execution_id    BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'execution id',
    step_id         VARCHAR(100) NOT NULL DEFAULT ''       COMMENT 'step id within scenario',
    step_type       VARCHAR(50) NOT NULL DEFAULT ''        COMMENT 'step type: send_telegram, delay, condition, etc',
    input_data      TEXT                                  COMMENT 'step input JSON',
    output_data     TEXT                                  COMMENT 'step output JSON',
    status          VARCHAR(20) NOT NULL DEFAULT ''        COMMENT 'success, failed, skipped',
    duration_ms     INT NOT NULL DEFAULT 0                COMMENT 'execution duration in ms',
    error_message   TEXT                                  COMMENT 'error if failed',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    INDEX idx_execution (execution_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='scenario step execution logs';

-- Delayed tasks (for delay steps in funnels)
CREATE TABLE IF NOT EXISTS merchant_scenario_delayed_task (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'merchantId',
    execution_id    BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'execution id',
    step_id         VARCHAR(100) NOT NULL DEFAULT ''       COMMENT 'step id to resume',
    execute_at      BIGINT NOT NULL DEFAULT 0             COMMENT 'unix timestamp to execute',
    status          VARCHAR(20) NOT NULL DEFAULT 'pending' COMMENT 'pending, executed, cancelled',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
    INDEX idx_execute_at (status, execute_at),
    INDEX idx_execution (execution_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='delayed scenario tasks';

-- Telegram user mapping (chat_id -> unibee user)
CREATE TABLE IF NOT EXISTS merchant_telegram_user (
    id              BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    merchant_id     BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'merchantId',
    user_id         BIGINT UNSIGNED NOT NULL DEFAULT 0   COMMENT 'unibee user id',
    telegram_chat_id VARCHAR(50) NOT NULL DEFAULT ''      COMMENT 'telegram chat id',
    telegram_username VARCHAR(100) NOT NULL DEFAULT ''    COMMENT 'telegram username',
    first_name      VARCHAR(100) NOT NULL DEFAULT ''      COMMENT 'telegram first name',
    last_name       VARCHAR(100) NOT NULL DEFAULT ''       COMMENT 'telegram last name',
    gmt_create      DATETIME DEFAULT CURRENT_TIMESTAMP    COMMENT 'create time',
    gmt_modify      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
    is_deleted      INT NOT NULL DEFAULT 0                COMMENT '0-UnDeleted, 1-Deleted',
    create_time     BIGINT NOT NULL DEFAULT 0             COMMENT 'create utc time',
    UNIQUE INDEX idx_merchant_chat (merchant_id, telegram_chat_id),
    INDEX idx_merchant_user (merchant_id, user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='telegram user to unibee user mapping';
