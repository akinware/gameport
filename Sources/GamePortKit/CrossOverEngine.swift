import Foundation

/// Detected installation of CodeWeavers CrossOver (`/Applications/CrossOver.app`).
/// GamePort never bundles, modifies, or mirrors CrossOver; when a user already owns CrossOver,
/// GamePort can use it directly as a 0 MB engine and 1-click launch games in existing bottles.
public struct CrossOverInstallation: Sendable, Equatable {
    public static let engineID = "system-crossover"

    public let appURL: URL
    public let sharedSupportURL: URL
    public let version: String?

    public init(appURL: URL, sharedSupportURL: URL, version: String?) {
        self.appURL = appURL
        self.sharedSupportURL = sharedSupportURL
        self.version = version
    }

    public var wineURL: URL { sharedSupportURL.appendingPathComponent("bin/wine") }
    public var wineServerURL: URL { sharedSupportURL.appendingPathComponent("bin/wineserver") }
    public var lib64URL: URL { sharedSupportURL.appendingPathComponent("lib64", isDirectory: true) }
    public var libURL: URL { sharedSupportURL.appendingPathComponent("lib", isDirectory: true) }

    public var hasExecutableWine: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: wineURL.path) && fm.isExecutableFile(atPath: wineServerURL.path)
    }

    /// Synthesizes a 0 MB `EngineManifest` pointing directly at the user's installed `CrossOver.app`.
    public func engineManifest() -> EngineManifest {
        let verLabel = version.map { " \($0)" } ?? ""
        let dyldLibs = [lib64URL.path, libURL.path].joined(separator: ":")
        return EngineManifest(
            schema: 1,
            id: Self.engineID,
            displayName: "CrossOver\(verLabel) (System · 0 MB)",
            arch: .rosetta,
            fexModules: nil,
            overlayMode: .prepend,
            supportsKosmicKrisp: false,
            minMacOS: "14.0",
            wineLoader: "bin/wine",
            wineServer: "bin/wineserver",
            components: [],
            baseEnvironment: [
                "DYLD_FALLBACK_LIBRARY_PATH+": dyldLibs,
                "CX_ROOT": sharedSupportURL.path,
            ],
            licenses: [:],
            notes: [
                "Uses your already-installed CrossOver.app directly (0 MB engine download).",
                "Inherits CrossOver's bundled Wine, D3DMetal, DXMT, and DXVK renderers.",
            ]
        )
    }

    /// Wraps this `CrossOver.app` installation as a standard `InstalledEngine` usable by `WineRunner`.
    public func asInstalledEngine() -> InstalledEngine {
        InstalledEngine(manifest: engineManifest(), root: sharedSupportURL)
    }
}

/// A launchable game discovered inside an existing CrossOver bottle.
public struct CrossOverBottleLaunchItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case steam(appID: Int)
        case battleNet
        case epicLauncher
        case gogGalaxy
    }

    public let bottleName: String
    public let bottlePath: URL
    public let title: String
    public let kind: Kind

    public init(bottleName: String, bottlePath: URL, title: String, kind: Kind) {
        self.bottleName = bottleName
        self.bottlePath = bottlePath
        self.title = title
        self.kind = kind
    }

    public var id: String {
        switch kind {
        case .steam(let appID): return "cx:\(bottleName):steam:\(appID)"
        case .battleNet: return "cx:\(bottleName):battlenet"
        case .epicLauncher: return "cx:\(bottleName):epic"
        case .gogGalaxy: return "cx:\(bottleName):gog"
        }
    }
}

/// Discovers an installed `CrossOver.app` and launches existing CrossOver bottle games with 1 click.
public enum CrossOverSupport {
    public static func detect(
        applicationsDirs: [URL]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CrossOverInstallation? {
        let dirs = applicationsDirs ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        let fm = FileManager.default
        for dir in dirs {
            let app = dir.appendingPathComponent("CrossOver.app", isDirectory: true)
            let shared = app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
            guard fm.fileExists(atPath: shared.appendingPathComponent("bin/wine").path) else { continue }
            let version = readBundleVersion(appURL: app)
            return CrossOverInstallation(appURL: app, sharedSupportURL: shared, version: version)
        }
        return nil
    }

    private static func readBundleVersion(appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return (dict["CFBundleShortVersionString"] as? String) ?? (dict["CFBundleVersion"] as? String)
    }

    /// Scans all CrossOver bottles for 1-click launchable Steam and Battle.net titles.
    public static func discoverBottleGames(
        bottlesRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    ) -> [CrossOverBottleLaunchItem] {
        let fm = FileManager.default
        let bottles = ExternalDiscovery.scanCrossOverBottles(in: bottlesRoot)
        var items: [CrossOverBottleLaunchItem] = []

        for bottle in bottles {
            for game in bottle.steamGames {
                items.append(CrossOverBottleLaunchItem(
                    bottleName: bottle.name,
                    bottlePath: bottle.path,
                    title: game.name,
                    kind: .steam(appID: game.appID)
                ))
            }
            for rel in BattleNetClient.relativeLauncherExes {
                let exe = bottle.path.appendingPathComponent("drive_c/" + rel)
                if fm.fileExists(atPath: exe.path) {
                    items.append(CrossOverBottleLaunchItem(
                        bottleName: bottle.name,
                        bottlePath: bottle.path,
                        title: "Battle.net (\(bottle.name))",
                        kind: .battleNet
                    ))
                    break
                }
            }
            let epicExes = [
                "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win64/EpicGamesLauncher.exe",
                "Program Files (x86)/Epic Games/Launcher/Portal/Binaries/Win32/EpicGamesLauncher.exe",
            ]
            if epicExes.contains(where: { fm.fileExists(atPath: bottle.path.appendingPathComponent("drive_c/" + $0).path) }) {
                items.append(CrossOverBottleLaunchItem(
                    bottleName: bottle.name,
                    bottlePath: bottle.path,
                    title: "Epic Games (\(bottle.name))",
                    kind: .epicLauncher
                ))
            }
            let gogExe = bottle.path.appendingPathComponent("drive_c/Program Files (x86)/GOG Galaxy/GalaxyClient.exe")
            if fm.fileExists(atPath: gogExe.path) {
                items.append(CrossOverBottleLaunchItem(
                    bottleName: bottle.name,
                    bottlePath: bottle.path,
                    title: "GOG Galaxy (\(bottle.name))",
                    kind: .gogGalaxy
                ))
            }
        }
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Builds the process executable, arguments, and environment to 1-click launch a CrossOver bottle game
    /// using CrossOver's own `wine` binary plus optional GamePort Apple Silicon Performance Pack flags.
    public static func launchSpec(
        installation: CrossOverInstallation,
        item: CrossOverBottleLaunchItem,
        performanceCores: Bool = true,
        metalFX: Bool = false,
        metalHUD: Bool = false,
        battleNetProduct: String? = nil
    ) -> (executable: String, arguments: [String], environment: [String: String]) {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = item.bottlePath.path
        env["CX_BOTTLE"] = item.bottleName
        env["CX_ROOT"] = installation.sharedSupportURL.path
        let libs = [installation.lib64URL.path, installation.libURL.path].joined(separator: ":")
        if let existing = env["DYLD_FALLBACK_LIBRARY_PATH"], !existing.isEmpty {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(libs):\(existing)"
        } else {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libs
        }
        if metalFX {
            env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
            env["DXMT_ENABLE_NVEXT"] = "1"
            env["D3DM_ENABLE_METALFX"] = "1"
        }
        if metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
        }

        let wineArgs: [String]
        switch item.kind {
        case .steam(let appID):
            wineArgs = [
                #"C:\Program Files (x86)\Steam\steam.exe"#,
                "-silent", "-nofriendsui", "-applaunch", String(appID),
            ]
        case .battleNet:
            var args = [#"C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe"#]
            if let code = battleNetProduct, !code.isEmpty {
                args.append("--exec=launch \(code)")
            }
            env["WINE_SIMULATE_WRITECOPY"] = "1"
            wineArgs = args
        case .epicLauncher:
            wineArgs = [#"C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#]
        case .gogGalaxy:
            wineArgs = [#"C:\Program Files (x86)\GOG Galaxy\GalaxyClient.exe"#]
        }

        #if os(macOS)
        if performanceCores && FileManager.default.isExecutableFile(atPath: "/usr/sbin/taskpolicy") {
            return ("/usr/sbin/taskpolicy", ["-a", "-t", "5", "-l", "5", installation.wineURL.path] + wineArgs, env)
        }
        #endif
        return (installation.wineURL.path, wineArgs, env)
    }

    /// 1-click launches a discovered CrossOver bottle game directly via the user's installed `CrossOver.app`.
    @discardableResult
    public static func launch(
        item: CrossOverBottleLaunchItem,
        installation: CrossOverInstallation? = nil,
        performanceCores: Bool = true,
        metalFX: Bool = false,
        metalHUD: Bool = false,
        battleNetProduct: String? = nil
    ) throws -> Process {
        guard let cx = installation ?? detect() else {
            throw GamePortError.missing("CrossOver.app is not installed in /Applications")
        }
        guard cx.hasExecutableWine else {
            throw GamePortError.missing("CrossOver Wine binary not found at \(cx.wineURL.path)")
        }
        let spec = launchSpec(
            installation: cx,
            item: item,
            performanceCores: performanceCores,
            metalFX: metalFX,
            metalHUD: metalHUD,
            battleNetProduct: battleNetProduct
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = performanceCores ? .userInteractive : .default
        try process.run()
        return process
    }
}
