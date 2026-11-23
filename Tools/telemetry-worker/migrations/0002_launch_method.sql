-- Adds launch_method ("windowsSteam", "bridge", "lab") to the key, so a Bridge report and a Windows
-- Steam report for the same game and setup are kept side by side instead of overwriting each other.
-- Existing rows came from Windows Steam plays and Lab runs; they become "windowsSteam".
CREATE TABLE lab_reports_v2 (
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
    launch_method TEXT NOT NULL DEFAULT 'windowsSteam',
    PRIMARY KEY (install_id, steam_app_id, renderer, vulkan_driver, engine_id, chip, launch_method)
);
-- Columns by name: deployments that added ram_gb later have it last.
INSERT INTO lab_reports_v2 (install_id, steam_app_id, recipe_id, renderer, vulkan_driver, sync_mode, engine_id, engine_arch, chip, ram_gb, macos, verdict, avg_fps, one_percent_low_fps, peak_thermal, crash_codes, reported_day, updated_at, launch_method)
SELECT install_id, steam_app_id, recipe_id, renderer, vulkan_driver, sync_mode, engine_id, engine_arch, chip, ram_gb, macos, verdict, avg_fps, one_percent_low_fps, peak_thermal, crash_codes, reported_day, updated_at, 'windowsSteam' FROM lab_reports;
DROP TABLE lab_reports;
ALTER TABLE lab_reports_v2 RENAME TO lab_reports;
CREATE INDEX IF NOT EXISTS idx_reports_game ON lab_reports (steam_app_id, chip, renderer);
