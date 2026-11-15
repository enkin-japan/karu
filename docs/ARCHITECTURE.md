# Karu 核心架构思想

> 定位：在满足功能需求的基础上，追求极致轻量化的 macOS 专用编辑器。
> 本文档记录不可随意推翻的架构决策。修改任何一条须先更新本文档并说明理由。

## 1. 硬性预算（红线）

| 指标 | 目标 | 上限 |
|---|---|---|
| 空闲常驻内存（空文档） | 20–30 MB | 99 MB |
| 全功能空闲常驻（打开中等文件 ~1 MB） | 30–45 MB | 99 MB |
| 打开大文件（~10 MB）常驻 | 50–60 MB | 99 MB |
| 排版/格式化瞬时峰值 | 文件大小 × 2–3 | 文件大小 × 4 |
| App bundle 体积 | 不设目标 | 不设上限（2026-11-13 取消），每次发布记录 |
| 冷启动时间 | < 0.5 s | 1 s |

任何新功能合入前，先对照本表评估；超预算的功能宁可不做。

> 2026-11-12 预算调整（用户决策）：三个常驻场景上限由 35 / 50 / 65 MB 统一上调为 99 MB，
> 目标列不变并作为回归预警线；超出目标但未超上限可判通过，须在台账写明原因。
> **新增常驻内存的纪律不变**：任何会增加常驻内存的改动，须先评估、提交同环境前后对照数据，
> 并单独向用户汇报增量与理由，不能以"仍低于 99 MB"为由跳过。瞬时峰值、冷启动不变。

> 2026-11-13 预算调整（用户决策）：取消 App bundle 体积上限。体积不再作为选型或验收约束，
> 每次发布仍记录总体积与增量；常驻内存红线与新增内存的汇报纪律不变。

> 测量口径：以上均为 800×600 默认窗口下的 phys_footprint。窗口的图层 backing store
> 随窗口像素面积线性增长（4K/Retina 最大化窗口约 +40–55 MB），这是所有原生 app
> 共同支付的窗口服务器图形内存，不计入本表预算（实测：200 行 md，800×600 窗口
> 43 MB，2056×1300 窗口 81 MB，缩小窗口即回落；24 秒空闲无增长）。
>
> 环境漂移：同一 commit 同机不同时段实测有 ±5 MB 系统级漂移（27/46/61 与
> 32/51/59，与深浅色模式无关）。预算判定应以**同环境对照跑**为准：怀疑回归时先在
> 当前环境重测已知良好 commit（git worktree），差值才是代码的责任。
>
> M17 读数（2026-11-15，T17.15b，macOS 27.2，800×600 Release）：三个场景 31–32 / 50.5–51.5 / 87–88 MB，冷启动到窗口
> 0.23 / 0.25 / 0.60 s；与 v0.12.0 同窗口、同字号配对为 0 / 0 / −13 MB，即 M17 没有给三个场景增加常驻。10 MB 场景高于 50–60 MB
> 目标主要是文本本身。项目文件夹索引在真实 5,000 文件仓库上常驻约 +7 MB，超出 M17 的 5 MB 分项目标（分配器保留页）。
> 明细与压力测试见 [M17 质量报告](M17-QUALITY-REPORT.md)。
>
> 首次编辑的图形层实体化（2026-07-22 排查，macOS 26 beta）：空文档一打字，
> footprint 从 ~33 MB 跳到 ~110 MB。**结论：非泄漏、非回归，不计入预算**。证据：
> ① v0.7.0 与 HEAD 逐字节同数值（排除 M12 回归）；② 拆分归因 IOSurface+GPU 图形
> ~50 MB、Malloc 仅 ~21 MB；③ 持续输入 20 行后稳定在 ~130 MB 平台线**不再增长**；
> ④ 最小化/遮挡时窗口服务器部分回收（110→66 MB）；⑤ 摘掉工具栏则回落到 ~43 MB，
> 裸 NSTextView 对照 +3 MB——触发条件是"本 app 工具栏 × 首次内容重绘"与 beta 合成
> 管线（Liquid Glass）的交互，与 v0.2.1 记录的 beta 合成器怪癖同族；⑥ 静态打开文件
> 路径（mem-benchmark 所测）不触发，故基准数字不受影响。该内存与窗口 backing store
> 同类（窗口服务器图形内存，随遮挡回收），按本表既有口径排除在预算外；正式版 macOS
> 发布后应复测一次。

## 2. 技术选型及理由

| 决策 | 选择 | 排除项及理由 |
|---|---|---|
| 语言 / UI 框架 | Swift + **AppKit** | SwiftUI 多 10–20 MB 常驻且大文档行为不可控；Electron/WKWebView 直接违背定位 |
| 文本引擎 | **NSTextView + NSLayoutManager（TextKit 1 路径）** | 复用系统文本布局；现有折叠依赖字形代理，高亮依赖临时属性，不自研文本布局 |
| 构建系统 | **SPM**（executable + 库分离）+ `bundle-macos.sh` 打包脚本 | 本机无完整 Xcode（仅 CLT），且 .xcodeproj 不利于 CLI 驱动开发 |
| 文档管理 | **自制轻量 DocumentController**（NSOpenPanel/NSSavePanel + 手动 dirty 追踪） | NSDocument 依赖 bundle Info.plist 文档类型注册，在 SPM 流程下别扭，且自制更可控更省 |
| 语法高亮 | **自写正则 tokenizer**，按语言声明式定义 | tree-sitter 会使 bundle +10–20 MB；当前功能集不需要真 AST。高亮引擎藏在协议后面，未来可换。M17 深层类型推断所需的解析器经 T17.9 实测选定**手写解析器**（基于通用词法扫描器的 token、扁平节点数组、按顶层语句增量），不引入 tree-sitter：1000 行文件的语法树常驻约 0.1–0.6 MB、完整解析约 0.3 ms，10 MB 约 34 MB / 90 ms，tree-sitter 分别约 1 MB、1.5 ms、340–360 MB、500 ms，容错样本 58/58 对 57/58（见 LEDGER T17.9） |
| 代码折叠 | 缩进层级 + 括号配对计算，不依赖 AST | 同上 |
| 补全 | 关键字表 + 文档分词索引 + 共享词法状态上的声明/作用域分析 + 进程内类型推断、导入解析与项目文件夹跨文件索引（2026-11-13 决策，见 [M17 方案](HIGHLIGHT-AND-COMPLETION-PLAN.md)） | **LSP 明确排除在产品边界外**（单个语言服务器 100 MB–1 GB，定位崩坏）。所有代码理解在 Karu 进程内完成，计入常驻预算；不执行项目代码获取信息 |
| 排版整理 | **仅内置** JSON / JSONL / XML / plist | C/C++/Java 等外部 formatter（clang-format、prettier）已决策放弃：拖运行时、bundle 膨胀 |
| 应用内更新 | **Sparkle 2**（唯一外部依赖，binary xcframework） | 自研"下载-验签-替换-重启"已评估放弃：省的 2 MB 只是磁盘体积。2026-07-21 决策：**体积预算放宽（5→10 MB 上限）、内存预算不动**——现代网络下 10 MB 内的下载体积无感，产品红线是常驻内存（2026-11-13 起体积上限整体取消，见 §1）；实测集成后启动 footprint 无可测变化（32 MB，同环境基线持平）。EdDSA 私钥在 login keychain，绝不入仓库 |

> 2026-10-09 文档校正：原表写 TextKit 2，但当前 EditorWindowController、FoldingController
> 及 HighlightEngine 实际使用 NSLayoutManager 的字形、布局代理与临时属性接口。
> 本次仅对齐实现事实，不迁移文本引擎。开发验证流程见 [DEVELOPMENT.md](DEVELOPMENT.md)。
>
> 2026-11-12 环境注记：构建系统一行的“本机无完整 Xcode（仅 CLT）”是 2026-07 选型时的环境；
> 当前开发机已装 Xcode 27.2。选型不变：仍以 SPM + 脚本为准，不以 Xcode 工程或 XCTest 为前提。

## 2.5 模块化（路线 A：静态内建 + 开关 + 懒加载）

产品形态：设置中提供各功能模块的"加载/卸载"开关；实现上**全部静态编译进单一二进制**，
"卸载"= 开关关闭 + 运行时状态释放。明确排除 dlopen/dylib 动态插件
（体积反增、Swift 无真卸载、签名复杂化；详见 2026-07-21 评估结论）。

- **常驻核心**（无开关）：GUI 骨架、纯文本编辑（含粘贴拦截/缩进/行号）、正则搜索替换、文档生命周期。
- **可开关模块**：`highlight`（语法高亮）、`completion`（补全）、`format`（一键排版）、
  `run`（代码执行，见 §6）。
- 注册表：`FeatureModule` 枚举 + UserDefaults key `module.<name>.enabled`（默认全开），
  变更广播 NotificationCenter；调用点以布尔短路接入。
- 纪律：模块**首次使用**才分配任何堆状态；开关关闭时释放全部运行时状态（如高亮的语言定义、
  补全索引），使关闭状态的常驻成本回到 ≈ 0。

## 3. 关键设计原则

1. **可见区域优先（viewport-only）**：语法高亮、彩色缩进点、行号只对可见范围计算/绘制。
   高亮属性通过 NSLayoutManager temporary attributes / 按需着色写入，**绝不**为整个文档预存属性 run。
2. **画出来的不存起来**：行号、彩色缩进点、折叠箭头全部在绘制阶段现场计算，
   不建立 per-line 常驻数据结构。折叠箭头绘制时只查可见行所在的 128 行窗口（有工作量上限的
   局部扫描）；全文折叠区域扫描按 ≈4 ms 主线程切片在 AnalysisScheduler 上运行，结果
   （每区域 8 字节、有序数组）按文本版本发布，编辑即失效并去抖重扫，绘制路径从不做全文扫描。
3. **一份索引多处复用**：全文档只维护一个"换行偏移索引"（整数数组，10 万行 ≈ 800 KB），
   同时服务行号、折叠区域定位、搜索结果行号显示。编辑时增量更新。
4. **瞬时不常驻**：格式化、全文搜索等一次性操作允许瞬时峰值，操作完成立即释放；
   任何后台常驻服务（索引进程、语言服务器）一律禁止。
5. **纯文本是唯一事实**：粘贴时拦截 `paste:`，只取 plain string，富文本属性在入口处丢弃；
   NSTextView 配置为非富文本模式。
6. **懒加载语言定义**：语言定义按需载入，未打开过的语言零占用。
7. **快捷键共享定义**（2026-10-10）：菜单派生命令目录，非菜单操作补充稳定标识；全局仅
   保留小型命令元数据与用户覆盖值，窗口持有一个临时组合键状态。设置表在打开时构建、
   关闭时释放，不建立每文档快捷键索引。Python 高亮只保留一个靠近可视区的词法状态检查点
   （偏移和解析栈），避免大文件每次滚动都从头扫描；编辑、切语言或关闭模块即失效/释放，
   不建立每行缓存或第二份全文索引。该常量状态以滚动耗时实测为依据。


> 缩进彩虹现状（T15.10–T15.12）：v0.9.9 起移除跨行背景色块和分隔线，改为前导空白
> 字符单元格内按级别着色的点，以避开滚动时行距区域失效不完整产生的缝隙。
> v0.9.10 点直径为字号 ÷ 3、透明度 40%。本次补记既有决议，未改变产品行为。

## 4. 模块划分

```
Sources/
  KaruApp/        可执行入口（main.swift，尽量薄）
  KaruCore/       全部逻辑（库 target，可被单元测试链接）
    App/                AppDelegate、主菜单、DocumentController（窗口/文件生命周期）
    Editor/             EditorTextView（粘贴拦截、Tab/自动缩进）、EditorWindowController
    Gutter/             行号 + 折叠箭头 + 缩进彩虹绘制（RulerView）
    Highlight/          HighlightEngine（viewport 调度）、LanguageDefinition 协议、Languages/ 各语言定义
    Search/             正则搜索替换栏（NSRegularExpression）
    Completion/         关键字表、文档分词索引、补全弹窗
    Inference/          内置类型表（TypeTableStore，mmap 懒加载）与 TypeExpr 类型表达式解析（M17 T17.10 起）
    Workspace/          项目文件夹与跨文件符号索引（WorkspaceIndex，SQLite，后台队列 + FSEvents；M17 T17.12 起）
    Format/             JSON/JSONL/XML/plist pretty-printer
    Settings/           偏好（每语言缩进宽度等，UserDefaults）+ 偏好窗口
    TextModel/          LineIndex（换行偏移索引）等共享数据结构
Tests/
  KaruCoreTests/  单元测试（LineIndex、tokenizer、formatter、缩进逻辑为主）
scripts/
  bundle-macos.sh       SPM 产物 → Karu.app 打包（红线文件，仅主会话可改）
```

**内置类型表（M17 T17.10）**：`scripts/m17/gen-type-tables.sh` 从固定版本的 typeshed
（`stdlib/`，按 Python 3.13 / darwin 求值）和 `typescript` npm 包（lib.es5…esnext、lib.dom*）
生成 `assets/typetables/python-stdlib.ktt` 与 `typescript-lib.ktt`（来源与哈希见同目录 `SOURCES.txt`，
许可证见 [THIRD-PARTY-NOTICES](THIRD-PARTY-NOTICES.md)），打包时复制到 `Contents/Resources/TypeTables/`。
- 格式 `.ktt`（小端，区域 4 字节对齐）：16 字节文件头（`KTT1`、版本、语言、区段数）+ 每区段 32 字节目录；
  每个区段自带按名字 UTF-8 字节排序的索引（名字串号、条目偏移、长度）、字符串表和条目区。
  条目是 LEB128 变长整数序列，字符串用串号引用，每个条目可单独解码。Python 一个区段（按模块），
  TS 分 ES、DOM 两个区段（按全局符号，命名空间成员用限定名），只查 ES 符号不会读到 DOM 区段。
  详细字段见 `Inference/TypeTableFile.swift` 文件头与 `scripts/m17/ktt_writer.py`。
- 加载：`TypeTableStore` 初始化不做任何事；首次查询某语言时只读 mmap 该文件、校验文件头，
  每次查询只解码一个模块或符号，结果进按估算字节封顶的 LRU（默认 4 MB，计入 §11 ②），
  `release()` 清空并解除映射。查找顺序：App 包 `TypeTables/`、`KARU_TYPE_TABLES`、仓库 `assets/typetables/`。
- 类型统一存为规范化文本，`TypeExpr.parse(_:syntax:)` 按 Python 或 TS 语法解析；测试保证表中每条类型文本都能解析。

**项目文件夹与跨文件索引（M17 T17.12）**：设置 › 项目文件夹… 里维护的文件夹（路径与书签存在本机
UserDefaults `workspace.projectFolders` / `workspace.projectFolderBookmarks`，不进设置导出）由应用级的
`WorkspaceIndex.shared` 建索引；它在进程内运行，不是独立服务或进程，与 §3 第 4 条不冲突。
- 存储：每个文件夹一个系统 SQLite 库，`~/Library/Application Support/dev.enkin.TinyEditor/Index/<标准化路径的 FNV-1a 64 位十六进制>.sqlite`，
  WAL、每库页缓存上限 1 MB、不 mmap、预编译语句。表 `meta`（schema、文件夹路径）、`files`（相对路径、语言、大小、mtime、索引时间）、
  `symbols`（名字、折叠名、类别、所属容器、UTF-16 位置、行号、可空的签名摘要），版本存在 `PRAGMA user_version`；
  版本或文件夹不符、文件损坏一律删库重建。只存声明，不存文件内容和普通词。
- 内容：复用 `DeclarationScan`（与编辑器同一份纯值代码），取模块级、类与命名空间成员、实例属性；参数、局部、导入不入库
  （`IndexedSymbol.extract`）。语言为有声明 walker 的全部语言（含 `.pyi`）。
- 范围：跳过 `.git`、`node_modules`、常见构建 / 缓存 / 虚拟环境目录与各级 `.gitignore` 的基本模式（`Workspace/IndexScope.swift`
  文件头列出支持的子集）；单文件 >2 MB 跳过；每个文件夹最多 50,000 个可索引文件，超出即停并在设置里提示。不跟随符号链接。
- 线程：一个 utility QoS 串行队列，每步最多处理一个文件（或列一个目录、或核对 64 个未变文件）后重新派发，只读磁盘、
  不碰 AppKit 和打开的文档；每个文件夹一个 FSEvents 流（文件级事件，0.3 s 合并）只记录路径。查询在调用方线程上、持该库的锁执行，
  结果是值类型。启动或重新打开模块时全量走一遍，按大小 + mtime 跳过未变文件、删除已消失文件。
- 开关：`crossFileIndex` 关闭即停流、丢弃待办、关库（库文件留在磁盘）；打开后按 mtime 追平。诊断运行（`KARU_DIAGNOSTIC_DIRECTORY`）
  不读用户文件夹。

支持语言（21 种）：Markdown, JSON, JSONL, Python, HTML, CSS, JavaScript/Node（含 `.jsx`）, TypeScript,
TypeScript JSX（`.tsx`，M17 T17.8b）, C, C++, C#, Java, Bash/Shell, SQL, XML/plist, YAML, TOML, Go, Rust, Swift。
其中 JSONL→JSON、plist→XML、Node→JS、TS≈JS 超集、TSX = TS 规则 + JSX，实际独立定义约 16 份。

## 5. 功能边界（已决策，不再摇摆）

**做**：GUI；纯文本粘贴去格式；正则搜索替换；21 语言高亮；代码折叠；关键字/文档词/轻量符号补全，以及作用域感知补全、进程内类型推断（Python、JS/TS 深层，其余语言读显式声明）、导入解析和项目文件夹跨文件索引（2026-11-13 纳入，见 M17 方案）；
JSON/JSONL/XML/plist 一键排版；行号；缩进彩虹；Tab 缩进 + 换行自动缩进；每语言缩进宽度可配置；
单文件代码执行与按需安装的工具链管理（§6，2026-11-12 纳入）；标题栏可选语言列表自定义。

**不做**：LSP 及任何外部语言服务进程；执行项目代码获取信息；跨文件重命名与全项目诊断；C/C++/Java 等重型语言排版；动态库插件系统（模块开关见 §2.5，
但一律静态内建）；分屏/minimap；超大文件（>50 MB）分块加载（第一版明确不做，打开时提示即可）。

## 6. 代码执行与工具链（2026-11-12 决策）

用途：直接运行当前编辑内容（未保存也可），定位是单文件脚本/小程序，不是 IDE 构建系统。

- **语言判定**：标题栏手动指定的语言优先，绝不改写；自动模式且已有语言则直接使用；
  自动模式且为 Plain Text 时按全文运行识别，识别成功即更正标题栏（仍为自动模式），
  失败报“无法识别语言”。手动 Plain Text 报“纯文本不可执行”。不做 C→C++、JS→TS 的运行时细化。
  增强识别规则与高亮自动识别共用一套（LanguageSniffer）。
- **可执行语言**：Python、JavaScript、TypeScript（Node 类型剥离）、Bash、C、C++、Swift、Go、
  Rust、Java（单文件源码启动）、C#（.NET 10 文件程序）。SQL、HTML 及标记/数据语言报“不可执行”。
- **执行方式**：编辑内容快照写入临时目录（UTF-8、LF），已保存文档以其所在目录为工作目录；
  独立进程组启动，stdout/stderr 分流，支持 stdin 输入行与 EOF；停止为 SIGTERM→SIGKILL 进程组；
  关窗/退出即终止并清理。每窗口同时一个运行。输出保留上限约 1 MB，UI 批量刷新。
- **资源纪律**：输出面板首次运行才创建，关闭即释放；`run` 模块关闭时零状态。
  进程管道读取不得常驻后台线程池；无运行时的常驻成本须为 ≈ 0（同环境基准验收）。
- **工具链来源**：每语言可选 Karu 安装 / 系统 PATH / 自定义路径，默认按此顺序回退。
  GUI 进程不继承 shell PATH，系统 PATH 通过一次 `$SHELL -l` 读取并缓存。
  `/usr/bin` 下 CLT、Java 占位程序会弹系统安装框，调用前须先检测，自行报错。
- **Karu 安装的工具链**：Python（python-build-standalone）、Node、Go、Java（Temurin）、
  .NET SDK，以及经实测可行时的 Zig（C/C++）。Swift、Rust 依赖 Apple CLT，只提供系统安装入口。
  安装于 `~/Library/Application Support/<bundle id>/Toolchains/`，不进 bundle（体积预算不受影响）。
  版本清单随 Karu 版本内置，固定官方下载地址与 SHA256，校验失败拒绝安装；运行时不拉远程清单。
  下载仅由用户在设置中触发，流式落盘、系统 tar 解压、暂存目录原子就位，可取消，卸载即删目录。
- **不影响全局环境**：不改 PATH、shell 配置、launchctl 环境或公共 bin 目录。仅对 Karu 启动的
  子进程前置工具链 bin，并把 GOPATH/GOCACHE、npm/pip/NuGet/.NET/Zig 等缓存重定向到 Karu 目录，
  关闭 .NET 遥测；卸载时缓存一并删除。用户选择系统/自定义工具链时按其原有行为运行。
  实测补充（2026-11-12）：Go 本地遥测不受 `GOTELEMETRY` 环境变量控制，改为只给编译步骤设
  缓存内 HOME（运行步骤保持用户 HOME）；NuGet 迁移标记写 LocalApplicationData，故 .NET 子进程设
  `XDG_DATA_HOME` 到缓存（`dotnet run` 为单一步骤，用户 C# 程序的 LocalApplicationData 亦随之指向缓存）。
- **不做**：包管理界面、多版本并存、项目级构建（Cargo/Maven/Go module 依赖）、终端仿真/PTY、
  错误行跳转（留待第二期）。

### 导入解析（M17 T17.13）

`Sources/KaruCore/Imports/` 负责 Python 和 JS/TS 的导入，按 HIGHLIGHT-AND-COMPLETION-PLAN §9 的顺序查找，标准库先走内置 typeshed 表。
- **读盘**：只经可注入的 `ImportFileSystem`，在串行 utility 队列 `dev.enkin.Karu.imports` 上执行。全程不启动任何进程：解释器的位置只读 Run 模块已缓存的结果。
- **缓存**：每个模块只保留导出摘要，放在全应用共用的 LRU 里，上限 8 MB。超限时先降为只留名字，单个模块超过 2 MB 也只留名字。
- **失效**：项目文件靠 WorkspaceIndex 的 FSEvents；site-packages、node_modules 和解释器按 mtime 复核，最多每 2 s 一次。
- **无项目文件夹**：只用标准库存根和解释器自带的包，不读文档所在的目录，以免触发访问授权。

