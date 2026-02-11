-- =====================================================
-- UniBee Scenario Engine — Database Migration
-- =====================================================

-- Integration connections (configured in Settings, used by Scenarios)
-- Stores credentials and endpoints for external services.
-- Telegram bot token, Slack webhook, custom HTTP APIs, etc.
-- Settings page manages these; Scenarios reference them by id.
CREATE TABLE IF NOT EXISTS `merchant_scenario_integration` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `merchant_id` bigint(20) unsigned DEFAULT NULL COMMENT 'merchantId',
  `integration_type` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'telegram, slack, webhook, http_api, email, discord',
  `name` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'display name, e.g. My Slack Workspace',
  `config_json` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'encrypted JSON: credentials, tokens, urls',
  `is_active` tinyint(1) NOT NULL DEFAULT '1' COMMENT '0-inactive, 1-active',
  `last_tested_at` bigint(20) DEFAULT NULL COMMENT 'last connection test utc time',
  `test_status` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'untested, success, failed',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  `gmt_modify` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
  `is_deleted` int(11) NOT NULL DEFAULT '0' COMMENT '0-UnDeleted, 1-Deleted',
  `create_time` bigint(20) DEFAULT NULL COMMENT 'create utc time',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_merchant_type` (`merchant_id`, `integration_type`),
  KEY `idx_merchant_active` (`merchant_id`, `is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='external service integrations configured in settings';

-- Scenario templates (prebuilt and merchant-custom)
CREATE TABLE IF NOT EXISTS `merchant_scenario_template` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `merchant_id` bigint(20) unsigned DEFAULT NULL COMMENT 'merchantId, 0 = system-wide template',
  `name` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'template name',
  `description` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'template description',
  `category` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'payment, subscription, onboarding, retention, notification',
  `scenario_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'template JSON DSL',
  `icon` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'template icon identifier',
  `is_system` tinyint(1) NOT NULL DEFAULT '0' COMMENT '0-merchant template, 1-system built-in',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  `gmt_modify` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
  `is_deleted` int(11) NOT NULL DEFAULT '0' COMMENT '0-UnDeleted, 1-Deleted',
  `create_time` bigint(20) DEFAULT NULL COMMENT 'create utc time',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_merchant` (`merchant_id`),
  KEY `idx_category` (`category`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='scenario templates for quick creation';

-- Scenarios (the JSON DSL definitions)
CREATE TABLE IF NOT EXISTS `merchant_scenario` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `merchant_id` bigint(20) unsigned DEFAULT NULL COMMENT 'merchantId',
  `name` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'scenario name',
  `description` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'scenario description',
  `scenario_json` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL COMMENT 'scenario JSON DSL',
  `enabled` tinyint(1) NOT NULL DEFAULT '0' COMMENT '0-disabled, 1-enabled',
  `trigger_type` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'trigger type: webhook_event, bot_command, button_click, schedule, manual',
  `trigger_value` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'trigger value: event name, command, cron expression',
  `template_id` bigint(20) unsigned DEFAULT NULL COMMENT 'source template id, null = from scratch',
  `version` int(11) NOT NULL DEFAULT '1' COMMENT 'scenario version, incremented on each save',
  `last_run_at` bigint(20) DEFAULT NULL COMMENT 'last execution utc time',
  `run_count` bigint(20) NOT NULL DEFAULT '0' COMMENT 'total execution count',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  `gmt_modify` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
  `is_deleted` int(11) NOT NULL DEFAULT '0' COMMENT '0-UnDeleted, 1-Deleted',
  `create_time` bigint(20) DEFAULT NULL COMMENT 'create utc time',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_merchant_trigger` (`merchant_id`, `trigger_type`, `trigger_value`),
  KEY `idx_merchant_enabled` (`merchant_id`, `enabled`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='merchant automation scenarios';

-- Scenario executions (running instances)
CREATE TABLE IF NOT EXISTS `merchant_scenario_execution` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `merchant_id` bigint(20) unsigned DEFAULT NULL COMMENT 'merchantId',
  `scenario_id` bigint(20) unsigned DEFAULT NULL COMMENT 'scenario id',
  `scenario_version` int(11) NOT NULL DEFAULT '1' COMMENT 'scenario version at execution time',
  `trigger_data` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'trigger input data JSON',
  `status` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'pending' COMMENT 'pending, running, completed, failed, waiting',
  `current_step` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'current step id',
  `variables` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'current variables JSON',
  `started_at` bigint(20) DEFAULT NULL COMMENT 'start utc time',
  `finished_at` bigint(20) DEFAULT NULL COMMENT 'finish utc time',
  `error_message` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'error message if failed',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  `gmt_modify` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
  `create_time` bigint(20) DEFAULT NULL COMMENT 'create utc time',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_merchant_scenario` (`merchant_id`, `scenario_id`),
  KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='scenario execution instances';

-- Step logs (audit trail for each step execution)
CREATE TABLE IF NOT EXISTS `merchant_scenario_step_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `execution_id` bigint(20) unsigned DEFAULT NULL COMMENT 'execution id',
  `step_id` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'step id within scenario',
  `step_type` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'step type: send_telegram, delay, condition, etc',
  `input_data` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'step input JSON',
  `output_data` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'step output JSON',
  `status` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'success, failed, skipped',
  `duration_ms` int(11) NOT NULL DEFAULT '0' COMMENT 'execution duration in ms',
  `error_message` text CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci COMMENT 'error if failed',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_execution` (`execution_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='scenario step execution logs';

-- Delayed tasks (for delay steps in funnels)
CREATE TABLE IF NOT EXISTS `merchant_scenario_delayed_task` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `merchant_id` bigint(20) unsigned DEFAULT NULL COMMENT 'merchantId',
  `execution_id` bigint(20) unsigned DEFAULT NULL COMMENT 'execution id',
  `step_id` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'step id to resume',
  `execute_at` bigint(20) NOT NULL DEFAULT '0' COMMENT 'unix timestamp to execute',
  `status` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'pending' COMMENT 'pending, executed, cancelled',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  `gmt_modify` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_execute_at` (`status`, `execute_at`),
  KEY `idx_execution` (`execution_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='delayed scenario tasks';

-- Telegram user mapping (chat_id -> unibee user)
CREATE TABLE IF NOT EXISTS `merchant_telegram_user` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id',
  `merchant_id` bigint(20) unsigned DEFAULT NULL COMMENT 'merchantId',
  `user_id` bigint(20) unsigned DEFAULT NULL COMMENT 'unibee user id',
  `telegram_chat_id` varchar(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'telegram chat id',
  `telegram_username` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'telegram username',
  `first_name` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'telegram first name',
  `last_name` varchar(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '' COMMENT 'telegram last name',
  `gmt_create` timestamp NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'create time',
  `gmt_modify` timestamp NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'update time',
  `is_deleted` int(11) NOT NULL DEFAULT '0' COMMENT '0-UnDeleted, 1-Deleted',
  `create_time` bigint(20) DEFAULT NULL COMMENT 'create utc time',
  PRIMARY KEY (`id`) USING BTREE,
  UNIQUE KEY `idx_merchant_chat` (`merchant_id`, `telegram_chat_id`),
  KEY `idx_merchant_user` (`merchant_id`, `user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='telegram user to unibee user mapping';
