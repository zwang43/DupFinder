#!/usr/bin/env bash
# DupFinder 构建脚本
# 用法：
#   ./build.sh          # release 编译并打包 DupFinder.app
#   ./build.sh smoke    # 运行核心逻辑冒烟测试（inode 去重 / 分组 / 取消）
#
# 说明：本机 SwiftPM 编译 manifest 时会被 sandbox-exec 拦截（嵌套沙箱不允许），
# 因此统一加 --disable-sandbox。源文件由 Package.swift 自动收集，无需手工维护列表。
set -e
cd "$(dirname "$0")"

if [ "${1:-}" = "smoke" ]; then
    echo "▶ 运行核心逻辑冒烟测试…"
    SMOKE_DIR=$(mktemp -d)
    cat > "$SMOKE_DIR/driver.swift" <<'DRIVER'
import Foundation
import CoreGraphics
import ImageIO
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    if cond { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
}

// 生成测试图。style=0 横向条带（默认）；style=1 纵向条带；style=2 纯色+单个大圆。
// 不同 style 的构图差异足够大，用于验证「不同的图不会被误判为相似」。
func makePNG(path: String, width: Int, height: Int, seed: Int, style: Int = 0) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    var rng = seed
    func next() -> CGFloat { rng = (rng &* 1103515245 &+ 12345) & 0x7fffffff; return CGFloat(rng % 1000) / 1000.0 }

    if style == 2 {
        // 纯色背景 + 一个居中大圆：构图极简，与条带图差异明显
        ctx.setFillColor(red: 0.02, green: 0.02, blue: 0.12, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 0.98, green: 0.95, blue: 0.85, alpha: 1)
        let s = CGFloat(min(width, height)) * 0.7
        ctx.fillEllipse(in: CGRect(x: (CGFloat(width) - s)/2, y: (CGFloat(height) - s)/2, width: s, height: s))
    } else {
        // 条带方向：0 横向 / 1 纵向
        let bands = 6
        for i in 0..<bands {
            ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
            let rect = style == 0
                ? CGRect(x: 0, y: CGFloat(i) * CGFloat(height)/CGFloat(bands), width: CGFloat(width), height: CGFloat(height)/CGFloat(bands))
                : CGRect(x: CGFloat(i) * CGFloat(width)/CGFloat(bands), y: 0, width: CGFloat(width)/CGFloat(bands), height: CGFloat(height))
            ctx.fill(rect)
        }
        for _ in 0..<12 {
            ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 0.9)
            let x = next() * CGFloat(width) * 0.8, y = next() * CGFloat(height) * 0.8
            let s = (0.05 + next() * 0.2) * CGFloat(min(width, height))
            if next() > 0.5 { ctx.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s)) }
            else { ctx.fill(CGRect(x: x, y: y, width: s, height: s)) }
        }
    }

    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    _ = CGImageDestinationFinalize(dest)
}

let base = "/tmp/dupfinder_smoke"
try? FileManager.default.removeItem(atPath: base)
try? FileManager.default.createDirectory(atPath: base + "/sub", withIntermediateDirectories: true)
FileManager.default.createFile(atPath: base + "/a.txt", contents: Data("hello world".utf8))
FileManager.default.createFile(atPath: base + "/b.txt", contents: Data("hello world".utf8))
FileManager.default.createFile(atPath: base + "/sub/c.txt", contents: Data("hello world".utf8))
FileManager.default.createFile(atPath: base + "/uniq.txt", contents: Data("unique".utf8))
FileManager.default.createFile(atPath: base + "/orig.bin", contents: Data(repeating: 7, count: 4096))
_ = link(base + "/orig.bin", base + "/hardlink.bin")   // 硬链接，共享 inode

let finder = DuplicateFinder()
let groups = finder.findDuplicates(in: [URL(fileURLWithPath: base)], shouldCancel: nil) { _ in }

let hello = groups.first { $0.files.contains { $0.url.lastPathComponent == "a.txt" } }
check(hello != nil, "相同内容的 3 个文件聚为一组")
check(hello?.files.count == 3, "组内 3 份（实际 \(hello?.files.count ?? 0)）")
check(hello?.wastedSpace == 22, "可节省空间 11×2=22（实际 \(hello?.wastedSpace ?? -1)）")
check(!groups.contains { $0.files.contains { $0.url.lastPathComponent == "uniq.txt" } },
      "唯一文件不被误报")
check(!groups.contains { $0.files.contains { $0.url.lastPathComponent == "hardlink.bin" } },
      "硬链接不算重复（inode 去重生效）")

let cancelled = finder.findDuplicates(
    in: [URL(fileURLWithPath: base)],
    shouldCancel: { true }
) { _ in }
check(cancelled.isEmpty, "取消后立即返回空结果")

// 包（package）处理验证
FileManager.default.createFile(atPath: base + "/outside.txt", contents: Data("pkg test content".utf8))
try? FileManager.default.createDirectory(atPath: base + "/Test.app", withIntermediateDirectories: true)
FileManager.default.createFile(atPath: base + "/Test.app/inside.txt", contents: Data("pkg test content".utf8))

let withSkip = finder.findDuplicates(
    in: [URL(fileURLWithPath: base)],
    options: DuplicateFinder.Options(skipPackageDescendants: true),
    shouldCancel: nil
) { _ in }
check(withSkip.first { $0.files.contains { $0.url.lastPathComponent == "outside.txt" } } == nil,
      "默认跳过包内部：.app 内文件不参与比对")

let intoPkg = finder.findDuplicates(
    in: [URL(fileURLWithPath: base)],
    options: DuplicateFinder.Options(skipPackageDescendants: false),
    shouldCancel: nil
) { _ in }
let pkgGroup = intoPkg.first { $0.files.contains { $0.url.lastPathComponent == "outside.txt" } }
check(pkgGroup?.files.count == 2,
      "关闭跳过后包内文件参与比对（实际 \(pkgGroup?.files.count ?? 0)）")

try? FileManager.default.removeItem(atPath: base)

// ===== 渐进式哈希正确性（关键边界）=====
// 若两个大文件「前缀相同但尾部不同」，绝不能被判为重复。
let bigBase = "/tmp/dupfinder_big"
try? FileManager.default.removeItem(atPath: bigBase)
try? FileManager.default.createDirectory(atPath: bigBase, withIntermediateDirectories: true)
let head1MB = [UInt8](repeating: 0x11, count: 1024 * 1024)
let tailA = [UInt8](repeating: 0xAA, count: 1024 * 1024)
let tailB = [UInt8](repeating: 0xBB, count: 1024 * 1024)
FileManager.default.createFile(atPath: bigBase + "/big_a.bin", contents: Data(head1MB + tailA))
FileManager.default.createFile(atPath: bigBase + "/big_b.bin", contents: Data(head1MB + tailB))       // 仅尾部不同
FileManager.default.createFile(atPath: bigBase + "/big_a_copy.bin", contents: Data(head1MB + tailA))  // 与 a 完全相同

let bigGroups = finder.findDuplicates(
    in: [URL(fileURLWithPath: bigBase)],
    options: DuplicateFinder.Options(),
    shouldCancel: nil
) { _ in }
check(bigGroups.count == 1, "前 1MB 相同但尾部不同的大文件未被误判（实际 \(bigGroups.count) 组）")
check(bigGroups.first?.files.count == 2, "仅完全相同的两份成组（实际 \(bigGroups.first?.files.count ?? 0)）")

// 缓存开启时二次扫描结果应保持一致
let bigGroups2 = finder.findDuplicates(
    in: [URL(fileURLWithPath: bigBase)],
    options: DuplicateFinder.Options(),
    shouldCancel: nil
) { _ in }
check(bigGroups2.count == bigGroups.count, "启用缓存后二次扫描结果一致")

// 关闭渐进式（直接全量哈希）结果应完全一致
let bigGroupsNoProg = finder.findDuplicates(
    in: [URL(fileURLWithPath: bigBase)],
    options: DuplicateFinder.Options(progressiveSteps: [], useCache: false),
    shouldCancel: nil
) { _ in }
check(bigGroupsNoProg.count == bigGroups.count, "关闭渐进式哈希后结果一致")

try? FileManager.default.removeItem(atPath: bigBase)

// ===== 相似图片检测 =====
let simBase = "/tmp/dupfinder_sim"
try? FileManager.default.removeItem(atPath: simBase)
try? FileManager.default.createDirectory(atPath: simBase, withIntermediateDirectories: true)
makePNG(path: simBase + "/orig_800.png", width: 800, height: 600, seed: 42, style: 0)
makePNG(path: simBase + "/half_400.png", width: 400, height: 300, seed: 42, style: 0)  // 同内容缩小 → 应相似
makePNG(path: simBase + "/other.png", width: 800, height: 600, seed: 777, style: 2)    // 完全不同构图 → 不应归组

let simFinder = SimilarityFinder()
let images = simFinder.collectImages(in: [URL(fileURLWithPath: simBase)], shouldCancel: nil) { _ in }
check(images.count == 3, "收集到 3 张图片（实际 \(images.count)）")

let simGroups = simFinder.findSimilar(
    in: images,
    options: SimilarityFinder.Options(threshold: 0.5),
    shouldCancel: nil
) { _ in }
check(simGroups.count == 1, "缩略版与原图聚为 1 组（实际 \(simGroups.count)）")
check(simGroups.first?.items.count == 2, "组内 2 张（实际 \(simGroups.first?.items.count ?? 0)）")
let groupHasOther = simGroups.first?.items.contains { $0.url.lastPathComponent == "other.png" } ?? false
check(!groupHasOther, "内容不同的图片未被误判为相似")
check((simGroups.first?.similarityPercent ?? 0) >= 90,
      "相似度百分比合理（实际 \(simGroups.first?.similarityPercent ?? 0)%）")

// 取消应返回空
let simCancelled = simFinder.findSimilar(in: images, shouldCancel: { true }) { _ in }
check(simCancelled.isEmpty, "相似扫描可取消")

try? FileManager.default.removeItem(atPath: simBase)
print(failures == 0 ? "\n✅ 冒烟测试全部通过" : "\n❌ \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
DRIVER
    # 单文件编译模式才允许顶层语句，故合并 Core 源码 + driver
    cat Sources/DupFinderCore/*.swift "$SMOKE_DIR/driver.swift" > "$SMOKE_DIR/all.swift"
    swiftc -target arm64-apple-macosx13.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        -O "$SMOKE_DIR/all.swift" -o "$SMOKE_DIR/run" 2>&1 | tail -20
    "$SMOKE_DIR/run"
    smoke_exit=$?
    rm -rf "$SMOKE_DIR"
    exit $smoke_exit
fi

echo "▶ 编译中（release）…"
swift build --disable-sandbox -c release 2>&1 | tail -20

# 打包成可双击的 .app
APP="DupFinder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DupFinder "$APP/Contents/MacOS/DupFinder"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DupFinder</string>
    <key>CFBundleDisplayName</key><string>DupFinder</string>
    <key>CFBundleIdentifier</key><string>com.local.dupfinder</string>
    <key>CFBundleExecutable</key><string>DupFinder</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "✅ 构建完成"
echo "   双击 $APP 运行，或终端执行：open $APP"
