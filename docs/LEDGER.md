# TinyEditor 工程步骤账本

> 开工前读 `ARCHITECTURE.md`。每完成一项：更新状态、记录负责方与验收结果。
> 负责方按 CLAUDE.md 路由规则：main = 主会话直接做；implementer / chore-worker = 委派。
> 委派必须附：涉及文件路径 + 验收标准。子代理改完，主会话 review diff 后才能提交。
> 状态：⬜ 未开始 / 🔄 进行中 / ✅ 完成 / ❌ 失败（记录次数，触发升级链）

## M1 骨架

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T1.1 | SPM 工程骨架：Core 库 + App 可执行分离，AppDelegate、最小菜单、空编辑窗口（NSTextView） | Package.swift, Sources/TinyEditorApp/, Sources/TinyEditorCore/App/, Editor/ | main | `swift build` 与 `swift test` 通过；启动出现可输入窗口 | ✅ 启动时 phys_footprint 2.5 MB |
| T1.2 | bundle-macos.sh：release 产物打包成 TinyEditor.app（红线：.p8/.env* 不得入 bundle） | scripts/bundle-macos.sh | main（红线，禁止委派） | 脚本产出可双击启动的 .app；bundle 内无密钥文件 | ✅ bundle 96 KB，ad-hoc 签名，密钥检查内置 |

## M2 编辑核心

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T2.1 | 文档生命周期：新建/打开/保存/另存/多窗口/dirty 标记/关闭确认 | Core/App/DocumentController.swift, Editor/EditorWindowController.swift | implementer | 单测：dirty 状态机；手测：菜单全链路可用 | ✅ 9 测试全绿；review 后主会话补 Cmd-Q 退出确认 |
| T2.2 | 纯文本粘贴拦截 + Tab/Shift-Tab 缩进 + 回车自动缩进 + 每语言缩进宽度设置（先读 UserDefaults，无 UI） | Core/Editor/EditorTextView.swift, Core/Settings/IndentSettings.swift | implementer | 单测：缩进逻辑（含 HTML 2/4 格切换）；粘贴富文本后 storage 无属性 | ✅ 17 新测试，43 全绿，review 通过 |
| T2.3 | LineIndex 换行偏移索引（增量更新）+ 行号 gutter + 缩进彩虹绘制 | Core/TextModel/LineIndex.swift, Core/Gutter/ | implementer | 单测：LineIndex 增量正确性（插入/删除跨行）；手测滚动无卡顿 | ✅ 22 新测试含 fuzz 对拍，79 全绿；冒烟 footprint 21 MB。注意：GutterView 占用 textStorage.delegate 槽位，T3.1 需做多路复用 |
| T2.4 | 正则搜索替换栏（大小写开关、正则开关、逐个/全部替换、结果计数与行号跳转） | Core/Search/ | implementer | 单测：替换含捕获组 `$1`；手测 UI 链路 | ✅ 15 新测试，94 全绿，review 通过。Find 菜单按 macOS 惯例放 Edit 子菜单 |

## M3 语言智能

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T3.0 | 模块注册表（路线 A）：FeatureModule 枚举 + ModuleSettings（UserDefaults + 变更广播）；架构文档 §2.5 | Core/Modules/FeatureModule.swift | main | 单测：默认全开/开关往返/通知去重 | ✅ 97 全绿 |
| T3.1 | 高亮引擎：LanguageDefinition 声明式协议、viewport 调度、编辑去抖、按扩展名检测语言；随附首个语言 JSON 作为样板。**必须**：受 `module.highlight` 开关门控（关闭清空属性并释放语言状态）；做 textStorage delegate 多路复用器解决与 GutterView 的槽位冲突；语法色用 temporary **foreground** 属性（背景色属性归搜索高亮，勿冲突） | Core/Highlight/, Core/TextModel/（多路复用器）, Gutter/GutterView.swift（改接复用器） | implementer | 单测：JSON tokenizer 分类正确；全文档属性不预存（代码 review 确认）；开关关闭后属性清空 | ✅ 11 新测试，108 全绿；冒烟 footprint 23 MB。遗留：语言检测时 languageIdentifier 应取定义的 identifier 而非扩展名（T3.2 处理） |
| T3.2 | 语言定义批次 1：Markdown, Python, JS(+Node), TS, HTML, CSS, JSONL | Core/Highlight/Languages/*.swift | implementer | 每语言单测：代表性片段 token 分类断言 | ✅ 25 新测试，133 全绿；languageIdentifier 接线修正一并完成 |
| T3.3 | 语言定义批次 2：C, C++, C#, Java, Bash, SQL, XML(+plist)（照 T3.1 样板逐个复制修改，附各语言关键字表） | Core/Highlight/Languages/*.swift | chore-worker | 同上；`swift test` 全绿 | ✅ 23 新测试，156 全绿，review 通过 |
| T3.4 | 代码折叠：缩进+括号配对计算折叠区域，gutter 箭头，折叠/展开（利用 LineIndex） | Core/Gutter/, Core/TextModel/FoldRegion.swift | implementer | 单测：折叠区域计算（Python 缩进式 + C 括号式）；手测折叠展开 | ✅ 15 新测试，171 全绿。后续可改进：编辑后保留未受影响折叠；折叠切换只增量重布局 |
| T3.5 | 补全：关键字表 + 文档分词增量索引 + 正则符号扫描（函数/变量/类名），Esc/方向键/回车交互 | Core/Completion/ | implementer | 单测：分词索引增量更新、符号提取；手测弹窗交互 | ✅ 17 新测试，188 全绿。v1：分词去抖全量重建（<10ms/MB）；符号排序 符号>关键字>文档词，上限 50 |

## M4 工具与设置

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T4.1 | JSON/JSONL 一键排版（保持 key 顺序、可配缩进宽度、错误定位到行） | Core/Format/JSONFormatter.swift | chore-worker（附详细算法计划） | 单测：嵌套/转义/大数/非法输入各用例 | ✅ 18 新测试全绿，review 通过（菜单接线待 T4.3/后续） |
| T4.2 | XML/plist 一键排版 | Core/Format/XMLFormatter.swift | chore-worker（附详细算法计划） | 单测：嵌套标签/属性/CDATA/注释用例 | ✅ 14 新测试，review 通过（菜单接线同 T4.1 待后续） |
| T4.3 | 偏好设置窗口：模块加载/卸载开关列表（ModuleSettings）、每语言缩进宽度、Tab 转空格、字体字号、缩进彩虹开关 | Core/Settings/ | implementer | 手测：改动实时生效并持久化；模块关闭后运行时状态释放 | ✅ 14 新测试，202 全绿；Format 菜单接线（含错误行定位）一并完成 |

## M5 收尾

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T5.1 | 内存基准脚本：footprint 采样（空文档 / 1 MB / 10 MB 文件），输出对照预算表 | scripts/mem-benchmark.sh | chore-worker | 脚本可重复运行出报告 | ✅ 三轮采样 + PASS/FAIL 对照表；主会话补 CLI 打开路径解锁带文件轮 |
| T5.2 | 全量 review + 对照 ARCHITECTURE.md 红线逐条验收 + 打磨 | 全部 | main（禁止委派） | 预算表全部达标 | ✅ 见变更记录 2026-07-21 验收条目 |

## M6 用户反馈迭代（2026-07-21 测试反馈）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T6.1 | 缩进彩虹辨识度：高区分度色环 + alpha 0.15-0.18 + 缩进单位分隔线 | Core/Gutter/IndentRainbow.swift, Editor/EditorTextView.swift | chore-worker | 202 测试不破坏；肉眼可辨格数 | ✅ |
| T6.2 | 语言自动识别：内容嗅探（shebang/JSON/XML 特征）补充扩展名检测；Language 菜单手动覆盖 | Core/Highlight/LanguageSniffer.swift（新）, EditorWindowController, MainMenu | implementer | 单测：嗅探特征用例；无扩展名文档粘贴 JSON 后自动高亮 | ✅ 26 新测试；主会话补 ES-module import 消歧 |
| T6.3 | 主窗口工具栏（语言选择/缩进宽度/Format/模块开关）+ UI 打磨（查找栏样式、状态栏行列号） | Editor/, App/ | implementer | 手测；既有测试不破坏 | ✅ 11 新测试，239 全绿；空文档基线 29 MB（工具栏代价 +5 MB，限内） |
| T6.4 | 中/日/英三语切换：轻量 L10n 表 + UserDefaults + 实时切换（不引入 .lproj，保体积红线） | Core/L10n/（新）+ 全部 UI 字符串改造 | implementer | 三语言下菜单/查找栏/偏好/警告框文案正确；切换即时生效 | ✅ 12 新测试，251 全绿 |
| T6.5 | App 图标：CoreGraphics 逐尺寸绘制 → .icns；bundle 接线主会话做（红线） | scripts/generate-icon.swift, assets/ | implementer + main | .icns 生成；打包后 Dock/Finder 显示图标 | ✅ bundle 1.0 MB |

依赖：T6.1、T6.5 并行先行；T6.2 → T6.3 → T6.4 串行（同文件冲突）；T6.5 完成后主会话接线 bundle-macos.sh 并重跑发布流水线。

## 依赖关系

T1.1 → T2.1 → T2.2/T2.3/T2.4（可并行）→ T3.1 → T3.2/T3.3（可并行）→ T3.4/T3.5
T4.1/T4.2 仅依赖 T1.1；T4.3 依赖 T2.2；T1.2 随时可做；T5.* 最后。

## 环境约束（委派时必须告知子代理）

- 本机仅有 Command Line Tools，无完整 Xcode：**没有 XCTest**，单元测试一律用 Swift Testing
  （`import Testing`、`@Test`、`#expect`）；构建/测试命令为 `swift build` / `swift test`。
- 涉及 AppKit 的测试代码需标注 `@MainActor`。
- **SPM 增量编译偶发陈旧**（本会话已两次遇到）：逻辑正确的改动测试却失败时，先
  `rm -rf .build` 全量重建再判定，不要空转排查。
- 视觉验证：`TINYEDITOR_SNAPSHOT=<png> .build/<cfg>/TinyEditorApp [file]` 让 app 自渲染快照
  （无需录屏权限）；`scripts/visual-smoke.sh` 为防"空白窗口"类回归的守门脚本，UI 改动后必跑。

## 变更记录

- 2026-07-21 v0.2.2（用户反馈第三轮）："打不开文档"真根因不是编码而是 **Finder→app 通道缺失**：
  Info.plist 无 CFBundleDocumentTypes + AppDelegate 无 application(_:open:)，文件从未到达 app。
  已补声明与入口（含纯净未命名窗口复用），用 `open -a` + 截图钩子实测验证（此前所有验证只走
  CLI 参数路径，为测试盲区）。补全词库补齐 8 语言内置函数（print/console 等）。259 测试全绿，
  公证出包 944 KB。

- 2026-07-21 v0.2.1 紧急修复（main 直接处理，含根因分析）：①空白窗口回归——StatusBarView 的
  draw 覆写在 macOS 26 beta 合成管线下使整窗渲染路径切换，NSTextView/NSRulerView 不上屏；
  git bisect 定位到 T6.3，自截图钩子逐项排除后锁定；已加 visual-smoke.sh 防复发。②打开非
  UTF-8 文件（UTF-16/Shift-JIS/GB18030）报错——编码链改为 BOM 检测（仅信任 Unicode 系）+
  NSString 统计检测。③空未命名文档关闭不再弹确认。256 测试全绿；公证出包 940 KB。

- 2026-07-21 M6 用户反馈迭代收官（v0.2.0）：缩进彩虹辨识度、语言自动嗅探+手动覆盖、工具栏+状态栏+查找栏打磨、中日英三语实时切换、App 图标。251 测试全绿。v0.2.0 已签名公证（Accepted）出 DMG 932 KB。

- 2026-07-21 发布流水线（main，红线任务）：Bundle ID 定为 dev.enkin.TinyEditor；Developer ID +
  hardened runtime 签名；公证 Accepted（凭据存钥匙串 profile "tinyeditor-notary"，需 --keychain
  显式指定 login keychain）；票据装订；DMG 552 KB。Gatekeeper 验证 "Notarized Developer ID"。
  更新分发暂缓（用户决定）。清理了 LSP 掉在仓库根目录并被误提交的 *.o/*.d 中间产物。

- 2026-07-21 T5.2 最终验收（main）：202 测试全绿。内存基准（release 构建）：空文档 23 MB（上限 35）、
  1.3 MB 文件 42 MB（上限 50）、10 MB 文件 58 MB（上限 65）——全部 PASS。修复关键问题：启用
  allowsNonContiguousLayout（此前打开 10 MB 文件全量布局冲到 97 MB）。补充架构预算表"大文件"行
  （立项讨论承诺口径 50–60 MB）。bundle 708 KB（上限 5 MB），ad-hoc 签名，无密钥文件。
  遗留打磨项：编辑后折叠不保留；折叠切换全文档重布局；补全弹窗几何未自动化测试。

- 2026-07-21 账本建立。
- 2026-07-21 T1.1 完成（main）：骨架构建/测试通过，启动冒烟 OK。发现环境无 XCTest，测试框架定为 Swift Testing。
