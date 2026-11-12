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
| App bundle 体积 | 2–6 MB | 10 MB |
| 冷启动时间 | < 0.5 s | 1 s |

任何新功能合入前，先对照本表评估；超预算的功能宁可不做。

> 2026-11-12 预算调整（用户决策）：三个常驻场景上限由 35 / 50 / 65 MB 统一上调为 99 MB，
> 目标列不变并作为回归预警线；超出目标但未超上限可判通过，须在台账写明原因。
> **新增常驻内存的纪律不变**：任何会增加常驻内存的改动，须先评估、提交同环境前后对照数据，
> 并单独向用户汇报增量与理由，不能以"仍低于 99 MB"为由跳过。瞬时峰值、体积、冷启动不变。

> 测量口径：以上均为 800×600 默认窗口下的 phys_footprint。窗口的图层 backing store
> 随窗口像素面积线性增长（4K/Retina 最大化窗口约 +40–55 MB），这是所有原生 app
> 共同支付的窗口服务器图形内存，不计入本表预算（实测：200 行 md，800×600 窗口
> 43 MB，2056×1300 窗口 81 MB，缩小窗口即回落；24 秒空闲无增长）。
>
> 环境漂移：同一 commit 同机不同时段实测有 ±5 MB 系统级漂移（27/46/61 与
> 32/51/59，与深浅色模式无关）。预算判定应以**同环境对照跑**为准：怀疑回归时先在
> 当前环境重测已知良好 commit（git worktree），差值才是代码的责任。
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
| 语法高亮 | **自写正则 tokenizer**，按语言声明式定义 | tree-sitter 会使 bundle +10–20 MB；当前功能集不需要真 AST。高亮引擎藏在协议后面，未来可换 |
| 代码折叠 | 缩进层级 + 括号配对计算，不依赖 AST | 同上 |
| 补全 | 关键字表 + 文档分词索引 + 轻量正则符号扫描 | **LSP 明确排除在产品边界外**（单个语言服务器 100 MB–1 GB，定位崩坏） |
| 排版整理 | **仅内置** JSON / JSONL / XML / plist | C/C++/Java 等外部 formatter（clang-format、prettier）已决策放弃：拖运行时、bundle 膨胀 |
| 应用内更新 | **Sparkle 2**（唯一外部依赖，binary xcframework） | 自研"下载-验签-替换-重启"已评估放弃：省的 2 MB 只是磁盘体积。2026-07-21 决策：**体积预算放宽（5→10 MB 上限）、内存预算不动**——现代网络下 10 MB 内的下载体积无感，产品红线是常驻内存；实测集成后启动 footprint 无可测变化（32 MB，同环境基线持平）。EdDSA 私钥在 login keychain，绝不入仓库 |

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
   不建立 per-line 常驻数据结构。
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
    Format/             JSON/JSONL/XML/plist pretty-printer
    Settings/           偏好（每语言缩进宽度等，UserDefaults）+ 偏好窗口
    TextModel/          LineIndex（换行偏移索引）等共享数据结构
Tests/
  KaruCoreTests/  单元测试（LineIndex、tokenizer、formatter、缩进逻辑为主）
scripts/
  bundle-macos.sh       SPM 产物 → Karu.app 打包（红线文件，仅主会话可改）
```

支持语言（20 种）：Markdown, JSON, JSONL, Python, HTML, CSS, JavaScript/Node, TypeScript,
C, C++, C#, Java, Bash/Shell, SQL, XML/plist, YAML, TOML, Go, Rust, Swift。
其中 JSONL→JSON、plist→XML、Node→JS、TS≈JS 超集，实际独立定义约 16 份。

## 5. 功能边界（已决策，不再摇摆）

**做**：GUI；纯文本粘贴去格式；正则搜索替换；20 语言高亮；代码折叠；关键字/文档词/轻量符号补全；
JSON/JSONL/XML/plist 一键排版；行号；缩进彩虹；Tab 缩进 + 换行自动缩进；每语言缩进宽度可配置；
单文件代码执行与按需安装的工具链管理（§6，2026-11-12 纳入）；标题栏可选语言列表自定义。

**不做**：LSP / 语义级补全；C/C++/Java 等重型语言排版；动态库插件系统（模块开关见 §2.5，
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
