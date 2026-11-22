import Foundation

/// A Steam game discovered from an installed Valve `appmanifest_<id>.acf` file.
public struct DiscoveredSteamGame: Sendable, Equatable, Identifiable {
    public let appID: Int
    public let name: String
    public let installDir: String
    public let sizeOnDisk: Int64?

    public var id: Int { appID }
}

/// A Steam game discovered from the signed-in native Mac Steam client's `userdata/*/config/localconfig.vdf`
/// enriched with local `appcache/appinfo.vdf` metadata (title, OS support, type) — zero API keys or network needed.
public struct OwnedSteamGame: Sendable, Equatable, Identifiable {
    public let appID: Int
    public let title: String?
    public let osList: [String]
    public let appType: String?
    public let lastPlayed: Date?
    public let playtimeMinutes: Int

    public var id: Int { appID }
    public var supportsMacOS: Bool { osList.contains("macos") }
    public var supportsWindows: Bool { osList.isEmpty || osList.contains("windows") }
    public var isGameType: Bool {
        guard let t = appType?.lowercased(), !t.isEmpty else { return true }
        return t == "game" || t == "demo"
    }

    public init(
        appID: Int,
        title: String? = nil,
        osList: [String] = [],
        appType: String? = nil,
        lastPlayed: Date?,
        playtimeMinutes: Int
    ) {
        self.appID = appID
        self.title = title
        self.osList = osList
        self.appType = appType
        self.lastPlayed = lastPlayed
        self.playtimeMinutes = playtimeMinutes
    }
}

/// Local Steam artwork files cached by native Mac Steam under `appcache/librarycache/<appID>/`.
public struct LocalSteamArtwork: Sendable, Equatable {
    public let poster: URL?
    public let hero: URL?
    public let logo: URL?
    public let header: URL?
}

/// Basic game metadata extracted from Valve's local binary `appcache/appinfo.vdf`.
public struct SteamAppInfoRecord: Sendable, Equatable {
    public let appID: Int
    public let name: String
    public let appType: String
    public let osList: [String]
}

/// An existing CrossOver bottle discovered under `~/Library/Application Support/CrossOver/Bottles`.
public struct CrossOverBottle: Sendable, Equatable, Identifiable {
    public let name: String
    public let path: URL
    public let steamGames: [DiscoveredSteamGame]

    public var id: String { name }
}

/// Snapshot of external macOS gaming tools installed on this Mac (read-only discovery).
/// GamePort never bundles or copies third-party apps; it only detects user-installed apps
/// so players can launch them from one place when appropriate (e.g. Obelisk for Linux-EAC games).
public struct ExternalEnvironment: Sendable, Equatable {
    public static let obeliskWebsite = "https://getobelisk.app"
    public static let siliconiumWebsite = "https://github.com/sirdankdabs/siliconium/releases/latest"

    /// Steam AppIDs of the classic Call of Duty lineup tuned by Siliconium (CoD 1 through Infinite Warfare).
    public static let siliconiumAppIDs: Set<Int> = [
        2620,   // Call of Duty (2003)
        2640,   // Call of Duty: United Offensive
        2630,   // Call of Duty 2
        7940,   // Call of Duty 4: Modern Warfare
        10090,  // Call of Duty: World at War
        10180,  // Call of Duty: Modern Warfare 2 (2009) SP
        10190,  // Call of Duty: Modern Warfare 2 (2009) MP
        42700,  // Call of Duty: Black Ops SP
        42710,  // Call of Duty: Black Ops MP
        42680,  // Call of Duty: Modern Warfare 3 (2011) SP
        42690,  // Call of Duty: Modern Warfare 3 (2011) MP
        202970, // Call of Duty: Black Ops II SP
        202990, // Call of Duty: Black Ops II MP
        212910, // Call of Duty: Black Ops II Zombies
        209160, // Call of Duty: Ghosts SP
        209170, // Call of Duty: Ghosts MP
        209650, // Call of Duty: Advanced Warfare SP
        209660, // Call of Duty: Advanced Warfare MP
        311210, // Call of Duty: Black Ops III
        292730, // Call of Duty: Infinite Warfare
    ]

    public let obeliskApp: URL?
    public let siliconiumApp: URL?
    public let crossoverApp: URL?
    public let crossoverBottles: [CrossOverBottle]
    public let macSteamApp: URL?
    public let macSteamGames: [DiscoveredSteamGame]
    public let macSteamOwnedGames: [OwnedSteamGame]
    public let notProtonInstalled: Bool

    public var hasObelisk: Bool { obeliskApp != nil }
    public var hasSiliconium: Bool { siliconiumApp != nil }
    public var hasCrossOver: Bool { crossoverApp != nil }
    public var hasMacSteam: Bool { macSteamApp != nil }

    public static func suggestsSiliconium(steamAppID: Int?) -> Bool {
        guard let id = steamAppID else { return false }
        return siliconiumAppIDs.contains(id)
    }

    public func macSteamGame(appID: Int) -> DiscoveredSteamGame? {
        macSteamGames.first { $0.appID == appID }
    }

    public func crossoverBottle(containingAppID appID: Int) -> CrossOverBottle? {
        crossoverBottles.first { $0.steamGames.contains { $0.appID == appID } }
    }

    /// True ONLY when a game uses Easy Anti-Cheat or BattlEye with Linux/Steam Deck support
    /// (e.g. Elden Ring online, Armored Core VI, Rocket League), where Obelisk's Linux runtime
    /// helps — never on VAC games that already work natively in GamePort's Windows Steam.
    public static func suggestsObelisk(for antiCheat: AntiCheatEntry?) -> Bool {
        guard let ac = antiCheat else { return false }
        let linuxOK = ac.linuxStatus == "Supported" || ac.linuxStatus == "Running"
        guard linuxOK else { return false }
        return ac.antiCheats.contains { name in
            let lower = name.lowercased()
            return lower.contains("easy anti-cheat") || lower.contains("battleye")
        }
    }

    public static let empty = ExternalEnvironment(
        obeliskApp: nil, siliconiumApp: nil, crossoverApp: nil, crossoverBottles: [],
        macSteamApp: nil, macSteamGames: [], macSteamOwnedGames: [], notProtonInstalled: false
    )
}

/// Read-only discovery of installed external launchers (Obelisk, Siliconium, CrossOver, native Mac Steam / NotProton).
public enum ExternalDiscovery {
    public static func scan(
        applicationsDirs: [URL]? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExternalEnvironment {
        let appDirs = applicationsDirs ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        let fm = FileManager.default

        func findApp(_ name: String) -> URL? {
            for dir in appDirs {
                let candidate = dir.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }

        let obelisk = findApp("Obelisk.app")
        let siliconium = findApp("Siliconium.app")
        let crossover = findApp("CrossOver.app")
        let macSteam = findApp("Steam.app")

        let bottlesRoot = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
        let bottles = scanCrossOverBottles(in: bottlesRoot)

        let steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        let macSteamGames = scanSteamApps(in: steamRoot.appendingPathComponent("steamapps", isDirectory: true))
        let appInfo = parseAppInfoVDF(at: steamRoot.appendingPathComponent("appcache/appinfo.vdf"))
        let macSteamOwnedGames = scanMacSteamOwnedGames(
            in: steamRoot.appendingPathComponent("userdata", isDirectory: true),
            appInfo: appInfo
        )
        let compatTools = steamRoot.appendingPathComponent("compatibilitytools.d", isDirectory: true)
        let notProton = ((try? fm.contentsOfDirectory(atPath: compatTools.path)) ?? [])
            .contains { $0.localizedCaseInsensitiveContains("notproton") || $0.localizedCaseInsensitiveContains("proton") || $0.localizedCaseInsensitiveContains("bridgeplay") }

        return ExternalEnvironment(
            obeliskApp: obelisk,
            siliconiumApp: siliconium,
            crossoverApp: crossover,
            crossoverBottles: bottles,
            macSteamApp: macSteam,
            macSteamGames: macSteamGames,
            macSteamOwnedGames: macSteamOwnedGames,
            notProtonInstalled: notProton
        )
    }

    public static func scanCrossOverBottles(in bottlesRoot: URL) -> [CrossOverBottle] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bottlesRoot.path) else { return [] }
        return names.sorted().compactMap { name in
            let dir = bottlesRoot.appendingPathComponent(name, isDirectory: true)
            let conf = dir.appendingPathComponent("cxbottle.conf")
            guard fm.fileExists(atPath: conf.path) else { return nil }
            let steamApps = dir.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps", isDirectory: true)
            return CrossOverBottle(name: name, path: dir, steamGames: scanSteamApps(in: steamApps))
        }
    }

    /// Resolves locally cached Steam artwork (`library_600x900.jpg`, `library_hero.jpg`, `logo.png`, `header.jpg`)
    /// from native Mac Steam's `appcache/librarycache/<appID>/` for instant 0 ms loading.
    public static func localSteamArtwork(
        appID: Int,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> LocalSteamArtwork {
        let dir = home.appendingPathComponent("Library/Application Support/Steam/appcache/librarycache/\(appID)", isDirectory: true)
        let fm = FileManager.default
        func pick(_ names: [String]) -> URL? {
            for name in names {
                let u = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: u.path) { return u }
            }
            return nil
        }
        return LocalSteamArtwork(
            poster: pick(["library_600x900.jpg", "library_capsule.jpg", "header.jpg"]),
            hero: pick(["library_hero.jpg", "header.jpg"]),
            logo: pick(["logo.png"]),
            header: pick(["header.jpg", "library_600x900.jpg"])
        )
    }

    /// Parses Valve's binary `appcache/appinfo.vdf` (v29 `0x07564429`) in pure Swift to extract
    /// official game titles, `type` (Game/Tool/DLC), and `oslist` (windows/macos/linux).
    public static func parseAppInfoVDF(at url: URL) -> [Int: SteamAppInfoRecord] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 16 else { return [:] }
        return data.withUnsafeBytes { raw -> [Int: SteamAppInfoRecord] in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            func u32(_ off: Int) -> UInt32 {
                UInt32(bytes[off]) | (UInt32(bytes[off + 1]) << 8) |
                (UInt32(bytes[off + 2]) << 16) | (UInt32(bytes[off + 3]) << 24)
            }
            func u64(_ off: Int) -> UInt64 {
                UInt64(u32(off)) | (UInt64(u32(off + 4)) << 32)
            }
            func readCStr(_ off: inout Int) -> String {
                let start = off
                while off < count && bytes[off] != 0 { off += 1 }
                let str = String(decoding: UnsafeBufferPointer(start: bytes.baseAddress! + start, count: off - start), as: UTF8.self)
                if off < count { off += 1 }
                return str
            }

            let magic = u32(0)
            guard magic == 0x0756_4429 else { return [:] }
            let strTableOff = Int(u64(8))
            guard strTableOff >= 16, strTableOff + 4 <= count else { return [:] }

            var sp = strTableOff
            let strCount = Int(u32(sp)); sp += 4
            var strings: [String] = []
            strings.reserveCapacity(min(strCount, 32_768))
            for _ in 0..<strCount {
                guard sp < count else { break }
                strings.append(readCStr(&sp))
            }

            func parseCommon(from startOff: Int, end: Int) -> (name: String?, type: String?, oslist: String?) {
                var off = startOff
                var name: String?
                var appType: String?
                var oslist: String?

                func walk(depth: Int, inCommon: Bool) {
                    while off < end {
                        let t = bytes[off]; off += 1
                        if t == 8 { return }
                        guard off + 4 <= end else { off = end; return }
                        let idx = Int(u32(off)); off += 4
                        let key = idx < strings.count ? strings[idx] : ""
                        switch t {
                        case 0:
                            let nextCommon = inCommon || (depth == 1 && key == "common")
                            walk(depth: depth + 1, inCommon: nextCommon)
                        case 1:
                            let val = readCStr(&off)
                            if inCommon && depth == 2 {
                                if key == "name" { name = val }
                                else if key == "type" { appType = val }
                                else if key == "oslist" { oslist = val }
                            }
                        case 2, 3, 5, 6:
                            off += 4
                        case 7, 10:
                            off += 8
                        default:
                            off = end
                            return
                        }
                    }
                }
                walk(depth: 0, inCommon: false)
                return (name, appType, oslist)
            }

            var records: [Int: SteamAppInfoRecord] = [:]
            var off = 16
            while off + 8 <= strTableOff {
                let appID = Int(u32(off)); off += 4
                if appID == 0 { break }
                let size = Int(u32(off)); off += 4
                let entryEnd = off + size
                guard size >= 60, entryEnd <= strTableOff else { break }
                let common = parseCommon(from: off + 60, end: entryEnd)
                if let name = common.name, !name.isEmpty {
                    let os = (common.oslist ?? "")
                        .lowercased()
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    records[appID] = SteamAppInfoRecord(
                        appID: appID,
                        name: name,
                        appType: common.type ?? "",
                        osList: os
                    )
                }
                off = entryEnd
            }
            return records
        }
    }

    /// Scans signed-in Mac Steam `userdata/*/config/localconfig.vdf` files for owned/played AppIDs
    /// enriched with `appinfo.vdf` names and OS lists (read-only, zero Steam API key or credentials).
    public static func scanMacSteamOwnedGames(
        in userdataDir: URL,
        appInfo: [Int: SteamAppInfoRecord] = [:]
    ) -> [OwnedSteamGame] {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: userdataDir.path) else { return [] }
        var byAppID: [Int: OwnedSteamGame] = [:]
        for acct in accounts where acct.allSatisfy(\.isNumber) {
            let vdf = userdataDir.appendingPathComponent("\(acct)/config/localconfig.vdf")
            guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
            for raw in parseLocalConfigApps(text) {
                let meta = appInfo[raw.appID]
                let game = OwnedSteamGame(
                    appID: raw.appID,
                    title: meta?.name ?? raw.title,
                    osList: meta?.osList ?? raw.osList,
                    appType: meta?.appType ?? raw.appType,
                    lastPlayed: raw.lastPlayed,
                    playtimeMinutes: raw.playtimeMinutes
                )
                guard game.isGameType else { continue }
                if let existing = byAppID[game.appID] {
                    let newerDate = max(existing.lastPlayed ?? .distantPast, game.lastPlayed ?? .distantPast)
                    byAppID[game.appID] = OwnedSteamGame(
                        appID: game.appID,
                        title: game.title ?? existing.title,
                        osList: game.osList.isEmpty ? existing.osList : game.osList,
                        appType: game.appType ?? existing.appType,
                        lastPlayed: newerDate == .distantPast ? nil : newerDate,
                        playtimeMinutes: max(existing.playtimeMinutes, game.playtimeMinutes)
                    )
                } else {
                    byAppID[game.appID] = game
                }
            }
        }
        return byAppID.values.sorted { lhs, rhs in
            let lTime = lhs.lastPlayed?.timeIntervalSince1970 ?? 0
            let rTime = rhs.lastPlayed?.timeIntervalSince1970 ?? 0
            if lTime != rTime { return lTime > rTime }
            if lhs.playtimeMinutes != rhs.playtimeMinutes { return lhs.playtimeMinutes > rhs.playtimeMinutes }
            return lhs.appID < rhs.appID
        }
    }

    /// Parses the `"apps" { "<appID>" { "LastPlayed" "..." "Playtime" "..." } }` section of `localconfig.vdf`.
    public static func parseLocalConfigApps(_ text: String) -> [OwnedSteamGame] {
        var results: [OwnedSteamGame] = []
        var depth = 0
        var appsDepth: Int? = nil
        var pendingKey: String? = nil
        var currentAppID: Int? = nil
        var currentLastPlayed: TimeInterval? = nil
        var currentPlaytime: Int? = nil

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                depth += 1
                if appsDepth == nil, pendingKey?.lowercased() == "apps" {
                    appsDepth = depth
                } else if let ad = appsDepth, depth == ad + 1, let key = pendingKey, let id = Int(key), id > 0 {
                    currentAppID = id
                    currentLastPlayed = nil
                    currentPlaytime = nil
                }
                pendingKey = nil
                continue
            }
            if line == "}" {
                if let ad = appsDepth {
                    if depth == ad + 1, let appID = currentAppID {
                        // Exclude Steam client internal buckets (7, 760) that have neither LastPlayed nor Playtime.
                        if currentLastPlayed != nil || currentPlaytime != nil {
                            let lp = (currentLastPlayed ?? 0) > 0 ? Date(timeIntervalSince1970: currentLastPlayed!) : nil
                            results.append(OwnedSteamGame(appID: appID, lastPlayed: lp, playtimeMinutes: currentPlaytime ?? 0))
                        }
                        currentAppID = nil
                    } else if depth == ad {
                        appsDepth = nil
                    }
                }
                depth = max(0, depth - 1)
                pendingKey = nil
                continue
            }
            let tokens = extractQuotedTokens(line)
            if tokens.count == 1 {
                pendingKey = tokens[0]
            } else if tokens.count >= 2, let ad = appsDepth, depth == ad + 1, currentAppID != nil {
                let k = tokens[0].lowercased()
                if k == "lastplayed", let ts = TimeInterval(tokens[1]) {
                    currentLastPlayed = ts
                } else if k == "playtime", let mins = Int(tokens[1]) {
                    currentPlaytime = mins
                }
            }
        }
        return results
    }

    public static func scanSteamApps(in steamappsDir: URL) -> [DiscoveredSteamGame] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: steamappsDir.path) else { return [] }
        return files.sorted().compactMap { file -> DiscoveredSteamGame? in
            guard file.hasPrefix("appmanifest_"), file.hasSuffix(".acf") else { return nil }
            guard let text = try? String(contentsOf: steamappsDir.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return parseAppManifest(text)
        }
    }

    /// Lightweight Valve ACF/VDF key-value parser for `appmanifest_<id>.acf`.
    public static func parseAppManifest(_ text: String) -> DiscoveredSteamGame? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = extractQuotedTokens(String(line))
            if parts.count >= 2 {
                let key = parts[0].lowercased()
                if values[key] == nil { values[key] = parts[1] }
            }
        }
        guard let idStr = values["appid"], let appID = Int(idStr), appID > 0,
              let name = values["name"], !name.isEmpty else { return nil }
        let installDir = values["installdir"] ?? ""
        let size = values["sizeondisk"].flatMap(Int64.init)
        return DiscoveredSteamGame(appID: appID, name: name, installDir: installDir, sizeOnDisk: size)
    }

    private static func extractQuotedTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in line {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" && inQuotes {
                escaped = true
            } else if ch == "\"" {
                if inQuotes {
                    tokens.append(current)
                    current = ""
                }
                inQuotes.toggle()
            } else if inQuotes {
                current.append(ch)
            }
        }
        return tokens
    }
}
