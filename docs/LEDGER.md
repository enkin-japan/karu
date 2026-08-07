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

| T12.20 | 排查：空文档打字 30→110 MB——结论**非泄漏非回归不计预算**（证据链六条见 ARCHITECTURE.md §1 测量口径：v0.7.0 同数值、图形内存主导、持续输入平台线不涨、遮挡可回收、工具栏×首次重绘×beta 合成器触发、静态打开不触发）。正式版 macOS 后复测 | docs/ARCHITECTURE.md | main | 同环境对照 + 归因拆分 | ✅ |

| T12.21 | 恶性 bug：粘贴完全失效——macOS 26 beta(26A5388g) 上 pasteAsPlainText × readablePasteboardTypes=[.string] 组合静默 no-op（最小子类二分锁定）。paste 改显式实现：读剪贴板（.string→attributed 回退）→ typingAttributes 属性化插入走 undo 通道，脱离系统私有管线 | Editor/EditorTextView.swift | main（紧急） | 粘贴/替换选区/剥富文本/可 undo 四回归测试 | ✅ 4 测试 |
| T12.22 | 恶性 bug：打字中崩溃（用户崩溃报告）——FoldScanner 无界信任 LineIndex 偏移读字符串，beta display-link 合成时序下与编辑事务交错失同步 → characterAtIndex 越界。三层修复：①扫描器长度守卫（失同步跳过本帧，装饰系统无崩溃权）②折叠编辑内/绘制内的布局失效推迟到事务外 ③IndentRainbow 等其余绘制期消费者审计（均已有界内检查） | TextModel/FoldRegion.swift, Editor/FoldingController.swift | main（紧急） | 失同步对不崩测试；打字/undo/IME 全程 LineIndex 同步压力测试 | ✅ 3 测试，586 全绿 |

（B1 多光标维持独立里程碑不混排；C 组除 C8 外按决议不做。）

## M13 用户反馈第九轮：识别空档 + 折叠统一 + Markdown 折叠 + 桌面惯例（2026-07-28）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T13.1 | 语言识别空档补齐：另存为 / 标题栏改名后若**扩展名变化**立即重跑识别（扩展名优先，内容嗅探兜底）；同扩展名操作不打扰手动选择 | Editor/EditorWindowController.swift | main | 改名换扩展名→重识别、同扩展名→保留手动选择，2 回归测试 | ✅ 588 全绿 |
| T13.2 | 折叠 UI 统一 VS Code 样式：①缩进区域尾部收缩，纯闭合符号行（`]` `},` `]);`）不再被冒号区域吞掉，一键折叠与单独折叠同块结果一致、闭合括号永远可见 ②折叠头 "⋯ N" 改 "⋯" ③⌥⌘[ 重复按向外折叠一层 | TextModel/FoldRegion.swift, Editor/FoldingController.swift, Editor/EditorTextView.swift | implementer | 反例文档 foldAll 后闭合行可见；向外折叠累积；6 新测试全绿 + visual-smoke | ✅ 594 全绿 |
| T13.3 | 一键折叠/展开键位 ⌘K ⌘0 / ⌘K ⌘J——复盘确认 T12.13 已实现（ChordStep 状态机，Esc 可取消），无需改动 | Editor/EditorTextView.swift | main | 复盘既有实现与测试 | ✅ 已存在 |
| T13.4 | Markdown 折叠：FoldScanner 增语言参数，markdown 停用括号/冒号规则，改 ATX 标题分节（≤3 前导空格，子标题嵌套，Setext 不做）+ 围栏代码块（```/~~~，闭栏行可见，未闭合折到文末，栏内 # 不当标题）；FoldingController 经 languageProvider 按需读语言 + noteLanguageChanged 缓存失效；languageIdentifier 四赋值点收拢单一 helper | TextModel/FoldRegion.swift, Editor/FoldingController.swift, Editor/EditorWindowController.swift | implementer | 分节/围栏/抑制通用规则/语言切换缓存失效，17 新测试全绿 + visual-smoke | ✅ 611 全绿 |
| T13.5 | 程序坞图标右键菜单"新建窗口"（applicationDockMenu，三语） | App/AppDelegate.swift, L10n | main | 构建通过，菜单随 UI 语言 | ✅ |
| T13.6 | 设置窗口 Esc 关闭（PreferencesWindow 子类拦 keyCode 53） | Settings/PreferencesWindowController.swift | main | 构建通过 | ✅ |
| T13.7 | 框选字符数**拖拽中实时**统计：AppKit 拖选以 stillSelecting 抑制选区通知，EditorTextView 覆写 setSelectedRanges 回调仅刷状态栏（括号/词高亮仍等选区定稿） | Editor/EditorTextView.swift, Editor/EditorWindowController.swift | main | 构建通过，零常驻 | ✅ |
| T13.8 | 用户实测反馈：⌘K ⌘0/⌘K ⌘J 无反应——⌘0 同时是"实际大小"菜单键位，菜单匹配在 keyDown 之前吃掉和弦第二键。和弦机抽 handleFoldChord，⌘ 步骤改 performKeyEquivalent 消费（视图先于菜单）；未武装原样放行；失焦不拦截 | Editor/EditorTextView.swift | main | 消费/放行/失焦 3 回归测试 | ✅ 614 全绿 |
| T13.9 | 用户实测反馈：折叠幽灵空行 + 闭合括号错位/消失（debug/test.json 截图）——真机 KARU_FOLDTEST 钩子 + 片段几何转储实锤：.null 字形令 typesetter 连隐藏换行一起跳过，段落熔合成跨隐藏/可见边界片段，零高塌缩永不触发；rig 环境 typesetter 行为不同故单测全绿（环境敏感回归）。修复：隐藏换行保留字形属性；布局失效延伸到文末；rainbow/缩进点/被吞折叠头跳过隐藏行。守门：visual-smoke.sh 增真机折叠几何校验 | Editor/FoldingController.swift, Editor/EditorTextView.swift, App/AppDelegate.swift, scripts/visual-smoke.sh | main | 真机几何断言（闭合行紧贴头行、隐藏行全塌缩）+ 3 rig 几何测试 | ✅ 617 全绿 + FOLD GEOMETRY OK |
## M14 用户反馈第十轮：体验优化批（2026-07-30）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T14.1 | 拉伸窗口行号不刷新：重排换行移动所有行片段但不触发 gutter 已监听的三种通知——补 textView frameDidChange 观察（高亮引擎早已监听，gutter 漏了） | Gutter/GutterView.swift | main | 构建通过 | ✅ |
| T14.2 | ⌘←/⌘→ 到逻辑行首/行末（软换行不影响）；行首 VS Code Home 语义（首个非空白⇄列 0 切换）；⇧ 选择变体同步 | Editor/EditorTextView.swift | main | 纯函数 6 测试 | ✅ |
| T14.3 | 第二个及以上窗口右下错开 24pt（共享 frame 自动保存槽致完全重叠）；越界回卷屏幕左上 | App/AppDelegate.swift | main | 构建通过 | ✅ |
| T14.4 | 补全弹窗移到光标上方（中文输入法候选窗在下方被遮，用户反馈）；上方不足回退下方 | Completion/CompletionController.swift | main | 构建通过 | ✅ |
| T14.5 | markdown 补漏：列表标记 .punctuation→.property（原色同正文视觉无高亮）；补 ***粗斜***/___粗斜___/~~删除线~~ 规则。代码块按语言高亮**搁置**（预算大，用户决议） | Highlight/Languages/MarkdownLanguage.swift | main | 3 新测试 + 1 旧预期更新 | ✅ |
| T14.6 | 第三个连续引号补全三引号对（Python """/'''，``` 围栏同规则受益）；decide 加 charBefore2 参数 | Editor/AutoClosePairs.swift, Editor/EditorTextView.swift | main | 3 新测试（补全/两连不触发/stepOver 优先） | ✅ |
| T14.7 | Python 三引号体内仍套代码高亮（用户 bug）：LanguageDefinition 加 multilineStringDelimiters（仅 Python），引擎画带起点瞬时扫描跨行状态（零常驻），体内行合成 .string token 兼堵 symbol 层，关闭行只 tokenize 尾部；'''/"""互不关闭；# 内定界符误翻转为文档化 v1 近似 | Highlight/HighlightEngine.swift, LanguageDefinition.swift, Languages/PythonLanguage.swift | implementer | 7 测试含端到端属性断言 | ✅ 636 全绿 |

| T14.8 | 会话恢复方案 A：SessionStore 随开随记（open/改名/失焦/关窗/退出五点），主动关窗移除、随退出关窗保留（isTerminating 区分），冷启动恢复文件+光标+滚动，已删文件静默清理，64 项上限 | App/SessionStore.swift（新）, App/AppDelegate.swift, Editor/EditorWindowController.swift | implementer | 13 测试（隔离 defaults suite）+ 真机三连跑 | ✅ 649 全绿 |

| T14.9 | 恢复语义对齐（用户拍板：正常退出不恢复，仅升级/崩溃恢复）：SessionStore 三态标志（beginSession 置进行中 / markCleanExit / markUpdateRelaunch），Sparkle updaterWillRelaunchApplication 委托探测升级重启；不恢复的启动清遗留清单。真机双向验证 | App/SessionStore.swift, App/UpdateController.swift, App/AppDelegate.swift | main | 4 策略测试 + 真机（正常退出不恢复/kill -9 恢复） | ✅ |
| T14.10 | 缩进感知退格：行首纯空格区退格删至缩进宽度下一较低倍数（宽4：11→8→4→0，9→8，用户规格）；行内文本/tab 前缀回退默认 | Editor/EditorTextView.swift | main | 纯函数 + 端到端 undo 4 测试 | ✅ 657 全绿 |

| T14.11 | 崩溃草稿（原方案 B 语义收窄后落地）：裁决规则"草稿存在⟺缓冲区≠SHA256基线"（与关闭确认同判据）；全部窗口；防抖 1.5s 原子落盘（主线程快照+串行 utility 队列）；终止获准即清（升级重启同理——退出前确认已处理脏窗口）；恢复：未命名/按 path 归位/磁盘较新弃草稿提示/孤儿转未命名；L10n 三语三条 | App/DraftStore.swift（新）, App/AppDelegate.swift, Editor/EditorWindowController.swift, L10n | implementer | 17 测试 + 真机三连（kill -9 恢复/正常退出清空/视觉） | ✅ 674 全绿 |

（本轮决议：粘贴 Python 不识别复现失败按偶发搁置；markdown 代码块按语言高亮搁置待重提。
**方案 B（未命名草稿恢复）搁置备案**：需草稿落盘机制 + 三个产品语义决策——①主动关闭未命名窗口
草稿删不删 ②与失焦自动保存/SHA256 关闭确认的交互 ③大缓冲区落盘 I/O 策略；另有"未保存内容
悄悄写盘"的隐私考量。预算约为方案 A 的 3–4 倍。待真实需求出现再重提。）

v0.9.8 发布（2026-08-05）：T15.7 备忘录借鉴批（纯文本待办 + 列表接续 + URL ⌘点击）+
  T15.8 保存框改面板 sheet + 链接悬浮提示 + T15.9 待办改 ⇧⌘L/⇧⌘U 双开关（用户否决三态
  循环后拍板）。三批本机预装实测通过后发版；latest appcast 解析 0.9.8/build 21；
  Gatekeeper "Notarized Developer ID"；发版后本机同步装 0.9.8（实测期本地为未升号
  构建，曾致"提示更新但更新出错"——发版尾装机为固定流程，消除该错位）。

v0.9.7 发布（2026-08-05）：T15.5 五项（查找栏双行+不遮首行、跨桌面、逻辑行移动、
  删除残影修复）+ T15.6 全屏候选栏判定平台限制（发布说明列为已知限制）。本机预装实测
  通过后发版；latest appcast 解析 0.9.7/build 20；Gatekeeper "Notarized Developer ID"。

v0.9.6 发布（2026-07-31）：T15.3/T15.4 草稿本打磨两批（行号字号联动 + 字号解耦 +
  查找替换 + 系统标题栏回归 + 最小宽度 + 缩放键路由）。本机预装实测通过后发版（新流程首例）；
  latest appcast 解析 0.9.6/build 19；Gatekeeper "Notarized Developer ID"；DMG 3.2 MB。

v0.9.5 发布（2026-07-31）：T15.2 草稿本图钉可见性修复 + 行号。全程无人值守；
  latest appcast 解析 0.9.5/build 18；Gatekeeper "Notarized Developer ID"；DMG 3.2 MB。

v0.9.4 发布（2026-07-31）：T15.1 常驻草稿本（⌥D 全局热键 + 非激活浮动面板 + 驻留形态）。
  签名探路通过，全程无人值守；latest appcast 解析 0.9.4/build 17；Gatekeeper "Notarized
  Developer ID"；DMG 3.2 MB。

v0.9.3 发布（2026-07-30）：T14.9–T14.11（恢复语义门控 + 缩进感知退格 + 崩溃草稿）。
签名探路通过，全程无人值守；latest appcast 解析 0.9.3/build 16。
v0.9.2 发布（2026-07-30）：M14 全部八项（T14.1–T14.8，会话恢复方案 A + 体验优化批）。
签名探路通过后全程无人值守；latest appcast 解析 0.9.2/build 15。
v0.9.1 发布（2026-07-28）：用户实测反馈两修复（T13.8 和弦被菜单截胡 / T13.9 折叠渲染
片段熔合）。发布前小签名探路生效；全程无人值守；latest appcast 解析 0.9.1/build 14。
v0.9.0 发布（2026-07-28）：M13 全部七项（T13.1–T13.7）。首跑因登录钥匙串锁定在第一签
失败（errSecInternalComponent，久未发布后锁屏/重启所致；已入记忆——发布前先做小签名探路），
用户解锁后重跑全程无人值守。latest appcast 解析 0.9.0/build 13；Gatekeeper
"Notarized Developer ID"；DMG 3.1 MB。
v0.8.2 发布（2026-07-22）：T12.21/T12.22 两恶性 bug 紧急修复。全程无人值守（钥匙串
"始终允许"生效）；latest appcast 解析 0.8.2/build 12。
v0.8.1 发布（2026-07-22）：T12.18/T12.19 + T12.20 排查结论。三资产上线，latest appcast
实测解析 0.8.1/build 11；sign_update 钥匙串 ACL 已获"始终允许"，后续发布可无人值守。

## M15 常驻草稿本（2026-07-31，交互方案与热键经两轮对齐定案）

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T15.1 | 常驻草稿本：全局热键 ⌥D（Carbon RegisterEventHotKey，免辅助功能权限，设置可录制改键+恢复默认）+ 非激活浮动面板（.nonactivatingPanel，唤出不切换活跃 app，隐藏焦点自动归还）；纯文本无格式（有意不用 EditorTextView）；无保存语义（1.5s 防抖落盘，独立于崩溃草稿）；Esc/⌘W/关闭钮=隐藏，图钉切换失焦保留（默认保留）；⌘S 毕业为真文件并转入编辑器窗口（首行建议文件名）；隐藏即整体拆除（undo 栈随拆有意丢弃），常驻仅热键注册+菜单栏项；驻留（用户拍板）：last-window-close 不退出 + NSStatusItem 菜单 + Dock 点击重开窗口；KARU_SCRATCHTEST=show/cycle 真机诊断钩子 | Scratchpad/ScratchpadStore.swift（新）, Scratchpad/ScratchpadController.swift（新）, App/HotKeyCenter.swift（新）, App/AppDelegate.swift, App/MainMenu.swift, Settings/PreferencesWindowController.swift, L10n/* | implementer | 14 新测试 + visual-smoke + 双钩子 dump（panelVisible/hotkeyStatus=0；panelNil=true/落盘内容） | ✅ 688 全绿 |

| T15.2 | 实测反馈：图钉不可见——titlebar accessory 在 utility 面板注册成功（count=1）但小标题栏不渲染（像素快照实证）；改为面板内容右上角叠放按钮。行号（用户请求）：复用 GutterView，每次 show 现建 LineIndex+ObserverHub 随 hide 拆除，隐藏态零常驻不变。show 钩子补 titlebarAccessories 计数 + KARU_SCRATCHTEST_PNG 像素快照（本 bug 即靠它定位） | Scratchpad/ScratchpadController.swift, App/AppDelegate.swift | main | 像素验证行号+图钉可见；cycle 钩子拆除+落盘不回退；688 全绿 + visual-smoke | ✅ |

| T15.3 | 打磨批（实测反馈六项）：①行号字体跟随正文字号+留白按字号比例（18pt 时各 3pt）+去 40pt 硬地板，宽度规则抽纯函数；②字号变化实时刷新 gutter（编辑器与草稿本同修，原需点击文本）；③草稿本字号解耦（scratchpad.fontSize，缺省活继承编辑器、设置后独立，⌘+/⌘-/⌘0 面板内直调不再误动全局，设置窗新行）；④自绘 20pt 标题 header（utility 系统标题无法调大）+图钉搬入 header 右侧+小手光标+header 可拖窗；⑤查找替换复用 FindBarController（仅依赖 NSTextView+LineIndex，与 gutter 共享同一 LineIndex，⌘F 唤出，Esc 先关查找栏再隐面板）；show 钩子补 fontSize 字段 | Gutter/GutterView.swift, Editor/EditorWindowController.swift, Scratchpad/*, Settings/PreferencesWindowController.swift, L10n/*, App/AppDelegate.swift | implementer | 10 新测试；像素验证标题/图钉/行号缩放/查找栏；cycle 拆除不回退；698 全绿 + visual-smoke | ✅ |

| T15.4 | 实测反馈四项（自绘 header 被否）：①标题恢复系统标题栏，CJK 短标题加全角空格（"草　稿　本"，纯函数+测试）；②styleMask 弃 .utilityWindow 换标准标题栏→图钉进标题栏 accessory（标准栏可渲染，utility 才是 T15.2 的祸根）+小手光标；③最小宽度暴增修复：查找栏 660pt 固有最小宽度经 stack fitting 约束传导到窗口，改为浮层叠放文本上方+右缘 480 优先级（**必须 <500**：NSWindow 会主动扩窗满足 >windowSizeStayPut 的约束，900 实测被拖回 682），contentMinSize 280×160，窄窗右侧裁剪；④缩放键误改全局字号：菜单键等价匹配抢在视图层之前，AppDelegate zoom 三动作按键窗口路由到草稿本（双保险），合成事件钩子 KARU_SCRATCHTEST=zoom 真实路径复现（editor 13→13，pad 13→14）；show 钩子补 frameW/title/fitting 几何 + KARU_SCRATCHTEST_NARROW 窄宽压测 | Scratchpad/ScratchpadController.swift, App/AppDelegate.swift | main | zoom 钩子 editor 不动 pad 动；窄宽 280 实测；像素验证标题/图钉；699 全绿 + visual-smoke | ✅ |

| T15.5 | 实测反馈五项：①查找栏遮首行+窄窗按钮不可见——FindBarController 增紧凑双行模式（compact init 参数，编辑器单行不动），草稿本查找栏改回参与布局（onVisibilityChanged 切换 scrollView.top 双约束，显示时推文本下移），contentMinSize 取紧凑条实测 fitting 宽度 max(340,…)；②全屏 Space 输入法候选栏消失——疑似 .moveToActiveSpace 钉死桌面所致，随③一并缓解，待用户实测（若仍复现则判 macOS 27 beta）；③跨桌面：.canJoinAllSpaces 替换 .moveToActiveSpace；④⌘←/→ 逻辑行首行末：ScratchpadTextView 四个 moveToLeft/RightEndOfLine 覆写复用 EditorTextView 静态纯函数；⑤全局删除残影——KARU_GHOSTTEST 两轮复现均 ghostPixels=0（cacheDisplay 全量重绘必然干净）反证缺陷在失效标记而非绘制：收缩腾出的区域从未被标脏，屏幕留旧像素；新增 ShrinkRepaintObserver（编辑器+草稿本共用，删除时把编辑行顶至可视区底的带标脏），像素级验证依赖用户实测 | Search/FindBarController.swift, Scratchpad/ScratchpadController.swift, Editor/ShrinkRepaintObserver.swift（新）, Editor/EditorWindowController.swift, App/AppDelegate.swift | implementer(①③④)+main(⑤+钩子) | 像素验证首行可见+按钮齐全；340 最小宽度；704 全绿 + visual-smoke | ✅ |

| T15.6 | 全屏 Space 输入法候选栏消失——排查终结：实验开关 scratchpad.activateOnShow 真机 A/B（用户执行）证明**激活状态不是关键变量**（程序化激活不跳 Space、焦点归还正常，但候选栏依然不出现；⌘Tab 激活则会被拽离全屏 Space）。app 侧可控变量已穷尽（激活态、Space 归属 canJoinAllSpaces、fullScreenAuxiliary），候选窗能否加入他人全屏 Space 由输入法进程+窗口服务器决定，第三方无公开手段。判定：平台层限制（macOS 27 beta，正式版有修复可能但无保证）。实验代码已 revert，记为已知限制，正式版发布后复测；届时仍复现则提交 Apple Feedback | Scratchpad/ScratchpadController.swift（实验后已还原） | main | 实验结论入档 | ✅ 搁置（平台限制） |
| T15.7 | 备忘录借鉴批（三步漏斗筛选，纯文本红线零妥协）：①三态待办——`- [ ] `/`- [x] ` 为字面字符（任何编辑器打开仍是干净纯文本），⇧⌘L/标题栏按钮循环 plain→未勾→已勾→plain（批量：选区含 plain 全部加标记原地；否则含未勾全部勾选**沉底**；否则全去标记），点击勾选框单行翻转（勾选沉底，取消勾选回插最后一个 `- [ ] ` 行之后，无则第一个 `- [x] ` 前，皆无原地），标记+移动经 minimalEdit 收敛为**单次 replaceCharacters**（一个撤销步、布局仅失效受影响段），光标随行迁移，仅按钮/快捷键/点击触发移动（手打 `- [x]` 不动）；②列表自动接续——⏎ 延续 `- [ ] `（新条目恒未勾）/`- `/`* `/`N. `（N+1 不重排），空条目 ⏎ 退出，前缀内/选区/IME 组字中走原生换行；③URL 识别 ⌘点击（编辑器+草稿本共享）——LinkDetector 仿 ShrinkRepaintObserver 挂 hub，0.3s 防抖 NSDataDetector 全文扫描（>1MB 跳过、>2000 链接放弃），仅 http/https/mailto，装饰走 layoutManager **临时属性** underline 通道（.foregroundColor 归 HighlightEngine 独占，绝不入 textStorage——画出来不存），⌘点击须命中链接自身 glyph rect 且片段整体即链接方开启；标题栏 accessory 扩 34→62pt 双按钮（图钉原位不动），双按钮 toolTip 含快捷键（⇧⌘L/⇧⌘P，面板无菜单、tooltip 是唯一可发现性入口），⇧⌘P 与图钉同路径 | Scratchpad/TodoEngine.swift（新）, Editor/LinkDetector.swift（新）, Scratchpad/ScratchpadController.swift, Editor/EditorTextView.swift, Editor/EditorWindowController.swift, L10n/* | implementer | 43 新测试（三态/批量/沉底回插/光标跟随/文末无换行/接续/minimalEdit 代理对/链接 scheme 过滤） | ✅ 747 全绿，已装本机待实测 |
| T15.8 | 实测反馈两项：①⌘S 保存框被他 app 窗口遮挡（非全屏）/落在非全屏 Space 且不自动跳转（全屏）——根因：macOS 14+ 激活变协作式，非活跃 app 的 `runModal` 窗口可落于活跃 app 之后；修复：保存框改为**挂在草稿本面板上的 sheet**（`beginSheetModal(for: panel)`），sheet 是面板子窗口→同 Space（含他人全屏）、恒在面板之上、免激活拿 key（与面板同机制）；写盘失败 alert 同改 sheet；isGraduating 三重防护（二次 ⌘S/失焦隐藏/热键拆面板压 sheet）；KARU_SCRATCHTEST=save 探针实证 sheetAttached/sheetIsKey/panelVisible 全 true（本轮曾被陈旧 .build 骗跑旧 runModal 代码，sample 栈定位，第 6 次）；②链接悬浮提示"⌘点击打开"——LinkDetector 每条链接按 enclosing rects 注册 NSView toolTip 区域（软换行每段一块），编辑后随装饰清除重建，视图 resize 重排矩形（搭 gutter 已开的 frame 通知便车），三语 | Scratchpad/ScratchpadController.swift, Editor/LinkDetector.swift, App/AppDelegate.swift, L10n/* | main | save 探针三项 true；747 全绿 | ✅ 已装本机待实测（全屏 Space 下 sheet 位置需真机确认） |
| T15.9 | 待办三态循环被否（已完成再按直接变普通行反直觉；1~2s 时间窗方案亦否——同键快慢异义无法建立肌肉记忆）→ 改**两个正交开关**（用户拍板）：⇧⌘L"是不是待办"——plain 加 `- [ ] `/全标记则去标记（checked 一步变普通行，完成态显式丢弃），混合选区只给 plain 行加标记、已勾选行原样不动（markUnchecked 不再重置 `- [x] `），**永不移动行**；⇧⌘U"完成没完成"——唯一移动入口，任一未勾→全部勾选整块沉底，全已勾→全部取消整块回插（uncheckReturnIndex 批量版，fallback 同单行），plain 行不参与、纯 prose 选区 no-op（⇧⌘U 不越权建清单）；点击勾选框/⏎ 接续/undo 路径不变；⇧⌘U 全菜单零占用（grep 实证）；待办按钮 tooltip 三语扩为双快捷键（面板无菜单，tooltip 是唯一可发现性入口） | Scratchpad/TodoEngine.swift, Scratchpad/ScratchpadController.swift, L10n/Strings.swift | implementer | 42 项引擎测试（9 cycle 删 17 新增）；755 全绿 | ✅ 已装本机待实测 |
| T15.10 | 实测反馈两 bug（v0.9.8 回归为主）：①264KB md 打开必崩——崩溃报告栈取证：LinkDetector 扫描后 addToolTips 对全文档链接取 glyph 矩形强制填布局洞→textView 长高→frameDidChange **同步**重入 addToolTips→递归爆栈（栈内循环 4 次可见，`Thread stack size exceeded`）；修复：tooltip 只按**可见区**链接注册（滚动/缩放换批，不再强制全文档布局，大文件非连续布局预算同时恢复），刷新一律下一轮 runloop 合并执行（通知回调零同步布局，递归按构造不可能）；KARU_LINKTEST 探针（真实 open 路径 + 超 512K 阈值保证布局洞 + 1900 链接压熔断线下；曾因 3000 链接触发自家 2000 熔断而"复现失败"）修复版 alive、可见区仅注册 3 块（原 3800）；无头环境凑不出真机通知风暴，未修版未能本地复现崩溃，栈证据充分判定根因，待用户原文件实测确认；②崩溃恢复把主动关闭的窗口也重开——关窗 windowWillClose 先删会话条目，随后 resign-key 通知触发 handleResignKey→recordSessionState **把条目写回**（正常退出被 clear() 掩盖，崩溃恢复现形）；修复：isClosing 旗标守卫，顺带堵住"不保存"关窗后失焦自动保存偷写盘的隐患；KARU_SESSIONTEST 探针 A/B：守卫关=幽灵复现 true、守卫开=false；③缩进彩虹相邻行随机缺口——色带纵向改用行片段矩形（铺满无隙）+ backingAlignedRect 像素对齐；无头全量渲染新旧代码均无缝（KARU_INDENTTEST，18pt CJK 分数行高 1921 行全着色）→ 判定缺口在增量合成层（分数边缘 AA 跨脏矩形批次拼不齐，GHOSTTEST 同款教训），像素对齐按构造消灭之，待用户实测确认 | Editor/LinkDetector.swift, Editor/EditorWindowController.swift, Editor/EditorTextView.swift, App/AppDelegate.swift（三探针钩子） | main | 三探针全绿；755 全绿 | ✅ 已装本机待实测 |

热键决策记录：⌘D 否决（全局热键抢占式，会废掉 Finder 复制/浏览器书签）；⌘⇧D 被 Mail 发送等占用；
⌥D 采纳（英文布局牺牲 ∂ 字符，可忽略）。菜单项落 View 菜单（无 Window 菜单，与命令面板同区），
不设菜单键等价（Carbon 热键对本 app 同样生效，且改键后菜单键会过期）。

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
