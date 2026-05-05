import SwiftUI

struct Viewer: View {
    let url: URL
    @Bindable var model: AppModel

    var body: some View {
        // Read model.searchActive here so SwiftUI tracks it as a body
        // dependency. Otherwise NSViewRepresentable.updateNSView won't fire
        // when search toggles, leaving the underlying viewer's cursor handler
        // unaware of the overlay.
        let searchActive = model.searchActive
        switch FilePlaylist.kind(of: url) {
        case .image:
            ImageViewerRepresentable(url: url, model: model, searchActive: searchActive)
        case .pdf:
            PDFViewerRepresentable(url: url, model: model, searchActive: searchActive)
        case .unsupported:
            UnsupportedView(url: url)
        }
    }
}

private struct UnsupportedView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Unsupported file type")
                .font(.title3)
            Text(url.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
