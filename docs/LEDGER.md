# Karu 工程步骤账本

> 开工前读 `ARCHITECTURE.md`。每完成一项：更新状态、记录负责方与验收结果。
> 当前 Codex 路由见 [AGENTS.md](../AGENTS.md)，开发流程见 [DEVELOPMENT.md](DEVELOPMENT.md)，
> 本机实测与发版见 [RELEASE.md](RELEASE.md)。历史 Claude 任务的负责方按当时 CLAUDE.md 记录保留。
> 委派必须附：涉及文件路径 + 验收标准。子代理改完，主会话 review diff 后才能提交。
> 状态：⬜ 未开始 / 🔄 进行中 / ✅ 完成 / ❌ 失败。区分自动化通过、待用户实测与已发布；
> 历史失败次数升级链不用于当前 Codex 流程，失败应报告证据，由主会话决定下一步。

## v0.12.0 / build 26 发布（2026-11-12）

- 用户明确指令“发布”。负责：main。状态：✅ 已发布、线上更新验证通过、正式版已安装本机。
- 内容：M16（代码运行、Karu 安装工具链、语言列表、增强语言识别）。源码 `5f1a9d8`，版本提交与标签
  `v0.12.0` → `a08e5f367122ff42b962bfd7b1720e763336ac97`（仅 bundle-macos.sh 版本号 0.11.0/25 → 0.12.0/26），已原子推送。
  工具链清单保持 M16 当日实测版本，未更新。
- 发布前验证（macOS 27.2 26B123、Xcode 27.2、Swift 6.4.2）：966 tests / 39 suites 通过；visual-smoke VISUAL OK、
  FOLD GEOMETRY OK；mem-benchmark 两次 32 / 51 / 63 MB，无 SKIPPED，全部低于 99 MB 上限，中等文档超出 45 MB 目标。
  同环境 A/B（git worktree 17f0786 与候选交替）：基线 30 / 49 / 62、50*/50 / 63（*空文档一次系统漂移），候选 31 / 50 / 63、
  33 / 51 / 63，新版约 +1 MB，方向一致、幅度在已知漂移内；release 二进制 2.21 → 3.17 MB（__TEXT +416 KB、__DATA +32 KB），
  推测为新增代码与三语文案元数据，非运行时常驻状态。按 §1 新规则已向用户汇报。中等文档超目标属既有情况（v0.11.0 同为 51 MB）。
- 临时副本 Developer ID 签名与可信时间戳检查通过；新机 `tinyeditor-notary` profile 首次用于发布：公证请求
  `b7faad75-f743-4ed5-b4dd-3ac2aa864ed7` Accepted，装订与验证通过，Gatekeeper `Notarized Developer ID`。
  v0.11.0 记录的“发布依赖旧机公证”自此正式解除。
- 产物：Karu.app 6.4 MB（0.12.0 / 26，deep/strict、stapler 通过）；Karu.zip 2439308 bytes（解包签名与票据通过、二进制一致）；
  Karu.dmg 2827801 bytes（hdiutil 校验与签名通过）；包内无密钥类文件。Sparkle EdDSA 签名以 app 内置公钥（openssl）独立验签通过。
  SHA256：zip `9748ae1263dfca7d2b8e692b795139ba6dcea77c532a37fba015c3beef544939`、dmg
  `a8e7f2bf908fe19acc796155c6315f44c2a55cf7ffb80ac122e41f882bfdac9d`、appcast `4315de12ccd292c612ea2408a56e55779ac25ab1adccea383575f2aaf0049ebb`、
  二进制 `6043b1630739eaff81f4c6a0261f4574ac82ee90aee38dfec5b016314b5590da`。
- GitHub Release：三语发布说明，草稿阶段三资产 SHA256 与本地一致后公开并设为 latest：
  https://github.com/enkin-japan/karu/releases/tag/v0.12.0 。从公开 `releases/latest/download/` 下载三资产与本地逐一一致；
  线上 appcast 为 0.12.0 / 26，URL、长度（2439308）正确，线上 ZIP 用内置公钥验签通过。
- 本机：正常请求测试构建退出后替换为正式版并启动，版本 0.12.0 (26)、stapler 与 Gatekeeper 通过、二进制与发布包一致；
  删除同版测试构建，保留 v0.11.0 回退副本 `/Applications/.Karu-before-m16-20261112-223027.app`。

## M17 高亮、补全与代码理解（2026-11-13 立项）

方案与决策 A–K：[HIGHLIGHT-AND-COMPLETION-PLAN.md](HIGHLIGHT-AND-COMPLETION-PLAN.md)。一个里程碑一次做完、一次发布（暂定 v0.13.0）。
LSP 与任何外部语言服务进程不做；类型推断、导入解析、项目文件夹跨文件索引在进程内完成，计入常驻预算。
取消安装包体积上限（只记录）。常驻内存红线 99 MB 不变；高亮 + 补全 ≤2 MB，推断 1000 行以内 ≤10 MB，
导入摘要 LRU ≤8 MB，索引常驻 ≤5 MB（各为配对增量）。VS Code 只作对照：T17.0 隔离安装，T17.15 卸载并核对清理。

| # | 任务 | 依赖 | 负责 | 状态 |
|---|---|---|---|---|
| T17.0 | 基线：VS Code 隔离安装与固定版本；对照样本库；计时埋点；现版颜色、候选名次、内存与时延；VS Code 语言服务内存；Esc/⌥⎋、离屏属性、长行、TCC 实测；mem-benchmark 1000 行推断样本 | — | main + implementer（夹具、基线套件、PerfLog），main 审查 | ✅ 自动化通过；项目文件夹重启授权留 T17.12 |
| T17.1 | 分析骨架 `DocumentAnalysis`：版本、稀疏检查点、分片调度与取消、共用声明扫描、`applyLanguage` 统一失效、两个新模块开关 | T17.0 | implementer，main 审查 | ✅ 自动化通过 |
| T17.2 | 通用词法扫描器：档案、两种模式、检查点接入，取代从 0 起扫；Python 迁移结论 | T17.1 | main 定接口 + implementer | ✅ 自动化通过；Python 保留原 tokenizer |
| T17.2b | 超长行分片（方案 §6 第 2 条）：扫描器安全切点、色带行内切片、行内检查点、JSON 接入档案 | T17.2 | main 定接口 + implementer | ✅ 自动化通过；未在真机打开长行实测 |
| T17.3 | 其余 18 种语言接入；钩子与妥协入账 | T17.2 | implementer | ✅ 自动化通过；除 Python 外全部语言有档案，一致率 39.0% → 77.7% |
| T17.4 | 声明与作用域：代码位置声明；Python、JS/TS 完整作用域；七种静态语言基础版；`=>` 修正 | T17.2 | implementer | ✅ 自动化通过；伪声明全部排除，一致率 77.7% → 80.7% |
| T17.5 | 候选模型、匹配、排序、最近接受、大小写、用法证据、触发字符 | T17.4 | implementer | ✅ 自动化通过；作用域 top1 24/24，误弹 0 |
| T17.6 | 候选界面与接受：身份保留、类别标签三语、自适应宽度、整词替换、一次撤销、输入法守卫、`complete(_:)`/Esc、菜单项 | T17.5 | implementer，main 实测输入法 | 🔶 自动化通过；真实窗口与真实输入法实测待做 |
| T17.7 | 配色：新 TokenKind 与色板、按位置分类 | T17.3 | implementer | ✅ 自动化通过；一致率深色 94.9%、浅色 91.6% |
| T17.8 | 嵌入语言：HTML script/style、Markdown 围栏、JSX/TSX 三类边界 | T17.3、T17.5 | implementer | ⬜ |
| T17.9 | 解析器选型：手写与 tree-sitter 原型实测 | T17.2 | main | ⬜ |
| T17.10 | 内置类型表：typeshed 与 TS ES/DOM 生成脚本、懒加载、许可证 | T17.9 | implementer | ⬜ |
| T17.11 | 深层推断（Python、JS/TS）与静态语言显式声明，接入成员候选与签名摘要 | T17.9、T17.10、T17.4 | implementer，main 审查 | ⬜ |
| T17.12 | 项目文件夹设置与 SQLite 索引、后台全量/增量、清除与占用显示 | T17.4 | implementer | ⬜ |
| T17.13 | 导入解析：查找顺序、导出摘要、LRU、`.pth` 安全规则、失效 | T17.11、T17.12 | implementer | ⬜ |
| T17.14 | 跨文件接入：补全、推断签名、工作区符号搜索 | T17.11–T17.13 | implementer | ⬜ |
| T17.15 | 集成验收、文档更新、卸载 VS Code 并核对清理 | 全部 | main | ⬜ |

- T17.0 进展（main，2026-11-13）：
  - **VS Code 对照环境**：官方更新服务器 darwin-arm64 包，1.146.0（commit `69047191`，2026-11-10），Microsoft Developer ID 签名、
    Gatekeeper `Notarized Developer ID`。装在 `~/KaruM17-VSCode/`，`--user-data-dir` / `--extensions-dir` 均指向其下独立目录；
    设置固定：遥测关、更新关、扩展自动更新关、语义高亮关、主题 Dark Modern、工作区信任关。扩展：ms-python.python 2026.10.0、
    vscode-pylance 2026.4.1（连带 debugpy 2026.6.0、vscode-python-envs 1.42.0）；TypeScript 为内置 6.0.3。
    安装前已保存 `~/Library` 与 `~` 的条目快照（`~/KaruM17-VSCode/pre-install-*.txt`），T17.15 卸载时据此核对。
  - **对照环境位置变更（2026-11-14，系统盘清理）**：`~/KaruM17-VSCode` 整个目录已迁到外接盘
    `/Volumes/enkin/project-support/KaruM17-VSCode/`，原位置现在是指向它的符号链接，本台账里所有 `~/KaruM17-VSCode/...` 路径照常可用。
    迁移后逐文件 SHA-256 与原件一致（仅访达的 `.DS_Store` 不同），`codesign --verify --deep --strict` 通过；迁移后未重新启动 VS Code 实测。
    `download/vscode.zip`（安装包，388 MB）已删除，需要重装时按上面的版本与 commit 从官方更新服务器重新下载。
    对 T17.15 的影响：卸载时要同时删除 `~/KaruM17-VSCode` 符号链接和外接盘上的实际目录；外接盘未挂载时对照环境不可用。
    `~/Documents/KaruTCCProbe/` 未动。迁移总记录见 `/Volumes/enkin/project-support/README.md`。
  - **默认主题已变**：1.146 的默认主题是 Dark 2026 / Light 2026（各自 include Modern，再覆盖约 50 条语法色，GitHub 风格：
    关键字 #ff7b72、字符串 #a5d6ff、函数 #d2a8ff、参数 #ffa657）。方案第 6 节按 Dark/Light Modern 写的 9 个新增色值，
    已用 1.146 的主题文件逐项核对，全部一致；另发现 Karu 现有类型色 #4EC9B2 与主题的 #4EC9B0 差 2，属笔误。
    用户决策（2026-11-13，决策 L）：对标 Dark/Light Modern，不跟随 2026。
  - **VS Code 语言服务内存**（phys_footprint，打开文件并完成诊断后静置；未触发补全请求，VS Code 在本机工具权限下不能输入）：
    Pylance 服务进程：打开空 .py 437 MB，再打开 1000 行样本 483 MB（+46 MB），之后回落到 340–384 MB；
    TS：语法服务 83→94 MB、语义服务 93→96 MB（两者合计 176→190 MB，+14 MB），另有 typings 安装进程 35 MB；
    扩展宿主 135–140 MB、JSON 语言服务 19 MB 不计入。即：外部语言服务的固定成本是 Karu 全部 99 MB 红线的 2–4 倍，
    与决策 H 的判断一致。样本：`Tests/Fixtures/M17/inference/sample_1000.{py,ts}`（生成脚本 `scripts/m17/gen-inference-samples.py`，
    931 / 967 行，Python 可编译，TS 在 `--strict` 下 0 诊断）。
  - **高亮参照脚本**：`scripts/m17/vscode-tokens.js` 用 VS Code 自带的 vscode-textmate、oniguruma、语法和主题（以其 Electron 的
    node 模式运行）把样本着色为 UTF-16 区间 TSV，`scripts/m17/compare-colors.py` 与 Karu 的导出逐字符比较。VS Code 无内置 TOML 语法，
    TOML 无参照。
  - **TCC**：非沙盒应用经「打开」收到 `~/Documents` 下的 a.py，读 a.py 立即成功；读同目录 b.py、列目录都被阻塞（>8 s），
    即触发「文稿」访问授权弹窗，而不是直接拒绝。结论：第 9 节「无项目文件夹时不读同目录」的约束必须保留。
    「设置里添加的项目文件夹重启后是否需要再次授权」未测：探针应用的屏幕控制授权未获批，留到 T17.12 用真实设置界面实测
    （方案已备安全作用域书签与重新选择两种处理）。探针在 `~/KaruM17-VSCode/tccprobe/`，测试文件在 `~/Documents/KaruTCCProbe/`，T17.15 一并删除。
  - **Esc / ⌥⎋**（v0.12.0，后台按键送达）：编辑区按 Esc 不弹任何列表；按 ⌥⎋ 弹出系统的 `__NSTextViewCompletionWindow`，
    内容是系统词典单词（interesting、interest、internet…），与 Karu 的补全无关；再按 Esc 可关闭。第 1 节「Esc 很可能弹出系统列表」的推测不成立，
    需要处理的是 ⌥⎋ 路径（第 5.1 节已计划重写 `complete(_:)`）。限制：按键在 Karu 非前台时送达。

- T17.0 收尾（implementer 实现夹具、基线套件与 PerfLog，main 审查 diff 并补 VS Code 侧）：
  - **新增**：`Tests/Fixtures/M17/`（20 种语言的跨行边界样本 + `embedded/` 下 HTML、Markdown 围栏、JSX、TSX；`completion/cases.json`
    共 96 例：作用域 46（含负例 9）、成员 40、显式声明 10，holdout 28 例；`interaction-checklist.md` 48 项）；
    `Tests/KaruCoreTests/M17BaselineTests.swift`（`KARU_M17_BASELINE=1` 才运行，5 项）；`Sources/KaruCore/App/PerfLog.swift`
    （`KARU_PERFLOG=<path>`，关闭时只多一次分支；`completion.request/index`、`highlight.pass/symbols` 四个埋点）；
    `scripts/m17/{gen-inference-samples.py,vscode-tokens.js,compare-colors.py,perf-summary.py}`；mem-benchmark 增加
    `KARU_BENCH_APP_BIN` 与「推断样本（参考）」两轮。基线产物在 `Tests/Fixtures/M17/baseline/`（karu 与 vscode-dark_modern 两组着色 TSV，
    以及候选名次与汇总）。
  - **验证**：全量 971 tests / 40 suites 通过（新套件默认跳过）；基线套件 5/5，连续两次产物一致；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
  - **现版着色**：边界样本与 VS Code Dark Modern 逐字符比对（非空白 UTF-16 单元）总一致率 **39.0%**；JSON 97.9%、JSONL 99.6%，
    JS 12.4%、YAML 22.2%、C 25.3% 最低。差异集中在块注释跨行、heredoc、原样字符串、YAML 块标量、CDATA、围栏代码，以及新增类别
    （控制流关键字、参数、常量）。VS Code 无内置 TOML 语法，TOML 无参照。
  - **现版候选**（完整表见 `baseline/completion-summary.md`）：作用域类 top1 16/32、期望前三全中 11/11、负例中注释与字符串内误弹 6/6；
    `py-scope-01` 的 `user_count` 排第 3（`user_cache|user_config|user_count`）；成员类前十命中 0/78，点号零前缀从不弹出。
    原记为「违禁名命中」的 3 例（注释或字符串里的伪声明 `fake_name`、`ghost_handler`、`fakeFn`）按方案 §1、§5.2 改判为
    `docWordOnly`：允许作为文档词出现，但只能排在所有代码来源候选之后，以声明身份出现或排在代码候选之前才算失败（main 决定）。
  - **探针**（debug 构建，墙钟）：
    1. 离屏属性：约 10 MB 多样名字 Python，800×600 从头滚到尾后，前景色 run 从 488 个涨到 719,306 个、覆盖全文 50.6%，旧区从不清理。
       证实第 6 节「离屏属性累积」风险，T17.2/T17.7 需要按差集清理。
    2. 超长行：5 MB 单行 JSON，首次着色 4758 ms、重绘 4483 ms，全在主线程，画 161 万个 run。第 6 节超长行分片是必须项。
    3. 声明扫描（约 10 MB）：多样名字 WordIndex 818 ms、symbols 427 ms、scanSymbolLocations 505 ms；重复块 216 / 323 / 677 ms。
    4. 热查询 `WordIndex.suggestions`：前缀 `in`（7,265 匹配）中位数 141 ms，`pa`（21,789）300 ms，无匹配 64 ms。
       远超第 11 节 p95 ≤8 ms，T17.5 的有界匹配集与复用是必须项（release 下会快些，未单独测）。
  - **内存**（`KARU_DIAGNOSTIC_DIRECTORY` 隔离）：32 / 51 / 63 MB，参考轮 sample_1000.py 46 MB、.ts 47 MB，全部低于 99 MB。
    不隔离时上一轮被 kill 的会话会被恢复，读数被污染（参考轮曾读到 91/95 MB），正式对照必须隔离。
  - 工作区里的 `.impeccable/config.json` 是设计检查插件生成的忽略配置（对 html 夹具的误报），与产品无关，提交前决定是否保留。

- T17.1（implementer 实现，main 审查 diff 并修一处）：
  - **新增** `Sources/KaruCore/Analysis/`：`DeclarationScan`（一次正则扫描同时产出导航位置、高亮符号表、补全符号集；
    旧三函数改为薄包装，等价测试覆盖全部 M17 夹具、三个旧测试文件的输入和 22 个语言标识，含顺序完全一致）、
    `CheckpointStore`（约 64 KB 一个、只丢弃编辑行起之后的；Python 高亮已改用，编辑不再清空全部检查点）、
    `AnalysisScheduler`（主线程 4 ms 分片、按 owner/版本取消、键窗口优先；本步声明扫描仍是单片，T17.4 换 token 扫描后分片）、
    `DocumentAnalysis`（每窗口一个，先于其他观察者注册；持有版本、语言、检查点、声明快照）。
    窗口所有语言入口（加载、重新载入/自动、菜单、工具栏、识别、运行时识别）统一走 `setDocumentLanguage`。
  - **修复**：切换语言后第一次补全请求即用新语言的声明（此前要等下一次编辑的去抖重建）。
  - **声明扫描次数**：同一版本只扫一次（高亮、补全、导航共用）；此前高亮 0.07 s、补全 0.15 s 各扫一遍，导航打开再扫一遍。
    高亮不再有自己的编辑去抖，改为收到新快照后重绘；补全的新符号由 0.15 s 提前到 0.07 s 生效。
  - **内存**：首轮 mem-benchmark 发现快照常驻 41 万个 `SymbolLocation`（约 16.6 MB，large.py 读到 98 MB），implementer 改为紧凑存储
    （名字驻留 + 打包字节流，约 2 B/条，该文件 829 KB），正则改为按需编译。修复后两轮 36 / 56 / 65、参考 50 / 50，
    同一会话的 T17.0 前构建为 36 / 56–57 / 66、参考 50 / 49–50：持平或略低。比 T17.0 记录（32 / 51 / 63）普遍高约 4 MB，
    T17.0 前构建同样偏高，判定为环境漂移。
  - **main 审查修改**：补全的 0.15 s 去抖重建原先调用 `ensureDeclarations()`，若分析的扫描任务被延后，会再同步扫一次全文；
    改为只采用现成快照，否则沿用旧符号、等 `.declarations` 通知。
  - **新模块开关**：`typeInference`、`crossFileIndex`（默认开、三语文案，设置窗口与工具栏模块菜单都会列出，本步只参与释放规则）。
    设置窗口内容高度约 660 → 704 pt。**兼容性**：含这两个键的导出文件，v0.12.0 导入会整份拒绝（"invalid value"），不会部分应用；
    只有用户改过这两个开关才会出现在导出里。发布说明需写明（与 M16 语言列表同类）。
  - **验证**：全量 992 tests / 43 suites 通过（新增 21）；visual-smoke VISUAL OK、FOLD GEOMETRY OK；基线重生成后 karu 着色 TSV 逐字节一致，
    候选列表全部一致（`forbiddenHits` 列 3→0 来自 T17.0 的 `docWordOnly` 改判，非 T17.1 引起）。
  - 方案 §3 的导航口径已改为「优先复用快照，高亮与补全都关时才临时扫描」。

- T17.2（main 定接口，写入方案 §4「接口（T17.2 定稿）」；implementer 实现，main 审查 diff）：
  - **新增**：`Highlight/LexicalProfile.swift`、`Highlight/LexicalScanner.swift`。
    - 档案的定界方式有四种：固定、N 连引号、`#` 计数、C++ raw。
    - 扫描器支持插值嵌套与括号深度，以及原子 token。
    - 帧栈上限 64；状态存入检查点 `LexicalState.generic`。
    - 两种模式（`advance`、`segments`）都可以在任意 `[from, to)` 上运行，切点不落在 token 内部时，分段扫描与一次扫描结果相同。
    - 有档案的语言，正则规则只在代码片段里生效，并跳过 string / comment 类规则。
  - **删除**：`multilineStringDelimiters`、`openMultilineDelimiter`、`multilineStringSpan` 等从偏移 0 起扫的路径（实际只剩测试在用）。
  - **引擎**：
    - 着色走「最近检查点 → `advance` → 色带 token」。Python 共用同一个泛化恢复函数，着色逻辑不变。
    - 新增 PerfLog 事件 `lexical.advance`。
  - **试点**：JavaScript 与 TypeScript 共用一份档案；Rust 有嵌套注释、`r#"…"#`、可跨行字符串，字符字面量与生命周期作为原子 token。
    其余语言在 T17.3 接入。
  - **Python 结论：保留 PythonTokenizer**。
    - 实验档案设为生产路径后有 12 处测试失败。除一处外，都是替换字段内部的特有分类：
      字段内标识符为 `.symbolVariable`，格式说明 `:…` 着字符串色，`!r` 为标点。
    - 要通过这些测试，必须在通用扫描器里加 Python 专用逻辑，按 §4 的规则不迁移。
    - 跨行结构判定与 PythonTokenizer 逐行一致。实验与差距记录在 `PythonProfileExperimentTests.swift`。
  - **离屏属性清理**（方案 §6 第 1 条）：
    - 记录当前持有颜色的范围，每次绘制立即清除新色带之外的部分；编辑时把持有范围映射过编辑，宁多清不少。
    - 10 MB Python 从头滚到尾，前景 run 由 **719,306 降到 490**，覆盖率由 50.6% 降到 0.04%。
  - **与 VS Code Dark Modern 的着色一致率**：JS **12.4% → 93.9%**、TS 36.8% → 49.5%、Rust 61.2% → 73.7%，全部样本 39.0% → 57.2%，Python 不变。
    其余差异：JS 正则字面量留 T17.3 钩子；转义序列与插值边界的颜色、类型色 `#4EC9B2` 的笔误留 T17.7。
  - **时延**（debug、800×600，同机对照 HEAD）：
    - 10 MB JS 首次跳到末尾：32 ms → 128 ms。HEAD 没有跨行状态，颜色本来就是错的。
    - 10 MB JS 附近重绘中位数：39 ms → 2.4 ms，注释正文不再跑正则。
    - Python 首跳约 640 ms、附近重绘约 10 ms，与 HEAD 持平。
    - 纯函数层冷算到末尾：JS 128 ms、Rust 425 ms（原子 token 约占一半）。
    - 检查点推进目前一次同步走完、没有分片；按第 11 节分开报告「最长主线程占用」时要处理（T17.15 读数）。
    - 每次绘制仍通过 `textView.string` 复制全文，10 MB 时约多 120 ms，属既有做法，未改。
  - **改动的旧测试期望**：`javascriptTemplateStringAndBlockComment` 中 `${`、`}` 改为标点，`y` 改为代码（插值按代码处理）。
    T14.7 的跨行定界测试改写为通用扫描器的等价测试；四个 Python 文档字符串的断言未改。
  - **验证**：
    - 全量 **1018 tests / 47 suites** 通过（新增 26），visual-smoke VISUAL OK、FOLD GEOMETRY OK。
    - 新测试覆盖合成档案单测、随机切点不变性，以及 js / ts / rs / py 的四路一致性：顺读、跳入、上游编辑后与全新扫描一致、撤销复原。
      测试还断言编辑确实改变了色带、用未失效的旧检查点会算错。另有真实文本视图的引擎级测试和离屏清理测试。
  - **注意**：`KARU_M17_BASELINE=1` 套件每次都会改写 `Tests/Fixtures/M17/baseline/` 下的 karu TSV 与候选文件，跑完要 `git checkout` 还原，
    除非是有意重建基线。
  - **超长行分片**（方案 §6 第 2 条）当时未做，见下方 T17.2b。
  - **内存**（release、`KARU_DIAGNOSTIC_DIRECTORY` 隔离，同机交替运行；HEAD 在临时 worktree 中构建）：
    - HEAD 两轮均为 26 / 35 / 63 MB，参考轮 29 / 29。
    - 候选三轮均为 25 / 35 / 63 MB，参考轮 29 / 29。
    - 持平，无新增常驻：只多一个 `colouredRange`，扫描器随语言定义一起释放。
    - 本次环境整体比 T17.1 时低（36 / 56 / 65），HEAD 同样偏低，判定为环境差异。
    - 第一次对照时把 HEAD 二进制单独拷出，缺资源包，无法采样，已作废。

- T17.2b 超长行分片（main 定接口，implementer 实现，main 审查 diff，2026-11-14）：
  - **扫描器**：新增 `advance` / `segments(…stoppingAtSafePointFrom:)`，返回目标之后第一个安全切点。
    - 安全切点：token 边界，且不在代理对、标识符、CRLF 中间；在代码里，前一个单元不能是前缀、`#`/lead、C++ `R`、原子前缀这类会被向后回看的字符。
    - 目标之前的标记搜索只截到目标，不多搜一遍；没有切点参数时行为与速度不变。
    - 顺带修复：`"\😀"` 这种转义后紧跟代理对时，下一次搜索从低代理开始会漏掉一个单元（Foundation 的行为），现在转义吃掉整个代理对。
  - **色带**：新纯函数 `bandBounds`。行边界在阈值（`longLineThreshold` = 8192 单元）以内时与原来的整行吸附完全一致，否则停在行内。
    - 有档案的语言：起点用安全切点恢复状态，前面多扫 256 单元规则上下文再裁掉；终点停在安全切点。
    - 超过 64 KB 的长行内部也会记检查点（只限通用扫描器）。
  - **JSON / JSONL 改用只含字符串的档案**，这样行中间开始的切片也知道自己在不在字符串里。
    - 键改由新参数 `propertyStringFollower`（`\s*:`）判定为 `.property`。
    - 现有夹具的着色 TSV 逐字节不变。
    - 只有格式错误的 JSON 着色会不同：行尾 `\` 续行、未闭合字符串、相邻的 `"a""b":`。
  - **妥协（入账）**：Python 和尚未建档案的语言，长行切片内用无状态规则着色，不追踪字符串状态；长行之后的状态仍精确恢复。
  - **顺带**：绘制改读 `textStorage.mutableString`，不再每次复制全文（T17.2 记的 10 MB 约 120 ms）；`PythonTokenizer.state` 直接扫 NSString。
  - **探针**（debug，5 MB 单行压缩 JSON，同会话对照 HEAD）：首次着色 4803 → **14.6 ms**，重绘 4465 → **14.9 ms**，
    绘制的 run 数 1,612,469 → **2,286**（色带 6915 单元）。离屏 run 数 490 不变（该探针是多行 Python）。
  - **测试**：
    - 新增 `LongLineSlicingTests`，10 个测试、4 个 suite。
      - 停点：JS、TS、Rust、JSON 和一个覆盖全部定界方式的合成档案，随机文本、随机目标的切分不变性；对抗样本逐位置都试一遍。
      - 引擎：真实 NSTextView 上的 2 MB JSON 与 1 MB JS，滚到中部、末尾，色带内与整行单趟扫描逐单元一致；色带长度 ≤64K，带外不留颜色；行中间编辑、撤销。
      - `bandBounds` 与 `wholeLineRange` 逐一对照。
    - 变异检查：分别去掉回看条件、规则前扫、规则后扫、截断键的前向扫描，都有测试失败。
    - 为让全套稳定，加固了几个原本就不稳的测试，断言都没改：
      - `L10nOverrideTests` 改在主线程同步运行。原来在后台线程 `L10n.set` 会让其他 suite 遗留的界面控制器在后台线程刷新文案，测试进程崩溃。
      - `AnalysisSchedulerTests` 等待上限 3 → 10 s，条件满足即返回。
      - `DocumentAnalysisTests` 三处「pump 之后检查已发生」改为最多 3 s 的条件轮询。
    - `unprofiledLanguagesKeepPerLineTokens` 中的 JSON 换成 YAML（JSON 已有档案）。
  - **验证**：全量 **1028 tests / 51 suites** 通过（main 复跑一次，implementer 连续 5 次）；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
  - **未做**：真实 App 打开长行文件滚动、编辑的实测，release 耗时，以及 mem-benchmark。本步没有新增常驻状态，长行里检查点密度与原来相同，留到 T17.15 一起实测。
  - 基线目录中 JS/TS/Rust/JSX/TSX 的 TSV 仍是 T17.0「现版」读数（T17.2 起有意不刷新），重跑基线套件后照旧 `git checkout` 还原。

- T17.3a 纯档案语言与 JS 正则（main 定范围，implementer 实现，main 审查 diff，2026-11-14）：
  - **接入档案**：C、C++、Java、C#、Go、CSS、SQL、Swift、TOML、HTML、XML/plist；JS/TS 增加正则字面量原子。
    - C/C++：`L u U u8` 前缀；字符原子带前缀，并用 lookbehind 排除 C++14 数字分隔 `1'000`；C++ raw `R"d(…)d"`。
    - C#：`$$"""`、`$"""`、`"""`、`$@"`/`@$"`、`@"`（双写引号、可跨行）、`$"`（`{{` 为转义）。Java 文本块 `"""`；Go 反引号。
    - Swift：可嵌套注释，`"`/`"""` 各带 `#` 计数，`\(`/`\#(` 插值。SQL：`'`、`"`、反引号可跨行，双写转义。
    - TOML：三引号与单引号四种字符串。HTML/XML：`<!-- -->`，XML 另有 CDATA。
  - **两个通用扩展**（写入方案 §4 接口）：
    - `LexicalProfile.keepsStringRules`：为 true 时 `.string` 规则在代码段里照常运行。用于 HTML/XML（引号只在标签内才算字符串，属性值仍是单行规则）和 C 的 `#include <header>`。
    - `AtomForm.precededBy: AtomContext(characters:words:)`：往回跳过空白（最多 256 单元），看前一个字符或单词决定原子是否成立。只读文本，不影响切分保证。JS 正则用它区分 `x = /re/` 与 `a / b / c`。
  - **与 VS Code Dark Modern 的一致率**（T17.0 → 本次）：
    - c 25.3 → **95.6**；java 50.5 → 75.6；xml 42.0 → 75.7；go 46.6 → 70.7；sql 69.7 → 88.1；
    - csharp 58.4 → 69.5；swift 55.9 → 69.5；css 53.8 → 67.3；html 69.2 → 79.9；
    - javascript 93.9 → 94.3、typescript 49.5 → 50.1（与 T17.2 比）；cpp 56.0 → 56.1；
    - **全部样本 57.2%（T17.2）→ 75.7%**。没有语言下降；JSON/JSONL 的 TSV 逐字节不变。TOML 无 VS Code 参照。
    - cpp 几乎不变：VS Code 把 `R"glsl(` 按分隔符名嵌入 GLSL 着色，单这一处就会让 cpp 从 56.0 降到 53.7，靠 `#include <…>` 规则补回。
    - 剩余差异主要是类别（变量、类型、常量、控制流）、转义和正则颜色，属 T17.4/T17.7；SQL 关键字表缺词；CSS 无引号取值。
  - **妥协（入账，均未加钩子）**：
    - C++ raw string 的嵌入语言（`R"glsl(`）不做。
    - C# `$$"""` 简化：`{{` 开插值、第一个 `}` 关；`$$$` 不建模。
    - Swift 正则字面量 `/…/`、`#/…/#` 不建模。
    - SQL：PostgreSQL `$$…$$` 不建模（样本里 VS Code 也把函数体当代码）；MySQL `#` 注释与反斜杠转义不建模。
    - TOML：结尾多出的引号（如四连引号）不建模。
    - HTML/XML：跨行属性值不着色；属性值里的 `<!--` 会开启注释。
    - JS 正则：
      - `i++ / 2 / x` 会读成正则（`+` 算运算符）。
      - `}` 后的 `/re/` 算正则（VS Code 判除号）。
      - 上一行以标识符结尾时，下一行开头的 `/` 判为除号（合乎 JS 语义，VS Code 判正则）。
      - 正则颜色暂用字符串色，T17.7 换。
  - **改动的旧测试期望**：C# `$"hi {name}"` 的插值内部改为代码、`{` `}` 为标点（与 §4 和 VS Code 一致）；`unprofiledLanguagesKeepPerLineTokens` 中 C 换成 Bash。
  - **测试**：
    - 新增 `LexicalProfiles` 套件（12 个），覆盖各跨行结构与正则/除号判定。
    - 新语言全部加入四路一致性、随机切分、安全点随机文本和对抗样本。
    - 全量 **1040 tests / 52 suites** 通过（main 复跑）；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
    - implementer 有一次全量运行中 `ToolchainManagerTests.installingCancelInstallAndUninstallFromTheRows` 失败，重跑通过，判为时序抖动，与本次无关。
  - **性能**（debug，约 10 MB、无检查点冷算到末尾）：C 45 ms、SQL 209、C++ 268、JS 133、XML 338、Swift 526、C# 546 ms，均低于 1 s。
  - **未做**：mem-benchmark（本步只多语言档案，随语言定义释放）、真机交互、release 耗时。

- T17.3b 行块钩子：Bash、YAML、Markdown（main 定接口，implementer 实现，main 审查 diff，2026-11-14）：
  - **新接口**（写入方案 §4）：
    - `LexicalProfile.lineCommentPrecededBy`：行注释只在文档开头、换行之后，或前一单元属于该集合时成立（Bash `" \t;|&()"`，YAML `" \t"`）。
    - `StringForm.precededBy: AtomContext?` 与 `AtomContext.lineStart`：字符串开头的文本上下文（YAML 引号只在标量开头才算字符串）。
    - `LexicalProfile.lineBlocks`：`.heredoc` / `.indentedBlock` / `.fence`，各带 `bodyKind`；新帧 `.heredoc`、`.indentedBlock`、`.fence`，都有 `inBody` 标志（开头行剩余部分仍按代码处理，遇到换行才进入正文）；新片段 `LexicalSegment.block(kind)`，正文里不跑规则。
    - `LexicalProfile.keepsCommentRules`（implementer 增补，main 认可）：Markdown 的引用块、删除线规则借用注释色，需要在代码段里保留。
  - **与设计的偏差（main 认可）**：
    - YAML 父缩进：原公式（行缩进 + 每个 `- ` 加 2）会让 `- |` 的正文立刻结束。改为取行首空白和各个 `- ` 之后的列号；指示符紧跟在 `- ` 后时取最后一个 `-` 的列。
    - YAML 指示符行和 backtick fence 的 info string 改为推迟判定：先压入 `inBody: false` 的帧，行内出现非法内容（YAML 出现空白和注释以外的字符，fence 的 info 里出现反引号）就取消。这样不需要向前读到 `to` 之后，切分保证不受影响。
  - **与 VS Code 的一致率**（本步开工时现跑 → 本次）：bash 39.5 → **59.6**；yaml 22.2 → **53.5**；markdown 62.6 → **76.9**；embedded/fences.md 50.8 → 64.2；
    **全部样本 75.7% → 77.7%**。其余样本 TSV 逐字节不变。
  - **妥协（入账）**：
    - Bash：一行只跟踪第一个 heredoc；未加引号的 heredoc 正文整体按字符串处理（VS Code 会给 `$var` 着色）；算术里的 `x<<y` 会被当成 heredoc。
    - YAML：显式缩进指示符（`|2-` 的 `2`）不参与判定；超过 4096 单元仍找不到行首时，任何非空行都会结束块标量。
    - Markdown：引用块里、缩进 4 格以上的 fence 不识别；内联代码里的 `<!--` 会开启注释；fence 内嵌语言留给 T17.8。
  - **剩余差异**：
    - Bash：函数调用名、字符串里的 `$var`、插值定界符的颜色。
    - YAML：普通标量（VS Code 着字符串色）、键色（我们 `.property` 蓝 `#9CDCFE`，VS Code `#569CD6`）。
    - Markdown：引用块整行着注释色（VS Code 只给 `>` 着色）。
    - 以上属 T17.7 类别配色或 T17.8。
  - **改动的旧测试期望**：shebang 改为 `.comment`（与 VS Code 一致）；```` ```swift ```` 开头行改为 `.plain`（fence 属于块，VS Code 不着色）；`unprofiledLanguagesKeepPerLineTokens` 改用合成的无档案定义。现在除 Python（自有 tokenizer）外，所有已注册语言都有档案。
  - **测试**：
    - 结构测试覆盖验收清单的全部项。
    - 三种语言加入四路一致性、随机切分、安全点随机文本和对抗样本（切点落在 `<<-EOF` 内、结束行、fence 标记串、块标量缩进、CR 与 LF 之间）。
    - 引擎级测试：真实 NSTextView 中修改 heredoc 结束行、在 YAML 块结束行前插入缩进，再撤销；近处、远处重绘都与全量扫描一致。
    - 全量 **1045 tests / 52 suites** 通过（main 复跑）；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
  - **性能**（debug，约 10 MB，冷算到末尾）：bash 779 ms（离 1 s 最近）、yaml 201、markdown 144 ms。
  - **未做**：真机交互、release 耗时；夹具都是 LF，CRLF 只由随机文本和对抗样本覆盖。
  - **T17.3 完成**：除 Python 外，全部语言接入通用扫描器；全部样本一致率由 T17.0 的 39.0% 升到 77.7%。

- T17.4a Python、JS/TS 的声明与作用域（main 定接口，implementer 实现，main 审查 diff，2026-11-14）：
  - **做法**：两门语言改为由手写的声明遍历器提取声明（`PythonDeclarationWalker`、`JavaScriptDeclarationWalker`）。遍历器读通用扫描器输出的代码 token，字符串、注释不参与。
    - Python 着色仍用 `PythonTokenizer`；分析专用的 `PythonLanguage.analysisProfile` 由 T17.2 的实验档案转正而来。
    - 其余语言仍走原正则路径，留 T17.4b。
  - **快照**（`DeclarationScan`）：
    - 声明种类细分为函数、方法、类、类型、变量、JS `var`、参数、导入、属性、global、nonlocal，再映射回旧的三类，供着色和导航使用。
    - 新增作用域大纲：模块、类、函数、lambda/箭头、推导式、块。只存起止范围，用 varint 字节流约 5 B/作用域；声明属于哪个作用域按位置推出，每个声明不额外存储。
    - 查询：`visibleBindings(at:)` 按「内层优先、同名遮蔽」给出可见绑定；`scopeChain(at:)` 给出外层作用域链。
  - **作用域规则**（详见代码注释）：
    - Python：
      - 按逻辑行缩进划分作用域；名字在整个作用域内可见。
      - 从方法内部看不到类体里的名字。
      - `global`/`nonlocal` 把名字绑到外层；增量赋值不产生绑定。
      - 推导式内的海象赋值绑在推导式作用域。这与 PEP 572 不同，PEP 规定绑在外层函数，入账为妥协。
    - JS/TS：
      - 按词法括号划分作用域；`var` 归最近的函数；函数声明属于所在块。
      - `let`/`const`/`class` 只在声明之后可见，中间隔着函数边界时除外。
      - 箭头函数必须看到 `=>` 才算函数，修正了 `const total = (a + b)` 被当成函数的问题。
      - 参数默认值里可以带括号。
  - **列出与只供作用域**：
    - 着色表、导航列表和补全符号集保持原来的覆盖面。
    - Python 的元组目标、普通 import、推导式、lambda、海象变量、`global`/`nonlocal` 和 match 捕获，只能通过 `visibleBindings` 查到。原因是 VS Code 不给 Python 变量着色，多着色会拉低一致率。
    - 曾试过把这些名字也放进补全，结果 py-mem-16 中 `Path` 排到了 `path` 前面，已撤回。
  - **分片**：
    - `DeclarationScanner` 可以分步推进，`DocumentAnalysis` 在约 4 ms 的片内以每步 8192 单元推进，每片开始前核对版本。
    - `ensureDeclarations()` 接着把进行中的扫描做完，不从头再来。
    - debug 实测：10 MB Python 共 322 片、合计 1418 ms，最长一片 4.71 ms；10 MB JS 共 114 片、484 ms，最长 4.59 ms。
    - 新增 PerfLog 字段 `sliced`、`slices`、`maxSliceUs`。
  - **效果**：
    - 注释、字符串里的伪声明全部排除，包括 docstring 里每处都出现的伪声明 `Karu`。
    - 着色一致率：typescript 50.1 → 61.6、component.tsx 45.8 → 62.5、component.jsx 53.4 → 61.1、javascript 94.3 → 94.7，python 逐字节不变；全部样本 **77.7% → 78.8%**，没有样本下降。
    - 候选基线：作用域 top1 16/32 → 17/32（py-neg-04 的伪声明 `ghost_handler` 消失）；top3 11/11、禁用名 0 不变。
  - **内存**：
    - 快照：10 MB Python +179 KB（大纲 298 KB / 59,580 个作用域；声明流因伪声明减少，由 834 KB 降到 715 KB），10 MB JS +137 KB。
    - mem-benchmark（release、隔离诊断目录、与 HEAD 交替各两轮）：空文档 25/25 对 25/25，中 35/34 对 35/35，大 63/63 对 **61/61** MB，参考轮持平。
    - implementer 中途发现一次性扫描每步 1 M 单元会缓存约 20 万 token，large 常驻多 3.5 MB；已把每步上限改为 16 K 单元。
  - **改动的旧测试期望**：`DeclarationScanTests` 与旧正则的等价性检查只保留仍走正则的语言；Python/JS/TS 改为检查着色表、位置和补全符号三者自洽。
  - **测试**：
    - 新增 6 个套件、38 个测试，覆盖：
      - 夹具上无伪声明（经词法核对，含 jsx/tsx）；`cases.json` 全部作用域样本；Python 13 个、JS/TS 11 个结构测试。
      - 鲁棒性：4000+ 个截断或随机删字的变体，每个都在 1 s 内完成。
      - 分片等价：预算取 1、7、64、4096 和随机值。
      - 两步之间文本被改动的防护；`DocumentAnalysis` 分片发布。
    - 全量 **1083 tests / 58 suites** 通过（main 复跑）；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
  - **已知缺口**：
    - JS 不带块体的 `for` 循环，循环变量一直可见到下一个 `;` 或换行。
    - TS：`c ? (a) : b => x` 可能误读为箭头函数；类型字面量返回类型 `(): { … } {` 会读错；类型别名的泛型参数、interface/enum 成员都没有记录。
    - JSX 子表达式可能产生多余绑定（T17.8 处理）。
    - **`visibleBindings` 每次调用都解码整份快照**：T17.5 要缓存模块级绑定，才能满足热查询 p95 ≤8 ms。
    - 偏移量对应快照扫描时的文本版本，编辑之后的映射由 T17.5 处理。

- T17.4b 七种静态语言的基础版作用域（main 定接口，implementer 实现，main 审查 diff，2026-11-14）：
  - **做法**：Swift、Go、Rust、Java、C#、C、C++ 改用一个共用的 `BraceDeclarationWalker`（约 3000 行），按语言分别处理参数和局部变量的写法。
    - 声明只从代码 token 中提取；需要往后看的结构（参数表、`Type name`、闭包参数）只在有界前瞻里判定，所以分片方式不影响结果。
    - 现在只剩 Bash 和数据格式没有声明遍历器，正则模式只作测试参照。
    - Java/C#/C/C++ 另有一遍流式处理，保留旧路径的着色覆盖：`name(` 记为函数、`new T(` 记为类型。这些只进着色表和补全符号，不算声明。
  - **作用域规则**：
    - 函数作用域从参数表开始；类型体、命名空间、Rust `impl` 是类作用域；闭包和 lambda 各自成一个作用域。
    - 局部变量只在声明之后可见；同一作用域里取光标前最近的一次声明，所以局部变量能遮蔽同名参数，Rust `let` 重影也成立。
    - Java/C#/C++/Swift 的方法内可以看到外层类型的成员（隐式 `this`/`self`）；Go/Rust/C 不可见。
  - **列出规则**：着色表、导航和补全符号集按着色比对决定；函数、方法、类型始终列出。
    - Swift 的参数、局部、字段只供作用域查询，文件级变量仍列出，与旧路径一致。若把文件级变量也改为只供作用域，Swift 能从 69.5% 升到 74.5%，但导航会少掉这些变量，留到 T17.7 按语法位置着色时一并处理（main 决定）。
    - C 的局部变量和文件级变量只供作用域；Rust 的 `const`/`static` 只供作用域。其余语言全部列出。
  - **用户可见变化**：Java/C#/C/C++ 的符号导航不再列出每一处 `name(` 调用，只列声明。发布说明需写明。
  - **与 VS Code 的一致率**（开工时现跑 → 本次）：
    - c 95.6 → 96.4、cpp 56.1 → **69.2**、csharp 69.5 → **86.4**、go 70.7 → 80.1、java 75.6 → 80.1、rust 73.7 → 79.8、swift 不变。
    - **全部样本 78.8% → 80.7%**，没有样本下降。
    - 变化原因：参数、局部、字段按变量着色；构造函数和 `new T(` 按类型着色；注释和原始字符串里的伪函数消失。
  - **候选基线**：rust-decl-02 的 `retries` 由第 5 升到第 1（全部 top1 23/53 → 24/53）；其余不变，禁用名 0。
  - **改动的旧测试期望**：
    - C 的符号表 `variables` 现在包含参数和字段，即 `["n", "x"]`。
    - 正则一步扫描的测试改为「无遍历器的语言一步完成」。
    - 与旧正则的等价性检查改为覆盖检查：旧路径在代码里命中的名字必须仍在着色表里，至少核对 150 处。
  - **测试**：
    - 新增 10 个套件，覆盖：各语言注释、字符串、原始字符串、字符字面量里的伪声明；各语言的绑定结构与遮蔽；`f(x);`、`a = b;`、`x.y = 1;`、`return a * b;` 不产生声明；括号未闭合时的恢复。
    - 鲁棒性：每个夹具 200 次截断加 200 次随机删字。分片等价：所有夹具，以及约 1 MB 的生成 C、Swift 文件。
    - 全量 **1115 tests / 68 suites** 通过（main 复跑）；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
  - **性能**（debug，约 10 MB）：
    - C：一次性 356 ms，分片 86 片，最长 4.38 ms。
    - Java：一次性 1483 ms，分片 322 片，最长 4.97 ms。
    - Swift：一次性 1758 ms，分片 427 片，最长 4.43 ms。Swift 最接近 2 s 的警戒线：词法约 0.5 s，切 token 约 0.4 s，遍历约 0.9 s。
  - **内存**：
    - 快照大小：10 MB C +32 KB（调用处和伪声明消失后，声明数据反而变小）；Java +212 KB；Swift +484 KB（大纲 283 KB / 65,649 个作用域）。
    - mem-benchmark（release，与 HEAD 交替各两轮）：两边都是 26/35/61 和 25/35/61 MB，配对差 0。这三个场景不涉及这七种语言，符合预期。
  - **已知缺口**：
    - 未记录：Rust match 分支绑定、枚举成员、import、泛型参数。
    - 模式里未绑定：C# `is T x`、Java `instanceof T x`、Swift `newValue`/`$0`。
    - C 系：函数指针声明符不绑定；宏前缀声明（`EXPORT int f()`）会漏掉。
    - 可见性：C++ 类外定义的成员函数看不到所属类的成员；Swift extension 看不到原类型的存储属性。
    - `a * b;` 按 `*` 两侧是否都有空白判定是表达式还是声明。
  - **T17.4 完成**：所有带声明的语言都只从代码位置提取声明；Python、JS/TS 做完整作用域，七种静态语言做基础版。

- T17.5 候选模型、匹配与排序（main 定接口，implementer 实现，main 审查 diff 并修一处，2026-11-14）：
  - **候选引擎**（`Completion/` 下的纯值代码）：
    - `CompletionContext`：判定光标处是代码、字符串、注释还是纯文本；按 Unicode 标识符边界取前缀，JS/TS 认 `$`；把光标两侧的整个标识符作为替换范围，修复 `userCo│unt`；识别成员访问的接收者。
    - `Candidate`：显示名、插入文本、类别、合并后的来源、匹配级别、匹配区间，以及按身份（名字 + 类别组）去重。
    - `CandidateEngine`：按来源收集候选、分级匹配、排序、截取 50 项。
  - **触发**：
    - 自动弹出要求位置在代码或纯文本里，前缀至少 2 个单元，并以字母、`_`（JS 另含 `$`）开头。
    - 点号后允许零前缀，但必须有接收者证据：`self.`/`this.` 的类成员，或之前出现过的 `obj.name`。没有证据就不弹出，也不再在点号后提供关键字。
    - 手动唤起允许空前缀：代码里给当前作用域的名字，字符串和注释里给文档词。
  - **排序**：
    - 先比匹配级别：原大小写前缀 > 忽略大小写前缀 > 词首（驼峰、下划线、数字边界）> 有界模糊。模糊匹配只在已有上限的集合里做，不扫全部文档词。
    - 再比来源：作用域（当前函数优先，再按作用域深度）> [推断成员] > self/this 成员与用法证据 > 本文件声明 > [导入] > [工作区] > 关键字与内置名 > 文档词。方括号里是预留给 T17.11–14 的位置。
    - 然后依次比：光标附近的使用、最近接受（每个窗口最多 32 项）、字典序。
    - 大小写敏感的语言保留不同拼写；纯文本和 SQL 忽略大小写去重。
    - 光标处正在输入的那个标识符，只有在全文仅此一处时才排除；大小写更正（`urlvalue` → `URLValue`）照样提供。
  - **时效**：
    - `DocumentAnalysis` 记录自上一份快照以来的编辑日志（`EditJournal`），超过 256 条就标记为无法映射，退回只用模块级名字。
    - 光标前后 ±40 行内新键入的名字立刻可用，不必等去抖重扫。
    - 模块级绑定按快照缓存在 `DeclarationQueryIndex` 里，解决 T17.4 记下的每次查询都解码整份快照的问题。
    - 前缀变长且快照版本不变时，复用上次的匹配集。
  - **文档词索引**：改为排序的 UTF-16 索引，支持前缀区间二分查找，另有首字母索引；构建可以分步进行。
  - **接受**：写入前核对光标、版本、编辑计数和标识符文本，有变化就重算；用 `insertText(_:replacementRange:)` 替换整个标识符，并 `breakUndoCoalescing()`，一次撤销即可恢复。弹窗刷新时按身份保留选中项。
  - **声明遍历器补充**：Python 方法内 `self.x =`/`cls.x =`、JS 类内 `this.x =` 记为不列出的 `.property`，只供 `self.`/`this.` 成员候选使用。
  - **main 审查修改**：数据格式（json、jsonl、yaml、toml、xml）的字符串位置按纯文本处理。按新规则，JSON 的内容几乎都在字符串里，会变成不自动弹出；方案 §5.2 规定数据格式只用文档词，并没有要求关掉自动弹出。已补测试。
  - **候选基线**（开工时现跑 → 本次；已提交的基线文件未刷新）：
    - 调参集：作用域 top1 12/24 → **24/24**；成员 top1 3/12 → 4/12，前十命中 0/66 → 17/66；缺失 79/117 → 60/117；误弹 4/4 → **0/4**；禁用名 0。
    - 保留集：作用域 top1 5/8 → 7/8；误弹 2/2 → 0/2；禁用名 0。
    - 有明确目标的作用域样本，前三全中：调参集 29/29，保留集 11/11（方案 §13 门槛 ≥90%）。全部 top1 24/53 → 39/53。
    - selfThis（前十 0/9 → 9/9）与 usage（0/8 → 8/8）大幅提升；其余成员类别要等 T17.11 的推断。
    - 唯一退步：js-mem-06（保留集，`cache.ge`）。原来的 `get` 来自关键字表，现在点号后不再给关键字；T17.11 推断出 `Map` 后会恢复。
  - **性能**（约 10 MB、名字多样的 Python，光标在中部方法内，p50 / p95 / max）：
    - 热查询（release）：`in` 1.2/1.4/1.5 ms，`pa` 2.2/2.4/2.4，无匹配 0.4/0.5/0.5，词首 `br1` 1.2/1.4/1.5。debug 下最高为 `pa` 4.9/5.1/5.2。T17.0 的旧值是 141/300/64 ms。
    - 从按键到首批候选：release 2.9/10.5/12.4 ms，debug 4.1/13.1/16.8 ms（目标 p95 ≤50）。
    - 冷启动后第一个键：release 48 ms、debug 288 ms，含查询索引构建和检查点推进。
    - 文档词索引构建：release 一次 77 ms（旧正则 879 ms）；分片构建最长一片 release 4.0 ms，**debug 8.3 ms**。
  - **内存**：
    - 名字多样的 10 MB 文档：文档词堆内存 16.3 → 6.5 MB；查询索引约 610 KB，只在快照上第一次补全时建立。
    - mem-benchmark（release、隔离诊断目录、与 HEAD 交替）：第一组 large +2.0 MB，原因是词表哈希表按文档长度预分配；改为从 4096 槽起增量增长后复测，配对差为 0/0、−10/−2（噪声）、0/0，没有超过 2 MB 的。两组之间环境有漂移。
  - **改动的旧测试期望**：`suggestionsSortDictionaryOrderWithinGroup` 改为原大小写前缀在前（§5.3）；基线测试改为经 `TextStorageObserverHub` 传递编辑（编辑日志需要），HEAD 在新、旧两种测试写法下生成的 TSV 逐字节相同。
  - **测试**：
    - 新增 49 个测试：引擎 28、时效 14、控制器 7，另有可选基准 `KARU_T175_BENCH=1`。
    - 全量 **1165 tests / 72 suites**，main 连跑两遍都通过。implementer 在负载 7–8 下观察到 5 个计时类测试偶发失败，单独重跑都通过。其中 `checkpointResumedPythonHighlightMatchesFreshEngine` 在 HEAD 上也会失败，属于原有的不稳定测试，留意。
    - visual-smoke VISUAL OK、FOLD GEOMETRY OK。
  - **用户可见变化（发布说明）**：
    - 字符串和注释里不再自动弹出候选，需要时手动唤起；数据格式除外。
    - 点号后没有接收者证据就不弹出。
    - 接受候选时替换整个标识符。
  - **已知缺口**：
    - Python 的 `self`/`cls` 按字面匹配；JS 嵌套普通函数里的 `this` 仍当作类实例。
    - 用法证据是文本级的，只识别 `=`、`:=`、`for`、`as`、`let`、`const`、`var` 这几种重新绑定。
    - 查询索引在每次发布新快照后的第一次请求时才懒建。
    - 统计探针 (4) 仍在测已经不用的旧 `WordIndex.suggestions`。
    - debug 下文档词分片最长 8.3 ms，release 下 4.0 ms 达标。

- T17.7 配色与按位置分类（main 定接口，implementer 实现，main 审查 diff 并修两处，2026-11-14）：
  - **色板**：新增 controlKeyword、parameter（与变量同色、类别独立）、constant、escape、regex、interpolationDelimiter、tagName、attributeName、heading（加粗），类型色笔误修正为 `#4EC9B0`。
    - 另增两个表外类别：`tagPunctuation`（`#808080` / `#800000`）、`markupValue`（`#CE9178` / `#0000FF`）。两者的色值都来自主题文件，删掉会让 HTML/XML/YAML 的一致率明显下降（main 认可）。
    - 深浅两套色值都按 VS Code 1.146.0 的 include 链（`*_modern` → `*_plus` → `*_vs`）逐项核对，`TokenKind` 改为 `CaseIterable`，测试逐个断言两种外观的 hex。
  - **加粗标题**：用临时属性描边实现（`strokeWidth -3`，描边色等于前景色）。测试证明加与不加描边，字形位置、行片段完全一致，只有像素变化。
  - **实现**：
    - 扫描器新增 `.escape` 片段，长形式由 `StringForm.escapeForms` 声明；YAML 的 `''` 用 `doubledCloseIsEscape` 报为转义。转义在切分意义上仍是 token。
    - JS/TS 正则 atom 归为 `.regex`，内部再细分出转义、量词、分组和 flags；插值边界映射为 `.interpolationDelimiter`，可按语言改（`interpolationDelimiterKind`）。
    - `IdentifierPolicy`（每种语言一份）：声明位置的角色优先（取自已发布的声明快照，经编辑日志映射，并核对该处仍是声明名），其次是全文符号表，最后是语言的默认类别。声明快照每 64 个声明加一个 seek 点，只解码色带内的声明。
    - 每门语言的规则编译成一个合并的交替正则（`RuleSet`），每个位置只调用一次；在词首没匹配到规则时跳过整个词。规则输出与逐条匹配一致，有覆盖全部夹具的等价测试。
  - **main 审查修改**：C# 按 VS Code 处理（决策 L）。插值的 `{` `}` 改用标点色；逐字字符串里的 `""` 算转义。csharp 一致率 96.1 → **98.3**，相应三处测试期望已改。
  - **与 VS Code 的一致率**（开工时现跑 → 本次）：
    - **深色 80.7% → 94.9%**（含 main 的 C# 修正）；**浅色 76.1% → 91.6%**（C# 修正前测得）。没有样本下降。
    - 深色：python 58.1 → 98.8、yaml 53.5 → 99.9、java 80.1 → 99.8、javascript 94.7 → 99.8、typescript 61.6 → 98.5、go 80.1 → 98.9、rust 79.8 → 97.2、html 79.9 → 97.2、swift 69.5 → 95.9、bash 59.6 → 93.1、markdown 76.9 → 91.0、cpp 69.2 → 85.5、css 67.3 → 80.4。
    - 剩余差异较大的是嵌入语言（page.html 54.3、fences.md 64.2、jsx 79.3、tsx 84.3，属 T17.8），以及 C++ `R"glsl(` 嵌入、CSS 选择器、浅色下 JSON 键（`#0451A5`，没有对应类别）。
    - 新增浅色参照目录 `Tests/Fixtures/M17/baseline/vscode-light_modern/`（23 个 TSV，用 `vscode-tokens.js` 按 `light_modern` 生成）；`KARU_M17_LIGHT=1` 时导出浅色 dump。
  - **用户可见变化（发布说明）**：
    - Python 不再给名字的引用处着色，只给 `def`/`class` 名和参数着色，与 VS Code 一致。
    - JS/TS 和 Rust 里，未被调用的函数名改为变量色。
    - C 不再给类型和变量的引用着色；Java、Swift 不再给变量的引用着色。
    - Swift 文件级变量不再着色，但仍在导航里，解决了 T17.4b 留下的问题。
    - Markdown 斜体用控制关键字色（Dark Modern 的 `markup.italic` 就是这个色）。
    - HTML 中后面跟空白的布尔属性不着色。
  - **改动的旧测试期望**：都是类别细分带来的。含转义的字符串拆成 string + escape；return/if/`#include` 等改为 controlKeyword；插值边界改为 interpolationDelimiter（C# 为标点）；Python 的 self、前缀、f-string 字段、装饰器；各语言内置名；标记语言的标签、属性、值；YAML 键与标量；Markdown 标题等。完整清单见 implementer 报告的分类。
  - **测试**：
    - 新增 `SyntaxCategoryTests`（22 个，7 个套件）：色板、转义、控制关键字、常量规则（`HTTPServer`、单字母不算）、声明位置角色、加粗不影响布局。
    - 随机切分和对抗样本都补了长转义与 Bash 变量的片段。
    - 全量 **1188 tests / 80 suites** 通过（main 复跑）；visual-smoke VISUAL OK、FOLD GEOMETRY OK。
    - implementer 另渲染了深浅两种外观的截图（Markdown、Python、TS、HTML）核对。
  - **性能**（debug、800×600）：
    - 10 MB JS：首跳 137 → 131 ms，附近重绘中位数 2.6 → **1.6 ms**。
    - 10 MB Python：首跳 135 → 132 ms，附近重绘中位数 9.7 → **5.1 ms**。
  - **内存**：没跑 mem-benchmark。新增常驻只有声明快照的 seek 表（每 64 个声明约 8 B，40 万个声明约 50 KB），以及每个语言定义多一个合并后的正则。留到 T17.15 的整体对照。
  - **第三方声明**：新增 `docs/THIRD-PARTY-NOTICES.md`，注明主题色来自 VS Code（MIT）。是否把声明放进 App 包或「关于」窗口，在发版时由 main 决定（涉及 bundle-macos.sh）。
  - **未做**：TS 枚举成员着常量色（遍历器还不认识枚举成员）；CSS 选择器、浅色下的 JSON 键；嵌入语言（T17.8）。

- T17.6 候选界面与接受（main 定范围，implementer 实现，main 审查 diff 并加固两个计时测试，2026-11-14）：
  - **手动唤起**：
    - `EditorTextView` 重写 `complete(_:)`，转给 Karu 的手动请求，不调用 super，所以系统词表不会出现。
    - 实测 AppKit 的分发：单独按 Esc 走 `cancelOperation:`，不会到达 `complete:`；⌥⎋ 走 `complete:`。`complete(_:)` 内另有防护：如果当前事件是单独的 Esc，只关闭面板。
    - 弹窗打开时按 Esc 只关闭弹窗；按 ⌥⎋ 按手动请求刷新。
  - **菜单**：「编辑 ▸ 显示候选 / Show Completions / 候補を表示」，默认快捷键 ⌥⎋，已登记到快捷键设置（`menu.showCompletions:`，编辑器作用域，可以改键），不占用 ⌃Space。补全模块关闭或文本不可编辑时禁用。
  - **列表行**：
    - 名字用 12 pt 等宽字体，匹配部分加粗；右侧是灰色的类别标签，中英日三语：参数、局部、成员、函数、类型、变量、关键字、内置、模块、文件、文档词。
    - VoiceOver 读作「名字, 类别」；`detail` 留作签名摘要的接口。
  - **宽度**：按全部候选行（最多 50 行）中最宽的一行自适应，限制在 180–480 pt 之间，也不超出屏幕。面板仍优先放在光标上方，空间不够时放到下方，水平方向也限制在屏幕内；名字太长时截掉中间。
  - **输入法守卫**：
    - 有 marked text 时，`keyDown` 先关闭面板，再把按键原样交给输入法，不拦截也不触发候选。
    - 组字开始时（包括 `setMarkedText`）关闭面板；组字期间请求、刷新和按键处理都不执行。
    - 提交组字的那个键不会弹出候选。
  - **收起时机**：
    - 以下情况都会收起：接受、Esc、点击正文、光标移动（无编辑）、编辑器失焦、窗口失去 key、切换语言、关闭模块、滚动导致锚点离开可见区域（锚点仍可见时面板跟着移动）、窗口移动或缩放。
    - 不是按键带来的编辑（粘贴、撤销、菜单命令），在下一轮 run loop 收起，不在 `didProcessEditing` 里处理。
    - ⇧Tab、⇧⏎、⌘⏎ 和带修饰键的方向键收起面板，并把按键交给编辑器。这是行为变化：⇧Tab 和 ⇧⏎ 以前会接受候选。
  - **接受**：Tab、回车、小键盘 Enter、双击都走 T17.5 的安全接受（替换整个标识符、一次撤销即可恢复、写入前重新核对）。
  - **手动弹窗的保持**：光标留在同一个标识符里时保持手动模式；输入空格后回到自动规则。
  - **测试**：
    - 新增 `CompletionUITests`（37 个，6 个套件）：`complete(_:)`、两种状态下的 Esc、菜单三语与禁用、各类别标签的三语文案、宽度、匹配区间（含非 BMP 字符）、按身份保留选中项、模拟组字（按键透传、不重开）、各种收起时机、四种接受方式与撤销、emoji、组合字符、CRLF、空文档。
    - 发真实 `mouseDown` 的测试会卡在 AppKit 的鼠标跟踪循环里，已去掉；鼠标收起逻辑没有改动。
    - **main 加固**：全量运行时 `stopEscalatesToSIGKILL` 和 `checkpointResumedPythonHighlightMatchesFreshEngine` 连续失败，负载约 10；单独跑都能通过。前者把上限 4.5 s 放宽到 10 s（只用来防止从不升级到 SIGKILL，1.5 s 的下限不变）；后者把等待快照发布的条件轮询上限从 3 s 放宽到 20 s。两者断言都没改。之后全量 **1225 tests / 86 suites** 连跑两遍通过。
    - visual-smoke VISUAL OK、FOLD GEOMETRY OK；候选基线 `completion-summary.md` 与改动前逐字节相同。
  - **截图**：implementer 渲染了深浅两种外观、中英两种语言的弹窗截图（重新生成：`KARU_T176_SHOTS=<dir> swift test --filter CompletionScreenshots`），main 看过深色中文版本：标签、加粗匹配部分、选中色都正常。
  - **性能**（debug、10 MB 多样名字 Python、负载 4–10，与 HEAD 交替）：从按键到面板，p50 3.5–4.0 → 4.2–5.0 ms，p95 10.5–11.7 → 13.1–17.3 ms，目标 ≤50。多出的约 1 ms 来自测量宽度和设置面板 frame。新进程里第一次测量标签宽度约 55 ms（冷加载字体）。
  - **真实窗口与真实输入法实测：待做**。`interaction-checklist.md` 中已有自动化测试覆盖的：ACC-01、02、04、08、11、15、16，SAFE-01、04、05、06、07、08，MOD-07；IME 各项只做了模拟。需要真实窗口的：ACC-03、05、06、07、09、10、12、13、14 的确认部分，SAFE-02/03 撤销后的光标位置，SAFE-09–13，MOD-01–06、08、09；需要真实输入法的：IME-01 到 IME-10。由 main 在用户在场时用真实中文、日文输入法逐项执行，结果填进清单。

## M16 代码执行、工具链管理与语言列表（2026-11-12 立项）

用户决策（2026-11-12）：常驻内存三场景上限统一上调为 99 MB，目标值不变，新增常驻内存仍须评估并汇报；
新增单文件代码执行（设计见 ARCHITECTURE §6）；App 内安装/卸载工具链；设置中自定义工具栏与
“语言”菜单可选语言。SQL/HTML 不执行；不做运行时语系细化；输出面板带 stdin；增强识别与高亮共用；
`run` 模块默认开；工具链第一批 Python/Node/Go/Java/.NET（+ Zig 视实测），不影响终端全局环境。

| # | 任务 | 负责 | 状态 |
|---|---|---|---|
| T16.1 | ARCHITECTURE 预算/边界/§6、mem-benchmark 上限改 99 MB | main | ✅ 文档完成 |
| T16.2 | 语言列表设置（工具栏 + 语言菜单，Auto/Plain 常驻，导出白名单） | implementer，main 审查 | ✅ 实现，自动化通过；GUI 待本机实测 |
| T16.3a | 运行引擎：语言判定、增强识别、工具链定位、执行计划、posix_spawn 进程层、RunSettings、run 模块枚举 | implementer，main 审查 | ✅ 自动化通过 |
| T16.3b | 运行界面：输出面板与 stdin、菜单/工具栏、运行设置窗口、三语文案、窗口/退出生命周期 | implementer，main 审查 | ✅ 自动化通过；已预装本机待实测 |
| T16.4 | Zig 在无 CLT 条件下编译运行 C/C++ 的可行性实测 | main | ✅ 可行（见下） |
| T16.5 | 工具链管理：内置清单 + SHA256、下载/解压/原子安装/取消/卸载、缓存隔离、设置界面 | implementer，main 审查与真实网络验证 | ✅ 自动化 + 真实下载运行通过；GUI 待本机实测 |
| T16.6 | 全量测试、视觉冒烟、内存同环境对照、本机预装待实测 | main | ✅ 已预装本机，待用户实测 |

- T16.4 实测（main）：官方 index.json 最新版 Zig 0.17.1（2026-11-02）aarch64-macos，
  tar.xz 54 MB、SHA256 与官方一致，解压 432 MB；二进制为 ad-hoc 签名，未加 quarantine 时可直接运行。
  以 `env -i PATH=/bin DEVELOPER_DIR=/nonexistent` 屏蔽 Xcode/xcrun，并把 ZIG 缓存指向隔离目录，
  `zig cc` / `zig c++ -std=c++20` 在 native 与显式 `-target aarch64-macos` 两种模式均成功编译运行
  C（stdio/math/stdin/退出码 3）与 C++（vector/string/algorithm/thread）；产物仅依赖
  `/usr/lib/libSystem.B.dylib`。首次编译 4–6 s 并生成约 117 MB 缓存，缓存命中后 < 1 s。
  结论：C/C++ 纳入 Karu 可安装工具链，运行时固定传显式 target 以免依赖本机 SDK；
  磁盘占用按“安装 432 MB + 缓存上百 MB”向用户展示。限制：仅 libc/libc++，无 Apple 框架。
  本机装有 Xcode，屏蔽方式为环境模拟，真正无 Xcode 机器仍在 T16.6 前择机复核。
- T16.2（implementer 实现，main 审查 diff）：新增 `LanguageMenuSettings`（只存隐藏 id，key
  `languages.hidden.v1`）与“语言列表…”子窗口；工具栏与语言菜单共用纯函数布局，手动选中的隐藏语言
  以分隔线后的临时项显示；快捷键目录仍按全部语言生成，隐藏语言的绑定不丢失；命令面板随菜单不列隐藏语言。
  设置导出新增数组值（仅此 key），格式版本仍为 1：含隐藏列表的新导出文件在旧版导入会被判无效。
  验证：794 tests / 15 suites 通过；visual-smoke（隔离诊断目录）VISUAL OK、FOLD GEOMETRY OK。
  子窗口布局、菜单刷新与界面语言切换未做真实 GUI 交互，留待本机实测。常驻增量仅一个无存储共享菜单代理
  与每工具栏一个观察者，未单独跑内存基准，T16.6 统一对照。
- T16.3a（implementer 实现，main 审查）：`Sources/KaruCore/Run/` 新增判定器、`ToolchainLocator`（自定义 >
  Karu 安装 > 登录 shell PATH > 系统 PATH；CLT 与 java 占位程序先探测、不触发系统安装框）、`RunPlanBuilder`
  （临时目录 UTF-8/LF 快照，编译步骤在临时目录、运行在文档目录）、`CodeRunner`（posix_spawn 独立进程组、
  每次运行一个串行队列、≤30 次/秒合并投递、约 1 MB 输出上限、stdin 非阻塞且无 SIGPIPE、SIGTERM→2 s→SIGKILL、
  主进程退出后 0.5 s 清理残留进程组）。LanguageSniffer 增加 Go/Rust/Java/C#/C++/Swift/TS 规则，原有测试不改全过；
  无命中 8 KB 样本最坏耗时约 0.7→1.45 ms/次（仅未分类的未命名文档触发）。补充：缺 locale 时为子进程设
  `LANG=en_US.UTF-8`。main 审查后将 Go 由 `go run` 改为临时目录 `go build` 再运行，避免文档目录所在 Go module 干扰。
  验证：908 tests / 25 suites 通过；implementer 另以本机工具链手工跑通 python（stdin/中文）、node JS/TS、
  zsh shebang、clang C/C++20、swiftc；Java（本机无 JDK，正确报缺运行时）、go/rustc/dotnet/zig 未实跑。
  已知局限：`$SHELL -l` 不读 `.zshrc`，只在 `.zshrc` 设 PATH 的用户需用自定义路径或 Karu 安装工具链。
- T16.3b（implementer 实现，main 审查）：每窗口懒建 `RunSessionController`（持有 CodeRunner 与输出面板）；
  工具栏 Run/Stop（模块关闭时移除）；“运行”菜单 ⌘R / ⌘. / ⇧⌘Y，自动进入快捷键目录；输出面板插在编辑区下方
  （自带 5 pt 拖动分隔条，未用 NSSplitView，编辑区视图不换父），stdin 行仅运行中显示；面板文本只镜像 runner 的
  有界缓冲；隐藏面板释放视图但保留运行，× 停止并释放会话；关窗/模块关闭停止并释放；启动清理 24 h 前的临时目录，
  退出时 `stopAll(force:)`。设置新增“运行…”子窗口（来源/自定义路径/检测/C·C++ 参数），每行留 T16.5 安装位。
  验证：928 tests / 31 suites 通过（新套件 7 次、全量 4 次无波动）；visual-smoke VISUAL OK、FOLD GEOMETRY OK；
  mem-benchmark（隔离诊断目录）两次均 31 / 50 / 63 MB，与改动前同环境基线一致，未使用时无常驻增量。
- 本机预装（2026-11-12，main）：`bundle-macos.sh` Developer ID 签名（团队 9A84P4ZS84），6.0 MB，deep/strict 通过，
  包内无密钥类文件；版本仍 0.11.0 (25)，测试构建不升版本。正常请求旧实例退出后替换 `/Applications/Karu.app`，
  回退副本 `/Applications/.Karu-before-m16-20261112-223027.app`；启动后进程路径正确、二进制与构建一致。
  状态：T16.2 + T16.3 待用户实测；真实工具链运行与 GUI 交互尚未由用户确认。
- T16.5（implementer 实现，main 审查）：`ToolchainManifest`（6 项，固定官方 URL/大小/SHA256 或 SHA512，host 白名单）、
  `ToolchainStore`（`<AppSupport>/<bundle id>/Toolchains/<id>/<version>`、`.cache/<id>`、`.staging`）、
  `ToolchainInstaller`（ephemeral URLSession 落盘、拒绝非 https 跳转、CryptoKit 1 MB 分块校验、系统 tar 子进程解压、
  可执行文件存在且符号链接不逃逸、同卷 rename 原子就位、失败/取消清理暂存）、`ToolchainManager`（仅设置窗口打开
  或任务进行中存活）、`KaruManagedToolchains` 作为定位器默认 provider；设置 › 运行每行安装/取消/卸载与占用显示，
  Swift/Rust 行显示 CLT 状态并可调用 `xcode-select --install`。main 补：退出 App 时取消安装并立即 SIGKILL tar。
- T16.5 真实网络验证（main，临时探针测试，未入库，结束即删除）：正式下载器把 6 套工具链装入临时根目录，
  全部下载、校验、解压成功（python 1 s、node 1 s、go 2 s、JDK 3 s、.NET 11 s、zig 10 s）；以 source=managed
  逐一运行 Python 3.14.10、JS/TS（Node 26.13.1 类型剥离）、Go 1.27.4、Java 25、C#（.NET 10 文件程序）、
  C/C++（zig cc/c++ -target aarch64-macos），输出含中文全部正确。安装占用约 1.9 GB（.NET 654 MB、zig 426 MB），
  首轮缓存约 0.5 GB。下载文件无 quarantine 属性（仅 provenance），未经公证的 python/zig 二进制可直接启动。
  首轮发现两处全局写入：`~/Library/Application Support/go/telemetry`（Go 本地遥测，`GOTELEMETRY` 环境变量无效）与
  `~/.local/share/NuGet/Migrations`。修复：新增仅作用于编译步骤的环境覆盖（`compileEnvironment` →
  `RunCommand.environmentOverrides`），Go 编译步骤 HOME 指向缓存；.NET 设 `XDG_DATA_HOME` 到缓存。删除两处探针产物后
  以全新缓存复跑：8 种语言全部通过，全局路径（~/go、~/.npm、~/.nuget、~/.dotnet、~/.cache/zig、~/.config/go、
  ~/Library/Application Support/go、~/Library/Caches/go-build、~/.local/share/NuGet 等）无新增或修改。
  验证在测试进程内完成；加固运行时 Karu.app 内的点击安装与运行待本机实测。新增回归测试后 964 tests / 39 suites 通过。
- T16.6（main）：964 tests / 39 suites 通过；visual-smoke VISUAL OK、FOLD GEOMETRY OK；mem-benchmark 两次均
  25 / 35 / 61 MB（全部 PASS，低于此前同日 31 / 50 / 63 MB，降幅超出已知 ±5 MB 漂移，未归因于代码，按环境波动记录）。
  重新打包（Developer ID，6.4 MB，deep/strict 通过）并在正常退出旧实例后替换安装、启动，二进制与构建一致；
  删除同日中间测试构建，保留 v0.11.0 回退副本 `/Applications/.Karu-before-m16-20261112-223027.app`。
  状态：M16 全部实现并自动化验证，已装本机待用户实测；未提交、未发布。
- 用户实测反馈（2026-11-12）：取消勾选部分语言后“工具栏等处仍是全语言清单”。main 在本机真实 App 中核查：
  主菜单“言語”、新窗口工具栏下拉框、已打开窗口的实时更新均已正确过滤（以 Swift 临时取消勾选验证后恢复原设置）；
  未跟随的是设置窗口“インデント幅”的语言下拉框，它使用自己的固定列表。修复：该下拉框按语言列表过滤并在设置变化时
  重建（按 id 保持当前选择；若该处全部被隐藏则回退为完整列表），新增回归测试。965 tests / 39 suites 通过，
  visual-smoke 通过；重新打包替换安装后在真实设置窗口确认下拉框已去掉隐藏语言。“运行…”窗口的按语言配置行
  属于工具链配置，当时未按语言列表隐藏。
- 用户决定“运行…”窗口也跟随语言列表（2026-11-12，main）：被隐藏语言的配置行、检测结果行及 C/C++ 编译参数行一并隐藏，
  设置变化时实时更新；窗口改为在内容变化（检测结果、安装/CLT 状态异步到达、行显隐）后按内容重新适配并保持顶边。
  隐藏仅影响显示，已安装的工具链与按语言设置不变。顺带修复 T16.5 补丁引入的竞态：取消回调先 SIGKILL tar 后，
  解压循环可能报“tar signal 9”而非“已取消”，现于收尾时优先判取消（相关测试连跑 8 次稳定）。
  验证：966 tests / 39 suites 通过；visual-smoke 通过；重新打包换装后在真实“实行”窗口确认只显示未隐藏语言的行。

## 维护：新机公证凭据与文档校正（2026-11-12）

负责：main。状态：✅ 公证 profile 已恢复并验证；文档/配置校正完成，未改应用代码，未提交。

- 公证凭据：新机 `tinyeditor-notary` 确认缺失后，经用户指定使用既有 App Store Connect
  API Key（Key ID 752V43A8GR，私钥位于 `~/.appstoreconnect/private_keys/`，仓库外；
  Issuer 取自同团队另一项目的本地 env 文件，未写入仓库或日志）。保存前先以该 Key 直接查询
  公证历史，可见 83 条记录，含 v0.11.0 `0952040a-…` 与 v0.10.0 `aa5042cf-…`，确认为团队 9A84P4ZS84。
  `notarytool store-credentials` 校验通过后存入 login keychain；随后按 release-macos.sh 的
  `--keychain-profile tinyeditor-notary --keychain login.keychain-db` 方式查询历史成功。
  v0.11.0 记录的“发布依赖旧机公证”待办就此解除；未新建 Key，未改签名或 Sparkle 身份。
- 当前环境复核：macOS 27.2 (26B123)、Xcode 27.2、Swift 6.4.2。`swift test` 784 tests / 14 suites 通过。
  `mem-benchmark.sh`（隔离 `KARU_DIAGNOSTIC_DIRECTORY`）连跑 3 次均为 31 / 50 / 63 MB，全部 PASS，
  但中等文档恰等于 50 MB 上限（footprint 精度 1 MB），新增常驻状态须先评估此场景。
- 校正 CLAUDE.md：原红线路径（apple-app/、backend/、config.yaml）来自另一项目，本仓库历史中
  从未存在；改为 `scripts/bundle-macos.sh`、`scripts/release-macos.sh`、签名/公证/发布与 bundle ID。
  T9.1 所写“bundle ID 为 APNs 红线”同源误植：Karu 不使用 APNs，bundle ID 保留的实际理由是
  Sparkle 更新身份、偏好/Application Support 数据与文件关联。
- 环境约束一节改为当前事实（装有 Xcode、产物在 `.build/out/Products`，仍只用 Swift Testing）；
  ARCHITECTURE 加环境注记，选型不变。chore-worker 模型由 `claude-sonnet-5` 改为别名 `sonnet`，
  与另两个代理的 `opus` 别名一致。清理仓库根目录 439 个未跟踪编译中间产物（28 MB，均已被忽略）。

## v0.11.0 / build 25 发布（2026-10-17）

- 用户实测后确认“没什么问题”，授权推送新版本，并要求核对迁移后环境的遗漏。
  负责：main。状态：✅ 已发布、线上更新验证通过、正式版已安装本机；新机公证凭据迁移仍待完成。
- 版本改为 0.11.0、build 25。发布内容为默认打开方式管理及设置 JSON 导出/导入，
  保留 Bundle ID、签名团队和已发布更新公钥；原有两处 Claude 配置改动不纳入提交。
- 本轮重新验证：784 tests / 14 suites 全通过；release 视觉冒烟、折叠几何通过。
  内存首测 31 / 51 / 63 MB，中等文档 51 MB 超出绝对阈值；同环境已发布基线与候选版
  均为 51 MB，按架构的同环境对照规则未见新增回归，未将脚本 FAIL 标成 PASS。
- 新环境核查：Developer ID Application（团队 9A84P4ZS84）已恢复。首次实际签名在等待
  系统授权后遇到时间戳差异，新的临时副本重试签名及可信时间戳验证成功，正式签名 bundle 5.4 MB 已生成。
- 发现 GitHub CLI 与登录配置未迁移；已安装 gh 2.102.0，用户完成网页登录，登录 enkin-japan，
  Git 使用现有 SSH，未创建/上传新 SSH 密钥。
- 提交时另发现 Git 作者配置未迁移；根据项目最近提交，将当前仓库局部配置恢复为
  enkin <contact@enkin.dev>，不修改全局 Git 配置。
- 仍缺两项独立凭据：notarytool 的 tinyeditor-notary profile 返回 No Keychain password item found；
  Sparkle sign_update 的 ed25519 账户返回 Signing key not found。测试仅签名临时文件，
  未导出私钥或生成新密钥。须恢复原 Sparkle 密钥并用既有公钥验签，不能更换更新身份。
- 后续用户完成 Sparkle 密钥迁移；已验证恢复后的公钥与已发布版本一致，临时文件签名与
  公钥验签通过。当前只剩公证 profile；按用户要求优先识别并恢复旧条目，不新建/覆盖凭据。
- 用户复制旧钥匙串后无法用旧登录密码解锁。Apple TN3137 说明 macOS 26.4 起文件钥匙串
  可能还依赖旧机受保护熵文件，故密码正确也可能无法解锁复制件；尚未确认该文件的具体原因。
  不关闭 SIP；准备改用旧机原钥匙串提交公证，新机装订与发布，尚待旧机 Accepted 结果。
  已保留签名 app，并生成 `build/Karu-v0.11.0-notary.zip`，SHA256：
  `454198a1a1bbac7d178851136977f504c5b17e0c46afa2433d6d88be2e9fa182`。
  旧机公证与新机装订之间不得重新构建或重签 app。
- 已准备三语发布说明。凭据恢复后继续公证、装订、更新包验签、标签与 Release 上传、
  线上 latest 更新验证及正式版本机安装；当前未创建发布标签或上传资产。
- 发布收尾：用户在旧机完成同一签名 ZIP 的公证，返回请求
  `0952040a-1b4f-4bea-ae48-2048078c311e`，授权本次先使用该结果。
  新机未重新构建或重签 app；核对原 ZIP 与二进制哈希后成功装订并验证票据，
  Gatekeeper 返回 `Notarized Developer ID`。因新机 profile 尚未恢复，未在新机读取公证日志。
- 源码提交 `a2aa96bafe14b6a1e5ac9eaca1b2ca4e5e0c2574` 与标签 `v0.11.0` 已原子推送；
  三语发布说明和 Karu.dmg、Karu.zip、appcast.xml 已上传，草稿资产 SHA256/长度核对后公开为 latest。
  发布页：https://github.com/enkin-japan/karu/releases/tag/v0.11.0 。
- 本次续发检查：更新 ZIP 解包后 deep/strict 签名、装订票据及版本 0.11.0 (25) 通过；
  DMG 完整性与签名通过；三份公开 latest 下载的 SHA256/长度与本地一致；线上 appcast
  版本、build、URL、长度正确，线上 ZIP 用既有 Sparkle 公钥独立验签通过。
  本次未重跑先前的 784 项测试、视觉或内存检查，业务源码与验收提交一致。
- 正常退出旧实例后安装并启动 `/Applications/Karu.app`，进程路径、版本、二进制哈希及
  安装后的 Gatekeeper 验证通过，保留 `/Applications/.Karu-before-v011-20261017-182231.app` 回退副本。
  正式二进制 SHA256：`07a5793591bdc92b338d30d3bcfac12a1c35a41834c9b850c136d78efcecee60`。
  发布 ZIP SHA256：`6a9973352f08bd7283d0a938d1a89e864a3f7c04ec24ce5526d9d3dff747bcd4`。
  待办：将原公证凭据保存到新机 `tinyeditor-notary` profile 并验证，以解除后续发布对旧机的依赖。


## 设置增强：默认打开方式与配置备份（2026-10-17）

负责：main。状态：实现完成，784 tests / 14 suites 及视觉检查通过，内存对照未见回归；已预装本机待实测，未发布。

- 设置新增“默认打开方式”：按系统 UTType 分组展示格式和当前默认应用，支持搜索、多选、
  刷新；由用户点击后通过 NSWorkspace 正式 API 异步设置，按系统要求确认，再查询验证结果。
  同一类型的扩展名一起更改；非文本/过宽类型不提供操作。本机只读查询为 31 组、39 个扩展名，
  `.ts` 被系统识别为视频，故排除。补齐 bundle 已支持语言 Go/Rust/Swift 的扩展名注册。
- 设置新增 JSON 导出/导入：version=1 的明确白名单，包含界面语言、模块、编辑偏好、语言缩进、
  草稿本字体/置顶/全局键及快捷键覆盖；不包含文档/笔记、会话路径、窗口、更新器、凭据或系统文件关联。
  缺省项保留为未覆盖状态，导入时恢复内置默认，避免固定缩进宽度破坏内容自动检测。
- 导入先验证格式/版本、值类型与范围、快捷键结构及冲突，确认替换后再写入；失败不部分修改。
  磁盘读取最多 1 MB + 1 byte；通过同一设置通知刷新模块、字体、语言、快捷键缓存与编辑器选项。
  成功导入/导出在设置窗口显示反馈。系统文件关联不随配置导入自动修改。
- 默认应用页面只在打开时查询和分配状态，关闭释放；配置备份处理无常驻服务或新增外部依赖。
- 验证：新增 8 项测试，覆盖配置往返和隐私排除、无效/超大文件拒绝、失败原子性、缺省语义、
  快捷键冲突、扩展名分组及模拟部分失败。独立界面探针截图通过，主设置窗口完整显示所有入口。
  默认关联读取使用真实 NSWorkspace；写入用注入的服务测试，未改用户现有文件关联，系统确认流程待用户选定格式实测。
- release 视觉冒烟与折叠几何通过。内存首测 31 / 51 / 63 MB，中等文档超过绝对上限 1 MB；
  同环境交替复测：已发布 v0.10.0 基线 50 / 51 MB，新版 50 / 50 MB，未见新增回归。
  基线取已发布二进制的临时副本，仅对副本作 ad-hoc 签名以独立运行（不改正式安装），
  两版均使用同一夹具、隔离会话及 phys_footprint 口径；未把最初的基准 FAIL 隐去。
- 本机签名环境：Developer ID 打包返回 no identity found，只读检查为 0 valid identities。
  按项目既有 SIGN_IDENTITY=- 路径生成仅本机测试签名包，deep/strict 校验通过，体积 5.2 MB。
  正常退出旧实例后安装并启动，二进制 SHA256 与测试构建一致；保留原正式版回退副本。
  版本仍为 0.10.0 (24)，本轮未提交、推送、公证或发布；正式发布前需恢复有效 Developer ID 身份。


## v0.10.0 / build 24 发布（2026-10-10）

- 用户在预装体验优化构建后明确要求“发布”，公证受阻时要求暂缓，随后再次授权尝试。
  负责：main；状态：✅ 已发布、线上更新验证通过、正式版已安装本机。
- 内容：R1–R11 缺陷修复；草稿本有序列表插入重排；Python f-string 表达式高亮及滚动优化；
  全部快捷键设置；已审核的 Codex 项目配置与开发/发布文档。
- 发布源码：`e0480d7d230915e198f455a4c360ae8cc53cdc43`，标签 `v0.10.0`，版本 0.10.0、build 24。
  原有两处 `.claude/agents` 模型调整保留在工作区，未纳入发布提交。
- 发布准备阶段验证：macOS 27.0.1 (26A434)、Apple Swift 6.4；776 tests / 13 suites 通过；
  release 视觉冒烟与折叠几何通过；phys_footprint 三场景 34 / 46 / 64 MB，无跳过。
  恢复发布时确认应用/测试/脚本源码未变，未重复运行不受影响的测试。
- 初次公证及协议处理后的早期重试均为协议 HTTP 403，连历史查询也受阻，尚未创建请求。
  用户稍后再次授权重试时提交成功；期间未改变应用代码或公证凭据。
  Apple 公证请求 `aa5042cf-63f7-4d75-b93e-065acb7f3fdd` 返回 Accepted，随后完成票据装订。
- 产物验证：Developer ID deep/strict 签名、stapler、Gatekeeper 均通过；ZIP/DMG 中的版本
  和二进制一致，包内无密钥类文件；用应用内置公钥验证 Sparkle Ed25519 签名通过。
- [GitHub Release v0.10.0](https://github.com/enkin-japan/karu/releases/tag/v0.10.0) 已公开并设为最新版；
  Karu.dmg（2440359 bytes）、Karu.zip（2016789 bytes）、appcast.xml 三个资产均上传完成。
  从公开 `releases/latest/download/` 下载三资产，与本地产物逐项 SHA256 一致；线上 appcast
  为版本 0.10.0 / build 24，长度、下载 URL 与更新签名验证通过。
- 本机：正常请求旧 Karu 退出后替换 `/Applications/Karu.app`，安装版本 0.10.0 (24)，
  签名、公证及运行路径核验通过，安装二进制与已发布更新包一致；保留测试构建回退副本。
- 已知边界：原始偶发文本背景绘制异常仍未复现确切触发条件，发布说明保留该边界。

## 维护流程：Codex 配置迁移（2026-10-09）

- 用户审核后实施：新增根 AGENTS.md、项目 .codex/config.toml、implementer/reviewer/verifier
  三个代理配置，以及 DEVELOPMENT.md、RELEASE.md；仅更新本台账入口与架构描述。
- 继承用户当前模型/推理强度和权限，最多同时运行两个子代理；按收益委派，主会话负责架构、
  最终审查与发布。共享构建和 GUI 验证串行；verifier 不改业务代码，reviewer 只读。
- 将经用户确认的“先本机实测、明确发布指令后发版、退出旧实例后替换”规则从 Claude
  私有记忆迁入仓库；保留原 Claude 配置及用户未提交改动。
- ARCHITECTURE.md 校正为当前 TextKit 1 路径，并补记缩进点替代背景色块的既有决议。
- 负责：main。验收：配置格式、引用、Codex 加载及 diff 检查；不改业务源码、不跑应用发布。
  状态：✅ 七个新增文件及两份文档更新完成；四份 TOML 与文档引用通过检查，
  本机 Codex 0.162.0-alpha.2 严格 config/read 确认项目配置生效，prompt-input 确认根规则
  与主会话加两个子代理的容量。角色文件已静态校验，当前会话接口没有角色选择参数，
  角色实际加载/执行尚未验证，按 AGENTS.md 回退至主会话；未运行 Swift 测试或发布流程。

## 维护审查：代码缺陷排查（2026-10-09）

范围：当前 v0.9.10 源码，覆盖文档/恢复、编辑/布局、搜索替换、格式化、语言功能、
草稿本、设置与发布脚本。负责：main；仅审查，未修改业务源码或测试源码，未安装/发布。
状态：✅ 审查与复现完成；审查时均未修复。后续修复与验收见下节。

验证：本机 Swift 6.4（arm64 macOS 27 SDK）运行 `swift test`，755 tests / 11 suites 全通过。
临时探针链接本轮实际构建的 KaruCore；下列 11 项均取得动态复现证据。
涉及持久化的探针使用临时目录和隔离 defaults；未对用户真实草稿做破坏性验证。
两项崩溃发生于独立探针进程，异常栈分别指向单词高亮清除与搜索替换的正则范围。
本轮未重跑整套视觉冒烟、内存基准、真实 iCloud/全屏输入法或签名公证发布链。

| ID | 优先级 | 缺陷及复现证据 | 定位 / 修复方向 | 状态 |
|---|---|---|---|---|
| R1 | P1 | 单词重复高亮后在文末退格，30000 字符测试文档缩短为 29999 时抛 NSRangeException；栈为 processEditing → WordOccurrenceHighlighter.clearHighlights → removeTemporaryAttribute → 段落边界越界 | Editor/WordOccurrenceHighlighter.swift：编辑回调仍同步清临时属性，应采用 LinkDetector 已有的延迟合并方式 | ✅ 已修复，自动验证通过 |
| R2 | P1 | 搜索命中 `{100,6}` 后把正文缩为 1 字符，再点“替换”，NSRegularExpression 因旧范围越界崩溃 | Search/FindBarController.swift：正文变更未刷新 matches；同时在 SearchEngine 边界防御 | ✅ 已修复，自动验证通过 |
| R3 | P1 | 模拟崩溃遗留草稿后先走 Finder 打开入口再启动：windows=1、recovered=false、draftsBeforeQuit=1；正常退出后 draftsAfterQuit=0，用户从未看到草稿就被清理 | App/AppDelegate.swift：恢复不应只发生于无文件参数且没有已开窗口的分支，恢复与显式打开需协调去重 | ✅ 已修复，自动验证通过 |
| R4 | P1 | XML/plist 格式化将 `<string>  hello  </string>` 变为 `<string>hello</string>`；PropertyListSerialization 解析前后值确实不同 | Format/XMLFormatter.swift：flushText 无条件 trim，需保留文本值及混合内容语义 | ✅ 已修复，自动验证通过 |
| R5 | P1 | 模拟草稿目录写入失败后隐藏草稿本，panelReleased=true、persisted=""，新文本唯一的内存副本被释放 | Scratchpad/ScratchpadController.swift + ScratchpadStore.swift：写入必须返回结果，失败不能继续销毁缓冲区 | ✅ 已修复，自动验证通过 |
| R6 | P2 | 查找 `foo` 并单次替换为 `(`，实际得到 `(foo)` 而非 `(` | Search/FindBarController.swift：insertText 进入 EditorTextView 自动配对/包裹路径；程序性替换需保持字面语义与撤销 | ✅ 已修复，自动验证通过 |
| R7 | P2 | 合法 CRLF JSON 与多行 CRLF JSONL 均报 unexpected character '\r\n'，对应 LF JSON 正常 | Format/JSONFormatter.swift：Swift Character 将 CRLF 视为整体，扫描及 JSONL 分行不能仅识别单独 CR/LF | ✅ 已修复，自动验证通过 |
| R8 | P2 | `one\rtwo\rthree` 被 LineIndex 统计为 1 行，第二行偏移仍返回行号 1；应用却提供 CR 转换菜单 | TextModel/LineIndex.swift：重建及增量路径只识别 LF，需与 AppKit 支持的换行一致 | ✅ 已修复，自动验证通过 |
| R9 | P2 | 对 `a\r\nb\r\n` 首行执行复制到下方，得到 `a\r\n\na\r\nb\r\n`，多出空行并混入 LF | Editor/LineOperations.swift：endsWithNewline 用 Character 比较遗漏 CRLF，误走“无末尾换行”分支 | ✅ 已修复，自动验证通过 |
| R10 | P2 | Python 高亮切换为 Plain Text 后，首字符 foregroundColor 临时属性仍存在（before=true、after=true） | Highlight/HighlightEngine.swift：language 变 nil 后调度直接返回，需清除旧语言全部着色 | ✅ 已修复，自动验证通过 |
| R11 | P2 | CRLF Markdown 中第 2–4 行是完整代码围栏，第 5 行是新标题；却扫描出 2–6 的代码块和 1–6 的前一标题，吞入后续章节 | TextModel/FoldRegion.swift：fenceCloses 未移除整体 CRLF，闭栏被当作未闭合；同类换行判断一并审查 | ✅ 已修复，自动验证通过 |

修复建议顺序：先 R1/R2 崩溃，再 R3/R4/R5 数据保护，随后 R6–R11；
将上述复现转成针对性回归测试，并对真实入口进行验证。755 全绿不覆盖这些路径。

## 维护修复：R1–R11 与偶发绘制崩溃（2026-10-09）

负责：main。状态：实现完成、自动化验证通过、已安装本机；待用户日常实测，未发布。

- R1/R2：同词高亮的清除延后到编辑处理完成，并跟随编辑更新已绘制范围；搜索在正文变化
  和执行操作前刷新，正则替换防御失效范围。程序性替换走保留撤销的字面写入，修复 R6。
- R3/R5：Finder/CLI 打开同样执行恢复并去重；草稿本写入失败返回错误，保留窗口和文本，
  提示错误、阻止隐藏/退出，允许重试或另存。退出前再次检查保存，覆盖保存对话框期间的编辑。
- R4：XML/plist 保留文本值、混合内容及 xml:space="preserve" 的内部原文；结构性缩进仍整理。
  无 schema 时无法证明空白节点可丢弃，因此已有空白文本也保守保留；仅无文本节点的
  结构展开缩进。节点仅保存原文范围，避免每层复制整个子树。更新原本错误地要求裁剪文本值的测试。
- R7–R11：统一处理 CRLF 字符、CR 行索引、跨 CRLF 编辑边界、复制行及 Markdown 围栏；
  切换纯文本/未知语言时清空旧着色。行索引增量结果用 Foundation 行边界做独立交叉验证。
- 用户补充的 editor_bug.log：0.9.10 (23)，macOS 27.0.1，2026-10-07 主线程在
  NSTextStorage.ensureAttributesAreFixedInRange → NSLayoutManager 背景绘制中抛异常。
  没有业务函数或具体越界范围，不能直接归因为 R1，也不能宣称已复现这个偶发崩溃。
  同类防御同时收紧：ShrinkRepaintObserver 在编辑回调只标记可视区重绘、不查询字形；
  滚动通知后的语法着色延后合并；旧括号高亮清理加边界检查。仍需用户日常使用观察。

本轮证据：

- Swift 6.4 / arm64 / macOS 27：765 tests / 12 suites 全通过，包含 10 项新增回归测试
  （启动恢复另有 Finder/CLI 两个参数用例）。替换的字面值、撤销/重做均验证。
- 原临时复现探针重新链接修复后的库：7 种模式均 exit 0。30000 字符文档末端已有
  60 个高亮样本，连续退格 60 次不崩溃；失效范围替换不崩溃；草稿写失败时
  panelReleased=false；Finder 启动 windows=2、recovered=true。
- release 视觉冒烟：bright 96.9%、dark 0.47%，VISUAL OK；折叠关闭行与头行边界
  均为 18.4，隐藏行高度为零，FOLD GEOMETRY OK。
- 真实应用滚动探针 passes=20、mismatches=0；跨多行中文删除后 ghostPixels=0。
- 内存三场景均执行：空文档 34 MB、中等文件 45 MB、大文件 65 MB，达到预算要求
  （大文件已在上限）。额外直接采样确认 footprint 命令返回 phys_footprint，未用 RSS 回退。
- 新增 KARU_DIAGNOSTIC_DIRECTORY 供现有真实 App 探针隔离会话/草稿/草稿本；每次
  诊断启动清空诊断会话。崩溃恢复本身使用注入的临时 stores 测试。未操作用户真实草稿。
- 本机预装完成：正常退出旧实例后替换并启动 `/Applications/Karu.app`；Developer ID 签名
  与 deep/strict 验证通过，bundle 5.1 MB，版本仍为 0.9.10 (23)。安装二进制 SHA256 与
  本轮最终构建一致；保留最初正式版回退副本。未提交、推送、升版本、打标签或发布。
- 尚未验证：用户原始偶发闪退的完整触发步骤、长时间日常使用、真实 iCloud 与全屏输入法；
  本轮不运行公证或发布上传链。


## 体验优化：列表、Python 与快捷键（2026-10-10）

负责：main。用户确认快捷键方案为“全部命令可搜索、修改、清除、恢复默认、冲突提示，
保留草稿本全局热键”。状态：实现完成、自动化及资源验证通过、已安装本机；待用户实测，尚未发布。

- 草稿本：有序列表中间回车，当前项后插入新编号，后续连续同级条目依次重排；嵌套条目
  保持自己的编号，空行、退缩进或非列表同级段落终止重排。支持 CRLF、Unicode 和行内拆分。
  换行与所有编号调整通过最小编辑一次提交，撤销/重做均为一步。空条目回车退出列表不变。
- Python：新增流式词法状态，区分 f/rf/fr 字符串文字、变量、内置函数、数字、花括号和
  格式说明符；处理转义花括号、嵌套字段/引号、三引号及可视区从字符串中部开始的情况。
  不引入解释器、LSP 或全文 token 常驻表。约 10 MB 文档末尾状态扫描的首测为 0.42 秒，
  随后改为原生字符集合搜索跳过普通代码，并只保留一个视口附近的词法检查点；编辑即失效。
  同一 10.35 MB 夹具最终首跳 0.225 秒、附近重绘 0.0036 秒、附近向上滚动 0.0043 秒。
- 设置 → 全部快捷键：78 条命令，菜单项（含语言/编码参数和缩放替代键）由 MainMenu
  派生；补充下方插入行、草稿本待办/完成/置顶和全局唤起。只持久化覆盖值，支持搜索、
  单键组合及两段组合键录制、清除、单项恢复、确认后全部恢复，菜单与运行时即时同步。
- 冲突检查包括应用内相同组合、单键与组合键前缀冲突；编辑器/草稿本的独立命令允许复用。
  两段组合键限编辑器/草稿本聚焦时，2 秒超时或失去焦点即取消。普通文字和系统光标移动
  不改绑。系统或其他应用占用的全局键不属于应用内冲突表。
- 录制仅接收设置窗口事件，失焦/关闭/Esc 取消并移除监听；录制期间暂时注销草稿本全局
  热键，结束后恢复，避免全局热键抢走录制输入。快捷键详情窗口关闭后释放。

验证：776 tests / 13 suites 全通过；包含 11 项新增测试。更新旧 f-string 整段 string 的
断言为表达式分色；修正已有命令面板测试依赖别的测试先初始化 NSApplication 的顺序问题。
隔离 defaults 的真实设置窗口探针已录入 ⌃⌥⌘9 并验证保存；窗口截图检查通过。
最终 release 视觉冒烟 VISUAL OK / FOLD GEOMETRY OK；Python 实际窗口截图确认插值
变量、内置函数、嵌套格式字段、转义花括号与多行插值着色区分正确；主设置入口完整可见。
最终内存：空文档 33 MB、约 1 MB 文件 47 MB、约 10 MB 文件 64 MB，均为 phys_footprint
口径且没有跳过场景。Developer ID 打包签名及 strict 检查通过，bundle 5.3 MB。
本机安装完成：正常退出旧实例后替换并启动 `/Applications/Karu.app`，deep/strict 签名
验证通过，安装二进制与本轮构建 SHA256 一致。保留升级前测试构建供回退。版本仍为
0.9.10 (23)，未提交、推送、升版本或发布。


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

v0.9.10 发布（2026-08-11）：T15.11 退格 NSRangeException 崩溃根治（processEditing 内
  禁触 layoutManager 定为铁律）+ T15.12 无末尾换行文件的行尾杂散缩进点 + 缩进点改字号
  等比缩放（÷3，40% 固定）。本机预装实测通过后发版；latest appcast 解析 0.9.10/build 23；
  Gatekeeper "Notarized Developer ID"；发版尾按新铁律**先退出旧实例再装机**（v0.9.9 期间
  实测装机未退旧实例，旧实例 Sparkle 弹更新且更新必错，只能重装——流程已修入记忆）。

v0.9.9 发布（2026-08-08）：T15.10 三修（链接 tooltip 布局递归崩溃、崩溃恢复幽灵窗口+
  "不保存"偷写盘、缩进彩虹五轮收束改级别着色点）。四个诊断探针（LINK/SESSION/SCROLL/
  INDENT）+崩溃栈取证+截图量化取证全程实证；本机预装实测通过后发版；latest appcast 解析
  0.9.9/build 22；Gatekeeper "Notarized Developer ID"；发版后本机同步装 0.9.9。

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
| T15.10 | 实测反馈两 bug（v0.9.8 回归为主）：①264KB md 打开必崩——崩溃报告栈取证：LinkDetector 扫描后 addToolTips 对全文档链接取 glyph 矩形强制填布局洞→textView 长高→frameDidChange **同步**重入 addToolTips→递归爆栈（栈内循环 4 次可见，`Thread stack size exceeded`）；修复：tooltip 只按**可见区**链接注册（滚动/缩放换批，不再强制全文档布局，大文件非连续布局预算同时恢复），刷新一律下一轮 runloop 合并执行（通知回调零同步布局，递归按构造不可能）；KARU_LINKTEST 探针（真实 open 路径 + 超 512K 阈值保证布局洞 + 1900 链接压熔断线下；曾因 3000 链接触发自家 2000 熔断而"复现失败"）修复版 alive、可见区仅注册 3 块（原 3800）；无头环境凑不出真机通知风暴，未修版未能本地复现崩溃，栈证据充分判定根因，待用户原文件实测确认；②崩溃恢复把主动关闭的窗口也重开——关窗 windowWillClose 先删会话条目，随后 resign-key 通知触发 handleResignKey→recordSessionState **把条目写回**（正常退出被 clear() 掩盖，崩溃恢复现形）；修复：isClosing 旗标守卫，顺带堵住"不保存"关窗后失焦自动保存偷写盘的隐患；KARU_SESSIONTEST 探针 A/B：守卫关=幽灵复现 true、守卫开=false；③缩进彩虹相邻行随机缺口——第一轮：行片段矩形（铺满无隙）+ backingAlignedRect 像素对齐；用户复测"好转但仍有，滑动后缺口转移"→ 实锤跨脏矩形批次伪影（同一接缝边被两个绘制批次各画一半，亚像素差异露缝；无头全量渲染永远无缝照不见，GHOSTTEST 同款教训）；第二轮：**相邻行同缩进合并为整块矩形一次填充**（行间无接缝边可露缝）；用户复测仍存缝→截图量化取证（三采样列一致）：色带段顶按 ~44px 节距漂移（+4px/行摩尔纹），文字恒定 47.8px——**屏幕并存两代布局的像素**：色带是旧布局代画的，文字是当前代；字形区域由 TextKit 失效机制保证重绘，背景装饰不在其覆盖内。第三轮（两板斧）：①绘制路径全部改 `glyphRange(forBoundingRectWithoutAdditionalLayout:)`（绘制中触发布局位移已画片段且 AppKit 不失效，TextKit 明令禁止）；②setFrameSize 变化即整视口重绘清洗旧代残像。用户复测：**打开完美（代际错位已灭），滚动出缝、缝随滚动迁移**→第四轮 KARU_SCROLLTEST 插桩实锤最终机制：绘制批次跑在**布局未完成**的区域上，懒查询返回截断范围→色带画短（探针捕获 lazy={0,191} vs forced={0,194}），文字随后经正规失效补画→缝；修复：viewWillDraw（AppKit 认可的绘制前布局时机）ensureLayout 覆盖 preparedContentRect∪visibleRect 再扩 200pt（跨底边行余量），绘制中保持零触发；终验 13 批次 lazy==forced 全等。用户复测仍不行→**第五轮设计收束（用户拍板）：放弃背景色块形态，缩进彩虹改为「缩进点按级别着色」**——色块跨行距区域，正坐在 AppKit 失效机制的盲区（字形区域重绘有保障、行距区域无），四轮对抗证明该形态在真机合成路径下不可靠；着色点位于字形单元格内，与文字同区域、同失效、同重绘，整类伪影从形态上消失。空格与 tab 每个前导空白字符一点（tab 原先仅靠色块、现在不留白），调色板不变（5 色循环、点用 0.7 alpha），分隔线随色块一并移除；viewWillDraw 预布局与绘制零触发保留（其余背景装饰仍受益）。KARU_INDENTTEST 改验点渲染（dotPixels=1376，80 点全出）+PNG 目检 | Editor/LinkDetector.swift, Editor/EditorWindowController.swift, Editor/EditorTextView.swift, Gutter/IndentRainbow.swift, App/AppDelegate.swift（四探针钩子） | main | 四探针全绿；755 全绿 | ✅ 已装本机待实测 |
| T15.11 | 实测反馈：草稿本刚打开就崩（退格删除触发）——崩溃报告 + unified log 双栈取证：`deleteBackward → processEditing → LinkDetector.clearDecoration → removeTemporaryAttribute → invalidateDisplayForCharacterRange → getParagraphStart` 抛 NSRangeException，AppKit 状态残破后下一帧 `drawRect → ensureAttributesAreFixedInRange` 二次抛异常 `_crashOnException` 落地。根因（T15.10 同课下半场）：`didProcessEditing` 观察者运行于 **layoutManager 处理该次编辑之前**（storage 已新、layout 映射仍旧），此窗口内任何临时属性操作都会让失效路径用旧字形映射查段落边界而越界——代码里的 `range ≤ length` 保护挡不住（越界发生在 AppKit 内部换算）。修复：下划线清除推迟下一 runloop 转（`scheduleDecorationClear` 合并执行，cancel/deinit 同步取消），与 tooltip 修复同构。独立探针 A/B：同步清除无头一击复现**逐帧同栈**（`Index 30995 out of bounds; string length 30995`，同款保护在场仍崩），推迟后 60 次退格全幸存 | Editor/LinkDetector.swift | main | 探针 A/B（sync 必崩/defer 幸存）；755 全绿 | ✅ |
| T15.12 | 实测反馈：python 文件末行为代码时行尾多出一个缩进点——KARU_DOTTEST 探针（EditorTextView.dotProbeLog 零成本 tap，逐点记录绘制来源 + 文档行表比对）复现：末行有缩进 + 文件无末尾换行符时，绘制循环 `while loc <= endChar` 在 `loc == 文档长度` 多跑一轮，lineRange 解析回末行但点位按 `loc + column` 越过文档末尾，被 glyphRange 钳制到最后一个字符——缩进几列就叠画几个点在行尾同一位置（探针实录 4 点同 rect x=87.86）。判定**一般性 bug 与 Python 无关**（Python 只是"缩进末行+无末尾换行"最常见）。修复 `<=` 收 `<`（合法末行绘制上一轮已用正确 loc 完成）；探针复验三变体（末行无缩进/有缩进无换行/有换行）点位全对零杂散。同批：缩进点观感多轮实测收束为**直径 = 字号 ÷ 3**（锚点 12→4pt、18→6pt，随 ⌘± 缩放等比跟随），透明度固定 40% | Editor/EditorTextView.swift, Gutter/IndentRainbow.swift, App/AppDelegate.swift（DOTTEST 探针） | main | 探针三变体全对；755 全绿 | ✅ |

热键决策记录：⌘D 否决（全局热键抢占式，会废掉 Finder 复制/浏览器书签）；⌘⇧D 被 Mail 发送等占用；
⌥D 采纳（英文布局牺牲 ∂ 字符，可忽略）。菜单项落 View 菜单（无 Window 菜单，与命令面板同区），
不设菜单键等价（Carbon 热键对本 app 同样生效，且改键后菜单键会过期）。

## 依赖关系

T1.1 → T2.1 → T2.2/T2.3/T2.4（可并行）→ T3.1 → T3.2/T3.3（可并行）→ T3.4/T3.5
T4.1/T4.2 仅依赖 T1.1；T4.3 依赖 T2.2；T1.2 随时可做；T5.* 最后。

## 环境约束（委派时必须告知子代理）

- 单元测试一律用 Swift Testing（`import Testing`、`@Test`、`#expect`），不引入 XCTest；
  构建/测试命令为 `swift build` / `swift test`。工程不得以完整 Xcode 为前提。
  （2026-11-12 核对：当前开发机装有 Xcode 27.2、无独立 CLT，Swift 6.4.2；SPM 产物实际在
  `.build/out/Products/<Debug|Release>`，`.build/debug`、`.build/release` 为符号链接，脚本路径照常可用。
  早期“本机仅 CLT、无 XCTest”是 2026-07 旧机环境。）
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
