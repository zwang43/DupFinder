import SwiftUI
import AppKit
import ImageIO

/// 文件缩略图：图片类型异步生成真实缩略图，其他类型退化为系统图标。
///
/// 使用 `CGImageSource` 直接生成缩略图，避免把整张大图解码进内存。
struct FileThumbView: View {
    let url: URL
    var size: CGFloat = 40

    @State private var image: NSImage?

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif",
        "bmp", "webp", "avif", "ico", "icns"
    ]

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if Self.isImage(url) {
                // 缩略图尚未就绪时的占位
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .task(id: url) { await load() }
    }

    private static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func load() async {
        guard Self.isImage(url) else { return }
        let target = url
        let maxPx = Int(size * 2) // 按 2x 生成，保证 Retina 清晰
        // 后台只产出 CGImage（Sendable 安全），NSImage 在主线程构造
        let cg: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPx
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        await MainActor.run {
            self.image = cg.map { NSImage(cgImage: $0, size: NSSize(width: maxPx, height: maxPx)) }
        }
    }
}
