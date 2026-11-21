import XCTest
@testable import GamePortKit

final class ImportedCatalogTests: XCTestCase {
    func testSidebarFiltersTheBundledCommunityCatalog() throws {
        let recipes = RecipeCatalog.bundled()
        XCTAssertEqual(recipes.count, BundledData.recipes.count)
        let catalog = RecipeCatalog(recipes: recipes)
        XCTAssertEqual(catalog.recipes.count, recipes.count)
        let community = recipes.filter { $0.id.hasPrefix("hbdb-") }
        XCTAssertEqual(community.count, 774, "Review the imported catalog size when updating the pin")
        XCTAssertTrue(community.allSatisfy { $0.status == .community && $0.steamAppID != nil })
        XCTAssertEqual(Set(community.compactMap(\.steamAppID)).count, community.count)
        XCTAssertEqual(catalog.recipe(steamAppID: 1245620)?.id, "elden-ring")

        var filter = RecipeFilter()
        filter.renderer = .dxvk
        filter.status = .community
        for query in ["pORtal 620", "hbdb-portal-2", "620"] {
            filter.query = query
            XCTAssertEqual(filter.apply(to: catalog.sorted).map(\.id), ["hbdb-portal-2"])
        }
        filter.status = .verified
        XCTAssertTrue(filter.apply(to: catalog.sorted).isEmpty)
    }
}
