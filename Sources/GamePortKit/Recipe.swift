import Foundation

/// What a game needs to run: renderer, sync mode, environment, registry values, launch method.
/// Recipes are data. Ours live in Resources/recipes; highball-db's (CC0) can be imported.
public struct Recipe: Codable, Sendable, Equatable, Identifiable {
    public enum Launch: String, Codable, Sendable {
        /// `steam.exe -silent -applaunch <appid>`: Steam starts the game (DRM, Steamworks work).
        case steam
        /// Steam is started in the background, then the game's own executable is run directly with
        /// SteamAppId set (used where Steam's launch path adds an anti-cheat bootstrapper that
        /// cannot run under Wine and the game supports offline play without it).
        case direct
        /// Windows Battle.net desktop app (`Battle.net Launcher.exe`, optionally with `--exec=launch <code>`).
        case battlenet
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case verified      // we ran it end to end on a Mac
        case community     // reported working by others, not yet verified by us
        case untested
        case blocked       // cannot work (kernel anti-cheat, …)
    }

    public struct RegistryValue: Codable, Sendable, Equatable {
        public var key: String          // e.g. HKCU\Software\Wine\AppDefaults\game.exe\Mac Driver
        public var name: String         // "" for the default value
        public var type: String         // REG_SZ | REG_DWORD
        public var data: String
    }

    public struct KnownIssue: Codable, Sendable, Equatable {
        public var symptom: String
        public var cause: String?
        public var fix: String?
    }

    public var schema: Int
    public var id: String
    public var title: String
    public var steamAppID: Int?
    /// Optional Blizzard Battle.net product code (e.g. `"Pro"` for Overwatch 2, `"Fen"` for Diablo IV).
    public var battleNetProduct: String?
    /// Path of the game executable relative to `steamapps/common`, used for detection and `direct`.
    public var executable: String?
    public var launch: Launch
    public var renderer: Renderer
    public var sync: SyncMode
    public var advertiseAVX: Bool
    public var environment: [String: String]
    public var dllOverrides: String?
    public var launchArguments: [String]
    public var registry: [RegistryValue]
    /// Optional fixes applied only when the player requests them.
    public var configDefaults: ConfigPatcher.Defaults?
    public var minMacOS: String?
    public var status: Status
    public var notes: [String]
    public var knownIssues: [KnownIssue]
    /// Where the facts came from (our test, highball-db id, …).
    public var source: String?

    public init(id: String, title: String, steamAppID: Int? = nil, battleNetProduct: String? = nil,
                executable: String? = nil, launch: Launch = .steam,
                renderer: Renderer, sync: SyncMode = .msync, advertiseAVX: Bool = false,
                environment: [String: String] = [:], dllOverrides: String? = nil, launchArguments: [String] = [],
                registry: [RegistryValue] = [], minMacOS: String? = nil, status: Status = .untested,
                notes: [String] = [], knownIssues: [KnownIssue] = [], source: String? = nil) {
        self.schema = 1
        self.id = id; self.title = title; self.steamAppID = steamAppID; self.battleNetProduct = battleNetProduct
        self.executable = executable
        self.launch = launch; self.renderer = renderer; self.sync = sync; self.advertiseAVX = advertiseAVX
        self.environment = environment; self.dllOverrides = dllOverrides; self.launchArguments = launchArguments
        self.registry = registry; self.minMacOS = minMacOS; self.status = status; self.notes = notes
        self.knownIssues = knownIssues; self.source = source
    }

    public func validate() throws {
        try validateID(id, what: "recipe id")
        try configDefaults?.validate()
        guard schema == 1 else { throw GamePortError.unsupported("recipe schema \(schema)") }
        if launch == .direct, executable == nil { throw GamePortError.invalid("\(id): a direct launch needs an executable") }
        if let exe = executable { _ = try Archive.safeSubpath(exe) }
        for r in registry {
            guard ["REG_SZ", "REG_DWORD"].contains(r.type) else { throw GamePortError.unsupported("\(id): registry type \(r.type)") }
            guard r.key.hasPrefix("HKCU\\") || r.key.hasPrefix("HKLM\\") || r.key.hasPrefix("HKEY_CURRENT_USER\\") else {
                throw GamePortError.invalid("\(id): registry key \(r.key)")
            }
        }
        for key in environment.keys where key.isEmpty || key.contains("=") {
            throw GamePortError.invalid("\(id): environment variable name '\(key)'")
        }
    }
}

/// All recipes the app knows: bundled ones first, then imported ones (bundled wins on id clash).
public struct RecipeCatalog: Sendable {
    public private(set) var recipes: [String: Recipe] = [:]

    public init(recipes: [Recipe] = []) {
        for r in recipes where self.recipes[r.id] == nil { self.recipes[r.id] = r }
    }

    public static func load(paths: Paths) -> RecipeCatalog {
        var all = bundled()
        all += loadDirectory(paths.db.appendingPathComponent("recipes"))
        return RecipeCatalog(recipes: all)
    }

    public static func bundled() -> [Recipe] {
        BundledData.recipes.compactMap { text in
            guard let r = try? JSONDecoder().decode(Recipe.self, from: Data(text.utf8)), (try? r.validate()) != nil else { return nil }
            return r
        }
    }

    static func loadDirectory(_ dir: URL) -> [Recipe] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let r = try? JSONDecoder().decode(Recipe.self, from: Data(contentsOf: url)), (try? r.validate()) != nil else { return nil }
            return r
        }
    }

    public subscript(id: String) -> Recipe? { recipes[id] }

    public func recipe(steamAppID: Int) -> Recipe? { recipes.values.first { $0.steamAppID == steamAppID } }

    public var sorted: [Recipe] {
        recipes.values.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

/// Filters an already sorted catalog so typing in the sidebar never reloads or reorders it.
public struct RecipeFilter {
    public var query = ""
    public var status: Recipe.Status?
    public var renderer: Renderer?

    public init() {}

    public func apply(to recipes: [Recipe]) -> [Recipe] {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let words = fold(query).split(whereSeparator: \.isWhitespace)
        return recipes.filter { recipe in
            guard status == nil || recipe.status == status, renderer == nil || recipe.renderer == renderer else { return false }
            if words.isEmpty { return true }
            let names = fold(recipe.title + " " + recipe.id)
            let appID = recipe.steamAppID.map(String.init)
            return words.allSatisfy { names.contains($0) || String($0) == appID }
        }
    }
}

/// Converts highball-db recipes (CC0, github.com/gauthierpiarrette/highball-db) into ours.
/// Steps we do not implement yet are kept as notes so nothing is silently lost.
public enum HighballDBImporter {
    public static func convert(_ data: Data, steamAppIDs: [String: Int] = [:]) throws -> Recipe {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String, let title = obj["title"] as? String else {
            throw GamePortError.invalid("could not read the highball-db recipe")
        }
        var renderer = Renderer(rawValue: (obj["renderer"] as? String) ?? "") ?? .dxmt
        var sync: SyncMode = .msync
        var env: [String: String] = [:]
        var registry: [Recipe.RegistryValue] = []
        var overrides: [String] = []
        var args: [String] = []
        var notes: [String] = []
        for step in (obj["steps"] as? [[String: Any]]) ?? [] {
            switch step["type"] as? String {
            case "renderer":
                if let r = Renderer(rawValue: (step["renderer"] as? String) ?? "") { renderer = r }
                else { notes.append("Desteklenmeyen renderer: \(step["renderer"] ?? "?")") }
            case "environment":
                if let n = step["name"] as? String, let v = step["value"] as? String {
                    if n == "WINEDLLOVERRIDES" { overrides.append(v) } else { env[n] = v }
                }
            case "registry":
                if let k = step["key"] as? String {
                    let type = (step["valueType"] as? String) ?? "REG_SZ"
                    let data = step["data"].map { "\($0)" } ?? ""
                    registry.append(.init(key: k, name: (step["name"] as? String) ?? "", type: type, data: data))
                }
            case "sync":
                if let s = SyncMode(rawValue: (step["sync"] as? String) ?? "") { sync = s }
            case "launchArgs", "arguments":
                args += (step["arguments"] as? [String]) ?? []
            case "note":
                if let t = step["text"] as? String { notes.append(t) }
            case let other?:
                notes.append("highball-db step not applied yet: \(other) \(step["verb"] ?? step["name"] ?? "")")
            case nil:
                break
            }
        }
        let issues = ((obj["knownIssues"] as? [[String: Any]]) ?? []).compactMap { i -> Recipe.KnownIssue? in
            guard let s = i["symptom"] as? String else { return nil }
            return .init(symptom: s, cause: i["cause"] as? String, fix: i["fix"] as? String)
        }
        let verified = obj["lastVerified"] is [String: Any]
        let recipe = Recipe(id: "hbdb-" + id, title: title, steamAppID: steamAppIDs[id], renderer: renderer, sync: sync,
                            environment: env.filter { $0.key != "ROSETTA_ADVERTISE_AVX" },
                            dllOverrides: overrides.isEmpty ? nil : overrides.joined(separator: ";"),
                            launchArguments: args, registry: registry,
                            status: verified ? .community : .untested, notes: notes, knownIssues: issues,
                            source: "highball-db/\(id) (CC0)")
        var r = recipe
        r.advertiseAVX = env["ROSETTA_ADVERTISE_AVX"] == "1"
        try r.validate()
        return r
    }
}
