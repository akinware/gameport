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

    func testBundledWineStagingManifestAndPrefixRendererStagerRoundTrip() throws {
        let gp = GamePort(paths: Paths(root: temp))
        let bundled = EngineStore.bundledManifests()
        XCTAssertEqual(bundled.first?.id, "x64-crossover26.3-hb20261014")
        let staging = try XCTUnwrap(EngineStore.bundledManifest(id: "x64-wine-staging-11.21"))
        XCTAssertEqual(staging.effectiveOverlayMode, .prefix)
        XCTAssertGreaterThan(staging.totalDownloadSize, 300_000_000)

        // Helper: fake PE with "Wine builtin DLL" marker at offset 0x40 and pe_offset = 0x80
        func fakeBuiltinPE(_ tag: String) -> Data {
            var d = Data(repeating: 0, count: 0x90)
            d[0] = 0x4D; d[1] = 0x5A // MZ
            d[0x3C] = 0x80           // pe_offset = 0x80
            let mark = Data("Wine builtin DLL".utf8)
            d.replaceSubrange(0x40..<(0x40 + mark.count), with: mark)
            let tagData = Data(tag.utf8)
            d.replaceSubrange(0x80..<(0x80 + min(tagData.count, 16)), with: tagData.prefix(16))
            return d
        }

        // Build a fake .prefix engine with dxmt (pure PE d3d11 + unix-backed winemetal) + dxvk
        let engineRoot = gp.paths.engine("prefix-test")
        let fm = FileManager.default
        let dxmt64 = engineRoot.appendingPathComponent("renderers/dxmt/wine/x86_64-windows")
        let dxmt32 = engineRoot.appendingPathComponent("renderers/dxmt/wine/i386-windows")
        let dxmtUnix = engineRoot.appendingPathComponent("renderers/dxmt/wine/x86_64-unix")
        let dxvk64 = engineRoot.appendingPathComponent("frameworks/renderer/dxvk/wine/x86_64-windows")
        try fm.createDirectory(at: dxmt64, withIntermediateDirectories: true)
        try fm.createDirectory(at: dxmt32, withIntermediateDirectories: true)
        try fm.createDirectory(at: dxmtUnix, withIntermediateDirectories: true)
        try fm.createDirectory(at: dxvk64, withIntermediateDirectories: true)

        let dxmtD3D11 = fakeBuiltinPE("dxmt-d3d11-64")
        let dxmtWinemetal = fakeBuiltinPE("dxmt-winemetal")
        try dxmtD3D11.write(to: dxmt64.appendingPathComponent("d3d11.dll"))
        try dxmtWinemetal.write(to: dxmt64.appendingPathComponent("winemetal.dll"))
        try Data("unix-so".utf8).write(to: dxmtUnix.appendingPathComponent("winemetal.so"))
        try Data("disabled".utf8).write(to: dxmt64.appendingPathComponent("_d3d12.dll"))
        try fakeBuiltinPE("dxmt-d3d11-32").write(to: dxmt32.appendingPathComponent("d3d11.dll"))
        try fakeBuiltinPE("dxvk-d3d11-64").write(to: dxvk64.appendingPathComponent("d3d11.dll"))

        let manifest = EngineManifest(
            schema: 1, id: "prefix-test", displayName: "Prefix Test", arch: .rosetta,
            fexModules: nil, overlayMode: .prefix, supportsKosmicKrisp: false,
            minMacOS: "14.0", wineLoader: "engine/bin/wine", wineServer: "engine/bin/wineserver",
            components: [], baseEnvironment: [:], licenses: [:], notes: []
        )
        let engine = InstalledEngine(manifest: manifest, root: engineRoot)

        // Verify env uses WINEDLLPATH+ (not WINEDLLPATH_PREPEND) and D3DMetal is rejected cleanly
        let env = try Renderer.dxmt.environment(engine: engine)
        XCTAssertNil(env["WINEDLLPATH_PREPEND"])
        XCTAssertNotNil(env["WINEDLLPATH+"])
        XCTAssertThrowsError(try Renderer.d3dmetal.environment(engine: engine))

        // Prepare fake prefix with Wine stub DLLs
        let prefix = temp.appendingPathComponent("prefix")
        let sys32 = prefix.appendingPathComponent("drive_c/windows/system32")
        let syswow = prefix.appendingPathComponent("drive_c/windows/syswow64")
        try fm.createDirectory(at: sys32, withIntermediateDirectories: true)
        try fm.createDirectory(at: syswow, withIntermediateDirectories: true)
        try Data("wine-stub-64".utf8).write(to: sys32.appendingPathComponent("d3d11.dll"))
        try Data("wine-stub-32".utf8).write(to: syswow.appendingPathComponent("d3d11.dll"))

        // 1. Stage DXMT: pure PE d3d11 has builtin marker stripped; winemetal stays symlinked with marker intact
        try RendererStager.sync(renderer: .dxmt, engine: engine, prefix: prefix)
        let stagedD3D11 = try Data(contentsOf: sys32.appendingPathComponent("d3d11.dll"))
        XCTAssertEqual(stagedD3D11[0x40..<0x50], Data(repeating: 0, count: 16))
        XCTAssertEqual(try Data(contentsOf: dxmt64.appendingPathComponent("d3d11.dll"))[0x40..<0x50], Data("Wine builtin DLL".utf8)) // engine untouched!
        let wmAttrs = try fm.attributesOfItem(atPath: sys32.appendingPathComponent("winemetal.dll").path)
        XCTAssertEqual(wmAttrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try Data(contentsOf: sys32.appendingPathComponent("winemetal.dll"))[0x40..<0x50], Data("Wine builtin DLL".utf8))
        XCTAssertFalse(fm.fileExists(atPath: sys32.appendingPathComponent("_d3d12.dll").path))
        XCTAssertTrue(fm.fileExists(atPath: sys32.appendingPathComponent("d3d11.dll.gameport-orig").path))

        // 2. Switch to DXVK -> winemetal removed, 64-bit becomes DXVK (marker stripped), 32-bit restores Wine stub
        try RendererStager.sync(renderer: .dxvk, engine: engine, prefix: prefix)
        XCTAssertFalse(fm.fileExists(atPath: sys32.appendingPathComponent("winemetal.dll").path))
        let stagedDXVK = try Data(contentsOf: sys32.appendingPathComponent("d3d11.dll"))
        XCTAssertEqual(stagedDXVK[0x40..<0x50], Data(repeating: 0, count: 16))
        XCTAssertEqual(try Data(contentsOf: syswow.appendingPathComponent("d3d11.dll")), Data("wine-stub-32".utf8))

        // 3. Switch to WineD3D -> both stubs restored cleanly and tracking file removed
        try RendererStager.sync(renderer: .wined3d, engine: engine, prefix: prefix)
        XCTAssertEqual(try Data(contentsOf: sys32.appendingPathComponent("d3d11.dll")), Data("wine-stub-64".utf8))
        XCTAssertEqual(try Data(contentsOf: syswow.appendingPathComponent("d3d11.dll")), Data("wine-stub-32".utf8))
        XCTAssertFalse(fm.fileExists(atPath: sys32.appendingPathComponent("d3d11.dll.gameport-orig").path))
        XCTAssertFalse(fm.fileExists(atPath: prefix.appendingPathComponent(".gameport-staged-dlls.json").path))
    }
}
