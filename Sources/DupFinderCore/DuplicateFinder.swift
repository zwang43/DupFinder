import Foundation

/// 重复文件查找器（精确哈希比对）。
///
/// 算法：
/// 1. 遍历所有根目录，收集常规文件并记录体积（**按 inode 去重**，硬链接只占一份空间，不算重复）；
/// 2. 按体积分组，体积唯一的文件不可能重复，直接排除（大幅减少哈希量）；
/// 3. 对「体积出现 ≥2 次」的候选文件并发计算 SHA-256（全过程可取消）；
/// 4. 按哈希分组，组内文件数 ≥2 即为重复组。
public final class DuplicateFinder {

    public struct Options {
        /// 小于该体积（字节）的文件直接忽略。默认 1 字节。
        public var minSize: Int64
        /// 跳过隐藏文件/目录。默认 true。
        public var skipHidden: Bool
        /// 跳过常见无意义的庞大目录（node_modules / .git / Library / Caches / DerivedData / .build）。默认 true。
        public var skipCommonJunk: Bool
        /// 是否跳过「包」的内部（.app / .photoslibrary / .framework / .bundle / .xcodeproj 等）。
        /// 默认 **true**：包在逻辑上是一个整体，单独删除其内部文件会破坏该包（App 损坏、照片库异常），
        /// 且包内重复通常没有清理价值。设为 false 则穿透进包内逐个比对。
        public var skipPackageDescendants: Bool
        /// 渐进式哈希的前缀阶段（字节），逐级淘汰后再做最后的全量哈希。
        /// 默认 [16KB, 1MB]。设为空数组可退化为「直接全量哈希」（便于对比测试）。
        public var progressiveSteps: [Int]
        /// 是否启用哈希缓存（默认开启，二次扫描同一批文件可大幅提速）
        public var useCache: Bool
        /// 并发上限；nil 表示按所在卷类型自动决定。
        public var maxConcurrency: Int?

        public init(
            minSize: Int64 = 1,
            skipHidden: Bool = true,
            skipCommonJunk: Bool = true,
            skipPackageDescendants: Bool = true,
            progressiveSteps: [Int] = [16 * 1024, 1024 * 1024],
            useCache: Bool = true,
            maxConcurrency: Int? = nil
        ) {
            self.minSize = minSize
            self.skipHidden = skipHidden
            self.skipCommonJunk = skipCommonJunk
            self.skipPackageDescendants = skipPackageDescendants
            self.progressiveSteps = progressiveSteps
            self.useCache = useCache
            self.maxConcurrency = maxConcurrency
        }
    }

    /// 根据所在卷类型推荐并发度。
    /// 可移动/可弹出卷通常是机械盘，多线程随机读会造成寻道抖动、反而更慢，
    /// 因此降到 2；内置 SSD 则用满核心（上限 8）。rmlint / fclones 采用同样策略。
    private static func recommendedConcurrency(for roots: [URL]) -> Int {
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        for root in roots {
            if let v = try? root.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsEjectableKey]),
               v.volumeIsRemovable == true || v.volumeIsEjectable == true {
                return min(2, cores)
            }
        }
        return min(8, cores)
    }

    private static let junkLeafNames: Set<String> = [
        "node_modules", ".git", "Library", "Caches", "DerivedData", ".build", ".npm", ".cache"
    ]

    // 注意：enumerator 要 Array，resourceValues 要 Set，按需转换。
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileResourceIdentifierKey
    ]

    public init() {}

    /// 在给定根目录中查找重复文件。
    /// - Parameters:
    ///   - roots: 一个或多个待扫描目录。
    ///   - options: 扫描选项。
    ///   - shouldCancel: 取消判定闭包，返回 true 时尽快中止并返回空结果（在后台线程调用）。
    ///   - onProgress: 进度回调（在后台线程触发，调用方需自行切回主线程更新 UI）。
    /// - Returns: 重复文件组，按可节省空间从大到小排序；被取消时返回空数组。
    public func findDuplicates(
        in roots: [URL],
        options: Options = Options(),
        shouldCancel: (() -> Bool)? = nil,
        onProgress: @escaping (ProgressInfo) -> Void
    ) -> [DuplicateGroup] {
        let fm = FileManager.default

        // 1) 收集文件 + 按体积分组
        var sizeMap: [Int64: [URL]] = [:]
        var fileSizes: [URL: Int64] = [:]
        var seenInodes = Set<AnyHashable>()
        var scannedCount = 0
        var skippedCount = 0
        var enumCount = 0

        for root in roots {
            if shouldCancel?() == true { return [] }
            var enumOptions: FileManager.DirectoryEnumerationOptions = []
            if options.skipHidden { enumOptions.insert(.skipsHiddenFiles) }
            if options.skipPackageDescendants { enumOptions.insert(.skipsPackageDescendants) }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(DuplicateFinder.resourceKeys),
                options: enumOptions
            ) else {
                skippedCount += 1   // 根目录本身无法访问（多为权限问题）
                continue
            }

            for case let url as URL in enumerator {
                enumCount += 1
                if enumCount % 256 == 0, shouldCancel?() == true { return [] }

                if options.skipCommonJunk,
                   DuplicateFinder.junkLeafNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let res = try? url.resourceValues(forKeys: DuplicateFinder.resourceKeys) else {
                    skippedCount += 1
                    continue
                }
                if res.isSymbolicLink == true { continue }
                guard res.isRegularFile == true else { continue }

                // 硬链接去重：同一 inode 的多个路径共享一份数据，不构成重复空间浪费。
                // 典型场景：Time Machine 备份卷（Backups.backupdb）大量使用硬链接。
                if let ident = res.fileResourceIdentifier as? any Hashable,
                   !seenInodes.insert(AnyHashable(ident)).inserted {
                    continue
                }

                let size = Int64(res.fileSize ?? 0)
                if size < options.minSize { continue }

                fileSizes[url] = size
                sizeMap[size, default: []].append(url)
                scannedCount += 1

                if scannedCount % 500 == 0 {
                    onProgress(ProgressInfo(
                        phase: .collecting,
                        totalCandidates: 0,
                        hashedCount: 0,
                        scannedCount: scannedCount,
                        skippedCount: skippedCount
                    ))
                }
            }
        }

        if shouldCancel?() == true { return [] }

        // 2) 体积出现 ≥2 次的才是候选（体积唯一的文件不可能重复）
        var activeGroups: [[URL]] = sizeMap.values.filter { $0.count > 1 }
        let candidateTotal = activeGroups.reduce(0) { $0 + $1.count }

        guard candidateTotal >= 2 else {
            onProgress(ProgressInfo(
                phase: .done,
                totalCandidates: 0,
                hashedCount: 0,
                scannedCount: scannedCount,
                skippedCount: skippedCount
            ))
            return []
        }

        // 3) 渐进式哈希：先比小前缀快速淘汰，逐级扩大，最后才全量读取。
        //    这是本工具最核心的性能优化 —— 瓶颈是磁盘 I/O 而非 CPU
        //    （M4 实测 SHA-256 约 2.7 GB/s），所以关键在「少读数据」而非「算得更快」。
        //    思路参考 rmlint 的 progressive hashing。
        let steps = options.progressiveSteps
        let stageCount = steps.count + 1                    // 最后一步为全量
        let cache = options.useCache ? HashCache() : nil
        let batch = max(1, options.maxConcurrency ?? Self.recommendedConcurrency(for: roots))

        let lock = NSLock()
        var hashOf: [URL: String] = [:]      // 每个文件最新一次算出的哈希
        var fullDone: Set<URL> = []          // 已完成全量哈希的（后续阶段直接复用）
        var cancelled = false

        for (index, step) in (steps + [Int.max]).enumerated() {
            let stageIndex = index + 1

            // 本阶段真正需要读盘的文件（更早阶段已全量哈希的直接跳过）
            let todo: [URL] = activeGroups.flatMap { group in
                group.filter { !fullDone.contains($0) }
            }
            let stageTotal = todo.count

            onProgress(ProgressInfo(
                phase: .hashing,
                totalCandidates: stageTotal,
                hashedCount: 0,
                scannedCount: scannedCount,
                skippedCount: skippedCount,
                stageIndex: stageIndex,
                stageCount: stageCount
            ))

            var stageResults: [URL: String] = [:]
            var done = 0
            let reportStride = max(1, stageTotal / 100)

            if stageTotal > 0 {
                // 分批并发：每批 batch 个，批间同步，避免一次性开太多线程抢 I/O
                for start in stride(from: 0, to: stageTotal, by: batch) {
                    if cancelled || shouldCancel?() == true {
                        cancelled = true
                        break
                    }
                    let end = min(start + batch, stageTotal)

                    DispatchQueue.concurrentPerform(iterations: end - start) { k in
                        let url = todo[start + k]
                        let size = fileSizes[url] ?? 0
                        let isFull = size <= step      // 这一步就能覆盖整个文件

                        // 只有全量哈希值得进缓存（前缀哈希没有复用价值）
                        var hash: String?
                        if isFull, let key = HashCache.key(for: url) {
                            hash = cache?.hash(for: key)
                        }
                        if hash == nil {
                            hash = HashEngine.sha256(of: url, maxBytes: step)
                        }
                        guard let hash else { return }

                        if isFull, let key = HashCache.key(for: url) {
                            cache?.set(hash: hash, for: key)
                        }

                        lock.lock()
                        stageResults[url] = hash
                        done += 1
                        let current = done
                        lock.unlock()

                        if current % reportStride == 0 || current == stageTotal {
                            onProgress(ProgressInfo(
                                phase: .hashing,
                                totalCandidates: stageTotal,
                                hashedCount: current,
                                scannedCount: scannedCount,
                                skippedCount: skippedCount,
                                currentFile: url.lastPathComponent,
                                stageIndex: stageIndex,
                                stageCount: stageCount
                            ))
                        }
                    }
                }
            }

            if cancelled {
                cache?.save()
                return []
            }

            // 记录本阶段结果，并更新 hashOf
            for url in todo {
                guard let hash = stageResults[url] else { continue }
                hashOf[url] = hash
                let size = fileSizes[url] ?? 0
                if size <= step { fullDone.insert(url) }
            }

            // 按本阶段哈希重新分组，只保留仍有 ≥2 个成员的组
            var nextGroups: [[URL]] = []
            for group in activeGroups {
                var buckets: [String: [URL]] = [:]
                for url in group {
                    guard let hash = hashOf[url] else { continue }
                    buckets[hash, default: []].append(url)
                }
                for (_, urls) in buckets where urls.count >= 2 {
                    nextGroups.append(urls)
                }
            }
            activeGroups = nextGroups
            if activeGroups.isEmpty { break }
        }

        cache?.save()
        if cancelled { return [] }

        onProgress(ProgressInfo(
            phase: .grouping,
            totalCandidates: candidateTotal,
            hashedCount: candidateTotal,
            scannedCount: scannedCount,
            skippedCount: skippedCount
        ))

        // 4) 组装重复组（此时 activeGroups 内均为全量哈希一致的组）
        var groups: [DuplicateGroup] = []
        for group in activeGroups where group.count > 1 {
            guard let hash = group.first.flatMap({ hashOf[$0] }) else { continue }
            let size = fileSizes[group[0]] ?? 0
            let entries: [FileEntry] = group.map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                return FileEntry(url: url, size: size, hash: hash, modified: modified)
            }
            // 排序：路径更短者优先（通常视为“更正式/更想保留”的位置），便于默认保留其一
            .sorted { $0.url.path.count < $1.url.path.count }
            groups.append(DuplicateGroup(id: hash, size: size, files: entries))
        }

        groups.sort { $0.wastedSpace > $1.wastedSpace }
        onProgress(ProgressInfo(
            phase: .done,
            totalCandidates: candidateTotal,
            hashedCount: candidateTotal,
            scannedCount: scannedCount,
            skippedCount: skippedCount
        ))
        return groups
    }
}
