import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Pure-Swift Mach-O header reader (thin and universal/FAT) used to verify whether
/// native macOS `steamclient.dylib` contains an `x86_64` slice loadable by Wine under Rosetta.
public enum MachOInspector {
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64:  UInt32 = 0x0100_000C

    public struct Architectures: Equatable, Sendable {
        public let hasX86_64: Bool
        public let hasARM64: Bool
        public init(hasX86_64: Bool, hasARM64: Bool) {
            self.hasX86_64 = hasX86_64
            self.hasARM64 = hasARM64
        }
    }

    public static func architectures(of file: URL) -> Architectures {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let data = try? handle.read(upToCount: 4096) else {
            return Architectures(hasX86_64: false, hasARM64: false)
        }
        try? handle.close()
        return architectures(from: data)
    }

    public static func architectures(from data: Data) -> Architectures {
        guard data.count >= 8 else { return Architectures(hasX86_64: false, hasARM64: false) }
        let magicBE = readUInt32BE(data, at: 0)
        let magicLE = readUInt32LE(data, at: 0)

        // Thin 64-bit Mach-O
        if magicLE == 0xFEED_FACF {
            let cpu = readUInt32LE(data, at: 4)
            return Architectures(hasX86_64: cpu == cpuTypeX86_64, hasARM64: cpu == cpuTypeARM64)
        }
        if magicBE == 0xFEED_FACF {
            let cpu = readUInt32BE(data, at: 4)
            return Architectures(hasX86_64: cpu == cpuTypeX86_64, hasARM64: cpu == cpuTypeARM64)
        }

        // Universal FAT (32-bit or 64-bit header, always big-endian on disk)
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            let entrySize = magicBE == 0xCAFE_BABF ? 32 : 20
            let nfat = Int(min(readUInt32BE(data, at: 4), 16))
            var x64 = false
            var arm = false
            for i in 0..<nfat {
                let offset = 8 + i * entrySize
                guard offset + 4 <= data.count else { break }
                let cpu = readUInt32BE(data, at: offset)
                if cpu == cpuTypeX86_64 { x64 = true }
                if cpu == cpuTypeARM64 { arm = true }
            }
            return Architectures(hasX86_64: x64, hasARM64: arm)
        }

        return Architectures(hasX86_64: false, hasARM64: false)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

/// Readiness snapshot of GamePort's clean-room macOS Steamworks Bridge (`steamclient64.dll` <-> `steamclient.dylib`).
public struct SteamBridgeStatus: Sendable, Equatable {
    public let macSteamInstalled: Bool
    public let macSteamRunning: Bool
    public let steamClientDylib: URL?
    public let steamClientHasX86_64: Bool
    public let overlayDir: URL
    public let overlayInstalled: Bool
    public let probeExecutable: URL
    public let steamCmdInstalled: Bool

    public init(
        macSteamInstalled: Bool,
        macSteamRunning: Bool,
        steamClientDylib: URL?,
        steamClientHasX86_64: Bool,
        overlayDir: URL,
        overlayInstalled: Bool,
        probeExecutable: URL,
        steamCmdInstalled: Bool
    ) {
        self.macSteamInstalled = macSteamInstalled
        self.macSteamRunning = macSteamRunning
        self.steamClientDylib = steamClientDylib
        self.steamClientHasX86_64 = steamClientHasX86_64
        self.overlayDir = overlayDir
        self.overlayInstalled = overlayInstalled
        self.probeExecutable = probeExecutable
        self.steamCmdInstalled = steamCmdInstalled
    }

    public var isReadyToLaunch: Bool {
        overlayInstalled && steamClientDylib != nil && steamClientHasX86_64
    }

    public var readinessSummary: String {
        if !overlayInstalled {
            return "Bridge overlay not built yet — run Scripts/build-steam-bridge.sh"
        }
        guard steamClientDylib != nil else {
            return "Bridge overlay built · Install & run native Mac Steam.app to connect"
        }
        if !steamClientHasX86_64 {
            return "Native steamclient.dylib lacks an x86_64 slice for Rosetta Wine"
        }
        return macSteamRunning
            ? "Ready — connected to running native Mac Steam (zero Windows Steam)"
            : "Ready — open native Mac Steam.app before launching bridged games"
    }
}

/// Result of running `bridge_probe.exe` inside a Wine engine to verify the PE <-> UnixLib ABI round-trip.
public struct SteamBridgeProbeResult: Sendable, Equatable {
    public let success: Bool
    public let engineID: String
    public let mockMode: Bool
    public let output: String
    public let exitCode: Int32
}

/// Result of checking whether a Steam game is safe to run in Bridge mode (no Windows Steam).
public enum SteamBridgeVACDecision: Sendable, Equatable {
    case allowed
    case blocked(reason: String)
}

/// Clean-room GamePort Steam Bridge:
/// Runs non-VAC Windows Steam games directly under Wine (CrossOver or Wine Staging 11)
/// with ZERO Windows Steam running in the background by forwarding `steamclient64.dll`
/// calls over Wine's unixlib boundary to the user's untouched native macOS `steamclient.dylib`.
public struct SteamBridge: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var overlayDir: URL { paths.tools.appendingPathComponent("steam-bridge", isDirectory: true) }
    public var hostDaemon: URL { overlayDir.appendingPathComponent("gpsteambridge-host") }
    public var peDLL: URL { overlayDir.appendingPathComponent("x86_64-windows/steamclient64.dll") }
    public var peDLL32: URL { overlayDir.appendingPathComponent("i386-windows/steamclient.dll") }
    public var unixSO: URL { overlayDir.appendingPathComponent("x86_64-unix/steamclient64.so") }
    public var unixSO32: URL { overlayDir.appendingPathComponent("x86_64-unix/steamclient.so") }
    public var probeExecutable: URL { overlayDir.appendingPathComponent("bridge_probe.exe") }
    public var probeExecutable32: URL { overlayDir.appendingPathComponent("bridge_probe32.exe") }

    public var isOverlayInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: peDLL.path) && fm.fileExists(atPath: unixSO.path)
    }

    public var has32BitSupport: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: peDLL32.path) && fm.fileExists(atPath: unixSO32.path)
    }

    /// Searches standard native macOS Steam paths for `steamclient.dylib` without modifying Steam.app.
    public static func locateMacSteamClient(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let explicit = environment["GAMEPORT_MAC_STEAMCLIENT"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        candidates.append(
            home.appendingPathComponent(
                "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
            )
        )
        candidates.append(URL(fileURLWithPath: "/Applications/Steam.app/Contents/MacOS/steamclient.dylib"))
        candidates.append(home.appendingPathComponent("Applications/Steam.app/Contents/MacOS/steamclient.dylib"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Checks whether native Mac Steam (`steam_osx`) is running using Darwin `proc_listpids` + `proc_name`
    /// directly in-process — zero subprocesses and never pumps the main thread's CFRunLoop.
    public static func isMacSteamRunning() -> Bool {
        #if canImport(Darwin)
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return false }
        let count = Int(byteCount) / MemoryLayout<pid_t>.stride + 16
        var pids = [pid_t](repeating: 0, count: count)
        let actualBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard actualBytes > 0 else { return false }
        let n = Int(actualBytes) / MemoryLayout<pid_t>.stride
        var nameBuf = [CChar](repeating: 0, count: 256)
        for i in 0..<n where pids[i] > 0 {
            let len = proc_name(pids[i], &nameBuf, UInt32(nameBuf.count))
            if len > 0 {
                let name = String(cString: nameBuf)
                if name == "steam_osx" { return true }
            }
        }
        return false
        #else
        return false
        #endif
    }

    public func status(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SteamBridgeStatus {
        let dylib = Self.locateMacSteamClient(environment: environment, home: home)
        let archs = dylib.map { MachOInspector.architectures(of: $0) }
        let fm = FileManager.default
        let macSteamApp = fm.fileExists(atPath: "/Applications/Steam.app") ||
            fm.fileExists(atPath: home.appendingPathComponent("Applications/Steam.app").path) ||
            dylib != nil
        return SteamBridgeStatus(
            macSteamInstalled: macSteamApp,
            macSteamRunning: Self.isMacSteamRunning(),
            steamClientDylib: dylib,
            steamClientHasX86_64: archs?.hasX86_64 ?? false,
            overlayDir: overlayDir,
            overlayInstalled: isOverlayInstalled,
            probeExecutable: probeExecutable,
            steamCmdInstalled: SteamDepotManager(paths: paths).isInstalled
        )
    }

    /// Prevents accidentally running VAC multiplayer titles in Bridge mode (which lacks Windows VAC)
    /// and steers them to GamePort's isolated Windows Steam profile instead.
    public static func vacDecision(for antiCheat: AntiCheatEntry?) -> SteamBridgeVACDecision {
        guard let ac = antiCheat else { return .allowed }
        let hasVAC = ac.antiCheats.contains { name in
            let lower = name.lowercased()
            return lower == "vac" || lower.contains("valve anti-cheat")
        }
        if hasVAC {
            return .blocked(reason: "This game uses Valve Anti-Cheat (VAC). Bridge mode does not support VAC multiplayer — launch through GamePort's Windows Steam profile instead (or pass --force-vac for offline play).")
        }
        return .allowed
    }

    /// Builds the Wine environment additions that route `steamclient64.dll` -> `steamclient64.so`
    /// -> native macOS `steamclient.dylib` while keeping profile `HOME` isolated.
    public func bridgeEnvironment(
        engine: InstalledEngine,
        appID: Int,
        macSteamClient: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        mockMode: Bool = false,
        verboseLog: Bool = false
    ) -> [String: String] {
        var env: [String: String] = [
            "SteamAppId": String(appID),
            "SteamGameId": String(appID),
            "GAMEPORT_REAL_HOME": home.path,
            "GAMEPORT_BRIDGE_HOST": hostDaemon.path,
            "STEAM_COMPAT_CLIENT_INSTALL_PATH": home.appendingPathComponent("Library/Application Support/Steam").path,
            "WINEDLLOVERRIDES": "steamclient64,steamclient=b",
        ]
        if engine.manifest.effectiveOverlayMode == .prefix {
            env["WINEDLLPATH+"] = overlayDir.path
        } else {
            env["WINEDLLPATH_PREPEND+"] = overlayDir.path
        }
        if let macSteamClient {
            env["GAMEPORT_MAC_STEAMCLIENT"] = macSteamClient.path
        }
        if mockMode {
            env["GP_STEAM_BRIDGE_MOCK"] = "1"
        }
        if verboseLog {
            env["GP_STEAM_BRIDGE_LOG"] = "1"
        }
        // Debugging aid: e.g. GAMEPORT_WINEDEBUG=+seh to see the exception behind a silent exit.
        if let debug = ProcessInfo.processInfo.environment["GAMEPORT_WINEDEBUG"], !debug.isEmpty {
            env["WINEDEBUG"] = debug
        }
        return env
    }

    /// Configures a profile's Wine prefix so `steam_api64.dll` discovers GamePort's `steamclient64.dll`
    /// via `HKCU\Software\Valve\Steam\ActiveProcess` without launching Windows Steam.
    public func preparePrefix(runner: WineRunner, appID: Int) throws {
        guard isOverlayInstalled else {
            throw GamePortError.missing("GamePort Steam Bridge overlay is not built yet (run Scripts/build-steam-bridge.sh)")
        }
        try runner.prepareDirectories()

        let fm = FileManager.default
        let system32 = runner.prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        let syswow64 = runner.prefix.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try fm.createDirectory(at: syswow64, withIntermediateDirectories: true)

        // Stage both 64-bit (system32/steamclient64.dll) and 32-bit WoW64 (syswow64/steamclient.dll)
        // as Wine builtin symlinks so Wine pairs them with x86_64-unix/steamclient64.so & steamclient.so.
        let stagedDLL = system32.appendingPathComponent("steamclient64.dll")
        try? fm.removeItem(at: stagedDLL)
        try fm.createSymbolicLink(at: stagedDLL, withDestinationURL: peDLL)

        if has32BitSupport {
            let stagedDLL32 = syswow64.appendingPathComponent("steamclient.dll")
            try? fm.removeItem(at: stagedDLL32)
            try fm.createSymbolicLink(at: stagedDLL32, withDestinationURL: peDLL32)
        }

        let regKey = #"HKCU\Software\Valve\Steam\ActiveProcess"#
        let entries: [(String, String, String)] = [
            ("SteamClientDll64", "REG_SZ", #"C:\windows\system32\steamclient64.dll"#),
            ("SteamClientDll", "REG_SZ", #"C:\windows\syswow64\steamclient.dll"#),
            ("pid", "REG_DWORD", "1"),
            ("ActiveUser", "REG_DWORD", "1"),
            ("Universe", "REG_SZ", "Public"),
        ]
        for (name, type, value) in entries {
            try runner.run(
                ["reg", "add", regKey, "/v", name, "/t", type, "/d", value, "/f"],
                sync: SyncMode.none,
                check: false
            )
        }
        _ = appID
    }

    /// Where Mac Steam keeps Workshop items for `appID`.
    public static func macSteamWorkshopFolder(appID: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/\(appID)", isDirectory: true)
    }

    /// Launches a Windows Steam game executable directly through GamePort Bridge (zero Windows Steam).
    public func launch(
        runner: WineRunner,
        executable: URL,
        arguments: [String] = [],
        gameFolder: URL? = nil,
        appID: Int,
        antiCheat: AntiCheatEntry? = nil,
        allowVACOverride: Bool = false,
        verboseLog: Bool = false,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Process {
        if !allowVACOverride, case .blocked(let reason) = Self.vacDecision(for: antiCheat) {
            throw GamePortError.unsupported(reason)
        }
        let st = status(home: home)
        guard st.overlayInstalled else {
            throw GamePortError.missing("GamePort Steam Bridge overlay is not built yet (run Scripts/build-steam-bridge.sh)")
        }
        guard let dylib = st.steamClientDylib else {
            throw GamePortError.missing("Native macOS Steam.app (steamclient.dylib) was not found. Install and launch Mac Steam first.")
        }
        guard st.steamClientHasX86_64 else {
            throw GamePortError.unsupported("Native macOS steamclient.dylib does not contain an x86_64 slice for Rosetta Wine.")
        }
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw GamePortError.missing("Game executable not found: \(executable.path)")
        }

        try preparePrefix(runner: runner, appID: appID)

        // Ensure steam_appid.txt exists next to the executable so steam_api64.dll initializes cleanly.
        let appIDFile = executable.deletingLastPathComponent().appendingPathComponent("steam_appid.txt")
        if !FileManager.default.fileExists(atPath: appIDFile.path) {
            try? "\(appID)\n".write(to: appIDFile, atomically: true, encoding: .utf8)
        }

        let extra = bridgeEnvironment(
            engine: runner.engine,
            appID: appID,
            macSteamClient: dylib,
            home: home,
            mockMode: false,
            verboseLog: verboseLog
        )
        // A game outside the prefix (a depot download) gets a drive letter, so it runs from `Y:\…`
        // instead of a `\\?\unix\…` path that .NET games cannot handle.
        let insidePrefix = executable.standardizedFileURL.path.hasPrefix(runner.prefix.standardizedFileURL.path + "/")
        let folder = gameFolder ?? executable.deletingLastPathComponent()
        let windowsPath = insidePrefix ? nil : try runner.mapGameDrive(folder, executable: executable)
        // Workshop items Mac Steam downloads for this game: the Bridge turns their macOS folder into W:\….
        try runner.mapDrive(WineRunner.workshopDrive, to: Self.macSteamWorkshopFolder(appID: appID, home: home))
        return try runner.spawn(
            [windowsPath ?? executable.path] + arguments,
            extra: extra,
            logName: "bridge-game.log",
            currentDirectory: executable.deletingLastPathComponent()
        )
    }

    /// Runs `bridge_probe.exe` (or 32-bit WoW64 `bridge_probe32.exe`) in a clean temporary prefix
    /// against the given engine to verify the PE <-> Wine UnixLib <-> macOS SysV ABI bridge end-to-end.
    public func probe(engine: InstalledEngine, mockMode: Bool = false, probe32: Bool = false) throws -> SteamBridgeProbeResult {
        let targetProbe = probe32 ? probeExecutable32 : probeExecutable
        guard isOverlayInstalled, FileManager.default.fileExists(atPath: targetProbe.path) else {
            throw GamePortError.missing("GamePort Steam Bridge overlay/probe is not built yet (run Scripts/build-steam-bridge.sh)")
        }
        let tempDir = paths.temp.appendingPathComponent("bridge-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var dummyProfile = Profile(id: "bridge-probe", title: "Bridge Probe", recipeID: nil, engineID: engine.id)
        dummyProfile.renderer = .wined3d
        let runner = WineRunner(paths: paths, engine: engine, profile: dummyProfile, recipe: nil, directory: tempDir)
        try runner.prepareDirectories()
        if engine.manifest.effectiveOverlayMode == .prefix {
            try runner.run(["wineboot", "--init"], sync: SyncMode.none, check: false)
            let system32 = runner.prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
            try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
            let staged = system32.appendingPathComponent("steamclient64.dll")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: peDLL)
            if has32BitSupport {
                let syswow64 = runner.prefix.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
                try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
                let staged32 = syswow64.appendingPathComponent("steamclient.dll")
                try? FileManager.default.removeItem(at: staged32)
                try FileManager.default.createSymbolicLink(at: staged32, withDestinationURL: peDLL32)
            }
        }

        let dylib = mockMode ? nil : Self.locateMacSteamClient()
        let extra = bridgeEnvironment(
            engine: engine,
            appID: 480,
            macSteamClient: dylib,
            mockMode: mockMode,
            verboseLog: true
        )
        let result = try runner.run([targetProbe.path], sync: SyncMode.none, extra: extra, check: false)
        let combined = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedMarker = probe32 ? "OK32:" : "OK:"
        return SteamBridgeProbeResult(
            success: result.status == 0 && combined.contains(expectedMarker),
            engineID: engine.id,
            mockMode: mockMode,
            output: combined,
            exitCode: result.status
        )
    }
}
