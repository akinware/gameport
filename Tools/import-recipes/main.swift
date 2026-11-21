import Foundation
import GamePortKit

// Maintenance helper for Scripts/import-recipes.py. All validation uses the shipping decoder.
func stageRecipes(existing: URL, batch: URL, output: URL) throws {
    let decoder = JSONDecoder()
    var ids = Set<String>()
    var appIDs = Set<Int>()
    for url in try FileManager.default.contentsOfDirectory(at: existing, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" {
        let recipe = try decoder.decode(Recipe.self, from: Data(contentsOf: url))
        try recipe.validate()
        ids.insert(recipe.id)
        ids.insert(url.deletingPathExtension().lastPathComponent)
        if let appID = recipe.steamAppID { appIDs.insert(appID) }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: batch)) as? [[String: Any]] else {
        throw GamePortError.invalid("expected an array of game recipes")
    }
    for entry in entries {
        guard let id = entry["id"] as? String, let appID = entry["steamAppID"] as? Int,
              let source = entry["source"] as? String else { throw GamePortError.invalid("missing game identity") }
        if ids.contains(id) || ids.contains("hbdb-" + id) || appIDs.contains(appID) { continue }
        let data = try JSONSerialization.data(withJSONObject: entry)
        var recipe = try HighballDBImporter.convert(data, steamAppIDs: [id: appID])
        recipe.status = .community
        recipe.source = source
        try recipe.validate()
        let json = try encoder.encode(recipe) + Data("\n".utf8)
        try json.write(to: output.appendingPathComponent(recipe.id + ".json"), options: .withoutOverwriting)
        ids.insert(recipe.id)
        appIDs.insert(appID)
    }
}

do {
    let args = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
    guard args.count == 3 else { throw GamePortError.invalid("expected existing-directory, batch, staging-directory") }
    try stageRecipes(existing: args[0], batch: args[1], output: args[2])
} catch {
    FileHandle.standardError.write(Data("recipe import failed: \(error)\n".utf8))
    exit(1)
}
