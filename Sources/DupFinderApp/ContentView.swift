import SwiftUI
import AppKit
import DupFinderCore

struct ContentView: View {
    @EnvironmentObject private var vm: ScanViewModel

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.isScanning {
                progressView
            }
            resultsList
            Divider()
            footer
        }
        .alert("提示", isPresented: $vm.showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .alert("确认移动到废纸篓？", isPresented: $vm.showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("移动 \(vm.selectedCount) 个到废纸篓", role: .destructive) {
                vm.deleteSelected()
            }
        } message: {
            Text(vm.deleteConfirmMessage)
        }
    }

    // MARK: - 头部
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("DupFinder · 本地重复文件清理")
                    .font(.title2.bold())
                Spacer()
                Button(action: vm.addFolders) {
                    Label("添加文件夹", systemImage: "folder.badge.plus")
                }
                .disabled(vm.isScanning)
            }

            // 已选根目录
            if !vm.roots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.roots, id: \.self) { url in
                            let isRef = vm.referenceRoots.contains(url)
                            HStack(spacing: 4) {
                                Image(systemName: isRef ? "shield.fill" : "folder")
                                    .foregroundStyle(isRef ? Color.green : Color.secondary)
                                Text(url.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button(action: { vm.toggleReference(url) }) {
                                    Image(systemName: isRef ? "shield.fill" : "shield")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(isRef ? Color.green : Color.secondary)
                                .help("标记为「参考文件夹」：其中的文件永远不会被删除")
                                Button(action: { vm.removeRoot(url) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(vm.isScanning)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isRef ? Color.green.opacity(0.14) : Color.gray.opacity(0.08),
                                        in: Capsule())
                        }
                    }
                }
                .frame(height: 28)
            }

            optionsSection

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("最小体积")
                    TextField("1", value: $vm.minSizeMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("MB")
                }
                .disabled(vm.isScanning || vm.scanMode == .similar)

                // 扫描模式（切换时 VM 会清空勾选，避免删掉当前列表看不见的文件）
                Picker("", selection: Binding(
                    get: { vm.scanMode },
                    set: { vm.setScanMode($0) }
                )) {
                    ForEach(ScanMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .disabled(vm.isScanning)
                .help("精确去重：内容字节完全相同；相似图片：视觉相似（改尺寸/压缩/不同格式）")

                Button {
                    if vm.isScanning { vm.cancelScan() } else { vm.startScan() }
                } label: {
                    Label(vm.isScanning ? "停止扫描" : "开始扫描",
                          systemImage: vm.isScanning ? "stop.fill" : "magnifyingglass")
                        .frame(minWidth: 100)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!vm.isScanning && vm.roots.isEmpty)

                Text(vm.statusMessage)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding()
    }

    // MARK: - 扫描选项
    private var optionsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("扫描「包」内部（.app / .photoslibrary / .framework 等）", isOn: Binding(
                    get: { !vm.skipPackageDescendants },
                    set: { vm.skipPackageDescendants = !$0 }
                ))
                .help("默认关闭：包是一个逻辑整体，单独删除其内部文件会导致 App 损坏或照片库异常。")

                Toggle("包含隐藏文件", isOn: $vm.includeHidden)
                    .help("如 .DS_Store、以点开头的文件等。")

                if vm.scanMode == .similar {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("相似度阈值")
                            Slider(value: Binding(
                                get: { Double(vm.similarityThreshold) },
                                set: { vm.similarityThreshold = Float($0) }
                            ), in: 0.1...1.5)
                            .frame(width: 200)
                            Text(String(format: "%.2f", vm.similarityThreshold))
                                .font(.caption.monospacedDigit())
                                .frame(width: 36)
                        }
                        Text("阈值越小越严格。默认 0.50 可抓到「改尺寸/轻压缩」的副本；"
                             + "调到 0.9 以上会把看起来像的不同照片也归为一组。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(vm.skipPackageDescendants
                     ? "当前：跳过包内部与隐藏文件，结果更干净也更安全。"
                     : "当前：会穿透进包内部比对，请勿随意删除包内文件。")
                    .font(.caption)
                    .foregroundStyle(vm.skipPackageDescendants ? Color.secondary : Color.orange)

                Divider()
                HStack(spacing: 8) {
                    Button("清空哈希缓存") { vm.clearHashCache() }
                    Text("缓存用于加速二次扫描，位于 ~/Library/Caches/DupFinder/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 4)
        } label: {
            Label("扫描选项", systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .disabled(vm.isScanning)
    }

    // MARK: - 进度
    private var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = vm.progress {
                if p.phase == .collecting {
                    // 收集阶段总量未知，用不确定进度条
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("已扫描 \(p.scannedCount) 个文件…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: p.fraction) {
                        // stageText 会带上渐进式哈希的阶段信息，如「阶段 2/3 · 正在计算哈希…」
                        Text(p.stageText)
                    }
                    .progressViewStyle(.linear)
                    HStack {
                        Text("\(p.hashedCount) / \(p.totalCandidates)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !p.currentFile.isEmpty {
                            Text("· \(p.currentFile)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", p.fraction * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - 结果列表
    private var resultsList: some View {
        Group {
            if !vm.hasResults && !vm.isScanning {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: vm.roots.isEmpty ? "folder.badge.questionmark" : "tray")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text(vm.roots.isEmpty ? "添加文件夹后开始扫描" : vm.statusMessage)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    if vm.roots.isEmpty {
                        Text(vm.scanMode == .exact
                             ? "支持任意文件类型，按内容 SHA-256 精确比对"
                             : "仅扫描图片，按视觉特征找相似（改尺寸 / 重压缩 / 不同格式）")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("添加文件夹") { vm.addFolders() }
                    }
                    if vm.skippedCount > 0 {
                        Text("有 \(vm.skippedCount) 个项目因权限不足未能读取")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            } else {
                List {
                    if vm.scanMode == .exact {
                        ForEach(vm.groups) { group in
                            groupRow(group)
                        }
                    } else {
                        ForEach(vm.similarGroups) { group in
                            similarGroupRow(group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func groupRow(_ group: DuplicateGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { vm.expanded.contains(group.id) },
                set: { expanded in
                    if expanded { vm.expanded.insert(group.id) }
                    else { vm.expanded.remove(group.id) }
                }
            )
        ) {
            ForEach(group.files) { file in
                FileRowView(
                    file: file,
                    reference: group.files[0],
                    isSelected: vm.selection.contains(file.url),
                    isProtected: vm.isProtected(file.url),
                    onToggle: { vm.toggle(file.url) },
                    onKeepThisOnly: { vm.keepOneBut(file, in: group) }
                )
            }
        } label: {
            HStack(spacing: 10) {
                FileThumbView(url: group.files[0].url, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files[0].url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(group.files[0].url.path)
                    HStack(spacing: 6) {
                        Text("\(group.files.count) 份")
                            .foregroundStyle(.orange)
                        Text("·")
                        Text("每份 \(formatBytes(group.size))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if group.files.allSatisfy({ vm.selection.contains($0.url) }) {
                    Text("⚠️ 全选")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.12), in: Capsule())
                }
                Text("可节省 \(formatBytes(group.wastedSpace))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 2)
        }
    }

    /// 相似图片组（items 已按体积降序，第一张即最大的那份）
    private func similarGroupRow(_ group: SimilarGroup) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { vm.expanded.contains(group.id) },
                set: { expanded in
                    if expanded { vm.expanded.insert(group.id) }
                    else { vm.expanded.remove(group.id) }
                }
            )
        ) {
            ForEach(group.items) { item in
                HStack(spacing: 10) {
                    Button(action: { vm.toggleSimilar(item.url) }) {
                        Image(systemName: vm.isProtected(item.url)
                              ? "lock.fill"
                              : (vm.similarSelection.contains(item.url) ? "checkmark.square.fill" : "square"))
                            .foregroundStyle(vm.isProtected(item.url)
                                             ? Color.blue
                                             : (vm.similarSelection.contains(item.url) ? Color.red : Color.secondary))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isProtected(item.url))
                    .help(vm.isProtected(item.url) ? "位于参考文件夹内，受保护不可删除" : "勾选后移动到废纸篓")

                    FileThumbView(url: item.url, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.url.path)
                        HStack(spacing: 6) {
                            Text(formatBytes(item.size))
                            Text("·")
                            Text("\(item.pixelWidth)×\(item.pixelHeight)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if item.url == group.items[0].url {
                        Text("建议保留")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("快速查看") { QuickLookCoordinator.shared.preview([item.url]) }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                FileThumbView(url: group.items[0].url, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.items[0].url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("\(group.items.count) 张")
                            .foregroundStyle(.orange)
                        Text("·")
                        Text("相似度 \(group.similarityPercent)%")
                        Text("·")
                        Text("距离 \(String(format: "%.2f", group.maxDistance))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if group.items.allSatisfy({ vm.similarSelection.contains($0.url) }) {
                    Text("⚠️ 全选")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.12), in: Capsule())
                }
                Text("可节省 \(formatBytes(group.reclaimable))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }
            .padding(.vertical, 2)
        }
    }

    // 文件行已抽离为 FileRowView（含与参考文件的差异对比、受保护标记、Quick Look）

    // MARK: - 底部
    private var footer: some View {
        HStack(spacing: 10) {
            if vm.hasResults {
                Button(vm.scanMode == .exact ? "每组保留一个" : "每组保留最佳") {
                    if vm.scanMode == .exact { vm.keepOneInAllGroups() }
                    else { vm.keepBestInAllGroups() }
                }
                .help(vm.scanMode == .exact
                      ? "每组保留路径最短的一份，其余标记删除"
                      : "每组保留体积最大的一份（通常画质最好），其余标记删除")
                Button("全选") { vm.selectAllGroups() }
                Button("清空选择") { vm.clearSelection() }
                    .disabled(vm.selectedCount == 0)
            }
            if vm.canUndo {
                Button("撤销删除") { vm.undoLastDeletion() }
                    .help("把最近一次删除的文件从废纸篓移回原位置（⌘Z）")
            }
            if vm.selectedCount > 0 {
                Button("快速查看") {
                    QuickLookCoordinator.shared.preview(Array(vm.selection) + Array(vm.similarSelection))
                }
            }
            Spacer()
            if vm.selectedCount > 0 {
                Text("已选 \(vm.selectedCount) 项 · 可释放 \(formatBytes(vm.selectedWasted))")
                    .foregroundStyle(.secondary)
            } else if vm.hasResults {
                let total = vm.scanMode == .exact ? vm.totalWasted : vm.similarTotalWasted
                Text("总计可节省 \(formatBytes(total))")
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                vm.showDeleteConfirm = true
            } label: {
                Label("移动到废纸篓 (\(vm.selectedCount))", systemImage: "trash")
            }
            .disabled(vm.selectedCount == 0 || vm.isDeleting)
            .keyboardShortcut(.delete, modifiers: [])
        }
        .padding()
    }
}
