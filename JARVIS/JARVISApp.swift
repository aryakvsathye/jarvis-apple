import AppIntents
import SwiftUI

@main
struct JARVISApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup { RootView().task { Location.shared.start(); Car.shared.start() } }
            .onChange(of: phase) { _, now in if now == .active { Talk.warm() } }
    }
}

/// "Talk to JARVIS" asks the app to start listening as soon as it's open.
final class Launch: ObservableObject {
    static let shared = Launch()
    @Published var wantsTalk = false
}

/// One way in, used four ways: "Hey Siri, JARVIS", Back Tap (Settings → Accessibility → Touch → Back Tap → Talk to
/// JARVIS), and buttons in Control Centre and on the Lock Screen (from the Shortcuts app for now).
struct TalkToJarvis: AppIntent {
    static var title: LocalizedStringResource = "Talk to JARVIS"
    static var description = IntentDescription("Opens JARVIS listening.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Launch.shared.wantsTalk = true
        return .result()
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToJarvis(),
                    phrases: ["\(.applicationName)", "Talk to \(.applicationName)", "Hey \(.applicationName)"],
                    shortTitle: "Talk to JARVIS",
                    systemImageName: "waveform")
    }
}
