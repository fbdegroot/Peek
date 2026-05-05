import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var dropTarget = false

    private let titleBarHeight: CGFloat = 38
    private let sidebarWidth: CGFloat = 168

    private var searchVisible: Bool {
        model.searchActive && model.activeDocumentIsPDF
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .init(white: 0.22, alpha: 1.0))
                .ignoresSafeArea()

            if let url = model.activeURL {
                Viewer(url: url, model: model)
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
            } else {
                EmptyState(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Drag area on top — full window width, including over the sidebar.
            WindowDragHandle()
                .frame(height: titleBarHeight)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)

            SearchBar(model: model, enabled: searchVisible)
                .padding(.top, titleBarHeight + 6)
                .opacity(searchVisible ? 1 : 0)
                .offset(y: searchVisible ? 0 : -50)
                .allowsHitTesting(searchVisible)
                .animation(.easeOut(duration: 0.2), value: searchVisible)

            if dropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .padding(8)
                    .allowsHitTesting(false)
            }

            // Single Escape handler: closes the search bar when active, otherwise
            // closes the window. Hidden zero-size button so it does not steal
            // focus or pointer events.
            Button("Escape") { model.handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.open(url: url) }
                }
            }
            return true
        }
    }
}

private struct DocumentSidebar: View {
    @Bindable var model: AppModel
    let topInset: CGFloat

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(model.documents) { doc in
                    SidebarItem(
                        doc: doc,
                        isActive: doc.id == model.activeID,
                        onSelect: { model.setActive(doc.id) },
                        onClose: { model.close(doc.id) }
                    )
                }
            }
            .padding(.top, topInset + 6)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }
}

private struct SidebarItem: View {
    let doc: DocumentEntry
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnailView
                    .frame(width: 144, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(isActive ? 0.35 : 0.18),
                            radius: isActive ? 10 : 4,
                            y: isActive ? 4 : 2)

                if hover || isActive {
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .transition(.opacity)
                }
            }

            Text(doc.url.lastPathComponent)
                .lineLimit(2)
                .truncationMode(.middle)
                .font(.system(size: 10.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(.white.opacity(isActive ? 0.95 : 0.55))
                .frame(maxWidth: 144, alignment: .leading)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(isActive ? 0.10 : (hover ? 0.04 : 0)))
        )
        .scaleEffect(isActive ? 1.0 : (hover ? 0.99 : 0.985))
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.12), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onSelect() }
        .task(id: doc.url) {
            thumbnail = await ThumbnailGenerator.generate(for: doc.url)
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
        } else {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.4))
                ProgressView()
                    .scaleEffect(0.6)
                    .progressViewStyle(.circular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var iconName: String {
        switch FilePlaylist.kind(of: doc.url) {
        case .pdf: "doc.text.fill"
        case .image: "photo.fill"
        case .unsupported: "questionmark.square.fill"
        }
    }
}

enum ThumbnailGenerator {
    static func generate(for url: URL) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            let kind = FilePlaylist.kind(of: url)
            let targetSize = CGSize(width: 280, height: 340)
            switch kind {
            case .pdf:
                return renderPDFThumbnail(url: url, targetSize: targetSize)
            case .image:
                return renderImageThumbnail(url: url, targetSize: targetSize)
            case .unsupported:
                return nil
            }
        }.value
    }

    private static func renderPDFThumbnail(url: URL, targetSize: CGSize) -> NSImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let pageBox = page.bounds(for: .mediaBox)
        let scale = min(targetSize.width / pageBox.width, targetSize.height / pageBox.height)
        let pixelW = Int(pageBox.width * scale)
        let pixelH = Int(pageBox.height * scale)
        guard pixelW > 0, pixelH > 0,
              let ctx = CGContext(
                data: nil, width: pixelW, height: pixelH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: pixelW, height: pixelH))
    }

    private static func renderImageThumbnail(url: URL, targetSize: CGSize) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(targetSize.width, targetSize.height) * 2,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}

private struct EmptyState: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.35))
            Text("Drop files or press ⌘O")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
            Button("Open…") { model.presentOpenPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
        }
    }
}

private struct SearchBar: View {
    @Bindable var model: AppModel
    let enabled: Bool
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Zoek in PDF", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { model.searchNext() }
                .cursor(.iBeam)

            if !model.searchQuery.isEmpty {
                Text(matchCounter)
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.searchPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(model.searchMatchInfo.total == 0)

            Button {
                model.searchNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(model.searchMatchInfo.total == 0)

            Button {
                model.closeSearch()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .cursor(.arrow)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .frame(maxWidth: 380)
        .onChange(of: enabled) { _, newValue in
            fieldFocused = newValue
        }
    }

    private var matchCounter: String {
        if model.searchMatchInfo.total == 0 { return "0" }
        return "\(model.searchMatchInfo.index) / \(model.searchMatchInfo.total)"
    }
}

/// Sets the AppKit cursor for the underlying view's bounds via a tracking
/// area. The PDF / image canvas underneath have their own cursorUpdate
/// handlers that fire on every mouse move; their handlers explicitly skip
/// when the cursor is over a sibling view, leaving us to set ours here.
/// Apply an NSCursor while hovering this view. Combines `disableCursorRects`
/// on the window with `NSCursor.push()` so it survives PDFView re-applying its
/// own cursor rects, which `NSCursor.set()` alone can't beat. Pattern from
/// the macOS SwiftUI community (cursor-handling gist + Apple Developer
/// Forums thread on cursor reset behavior).
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active:
                guard NSCursor.current != cursor else { return }
                NSApp.windows.forEach { $0.disableCursorRects() }
                cursor.push()
            case .ended:
                NSCursor.pop()
                NSApp.windows.forEach { $0.enableCursorRects() }
            }
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// Translucent blur background using NSVisualEffectView. Used to give the
/// sidebar a soft, layered look that lets the underlying desktop tint through.
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
