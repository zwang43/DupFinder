import Foundation

/// 单条文件记录（已确认哈希）。
public struct FileEntry: Identifiable, Hashable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public let hash: String
    public let modified: Date

    public init(url: URL, size: Int64, hash: String, modified: Date) {
        self.url = url
        self.size = size
        self.hash = hash
        self.modified = modified
    }
}

/// 一组内容完全相同的重复文件。
public struct DuplicateGroup: Identifiable {
    public let id: String          // 内容哈希，作为组唯一标识
    public let size: Int64         // 单文件大小
    public let files: [FileEntry]

    /// 可被回收的冗余空间：保留 1 份，其余均为浪费。
    public var wastedSpace: Int64 { size * Int64(max(0, files.count - 1)) }

    public init(id: String, size: Int64, files: [FileEntry]) {
        self.id = id
        self.size = size
        self.files = files
    }
}

/// 扫描阶段，用于进度展示。
public enum ScanPhase: CustomStringConvertible {
    case collecting
    case hashing
    case grouping
    case done

    public var description: String {
        switch self {
        case .collecting: return "正在遍历文件…"
        case .hashing:    return "正在计算哈希…"
        case .grouping:   return "正在分组…"
        case .done:       return "完成"
        }
    }
}

/// 进度快照。
public struct ProgressInfo {
    public var phase: ScanPhase
    public var totalCandidates: Int   // 待哈希文件总数（已通过大小初筛）
    public var hashedCount: Int       // 已完成哈希数
    public var scannedCount: Int      // 收集阶段已扫描文件数
    public var skippedCount: Int      // 因权限等原因无法读取、被跳过的项数
    public var currentFile: String    // 正在处理的文件路径（仅展示用）
    public var stageIndex: Int        // 渐进式哈希当前阶段（从 1 开始，0 表示不适用）
    public var stageCount: Int        // 渐进式哈希总阶段数

    public init(
        phase: ScanPhase,
        totalCandidates: Int,
        hashedCount: Int,
        scannedCount: Int = 0,
        skippedCount: Int = 0,
        currentFile: String = "",
        stageIndex: Int = 0,
        stageCount: Int = 0
    ) {
        self.phase = phase
        self.totalCandidates = totalCandidates
        self.hashedCount = hashedCount
        self.scannedCount = scannedCount
        self.skippedCount = skippedCount
        self.currentFile = currentFile
        self.stageIndex = stageIndex
        self.stageCount = stageCount
    }

    /// 阶段描述，如「阶段 2/3 · 正在计算哈希…」
    public var stageText: String {
        guard stageCount > 0, stageIndex > 0 else { return phase.description }
        return "阶段 \(stageIndex)/\(stageCount) · \(phase.description)"
    }

    public var fraction: Double {
        guard totalCandidates > 0 else { return phase == .done ? 1 : 0 }
        return min(1, Double(hashedCount) / Double(totalCandidates))
    }
}

/// 人类可读的字节数。
public func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    let value = Double(bytes)
    var unit = 0
    var v = value
    while v >= 1024 && unit < units.count - 1 {
        v /= 1024
        unit += 1
    }
    let formatted = unit == 0 ? String(format: "%.0f", v) : String(format: "%.2f", v)
    return "\(formatted) \(units[unit])"
}
