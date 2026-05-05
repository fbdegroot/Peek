import SwiftUI
import AppKit

enum PanMouseButton: String, CaseIterable, Identifiable {
    case left, right, middle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left:   return "Linkermuisknop"
        case .right:  return "Rechtermuisknop"
        case .middle: return "Middelste muisknop"
        }
    }

    /// Button number reported by NSEvent (0 = left, 1 = right, 2 = middle).
    var buttonNumber: Int {
        switch self {
        case .left:   return 0
        case .right:  return 1
        case .middle: return 2
        }
    }
}

enum KeyboardModifier: String, CaseIterable, Identifiable {
    case none, command, option, control, shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:    return "Geen"
        case .command: return "⌘ Command"
        case .option:  return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift:   return "⇧ Shift"
        }
    }

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .none:    return []
        case .command: return .command
        case .option:  return .option
        case .control: return .control
        case .shift:   return .shift
        }
    }

    /// True when the configured modifier is satisfied by `flags`.
    /// `.none` requires no relevant modifier to be held; otherwise the
    /// configured flag must be present (other modifiers are ignored).
    func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let active = flags.intersection(relevant)
        switch self {
        case .none:
            return active.isEmpty
        default:
            return active.contains(nsFlag)
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var panMouseButton: PanMouseButton {
        didSet {
            UserDefaults.standard.set(panMouseButton.rawValue, forKey: Keys.panMouseButton)
        }
    }

    var panModifier: KeyboardModifier {
        didSet {
            UserDefaults.standard.set(panModifier.rawValue, forKey: Keys.panModifier)
        }
    }

    var zoomModifier: KeyboardModifier {
        didSet {
            UserDefaults.standard.set(zoomModifier.rawValue, forKey: Keys.zoomModifier)
        }
    }

    private enum Keys {
        static let panMouseButton = "panMouseButton"
        static let panModifier = "panModifier"
        static let zoomModifier = "zoomModifier"
    }

    private init() {
        let d = UserDefaults.standard
        panMouseButton = PanMouseButton(rawValue: d.string(forKey: Keys.panMouseButton) ?? "") ?? .left
        panModifier = KeyboardModifier(rawValue: d.string(forKey: Keys.panModifier) ?? "") ?? .none
        zoomModifier = KeyboardModifier(rawValue: d.string(forKey: Keys.zoomModifier) ?? "") ?? .command
    }
}

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Pannen (slepen om te verplaatsen)") {
                Picker("Muisknop", selection: $settings.panMouseButton) {
                    ForEach(PanMouseButton.allCases) { button in
                        Text(button.displayName).tag(button)
                    }
                }
                Picker("Modifier", selection: $settings.panModifier) {
                    ForEach(KeyboardModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
            }

            Section("Zoomen met scrollen") {
                Picker("Modifier", selection: $settings.zoomModifier) {
                    ForEach(KeyboardModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 260)
    }
}
