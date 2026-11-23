import Foundation

/// A fix GamePort applied by itself after a crash, and whether it helped.
///
/// Only fixes whose cause is clear from the log are applied without asking (see
/// `SelfHealing.automaticActionIDs`): each one at most once per profile, one at a time. The next
/// session decides: if it works, the fix stays; if the game fails again, the profile goes back to
/// how it was and the player gets the usual choices.
public struct AutoFix: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// Applied; the next conclusive session decides.
        case trying
        /// The game worked afterwards: the fix stays.
        case kept
        /// The game failed again: the change was undone.
        case undone
    }

    public var actionID: String
    /// "Switch renderer to DXMT".
    public var title: String
    /// What went wrong: the diagnosis headline.
    public var reason: String
    public var appliedAt: Date
    public var state: State
    public var resolvedAt: Date?
    /// The settings the fix changed, as they were before (to undo it).
    public var previousRenderer: Renderer?
    public var previousVulkanDriver: VulkanDriver?
    public var previousAVX: String?

    /// "After a crash (DXVK hit an unsupported MoltenVK query), GamePort switched the renderer to DXMT. It worked, so it stays."
    public var summary: String {
        let did = "After a problem (\(reason)), GamePort did this by itself: \(title)."
        switch state {
        case .trying: return did + " The next time the game runs shows whether it helps."
        case .kept: return did + " The game worked afterwards, so the change stays."
        case .undone: return did + " It did not help, so the change was undone."
        }
    }
}

/// A profile's automatic fixes, newest first, in `profiles/<id>/autofix.json`.
public struct AutoFixStore: Sendable {
    public let paths: Paths
    public static let limit = 10

    public init(paths: Paths) { self.paths = paths }

    public func file(_ profileID: String) -> URL {
        paths.profile(profileID).appendingPathComponent("autofix.json")
    }

    public func fixes(_ profileID: String) -> [AutoFix] {
        guard let data = try? Data(contentsOf: file(profileID)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AutoFix].self, from: data)) ?? []
    }

    func save(_ fixes: [AutoFix], profileID: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(Array(fixes.prefix(Self.limit))).write(to: file(profileID), options: .atomic)
    }

    /// The fix being tried now, if any.
    public func pending(_ profileID: String) -> AutoFix? {
        fixes(profileID).first { $0.state == .trying }
    }

    /// Settles the fix being tried with a finished session that started after it was applied:
    /// a working session keeps it, a failed one undoes it. A quick deliberate quit decides nothing.
    @discardableResult
    public func resolve(_ profileID: String, with session: PlayRecord) -> AutoFix? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var all = fixes(profileID)
        guard let index = all.firstIndex(where: { $0.state == .trying }),
              session.startedAt >= all[index].appliedAt, session.outcome.isConclusive else { return nil }
        if session.outcome == .worked {
            all[index].state = .kept
        } else {
            undo(all[index], profileID: profileID)
            all[index].state = .undone
        }
        all[index].resolvedAt = Date()
        save(all, profileID: profileID)
        return all[index]
    }

    /// Undoes the fix being tried because the game failed again. Returns it, or nil if none was pending.
    @discardableResult
    public func undoPending(_ profileID: String) -> AutoFix? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var all = fixes(profileID)
        guard let index = all.firstIndex(where: { $0.state == .trying }) else { return nil }
        undo(all[index], profileID: profileID)
        all[index].state = .undone
        all[index].resolvedAt = Date()
        save(all, profileID: profileID)
        return all[index]
    }

    func record(_ fix: AutoFix, profileID: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        save([fix] + fixes(profileID), profileID: profileID)
    }

    /// Puts back only what the fix changed, so other changes made since stay.
    private func undo(_ fix: AutoFix, profileID: String) {
        let store = ProfileStore(paths: paths)
        guard var profile = try? store.load(profileID) else { return }
        switch fix.actionID {
        case "vk-mvk":
            profile.vulkanDriver = fix.previousVulkanDriver
        case "avx-on":
            profile.environment["ROSETTA_ADVERTISE_AVX"] = fix.previousAVX
        default:
            profile.renderer = fix.previousRenderer
        }
        try? store.save(profile)
    }

    private static let lock = NSLock()
}

extension GamePort {
    public var autoFixes: AutoFixStore { AutoFixStore(paths: paths) }

    /// Called when a launch failed. Applies the diagnosis's sure fix by itself and returns it, so the
    /// caller can start the game once more. Returns nil when there is nothing sure to do:
    /// - a fix was already being tried (it failed too, so it is undone and the player decides),
    /// - the same fix was tried before on this profile,
    /// - the cause is not clear from the log.
    public func applyAutoFix(_ diagnosis: LaunchDiagnosis, profileID: String) -> AutoFix? {
        if autoFixes.undoPending(profileID) != nil { return nil }
        guard let action = diagnosis.autoFix,
              !autoFixes.fixes(profileID).contains(where: { $0.actionID == action.id }),
              let before = try? profiles.load(profileID) else { return nil }
        guard (try? applyRecovery(action.kind, to: profileID)) != nil else { return nil }
        let fix = AutoFix(actionID: action.id, title: action.title, reason: diagnosis.headline,
                          appliedAt: Date(), state: .trying,
                          previousRenderer: before.renderer, previousVulkanDriver: before.vulkanDriver,
                          previousAVX: before.environment["ROSETTA_ADVERTISE_AVX"])
        autoFixes.record(fix, profileID: profileID)
        return fix
    }
}
