import Foundation
import CoreGraphics
import ImageIO
import Vision
import Accelerate

/// 相似图片组中的一个成员
public struct SimilarItem: Identifiable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(url: URL, size: Int64, pixelWidth: Int, pixelHeight: Int) {
        self.url = url
        self.size = size
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// 一组视觉上相似的图片
public struct SimilarGroup: Identifiable {
    public let id: String
    public let items: [SimilarItem]
    /// 组内两两比较的最大特征距离（0 = 完全一致）
    public let maxDistance: Float

    /// 保留最大的一份、删除其余可释放的空间
    public var reclaimable: Int64 {
        guard let largest = items.map(\.size).max() else { return 0 }
        return items.reduce(0) { $0 + $1.size } - largest
    }

    /// 相似度百分比（0–100）。由平方距离单调映射而来，仅用于给用户直观参考。
    /// 距离 0 → 100%；0.34 → 约 75%；0.69 → 约 59%；1.44 → 约 41%。
    public var similarityPercent: Int {
        Int((100.0 / (1.0 + maxDistance)).rounded())
    }

    public init(id: String, items: [SimilarItem], maxDistance: Float) {
        self.id = id
        self.items = items
        self.maxDistance = maxDistance
    }
}

/// 并查集：用于把「A 像 B、B 像 C」的传递关系聚成一组
struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0..<count)
    }

    mutating func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])   // 路径压缩
        }
        return parent[x]
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}

/// 相似图片查找器。
///
/// 技术路线（纯 Apple 原生，零第三方依赖）：
/// 1. 用 `CGImageSource` 生成降采样缩略图，避免解码整张大图；
/// 2. 用 Vision 的 `VNGenerateImageFeaturePrintRequest` 提取特征向量（Apple Silicon 走神经引擎）；
/// 3. 用 Accelerate 的 `vDSP_distancesq` 计算两两欧氏平方距离；
/// 4. 距离低于阈值视为相似，用并查集做传递闭包聚类。
public final class SimilarityFinder {

    public struct Options {
        /// 特征距离阈值（**平方**欧氏距离），越小越严格。默认 0.5。
        ///
        /// 实测标定（256px 降采样，真实照片）：
        /// - 同一张图自比：0.0000
        /// - 同图缩小 50% + JPEG q50：0.34
        /// - 同图缩小 25% + JPEG q30：1.44（已超出可用范围）
        /// - 两张不同的相似照片：0.69 – 1.02
        /// 因此 0.5 能抓到「改尺寸/轻压缩」的副本，又不会把不同照片误判为重复。
        /// 注意：重度降质（低于原尺寸 25% 或 q30 以下）本质上已不像，任何感知哈希都救不回。
        public var threshold: Float
        /// 提取特征前的降采样边长（像素）。默认 256，足够准且快。
        public var maxDimension: CGFloat

        public init(threshold: Float = 0.5, maxDimension: CGFloat = 256) {
            self.threshold = threshold
            self.maxDimension = maxDimension
        }
    }

    /// 支持的图片扩展名
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif",
        "bmp", "webp", "avif", "ico"
    ]

    public init() {}

    /// 递归收集目录下的图片文件（按扩展名过滤）。
    /// - Returns: 图片文件 URL 列表；被取消时返回空数组。
    public func collectImages(
        in roots: [URL],
        skipHidden: Bool = true,
        skipPackageDescendants: Bool = true,
        shouldCancel: (() -> Bool)? = nil,
        onProgress: @escaping (ProgressInfo) -> Void
    ) -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileResourceIdentifierKey
        ]
        var result: [URL] = []
        var scanned = 0
        var skipped = 0
        var seenInodes = Set<AnyHashable>()

        for root in roots {
            if shouldCancel?() == true { return [] }

            var enumOptions: FileManager.DirectoryEnumerationOptions = []
            if skipHidden { enumOptions.insert(.skipsHiddenFiles) }
            if skipPackageDescendants { enumOptions.insert(.skipsPackageDescendants) }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: enumOptions
            ) else {
                skipped += 1      // 根目录本身无法访问（多为权限问题）
                continue
            }

            for case let url as URL in enumerator {
                if scanned % 256 == 0, shouldCancel?() == true { return [] }
                // 先做便宜的扩展名判断，避免对大量非图片文件读属性
                guard Self.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let res = try? url.resourceValues(forKeys: keys) else { skipped += 1; continue }
                if res.isSymbolicLink == true { continue }
                guard res.isRegularFile == true else { continue }

                // 硬链接去重：同一 inode 的多个路径是同一份数据，
                // 若不去重会被判为「相似」，但删掉其中一个并不释放空间（reclaimable 虚报）。
                if let ident = res.fileResourceIdentifier as? any Hashable,
                   !seenInodes.insert(AnyHashable(ident)).inserted { continue }

                result.append(url)
                scanned += 1
                if scanned % 500 == 0 {
                    onProgress(ProgressInfo(
                        phase: .collecting,
                        totalCandidates: 0,
                        hashedCount: 0,
                        scannedCount: scanned,
                        skippedCount: skipped
                    ))
                }
            }
        }
        // 收尾上报一次，确保最终的 skippedCount 能传到 UI
        onProgress(ProgressInfo(
            phase: .collecting,
            totalCandidates: 0,
            hashedCount: 0,
            scannedCount: scanned,
            skippedCount: skipped
        ))
        return result
    }

    /// 在给定文件中查找视觉相似的图片。
    /// - Parameters:
    ///   - urls: 候选图片文件（调用方负责先筛出图片）
    ///   - options: 阈值与降采样配置
    ///   - shouldCancel: 取消判定（后台线程调用）
    ///   - onProgress: 进度回调（后台线程触发）
    public func findSimilar(
        in urls: [URL],
        options: Options = Options(),
        shouldCancel: (() -> Bool)? = nil,
        onProgress: @escaping (ProgressInfo) -> Void
    ) -> [SimilarGroup] {
        let total = urls.count
        guard total >= 2 else { return [] }

        // 1) 提取特征（逐个，可取消）
        var features: [[Float]] = []
        var metas: [SimilarItem] = []
        features.reserveCapacity(total)
        metas.reserveCapacity(total)

        for (index, url) in urls.enumerated() {
            if index % 16 == 0, shouldCancel?() == true { return [] }

            if let item = meta(for: url),
               let vector = featureVector(for: url, maxDimension: options.maxDimension) {
                features.append(vector)
                metas.append(item)
            }

            if index % 20 == 0 || index == total - 1 {
                onProgress(ProgressInfo(
                    phase: .hashing,
                    totalCandidates: total,
                    hashedCount: index + 1,
                    currentFile: url.lastPathComponent
                ))
            }
        }

        guard features.count >= 2 else { return [] }
        if shouldCancel?() == true { return [] }

        // 2) 两两比较 + 并查集聚类（O(n²)，但 vDSP 单次计算很快）
        var uf = UnionFind(count: features.count)
        var pairs = 0
        let totalPairs = features.count * (features.count - 1) / 2

        for i in 0..<features.count {
            if i % 8 == 0, shouldCancel?() == true { return [] }
            for j in (i + 1)..<features.count {
                let d = distance(features[i], features[j])
                if d < options.threshold {
                    uf.union(i, j)
                }
            }
            pairs += features.count - i - 1
            onProgress(ProgressInfo(
                phase: .grouping,
                totalCandidates: totalPairs,
                hashedCount: min(pairs, totalPairs)
            ))
        }

        // 3) 按连通分量汇总
        var buckets: [Int: [Int]] = [:]
        for i in 0..<features.count {
            buckets[uf.find(i), default: []].append(i)
        }

        var groups: [SimilarGroup] = []
        for (_, indices) in buckets where indices.count > 1 {
            let items = indices.map { metas[$0] }
            // 组内最大两两距离，作为该组的“相似程度”参考
            var maxD: Float = 0
            for a in 0..<indices.count {
                for b in (a + 1)..<indices.count {
                    let d = distance(features[indices[a]], features[indices[b]])
                    if d > maxD { maxD = d }
                }
            }
            let id = items.map { $0.url.path }.sorted().joined(separator: "|")
            groups.append(SimilarGroup(id: id, items: items.sorted { $0.size > $1.size }, maxDistance: maxD))
        }

        groups.sort { $0.reclaimable > $1.reclaimable }
        onProgress(ProgressInfo(phase: .done, totalCandidates: total, hashedCount: total))
        return groups
    }

    // MARK: - 调试/标定
    // ⚠️ 非生产路径：仅供阈值标定与基准测试脚本使用（应用内不调用）。
    //    保留它是因为相似度阈值需要靠实测数据来确定，见 Options.threshold 的标定表。
    /// 计算两张图片的特征距离，用于标定阈值或排查误判。返回 nil 表示无法提取特征。
    public func debugDistance(between a: URL, and b: URL) -> Float? {
        guard let fa = featureVector(for: a, maxDimension: 256),
              let fb = featureVector(for: b, maxDimension: 256) else { return nil }
        return distance(fa, fb)
    }

    // MARK: - 特征提取
    /// 读取图片的基础信息（体积、像素尺寸）
    private func meta(for url: URL) -> SimilarItem? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        let size = Int64(values.fileSize ?? 0)
        var w = 0, h = 0
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(
               source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
           ) as? [CFString: Any] {
            w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        }
        return SimilarItem(url: url, size: size, pixelWidth: w, pixelHeight: h)
    }

    /// 用 Vision 提取图片特征向量
    private func featureVector(for url: URL, maxDimension: CGFloat) -> [Float]? {
        guard let cg = downsampledImage(url: url, maxDimension: maxDimension) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
            return observation.floatVector
        } catch {
            return nil
        }
    }

    /// 生成降采样缩略图（不解码整张大图，省内存）
    private func downsampledImage(url: URL, maxDimension: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - 距离
    /// 欧氏平方距离（Accelerate 加速）
    private func distance(_ a: [Float], _ b: [Float]) -> Float {
        let n = vDSP_Length(min(a.count, b.count))
        guard n > 0 else { return Float.greatestFiniteMagnitude }
        var result: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                vDSP_distancesq(pa.baseAddress!, 1, pb.baseAddress!, 1, &result, n)
            }
        }
        return result
    }
}

extension VNFeaturePrintObservation {
    /// 把 Vision 的特征数据转成 Float 数组（兼容 float / double 两种元素类型）
    var floatVector: [Float] {
        let count = elementCount
        var result = [Float]()
        result.reserveCapacity(count)

        switch elementType {
        case .float:
            data.withUnsafeBytes { raw in
                let buffer = raw.bindMemory(to: Float.self)
                result.append(contentsOf: buffer.prefix(count))
            }
        case .double:
            data.withUnsafeBytes { raw in
                let buffer = raw.bindMemory(to: Double.self)
                for value in buffer.prefix(count) { result.append(Float(value)) }
            }
        default:
            // .unspecified 等未知元素类型：无法安全解析，返回空
            return []
        }
        return result
    }
}
