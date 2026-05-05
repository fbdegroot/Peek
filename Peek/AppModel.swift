import SwiftUI
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

enum ZoomCommand {
    case `in`, out, actual, fit
}

enum RotationDirection {
    case left, right

    var degrees: Int {
        switch self {
        case .left:  return -90
        case .right: return 90
        }
    }
}

enum NavigationDirection {
    case previous, next
}

struct DocumentEntry: Identifiable, Hashable {
    let id: UUID
    let url: URL

    init(url: URL) {
        self.id = UUID()
        self.url = url
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var documents: [DocumentEntry] = []
    var activeID: UUID?
    private(set) var zoomCommandToken: ZoomCommandToken?
    private(set) var rotationCommandToken: RotationCommandToken?

    var searchActive: Bool = false
    var searchQuery: String = ""
    private(set) var searchMatchInfo = SearchMatchInfo(index: 0, total: 0)
    private(set) var searchActionToken: SearchActionToken?

    struct SearchMatchInfo: Equatable {
        let index: Int   // 1-based; 0 means no current match
        let total: Int
    }

    enum SearchAction { case next, previous }

    struct SearchActionToken: Equatable {
        let id: UUID
        let action: SearchAction

        static func == (lhs: SearchActionToken, rhs: SearchActionToken) -> Bool {
            lhs.id == rhs.id
        }
    }

    var activeDocumentIsPDF: Bool {
        guard let url = activeURL else { return false }
        return FilePlaylist.kind(of: url) == .pdf
    }

    @ObservationIgnored
    weak var hostingWindow: NSWindow?

    @ObservationIgnored
    var hasRestoredFrame: Bool = false

    struct ZoomCommandToken: Equatable {
        let id: UUID
        let command: ZoomCommand

        static func == (lhs: ZoomCommandToken, rhs: ZoomCommandToken) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct RotationCommandToken: Equatable {
        let id: UUID
        let direction: RotationDirection

        static func == (lhs: RotationCommandToken, rhs: RotationCommandToken) -> Bool {
            lhs.id == rhs.id
        }
    }

    var activeURL: URL? {
        guard let activeID else { return nil }
        return documents.first(where: { $0.id == activeID })?.url
    }

    var activeDocument: DocumentEntry? {
        guard let activeID else { return nil }
        return documents.first(where: { $0.id == activeID })
    }

    /// Open a file. If already in a tab, just switch to it. Otherwise add a new tab.
    func open(url: URL) {
        if let existing = documents.first(where: { $0.url == url }) {
            activeID = existing.id
            updateWindowTitle()
            return
        }
        let entry = DocumentEntry(url: url)
        let isFirst = documents.isEmpty
        documents.append(entry)
        activeID = entry.id
        updateWindowTitle()
        if isFirst {
            resizeWindowToContent(of: url)
        }
    }

    func setActive(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        activeID = id
        updateWindowTitle()
    }

    func close(_ id: UUID) {
        guard let idx = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: idx)
        if activeID == id {
            if documents.isEmpty {
                activeID = nil
            } else {
                let newIdx = min(idx, documents.count - 1)
                activeID = documents[newIdx].id
            }
        }
        updateWindowTitle()
    }

    func closeActive() {
        guard let activeID else { return }
        close(activeID)
    }

    /// Escape behaviour: dismiss the search bar if it's showing, otherwise
    /// close the entire window.
    func handleEscape() {
        if searchActive {
            closeSearch()
        } else {
            hostingWindow?.performClose(nil)
        }
    }

    func switchTab(direction: NavigationDirection) {
        guard let activeID,
              let idx = documents.firstIndex(where: { $0.id == activeID }),
              !documents.isEmpty else { return }
        let nextIdx: Int
        switch direction {
        case .previous: nextIdx = (idx - 1 + documents.count) % documents.count
        case .next:     nextIdx = (idx + 1) % documents.count
        }
        self.activeID = documents[nextIdx].id
        updateWindowTitle()
    }

    /// Replace the active tab with a sibling file from the same folder.
    /// This keeps arrow-key folder navigation working without spawning new tabs.
    func navigate(_ direction: NavigationDirection) {
        guard let activeDocument else { return }
        let siblings = FilePlaylist.scan(folderOf: activeDocument.url)
        guard let idx = siblings.firstIndex(of: activeDocument.url),
              !siblings.isEmpty else { return }
        let nextIdx: Int
        switch direction {
        case .previous: nextIdx = (idx - 1 + siblings.count) % siblings.count
        case .next:     nextIdx = (idx + 1) % siblings.count
        }
        let newURL = siblings[nextIdx]
        // If sibling is already in another tab, switch to it; otherwise replace
        // the URL in the active tab.
        if let existing = documents.first(where: { $0.url == newURL }) {
            activeID = existing.id
            updateWindowTitle()
            return
        }
        // Replace URL of active tab while keeping its id (so the tab item stays put).
        if let activeID,
           let activeIdx = documents.firstIndex(where: { $0.id == activeID }) {
            documents[activeIdx] = DocumentEntry(url: newURL)
            self.activeID = documents[activeIdx].id
            updateWindowTitle()
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = FilePlaylist.supportedTypes
        if panel.runModal() == .OK {
            for url in panel.urls { open(url: url) }
        }
    }

    func zoomCommand(_ command: ZoomCommand) {
        zoomCommandToken = ZoomCommandToken(id: UUID(), command: command)
    }

    func rotateCommand(_ direction: RotationDirection) {
        rotationCommandToken = RotationCommandToken(id: UUID(), direction: direction)
    }

    func toggleSearch() {
        guard activeDocumentIsPDF else { return }
        searchActive.toggle()
        if !searchActive {
            searchQuery = ""
            searchMatchInfo = SearchMatchInfo(index: 0, total: 0)
        }
    }

    func closeSearch() {
        searchActive = false
        searchQuery = ""
        searchMatchInfo = SearchMatchInfo(index: 0, total: 0)
    }

    func searchNext() {
        guard searchActive else { return }
        searchActionToken = SearchActionToken(id: UUID(), action: .next)
    }

    func searchPrevious() {
        guard searchActive else { return }
        searchActionToken = SearchActionToken(id: UUID(), action: .previous)
    }

    func updateSearchMatchInfo(_ info: SearchMatchInfo) {
        searchMatchInfo = info
    }

    private func updateWindowTitle() {
        guard let window = mainWindow else { return }
        if let url = activeURL {
            window.title = url.lastPathComponent
            window.representedURL = url
        } else {
            window.title = "Peek"
            window.representedURL = nil
        }
    }

    private var mainWindow: NSWindow? {
        // Prefer the window this model is bound to. With multiple WindowGroup
        // instances every window shares the "main" scene id, so a generic
        // identifier-based lookup would aim at the wrong window.
        hostingWindow ?? NSApp.keyWindow ?? NSApp.windows.first
    }

    private func resizeWindowToContent(of url: URL) {
        // If we already restored a remembered frame for this window, leave it
        // alone — the user's chosen size wins over fit-to-content.
        guard !hasRestoredFrame else { return }
        guard let window = mainWindow,
              let size = contentSize(of: url),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let maxW = visible.width * 0.9
        let maxH = visible.height * 0.9
        var w = size.width
        var h = size.height
        if w > maxW { let r = maxW / w; w = maxW; h *= r }
        if h > maxH { let r = maxH / h; h = maxH; w *= r }
        // Comfortable first-time minimum — A4 at native scale used to fit in
        // 595×842, which felt cramped. Bump the floor so PDFs and most images
        // open in a window large enough to read without immediately resizing.
        let minW = min(800, maxW)
        let minH = min(1000, maxH)
        let contentRect = NSRect(x: 0, y: 0, width: max(w, minW), height: max(h, minH))
        let frameRect = window.frameRect(forContentRect: contentRect)
        let origin = NSPoint(
            x: visible.midX - frameRect.width / 2,
            y: visible.midY - frameRect.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: frameRect.size), display: true, animate: false)
    }

    private func contentSize(of url: URL) -> CGSize? {
        switch FilePlaylist.kind(of: url) {
        case .image:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
            else { return nil }
            return CGSize(width: w, height: h)
        case .pdf:
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return page.bounds(for: .mediaBox).size
        case .unsupported:
            return nil
        }
    }
}
