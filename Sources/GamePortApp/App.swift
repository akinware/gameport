import GamePortKit
#if os(macOS)
import AppKit
import SwiftUI

@main
struct GamePortApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Launched from Xcode or `swift run` an SPM executable starts as a background process;
        // make it a regular app with a Dock icon and a key window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup(Brand.displayName) {
            ContentView().environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
#else
@main
enum GamePortAppStub {
    static func main() { print("\(Brand.displayName) runs on macOS only. For the command line: \(Brand.cliName)") }
}
#endif
