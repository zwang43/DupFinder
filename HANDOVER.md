# DupFinder 接手文档

> 面向接手开发的模型/开发者。读完本文应能直接继续开发，无需重新探索代码。
> 最后更新：2026-08-31

---

## 1. 项目定位

**DupFinder** —— macOS 原生 SwiftUI 的**本地重复文件清理工具**，自用为主，不上架 App Store。

- 目标用户：本人（macOS M4 / 16GB，有照片库、车模/F1 资料库）
- 核心场景：清理本地磁盘重复文件，重点在**照片库去重**
- 设计原则：**安全优先**（删除一律可逆）、本地离线、零第三方依赖

### 明确不做
- 不接入任何网络/云服务/遥测
- 不做付费开发者账号相关（不签名、不公证、不上架）
- 不做「磁盘清理套件」路线（暂不实现空文件夹/临时文件/损坏文件/大文件 TOP-N，即原计划 D 已否决）

---

## 2. 技术栈与环境

| 项 | 值 |
|---|---|
| 语言 | Swift 5（Swift 6.3.3 工具链，**语言模式为 Swift 5，非严格并发**） |
| UI | SwiftUI（macOS 13+） |
| 构建 | SwiftPM + `build.sh` 封装 |
| 最低系统 | macOS 13 Ventura |
| 依赖 | 零第三方。系统框架：Foundation / AppKit / SwiftUI / CommonCrypto / ImageIO |

### ⚠️ 环境关键坑（必读）

1. **`swift build` 必须加 `--disable-sandbox`**
   本机 SwiftPM 编译 manifest 时会调用 `sandbox-exec`，而当前环境不允许嵌套沙箱，报
   `sandbox-exec: sandbox_apply: Operation not permitted`。
   `build.sh` 已封装该参数。**任何时候不要裸跑 `swift build`。**

2. **本机只有 CommandLineTools，没有完整 Xcode.app**
   `xcodebuild -version` 输出为空属正常。`swiftc` / `swift build` 均可用，能编译链接 SwiftUI/AppKit 并手工打包 `.app`。

3. **UI 层必须 `import DupFinderCore`**
   Package.swift 是双 target 结构（库 + 可执行）。若改用 swiftc 单模块编译会退化成单模块导致 `import` 报 `no such module` —— **不要退回 swiftc 直编**。

4. **多文件交给 swiftc 时不允许顶层语句**
   冒烟测试因此把 Core 源码 + driver 合并成单文件再编译（`build.sh` 内已处理）。

---

## 3. 代码结构

```
DupFinder/
├── Package.swift                 # 唯一事实源，源文件自动收集
├── build.sh                      # build（打包.app） / smoke（冒烟测试）
├── README.md                     # 用户向说明
├── HANDOVER.md                   # 本文（接手文档）
├── Sources/
│   ├── DupFinderCore/            # 纯逻辑，无 UI 依赖
│   │   ├── Models.swift          # FileEntry / DuplicateGroup / ScanPhase / ProgressInfo / formatBytes
│   │   ├── HashEngine.swift      # SHA-256 流式哈希（64KB 分块，CommonCrypto）
│   │   └── DuplicateFinder.swift # 遍历 → inode 去重 → 体积初筛 → 并发哈希 → 分组（可取消）
│   └── DupFinderApp/
│       ├── DupFinderApp.swift    # @main 入口
│       ├── ScanViewModel.swift   # @MainActor 状态中枢（CancelToken / 删除确认 / 废纸篓）
│       ├── ContentView.swift     # 主界面（列表 / 勾选 / 进度 / 扫描选项 / 确认弹窗）
│       └── FileThumbView.swift   # 缩略图（图片 CGImageSource，其他系统图标）
```

---

## 4. 核心算法流程（`DuplicateFinder.findDuplicates`）

```
1. 递归枚举（FileManager.enumerator）
   ├─ 跳过符号链接、隐藏项（可选）、常见垃圾目录、包内部（可选）
   └─ 读 inode（.fileResourceIdentifierKey）→ 硬链接只统计一次
2. 按体积分组 → 体积唯一的文件直接排除（不去哈希）
3. 对「体积出现 ≥2 次」的候选，DispatchQueue.concurrentPerform 并发算 SHA-256
4. 按哈希分组 → 组内 ≥2 份即重复组
5. 按可节省空间降序；组内按路径长度升序（短路径视为"更想保留"）
```

**取消机制**：收集阶段每 256 项、哈希阶段每 32 项检查 `shouldCancel?()`，由 `CancelToken`（NSLock 保护的 `@unchecked Sendable`）跨线程传递。

---

## 5. 已完成功能（含验证状态）

| 功能 | 状态 | 备注 |
|---|:--:|---|
| **精确去重（SHA-256）** | ✅ | 18 项冒烟全绿 |
| 体积初筛 + 并发哈希 | ✅ | |
| **渐进式哈希**（16KB→1MB→全量） | ✅ | I/O 减少 89% |
| **哈希缓存**（dev:inode:size:mtime） | ✅ | 二次扫描 I/O 减少 96% |
| **设备感知并发**（可移动卷降并发） | ✅ | 机械盘多线程反而更慢 |
| inode 去重（硬链接不误报） | ✅ | 扫 Time Machine 备份卷必需 |
| 包穿透开关 `.app/.photoslibrary` | ✅ | 默认**跳过**（删包内文件会破坏 App） |
| 扫描取消（CancelToken） | ✅ | 两种模式均支持 |
| 收集/哈希阶段进度 | ✅ | 收集阶段用不确定进度条，渐进式显示「阶段 x/3」 |
| 权限不可读项统计 | ✅ | `skippedCount` |
| **相似图片检测**（Vision+Accelerate） | ✅ | 见下方阈值标定 |
| **参考文件夹保护** | ✅ | dupeGuru 式，受保护文件无法勾选 |
| **⌘Z 撤销删除** | ✅ | 从废纸篓移回原位 |
| **Quick Look 预览** | ✅ | `QLPreviewPanel` |
| **差异对比（Delta Values）** | ✅ | 日期差高亮 + 图片像素尺寸 |
| 删除确认弹窗 | ✅ | 数量 + 空间 + 三类风险警示 |
| 缩略图（CGImageSource 异步） | ✅ | 后台只返 CGImage，主线程包 NSImage |
| 移到废纸篓（非永久删除） | ✅ | `NSWorkspace.recycle` |

### 代码复查修复（2026-08-31，静态审查 + 编译 + 冒烟 + 运行时压力测试）

对原始三项需求（重复检测 / 去重清理 / 相似检测）做完整度检阅与压力测试，共发现并修复 **11 项**问题
（均已编译通过、冒烟 18/18 全绿），并在 **5 万文件合成夹具**上实跑压力测试 8/8 全绿
（极深目录 / 特殊文件名 / 符号链接环无死循环 / 权限受限优雅跳过 / 包内部跳过 / 50MB 大文件全量哈希 /
取消安全返回空）。按严重度分级如下：

| 级别 | 问题 | 修复 |
|:--:|---|---|
| **P0** | 模式切换（精确↔相似）后，另一模式下的勾选仍会留在删除集合里，违反「所见即所得」，可能删除界面上看不到的文件 | `ScanViewModel.setScanMode(_:)` 切换时清空 `selection` 与 `similarSelection` 并重置统计文案；Picker 改为 `set:` 显式调用（此前全项目无 `onChange`） |
| **P1** | 进度条未显示渐进式哈希的「阶段 x/3」文案（`ProgressInfo.stageText` 定义后零引用） | `ContentView` 进度区改用 `p.stageText` |
| **P1** | `FileRowView` 重构时丢失了右键「保留这一份（删其余）」项（`keepOneBut`） | 右键菜单补回该条目，绑 `vm.keepOneBut(file, in: group)` |
| **P2** | ⌘Z 撤销只把文件从废纸篓移回磁盘，但列表不还原（组里仍显示已删项） | 删除前快照 `groups` / `similarGroups` 到 `snapshotExact` / `snapshotSimilar`，撤销时整体还原 |
| **P2** | 相似模式无 inode 去重，硬链接会虚报 `reclaimable`；且不统计 `skippedCount` | `collectImages` 加 inode 去重 + `skippedCount` |
| **P2** | `FileRowView` 对非图片也去读像素尺寸（浪费 I/O） | 读像素尺寸前先判图片扩展名 |
| **P3** | `HashCache.clear()/.count` 死代码（无调用入口） | 设置区加「清空哈希缓存」按钮，绑 `vm.clearHashCache()` |
| **P3** | `debugDistance/trackBytesRead/resetStats` 等诊断 API 仅冒烟标定用，缺说明易误用 | 补注释标明「非生产路径，默认关闭零开销」 |

> 复查未引入新依赖、未改动 Core 算法正确性（18 项冒烟全绿即为证明）。

---

## 6. 关键技术决策（改动前请先理解）

| 决策 | 原因 |
|---|---|
| 默认**跳过**包内部 | 包是逻辑整体，删内部文件会让 App 损坏/照片库异常。宁可漏报也不误删 |
| 默认最小体积 1 MB | 避免海量小文件噪音；用户可改 0（下限 1 字节） |
| 哈希用 SHA-256 | 精确无碰撞。但**这是性能瓶颈**，计划 A 要换非加密哈希 |
| 组内按路径长度排序 | 短路径通常是"更正式"的位置，用作默认保留项 |
| 删除只走废纸篓 | 安全红线，绝不用 `rm` |
| 语言模式保持 Swift 5 | 切 Swift 6 严格并发会触发 `[weak self]` 非 Sendable 捕获报错，需先重构进度回调 |

---

## 7. 已知坑与未解决问题

### 已踩过的坑（避免重犯）
1. `FileManager.enumerator` 的 `includingPropertiesForKeys` 要 **`[URLResourceKey]`**，而 `url.resourceValues(forKeys:)` 要 **`Set<URLResourceKey>`** —— 必须显式转换。
2. `foregroundStyle(x ? .secondary : .orange)` 三元会报 `HierarchicalShapeStyle` 与 `Color` 不等价 → 必须写 `Color.secondary` / `Color.orange`。
3. 后台 Task 返回 `NSImage` 会警告「Sendable 需 macOS 14」→ 改为后台只返回 `CGImage`，主线程再构造 `NSImage`。
4. `.windowResizability` 需 macOS 13，故 `Package.swift` platforms 为 `.v13`。
5. `NSWorkspace.shared.recycle` 的回调**只有 2 个参数** `( [URL:URL], Error? )`，不是 3 个。

### 早期需求级修复（已解决）
首轮开发即完成的可靠性修复：参考文件夹保护、⌘Z 撤销、相似检测、渐进式哈希、缓存、设备感知并发。
后续在 **2026-08-31 代码复查**中又发现并修复了 P0–P3 共 11 项（见上表），故当前已无已知阻塞性缺陷。

### 待解决（按优先级）
- **P1**：相似图片未做**特征向量缓存**——每次扫描都要重新提取特征（目前只缓存了文件哈希，没缓存 Vision 特征）。大图库二次扫描仍慢。参考 Finder Sight 做法落盘到 `~/Library/Caches/DupFinder/`
- **P2**：相似检测是 O(n²) 两两比较，1 万张图 = 5000 万次距离计算。**超过约 5000 张会明显变慢**，需要分桶/降维优化
- **P2**：进度回调用 `Task { @MainActor }` 未节流，海量文件时产生大量 Task
- **P2**：`fileSizes` / `sizeMap` 全量驻留内存，百万级文件开销大
- **P2**：`fileSizes` / `sizeMap` 全量驻留内存，百万级文件开销大
- **P2**：缺 XCTest 正式单测（现为 `build.sh smoke` 冒烟测试）
- **P2**：Swift 6 严格并发未就绪
- **P3**：默认跳过包内部 → 两个相同的 `.app` 检测不到（已知取舍）

---

## 8. 路线图 C → B → A：**均已实现**

### ✅ 计划 C · 安全与交互

| 子项 | 实现位置 |
|---|---|
| **参考文件夹** | `ScanViewModel.referenceRoots` / `isProtected(url)`；`toggle` 拒绝受保护文件；`keepOne` 优先保留参考目录内的；UI 在文件夹 chip 上用盾牌图标切换 |
| **⌘Z Undo** | `recycle` 回调的 `[原URL: 废纸篓新URL]` 存入 `lastDeletion`；`undoLastDeletion()` 用 `FileManager.moveItem` 移回；通过 `.commands` 注册 ⌘Z |
| **Quick Look** | `QuickLookCoordinator.swift`（`QLPreviewPanel` + dataSource）；右键菜单与底部按钮触发 |
| **差异对比** | `FileRowView.swift`：与组内参考文件比较修改日期（差异橙色高亮）+ 显示图片像素尺寸 |

---

### ✅ 计划 B · 相似图片检测

**技术栈**：`VNGenerateImageFeaturePrintRequest`（Vision）+ `vDSP_distancesq`（Accelerate）+ Union-Find 并查集聚类。零第三方依赖。

#### ⚠️ 阈值标定（实测，改动前务必理解）

以 256px 降采样、真实照片测得的**平方欧氏距离**：

| 场景 | 距离 |
|---|---|
| 同一张图自比 | 0.0000 |
| 同图缩小 50% + JPEG q50 | **0.34** |
| 同图缩小 25% + JPEG q30 | **1.44** |
| 两张不同的相似照片 | **0.69 – 1.02** |

**关键洞察**：后两行**区间重叠**——重度降质的同一张图（1.44）比两张不同照片（0.69）距离还远。
说明：感知哈希只能可靠识别「改尺寸 / 轻压缩」的副本；**重度降质本质上已不像，任何感知哈希都救不回**。

因此默认阈值取 **0.5**（能抓 0.34 的改版，能挡 0.69 的不同照片），UI 提供 0.1–1.5 滑块。
相似度百分比映射：`100 / (1 + distance)`。

**另一个坑**：写测试时，若"不同的图"用同一套算法生成（同样的条带构图、只换随机种子），
它们的特征距离只有 0.2 左右，会被误判为相似。**测试图必须构图上就不同**（见 build.sh 中 `makePNG` 的 style 参数）。

---

### ✅ 计划 A · 性能工程化

#### ⚠️ 先说一个被实测推翻的决定

原计划要「把 SHA-256 换成 BLAKE3/xxHash」。**实测后放弃**：

- M4 上 SHA-256（硬件加速）吞吐 **2723 MB/s**，哈希 256MB 仅需 0.094s
- SSD 读取约 2–3 GB/s，HDD 约 150 MB/s

→ **瓶颈是 I/O，不是 CPU**。换更快的哈希收益接近于零。
真正该做的是**少读数据**，这也是 rmlint 渐进式哈希的思路。

#### 已实现

| 子项 | 实现 |
|---|---|
| **渐进式哈希** | `[16KB, 1MB]` 两级前缀淘汰，最后才全量。`Options.progressiveSteps`，设 `[]` 可退化对比 |
| **哈希缓存** | `HashCache.swift`，键 = `dev:inode:size:mtime`（用 inode 故文件移动后仍命中），存 `~/Library/Caches/DupFinder/hashcache.json`，线程安全 |
| **设备感知并发** | `recommendedConcurrency()`：可移动/可弹出卷降到 2（机械盘多线程寻道抖动反而更慢），内置盘用满核心（上限 8）。分批 `concurrentPerform` 控制并发 |

#### 实测收益（60 个 2MB 文件、仅 2 对重复）

| 方案 | 实际读取 | 相比基线 |
|---|---|---|
| 基线（全量哈希） | 120.0 MB | — |
| 渐进式（冷） | 12.9 MB | **↓ 89%** |
| 渐进式 + 缓存（二次） | 4.9 MB | **↓ 96%** |

四种方式结果完全一致（都是 2 组），正确性无损。

> 注：二次扫描仍读 4.9MB 是因为**前缀哈希不进缓存**（只有全量哈希值得缓存）。
> 若想把这部分也省掉，可考虑缓存前缀哈希，但收益有限。
>
> 测量方法：本机 16GB 内存，页缓存会掩盖磁盘 I/O，导致计时不可信
> （曾测出 0.01s 的无意义结果）。因此改用 `HashEngine.trackBytesRead` 统计真实读取字节数——
> 这是与机器无关的硬指标。该开关默认关闭，零开销。

---

## 9. 构建与测试

```bash
cd DupFinder

./build.sh          # release 编译 + 打包 DupFinder.app
./build.sh smoke    # 运行核心逻辑冒烟测试（18 项断言）
open DupFinder.app  # 运行
```

冒烟测试覆盖（18 项断言）：分组正确性、可节省空间计算、唯一文件不误报、inode 去重、
取消即返回空、包跳过/穿透、渐进式哈希边界（前缀相同尾部不同不误判）、缓存一致性、关闭渐进式一致性、
相似图片收集/聚类/取消/不误判不同图。
**改动 Core 后必须跑 `./build.sh smoke`。**

---

## 10. 代码约定

- 中文注释，说明「为什么」而非「是什么」
- Core 层保持无 UI 依赖，便于单测
- 跨线程状态更新统一 `Task { @MainActor in ... }`
- `@Published` 属性只在主线程写
- 新增源文件**无需**改 Package.swift（目录自动收集），但要重跑 `./build.sh`
- 提交前：`./build.sh` + `./build.sh smoke` 必须全绿

---

## 11. 安全红线（不可违反）

1. 删除**一律**走 `NSWorkspace.recycle`（废纸篓），**绝不**用 `rm` / `FileManager.removeItem` 直接删用户文件
2. 删除前**必须**弹确认框，展示数量与空间
3. 整组全选、包内文件删除，**必须**额外红色警示
4. 「保留一个」类操作必须先把保留项从删除集合摘除（曾出过语义反转 bug）
5. 任何新功能不得引入网络请求
