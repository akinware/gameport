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
    /// Optional HTTPS endpoint for anonymous Lab reports (e.g. your Cloudflare Worker `/v1/report`).
    /// Nil keeps uploads dormant until deployed; override with `GAMEPORT_TELEMETRY_URL` for testing.
    public static let telemetryEndpoint: String? = nil
    /// Environment variable overriding `telemetryEndpoint`.
    public static let telemetryURLVariable = "GAMEPORT_TELEMETRY_URL"
}
