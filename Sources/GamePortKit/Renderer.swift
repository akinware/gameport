import Foundation

/// Which driver turns Vulkan (DXVK, vkd3d) into Metal for a game.
public enum VulkanDriver: String, Codable, Sendable, CaseIterable {
    /// MoltenVK, bundled with the engine.
    case moltenvk
    /// KosmicKrisp: Mesa's Vulkan 1.4 driver on Metal (macOS 26+), reached through GamePort's shim
    /// (Tools/kosmickrisp-shim). Experimental: only the game uses it; Steam and Wine stay on MoltenVK.
    case kosmickrisp

    public var displayName: String {
        switch self {
        case .moltenvk: return "MoltenVK"
        case .kosmickrisp: return "KosmicKrisp (experimental)"
        }
    }
}

/// How a game's Direct3D reaches Metal.
public enum Renderer: String, Codable, Sendable, CaseIterable {
    /// Wine's own D3D-on-OpenGL. Old games and launcher UIs.
    case wined3d
    /// DXMT: Direct3D 10/11 straight to Metal (LGPL-2.1+ since v0.80; MIT before).
    case dxmt
    /// Apple's D3DMetal (Game Porting Toolkit): Direct3D 11/12 to Metal. Apple licence, 64-bit only.
    case d3dmetal
    /// DXVK: Direct3D 9/10/11 to Vulkan, then MoltenVK to Metal.
    case dxvk

    public var displayName: String {
        switch self {
        case .wined3d: return "WineD3D (OpenGL)"
        case .dxmt: return "DXMT (D3D10/11 → Metal)"
        case .d3dmetal: return "D3DMetal (D3D11/12 → Metal, Apple GPTK)"
        case .dxvk: return "DXVK (D3D9/10/11 → Vulkan → Metal)"
        }
    }

    /// The licence id (from the engine manifest) that must be accepted before this renderer is used.
    public func gatingLicense(in manifest: EngineManifest) -> String? {
        manifest.licenses.first { $0.value.gatesRenderers.contains(rawValue) }?.key
    }

    /// Ordered `<renderer>/wine` directories (first wins) that supply DLLs for this renderer.
    public func overlayDirectories(engine: InstalledEngine) throws -> [URL] {
        func dir(_ name: String) throws -> URL {
            guard let d = engine.rendererDirectory(name) else {
                throw GamePortError.missing("the \(name) renderer is not in the engine (\(engine.id))")
            }
            return d
        }
        let d9vk = engine.rendererDirectory("d9vk")?.appendingPathComponent("wine", isDirectory: true)
        func withD9VK(_ overlays: [URL]) -> [URL] { (d9vk.map { [$0] } ?? []) + overlays }

        switch self {
        case .wined3d:
            return []
        case .dxmt:
            return withD9VK([try dir("dxmt").appendingPathComponent("wine", isDirectory: true)])
        case .d3dmetal:
            guard engine.manifest.arch == .rosetta else { throw GamePortError.unsupported("D3DMetal requires an x86_64 engine") }
            guard engine.manifest.effectiveOverlayMode == .prepend else {
                throw GamePortError.unsupported("D3DMetal requires an engine with WINEDLLPATH_PREPEND; use DXMT or DXVK on \(engine.id)")
            }
            let d3dm = try dir("d3dmetal")
            var overlays = [d3dm.appendingPathComponent("wine", isDirectory: true)]
            // D3DMetal is 64-bit only: 32-bit D3D10/11 falls through to DXMT instead of wined3d.
            if let dxmt = engine.rendererDirectory("dxmt") {
                overlays.append(dxmt.appendingPathComponent("wine", isDirectory: true))
            }
            return withD9VK(overlays)
        case .dxvk:
            return withD9VK([try dir("dxvk").appendingPathComponent("wine", isDirectory: true)])
        }
    }

    /// Environment that points Wine at this renderer's DLL overlay.
    /// Patched engines (`overlayMode == .prepend`) honor `WINEDLLPATH_PREPEND`.
    /// Stock Wine builds (`overlayMode == .prefix`) get `WINEDLLPATH` for unix `.so` modules
    /// while `RendererStager` symlinks PE DLLs into the profile's `system32`/`syswow64`.
    public func environment(engine: InstalledEngine) throws -> [String: String] {
        var env: [String: String] = [:]
        let overlays = try overlayDirectories(engine: engine)
        let d9vk = engine.rendererDirectory("d9vk") != nil
        let dllPathKey = engine.manifest.effectiveOverlayMode == .prefix ? "WINEDLLPATH+" : "WINEDLLPATH_PREPEND"
        let overlayPath = overlays.map(\.path).joined(separator: ":")

        switch self {
        case .wined3d:
            break
        case .dxmt:
            env[dllPathKey] = overlayPath
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core" + (d9vk ? ",d3d9" : "") + "=n,b"
        case .d3dmetal:
            let d3dm = try {
                guard let d = engine.rendererDirectory("d3dmetal") else {
                    throw GamePortError.missing("the d3dmetal renderer is not in the engine (\(engine.id))")
                }
                return d
            }()
            env[dllPathKey] = overlayPath
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core,d3d12,d3d12core" + (d9vk ? ",d3d9" : "") + "=n,b"
            let external = d3dm.appendingPathComponent("external").path
            env["CX_D3DMETALPATH"] = external
            env["DYLD_FALLBACK_LIBRARY_PATH+"] = external
            env["DYLD_FALLBACK_FRAMEWORK_PATH+"] = external
        case .dxvk:
            env[dllPathKey] = overlayPath
            env["WINEDLLOVERRIDES"] = "dxgi,d3d11,d3d10core" + (d9vk ? ",d3d9" : "") + "=n,b"
        }
        return env
    }
}

/// Reversible renderer DLL staging for stock Wine engines (`overlayMode == .prefix`).
/// - DLLs with a companion Unix `.so` (e.g. `winemetal.dll` + `x86_64-unix/winemetal.so`) are
///   symlinked as-is so Wine loads them as builtins via `WINEDLLPATH`.
/// - Pure PE DLLs (`d3d11.dll`, `dxgi.dll`, `d3d10core.dll`, `d3d9.dll`) are copied into
///   `system32`/`syswow64` with any `"Wine builtin DLL"` DOS-stub marker cleared so stock Wine
///   loads them natively (`=n,b`) instead of falling back to `wined3d`.
/// Tracks every staged file in `<prefix>/.gameport-staged-dlls.json` and backs up Wine's original
/// stub DLLs as `<name>.gameport-orig` so switching renderers always restores a clean prefix.
public enum RendererStager {
    static let manifestName = ".gameport-staged-dlls.json"
    static let backupSuffix = ".gameport-orig"
    static let builtinMarker = Data("Wine builtin DLL".utf8)

    struct Record: Codable {
        var renderer: String
        var files: [String]
    }

    public static func sync(renderer: Renderer, engine: InstalledEngine, prefix: URL) throws {
        guard engine.manifest.effectiveOverlayMode == .prefix else { return }
        let fm = FileManager.default
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        guard fm.fileExists(atPath: system32.path) else { return }

        // 1. Always restore any previously staged files first so stale DLLs never linger.
        try restore(prefix: prefix)

        let overlays = try renderer.overlayDirectories(engine: engine)
        guard !overlays.isEmpty else { return }

        let syswow64 = prefix.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        let archMappings: [(src: String, relDest: String, destDir: URL)] = [
            ("x86_64-windows", "drive_c/windows/system32", system32),
            ("i386-windows", "drive_c/windows/syswow64", syswow64),
        ]

        var staged: [String] = []
        var claimed = Set<String>()

        for overlay in overlays {
            let unixDir = overlay.appendingPathComponent("x86_64-unix", isDirectory: true)
            for map in archMappings {
                guard fm.fileExists(atPath: map.destDir.path) else { continue }
                let srcDir = overlay.appendingPathComponent(map.src, isDirectory: true)
                guard let entries = try? fm.contentsOfDirectory(atPath: srcDir.path) else { continue }
                for name in entries.sorted() {
                    guard name.lowercased().hasSuffix(".dll"), !name.hasPrefix("_") else { continue }
                    let relPath = "\(map.relDest)/\(name)"
                    let key = relPath.lowercased()
                    guard claimed.insert(key).inserted else { continue }

                    let srcFile = srcDir.appendingPathComponent(name)
                    let dstFile = map.destDir.appendingPathComponent(name)
                    let backup = map.destDir.appendingPathComponent(name + backupSuffix)

                    if fm.fileExists(atPath: dstFile.path) || (try? fm.attributesOfItem(atPath: dstFile.path)) != nil {
                        let attrs = try? fm.attributesOfItem(atPath: dstFile.path)
                        let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
                        if isLink {
                            try? fm.removeItem(at: dstFile)
                        } else if !fm.fileExists(atPath: backup.path) {
                            try fm.moveItem(at: dstFile, to: backup)
                        } else {
                            try? fm.removeItem(at: dstFile)
                        }
                    }

                    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                    let hasUnixSO = fm.fileExists(atPath: unixDir.appendingPathComponent("\(stem).so").path)
                    if hasUnixSO {
                        try fm.createSymbolicLink(at: dstFile, withDestinationURL: srcFile)
                    } else {
                        try stagePurePEDLL(from: srcFile, to: dstFile)
                    }
                    staged.append(relPath)
                }
            }
        }

        if !staged.isEmpty {
            let data = try JSONEncoder.pretty.encode(Record(renderer: renderer.rawValue, files: staged))
            try data.write(to: prefix.appendingPathComponent(manifestName), options: .atomic)
        }
    }

    /// Copies a pure-PE DLL and clears any 32-byte `"Wine builtin DLL"` DOS-stub marker at 0x40
    /// (without ever modifying the read-only engine copy) so stock Wine loads it natively (`n,b`).
    private static func stagePurePEDLL(from source: URL, to dest: URL) throws {
        var bytes = try Data(contentsOf: source)
        if bytes.count >= 0x60, bytes[0] == 0x4D, bytes[1] == 0x5A { // "MZ"
            let peOffset = Int(bytes[0x3C]) | (Int(bytes[0x3D]) << 8) | (Int(bytes[0x3E]) << 16) | (Int(bytes[0x3F]) << 24)
            if peOffset >= 0x60, bytes[0x40..<0x50] == builtinMarker {
                bytes.replaceSubrange(0x40..<0x60, with: Data(repeating: 0, count: 32))
            }
        }
        try bytes.write(to: dest, options: .atomic)
    }

    public static func restore(prefix: URL) throws {
        let fm = FileManager.default
        let manifestURL = prefix.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return }

        for rel in record.files {
            let dst = prefix.appendingPathComponent(rel)
            let backup = prefix.appendingPathComponent(rel + backupSuffix)
            if fm.fileExists(atPath: dst.path) || (try? fm.attributesOfItem(atPath: dst.path)) != nil {
                try? fm.removeItem(at: dst)
            }
            if fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: dst.path) {
                try? fm.moveItem(at: backup, to: dst)
            }
        }
        try? fm.removeItem(at: manifestURL)
    }
}

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    case msync, esync, none

    public var environment: [String: String] {
        switch self {
        case .msync: return ["WINEMSYNC": "1", "WINEESYNC": "0"]
        case .esync: return ["WINEMSYNC": "0", "WINEESYNC": "1"]
        case .none: return ["WINEMSYNC": "0", "WINEESYNC": "0"]
        }
    }
}

/// Merges `extra` into `base`. Keys ending in `+` append: `:` for paths, `;` for WINEDLLOVERRIDES.
/// WINEDLLOVERRIDES is always appended, never replaced, so a recipe cannot silently drop the renderer's.
public func mergeEnvironment(_ base: [String: String], _ extra: [String: String]) -> [String: String] {
    var env = base
    for (rawKey, value) in extra.sorted(by: { $0.key < $1.key }) {
        let append = rawKey.hasSuffix("+") || rawKey == "WINEDLLOVERRIDES"
        let key = rawKey.hasSuffix("+") ? String(rawKey.dropLast()) : rawKey
        if append, let existing = env[key], !existing.isEmpty {
            let sep = key == "WINEDLLOVERRIDES" ? ";" : ":"
            env[key] = existing + sep + value
        } else {
            env[key] = value
        }
    }
    return env
}
