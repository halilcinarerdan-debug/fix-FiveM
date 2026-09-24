SET FOREIGN_KEY_CHECKS = 0;

-- [1] matrix_forensic_evidence — eksik kolonları ekle
ALTER TABLE `matrix_forensic_evidence`
    ADD COLUMN IF NOT EXISTS `dna_id`          VARCHAR(64)   DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `citizenid`       VARCHAR(50)   DEFAULT NULL,
    ADD COLUMN IF NOT EXISTS `sanitized`       TINYINT(1)    NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS `crime_scene_ref` VARCHAR(255)  DEFAULT NULL;

-- [2] matrix_sales_ledger — yok ise oluştur
CREATE TABLE IF NOT EXISTS `matrix_sales_ledger` (
    `id`               BIGINT        NOT NULL AUTO_INCREMENT,
    `batch_id`         VARCHAR(64)   NOT NULL,
    `seller_citizenid` VARCHAR(50)   DEFAULT NULL,
    `buyer_citizenid`  VARCHAR(50)   NOT NULL,
    `purity`           DECIMAL(5,4)  NOT NULL DEFAULT 0.0,
    `grams`            DECIMAL(10,2) DEFAULT 0.0,
    `total_cash`       DECIMAL(15,2) DEFAULT 0.0,
    `created_at`       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_buyer_purity` (`buyer_citizenid`, `purity`),
    KEY `idx_batch`        (`batch_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- [3] matrix_trap_house_stash — yok ise oluştur
CREATE TABLE IF NOT EXISTS `matrix_trap_house_stash` (
    `id`               BIGINT        NOT NULL AUTO_INCREMENT,
    `owner_citizenid`  VARCHAR(50)   NOT NULL,
    `trap_house_id`    INT           DEFAULT NULL,
    `weight_kg`        DECIMAL(10,3) NOT NULL DEFAULT 0.0,
    `cap_kg`           DECIMAL(10,3) NOT NULL DEFAULT 150.0,
    `updated_at`       DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_owner_stash` (`owner_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;