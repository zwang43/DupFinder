import Foundation
import SwiftUI
import AppKit
import DupFinderCore

/// 扫描模式
enum ScanMode: String, CaseIterable, Identifiable {
    case exact = "精确去重"
    case similar = "相似图片"
    var id: String { rawValue }
}

/// 线程安全的取消令牌，供后台扫描线程读取、主线程写入。
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

@MainActor
final class ScanViewModel: ObservableObject {
    // MARK: - 输入
    @Published var roots: [URL] = []
    @Published var minSizeMB: Double = 1
    /// 扫描模式：精确去重（内容完全相同）/ 相似图片（视觉相似）
    @Published var scanMode: ScanMode = .exact
    /// 相似图片的特征距离阈值（仅相似模式），越大越宽松
    @Published var similarityThreshold: Float = 0.5
    /// 跳过「包」内部（.app / .photoslibrary 等），默认开启。
    /// 关闭后包内文件会单独参与比对，但删除它们可能破坏该包。
    @Published var skipPackageDescendants = true
    /// 是否把隐藏文件也纳入扫描
    @Published var includeHidden = false

    // MARK: - 状态
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var progress: ProgressInfo?
    @Published var statusMessage = "请选择要扫描的文件夹"
    @Published var errorMessage: String?
    @Published var showError = false
    /// 因权限等原因被跳过、未能读取的项数
    @Published var skippedCount = 0

    // MARK: - 删除确认
    @Published var showDeleteConfirm = false

    // MARK: - 参考文件夹保护
    /// 被标记为「参考」的目录：其中的文件永不允许被标记删除。
    /// 借鉴 dupeGuru 的 Reference Folders，从机制上杜绝误删原片。
    @Published var referenceRoots: Set<URL> = []

    // MARK: - 撤销
    /// 最近一次删除的映射：原路径 → 废纸篓中的路径。用于 ⌘Z 撤销。
    private var lastDeletion: [URL: URL] = [:]
    /// 删除前的分组快照，撤销时用于还原结果列表
    private var snapshotExact: [DuplicateGroup] = []
    private var snapshotSimilar: [SimilarGroup] = []
    @Published var canUndo = false

    // MARK: - 结果（精确模式）
    @Published var groups: [DuplicateGroup] = []
    /// 被勾选、准备删除（移入废纸篓）的文件
    @Published var selection: Set<URL> = Set()

    // MARK: - 结果（相似模式）
    @Published var similarGroups: [SimilarGroup] = []
    @Published var similarSelection: Set<URL> = Set()

    /// 展开/收起的分组
    @Published var expanded: Set<String> = Set()

    private var cancelToken: CancelToken?

    // MARK: - 统计
    var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wastedSpace } }
    var similarTotalWasted: Int64 { similarGroups.reduce(0) { $0 + $1.reclaimable } }

    /// 当前勾选删除所能释放的空间（按选中份数 × 单份大小累计）。
    var selectedWasted: Int64 {
        var sum: Int64 = 0
        for g in groups {
            let removable = g.files.filter { selection.contains($0.url) }.count
            sum += g.size * Int64(removable)
        }
        for g in similarGroups {
            for item in g.items where similarSelection.contains(item.url) {
                sum += item.size
            }
        }
        return sum
    }

    var selectedCount: Int { selection.count + similarSelection.count }

    /// 当前模式下是否有结果
    var hasResults: Bool {
        scanMode == .exact ? !groups.isEmpty : !similarGroups.isEmpty
    }

    /// 是否存在「整组副本都被选中」的情况——删除后该文件将彻底消失。
    var wouldDeleteWholeGroup: Bool {
        groups.contains { g in g.files.allSatisfy { selection.contains($0.url) } }
            || similarGroups.contains { g in g.items.allSatisfy { similarSelection.contains($0.url) } }
    }

    // MARK: - 参考文件夹
    /// 切换某个扫描目录的「参考」标记
    func toggleReference(_ url: URL) {
        if referenceRoots.contains(url) {
            referenceRoots.remove(url)
        } else {
            referenceRoots.insert(url)
        }
    }

    /// 该文件是否位于参考文件夹内（受保护，不可删除）
    func isProtected(_ url: URL) -> Bool {
        guard !referenceRoots.isEmpty else { return false }
        let path = url.standardizedFileURL.path
        for root in referenceRoots {
            let rp = root.standardizedFileURL.path
            let prefix = rp.hasSuffix("/") ? rp : rp + "/"
            if path == rp || path.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// 常见的「包」扩展名（目录，但用户视角是一个整体文件）
    static let packageExtensions: Set<String> = [
        "app", "photoslibrary", "framework", "bundle", "xcodeproj", "xcworkspace",
        "playground", "appinstaller", "kext", "plugin", "prefPane", "scpt", "rtfd", "pages", "numbers", "key"
    ]

    /// 选中项里是否包含「包内部」的文件——删除会破坏该包。
    var deletesInsidePackage: Bool {
        selection.contains { url in
            let comps = url.pathComponents
            guard comps.count > 1 else { return false }
            return comps.dropLast().contains { comp in
                ScanViewModel.packageExtensions.contains((comp as NSString).pathExtension.lowercased())
            }
        }
    }

    /// 删除确认弹窗文案
    var deleteConfirmMessage: String {
        var msg = "将移动 \(selectedCount) 个文件到废纸篓，释放约 \(formatBytes(selectedWasted))。\n删除后可从废纸篓恢复。"
        if wouldDeleteWholeGroup {
            msg += "\n\n⚠️ 有分组的全部副本都被选中，删除后这些文件将只剩废纸篓中的副本。"
        }
        if deletesInsidePackage {
            msg += "\n\n⚠️ 选中项包含「包」内部的文件（.app / .photoslibrary 等），删除可能导致该 App 或资料库损坏。"
        }
        if scanMode == .similar {
            msg += "\n\n注意：相似图片判定基于视觉特征，存在误判可能，请确认后再删除。"
        }
        return msg
    }

    // MARK: - 文件夹选择
    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = "选择要扫描的文件夹"
        if panel.runModal() == .OK {
            for url in panel.urls where !roots.contains(url) {
                roots.append(url)
            }
            statusMessage = "已选择 \(roots.count) 个文件夹，点击开始扫描"
        }
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        referenceRoots.remove(url)
    }

    // MARK: - 扫描
    func startScan() {
        guard !roots.isEmpty else {
            presentError("请先选择一个或多个文件夹")
            return
        }
        guard !isScanning else { return }

        let scanRoots = roots
        let minSizeBytes = Int64(max(0, minSizeMB) * 1_000_000)
        let skipPkg = skipPackageDescendants
        let hidden = includeHidden
        let threshold = similarityThreshold
        let token = CancelToken()
        cancelToken = token

        isScanning = true
        groups = []
        similarGroups = []
        selection = Set()
        similarSelection = Set()
        skippedCount = 0
        // 新扫描结果已变化，旧的撤销记录与快照失效
        lastDeletion = [:]
        snapshotExact = []
        snapshotSimilar = []
        canUndo = false
        progress = ProgressInfo(phase: .collecting, totalCandidates: 0, hashedCount: 0)
        statusMessage = ScanPhase.collecting.description

        if scanMode == .exact {
            runExactScan(roots: scanRoots, minSizeBytes: minSizeBytes,
                         skipPkg: skipPkg, hidden: hidden, token: token)
        } else {
            runSimilarScan(roots: scanRoots, threshold: threshold,
                           skipPkg: skipPkg, hidden: hidden, token: token)
        }
    }

    private func runExactScan(roots: [URL], minSizeBytes: Int64,
                              skipPkg: Bool, hidden: Bool, token: CancelToken) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let finder = DuplicateFinder()
            let opts = DuplicateFinder.Options(
                minSize: max(1, minSizeBytes),
                skipHidden: !hidden,
                skipCommonJunk: true,
                skipPackageDescendants: skipPkg
            )
            let result = finder.findDuplicates(
                in: roots,
                options: opts,
                shouldCancel: { token.isCancelled }
            ) { info in
                Task { @MainActor in
                    self?.progress = info
                    self?.skippedCount = info.skippedCount
                    self?.statusMessage = info.phase.description
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.finishScanning(token: token)
                guard !token.isCancelled else { return }
                self.groups = result
                self.applyExactResult(result)
            }
        }
    }

    private func runSimilarScan(roots: [URL], threshold: Float,
                                skipPkg: Bool, hidden: Bool, token: CancelToken) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let finder = SimilarityFinder()
            // 阶段 1：收集图片
            let images = finder.collectImages(
                in: roots,
                skipHidden: !hidden,
                skipPackageDescendants: skipPkg,
                shouldCancel: { token.isCancelled }
            ) { info in
                Task { @MainActor in
                    self?.progress = info
                    self?.skippedCount = info.skippedCount
                    self?.statusMessage = "正在收集图片… 已找到 \(info.scannedCount) 张"
                }
            }
            guard !token.isCancelled else {
                Task { @MainActor in
                    guard let self else { return }
                    self.finishScanning(token: token)
                }
                return
            }

            // 阶段 2：特征提取 + 两两比较聚类
            let groups = finder.findSimilar(
                in: images,
                options: SimilarityFinder.Options(threshold: threshold),
                shouldCancel: { token.isCancelled }
            ) { info in
                Task { @MainActor in
                    self?.progress = info
                    self?.statusMessage = info.phase.description
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.finishScanning(token: token)
                guard !token.isCancelled else { return }
                self.similarGroups = groups
                self.applySimilarResult(groups)
            }
        }
    }

    /// 收尾：统一清理扫描状态
    private func finishScanning(token: CancelToken) {
        isScanning = false
        progress = nil
        cancelToken = nil
        if token.isCancelled {
            groups = []
            similarGroups = []
            statusMessage = "已取消扫描"
        }
    }

    private func applyExactResult(_ result: [DuplicateGroup]) {
        if result.isEmpty {
            statusMessage = skippedCount > 0
                ? "未发现重复文件（有 \(skippedCount) 项因权限无法读取）"
                : "未发现重复文件 🎉"
        } else {
            statusMessage = "发现 \(result.count) 组重复文件"
            expanded = Set(result.prefix(20).map { $0.id })
        }
    }

    private func applySimilarResult(_ result: [SimilarGroup]) {
        if result.isEmpty {
            statusMessage = "未发现相似图片 🎉"
        } else {
            statusMessage = "发现 \(result.count) 组相似图片"
            expanded = Set(result.prefix(20).map { $0.id })
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        cancelToken?.cancel()
        statusMessage = "正在取消…"
    }

    // MARK: - 模式切换
    /// 切换扫描模式。**必须清空两个模式的勾选** —— 否则另一模式的勾选项在当前列表里不可见，
    /// 却仍会被计入「已选 N 项」并被执行删除，等于删掉用户看不见的文件。
    func setScanMode(_ mode: ScanMode) {
        guard mode != scanMode else { return }
        scanMode = mode
        selection.removeAll()
        similarSelection.removeAll()
        progress = nil
        statusMessage = "已切换到「\(mode.rawValue)」模式，点击开始扫描"
    }

    /// 清空哈希缓存（缓存会随扫描增长，给用户一个清理入口）
    func clearHashCache() {
        guard !isScanning else {
            presentError("扫描进行中，无法清空缓存")
            return
        }
        let cache = HashCache()
        let count = cache.count
        cache.clear()
        statusMessage = count > 0 ? "已清空哈希缓存（\(count) 条）" : "哈希缓存为空"
    }

    // MARK: - 选择辅助（精确模式）
    func toggle(_ url: URL) {
        guard !isProtected(url) else {
            presentError("该文件位于「参考文件夹」内，受保护不可删除。\n如需操作，请先取消该文件夹的参考标记。")
            return
        }
        if selection.contains(url) { selection.remove(url) }
        else { selection.insert(url) }
    }

    /// 本组保留一个：优先保留参考文件夹内的那份，否则保留排序最前的（路径最短）。
    func keepOne(in group: DuplicateGroup) {
        let keep = group.files.first { isProtected($0.url) } ?? group.files.first
        guard let keep else { return }
        selection.remove(keep.url)
        for f in group.files where f.url != keep.url && !isProtected(f.url) {
            selection.insert(f.url)
        }
    }

    /// 保留指定文件、删除同组其余（右键菜单用）。
    func keepOneBut(_ file: FileEntry, in group: DuplicateGroup) {
        selection.remove(file.url)
        for f in group.files where f.url != file.url && !isProtected(f.url) {
            selection.insert(f.url)
        }
    }

    /// 本组全部选删除（自动跳过受保护文件）。
    func selectAllInGroup(_ group: DuplicateGroup) {
        for f in group.files where !isProtected(f.url) { selection.insert(f.url) }
    }

    // MARK: - 选择辅助（相似模式）
    func toggleSimilar(_ url: URL) {
        guard !isProtected(url) else {
            presentError("该文件位于「参考文件夹」内，受保护不可删除。\n如需操作，请先取消该文件夹的参考标记。")
            return
        }
        if similarSelection.contains(url) { similarSelection.remove(url) }
        else { similarSelection.insert(url) }
    }

    /// 相似组保留最好的一份（items 已按体积降序，即默认保留最大的那份）
    func keepBest(in group: SimilarGroup) {
        guard let best = group.items.first(where: { !isProtected($0.url) }) else { return }
        similarSelection.remove(best.url)
        for item in group.items where item.url != best.url && !isProtected(item.url) {
            similarSelection.insert(item.url)
        }
    }

    func selectAllInSimilarGroup(_ group: SimilarGroup) {
        for item in group.items where !isProtected(item.url) { similarSelection.insert(item.url) }
    }

    /// 对所有精确组执行「保留一个」
    func keepOneInAllGroups() { for g in groups { keepOne(in: g) } }
    /// 对所有相似组执行「保留最好的一份」
    func keepBestInAllGroups() { for g in similarGroups { keepBest(in: g) } }
    /// 全选所有组
    func selectAllGroups() {
        for g in groups { selectAllInGroup(g) }
        for g in similarGroups { selectAllInSimilarGroup(g) }
    }

    /// 清空所有删除勾选。
    func clearSelection() {
        selection.removeAll()
        similarSelection.removeAll()
    }

    // MARK: - 删除（移动到废纸篓，安全可逆）
    func deleteSelected() {
        let urls = Array(selection) + Array(similarSelection)
        guard !urls.isEmpty else { return }
        guard !isDeleting else { return }

        isDeleting = true
        NSWorkspace.shared.recycle(urls) { [weak self] newURLs, error in
            // newURLs: [原路径: 废纸篓中的新路径] —— 撤销时据此把文件移回原位
            Task { @MainActor in
                guard let self else { return }
                self.isDeleting = false
                if let error {
                    self.presentError("移动到废纸篓失败：\(error.localizedDescription)")
                    return
                }
                // 先快照删除前的分组，撤销时才能把列表一起还原
                self.snapshotExact = self.groups
                self.snapshotSimilar = self.similarGroups

                let removed = Set(urls)
                self.groups = self.groups.compactMap { g -> DuplicateGroup? in
                    let files = g.files.filter { !removed.contains($0.url) }
                    return files.count > 1 ? DuplicateGroup(id: g.id, size: g.size, files: files) : nil
                }
                self.similarGroups = self.similarGroups.compactMap { g -> SimilarGroup? in
                    let items = g.items.filter { !removed.contains($0.url) }
                    return items.count > 1 ? SimilarGroup(id: g.id, items: items, maxDistance: g.maxDistance) : nil
                }
                self.selection.removeAll()
                self.similarSelection.removeAll()
                self.lastDeletion = newURLs
                self.canUndo = !newURLs.isEmpty
                self.statusMessage = "已移动到废纸篓 ✓（⌘Z 可撤销）"
            }
        }
    }

    // MARK: - 撤销删除
    /// 把最近一次删除的文件从废纸篓移回原路径。
    /// 注意：若目标位置已存在同名文件，该项会恢复失败并计入 failed。
    func undoLastDeletion() {
        let mapping = lastDeletion
        guard !mapping.isEmpty else { return }

        var restored = 0
        var failed = 0
        for (original, trashed) in mapping {
            do {
                let dir = original.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: trashed, to: original)
                restored += 1
            } catch {
                failed += 1
            }
        }
        lastDeletion = [:]
        canUndo = false

        if failed == 0 {
            // 全部恢复成功，把结果列表也还原回去（否则文件回来了、列表里却没了）
            groups = snapshotExact
            similarGroups = snapshotSimilar
            statusMessage = "已撤销，恢复 \(restored) 个文件 ✓"
        } else {
            // 部分失败时列表已不可信，保留当前状态并提示重新扫描
            statusMessage = "恢复 \(restored) 个，\(failed) 个失败（可能已不在废纸篓）· 建议重新扫描"
        }
        snapshotExact = []
        snapshotSimilar = []
    }

    // MARK: - 错误
    func presentError(_ msg: String) {
        errorMessage = msg
        showError = true
    }
}
