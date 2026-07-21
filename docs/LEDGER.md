# TinyEditor 工程步骤账本

> 开工前读 `ARCHITECTURE.md`。每完成一项：更新状态、记录负责方与验收结果。
> 负责方按 CLAUDE.md 路由规则：main = 主会话直接做；implementer / chore-worker = 委派。
> 委派必须附：涉及文件路径 + 验收标准。子代理改完，主会话 review diff 后才能提交。
> 状态：⬜ 未开始 / 🔄 进行中 / ✅ 完成 / ❌ 失败（记录次数，触发升级链）

## M1 骨架

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T1.1 | SPM 工程骨架：Core 库 + App 可执行分离，AppDelegate、最小菜单、空编辑窗口（NSTextView） | Package.swift, Sources/TinyEditorApp/, Sources/TinyEditorCore/App/, Editor/ | main | `swift build` 与 `swift test` 通过；启动出现可输入窗口 | ✅ 启动时 phys_footprint 2.5 MB |
| T1.2 | bundle-macos.sh：release 产物打包成 TinyEditor.app（红线：.p8/.env* 不得入 bundle） | scripts/bundle-macos.sh | main（红线，禁止委派） | 脚本产出可双击启动的 .app；bundle 内无密钥文件 | ⬜ |

## M2 编辑核心

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T2.1 | 文档生命周期：新建/打开/保存/另存/多窗口/dirty 标记/关闭确认 | Core/App/DocumentController.swift, Editor/EditorWindowController.swift | implementer | 单测：dirty 状态机；手测：菜单全链路可用 | ⬜ |
| T2.2 | 纯文本粘贴拦截 + Tab/Shift-Tab 缩进 + 回车自动缩进 + 每语言缩进宽度设置（先读 UserDefaults，无 UI） | Core/Editor/EditorTextView.swift, Core/Settings/IndentSettings.swift | implementer | 单测：缩进逻辑（含 HTML 2/4 格切换）；粘贴富文本后 storage 无属性 | ⬜ |
| T2.3 | LineIndex 换行偏移索引（增量更新）+ 行号 gutter + 缩进彩虹绘制 | Core/TextModel/LineIndex.swift, Core/Gutter/ | implementer | 单测：LineIndex 增量正确性（插入/删除跨行）；手测滚动无卡顿 | ⬜ |
| T2.4 | 正则搜索替换栏（大小写开关、正则开关、逐个/全部替换、结果计数与行号跳转） | Core/Search/ | implementer | 单测：替换含捕获组 `$1`；手测 UI 链路 | ⬜ |

## M3 语言智能

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T3.1 | 高亮引擎：LanguageDefinition 声明式协议、viewport 调度、编辑去抖、按扩展名检测语言；随附首个语言 JSON 作为样板 | Core/Highlight/HighlightEngine.swift, LanguageDefinition.swift, Languages/JSON.swift | implementer | 单测：JSON tokenizer 分类正确；全文档属性不预存（代码 review 确认） | ⬜ |
| T3.2 | 语言定义批次 1：Markdown, Python, JS(+Node), TS, HTML, CSS, JSONL | Core/Highlight/Languages/*.swift | implementer | 每语言单测：代表性片段 token 分类断言 | ⬜ |
| T3.3 | 语言定义批次 2：C, C++, C#, Java, Bash, SQL, XML(+plist)（照 T3.1 样板逐个复制修改，附各语言关键字表） | Core/Highlight/Languages/*.swift | chore-worker | 同上；`swift test` 全绿 | ⬜ |
| T3.4 | 代码折叠：缩进+括号配对计算折叠区域，gutter 箭头，折叠/展开（利用 LineIndex） | Core/Gutter/, Core/TextModel/FoldRegion.swift | implementer | 单测：折叠区域计算（Python 缩进式 + C 括号式）；手测折叠展开 | ⬜ |
| T3.5 | 补全：关键字表 + 文档分词增量索引 + 正则符号扫描（函数/变量/类名），Esc/方向键/回车交互 | Core/Completion/ | implementer | 单测：分词索引增量更新、符号提取；手测弹窗交互 | ⬜ |

## M4 工具与设置

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T4.1 | JSON/JSONL 一键排版（保持 key 顺序、可配缩进宽度、错误定位到行） | Core/Format/JSONFormatter.swift | chore-worker（附详细算法计划） | 单测：嵌套/转义/大数/非法输入各用例 | ⬜ |
| T4.2 | XML/plist 一键排版 | Core/Format/XMLFormatter.swift | chore-worker（附详细算法计划） | 单测：嵌套标签/属性/CDATA/注释用例 | ⬜ |
| T4.3 | 偏好设置窗口：每语言缩进宽度、Tab 转空格、字体字号、缩进彩虹开关 | Core/Settings/ | implementer | 手测：改动实时生效并持久化 | ⬜ |

## M5 收尾

| ID | 任务 | 文件 | 负责 | 验收标准 | 状态 |
|---|---|---|---|---|---|
| T5.1 | 内存基准脚本：footprint 采样（空文档 / 1 MB / 10 MB 文件），输出对照预算表 | scripts/mem-benchmark.sh | chore-worker | 脚本可重复运行出报告 | ⬜ |
| T5.2 | 全量 review + 对照 ARCHITECTURE.md 红线逐条验收 + 打磨 | 全部 | main（禁止委派） | 预算表全部达标 | ⬜ |

## 依赖关系

T1.1 → T2.1 → T2.2/T2.3/T2.4（可并行）→ T3.1 → T3.2/T3.3（可并行）→ T3.4/T3.5
T4.1/T4.2 仅依赖 T1.1；T4.3 依赖 T2.2；T1.2 随时可做；T5.* 最后。

## 环境约束（委派时必须告知子代理）

- 本机仅有 Command Line Tools，无完整 Xcode：**没有 XCTest**，单元测试一律用 Swift Testing
  （`import Testing`、`@Test`、`#expect`）；构建/测试命令为 `swift build` / `swift test`。
- 涉及 AppKit 的测试代码需标注 `@MainActor`。

## 变更记录

- 2026-07-21 账本建立。
- 2026-07-21 T1.1 完成（main）：骨架构建/测试通过，启动冒烟 OK。发现环境无 XCTest，测试框架定为 Swift Testing。
