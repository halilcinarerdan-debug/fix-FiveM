-- =====================================================================
-- MATRIX PHASE 3 — Persistent No-Cache Vehicles & Arson Forensic Ledger
-- MariaDB 10.4+ / MySQL 8.0+ uyumlu
-- Deterministik, idempotent, strict IF NOT EXISTS.
-- =====================================================================

-- ---------------------------------------------------------------------
-- [PV-1] KALICI ARAÇ MATRİSİ — NO-CACHE VEHICLES
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_persistent_vehicles` (
    `plate`            VARCHAR(12)  NOT NULL,
    `citizenid_owner`  VARCHAR(50)  NOT NULL,
    `vehicle_model`    INT          NOT NULL,
    `coord_x`          FLOAT        NOT NULL,
    `coord_y`          FLOAT        NOT NULL,
    `coord_z`          FLOAT        NOT NULL,
    `heading`          FLOAT        NOT NULL,
    `body_health`      FLOAT        NOT NULL DEFAULT 1000.0,
    `fuel_level`       FLOAT        NOT NULL DEFAULT 100.0,
    `status`           VARCHAR(20)  NOT NULL DEFAULT 'active_field'
        COMMENT 'parked_hood|active_field|destroyed',
    PRIMARY KEY (`plate`),
    INDEX `idx_status`  (`status`),
    INDEX `idx_owner`   (`citizenid_owner`),
    INDEX `idx_coords`  (`coord_x`, `coord_y`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ---------------------------------------------------------------------
-- [AR-4] ARSON FORENSIC LEDGER — her kundaklama oturumu için kalıcı iz
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_arson_events` (
    `event_id`         BIGINT       NOT NULL AUTO_INCREMENT,
    `plate`            VARCHAR(12)  NOT NULL,
    `actor_citizenid`  VARCHAR(50)  NOT NULL,
    `started_at`       DATETIME     NOT NULL,
    `completed_at`     DATETIME     NULL,
    `outcome`          VARCHAR(24)  NOT NULL
        COMMENT 'sanitized|salvaged|aborted',
    `final_body_health` FLOAT       NOT NULL DEFAULT 0.0,
    `intensity_before` FLOAT        NOT NULL DEFAULT 0.0,
    `intensity_after`  FLOAT        NOT NULL DEFAULT 0.0,
    `sanitized`        TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (`event_id`),
    INDEX `idx_plate`      (`plate`),
    INDEX `idx_actor`      (`actor_citizenid`),
    INDEX `idx_outcome`    (`outcome`),
    INDEX `idx_started_at` (`started_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ---------------------------------------------------------------------
-- [SEC-2 LEDGER] ORPHAN REFUND KAYITLARI (logistics C-5 deseni)
-- Bu tablo zaten başka bir modülde oluşturulmuş olabilir; IF NOT EXISTS
-- ile idempotent bırakıldı. Kolon şeması mevcut yapıya uyarlandı.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_pending_refunds` (
    `id`           BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`    VARCHAR(50)  NOT NULL,
    `amount`       DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    `reason`       VARCHAR(120) NOT NULL,
    `created_at`   DATETIME     NOT NULL,
    PRIMARY KEY (`id`),
    INDEX `idx_citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;