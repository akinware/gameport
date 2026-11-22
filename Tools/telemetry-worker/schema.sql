CREATE TABLE IF NOT EXISTS lab_reports (
    install_id TEXT NOT NULL,
    steam_app_id INTEGER NOT NULL,
    recipe_id TEXT,
    renderer TEXT NOT NULL,
    vulkan_driver TEXT NOT NULL,
    sync_mode TEXT NOT NULL,
    engine_id TEXT NOT NULL,
    engine_arch TEXT NOT NULL,
    chip TEXT NOT NULL,
    ram_gb INTEGER,
    macos TEXT NOT NULL,
    verdict TEXT NOT NULL,
    avg_fps REAL,
    one_percent_low_fps REAL,
    peak_thermal TEXT,
    crash_codes TEXT NOT NULL,
    reported_day TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (install_id, steam_app_id, renderer, vulkan_driver, engine_id, chip)
);

CREATE INDEX IF NOT EXISTS idx_reports_game ON lab_reports (steam_app_id, chip, renderer);
