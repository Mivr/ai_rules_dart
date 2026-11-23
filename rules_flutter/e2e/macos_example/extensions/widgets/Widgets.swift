import AppIntents
import Security
import SwiftUI
import WidgetKit

/// The App Group the app and its extensions share. Each writes and reads the
/// same `UserDefaults` suite through it. The ad hoc and team-signed builds use
/// different ids, so it is read from this bundle's signed entitlements.
let appGroup: String = {
    let task = SecTaskCreateFromSelf(nil)
    let key = "com.apple.security.application-groups" as CFString
    let groups = task.flatMap { SecTaskCopyValueForEntitlement($0, key, nil) }
    return (groups as? [String])?.first ?? ""
}()

struct NoteEntry: TimelineEntry {
    let date: Date
    let note: String
}

struct NoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> NoteEntry {
        NoteEntry(date: .now, note: "rules_flutter")
    }

    func getSnapshot(in context: Context, completion: @escaping (NoteEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NoteEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> NoteEntry {
        let shared = UserDefaults(suiteName: appGroup)?.string(forKey: "note")
        return NoteEntry(date: .now, note: shared ?? "rules_flutter")
    }
}

struct NoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NoteWidget", provider: NoteProvider()) { entry in
            Text(entry.note)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Note")
        .supportedFamilies([.systemSmall])
    }
}

/// What the Control Center button runs. `app_intents` on the extension
/// extracts its metadata, which the system needs to perform it.
@available(macOS 26.0, *)
struct PingIntent: AppIntent {
    static let title: LocalizedStringResource = "Ping"

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: appGroup)?.set("pinged", forKey: "note")
        return .result()
    }
}

/// A Control Center control. Controls need macOS 26 and the extension runs on
/// 14, so the bundle below includes it behind `#available`.
@available(macOS 26.0, *)
struct PingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PingControl") {
            ControlWidgetButton(action: PingIntent()) {
                Label("Ping", systemImage: "bell")
            }
        }
        .displayName("Ping")
    }
}

@main
struct ExampleWidgets: WidgetBundle {
    var body: some Widget {
        NoteWidget()
        if #available(macOS 26.0, *) {
            PingControl()
        }
    }
}
