import Foundation

/// The product's name and identifiers, in one place so a rename is a small change.
/// Changing `dataFolder` moves where everything lives: existing installs then need their
/// ~/Library/Application Support/<old name> folder moved to the new name.
public enum Brand {
    /// Shown in the app's window, the CLI and messages.
    public static let displayName = "GamePort"
    /// The command-line tool's name (the SwiftPM product is `gameport`).
    public static let cliName = "gameport"
    /// Folder under ~/Library/Application Support.
    public static let dataFolder = "GamePort"
    /// Environment variable that overrides the data folder (tests, isolated QA).
    public static let homeEnvironmentVariable = "GAMEPORT_HOME"
    /// macOS bundle identifier of the app (also set in Scripts/make-app.sh).
    public static let bundleIdentifier = "app.gameport.GamePort"
    /// HTTPS endpoint for anonymous compatibility reports (Cloudflare Worker `/v1/report`).
    /// Override with `GAMEPORT_TELEMETRY_URL` for local testing.
    public static let telemetryEndpoint: String? = "https://gameport-telemetry.gameportapp.workers.dev/v1/report"
    /// HTTPS endpoint for aggregated live community verdicts (Cloudflare Worker `/v1/verdicts.json`).
    public static let verdictsEndpoint: String? = "https://gameport-telemetry.gameportapp.workers.dev/v1/verdicts.json"
    /// Environment variable overriding `telemetryEndpoint`.
    public static let telemetryURLVariable = "GAMEPORT_TELEMETRY_URL"
}
