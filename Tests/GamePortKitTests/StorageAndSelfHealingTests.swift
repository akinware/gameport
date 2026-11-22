import XCTest
@testable import GamePortKit

final class StorageAndSelfHealingTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gameport-sh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func testStoragePreferenceRoundTripAndEnvOverride() throws {
        let prefFile = temp.appendingPathComponent("storage.json")
        let customDir = temp.appendingPathComponent("ExternalSSD/GamePort")
        let info = try StorageInfo.setCustomRoot(customDir, preferenceFile: prefFile)
        XCTAssertTrue(info.isCustom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customDir.path))

        // Saved custom root is picked up when GAMEPORT_HOME is unset
        let resolved = Paths.default(environment: [:], preferenceFile: prefFile)
        XCTAssertEqual(resolved.root.standardizedFileURL.path, customDir.standardizedFileURL.path)

        // GAMEPORT_HOME always overrides saved storage.json
        let envDir = temp.appendingPathComponent("EnvOverride")
        let envResolved = Paths.default(environment: [Brand.homeEnvironmentVariable: envDir.path], preferenceFile: prefFile)
        XCTAssertEqual(envResolved.root.standardizedFileURL.path, envDir.standardizedFileURL.path)

        _ = try StorageInfo.resetToDefault(preferenceFile: prefFile)
        XCTAssertNil(StoragePreference.load(from: prefFile).customRoot)
    }

    func testSelfHealingDiagnosesCommonFailuresAndAppliesRecovery() throws {
        var profile = Profile(id: "skyrim-se", title: "Skyrim SE", recipeID: "skyrim-se", engineID: "e1")
        profile.renderer = .dxvk
        profile.vulkanDriver = .kosmickrisp

        // 1. KosmicKrisp + DXVK pipeline-statistics crash suggests MoltenVK + DXMT + snapshot rollback
        let snap = Snapshot(name: "auto-2026-11-22", engineID: "e1", createdAt: Date())
        let diag = SelfHealing.diagnose(
            profile: profile,
            recipe: nil,
            crashSigns: ["Unhandled exception", "DXVK pipeline-statistics query unsupported"],
            logText: "kosmickrisp-shim: VK_ERROR_FEATURE_NOT_PRESENT vkResetQueryPoolEXT",
            snapshots: [snap],
            hasD3DMetalLicense: true
        )
        XCTAssertTrue(diag.actions.contains(where: { $0.kind == .switchVulkan(.moltenvk) }))
        XCTAssertTrue(diag.actions.contains(where: { $0.kind == .switchRenderer(.dxmt) }))
        XCTAssertTrue(diag.actions.contains(where: { $0.kind == .restoreSnapshot("auto-2026-11-22") }))

        // 2. Illegal instruction suggests enabling AVX
        var avxProfile = Profile(id: "hogwarts-legacy", title: "Hogwarts Legacy", recipeID: "hogwarts-legacy", engineID: "e1")
        avxProfile.renderer = .d3dmetal
        let avxDiag = SelfHealing.diagnose(
            profile: avxProfile,
            recipe: nil,
            crashSigns: ["Unhandled exception"],
            logText: "Unhandled exception 0xc000001d illegal instruction AVX required"
        )
        XCTAssertTrue(avxDiag.actions.contains(where: { $0.kind == .enableAVX }))

        // 3. applyRecovery mutates and persists the profile cleanly
        let gp = GamePort(paths: Paths(root: temp))
        try gp.profiles.save(profile)
        _ = try gp.applyRecovery(.switchVulkan(.moltenvk), to: "skyrim-se")
        _ = try gp.applyRecovery(.switchRenderer(.dxmt), to: "skyrim-se")
        _ = try gp.applyRecovery(.enableAVX, to: "skyrim-se")
        let saved = try gp.profiles.load("skyrim-se")
        XCTAssertNil(saved.vulkanDriver)
        XCTAssertEqual(saved.renderer, .dxmt)
        XCTAssertEqual(saved.environment["ROSETTA_ADVERTISE_AVX"], "1")
    }

    func testEngineCatalogDefaultSelectionAndSafeRemoval() throws {
        let gp = GamePort(paths: Paths(root: temp))
        // Before any install, bundled manifest appears in catalog as not installed.
        let initial = gp.engineCatalog()
        XCTAssertFalse(initial.isEmpty)
        XCTAssertTrue(initial.allSatisfy { $0.isBundled && !$0.isInstalled && !$0.isDefault })
        XCTAssertGreaterThan(initial[0].manifest.totalDownloadSize, 0)

        // Create two fake installed engines (one custom, one second custom)
        func installFake(_ id: String) throws {
            let root = gp.paths.engine(id)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let m = EngineManifest(
                schema: 1,
                id: id,
                displayName: "Engine \(id)",
                arch: .rosetta,
                fexModules: nil,
                supportsKosmicKrisp: false,
                minMacOS: "14.0",
                wineLoader: "engine/bin/wine",
                wineServer: "engine/bin/wineserver",
                components: [
                    .init(name: "a", kind: "engine", url: "https://example.com/a.tar.xz",
                          sha256: String(repeating: "a", count: 64), size: 100, license: "LGPL"),
                    .init(name: "b", kind: "renderer", url: "https://example.com/a.tar.xz",
                          sha256: String(repeating: "a", count: 64), size: 100, license: "LGPL"),
                    .init(name: "c", kind: "tool", url: "https://example.com/c.sh",
                          sha256: String(repeating: "b", count: 64), size: 50, license: "LGPL"),
                ],
                baseEnvironment: [:],
                licenses: [:],
                notes: []
            )
            XCTAssertEqual(m.totalDownloadSize, 150) // dedupes identical sha256
            let data = try JSONEncoder().encode(m)
            try data.write(to: root.appendingPathComponent("gameport-engine.json"))
        }

        try installFake("custom-one")
        try installFake("custom-two")
        try gp.engines.setDefaultEngine("custom-two")
        XCTAssertEqual(gp.engines.defaultEngineID(), "custom-two")

        // Attach a profile to custom-two -> removal must fail while referenced
        let p = Profile(id: "tf2", title: "TF2", recipeID: "team-fortress-2", engineID: "custom-two")
        try gp.profiles.save(p)

        let catalog = gp.engineCatalog()
        let row2 = try XCTUnwrap(catalog.first(where: { $0.id == "custom-two" }))
        XCTAssertTrue(row2.isInstalled)
        XCTAssertTrue(row2.isDefault)
        XCTAssertEqual(row2.profilesUsingCount, 1)

        XCTAssertThrowsError(try gp.removeEngine("custom-two"))
        XCTAssertNoThrow(try gp.removeEngine("custom-one"))
        XCTAssertNil(gp.engineCatalog().first(where: { $0.id == "custom-one" }))
    }
}
