import AppKit
import QuickLook
import QuickLookUI

/// Quick Look 预览控制器。
///
/// 包装 AppKit 的 `QLPreviewPanel`，让 SwiftUI 能对选中的文件唤起系统预览（空格预览的等价能力）。
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookCoordinator()

    private var urls: [URL] = []

    private override init() { super.init() }

    /// 预览给定文件（可多个，面板内可左右切换）
    func preview(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - QLPreviewPanelDataSource
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0, index < urls.count else { return nil }
        return urls[index] as QLPreviewItem
    }
}
