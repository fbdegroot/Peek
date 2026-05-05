import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImageViewerRepresentable: NSViewRepresentable {
    let url: URL
    let model: AppModel
    let searchActive: Bool

    func makeNSView(context: Context) -> ImageCanvasView {
        let view = ImageCanvasView()
        view.onNavigate = { [weak model] direction in
            model?.navigate(direction)
        }
        view.loadImage(from: url)
        return view
    }

    func updateNSView(_ nsView: ImageCanvasView, context: Context) {
        if context.coordinator.lastURL != url {
            nsView.loadImage(from: url)
            context.coordinator.lastURL = url
            context.coordinator.lastZoomToken = nil
            context.coordinator.lastRotationToken = nil
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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastURL: URL?
        var lastZoomToken: AppModel.ZoomCommandToken?
        var lastRotationToken: AppModel.RotationCommandToken?
    }
}

final class ImageCanvasView: NSView {
    private let imageLayer = CALayer()
    private var cgImage: CGImage?
    private var originalCGImage: CGImage?
    private var originalSize: CGSize = .zero
    private var rotation: Int = 0
    private var imageSize: CGSize = .zero
    private var zoomScale: CGFloat = 1.0
    private var contentOffset: CGPoint = .zero
    private let minZoom: CGFloat = 0.05
    private let maxZoom: CGFloat = 64.0
    private var hasFittedOnce = false

    private var isDragging = false
    private var dragStartLocation: NSPoint = .zero
    private var offsetAtDragStart: CGPoint = .zero
    private var userHasInteracted = false

    var onNavigate: ((NavigationDirection) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = CALayer()
        root.backgroundColor = NSColor(white: 0.22, alpha: 1.0).cgColor
        // Clip the image layer to the view's bounds — without this the
        // layer renders past the view's edges and visually overlaps siblings
        // like the sidebar.
        root.masksToBounds = true
        layer = root

        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
            "transform": NSNull(), "contents": NSNull(),
        ]
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    override func layout() {
        super.layout()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        // Refit on every layout pass (window resize, initial sizing) until
        // the user manually zooms or pans. This handles SwiftUI delivering
        // tiny initial bounds before settling on the real window size.
        if imageSize != .zero, bounds.width > 0, bounds.height > 0, !userHasInteracted {
            fitToWindow(animated: false)
        }
        updateLayerFrame()
    }

    func loadImage(from url: URL) {
        let img = Self.loadCGImage(at: url)
        let size = img.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        originalCGImage = img
        originalSize = size
        rotation = 0
        setCGImage(img, displaySize: size)
    }

    /// Use a CGImage with a custom display size (the size the image should
    /// occupy in unscaled view units). Useful when the CGImage is rendered at
    /// a higher resolution than the intended display size — e.g. PDF pages
    /// rendered at 2× for retina sharpness.
    func setCGImage(_ image: CGImage?, displaySize: CGSize) {
        cgImage = image
        imageSize = displaySize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
        userHasInteracted = false
        if bounds.width > 0, bounds.height > 0 {
            fitToWindow(animated: false)
        }
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldAllowFloat: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    private func updateLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(
            x: contentOffset.x,
            y: contentOffset.y,
            width: imageSize.width * zoomScale,
            height: imageSize.height * zoomScale
        )
        if zoomScale >= 1.0 {
            imageLayer.magnificationFilter = .nearest
        } else {
            imageLayer.magnificationFilter = .trilinear
        }
        CATransaction.commit()
    }

    private func setZoom(_ newZoom: CGFloat, anchor anchorPoint: NSPoint) {
        let clamped = newZoom.clamped(to: minZoom...maxZoom)
        guard clamped != zoomScale else { return }
        let contentX = (anchorPoint.x - contentOffset.x) / zoomScale
        let contentY = (anchorPoint.y - contentOffset.y) / zoomScale
        zoomScale = clamped
        contentOffset.x = anchorPoint.x - contentX * zoomScale
        contentOffset.y = anchorPoint.y - contentY * zoomScale
        clampContentOffset()
        userHasInteracted = true
        updateLayerFrame()
    }

    /// Keep the image edges from drifting past the viewport edges.
    /// Mirrors PDFView's PeekClipView clamping logic so images and PDFs
    /// behave identically.
    private func clampContentOffset() {
        guard imageSize != .zero else { return }
        let scaledW = imageSize.width * zoomScale
        let scaledH = imageSize.height * zoomScale

        if scaledW >= bounds.width {
            // Image larger than viewport: image must extend past viewport in x.
            contentOffset.x = max(bounds.width - scaledW, min(0, contentOffset.x))
        } else {
            // Image fits: position must keep it inside viewport.
            contentOffset.x = max(0, min(bounds.width - scaledW, contentOffset.x))
        }
        if scaledH >= bounds.height {
            contentOffset.y = max(bounds.height - scaledH, min(0, contentOffset.y))
        } else {
            contentOffset.y = max(0, min(bounds.height - scaledH, contentOffset.y))
        }
    }

    func fitToWindow(animated: Bool) {
        guard imageSize != .zero, bounds.width > 0, bounds.height > 0 else { return }
        // Scale down to fit in viewport (preserving aspect), but never upscale
        // small images — that would just produce a blurry result. User can
        // explicitly zoom in via Cmd+scroll if they want.
        let widthScale = bounds.width / imageSize.width
        let heightScale = bounds.height / imageSize.height
        zoomScale = min(widthScale, heightScale, 1.0).clamped(to: minZoom...maxZoom)
        // Anchor at top-left: in unflipped self coords, image's bottom-left is at
        // contentOffset; image's top-left = contentOffset.y + scaledHeight = bounds.height.
        contentOffset.x = 0
        contentOffset.y = bounds.height - imageSize.height * zoomScale
        updateLayerFrame()
    }

    func apply(command: ZoomCommand) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        switch command {
        case .in:     setZoom(zoomScale * 1.25, anchor: center)
        case .out:    setZoom(zoomScale / 1.25, anchor: center)
        case .actual: actualSize()
        case .fit:
            userHasInteracted = false
            fitToWindow(animated: true)
        }
    }

    func apply(rotation direction: RotationDirection) {
        guard let original = originalCGImage else { return }
        rotation = ((rotation + direction.degrees) % 360 + 360) % 360
        let rotated = Self.rotate(image: original, byDegrees: rotation)
        let newSize: CGSize = (rotation % 180 == 0)
            ? originalSize
            : CGSize(width: originalSize.height, height: originalSize.width)
        cgImage = rotated
        imageSize = newSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = rotated
        CATransaction.commit()
        userHasInteracted = false
        if bounds.width > 0, bounds.height > 0 {
            fitToWindow(animated: false)
        }
    }

    /// Rotate a CGImage clockwise by `degrees` (must be a multiple of 90).
    /// Returns a fresh image with swapped dimensions for 90/270.
    private static func rotate(image: CGImage, byDegrees degrees: Int) -> CGImage? {
        if degrees == 0 { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let radians = -CGFloat(degrees) * .pi / 180  // CGContext rotates CCW; negate for clockwise.
        let outSize: CGSize = (degrees % 180 == 0) ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard let ctx = CGContext(
            data: nil,
            width: Int(outSize.width),
            height: Int(outSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.translateBy(x: outSize.width / 2, y: outSize.height / 2)
        ctx.rotate(by: radians)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    private func actualSize() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        setZoom(1.0, anchor: center)
    }

    override func scrollWheel(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        if AppSettings.shared.zoomModifier.matches(event.modifierFlags) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            let factor = pow(1.0015, delta)
            setZoom(zoomScale * factor, anchor: mouseInView)
            return
        }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: invert direction so wheel-forward scrolls content up.
            dx *= -16
            dy *= -16
        }
        contentOffset.x += dx
        contentOffset.y += dy
        clampContentOffset()
        updateLayerFrame()
    }

    override func magnify(with event: NSEvent) {
        let mouseInView = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + event.magnification
        setZoom(zoomScale * factor, anchor: mouseInView)
    }

    override func mouseDown(with event: NSEvent) {
        handlePanMouseDown(event, button: .left)
    }

    override func mouseDragged(with event: NSEvent) {
        handlePanMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        handlePanMouseUp()
    }

    override func rightMouseDown(with event: NSEvent) {
        handlePanMouseDown(event, button: .right)
    }

    override func rightMouseDragged(with event: NSEvent) {
        handlePanMouseDragged(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        handlePanMouseUp()
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == PanMouseButton.middle.buttonNumber {
            handlePanMouseDown(event, button: .middle)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        handlePanMouseDragged(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        handlePanMouseUp()
    }

    private func handlePanMouseDown(_ event: NSEvent, button: PanMouseButton) {
        let settings = AppSettings.shared
        guard button == settings.panMouseButton,
              settings.panModifier.matches(event.modifierFlags) else { return }
        window?.makeFirstResponder(self)
        isDragging = true
        dragStartLocation = event.locationInWindow
        offsetAtDragStart = contentOffset
        NSCursor.closedHand.set()
    }

    private func handlePanMouseDragged(_ event: NSEvent) {
        guard isDragging else { return }
        let dx = event.locationInWindow.x - dragStartLocation.x
        let dy = event.locationInWindow.y - dragStartLocation.y
        contentOffset.x = offsetAtDragStart.x + dx
        contentOffset.y = offsetAtDragStart.y + dy
        clampContentOffset()
        userHasInteracted = true
        updateLayerFrame()
    }

    private func handlePanMouseUp() {
        guard isDragging else { return }
        isDragging = false
        if AppSettings.shared.panMouseButton == .left {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    var suppressCursor: Bool = false  // unused; kept so the representable API stays stable

    override func keyDown(with event: NSEvent) {
        if let special = event.specialKey {
            switch special {
            case .leftArrow:
                onNavigate?(.previous); return
            case .rightArrow:
                onNavigate?(.next); return
            default: break
            }
        }
        if event.charactersIgnoringModifiers == " " {
            onNavigate?(.next)
            return
        }
        super.keyDown(with: event)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
