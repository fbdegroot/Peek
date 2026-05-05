import SwiftUI
import AppKit
import Sparkle

struct AppModelFocusedKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedKey.self] }
        set { self[AppModelFocusedKey.self] = newValue }
    }
}

@main
struct PeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup(id: "main", for: URL.self) { $url in
            PeekWindowContent(initialURL: url, appDelegate: appDelegate)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenCommandButton()
            }
            CommandGroup(replacing: .saveItem) {
                CloseTabCommandButton()
            }
            CommandGroup(replacing: .textEditing) {
                SearchCommandButtons()
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }
            CommandGroup(after: .toolbar) {
                Divider()
                ZoomCommandButtons()
                Divider()
                RotationCommandButtons()
                Divider()
                TabSwitchCommandButtons()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesButton: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

private struct PeekWindowContent: View {
    let initialURL: URL?
    let appDelegate: AppDelegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 480, minHeight: 320)
            .focusedSceneValue(\.appModel, model)
            .background(WindowAccessor { window in
                model.hostingWindow = window
                if let window {
                    WindowFramePersistence.attach(to: window, markRestored: {
                        model.hasRestoredFrame = true
                    })
                }
            })
            .onAppear {
                appDelegate.register(openWindow: openWindow, model: model)
                let urls: [URL] = initialURL.map { [$0] } ?? appDelegate.consumePendingURLs()
                for (i, url) in urls.enumerated() {
                    if i == 0 {
                        model.open(url: url)
                    } else {
                        openWindow(value: url)
                    }
                }
            }
    }
}

@MainActor
enum WindowFramePersistence {
    private static let key = "PeekWindowFrame"

    static func attach(to window: NSWindow, markRestored: () -> Void) {
        if let saved = loadFrame(),
           let screen = window.screen ?? NSScreen.main {
            let constrained = window.constrainFrameRect(saved, to: screen)
            window.setFrame(constrained, display: false)
            markRestored()
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { note in
            if let w = note.object as? NSWindow { saveFrame(w.frame) }
        }
        center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { note in
            if let w = note.object as? NSWindow { saveFrame(w.frame) }
        }
    }

    private static func loadFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: key) else { return nil }
        let rect = NSRectFromString(str)
        return (rect.width > 0 && rect.height > 0) ? rect : nil
    }

    private static func saveFrame(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

private struct OpenCommandButton: View {
    @FocusedValue(\.appModel) private var model
    var body: some View {
        Button("Open…") { model?.presentOpenPanel() }
            .keyboardShortcut("o", modifiers: .command)
    }
}

private struct CloseTabCommandButton: View {
    @FocusedValue(\.appModel) private var model
    var body: some View {
        Button("Close Tab") { model?.closeActive() }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(model?.activeID == nil)
    }
}

private struct ZoomCommandButtons: View {
    @FocusedValue(\.appModel) private var model
    var body: some View {
        Button("Zoom In") { model?.zoomCommand(.in) }
            .keyboardShortcut("=", modifiers: .command)
        Button("Zoom Out") { model?.zoomCommand(.out) }
            .keyboardShortcut("-", modifiers: .command)
        Button("Actual Size") { model?.zoomCommand(.actual) }
            .keyboardShortcut("1", modifiers: .command)
        Button("Fit to Window") { model?.zoomCommand(.fit) }
            .keyboardShortcut("0", modifiers: .command)
    }
}

private struct SearchCommandButtons: View {
    @FocusedValue(\.appModel) private var model
    var body: some View {
        Button("Find…") { model?.toggleSearch() }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(model?.activeDocumentIsPDF != true)
        Button("Find Next") { model?.searchNext() }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(model?.searchActive != true)
        Button("Find Previous") { model?.searchPrevious() }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(model?.searchActive != true)
    }
}

private struct RotationCommandButtons: View {
    @FocusedValue(\.appModel) private var model
    var body: some View {
        Button("Rotate Left") { model?.rotateCommand(.left) }
            .keyboardShortcut(.leftArrow, modifiers: .command)
        Button("Rotate Right") { model?.rotateCommand(.right) }
            .keyboardShortcut(.rightArrow, modifiers: .command)
    }
}

private struct TabSwitchCommandButtons: View {
    @FocusedValue(\.appModel) private var model
    var body: some View {
        Button("Show Next Tab") { model?.switchTab(direction: .next) }
            .keyboardShortcut("]", modifiers: [.command, .shift])
        Button("Show Previous Tab") { model?.switchTab(direction: .previous) }
            .keyboardShortcut("[", modifiers: [.command, .shift])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openWindow: OpenWindowAction?
    private var pendingURLs: [URL] = []
    private var registeredModels: [WeakModel] = []

    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls {
            if let empty = firstEmptyModel() {
                empty.open(url: url)
            } else if let openWindow {
                openWindow(value: url)
            } else {
                pendingURLs.append(url)
            }
        }
        scheduleCleanup()
    }

    func register(openWindow: OpenWindowAction, model: AppModel) {
        self.openWindow = openWindow
        registeredModels.removeAll { $0.value == nil }
        if !registeredModels.contains(where: { $0.value === model }) {
            registeredModels.append(WeakModel(value: model))
        }
        // A new (likely empty) window may be a state-restored straggler from a
        // previous session. Schedule a sweep so it gets closed as soon as any
        // sibling window has actual content.
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        Task { @MainActor [weak self] in
            self?.closeStaleEmptyWindows()
        }
    }

    func consumePendingURLs() -> [URL] {
        let urls = pendingURLs
        pendingURLs.removeAll()
        return urls
    }

    private func firstEmptyModel() -> AppModel? {
        registeredModels.removeAll { $0.value == nil }
        return registeredModels.compactMap(\.value).first { $0.documents.isEmpty }
    }

    private func closeStaleEmptyWindows() {
        registeredModels.removeAll { $0.value == nil }
        let models = registeredModels.compactMap(\.value)
        guard models.contains(where: { !$0.documents.isEmpty }) else { return }
        for model in models where model.documents.isEmpty {
            model.hostingWindow?.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private final class WeakModel {
    weak var value: AppModel?
    init(value: AppModel) { self.value = value }
}

