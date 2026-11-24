import AppIntents

/// A minimal App Intent. `flutter_macos_app(runner_deps = ...)` links it into
/// the runner and rules_apple's `app_intents` extracts its metadata.
@available(macOS 13.0, *)
struct PingIntent: AppIntent {
    static let title: LocalizedStringResource = "Ping"

    func perform() async throws -> some IntentResult {
        .result()
    }
}
