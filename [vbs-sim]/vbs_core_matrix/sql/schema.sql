-- =====================================================================
-- ★★★ schema.sql — SESSION 1/2/3 KONSOLIDASYON EKI ★★★
--
-- Bu dosya sql/matrix_v3_ultimate_combined.sql'in YERINE GECMEZ -- onun
-- UZERINE, idempotent bir ek migration olarak calisir. Once
-- matrix_v3_ultimate_combined.sql import edilmis olmalidir (matrix_bots ve
-- matrix_trap_houses tablolarinin zaten var olmasi GEREKIR); bu dosya o iki
-- tabloyu YENIDEN TANIMLAMAZ, sadece genisletir.
--
-- ICERIK:
--   [1] matrix_trap_houses  -- coklu-kolon UNIQUE kisiti (cift-kayit
--       instabilitesini kapatir: ayni koordinatta iki hucre acilamaz).
--   [2] matrix_exploit_log  -- istemci taraflı anomali/exploit-denemesi
--       gunlugu (savunma amacli; sunucu yoneticisinin supheli client
--       raporlarini/kimlik dogrulama sapmalarini geriye donuk inceleyebilmesi
--       icindir).
--   [3] matrix_agent_pool   -- matrix_bots uzerine salt-okunur VIEW; her
--       bot'a "AGENT_00001" formatinda bir kod-adi kolonu ekler (F10
--       terminali / admin panel gosterimi icin -- ham `id` yerine).
--
-- Guvenle birden fazla kez calistirilabilir (tum adimlar IF NOT EXISTS /
-- CREATE OR REPLACE kullanir). MariaDB 10.5+ / MySQL 8.0+ gerektirir
-- (ADD ... IF NOT EXISTS sozdizimi icin) -- bkz. README.md Sistem
-- Gereksinimleri (MariaDB 10.6+ zaten minimum olarak listeli).
-- =====================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------------
-- [1] matrix_trap_houses — cift-kayit instabilite kilidi
--
-- Eski semada bu tabloda coord_x/coord_y/coord_z ustune HICBIR kisit
-- yoktu: /traphouseekle art arda ayni koordinatlarla cagrilirsa (cift
-- tiklama, script hatasi, iki admin ayni komutu ayni anda calistirirsa)
-- ayni fiziksel noktada BIRDEN FAZLA hucre kaydi olusabiliyordu. Bu da
-- server/odor_core.lua'nin FindNearestTrapHouse / client odor-alani
-- yayininda cakisan/ust-uste binen koku alanlarina, ve server/wound_system.
-- lua ile server/bureau.lua'nin "en yakin trap house" cozumlemelerinde
-- BELIRSIZ (hangi kayit esas?) davranisa yol aciyordu -- Bolum 1'de
-- tanimlanan "%45 kod instabilitesi"nin somut kaynaklarindan biri.
--
-- NOT: eger mevcut veritabaninizda zaten ayni koordinatta duplike kayit
-- varsa bu ALTER hata verir -- once o kayitlari elle birlestirin/silin.
-- ---------------------------------------------------------------------
ALTER TABLE `matrix_trap_houses`
    ADD UNIQUE KEY IF NOT EXISTS `uq_matrix_trap_houses_coords` (`coord_x`, `coord_y`, `coord_z`);

-- ---------------------------------------------------------------------
-- [2] matrix_exploit_log — client-taraflı anomali / exploit-denemesi defteri
--
-- server/player_telemetry.lua, server/wound_system.lua (ValidateWoundReport)
-- ve client/humint_stalking.lua (NetOwner dogrulamasi) gibi modüller zaten
-- supheli/sahte client raporlarini pcall ile SESSIZCE reddediyor -- ama
-- hicbir yerde KALICI bir iz birakmiyordu, bu da bir yoneticinin "bu
-- oyuncu tekrar tekrar sahte paket mi gonderiyor?" sorusunu yanitlamasini
-- imkansiz kiliyordu. Bu tablo o bosluğu kapatir; asla silinmez (adli
-- kayit politikasiyla ayni disiplin -- bkz. matrix_v3_ultimate_combined.sql
-- basligindaki "ADLI KAYIT POLITIKASI" notu).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `matrix_exploit_log` (
    `id`          BIGINT       NOT NULL AUTO_INCREMENT,
    `citizenid`   VARCHAR(50)  NULL,
    `source_id`   INT          NULL,
    `category`    VARCHAR(64)  NOT NULL,
    `detail`      VARCHAR(255) NOT NULL,
    `coords_x`    FLOAT        NULL,
    `coords_y`    FLOAT        NULL,
    `coords_z`    FLOAT        NULL,
    `created_at`  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_matrix_exploit_log_citizenid` (`citizenid`),
    KEY `idx_matrix_exploit_log_category`  (`category`)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;

-- ---------------------------------------------------------------------
-- [3] matrix_agent_pool — matrix_bots uzerine salt-okunur formatlanmis VIEW
--
-- Ham `matrix_bots.id` (1, 2, 3, ...) admin panelinde/F10 terminalinde
-- okunmasi zor, cakisma-riskli bir gorunum veriyordu. Bu VIEW hicbir veriyi
-- kopyalamaz/coğaltmaz (matrix_bots'un salt-okunur bir izdusumudur) -- yalnizca
-- goruntuleme icin "AGENT_00001" bicimli bir kod-adi kolonu ekler.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW `matrix_agent_pool` AS
SELECT
    `id`,
    CONCAT('AGENT_', LPAD(`id`, 5, '0')) AS `agent_code`,
    `dna_id`,
    `name`,
    `role`,
    `status`,
    `trap_house_id`,
    `created_at`,
    `updated_at`
FROM `matrix_bots`;

SET FOREIGN_KEY_CHECKS = 1;
