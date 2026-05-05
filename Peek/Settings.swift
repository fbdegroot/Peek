import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

@MainActor
@Observable
final class DefaultAppCoordinator {
    static let supportedTypes: [UTType] = [
        .png, .jpeg, .heic, .heif, .webP, .gif, .tiff, .bmp, .svg, .pdf
    ]

    private(set) var defaultCount: Int = 0
    private(set) var isUpdating: Bool = false
    var totalCount: Int { Self.supportedTypes.count }

    func refresh() {
        let myBundleID = Bundle.main.bundleIdentifier
        defaultCount = Self.supportedTypes.filter { type in
            guard let url = NSWorkspace.shared.urlForApplication(toOpen: type),
                  let bundle = Bundle(url: url) else { return false }
            return bundle.bundleIdentifier == myBundleID
        }.count
    }

    func setAsDefault() async {
        isUpdating = true
        defer { isUpdating = false }
        let bundleURL = Bundle.main.bundleURL
        for type in Self.supportedTypes {
            try? await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type)
        }
        refresh()
    }
}

struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @State private var defaults = DefaultAppCoordinator()

    private var defaultsStatusText: String {
        switch defaults.defaultCount {
        case defaults.totalCount:
            return "Peek opent alle ondersteunde bestanden."
        case 0:
            return "Peek is voor geen enkel bestandstype de standaard."
        default:
            return "Peek opent \(defaults.defaultCount) van \(defaults.totalCount) ondersteunde bestandstypen."
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("PDF's en afbeeldingen") {
                    if defaults.defaultCount == defaults.totalCount {
                        Label("Gekoppeld", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Button("Maak standaard") {
                            Task { await defaults.setAsDefault() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(defaults.isUpdating)
                    }
                }
            } header: {
                Text("Standaard viewer")
            } footer: {
                Text(defaultsStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pannen") {
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

            Section("Zoomen") {
                Picker("Modifier bij scrollen", selection: $settings.zoomModifier) {
                    ForEach(KeyboardModifier.allCases) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollIndicators(.hidden)
        .frame(width: 480, height: 440)
        .onAppear { defaults.refresh() }
    }
}
