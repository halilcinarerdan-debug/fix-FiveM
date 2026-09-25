-- =====================================================================
-- MATRIX PHASE 4 — HARDCORE FRICTION FINALIZE
-- MariaDB 10.4+ / MySQL 8.0+ uyumlu
-- Deterministik, idempotent, strict IF NOT EXISTS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [LB-1] 24 SAATLİK BANKA ESCROW KİLİDİ
-- Aklanan nakit ANINDA clean balansa düşmez; 24 saatlik processing
-- penceresi boyunca bu tabloda bekletilir. Federal raid veya Büro
-- lockdown bu pencere içinde tetiklenirse %100 confiscate.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_banking_escrow` (
    `id`              BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`       VARCHAR(50)  NOT NULL,
    `trap_house_id`   INT          NOT NULL,
    `amount`          FLOAT        NOT NULL,
    `deposited_epoch` BIGINT       NOT NULL,
    `release_epoch`   BIGINT       NOT NULL,
    `status`          VARCHAR(20)  NOT NULL DEFAULT 'processing'
        COMMENT 'processing|released|confiscated',
    `confiscated_by`  VARCHAR(64)  NULL,
    `created_at`      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `idx_escrow_citizenid` (`citizenid`),
    INDEX `idx_escrow_release`   (`release_epoch`),
    INDEX `idx_escrow_status`    (`status`),
    INDEX `idx_escrow_trap`      (`trap_house_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- [LA-1] CCTV log satırları için progressive scrub skoru. 1.0'dan
-- başlar, -0.20/adım (5sn) ile sıfıra iner; sıfırlandığında satır
-- silinebilir.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_cctv_logs`
    ADD COLUMN IF NOT EXISTS `cctv_certainty` FLOAT NOT NULL DEFAULT 1.0
        COMMENT 'FAZ4 progressive scrub skoru; 0 = tam scrub';

-- ---------------------------------------------------------------------
-- [LA-2] Forensic evidence için progressive scrub bayrağı.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `scrubbed` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT 'FAZ4 progressive scrub tamamlandi mi';

-- ---------------------------------------------------------------------
-- [LB-4] Haftalık bozulma epoch damgası (KV deposu — restart-proof).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_kv` (
    `key_name`   VARCHAR(64)  NOT NULL,
    `value`      VARCHAR(255) NOT NULL,
    `updated_at` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`key_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;