import SwiftUI
import AppKit
import PDFKit

struct PDFViewerRepresentable: NSViewRepresentable {
    let url: URL
    let model: AppModel
    let searchActive: Bool

    func makeNSView(context: Context) -> PeekPDFView {
        let view = PeekPDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor(white: 0.22, alpha: 1.0)
        view.minScaleFactor = 0.05
        view.maxScaleFactor = 64.0
        // Preview-style page separation: each page sits on the gray backdrop
        // with a drop shadow and a gray gap between consecutive pages. The gap
        // is vertical only (top/bottom) — the page still fills the viewport
        // width flush to both edges, so there's no horizontal dark frame and no
        // sideways overflow. `fitToWindow` fits the page width exactly, and the
        // extra top/bottom margins become the visible canvas between pages.
        view.pageShadowsEnabled = true
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(
            top: PeekPDFView.pageGutter,
            left: 0,
            bottom: PeekPDFView.pageGutter,
            right: 0
        )
        view.onNavigate = { [weak model] direction in
            model?.navigate(direction)
        }
        view.loadDocument(at: url)
        return view
    }

    func updateNSView(_ nsView: PeekPDFView, context: Context) {
        if context.coordinator.lastURL != url {
            nsView.loadDocument(at: url)
            context.coordinator.lastURL = url
            context.coordinator.lastZoomToken = nil
            context.coordinator.lastRotationToken = nil
            context.coordinator.lastSearchQuery = ""
            context.coordinator.lastSearchActive = false
            context.coordinator.lastSearchActionToken = nil
        }
        nsView.onSearchMatchInfoChanged = { [weak model] info in
            model?.updateSearchMatchInfo(info)
        }
        nsView.suppressCursor = searchActive
        if let token = model.zoomCommandToken, token != context.coordinator.lastZoomToken {
            nsView.apply(command: token.command)
            context.coordinator.lastZoomToken = token
        }
        if let token = model.rotationCommandToken, token != context.coordinator.lastRotationToken {
            nsView.apply(rotation: token.direction)
            context.coordinator.lastRotationToken = token
        }
        if context.coordinator.lastSearchActive != model.searchActive ||
           context.coordinator.lastSearchQuery != model.searchQuery {
            nsView.search(query: model.searchActive ? model.searchQuery : "")
            context.coordinator.lastSearchActive = model.searchActive
            context.coordinator.lastSearchQuery = model.searchQuery
        }
        if let token = model.searchActionToken, token != context.coordinator.lastSearchActionToken {
            switch token.action {
            case .next:     nsView.searchNext()
            case .previous: nsView.searchPrevious()
            }
            context.coordinator.lastSearchActionToken = token
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        var lastZoomToken: AppModel.ZoomCommandToken?
        var lastRotationToken: AppModel.RotationCommandToken?
        var lastSearchQuery: String = ""
        var lastSearchActive: Bool = false
        var lastSearchActionToken: AppModel.SearchActionToken?
    }
}

final class PeekPDFView: PDFView {
    /// Height of the gray gap drawn above and below every page (fed into
    /// `pageBreakMargins`). Only the vertical gap is used, so the space appears
    /// as canvas *between* consecutive pages while each page still spans the
    /// full viewport width. The visible gap between two pages is twice this
    /// (bottom margin of one + top margin of the next).
    static let pageGutter: CGFloat = 7

    var onNavigate: ((NavigationDirection) -> Void)?

    private var hasFittedOnce = false
    private var userHasInteracted = false
    private var styleObservation: NSKeyValueObservation?
    private var scrollMonitor: Any?

    private var isPanning = false
    private var dragStartLocation: NSPoint = .zero
    private var scrollOriginAtDragStart: NSPoint = .zero
    private var hoverTrackingArea: NSTrackingArea?

    private var searchMatches: [PDFSelection] = []
    private var searchIndex: Int = 0
    var onSearchMatchInfoChanged: ((AppModel.SearchMatchInfo) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    private var pdfScrollView: NSScrollView? {
        var queue: [NSView] = subviews
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let sv = v as? NSScrollView { return sv }
            queue.append(contentsOf: v.subviews)
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureScrollView()
        installHoverTrackingArea()
        if window != nil {
            installScrollMonitor()
        } else if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func installHoverTrackingArea() {
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
            hoverTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if isPanning {
            NSCursor.closedHand.set()
            return
        }
        applyHoverCursor(at: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if !isPanning {
            applyHoverCursor(at: event.locationInWindow)
        }
    }

    /// Pick the right cursor based on what's underneath the pointer:
    /// - selectable text on a PDF page → I-beam,
    /// - elsewhere → openHand when left is the pan trigger (so it visually
    ///   hints at draggability), or arrow when pan is bound to another button.
    private func applyHoverCursor(at locationInWindow: NSPoint) {
        let pointInSelf = convert(locationInWindow, from: nil)
        if pointIsOverText(pointInSelf) {
            NSCursor.iBeam.set()
            return
        }
        if AppSettings.shared.panMouseButton == .left {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func pointIsOverText(_ pointInSelf: NSPoint) -> Bool {
        guard let page = page(for: pointInSelf, nearest: false) else { return false }
        let pagePoint = convert(pointInSelf, to: page)
        let idx = page.characterIndex(at: pagePoint)
        return idx >= 0 && idx != NSNotFound
    }

    /// Intercept Cmd+scroll and plain mouse-wheel scroll at the app level.
    /// PDFView's inner scrollview consumes scrollWheel events before our
    /// override runs, so we use a local event monitor that fires before any
    /// view receives the event.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self,
                  let window = self.window,
                  event.window === window else { return event }
            let frameInWindow = self.convert(self.bounds, to: nil)
            let inside = frameInWindow.contains(event.locationInWindow)

            if AppSettings.shared.zoomModifier.matches(event.modifierFlags) {
                // If cursor is outside the viewer, eat the event so no other
                // view (sidebar, etc.) reacts either — the bar should feel
                // completely off-limits to zoom gestures.
                guard inside else { return nil }
                let pointInSelf = self.convert(event.locationInWindow, from: nil)
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
                let factor = pow(1.0015, delta)
                self.zoomToCursor(newScale: self.scaleFactor * factor, cursorInSelf: pointInSelf)
                return nil
            }

            // Mouse wheel (non-precise deltas): invert direction. Trackpad
            // scrolls (precise deltas) keep following the system natural-scroll
            // preference and pass through unchanged.
            if inside, !event.hasPreciseScrollingDeltas, let scrollView = self.pdfScrollView {
                self.userHasInteracted = true
                let lineHeight: CGFloat = 16
                let clip = scrollView.contentView
                var origin = clip.bounds.origin
                origin.x += event.scrollingDeltaX * lineHeight
                origin.y += event.scrollingDeltaY * lineHeight
                clip.setBoundsOrigin(origin)
                scrollView.reflectScrolledClipView(clip)
                scrollView.flashScrollers()
                return nil
            }

            return event
        }
    }

    private func configureScrollView() {
        guard let sv = pdfScrollView else { return }

        // Force overlay-style scrollers regardless of system preference. AppKit
        // auto-resets scrollerStyle in many places — KVO observer puts it back.
        if styleObservation == nil {
            styleObservation = sv.observe(\.scrollerStyle, options: [.new, .initial]) { sv, _ in
                if sv.scrollerStyle != .overlay {
                    sv.scrollerStyle = .overlay
                }
            }
        }

        sv.scrollerStyle = .overlay
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.contentView.drawsBackground = false
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = .init()
        sv.scrollerInsets = .init()
        sv.verticalScroller?.knobStyle = .default
        sv.horizontalScroller?.knobStyle = .default
    }

    deinit {
        styleObservation?.invalidate()
    }

    override func layout() {
        super.layout()
        configureScrollView()
        // Refit on every layout pass (window resize, initial sizing) until the
        // user manually zooms or pans. Handles SwiftUI delivering tiny initial
        // bounds before settling on the real window size.
        if document != nil, bounds.width > 0, bounds.height > 0, !userHasInteracted {
            fitToWindow()
            hasFittedOnce = true
        }
    }

    func loadDocument(at url: URL) {
        let doc = PDFDocument(url: url)
        document = doc
        hasFittedOnce = false
        userHasInteracted = false
        configureScrollView()
        if bounds.width > 0, bounds.height > 0 {
            fitToWindow()
            hasFittedOnce = true
        }
    }

    func fitToWindow() {
        guard let document, let firstPage = document.page(at: 0) else { return }
        // Use the crop box — that's what PDFKit actually renders, so fitting to
        // the media box would leave the page looking slightly off / zoomed.
        let pageBox = firstPage.bounds(for: .cropBox)
        guard pageBox.width > 0, pageBox.height > 0 else { return }
        // Fit to width: the page fills the viewport width flush to both edges
        // (no gray margins), and you scroll down through the pages. The window
        // is auto-sized to the page's aspect ratio on open, so the whole first
        // page is visible too — but on any other window shape there's still no
        // dark frame, only the gap *between* pages.
        scaleFactor = bounds.width / pageBox.width
        layoutSubtreeIfNeeded()
        snapToPageTop(firstPage)
    }

    /// Scroll so page 1's top-left corner sits at the viewport's top-left,
    /// hiding the top page-break margin PDFKit reserves above the first page
    /// (otherwise it shows as a dark band at the very top). When the page is
    /// narrower than the viewport (wider window), centering keeps it balanced.
    private func snapToPageTop(_ page: PDFPage) {
        guard let scrollView = pdfScrollView, let docView = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let cropBox = page.bounds(for: .cropBox)
        let pageTopInSelf = convert(NSPoint(x: cropBox.minX, y: cropBox.maxY), from: page)
        let pageTopInDoc = docView.convert(pageTopInSelf, from: self)
        let originY = clip.isFlipped ? pageTopInDoc.y : pageTopInDoc.y - clip.bounds.height
        let originX = max(0, (docView.frame.width - clip.bounds.width) / 2)
        clip.setBoundsOrigin(NSPoint(x: originX, y: originY))
        scrollView.reflectScrolledClipView(clip)
    }

    func apply(command: ZoomCommand) {
        switch command {
        case .in:
            zoomAtCenter(factor: 1.25)
        case .out:
            zoomAtCenter(factor: 1.0 / 1.25)
        case .actual:
            zoomAtCenter(targetScale: 1.0)
        case .fit:
            userHasInteracted = false
            fitToWindow()
        }
    }

    func apply(rotation: RotationDirection) {
        guard let document else { return }
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let next = page.rotation + rotation.degrees
            page.rotation = ((next % 360) + 360) % 360
        }
        layoutDocumentView()
        userHasInteracted = false
        fitToWindow()
    }

    func search(query: String) {
        searchMatches.removeAll()
        searchIndex = 0
        guard !query.isEmpty, let document else {
            setCurrentSelection(nil, animate: false)
            onSearchMatchInfoChanged?(.init(index: 0, total: 0))
            return
        }
        searchMatches = document.findString(query, withOptions: .caseInsensitive)
        if searchMatches.isEmpty {
            setCurrentSelection(nil, animate: false)
            onSearchMatchInfoChanged?(.init(index: 0, total: 0))
        } else {
            highlightCurrentSearchMatch()
        }
    }

    func searchNext() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchMatches.count
        highlightCurrentSearchMatch()
    }

    func searchPrevious() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchMatches.count) % searchMatches.count
        highlightCurrentSearchMatch()
    }

    private func highlightCurrentSearchMatch() {
        let selection = searchMatches[searchIndex]
        setCurrentSelection(selection, animate: true)
        scrollSelectionToVisible(nil)
        onSearchMatchInfoChanged?(.init(index: searchIndex + 1, total: searchMatches.count))
    }

    private func zoomAtCenter(factor: CGFloat? = nil, targetScale: CGFloat? = nil) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let target: CGFloat
        if let factor { target = scaleFactor * factor }
        else if let targetScale { target = targetScale }
        else { return }
        zoomToCursor(newScale: target, cursorInSelf: center)
    }

    /// Zoom toward the cursor by anchoring on a PDF page point. We grab the
    /// page point under the cursor (scale-independent), let PDFView change
    /// scaleFactor (which resizes the documentView and may auto-adjust scroll),
    /// then shift the clipView origin so the same page point lands back under
    /// the cursor.
    private func zoomToCursor(newScale: CGFloat, cursorInSelf: NSPoint) {
        let oldScale = scaleFactor
        let clamped = newScale.clamped(to: minScaleFactor...maxScaleFactor)
        guard clamped != oldScale else { return }
        userHasInteracted = true
        guard let page = self.page(for: cursorInSelf, nearest: true) else {
            scaleFactor = clamped
            return
        }
        let pagePoint = self.convert(cursorInSelf, to: page)

        scaleFactor = clamped
        layoutSubtreeIfNeeded()

        let newCursorInSelf = self.convert(pagePoint, from: page)
        let dx = newCursorInSelf.x - cursorInSelf.x
        let dy = newCursorInSelf.y - cursorInSelf.y

        guard let scrollView = pdfScrollView else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x += dx
        if clip.isFlipped == self.isFlipped {
            origin.y += dy
        } else {
            origin.y -= dy
        }
        clip.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func magnify(with event: NSEvent) {
        let cursor = convert(event.locationInWindow, from: nil)
        zoomToCursor(newScale: scaleFactor * (1.0 + event.magnification), cursorInSelf: cursor)
    }

    // MARK: - Hand-tool pan
    //
    // The button + modifier combination is user-configurable via Settings.
    // When the press doesn't match the configured combo we fall through to
    // PDFView's own handlers — that keeps text selection, link clicks, and
    // the right-click context menu working.

    override func mouseDown(with event: NSEvent) {
        if shouldStartPan(event, button: .left) {
            startPan(event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            updatePan(event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            endPan()
        } else {
            super.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if shouldStartPan(event, button: .right) {
            startPan(event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if isPanning {
            updatePan(event)
        } else {
            super.rightMouseDragged(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if isPanning {
            endPan()
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == PanMouseButton.middle.buttonNumber,
           shouldStartPan(event, button: .middle) {
            startPan(event)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if isPanning {
            updatePan(event)
        } else {
            super.otherMouseDragged(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if isPanning {
            endPan()
        } else {
            super.otherMouseUp(with: event)
        }
    }

    /// Right-click would normally summon a context menu. Suppress it when the
    /// right button is the configured pan button — otherwise the menu appears
    /// the moment the user releases.
    override func menu(for event: NSEvent) -> NSMenu? {
        if event.type == .rightMouseDown,
           AppSettings.shared.panMouseButton == .right,
           AppSettings.shared.panModifier.matches(event.modifierFlags) {
            return nil
        }
        return super.menu(for: event)
    }

    private func shouldStartPan(_ event: NSEvent, button: PanMouseButton) -> Bool {
        let settings = AppSettings.shared
        guard button == settings.panMouseButton else { return false }
        return settings.panModifier.matches(event.modifierFlags)
    }

    private func startPan(_ event: NSEvent) {
        guard let scrollView = pdfScrollView else { return }
        isPanning = true
        dragStartLocation = event.locationInWindow
        scrollOriginAtDragStart = scrollView.contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    private func updatePan(_ event: NSEvent) {
        guard let scrollView = pdfScrollView else { return }
        userHasInteracted = true
        let dx = event.locationInWindow.x - dragStartLocation.x
        let dy = event.locationInWindow.y - dragStartLocation.y
        let mag = scrollView.magnification == 0 ? 1 : scrollView.magnification
        var newOrigin = scrollOriginAtDragStart
        newOrigin.x -= dx / mag
        newOrigin.y -= dy / mag
        scrollView.contentView.setBoundsOrigin(newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.flashScrollers()
    }

    private func endPan() {
        isPanning = false
        // Restore the cursor right away based on what's now under the pointer
        // (I-beam over text, openHand/arrow elsewhere). Without this, the
        // closed hand from the drag would persist until the next mouseMoved.
        if let window = window {
            let mouseInWindow = window.mouseLocationOutsideOfEventStream
            applyHoverCursor(at: mouseInWindow)
        }
    }

    var suppressCursor: Bool = false  // unused; kept so the representable API stays stable

    override func keyDown(with event: NSEvent) {
        if let special = event.specialKey {
            switch special {
            case .leftArrow:
                if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                    onNavigate?(.previous)
                    return
                }
            case .rightArrow:
                if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                    onNavigate?(.next)
                    return
                }
            default: break
            }
        }
        super.keyDown(with: event)
    }
}
