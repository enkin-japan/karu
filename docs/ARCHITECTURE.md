# TinyEditor 核心架构思想

> 定位：在满足功能需求的基础上，追求极致轻量化的 macOS 专用编辑器。
> 本文档记录不可随意推翻的架构决策。修改任何一条须先更新本文档并说明理由。

## 1. 硬性预算（红线）

| 指标 | 目标 | 上限 |
|---|---|---|
| 空闲常驻内存（空文档） | 20–30 MB | 35 MB |
| 全功能空闲常驻（打开中等文件） | 30–45 MB | 50 MB |
| 排版/格式化瞬时峰值 | 文件大小 × 2–3 | 文件大小 × 4 |
| App bundle 体积 | 1–2 MB | 5 MB |
| 冷启动时间 | < 0.5 s | 1 s |

任何新功能合入前，先对照本表评估；超预算的功能宁可不做。

## 2. 技术选型及理由

| 决策 | 选择 | 排除项及理由 |
|---|---|---|
| 语言 / UI 框架 | Swift + **AppKit** | SwiftUI 多 10–20 MB 常驻且大文档行为不可控；Electron/WKWebView 直接违背定位 |
| 文本引擎 | **NSTextView + TextKit 2** | 系统控件几乎免费；不自研文本布局 |
| 构建系统 | **SPM**（executable + 库分离）+ `bundle-macos.sh` 打包脚本 | 本机无完整 Xcode（仅 CLT），且 .xcodeproj 不利于 CLI 驱动开发 |
| 文档管理 | **自制轻量 DocumentController**（NSOpenPanel/NSSavePanel + 手动 dirty 追踪） | NSDocument 依赖 bundle Info.plist 文档类型注册，在 SPM 流程下别扭，且自制更可控更省 |
| 语法高亮 | **自写正则 tokenizer**，按语言声明式定义 | tree-sitter 会使 bundle +10–20 MB；当前功能集不需要真 AST。高亮引擎藏在协议后面，未来可换 |
| 代码折叠 | 缩进层级 + 括号配对计算，不依赖 AST | 同上 |
| 补全 | 关键字表 + 文档分词索引 + 轻量正则符号扫描 | **LSP 明确排除在产品边界外**（单个语言服务器 100 MB–1 GB，定位崩坏） |
| 排版整理 | **仅内置** JSON / JSONL / XML / plist | C/C++/Java 等外部 formatter（clang-format、prettier）已决策放弃：拖运行时、bundle 膨胀 |

## 2.5 模块化（路线 A：静态内建 + 开关 + 懒加载）

产品形态：设置中提供各功能模块的"加载/卸载"开关；实现上**全部静态编译进单一二进制**，
"卸载"= 开关关闭 + 运行时状态释放。明确排除 dlopen/dylib 动态插件
（体积反增、Swift 无真卸载、签名复杂化；详见 2026-07-21 评估结论）。

- **常驻核心**（无开关）：GUI 骨架、纯文本编辑（含粘贴拦截/缩进/行号）、正则搜索替换、文档生命周期。
- **可开关模块**：`highlight`（语法高亮）、`completion`（补全）、`format`（一键排版）。
- 注册表：`FeatureModule` 枚举 + UserDefaults key `module.<name>.enabled`（默认全开），
  变更广播 NotificationCenter；调用点以布尔短路接入。
- 纪律：模块**首次使用**才分配任何堆状态；开关关闭时释放全部运行时状态（如高亮的语言定义、
  补全索引），使关闭状态的常驻成本回到 ≈ 0。

## 3. 关键设计原则

1. **可见区域优先（viewport-only）**：语法高亮、缩进彩色块、行号只对可见范围计算/绘制。
   高亮属性通过 NSLayoutManager temporary attributes / 按需着色写入，**绝不**为整个文档预存属性 run。
2. **画出来的不存起来**：行号、缩进彩虹色块、缩进参考线、折叠箭头全部在绘制阶段现场计算，
   不建立 per-line 常驻数据结构。
3. **一份索引多处复用**：全文档只维护一个"换行偏移索引"（整数数组，10 万行 ≈ 800 KB），
   同时服务行号、折叠区域定位、搜索结果行号显示。编辑时增量更新。
4. **瞬时不常驻**：格式化、全文搜索等一次性操作允许瞬时峰值，操作完成立即释放；
   任何后台常驻服务（索引进程、语言服务器）一律禁止。
5. **纯文本是唯一事实**：粘贴时拦截 `paste:`，只取 plain string，富文本属性在入口处丢弃；
   NSTextView 配置为非富文本模式。
6. **懒加载语言定义**：语言定义按需载入，未打开过的语言零占用。

## 4. 模块划分

```
Sources/
  TinyEditorApp/        可执行入口（main.swift，尽量薄）
  TinyEditorCore/       全部逻辑（库 target，可被单元测试链接）
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
  TinyEditorCoreTests/  单元测试（LineIndex、tokenizer、formatter、缩进逻辑为主）
scripts/
  bundle-macos.sh       SPM 产物 → TinyEditor.app 打包（红线文件，仅主会话可改）
```

支持语言（15 种）：Markdown, JSON, JSONL, Python, HTML, CSS, JavaScript/Node, TypeScript,
C, C++, C#, Java, Bash/Shell, SQL, XML/plist。
其中 JSONL→JSON、plist→XML、Node→JS、TS≈JS 超集，实际独立定义约 11 份。

## 5. 功能边界（已决策，不再摇摆）

**做**：GUI；纯文本粘贴去格式；正则搜索替换；15 语言高亮；代码折叠；关键字/文档词/轻量符号补全；
JSON/JSONL/XML/plist 一键排版；行号；缩进彩虹；Tab 缩进 + 换行自动缩进；每语言缩进宽度可配置。

**不做**：LSP / 语义级补全；C/C++/Java 等重型语言排版；动态库插件系统（模块开关见 §2.5，
但一律静态内建）；分屏/minimap；超大文件（>50 MB）分块加载（第一版明确不做，打开时提示即可）。
