import Foundation
import CommonCrypto

/// 文件内容哈希引擎。默认使用 SHA-256（精确、可靠、零误判）。
public enum HashEngine {

    // MARK: - 诊断统计（默认关闭，关闭时无额外开销）
    // ⚠️ 非生产路径：仅供基准测试脚本统计真实读取字节数（应用内从未开启）。
    //    存在的理由：本机 16GB 内存下页缓存会掩盖磁盘 I/O，计时完全不可信
    //    （曾测出 0.01s 的无意义结果），只有统计实际读取字节数才能衡量优化效果。
    /// 开启后累计实际读取的字节数，用于验证渐进式哈希的 I/O 优化效果。
    public static var trackBytesRead = false
    private static let statsLock = NSLock()
    private static var _bytesRead: Int = 0

    public static var bytesRead: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return _bytesRead
    }

    public static func resetStats() {
        statsLock.lock(); _bytesRead = 0; statsLock.unlock()
    }

    private static func addBytesRead(_ n: Int) {
        guard trackBytesRead else { return }
        statsLock.lock(); _bytesRead += n; statsLock.unlock()
    }

    /// 计算文件 SHA-256 的十六进制字符串。读取失败时返回 nil。
    /// 流式分块读取，避免一次性把大文件读进内存。
    ///
    /// - Parameter maxBytes: 最多读取的字节数（渐进式哈希用）。默认读取整个文件。
    ///   M4 实测 SHA-256 吞吐约 2.7 GB/s，CPU 几乎不是瓶颈，
    ///   真正的优化空间在于**少读数据**，所以这个参数很关键。
    public static func sha256(of url: URL, maxBytes: Int = Int.max) -> String? {
        let path = url.path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)

        let bufferSize = 1 << 16 // 64 KB
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var totalRead: Int = 0
        var bytesRead: Int
        repeat {
            let toRead = min(bufferSize, maxBytes - totalRead)
            if toRead <= 0 { break }
            bytesRead = read(fd, buffer, toRead)
            if bytesRead > 0 {
                CC_SHA256_Update(&ctx, buffer, CC_LONG(bytesRead))
                totalRead += bytesRead
                addBytesRead(bytesRead)
            } else if bytesRead < 0 {
                return nil
            }
        } while bytesRead > 0 && totalRead < maxBytes

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
