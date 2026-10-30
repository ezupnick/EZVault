import SwiftUI

@main
struct VaultChatApp: App {
    @StateObject private var settings = Settings()
    @StateObject private var vault = VaultStore()

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(settings)
                .environmentObject(vault)
        }
    }
}
