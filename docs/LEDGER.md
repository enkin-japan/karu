# Karu 工程步骤账本

> 开工前读 `ARCHITECTURE.md`。每完成一项：更新状态、记录负责方与验收结果。
> 负责方按 CLAUDE.md 路由规则：main = 主会话直接做；implementer / chore-worker = 委派。
> 委派必须附：涉及文件路径 + 验收标准。子代理改完，主会话 review diff 后才能提交。
> 状态：⬜ 未开始 / 🔄 进行中 / ✅ 完成 / ❌ 失败（记录次数，触发升级链）

## M1 骨架

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T1.1 | SPM 工程骨架：Core 库 + App 可执行分离，AppDelegate、最小菜单、空编辑窗口（NSTextView） | Package.swift, Sources/KaruApp/, Sources/KaruCore/App/, Editor/ | main | `swift build` 与 `swift test` 通过；启动出现可输入窗口 | ✅ 启动时 phys_footprint 2.5 MB |
| T1.2 | bundle-macos.sh：release 产物打包成 Karu.app（红线：.p8/.env* 不得入 bundle） | scripts/bundle-macos.sh | main（红线，禁止委派） | 脚本产出可双击启动的 .app；bundle 内无密钥文件 | ✅ bundle 96 KB，ad-hoc 签名，密钥检查内置 |

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

## M7 用户反馈迭代（第四轮）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T7.1 | Finder 打开多开空窗口：didFinishLaunching 加已开窗口守卫 | App/AppDelegate.swift | main | open -a 后 windows=1 | ✅ |
| T7.2 | VS Code 式缩进检测：按文档内容自动推断缩进单位（detectIndentation），驱动彩虹与 Tab | Core/Editor/IndentDetector.swift（新）等 | implementer | 单测：2/4/8 格与 tab 文档的推断；md 4 格缩进单色带 | ✅ 11 新测试 |
| T7.3 | 折叠视觉：放大箭头、折叠头行背景色 + 行数提示 | Core/Gutter/, Editor/ | implementer | 视觉冒烟对比 | ✅ 4 新测试 + 视觉冒烟 |
| T7.4 | 文档符号高亮：函数/类/变量名（进程内符号扫描接入高亮引擎） | Core/Highlight/, Completion/WordIndex.swift | implementer | 单测：符号分类；视觉验证 | ✅ 7 新测试 |

## M8 候选任务（2026-07-21 CotEditor 对比得出，讨论定案后开工）

来源：与 CotEditor（main 分支）源码对比 + 用户实测反馈。全部候选均须守住
ARCHITECTURE.md 预算红线；明确不引入 tree-sitter / SwiftUI / NSDocument。

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T8.1 | 滑动流畅度：高亮 overscan（±1.5 屏预染）+ 已染色带内滚动零工作（paintedRange 短路）+ 小文件（<512 KiB）自适应关闭 noncontiguous layout（LayoutModeController，编辑跨阈值自动切换；大文件保持懒布局）。注：滚动路径本就无去抖，主因是惰性布局滞后 | Core/Highlight/HighlightEngine.swift, Editor/LayoutMode.swift（新）, Editor/EditorWindowController.swift | implementer | 快速滑动无 pop-in；mem-benchmark 三轮 PASS | ✅ 14 新测试，295 全绿；基准 27/46/61 MB 全 PASS；视觉冒烟 OK |
| T8.2 | 编码手动重解释：File ▸ Reopen with Encoding（9 种编码，非 lossy 强制解码，脏文档先确认，untitled 禁用；保存仍一律 UTF-8） | App/DocumentController.swift, App/TextEncoding.swift（新）, MainMenu, EditorWindowController, L10n | implementer | 选错编码可换编码重开且不丢文件 | ✅ 与 T8.3 合并实施 |
| T8.3 | 换行符：LineEnding 纯函数检测/转换（新文件）+ 状态栏显示 + Format ▸ Convert Line Endings（走 undo 通道，当前值打勾）。已知限制：CRLF 文档中打回车仍插 \n（混合换行），后续可在 insertNewline 拦截 | Core/TextModel/LineEnding.swift（新）, Editor/StatusBarView.swift, EditorWindowController, MainMenu, L10n | implementer | 状态栏正确显示；转换可 undo | ✅ 23 新测试，325 全绿；视觉冒烟 OK；主会话修正转换被拒时状态栏误显 |
| T8.4 | 大纲/符号导航：Cmd+Shift+O 弹窗，声明正则重构为共享模式表 + 一次性带位置扫描（scanSymbolLocations），过滤/回车跳转/Esc；关闭即全量释放（瞬时不常驻） | Core/Completion/WordIndex.swift, Editor/SymbolNavigator.swift（新）, EditorWindowController, MainMenu, L10n | implementer | 符号列表可跳转；常驻增量 ≈ 0 | ✅ 7 新测试，302 全绿；三语文案齐；视觉冒烟 OK |
| T8.5 | `karu` 命令行工具：shell 脚本随 bundle 分发（Resources/karu，用户 symlink 到 PATH），不存在的路径先建空文件再打开 | scripts/karu（新）, scripts/bundle-macos.sh（红线，main） | main | 终端 `karu file` 可唤起 app 打开文件 | ✅ 实测新建+打开 OK；bundle 1.4 MB |

用户实测背景（T8.1 依据）：同窗口同 200 行 md，两 app 静态均 ~80 MB（窗口 backing
store 主导，符合预期）；CotEditor 快速滑动内存翻倍但停止即回落、滑动更顺；
Karu 因 viewport 动态加载，快滑有可见的加载等待痕迹。

## M9 开源准备（2026-07-21）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T9.1 | 产品改名 TinyEditor → **Karu**（避开 OpenTiny TinyEditor 撞名；bundle ID `dev.enkin.TinyEditor` 为 APNs 红线**保留不改**，keychain 公证 profile `tinyeditor-notary` 保留）；SPM target/CLI/文档/快照环境变量（KARU_SNAPSHOT）全量更名 | 全仓库（红线脚本主会话改） | main | 全量重建 + 325 测试全绿 + 冒烟 + 基准 | ✅ v0.5.0/build 7 |
| T9.2 | 修复 T8.3 引入的大文件内存回归：LineEnding.detect 的 `Array(text.unicodeScalars)` 物化整文档（10 MB 文件 +40 MB 常驻，基准 99 MB 爆表）→ 改流式单遍扫描 O(1) 内存 | Core/TextModel/LineEnding.swift | main | 基准 large.py 回到 ≤65 | ✅ 99→59 MB；worktree 二分定位 |
| T9.3 | 视觉冒烟深色模式误报：夜间系统自动深色使"亮色纸面>50%"阈值失效 → 快照钩子强制 aqua 外观，像素判定确定化 | App/AppDelegate.swift | main | 深色系统下 VISUAL OK | ✅ |

## M10 开源前 bug 修复（2026-07-21 用户反馈第六轮）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T10.1 | 标题栏透明致标题与文本重叠（macOS 26 Liquid Glass）：内容 stack 锚定 contentLayoutGuide + 显式不透明标题栏；快照钩子增强（整窗捕捉/外观/滚动参数）但未能静态复现，待用户实测确认 | Editor/EditorWindowController.swift, App/AppDelegate.swift | main | 用户复测不再重叠 | ✅ 防护已上，待用户确认 |
| T10.2 | 内置函数（print/open 等 builtins）高亮 + 变量声明模式补漏 + VS Code Dark/Light Modern 风格配色（动态外观） | Highlight/, Completion/WordIndex.swift | implementer | builtin 染色测试；深浅色快照 | ✅ 14 新测试；主会话补 tokenizer 边界修复（.withTransparentBounds，main 内 in 误染类 bug 根治）|
| T10.3 | Format Document 快捷键 ⌃⇧F → ⌥⇧F（VS Code 同款） | App/MainMenu.swift | main | 菜单显示 ⌥⇧F | ✅ |
| T10.4 | iCloud 未下载文件：双击触发下载但不打开、再次双击开双窗 → 下载中窗口 + 轮询完成自动载入 + 同 URL 去重 | App/AppDelegate.swift, Editor/ | implementer | 去重/占位名换算单测；双击两次 windows=1 | ✅ 18 新测试；无 iCloud 测试环境，真机行为待用户确认 |
| T10.5 | 开源准备：MIT LICENSE、git remote（github.com/enkin-japan/karu）、README、首个 Release | LICENSE, README.md | main | push 成功、Release 挂 DMG | ✅ v0.6.0 |

## M11 一键更新 + 用户反馈第七轮（2026-07-21）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T11.1 | Sparkle 2 一键更新：SPM 依赖 + rpath、框架嵌入与由内向外签名（红线脚本）、EdDSA 密钥（私钥 keychain）、Info.plist 三键、发布脚本产 Karu.zip 签名 + appcast.xml；体积预算修订 5→10 MB（内存不动，实测集成后 32 MB 持平） | Package.swift, App/UpdateController.swift（新）, AppDelegate, MainMenu+L10n（待）, scripts/bundle-macos.sh, scripts/release-macos.sh, docs/ARCHITECTURE.md | main（红线） | 更新弹窗可用；mem-benchmark 不涨 | ✅ 菜单接线完成；集成后启动 32 MB 持平；v0.7.0 首发自动更新 |
| T11.2 | 设置窗口被主窗口压住：activate + moveToActiveSpace + orderFrontRegardless | App/AppDelegate.swift | main | 任何状态下点设置必到最前 | ✅ |
| T11.3 | 缩进空格灰色圆点（VS Code 风格，绘制期现场算，随 rainbow 开关） | Editor/EditorTextView.swift, Gutter/IndentRainbow.swift | implementer | 深浅色快照可见 | ✅ 快照确认 |
| T11.4 | 标题栏文件名胶囊点击改名（方框+背景色差暗示；DocumentController.rename 可单测；untitled 不启用） | Editor/TitleRenameControl（新）等 | implementer | rename 校验单测；快照确认胶囊 | ✅ 6 rename 测试 |
| T11.5 | Ctrl+G 直达某行（预算评估：瞬时面板+复用 LineIndex，常驻 ≈ 0，绿灯）；键位对齐 VS Code | Editor/GoToLineController（新）, MainMenu, L10n | implementer | parseLineInput 单测；跳转选中滚动正确 | ✅ 370 全绿 |

## M12 Monaco 对比采纳 + 用户反馈第八轮（2026-07-22，决议见 notes/monaco-gap-analysis.md，不入仓库）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T12.1 | bug：⌥⇧F 变成输入特殊字符——无 ⌘ 的 Option 组合菜单匹配不可靠，落入 keyDown 被插入"Ï"。EditorTextView 键路径前置拦截 → 发 formatDocument 到响应链 | Editor/EditorTextView.swift | implementer | 静态匹配函数单测；实际按键不再插入字符 | ✅ 7 测试 |
| T12.2 | 关闭确认按**内容**判定：DocumentController 存基线 SHA256（load/save/reload/init 时更新，常驻 32 字节），关闭/重开确认时瞬时比对，undo 回原文不弹窗 | App/DocumentController.swift, Editor/EditorWindowController.swift | implementer | 基线转移单测（load→edit→undo 回原文 = clean）；suite 全绿 | ✅ 6 测试，383 全绿 |
| T12.3 | A1 注释切换 ⌘/：per-language 行/块注释表 + 纯文本变换 | Editor/CommentToggle（新）, MainMenu, L10n, Languages | implementer | 变换纯函数单测（含块注释语言）；370+ 全绿 | ✅ 13 测试 |
| T12.4 | A2 行操作：上移/下移 ⌥↑↓、复制行 ⇧⌥↑↓、删除行 ⌘⇧K（join 暂不做） | Editor/LineOperations（新）, MainMenu, L10n | implementer | 纯函数单测（选区保持/首尾行边界）；undo 正确 | ✅ 15+9 测试 |
| T12.5 | A6 字体缩放：新建"视图"菜单，放大 ⌘+ / 缩小 ⌘- / 实际大小 ⌘0，UserDefaults 持久 | Editor/, MainMenu, L10n, Settings | implementer | 缩放范围钳制单测 | ✅ 6 测试；视图菜单新建 |
| T12.6 | A4 自动闭合括号/引号 + 选中包裹（右侧已闭合跳过、词内引号不闭合；设置开关默认开） | Editor/AutoClosePairs（新）, EditorTextView, Settings | implementer | 决策纯函数单测（成对/跳过/包裹/词内） | ✅ 16 测试 |
| T12.7 | A3 括号配对高亮 + ⌘⇧\ 跳转（viewport 扫描，temporary attributes） | Editor/BracketMatcher（新）, EditorWindowController, MainMenu | implementer | 配对定位纯函数单测（嵌套/字符串内跳过可后补） | ✅ 13 测试，455 全绿 |
| T12.8 | A5 命令面板 ⌘⇧P：枚举主菜单树 + 模糊过滤，复用瞬时面板模板 | Editor/CommandPalette（新）, MainMenu, L10n | implementer | 过滤/枚举单测；执行走 performActionForItem（validate 链尊重） | ✅ 11 测试 |
| T12.9 | A7 光标词高亮（viewport 内同词匹配，debounce，temporary attributes 独立通道） | Editor/WordOccurrenceHighlighter（新） | implementer | 词边界匹配单测；快照可见 | ✅ 11 测试；>1 处才涂色 |
| T12.10 | A8 不可见/易混淆字符警示 + 异常行终止符（viewport 正则 + 着色边框） | Editor/UnicodeAlert（新） | implementer | 检测纯函数单测（零宽/BOM/双向控制/LS·PS） | ✅ 10 测试，487 全绿；同形字表 v1 不做（~100KB 违背轻量） |
| T12.11 | E2 状态栏选中字符数（选区>0 显示"已选 N 字符·M 行"，UTF-16 口径 O(1)） | Editor/EditorWindowController.swift, StatusBarView, L10n | chore-worker | 有/无选区状态切换；三语 key 完整性测试 | ✅ 5 测试，492 全绿 |
| T12.12 | E3 一键折叠/展开：视图菜单 + 折叠当前块 ⌥⌘[/⌥⌘] + 全折/全展（⌘K ⌘0 / ⌘K ⌘J 前缀和弦状态机）；isHidden 改二分 | Editor/FoldingController, EditorTextView, MainMenu, L10n | implementer | foldAll/unfoldAll/当前块单测；和弦状态机单测 | ✅ 16+11 测试 |
| T12.13 | E4 折叠跨编辑保持：行号三规则维护（上方保留/下方平移/相交展开）+ applyFolds 定向失效 | Editor/FoldingController.swift | implementer | 平移/相交/undo 测试矩阵；10MB 逐键无卡顿 | ✅ 519 全绿；2000 行全折+50 键 0.23s；applyFolds 定向失效 |
| T12.14 | E1 失焦自动保存（默认关，设置开关；失败静默回 dirty + 状态栏提示，绝不弹窗；untitled 跳过） | App/, Editor/, Settings, L10n | implementer | 触发条件纯逻辑单测；开关持久 | ✅ 7 测试；失败静默降级+状态栏瞬时提示 |
| T12.15 | C8 CSS 颜色装饰器（viewport 正则 + 色块 attachment-free 绘制） | Editor/ColorDecorator（新）, Highlight | implementer | 颜色解析单测（hex/rgb/hsl/命名色） | ✅ 16 测试，542 全绿 |
| T12.16 | A9 语言定义扩充：YAML / TOML / Go / Rust / Swift（懒加载；Ruby/PHP/Kotlin/INI/Dockerfile 留积压） | Highlight/Languages/*（新×5）, SupportedLanguage | implementer | 每语言 tokenizer 测试；builtins 高亮 | ✅ 26 测试，568 全绿；CommentToggle/符号导航/缩进宽度一并接线 |
| T12.17 | 文档对齐（README×3 功能项、ARCHITECTURE 语言数、变更记录）+ v0.8.0 发布（版本号红线文件 main 改） | README*, docs/, scripts/bundle-macos.sh | chore-worker + main | 370+ 全绿、visual-smoke、mem-benchmark、公证发布 | ✅ v0.8.0 已发布：568 全绿、基准 27/48/63 PASS、公证+装订+DMG、三资产上线，appcast 实测解析 0.8.0/build10 含 EdDSA 签名。发布时曾受阻于 sign_update 钥匙串 ACL 弹窗，用户点击"始终允许"后恢复 |

| T12.18 | bug：空文档开头输入 `[]` 等闭合符后整篇字体变小——自动闭合 insertPair/wrap 用裸字符串写 textStorage，位置 0 无前文属性可继承，跌落到默认小字体。改为携带 typingAttributes 的 NSAttributedString 插入 | Editor/EditorTextView.swift | main | 空文档 insertPair/wrap 后 .font 属性 = 编辑器字体 | ✅ 2 回归测试 |
| T12.19 | ⌘⏎ 无视光标位置在下方开新行（VS Code Insert Line Below；保留当前行缩进；键路径和弦拦截，无菜单项） | Editor/LineOperations.swift, EditorTextView, EditorWindowController | main | 纯函数单测（中间/末行无换行/空文档/缩进保持/选区取末行）；579 全绿 | ✅ 9 测试 |

（B1 多光标维持独立里程碑不混排；C 组除 C8 外按决议不做。）

## 依赖关系

T1.1 → T2.1 → T2.2/T2.3/T2.4（可并行）→ T3.1 → T3.2/T3.3（可并行）→ T3.4/T3.5
T4.1/T4.2 仅依赖 T1.1；T4.3 依赖 T2.2；T1.2 随时可做；T5.* 最后。

## 环境约束（委派时必须告知子代理）

- 本机仅有 Command Line Tools，无完整 Xcode：**没有 XCTest**，单元测试一律用 Swift Testing
  （`import Testing`、`@Test`、`#expect`）；构建/测试命令为 `swift build` / `swift test`。
- 涉及 AppKit 的测试代码需标注 `@MainActor`。
- **SPM 增量编译偶发陈旧**（本会话已两次遇到）：逻辑正确的改动测试却失败时，先
  `rm -rf .build` 全量重建再判定，不要空转排查。
- 视觉验证：`KARU_SNAPSHOT=<png> .build/<cfg>/KaruApp [file]` 让 app 自渲染快照
  （无需录屏权限）；`scripts/visual-smoke.sh` 为防"空白窗口"类回归的守门脚本，UI 改动后必跑。

## 变更记录

- 2026-07-21 v0.3.0（M7 第四轮反馈收官）：Finder 打开不再多开空窗；VS Code 式缩进检测；
  折叠箭头加大+折叠头行高亮+行数提示；文档符号高亮（函数/类/变量三色）。281 测试全绿，
  内存基准三轮 PASS（27/46/61 MB），公证出包 968 KB。

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
