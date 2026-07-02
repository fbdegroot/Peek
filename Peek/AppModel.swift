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
        guard let window = mainWindow,
              let size = contentSize(of: url),
              size.width > 0, size.height > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let maxW = visible.width * 0.9
        let maxH = visible.height * 0.9
        let aspect = size.width / size.height

        // Always match the window's *width* to the page so it fills the window
        // without gray margins left/right. Height: if the user already has a
        // preferred window size (a remembered frame), keep that height and just
        // re-shape the width to the page; otherwise pick a comfortable reading
        // height. A4 at native scale (595×842) felt cramped, hence 1000.
        let currentContent = window.contentRect(forFrameRect: window.frame)
        var h = hasRestoredFrame ? currentContent.height : min(1000, maxH)
        var w = h * aspect
        // Clamp to the screen, preserving aspect ratio.
        if w > maxW { w = maxW; h = w / aspect }
        if h > maxH { h = maxH; w = h * aspect }

        let contentRect = NSRect(x: 0, y: 0, width: w, height: h)
        let frameRect = window.frameRect(forContentRect: contentRect)
        let origin: NSPoint
        if hasRestoredFrame {
            // Keep the window where it is, anchored at its top-left corner, so
            // only the width visibly changes.
            let current = window.frame
            origin = NSPoint(x: current.minX, y: current.maxY - frameRect.height)
        } else {
            origin = NSPoint(
                x: visible.midX - frameRect.width / 2,
                y: visible.midY - frameRect.height / 2
            )
        }
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
            // Crop box matches what PDFKit renders, so the window matches the
            // visible page exactly.
            var size = page.bounds(for: .cropBox).size
            // Multi-page: the viewer frames page 1 with an equal gray gutter on
            // all four sides. Fold that gutter into the window's aspect ratio so
            // the top and bottom margins come out equal to the left/right ones —
            // otherwise the window is sized to the bare page and the bottom
            // shows extra (the run-up to page 2) while the top does not.
            if doc.pageCount > 1 {
                let g = PeekPDFView.pageGutter
                size.width += 2 * g
                size.height += 2 * g
            }
            return size
        case .unsupported:
            return nil
        }
    }
}
