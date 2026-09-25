-- =====================================================================
-- vbs_core_matrix v3.0 PHASE 1 — COGNITIVE MATRIX ADDITIVE MIGRATION
-- Strict IF NOT EXISTS. Safe to re-run.
-- =====================================================================
CREATE TABLE IF NOT EXISTS matrix_bot_cognition (
    bot_id INT PRIMARY KEY,
    iq_score INT DEFAULT 100,
    withdrawal_index FLOAT DEFAULT 0.0,
    fatigue_accumulation FLOAT DEFAULT 0.0,
    current_drug_influence VARCHAR(32) DEFAULT 'none',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);