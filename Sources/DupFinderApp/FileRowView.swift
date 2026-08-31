import SwiftUI
import AppKit
import ImageIO
import DupFinderCore

/// 读取图片元信息（像素尺寸）。
enum ImageMeta {
    /// 非图片或读取失败时返回 nil
    static func pixelSize(of url: URL) async -> CGSize? {
        await Task.detached(priority: .utility) { () -> CGSize? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return CGSize(width: w, height: h)
        }.value
    }
}

/// 重复组内的单个文件行。
///
/// 借鉴 dupeGuru 的 Delta Values：与组内参考文件做差异对比（日期差、图片尺寸），
/// 让用户能一眼看出该保留哪一份（例如保留分辨率最高、日期最新的）。
struct FileRowView: View {
    let file: FileEntry
    /// 组内参考文件（默认第一个，用于差异对比）
    let reference: FileEntry
    let isSelected: Bool
    let isProtected: Bool
    let onToggle: () -> Void
    /// 保留这一份、删除同组其余（右键菜单项）
    let onKeepThisOnly: () -> Void

    @State private var pixelSize: CGSize?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var isReference: Bool { file.url == reference.url }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            .buttonStyle(.plain)
            .disabled(isProtected)
            .help(isProtected ? "位于参考文件夹内，受保护不可删除" : "勾选后移动到废纸篓")

            FileThumbView(url: file.url, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
                HStack(spacing: 6) {
                    Text(dateText)
                        .font(.caption)
                        .foregroundStyle(hasDateDelta ? Color.orange : Color.secondary)
                    if let pixelSize {
                        Text("\(Int(pixelSize.width))×\(Int(pixelSize.height))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isReference {
                        tag("参考", color: .green)
                    }
                    if isProtected {
                        tag("受保护 🔒", color: .blue)
                    }
                    if isInsidePackage {
                        tag("包内 ⚠️", color: .orange)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("快速查看") { QuickLookCoordinator.shared.preview([file.url]) }
            Button("保留这一份（删其余）") { onKeepThisOnly() }
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
        .task(id: file.url) {
            // 只对图片读取像素尺寸，避免对非图片文件白跑一次 CGImageSource
            guard SimilarityFinder.imageExtensions.contains(file.url.pathExtension.lowercased()) else { return }
            pixelSize = await ImageMeta.pixelSize(of: file.url)
        }
    }

    // MARK: - 展示细节
    private var iconName: String {
        if isProtected { return "lock.fill" }
        return isSelected ? "checkmark.square.fill" : "square"
    }

    private var iconColor: Color {
        if isProtected { return .blue }
        return isSelected ? .red : .secondary
    }

    /// 与参考文件的日期差（天）
    private var dateDeltaDays: Int {
        guard !isReference else { return 0 }
        return Calendar.current.dateComponents([.day], from: reference.modified, to: file.modified).day ?? 0
    }

    private var hasDateDelta: Bool { !isReference && dateDeltaDays != 0 }

    private var dateText: String {
        let base = Self.dateFmt.string(from: file.modified)
        let days = dateDeltaDays
        if isReference || days == 0 { return base }
        return days > 0 ? "\(base)（晚 \(days) 天）" : "\(base)（早 \(-days) 天）"
    }

    private var isInsidePackage: Bool {
        let comps = file.url.pathComponents
        guard comps.count > 1 else { return false }
        return comps.dropLast().contains {
            ScanViewModel.packageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
