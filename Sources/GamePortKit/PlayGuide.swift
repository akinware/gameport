import Foundation

/// The next action for the selected recipe and profile. GamePort still performs launch preflight.
public enum PlayStep: Equatable, Sendable {
    case setupEngine, createProfile, reviewLicense, installSteam, downloadGame, openSteam, installBattleNet, openBattleNet, play

    public static func next(engineAvailable: Bool, hasProfile: Bool, needsLicense: Bool,
                            steamInstalled: Bool, hasSteamAppID: Bool, gameInstalled: Bool, hasFallback: Bool,
                            isBattleNet: Bool = false, battleNetInstalled: Bool = false) -> Self {
        guard hasProfile else { return engineAvailable ? .createProfile : .setupEngine }
        if needsLicense { return .reviewLicense }
        guard engineAvailable else {
            // Only play() can switch to the other profile. It verifies the fallback's local install.
            return hasFallback && hasSteamAppID ? .play : .setupEngine
        }
        if isBattleNet {
            return battleNetInstalled ? .openBattleNet : .installBattleNet
        }
        guard steamInstalled else { return .installSteam }
        guard hasSteamAppID else { return .openSteam }
        return gameInstalled ? .play : .downloadGame
    }
}

extension Recipe {
    /// Steam store header for the selected game. Some recipes have no Steam listing.
    public var steamHeaderURL: URL? {
        guard let steamAppID, steamAppID > 0 else { return nil }
        return URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(steamAppID)/header.jpg")
    }
}
