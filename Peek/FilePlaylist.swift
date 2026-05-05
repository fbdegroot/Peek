import Foundation
import UniformTypeIdentifiers

enum FilePlaylist {
    static let supportedTypes: [UTType] = [
        .png, .jpeg, .heic, .webP, .gif, .tiff, .bmp, .svg, .image,
        .pdf
    ]

    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "svg", "pdf"
    ]

    enum FileKind {
        case image, pdf, unsupported
    }

    static func kind(of url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if supportedExtensions.contains(ext) { return .image }
        return .unsupported
    }

    static func scan(folderOf url: URL) -> [URL] {
        let folder = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [url] }

        let files = entries.filter { entry in
            supportedExtensions.contains(entry.pathExtension.lowercased())
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
