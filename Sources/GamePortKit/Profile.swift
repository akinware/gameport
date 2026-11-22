import Foundation

/// One isolated Windows environment per game: its own Wine prefix, Steam install, logs and settings.
/// A fix for one game can never break another, because nothing is shared but the read-only engine.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public var schema: Int = 1
    public var id: String
    public var title: String
    public var recipeID: String?
    public var engineID: String
    /// A separately prepared profile for this game on another engine. Used only before launching.
    public var fallbackProfileID: String?
    /// Player overrides on top of the recipe (nil = take the recipe's value).
    public var renderer: Renderer?
    public var sync: SyncMode?
    public var advertiseAVX: Bool?
    public var metalHUD: Bool = false
    /// nil = MoltenVK.
    public var vulkanDriver: VulkanDriver?
    /// Daily snapshot before Steam starts (nil = on). Optional so older profile.json files still decode.
    public var autoSnapshots: Bool?
    /// Apple Silicon Performance Pack overrides (all optional for backwards compatibility).
    /// nil = on (schedule game processes on Performance cores via `taskpolicy`).
    public var performanceCores: Bool?
    /// nil = unchanged; false = force 1x Native (faster on Retina MacBooks); true = HiDPI Retina.
    public var retinaMode: Bool?
    /// nil = off; true = enable MetalFX upscaling (DXMT spatial + D3DMetal MetalFX).
    public var metalFX: Bool?
    /// nil = Rosetta 2 (default). Optional experimental AArchX (`ocerz` / `ocerz -fex`) runner.
    public var executionRunner: ExecutionRunner?
    public var environment: [String: String] = [:]
    public var createdAt: Date = Date()

    public init(id: String, title: String, recipeID: String?, engineID: String) {
        self.id = id; self.title = title; self.recipeID = recipeID; self.engineID = engineID
    }
}

public struct ProfileStore: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func directory(_ id: String) -> URL { paths.profile(id) }
    public func prefix(_ id: String) -> URL { directory(id).appendingPathComponent("prefix", isDirectory: true) }
    public func logs(_ id: String) -> URL { directory(id).appendingPathComponent("logs", isDirectory: true) }
    /// Private HOME / caches so Wine and Steam never write into the user's real home folders.
    public func home(_ id: String) -> URL { directory(id).appendingPathComponent("home", isDirectory: true) }
    private func file(_ id: String) -> URL { directory(id).appendingPathComponent("profile.json") }

    public func all() -> [Profile] {
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: paths.profiles.path) else { return [] }
        return ids.sorted().compactMap { try? load($0) }
    }

    public func load(_ id: String) throws -> Profile {
        try validateID(id, what: "profile id")
        let url = file(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw GamePortError.missing("profile \(id)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Profile.self, from: Data(contentsOf: url))
    }

    public func save(_ profile: Profile) throws {
        try validateID(profile.id, what: "profile id")
        try paths.ensure(directory(profile.id), logs(profile.id), home(profile.id))
        let encoder = JSONEncoder.pretty
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profile).write(to: file(profile.id), options: .atomic)
    }

    public func delete(_ id: String) throws {
        try validateID(id, what: "profile id")
        try FileManager.default.removeItem(at: directory(id))
    }
}

/// Licence acceptance receipts. Accepting is always an explicit user action (CLI or app button).
public struct LicenseStore: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public func isAccepted(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: paths.licenses.appendingPathComponent(id).path)
    }

    public func accept(_ id: String) throws {
        try validateID(id, what: "licence id")
        try paths.ensure(paths.licenses)
        let stamp = ISO8601DateFormatter().string(from: Date())
        try Data("accepted \(stamp)\n".utf8).write(to: paths.licenses.appendingPathComponent(id))
    }

    public func revoke(_ id: String) throws {
        try validateID(id, what: "licence id")
        try? FileManager.default.removeItem(at: paths.licenses.appendingPathComponent(id))
    }
}
