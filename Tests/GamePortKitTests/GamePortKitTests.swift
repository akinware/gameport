import XCTest
@testable import GamePortKit

final class GamePortKitTests: XCTestCase {
    var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("gameport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    func testSHA256KnownVectors() throws {
        XCTAssertEqual(Checksum.sha256(data: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Checksum.sha256(data: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data(String(repeating: "a", count: 1_000_000).utf8)
        XCTAssertEqual(Checksum.sha256(data: long), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        let file = temp.appendingPathComponent("f")
        try long.write(to: file)
        XCTAssertEqual(try Checksum.sha256(file: file), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        XCTAssertThrowsError(try Checksum.verify(file: file, sha256: String(repeating: "0", count: 64)))
    }

    func testBundledEngineManifestIsValid() throws {
        let manifests = EngineStore.bundledManifests()
        XCTAssertEqual(manifests.count, 1)
        let m = try XCTUnwrap(manifests.first)
        XCTAssertTrue(m.requiresRosetta)
        XCTAssertEqual(m.licenses["apple-gptk"]?.gatesRenderers, ["d3dmetal"])
        XCTAssertEqual(Renderer.d3dmetal.gatingLicense(in: m), "apple-gptk")
        XCTAssertNil(Renderer.dxmt.gatingLicense(in: m))
        XCTAssertTrue(m.components.contains { $0.kind == "engine" })
    }

    func testAllBundledRecipesDecodeAndValidate() throws {
        XCTAssertEqual(BundledData.recipes.count, RecipeCatalog.bundled().count, "a bundled recipe failed to decode or validate")
        let catalog = RecipeCatalog(recipes: RecipeCatalog.bundled())
        XCTAssertEqual(catalog["elden-ring"]?.steamAppID, 1245620)
        XCTAssertEqual(catalog.recipe(steamAppID: 730)?.id, "counter-strike-2")
        XCTAssertEqual(catalog["steam"]?.sync, SyncMode.none)
    }

    func testOptionalWineDefaultsUseNoClobberFlagsAndKeepRecipeScope() throws {
        let controller = ConfigPatcher.WineDefault.controller
        let display = ConfigPatcher.WineDefault.openGL
        XCTAssertEqual(try controller.registry.map { try ConfigPatcher.registryLine($0, preset: controller) }, [
            #"HKLM,"System\CurrentControlSet\Services\winebus","Enable SDL",0x00010003,1"#,
            #"HKLM,"System\CurrentControlSet\Services\winebus","DisableHidraw",0x00010003,1"#
        ])
        let gl = try XCTUnwrap(display.registry.first)
        XCTAssertEqual(try ConfigPatcher.registryLine(gl, preset: display),
                       #"HKCU,"Software\Wine\Mac Driver","CaptureDisplaysForFullscreen",0x00000002,"n""#)
        XCTAssertThrowsError(try ConfigPatcher.Defaults(ini: nil, registry: controller.registry).validate())
        XCTAssertThrowsError(try ConfigPatcher.registryLine(gl, preset: controller))
        var modified = gl
        modified.name = "Other"
        XCTAssertThrowsError(try ConfigPatcher.registryLine(modified, preset: display))
    }

    func testWineDefaultsAreExplicitAndConfinedToOneProfile() throws {
        let kit = GamePort(paths: Paths(root: temp))
        let manifest = try XCTUnwrap(kit.defaultManifest)
        let engine = InstalledEngine(manifest: manifest, root: kit.paths.engine(manifest.id))
        func installStub(_ url: URL, _ script: String) throws {
            try kit.paths.ensure(url.deletingLastPathComponent())
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try installStub(engine.wineServer, "exit 0")
        try installStub(engine.wine, #"""
        case "$1" in
          rundll32.exe) cp "$WINEPREFIX"/drive_c/gameport-*.inf "$WINEPREFIX/applied.inf" ;;
          reg) [ "$2" = query ] ;;
          *) exit 1 ;;
        esac
        """#)
        try JSONEncoder().encode(manifest).write(to: engine.root.appendingPathComponent(EngineStore.receiptName))
        for id in ["first", "second"] {
            var profile = Profile(id: id, title: id, recipeID: nil, engineID: engine.id)
            profile.renderer = .wined3d
            try kit.profiles.save(profile)
            let runner = try kit.runner(for: id)
            try kit.paths.ensure(runner.prefix.appendingPathComponent("drive_c"))
            try runner.settle()
        }
        let first = kit.profiles.prefix("first").appendingPathComponent("applied.inf")
        let second = kit.profiles.prefix("second").appendingPathComponent("applied.inf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        try kit.applyWineDefault(.controller, to: "first")
        let original = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(original.contains("DisableHidraw"))
        XCTAssertFalse(original.contains("CaptureDisplaysForFullscreen"))
        try kit.applyWineDefault(.controller, to: "first")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().appendingPathComponent("drive_c").path)
        XCTAssertTrue(files.isEmpty)
        try installStub(engine.wineServer, "exit 1")
        XCTAssertThrowsError(try kit.applyWineDefault(.openGL, to: "first"))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), original)
    }

    func testIDValidationRejectsTraversal() {
        XCTAssertThrowsError(try validateID("..", what: "x"))
        XCTAssertThrowsError(try validateID("a/b", what: "x"))
        XCTAssertThrowsError(try validateID("", what: "x"))
        XCTAssertNoThrow(try validateID("elden-ring_2.0", what: "x"))
        XCTAssertThrowsError(try Archive.safeSubpath("../etc"))
        XCTAssertThrowsError(try Archive.safeSubpath("/abs"))
        XCTAssertEqual(try Archive.safeSubpath("engine/"), "engine")
    }

    func testEnvironmentMergeAppendsOverridesAndPaths() {
        let base = ["WINEDLLOVERRIDES": "winemenubuilder.exe=d", "DYLD_FALLBACK_LIBRARY_PATH": "/a", "X": "1"]
        let merged = mergeEnvironment(base, ["WINEDLLOVERRIDES": "dxgi=n,b", "DYLD_FALLBACK_LIBRARY_PATH+": "/b", "X": "2"])
        XCTAssertEqual(merged["WINEDLLOVERRIDES"], "winemenubuilder.exe=d;dxgi=n,b")
        XCTAssertEqual(merged["DYLD_FALLBACK_LIBRARY_PATH"], "/a:/b")
        XCTAssertEqual(merged["X"], "2")
    }

    func fakeEngine(renderers: [String]) throws -> InstalledEngine {
        let m = try XCTUnwrap(EngineStore.bundledManifests().first)
        let root = temp.appendingPathComponent("engine-\(UUID().uuidString)")
        for r in renderers {
            let sub = r == "dxmt" ? "renderers/dxmt/wine" : (r == "d3dmetal" ? "frameworks/renderer/d3dmetal/external" : "frameworks/renderer/\(r)/wine")
            try FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
            if r == "d3dmetal" { try FileManager.default.createDirectory(at: root.appendingPathComponent("frameworks/renderer/d3dmetal/wine"), withIntermediateDirectories: true) }
        }
        return InstalledEngine(manifest: m, root: root)
    }

    func testRendererEnvironments() throws {
        let engine = try fakeEngine(renderers: ["dxmt", "d3dmetal", "dxvk"])
        let dxmt = try Renderer.dxmt.environment(engine: engine)
        XCTAssertTrue(dxmt["WINEDLLPATH_PREPEND"]!.hasSuffix("renderers/dxmt/wine"))
        XCTAssertEqual(dxmt["WINEDLLOVERRIDES"], "dxgi,d3d11,d3d10core=n,b")
        let d3dm = try Renderer.d3dmetal.environment(engine: engine)
        let overlays = d3dm["WINEDLLPATH_PREPEND"]!.split(separator: ":")
        XCTAssertEqual(overlays.count, 2, "D3DMetal first, DXMT behind it for 32-bit D3D11")
        XCTAssertTrue(overlays[0].hasSuffix("renderer/d3dmetal/wine"))
        XCTAssertTrue(d3dm["CX_D3DMETALPATH"]!.hasSuffix("d3dmetal/external"))
        XCTAssertTrue(d3dm["WINEDLLOVERRIDES"]!.contains("d3d12"))
        XCTAssertTrue(try Renderer.wined3d.environment(engine: engine).isEmpty)
        let none = try fakeEngine(renderers: [])
        XCTAssertThrowsError(try Renderer.dxvk.environment(engine: none))
    }

    func testRunnerEnvironmentLayersAndLicenseGate() throws {
        let paths = Paths(root: temp.appendingPathComponent("home"))
        let engine = try fakeEngine(renderers: ["dxmt", "d3dmetal"])
        let recipe = Recipe(id: "g", title: "G", steamAppID: 1, renderer: .d3dmetal, sync: .msync, advertiseAVX: true,
                            environment: ["FOO": "bar"], dllOverrides: "amd_ags_x64=")
        var profile = Profile(id: "g", title: "G", recipeID: "g", engineID: engine.id)
        let runner = WineRunner(paths: paths, engine: engine, profile: profile, recipe: recipe)
        XCTAssertThrowsError(try runner.environment()) { XCTAssertEqual($0 as? GamePortError, .licenseNotAccepted("apple-gptk")) }
        try LicenseStore(paths: paths).accept("apple-gptk")
        let env = try runner.environment()
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertEqual(env["FOO"], "bar")
        XCTAssertTrue(env["WINEDLLOVERRIDES"]!.hasPrefix("winemenubuilder.exe=d;"))
        XCTAssertTrue(env["WINEDLLOVERRIDES"]!.hasSuffix(";amd_ags_x64="))
        XCTAssertEqual(env["WINEPREFIX"], paths.profile("g").appendingPathComponent("prefix").path)
        XCTAssertTrue(env["HOME"]!.hasPrefix(paths.profile("g").path), "HOME is private to the profile")
        XCTAssertTrue(env["DYLD_FALLBACK_LIBRARY_PATH"]!.contains("d3dmetal/external"))
        // Steam's own session: sync forced off regardless of the recipe.
        XCTAssertEqual(try runner.environment(sync: SyncMode.none)["WINEMSYNC"], "0")
        // Player override beats the recipe.
        profile.renderer = .dxmt
        profile.sync = SyncMode.none
        let env2 = try WineRunner(paths: paths, engine: engine, profile: profile, recipe: recipe).environment()
        XCTAssertNil(env2["CX_D3DMETALPATH"])
        XCTAssertEqual(env2["WINEESYNC"], "0")
    }

    func testKosmicKrispDriverEnvironment() throws {
        let paths = Paths(root: temp.appendingPathComponent("home-kk"))
        let engine = try fakeEngine(renderers: ["dxmt"])
        var profile = Profile(id: "g", title: "G", recipeID: nil, engineID: engine.id)
        XCTAssertNil(try WineRunner(paths: paths, engine: engine, profile: profile, recipe: nil).environment()["CX_LIBVULKAN"])
        profile.vulkanDriver = .kosmickrisp
        XCTAssertThrowsError(try WineRunner(paths: paths, engine: engine, profile: profile, recipe: nil).environment(),
                             "KosmicKrisp chosen but not installed")
        let kk = engine.root.appendingPathComponent("renderers/kosmickrisp")
        try FileManager.default.createDirectory(at: kk, withIntermediateDirectories: true)
        for f in ["libMoltenVK.dylib", "libMoltenVK-engine.dylib", "libvulkan_kosmickrisp.dylib"] {
            FileManager.default.createFile(atPath: kk.appendingPathComponent(f).path, contents: Data())
        }
        let env = try WineRunner(paths: paths, engine: engine, profile: profile, recipe: nil).environment()
        XCTAssertEqual(env["CX_LIBVULKAN"], kk.appendingPathComponent("libMoltenVK.dylib").path)
        XCTAssertEqual(env["CX_ACTIVE_GRAPHICS_BACKEND"], "wined3d")

        var r = LabResult(profileID: "g", recipeID: "g", renderer: .dxmt, sync: .msync, engineID: "e", macOS: "27", machine: "M1",
                          startedAt: Date(), seconds: 150, verdict: .notVisible, steady: nil, whole: nil, hudLog: "x")
        XCTAssertTrue(r.summary.hasPrefix("dxmt: "))
        r.vulkanDriver = .kosmickrisp
        XCTAssertTrue(r.summary.hasPrefix("dxmt + KosmicKrisp: "))
    }

    func testProfileAndLicenseStores() throws {
        let paths = Paths(root: temp)
        let store = ProfileStore(paths: paths)
        let p = Profile(id: "elden-ring", title: "Elden Ring", recipeID: "elden-ring", engineID: "e")
        try store.save(p)
        XCTAssertEqual(try store.load("elden-ring").title, "Elden Ring")
        XCTAssertEqual(store.all().map(\.id), ["elden-ring"])
        XCTAssertThrowsError(try store.load("../x"))
        let licenses = LicenseStore(paths: paths)
        XCTAssertFalse(licenses.isAccepted("apple-gptk"))
        try licenses.accept("apple-gptk")
        XCTAssertTrue(licenses.isAccepted("apple-gptk"))
        try licenses.revoke("apple-gptk")
        XCTAssertFalse(licenses.isAccepted("apple-gptk"))
    }

    func testEngineComponentPlacementFromArchive() throws {
        // Build a tiny archive shaped like the real engine tarball (./engine/bin/wine).
        let src = temp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("engine/bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: src.appendingPathComponent("engine/bin/wine"))
        let archive = temp.appendingPathComponent("e.tar.gz")
        try Shell.run("/usr/bin/tar", ["-czf", archive.path, "-C", src.path, "."])
        let paths = Paths(root: temp.appendingPathComponent("k"))
        let store = EngineStore(paths: paths)
        let root = temp.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let c = EngineManifest.Component(name: "wine", kind: "engine", url: "https://x", sha256: String(repeating: "a", count: 64),
                                         size: nil, license: "LGPL", note: nil, extract: .init(subpath: "engine", into: "engine"),
                                         place: nil, executable: nil, order: 0)
        try store.place(c, file: archive, engineRoot: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("engine/bin/wine").path))
        // A plain file component lands at `place`, executable.
        let tool = EngineManifest.Component(name: "winetricks", kind: "tool", url: "https://x", sha256: String(repeating: "a", count: 64),
                                            size: nil, license: "LGPL", note: nil, extract: nil, place: "tools/winetricks", executable: true, order: 2)
        try store.place(tool, file: src.appendingPathComponent("engine/bin/wine"), engineRoot: root)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("tools/winetricks").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testHighballDBImporter() throws {
        let json = """
        {"id":"hogwarts-legacy","kind":"game","title":"Hogwarts Legacy","requires":["steam"],"renderer":"d3dmetal",
         "steps":[{"type":"renderer","renderer":"d3dmetal"},{"type":"environment","name":"ROSETTA_ADVERTISE_AVX","value":"1"},
                  {"type":"registry","key":"HKCU\\\\Software\\\\Wine\\\\AppDefaults\\\\x.exe\\\\X11 Driver","name":"EmulateModeset","valueType":"REG_SZ","data":"y"},
                  {"type":"winetricks","verb":"vcrun2022"},{"type":"note","text":"DX12 only"}],
         "knownIssues":[{"symptom":"crash","cause":"c","fix":"f"}],"lastVerified":null}
        """
        let r = try HighballDBImporter.convert(Data(json.utf8), steamAppIDs: ["hogwarts-legacy": 990080])
        XCTAssertEqual(r.id, "hbdb-hogwarts-legacy")
        XCTAssertEqual(r.renderer, .d3dmetal)
        XCTAssertTrue(r.advertiseAVX)
        XCTAssertNil(r.environment["ROSETTA_ADVERTISE_AVX"])
        XCTAssertEqual(r.registry.first?.name, "EmulateModeset")
        XCTAssertEqual(r.steamAppID, 990080)
        XCTAssertTrue(r.notes.contains { $0.contains("winetricks") }, "unimplemented steps are kept as notes")
        XCTAssertEqual(r.status, .untested)
    }

    /// A prefix-shaped tree: a file, a nested file, Wine's C: link and a host-volume link.
    func fakePrefix(at prefix: URL, marker: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: prefix.appendingPathComponent("user.reg"))
        try Data(marker.utf8).write(to: prefix.appendingPathComponent("drive_c/users/save.dat"))
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/d:").path, withDestinationPath: "/Volumes")
    }

    func testCopyOnWriteCloneAndReplace() throws {
        let src = temp.appendingPathComponent("src"), dst = temp.appendingPathComponent("a/b/dst")
        try fakePrefix(at: src, marker: "one")
        try CopyOnWrite.clone(src, to: dst)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("drive_c/users/save.dat"), encoding: .utf8), "one")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("dosdevices/c:").path), "../drive_c",
                       "links are cloned as links, not followed")
        XCTAssertThrowsError(try CopyOnWrite.clone(src, to: dst), "never clones over an existing tree")
        // Writing to the clone leaves the original alone.
        try Data("two".utf8).write(to: dst.appendingPathComponent("user.reg"))
        XCTAssertEqual(try String(contentsOf: src.appendingPathComponent("user.reg"), encoding: .utf8), "one")
        try CopyOnWrite.replace(dst, withCloneOf: src)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("user.reg"), encoding: .utf8), "one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path), ["dst"], "no .new/.old left behind")
    }

    func testSnapshotsRoundTrip() throws {
        let paths = Paths(root: temp)
        let store = ProfileStore(paths: paths)
        try store.save(Profile(id: "g", title: "G", recipeID: nil, engineID: "engine-a"))
        try fakePrefix(at: store.prefix("g"), marker: "before")
        let first = try store.createSnapshot("g", name: "before-update", now: Date(timeIntervalSince1970: 1_000))
        XCTAssertThrowsError(try store.createSnapshot("g", name: "before-update"), "names are unique")
        XCTAssertThrowsError(try store.createSnapshot("g", name: "../escape"))
        let auto = try store.createSnapshot("g", now: Date(timeIntervalSince1970: 2_000))
        XCTAssertFalse(auto.name.contains(":"), "default name is a safe folder name")
        XCTAssertEqual(store.listSnapshots("g").map(\.name), [auto.name, "before-update"], "newest first")

        // An update breaks the prefix and moves the profile to another engine; restore undoes both.
        try Data("broken".utf8).write(to: store.prefix("g").appendingPathComponent("user.reg"))
        try FileManager.default.removeItem(at: store.prefix("g").appendingPathComponent("drive_c/users/save.dat"))
        var moved = try store.load("g"); moved.engineID = "engine-b"; try store.save(moved)
        XCTAssertEqual(try store.restoreSnapshot("g", name: first.name), first)
        XCTAssertEqual(try String(contentsOf: store.prefix("g").appendingPathComponent("user.reg"), encoding: .utf8), "before")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.prefix("g").appendingPathComponent("drive_c/users/save.dat").path))
        XCTAssertEqual(try store.load("g").engineID, "engine-a")
        XCTAssertEqual(store.listSnapshots("g").count, 2, "restoring keeps the snapshot")
        try store.deleteSnapshot("g", name: auto.name)
        XCTAssertEqual(store.listSnapshots("g").map(\.name), ["before-update"])
        XCTAssertThrowsError(try store.restoreSnapshot("g", name: auto.name))
    }

    func testIsolationKeepsOnlyDriveC() throws {
        let paths = Paths(root: temp)
        let engine = try fakeEngine(renderers: ["dxmt"])
        let runner = WineRunner(paths: paths, engine: engine, profile: Profile(id: "g", title: "G", recipeID: nil, engineID: engine.id), recipe: nil)
        try fakePrefix(at: runner.prefix, marker: "x")
        try FileManager.default.createSymbolicLink(atPath: runner.prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try FileManager.default.createSymbolicLink(atPath: runner.prefix.appendingPathComponent("dosdevices/d::").path, withDestinationPath: "/dev/rdisk9")
        try runner.isolateHostDrives()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runner.prefix.appendingPathComponent("dosdevices").path), ["c:"])
    }

    func testSteamBaseIsOnlyClonedWhenComplete() throws {
        let paths = Paths(root: temp)
        let engine = try fakeEngine(renderers: ["dxmt"])
        let base = SteamBase(paths: paths, engine: engine)
        XCTAssertEqual(base.directory, paths.base(engine.id))
        XCTAssertEqual(try base.runner.environment()["WINEPREFIX"], base.prefix.path, "the base runs in its own folder, not a profile's")
        try fakePrefix(at: base.prefix, marker: "base")
        XCTAssertFalse(base.isReady, "no stamp yet: Steam's first update has not finished")
        XCTAssertThrowsError(try base.clone(to: temp.appendingPathComponent("p")))
        XCTAssertFalse(base.steamUpdated)
        let steam = base.steamDirectory
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("package"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("bin/cef/cef.win64"), withIntermediateDirectories: true)
        try Data().write(to: steam.appendingPathComponent("package/steam_client_win64.installed"))
        try Data().write(to: steam.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe"))
        XCTAssertTrue(base.steamUpdated)
        try FileManager.default.createDirectory(at: steam.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("[2026-10-30 00:21:24] Downloading update (8,305 of 336,229 KB)...\n".utf8).write(to: steam.appendingPathComponent("logs/bootstrap_log.txt"))
        XCTAssertEqual(base.updateStatus(), "Downloading update (8,305 of 336,229 KB)...")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(SteamBase.Stamp(engineID: engine.id, builtAt: Date())).write(to: base.stampFile)
        XCTAssertTrue(base.isReady)
        let target = ProfileStore(paths: paths).prefix("g")
        try base.clone(to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("user.reg"), encoding: .utf8), "base")
    }

    func testAutomaticSnapshotsAreDailyAndPruned() throws {
        let store = ProfileStore(paths: Paths(root: temp))
        try store.save(Profile(id: "g", title: "G", recipeID: nil, engineID: "e"))
        try fakePrefix(at: store.prefix("g"), marker: "x")
        let day: TimeInterval = 24 * 3600
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.autoSnapshotDue("g", now: t0))
        try store.createSnapshot("g", name: "mine", now: t0)
        XCTAssertTrue(store.autoSnapshotDue("g", now: t0), "the player's own snapshots do not count")
        for i in 0..<3 {
            let t = t0.addingTimeInterval(Double(i) * day)
            try store.createSnapshot("g", name: ProfileStore.autoPrefix + ProfileStore.snapshotName(t), now: t)
        }
        XCTAssertFalse(store.autoSnapshotDue("g", now: t0.addingTimeInterval(2.5 * day)))
        XCTAssertTrue(store.autoSnapshotDue("g", now: t0.addingTimeInterval(3 * day)))
        try store.pruneAutoSnapshots("g", keep: 2)
        let names = store.listSnapshots("g").map(\.name)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("mine"), "pruning never touches the player's snapshots")
        XCTAssertFalse(names.contains(ProfileStore.autoPrefix + ProfileStore.snapshotName(t0)), "the oldest automatic one goes first")
    }

    func testProfilesWrittenBeforeAutoSnapshotsStillLoad() throws {
        let paths = Paths(root: temp)
        try paths.ensure(paths.profile("old"))
        let json = #"{"schema":1,"id":"old","title":"Old","engineID":"e","metalHUD":false,"environment":{},"createdAt":"2026-10-29T10:00:00Z"}"#
        try Data(json.utf8).write(to: paths.profile("old").appendingPathComponent("profile.json"))
        XCTAssertNil(try ProfileStore(paths: paths).load("old").autoSnapshots)
    }

    func testMetalHUDLabParsing() throws {
        // Game (pid 100) at 20 FPS for 90 s with a 10 s freeze; Steam's web helper (pid 200) idles at frame 50.
        var lines = ["Filtering the log data using \"subsystem == \"com.apple.metal.hud\"\"", "Timestamp               Ty Process[PID:TID]"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var frame = 0.0
        for s in 0...90 {
            if !(40..<50).contains(s) { frame += 20 }
            let stamp = formatter.string(from: t0.addingTimeInterval(Double(s)))
            lines.append("\(stamp) Df wine[100:db3120] [com.apple.metal.hud:Logging] metal-HUD: \(Int(frame)),484.70,601.46<private>")
            if s % 10 == 0 { lines.append("\(stamp) Df wine[200:a1] [com.apple.metal.hud:Logging] metal-HUD: 50,12.0,80.1<private>") }
            if s == 20 { lines.append("\(stamp) Df wine[100:db30fe] [com.apple.metal.hud:Logging] metal-HUD: 0,486.00,611.55<private>") }
        }
        lines.append(lines.last!) // the same event printed twice
        let text = lines.joined(separator: "\n")

        // Parse in the formatter's zone so the test does not depend on the Mac's.
        let saved = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "UTC")!
        defer { NSTimeZone.default = saved }
        let samples = MetalHUDLog.parse(text)
        XCTAssertEqual(samples.filter { $0.pid == 100 }.count, 92, "91 game lines + the frame-0 line; the duplicate is dropped")
        XCTAssertEqual(MetalHUDLog.busiestProcess(samples), 100, "the game, not Steam's web helper")
        let game = samples.filter { $0.pid == 100 }
        let stats = try XCTUnwrap(LabStats.from(game))
        XCTAssertEqual(stats.seconds, 90)
        XCTAssertEqual(stats.frames, 1600)
        XCTAssertEqual(stats.typicalFPS, 20)
        XCTAssertEqual(stats.slowestFPS, 0)
        XCTAssertEqual(stats.stalls, 10, "frame 0 is not a stall; the ten frozen seconds are")
        XCTAssertEqual(LabStats.from(game, after: t0.timeIntervalSince1970 + 60)?.stalls, 0)

        let end = t0.timeIntervalSince1970 + 91
        XCTAssertEqual(LabResult.verdict(game, end: end), .works)
        XCTAssertEqual(LabResult.verdict(game.filter { $0.time < t0.timeIntervalSince1970 + 45 }, end: end), .stopped)
        XCTAssertEqual(LabResult.verdict([], end: end), .noFrames)
        // Covered window: frames stop or never come, which says nothing about the game.
        XCTAssertEqual(LabResult.verdict([], end: end, frontmostShare: 0.2), .notVisible)
        XCTAssertEqual(LabResult.verdict(game.filter { $0.time < t0.timeIntervalSince1970 + 45 }, end: end, frontmostShare: 0), .notVisible)
        XCTAssertEqual(LabResult.verdict([], end: end, frontmostShare: 0.8), .noFrames, "in front and still nothing: a real failure")
        XCTAssertEqual(LabResult.verdict(game, end: end, frontmostShare: 0), .works, "frames that arrived are proof enough")
    }

    func testLabResultsAreReadNewestFirst() throws {
        let store = ProfileStore(paths: Paths(root: temp))
        try store.save(Profile(id: "g", title: "G", recipeID: "g", engineID: "e"))
        XCTAssertTrue(store.labResults("g").isEmpty)
        let lab = store.directory("g").appendingPathComponent("lab")
        try FileManager.default.createDirectory(at: lab, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (i, verdict) in [LabResult.Verdict.stopped, .works].enumerated() {
            let r = LabResult(profileID: "g", recipeID: "g", renderer: .dxmt, sync: .msync, engineID: "e", macOS: "27.0.1",
                              machine: "Apple M1", startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60),
                              seconds: 180, verdict: verdict, steady: nil, whole: nil, hudLog: "x.hud.log")
            try encoder.encode(r).write(to: lab.appendingPathComponent("run\(i).json"))
        }
        try Data("not json".utf8).write(to: lab.appendingPathComponent("broken.json"))
        try Data().write(to: lab.appendingPathComponent("run0.hud.log"))
        let results = store.labResults("g")
        XCTAssertEqual(results.map(\.verdict), [.works, .stopped], "newest first; broken and non-JSON files skipped")
        XCTAssertTrue(results[0].summary.hasPrefix("dxmt: works"))
    }

    func testEvidencePrefersMeasurementsOnThisMac() throws {
        func result(_ verdict: LabResult.Verdict, at t: TimeInterval) -> LabResult {
            LabResult(profileID: "g", recipeID: "g", renderer: .dxmt, sync: .msync, engineID: "e", macOS: "27.0.1", machine: "Apple M1",
                      startedAt: Date(timeIntervalSince1970: t), seconds: 180, verdict: verdict,
                      steady: LabStats(frames: 100, seconds: 10, averageFPS: 10, typicalFPS: 10, slowestFPS: 9, stalls: 0, stallSeconds: 0),
                      whole: nil, hudLog: "x")
        }
        var recipe = Recipe(id: "g", title: "G", steamAppID: 1, renderer: .dxmt)
        recipe.status = .community
        XCTAssertEqual(Evidence.of(recipe, results: []).level, .community)
        XCTAssertEqual(Evidence.of(recipe, results: [result(.stopped, at: 1), result(.works, at: 2)]).level, .labWorks, "the newest run counts")
        XCTAssertEqual(Evidence.of(recipe, results: [result(.works, at: 1), result(.noFrames, at: 2)]).level, .labFailed)
        XCTAssertTrue(Evidence.of(recipe, results: [result(.works, at: 1)]).detail!.contains("10.0 FPS"))
        XCTAssertEqual(Evidence.of(recipe, results: [result(.works, at: 1), result(.notVisible, at: 2)]).level, .labWorks,
                       "a run with the window covered is not evidence")
        XCTAssertEqual(Evidence.of(recipe, results: [result(.notVisible, at: 2)]).level, .community)
        recipe.status = .verified
        XCTAssertEqual(Evidence.of(recipe, results: []).level, .verified)
        recipe.status = .blocked
        XCTAssertEqual(Evidence.of(recipe, results: [result(.works, at: 1)]).level, .blocked, "a game that cannot work never shows as working")
    }

    func testBundledAntiCheatMap() throws {
        let db = AntiCheatDB.bundled
        XCTAssertEqual(db.entries.count, 1166, "the embedded map decodes completely")
        XCTAssertEqual(db.search("valorant").first?.risk, .blocked)
        XCTAssertEqual(db.entry(steamAppID: 271590)?.risk, .onlineDenied, "GTA V: BattlEye denies Wine")
        XCTAssertEqual(db.entry(steamAppID: 440)?.risk, .caution)
        XCTAssertEqual(db.search("  271590 ").first?.title, "Grand Theft Auto V")
        XCTAssertTrue(db.search("no such game zzz").isEmpty)
        let gta = try XCTUnwrap(RecipeCatalog(recipes: RecipeCatalog.bundled())["grand-theft-auto-v"])
        XCTAssertEqual(db.entry(for: gta)?.steamAppID, 271590, "recipes are matched by Steam app id")
    }

    func testAntiCheatShapesEvidence() throws {
        func ac(_ verdict: AntiCheatEntry.MacVerdict, _ linux: String) -> AntiCheatEntry {
            AntiCheatEntry(id: "g", title: "G", antiCheats: ["X"], linuxStatus: linux, steamAppID: 1, macVerdict: verdict)
        }
        let works = LabResult(profileID: "g", recipeID: "g", renderer: .dxmt, sync: .msync, engineID: "e", macOS: "27", machine: "M1",
                              startedAt: Date(), seconds: 180, verdict: .works, steady: nil, whole: nil, hudLog: "x")
        var recipe = Recipe(id: "g", title: "G", steamAppID: 1, renderer: .dxmt)
        recipe.status = .community
        XCTAssertEqual(Evidence.of(recipe, results: [works], antiCheat: ac(.blocked, "Denied")).level, .blocked,
                       "kernel anti-cheat beats any measurement")
        XCTAssertEqual(Evidence.of(recipe, results: [], antiCheat: ac(.warning, "Denied")).level, .antiCheatRisk)
        XCTAssertEqual(Evidence.of(recipe, results: [], antiCheat: ac(.warning, "Broken")).level, .antiCheatRisk)
        let measured = Evidence.of(recipe, results: [works], antiCheat: ac(.warning, "Denied"))
        XCTAssertEqual(measured.level, .labWorks, "the game starts; the anti-cheat warning goes in the detail")
        XCTAssertTrue(measured.detail!.contains("Online play"))
        let caution = Evidence.of(recipe, results: [], antiCheat: ac(.warning, "Supported"))
        XCTAssertEqual(caution.level, .community)
        XCTAssertTrue(caution.detail!.contains("Supported on Linux"))
    }

    func testBestRendererIsFastestThatWorks() throws {
        func run(_ r: Renderer, _ verdict: LabResult.Verdict, steady: Double?, whole: Double? = nil) -> LabResult {
            func stats(_ fps: Double?) -> LabStats? {
                fps.map { LabStats(frames: 1, seconds: 1, averageFPS: $0, typicalFPS: $0, slowestFPS: $0, stalls: 0, stallSeconds: 0) }
            }
            return LabResult(profileID: "g", recipeID: "g", renderer: r, sync: .msync, engineID: "e", macOS: "27", machine: "M1",
                             startedAt: Date(), seconds: 180, verdict: verdict, steady: stats(steady), whole: stats(whole), hudLog: "x")
        }
        let runs = [run(.dxmt, .works, steady: 40), run(.d3dmetal, .stopped, steady: 90), run(.dxvk, .works, steady: 55)]
        XCTAssertEqual(LabResult.best(runs)?.renderer, .dxvk, "a crash never wins, however fast it was before")
        XCTAssertEqual(LabResult.best([run(.dxmt, .works, steady: nil, whole: 30), run(.dxvk, .works, steady: 20)])?.renderer, .dxmt,
                       "falls back to the whole run when there is no steady phase")
        XCTAssertNil(LabResult.best([run(.dxmt, .notVisible, steady: nil), run(.dxvk, .noFrames, steady: nil)]))
    }

    func testLabCandidatesRespectLicenceAndRendererPresence() throws {
        let paths = Paths(root: temp.appendingPathComponent("home"))
        let engine = try fakeEngine(renderers: ["dxmt", "d3dmetal", "dxvk"])
        let gameport = GamePort(paths: paths)
        // Register the fake engine and a profile on it.
        try FileManager.default.createDirectory(at: paths.engines, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.engine(engine.id), withDestinationURL: engine.root)
        try JSONEncoder.pretty.encode(engine.manifest).write(to: engine.root.appendingPathComponent(EngineStore.receiptName))
        try gameport.profiles.save(Profile(id: "elden-ring", title: "Elden Ring", recipeID: "elden-ring", engineID: engine.id))
        let recipeRenderer = try XCTUnwrap(gameport.catalog["elden-ring"]).renderer
        var candidates = try gameport.labCandidates("elden-ring")
        XCTAssertEqual(candidates.first, recipeRenderer, "the current choice is tried first")
        XCTAssertFalse(candidates.contains(.d3dmetal) && recipeRenderer != .d3dmetal, "D3DMetal waits for Apple's licence")
        XCTAssertFalse(candidates.contains(.wined3d))
        try gameport.licenses.accept("apple-gptk")
        candidates = try gameport.labCandidates("elden-ring")
        XCTAssertEqual(Set(candidates), [.dxmt, .d3dmetal, .dxvk])
    }

    func testCrashSignsKeepFailuresVisible() throws {
        // What the TF2 DXVK run wrote: Steam's web helper starting over and over, then a stack overflow.
        var log = (0..<27).map { _ in "info:  Game: steamwebhelper.exe\ninfo:  DXVK: v1.10.3" }.joined(separator: "\n")
        log += "\n020c:err:virtual:virtual_setup_exception stack overflow 832 bytes addr 0x6fffea213114"
        let signs = LabTriage.crashSigns(inLog: log)
        XCTAssertEqual(signs, ["Steam web helper restarted 27 times", "stack overflow"])
        XCTAssertEqual(LabTriage.crashSigns(inLog: "info:  Game: steamwebhelper.exe\ninfo:  Game: steamwebhelper.exe\ninfo:  Game: tf_win64.exe"), [],
                       "two web-helper starts are normal")
        XCTAssertEqual(LabTriage.crashSigns(inLog: "wine: Unhandled page fault on read access\nwine: Unhandled page fault on read access"),
                       ["page fault ×2"])

        XCTAssertEqual(LabResult.gameProcessIDs(inProcessList: #"""
            44950 C:\Program Files (x86)\Steam\steamapps\common\Team Fortress 2\tf_win64.exe -steam
            44943 C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=gpu-process
            """#), [44950])
        XCTAssertEqual(LabResult.gameProcessIDs(inProcessList: #"37485 C:\Program Files (x86)\Steam\steam.exe -silent"#), [])

        let end = Date().timeIntervalSince1970
        XCTAssertEqual(LabResult.verdict([], end: end, frontmostShare: 0, gameStarted: true), .notVisible,
                       "the game ran but was covered: nothing measured")
        XCTAssertEqual(LabResult.verdict([], end: end, frontmostShare: 0, gameStarted: false), .noFrames,
                       "a game that never started is a failure even when covered")
        XCTAssertEqual(LabResult.verdict([], end: end, frontmostShare: 0, gameStarted: true, crashSigns: signs), .noFrames)

        let r = LabResult(profileID: "g", recipeID: "g", renderer: .dxvk, sync: .msync, engineID: "e", macOS: "27", machine: "M1",
                          startedAt: Date(), seconds: 180, verdict: .noFrames, steady: nil, whole: nil, hudLog: "x",
                          frontmostShare: 0, gameStarted: false, crashSigns: signs)
        XCTAssertTrue(r.summary.contains("the game process never started"))
        XCTAssertTrue(r.summary.contains("27 times"))
    }

    func testOnlyTheGameProcessIsMeasured() {
        let t = Date().timeIntervalSince1970
        let steamUI = (0..<100).map { MetalHUDLog.Sample(time: t + Double($0), pid: 44943, frame: Double($0 * 100)) }
        let game = (0..<10).map { MetalHUDLog.Sample(time: t + Double($0), pid: 44950, frame: Double($0 * 10)) }
        XCTAssertEqual(Set(LabResult.gameSamples(steamUI + game, gamePIDs: [44950]).map(\.pid)), [44950])
        XCTAssertEqual(LabResult.gameSamples(steamUI, gamePIDs: [44950]), [], "Steam's frames never stand in for a crashed game")
        XCTAssertEqual(Set(LabResult.gameSamples(steamUI + game, gamePIDs: []).map(\.pid)), [44943], "no game seen: busiest")
    }

    func testSteamGPUCrashesFromCEFLog() throws {
        let crash = "[1024:1028:1031/164855.981:ERROR:gpu_process_host.cc(1002)] GPU process exited unexpectedly: exit_code=541541187"
        XCTAssertEqual(LabTriage.steamCrashSigns(inCEFLog: crash), [], "one crash is recovered from")
        XCTAssertEqual(LabTriage.steamCrashSigns(inCEFLog: [crash, "x", crash, crash].joined(separator: "\n")),
                       ["Steam's GPU process crashed 3 times"])
        XCTAssertEqual(LabTriage.steamCrashSigns(inCEFLog: "", bootstrap: ""), ["Steam itself never started"])
        XCTAssertEqual(LabTriage.steamCrashSigns(inCEFLog: "", bootstrap: "[2026-11-01 00:29:49] Startup - updater built"), [])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cef-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try "old run\n".write(to: file, atomically: true, encoding: .utf8)
        try "old run\nnew run\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GamePort.tail(of: file, from: 8), "new run\n")
        XCTAssertEqual(GamePort.tail(of: file, from: 999), "old run\nnew run\n", "a replaced, shorter log is read whole")
    }
}
