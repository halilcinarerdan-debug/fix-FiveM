-- =====================================================================
-- PROJECT MATRIX — SESSION 1 — PROXY ASSET REGISTRY (BRIDGE)
-- HeidiSQL / MariaDB 10.2+ / MySQL 8.0+ uyumlu düzeltilmiş sürüm.
-- Additive-only. Legacy matrix_trap_houses şemasına DOKUNMAZ.
-- =====================================================================
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- TEMİZ SLATE — şema çakışmasını önlemek için önce temizle
-- (Session 1 ilk kurulumda veri kaybı beklenmez.)
-- ---------------------------------------------------------------------
DROP VIEW  IF EXISTS `matrix_agent_pool`;
DROP TABLE IF EXISTS `matrix_traphouses`;
DROP TABLE IF EXISTS `matrix_exploit_log`;

-- ---------------------------------------------------------------------
-- [1] matrix_traphouses — PROXY ASSET REGISTRY
-- Kısıtlamalar/CHECK'ler ayrı ALTER'ler ile eklenir (HeidiSQL-safe).
-- ---------------------------------------------------------------------
CREATE TABLE `matrix_traphouses` (
    `id`                INT          NOT NULL AUTO_INCREMENT,
    `citizenid`         VARCHAR(50)  NOT NULL,
    `house_name`        VARCHAR(100) NOT NULL,
    `coords`            LONGTEXT     NOT NULL
        COMMENT 'JSON string layout: {"x":..,"y":..,"z":..} — legacy FLOAT bridge',
    `house_size`        VARCHAR(20)  NOT NULL DEFAULT 'small'
        COMMENT 'small | medium | large',
    `max_house_limit`   INT          NOT NULL DEFAULT 1
        COMMENT 'dinamik operasyonel ust sinir (hard cap 3)',
    `last_tax_payment`  INT          NOT NULL
        COMMENT 'Unix timestamp (os.time) — son basarili FinCEN audit',
    `is_sealed`         TINYINT      NOT NULL DEFAULT 0
        COMMENT '1 = audit fail / tactical lockdown',
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- UNIQUE kısıtlaması (ayrı ALTER — HeidiSQL-safe)
ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `unique_citizen_house_limit`
    UNIQUE (`citizenid`, `id`);

-- CHECK kısıtlamaları (MariaDB 10.2+ / MySQL 8.0.16+ destekler)
ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `chk_matrix_traphouses_size`
    CHECK (`house_size` IN ('small','medium','large'));

ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `chk_matrix_traphouses_limit`
    CHECK (`max_house_limit` BETWEEN 1 AND 3);

ALTER TABLE `matrix_traphouses`
    ADD CONSTRAINT `chk_matrix_traphouses_sealed`
    CHECK (`is_sealed` IN (0, 1));

-- İndeksler (ayrı ayrı, hata durumunda izole edilebilir)
CREATE INDEX `idx_matrix_traphouses_citizenid`
    ON `matrix_traphouses` (`citizenid`);

CREATE INDEX `idx_matrix_traphouses_sealed_tax`
    ON `matrix_traphouses` (`is_sealed`, `last_tax_payment`);

-- ---------------------------------------------------------------------
-- [2] matrix_agent_pool — MİLSİM AGENT DATA MASK VIEW
-- FİZİKSEL TABLO DEĞİL. matrix_bots üzerine overlay SQL VIEW.
-- Legacy INT botId → 'AGENT_%05d' via CONCAT + LPAD.
-- ---------------------------------------------------------------------
CREATE VIEW `matrix_agent_pool` AS
SELECT
    CONCAT('AGENT_', LPAD(b.`id`, 5, '0'))          AS `agent_hash`,
    b.`id`                                          AS `legacy_bot_id`,
    b.`dna_id`                                      AS `dna_id`,
    b.`name`                                        AS `code_name`,
    b.`role`                                        AS `role`,
    b.`status`                                      AS `status`,
    b.`handler_citizenid`                           AS `handler_citizenid`,
    b.`loyalty_base`                                AS `loyalty_base`,
    COALESCE(c.`iq_score`, 100)                     AS `bot_iq`,
    b.`skill_chemistry`                             AS `skill_chemistry`,
    b.`skill_cyber`                                 AS `skill_cyber`,
    b.`skill_logistics`                             AS `skill_logistics`,
    COALESCE(c.`current_drug_influence`, 'none')    AS `current_drug_influence`,
    b.`fear_factor`                                 AS `fear_factor`,
    b.`resilience`                                  AS `resilience`,
    b.`snitch_tendency`                             AS `snitch_tendency`,
    b.`economic_pressure`                           AS `economic_pressure`,
    b.`cognitive_shifter`                           AS `cognitive_shifter`,
    b.`fatigue_level`                               AS `fatigue_level`,
    b.`cortisol_level`                              AS `cortisol_level`,
    b.`withdrawal_index`                            AS `withdrawal_index`,
    b.`addiction_level`                             AS `addiction_level`,
    b.`trap_house_id`                               AS `trap_house_id`,
    b.`updated_at`                                  AS `updated_at`
FROM `matrix_bots` b
LEFT JOIN `matrix_bot_cognition` c ON c.`bot_id` = b.`id`;

-- ---------------------------------------------------------------------
-- [3] matrix_exploit_log — Anti-exploit secure log
-- ---------------------------------------------------------------------
CREATE TABLE `matrix_exploit_log` (
    `id`              INT          NOT NULL AUTO_INCREMENT,
    `citizenid`       VARCHAR(50)  NOT NULL,
    `attempted_size`  VARCHAR(20)  NOT NULL,
    `active_count`    INT          NOT NULL,
    `max_limit`       INT          NOT NULL,
    `coords_hash`     VARCHAR(64)  NOT NULL,
    `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE INDEX `idx_matrix_exploit_log_citizenid`
    ON `matrix_exploit_log` (`citizenid`);

SET FOREIGN_KEY_CHECKS = 1;

-- =====================================================================
-- DOĞRULAMA (opsiyonel, elle çalıştırın)
-- =====================================================================
-- SELECT COUNT(*) AS tbl FROM information_schema.tables
--  WHERE table_schema = DATABASE() AND table_name = 'matrix_traphouses';   -- beklenen: 1
-- SELECT COUNT(*) AS vw  FROM information_schema.views
--  WHERE table_schema = DATABASE() AND table_name = 'matrix_agent_pool';   -- beklenen: 1
-- SELECT COUNT(*) AS log FROM information_schema.tables
--  WHERE table_schema = DATABASE() AND table_name = 'matrix_exploit_log';  -- beklenen: 1