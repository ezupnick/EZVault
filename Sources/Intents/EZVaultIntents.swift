import AppIntents

/// "Capture to EZVault" — a Siri/Shortcuts action that saves a note to the capture folder.
struct CaptureToEZVaultIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture to EZVault"
    static var description = IntentDescription("Save a quick note to your EZVault capture folder.")
    static var openAppWhenRun = false

    @Parameter(title: "Note", requestValueDialog: "What would you like to capture?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let rel = VaultCapture.save(text: text) else {
            throw CaptureIntentError.failed
        }
        return .result(dialog: "Saved to \(rel).")
    }
}

enum CaptureIntentError: Error, CustomLocalizedStringResourceConvertible {
    case failed
    var localizedStringResource: LocalizedStringResource {
        "Couldn't save. Open EZVault once and pick your vault folder first."
    }
}

/// Registers the phrases so you can say "Capture to EZVault" to Siri, and exposes the
/// action in Shortcuts (which can be placed on the Home Screen, Lock Screen, Control
/// Center, or the Share Sheet).
struct EZVaultShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureToEZVaultIntent(),
            phrases: [
                "Capture to \(.applicationName)",
                "Add a note to \(.applicationName)",
                "New \(.applicationName) note"
            ],
            shortTitle: "Capture",
            systemImageName: "square.and.pencil"
        )
    }
}
