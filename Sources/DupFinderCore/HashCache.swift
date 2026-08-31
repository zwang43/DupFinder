import Foundation
import Darwin

/// 文件哈希缓存：避免重复扫描时反复读取同一批文件。
///
/// 缓存键 = `设备号:inode:体积:修改时间`。用 inode 而非路径，
/// 这样文件被移动或重命名后缓存依然命中（fclones 同样做法）。
/// 同时带上体积与修改时间，可避免 inode 复用导致的误命中。
///
/// 线程安全：内部用 NSLock 保护，可在并发哈希时直接调用。
public final class HashCache {

    private var map: [String: String]
    private let fileURL: URL
    private let lock = NSLock()
    private var isDirty = false

    /// 缓存目录，默认 ~/Library/Caches/DupFinder/
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("DupFinder", isDirectory: true)
    }

    public init(directory: URL? = nil) {
        let dir = directory ?? HashCache.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("hashcache.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.map = decoded
        } else {
            self.map = [:]
        }
    }

    /// 生成缓存键；返回 nil 表示拿不到文件标识（此时不应读写缓存）
    public static func key(for url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec)"
    }

    public func hash(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }

    public func set(hash: String, for key: String) {
        lock.lock()
        map[key] = hash
        isDirty = true
        lock.unlock()
    }

    /// 落盘。扫描结束后调用一次即可。
    public func save() {
        lock.lock()
        guard isDirty else { lock.unlock(); return }
        let snapshot = map
        isDirty = false
        lock.unlock()

        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL)
        }
    }

    /// 清空缓存（用户可在 UI 中触发）
    public func clear() {
        lock.lock()
        map = [:]
        isDirty = true
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }
}
