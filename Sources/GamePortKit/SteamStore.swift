import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Looks up Steam Store games by name, App ID, or Store URL so players can add and launch
/// any Windows game on Steam — even titles never tested on Mac before.
public enum SteamStore {
    public struct SearchResult: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var name: String
        public var tinyImage: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case tinyImage = "tiny_image"
        }

        public init(id: Int, name: String, tinyImage: String? = nil) {
            self.id = id
            self.name = name
            self.tinyImage = tinyImage
        }
    }

    /// Extracts a positive Steam App ID from a plain number, Store URL, or `steam://` URL.
    public static func parseAppID(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), let id = Int(trimmed), id > 0 { return id }
        let patterns = [
            #"(?:store\.steampowered\.com|steamcommunity\.com)/app/(\d+)"#,
            #"steam://(?:run|rungameid|store)/(\d+)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed),
               let id = Int(trimmed[range]), id > 0 {
                return id
            }
        }
        return nil
    }

    public static func search(_ query: String) async throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let appID = parseAppID(trimmed) {
            let name = (try? await fetchTitle(appID: appID)) ?? "Steam Game \(appID)"
            return [SearchResult(id: appID, name: name, tinyImage: nil)]
        }
        var comps = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US"),
        ]
        guard let url = comps.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("\(Brand.displayName)/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GamePortError.invalid("Steam Store search failed")
        }
        return try parseSearchResponse(data)
    }

    public static func fetchTitle(appID: Int) async throws -> String? {
        guard appID > 0, let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("\(Brand.displayName)/1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return parseAppDetailsTitle(data, appID: appID)
    }

    static func parseSearchResponse(_ data: Data) throws -> [SearchResult] {
        struct Payload: Decodable { let items: [SearchResult]? }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        return (decoded.items ?? []).filter { $0.id > 0 && !$0.name.isEmpty }
    }

    static func parseAppDetailsTitle(_ data: Data, appID: Int) -> String? {
        struct Entry: Decodable {
            struct Details: Decodable { let name: String? }
            let success: Bool
            let data: Details?
        }
        guard let dict = try? JSONDecoder().decode([String: Entry].self, from: data),
              let entry = dict[String(appID)], entry.success,
              let name = entry.data?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }
}

extension GamePort {
    /// Adds a local recipe for any Steam game not yet in the catalog (or returns the existing one).
    @discardableResult
    public func addCustomSteamGame(appID: Int, title: String, renderer: Renderer = .dxmt) throws -> Recipe {
        guard appID > 0 else { throw GamePortError.invalid("Steam App ID must be positive") }
        if let existing = catalog.recipe(steamAppID: appID) { return existing }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { throw GamePortError.invalid("game title cannot be empty") }
        let recipe = Recipe(
            id: "custom-\(appID)",
            title: cleanTitle,
            steamAppID: appID,
            launch: .steam,
            renderer: renderer,
            sync: .msync,
            advertiseAVX: false,
            environment: [:],
            launchArguments: [],
            registry: [],
            status: .untested,
            notes: ["Added manually via Steam. Use Advanced → Find the best renderer if the default renderer has trouble."],
            knownIssues: [],
            source: "Added by player"
        )
        try recipe.validate()
        let dir = paths.db.appendingPathComponent("recipes", isDirectory: true)
        try paths.ensure(dir)
        let file = dir.appendingPathComponent("\(recipe.id).json")
        try JSONEncoder.pretty.encode(recipe).write(to: file, options: .atomic)
        return recipe
    }
}
