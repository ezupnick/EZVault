import SwiftUI

@main
struct VaultChatApp: App {
    @StateObject private var settings = Settings()
    @StateObject private var vault = VaultStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(settings)
                .environmentObject(vault)
        }
        // Refresh the index whenever the app comes to the foreground, so notes
        // added or edited since last launch (e.g. today's daily) get picked up.
        // reindex() is incremental and no-ops if there's no vault or one is running.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await vault.reindex() }
            }
        }
    }
}
