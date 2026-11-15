# Karu 开发与维护流程

本文件描述当前工作方式；入口和任务路由见 [AGENTS.md](../AGENTS.md)，
资源预算与产品边界见 [ARCHITECTURE.md](ARCHITECTURE.md)，历史证据见
[LEDGER.md](LEDGER.md)，安装与发布见 [RELEASE.md](RELEASE.md)。

## 开始任务

1. 检查分支、工作区差异和相关台账条目，保留用户改动。只读调查不创建分支；
   需要新分支时使用 `codex/` 前缀，除非用户另有要求。
2. 确认复现步骤、期望行为、影响文件和验收条件。复杂工作先列简短计划，
   已授权且边界明确的修复直接推进；不要为例行实现选择增加审批。
3. 对照当前代码确认文档描述。台账包含已被后续决策替代的方案，不能只取最早记录。
4. 新功能先评估常驻内存、瞬时分配、窗口资源和依赖成本，不默认扩大功能边界。

## 工程与环境

- SPM targets：`KaruApp` / `KaruCore` / `KaruCoreTests`；最低 macOS 13。
- 使用 `swift build`、`swift test`；测试框架为 Swift Testing，涉及 AppKit 使用 `@MainActor`。
  历史环境只有 Command Line Tools，维护时核对当前工具链，不假定完整 Xcode 可用。
- `Sources/KaruCore/App/` 管应用/文档/恢复，`Editor/` 管编辑交互与窗口，
  `TextModel/` 管共享索引，`Highlight/` 管着色，`Scratchpad/` 管独立草稿本。
- 根目录的 `.o`、`.d`、`.swiftdeps` 等及 `.build/`、`build/` 是忽略的生成物，
  不把它们当源码提交。`CotEditor/`、`monaco-editor/` 是参考项目，不是构建依赖。
- 不修改 `.claude/` 以完成 Codex 任务，也不把个人绝对路径或凭据写入共享配置。

## 修改时必须保留的行为

- NSTextView / NSLayoutManager 使用 UTF-16 范围；不能用 Swift 字符数替代 NSRange 长度。
  文本操作考虑 emoji、代理对、选区、空行和无末尾换行符的末行。
- 保持撤销事务完整；输入法组字期间不得贸然套用自动补全、列表或括号变换。
- 显示装饰留在临时属性或绘制层，不污染 textStorage 中的纯文本内容。
- `didProcessEditing` 中 storage 已更新而 layout 映射可能尚旧。不要同步清除临时属性、
  查询布局或注册会触发布局的 tooltip；沿用延迟、合并、取消与释放的处理方式（T15.10–11）。
- 绘制路径不强制触发布局；需要的可视范围在 `viewWillDraw` 等合适阶段准备。
  缩进彩虹现为字符单元格内的着色点，不恢复已放弃的跨行背景色块（T15.10–12）。
- 会话恢复区分正常退出、升级重启、崩溃和主动关窗；主动关窗不能被失焦回调重新记入会话，
  “不保存”也不能随后触发失焦自动保存。
- 崩溃草稿与常驻草稿本是两套生命周期；正常退出的清理、草稿本隐藏时持久化与视图拆除
  必须按当前代码和最新台账语义分别处理。
- 模块关闭、窗口关闭和草稿本隐藏时检查观察者、延迟任务、索引及视图状态是否释放。

## 验证矩阵

命令均从仓库根目录执行；由主会话指定唯一执行者，避免共享 `.build/` 和 GUI 状态互扰。

| 改动 | 必要验证 |
|---|---|
| 仅文档/代理配置 | diff 检查、引用检查、TOML 解析、Codex 配置加载；不启动 App |
| 逻辑功能或修复 | `swift build`、相关 `swift test --filter <实际测试名>`；应用代码交付前运行 `swift test` |
| UI、绘制、折叠 | 上述检查 + `bash scripts/visual-smoke.sh`；按问题增加真实 App 探针与交互验证 |
| 高亮、索引、大文件、常驻状态 | 上述适用检查 + `bash scripts/mem-benchmark.sh`，必要时同环境对照已知良好版本 |
| 保存、崩溃恢复、草稿本 | 隔离存储的状态机测试 + 对应真实入口验证，核对关闭/退出/崩溃不同路径 |
| 发布 | RELEASE.md 的完整发布检查与资源预算验证 |

- 回归测试应覆盖失败机制与边界，不为低影响文案修改编写镜像测试。
- 项目指令加载可用 `codex debug prompt-input` 检查模型输入中的项目规则及并发容量；
  它不证明自定义角色已被发现或运行。本机 0.162.0-alpha.2 的此子命令不接受
  `--strict-config`；严格配置检查可通过临时 `codex app-server --strict-config --stdio`
  的只读 `config/read` 接口完成，无需发起模型任务。诊断输出可能含全局指令，
  只保存临时副本并报告必要结论，不入仓库。
- 真实 App 探针设置 `KARU_DIAGNOSTIC_DIRECTORY=<本次绝对临时目录>`，隔离会话、崩溃草稿
  和草稿本，并在每次启动时重置诊断会话。诊断 defaults 域为
  `dev.enkin.Karu.Diagnostics.<临时目录末段>`，结束后可清理该域；它不隔离全局字体/语言偏好，
  因此探针不要改用户偏好。测试跨启动恢复应使用可注入 stores，不依赖这个清空会话的入口。
- 可用 `KARU_SNAPSHOT=<临时 PNG 路径> .build/release/KaruApp <夹具文件>` 自渲染快照。
  visual-smoke 包含空白窗口与真实 App 折叠几何检查；通过不代表滚动合成和全屏交互已通过。
- 更多探针入口位于 `AppDelegate.swift`：`KARU_FOLDTEST`、`KARU_SCRATCHTEST`、
  `KARU_LINKTEST`、`KARU_SESSIONTEST`、`KARU_SCROLLTEST`、`KARU_INDENTTEST`、
  `KARU_DOTTEST`、`KARU_GHOSTTEST`。参数不统一，运行前读当前实现，不猜测调用方式。
- 计时日志 `KARU_PERFLOG=<绝对路径>`（M17 T17.0，`App/PerfLog.swift`）：启动时一次性判定，
  未设置时每个埋点只多一次分支、不建文件。开启后以 TSV 追加
  `uptime_ns  event  duration_us  key=value…`，后台队列至多每 0.5 s 写一次，正常退出时补写；
  被强杀时可能丢最后 0.5 s。事件：`completion.request`（按键事件时间戳到弹出/刷新/收起，
  `result`、`count`、`prefixLen`、`lazyIndex`；T17.5 起另记 `reused`=1 表示前缀增长时复用了上次的匹配集）、
  `completion.index`（文档词索引重建；T17.5 起 `sliced`=1 为编辑停顿后的分片重建，时长为各片之和，另记 `slices`、`maxSliceUs`）、`highlight.pass`
  （`lang`、`painted`、`skipped`、`sliced`：色带落在超长行中间而只着色一段时为 1）、`analysis.declarations`（T17.1 起取代 `highlight.symbols`：每个文档版本一次的
  共用声明扫描，`docLen`、`lang`、`version`；T17.4a 起 `sliced`=1 为分片扫描，时长为各片主线程时间之和，
  另记 `slices` 片数与 `maxSliceUs` 最长一片）、`lexical.advance`（T17.2：着色前从最近检查点推进
  词法状态到色带起点，`lang`、`units` 扫描的 UTF-16 单元数、`resumedAt` 起点、`checkpoints` 现存数量）、`lexical.catchUp`（T17.15d-A：
  语言切换、编辑停顿或模块开关之后，把高亮与补全的两套检查点分片推进到文末，时长为各片之和，`slices`、`maxSliceUs`、
  `checkpoints` / `contextCheckpoints` 完成后的数量）。T17.15d-A 起 `analysis.declarations` 在超过 256 K 单元的文档上打开时也是 `sliced=1`。用
  `python3 -I scripts/m17/perf-summary.py <日志>` 汇总各事件的 count / p50 / p95 / max。
  M17 基线采集套件（`KARU_M17_BASELINE=1 swift test --filter M17Baseline`）另写
  `Tests/Fixtures/M17/baseline/` 与 `.build/m17-baseline/probes.txt`，普通 `swift test` 跳过。
  T17.7 起加 `KARU_M17_LIGHT=1` 时着色导出改用浅色外观，写入未纳入版本库的 `baseline/karu-light_modern/`，
  与 `baseline/vscode-light_modern/` 比对（`compare-colors.py … --neutral '#3b3b3b,#000000'`）；
  高亮单趟计时（10 MB JS / Python 首跳与附近重绘）用 `KARU_T177_BENCH=1 swift test --filter HighlightPassBenchmark`。
  内置类型表（T17.10）：`bash scripts/m17/gen-type-tables.sh` 重新生成（源码缓存在仓库外
  `/Volumes/enkin/project-support/KaruM17-TypeSources/`，可用 `KARU_TYPE_SOURCES` 改），`--check` 重新生成到临时目录并与
  `assets/typetables/` 逐字节比对；冷查询与解码内存用 `KARU_T1710_BENCH=1 swift test --filter TypeTableBenchmark`（单独运行）。
  类型推断（T17.11b，`Inference/`）：按键到成员候选的冷/热时延、推断部分与配对内存用
  `KARU_TYPE_TABLES=$PWD/assets/typetables KARU_T1711B_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter TypeInferenceBenchmark`
  （单独运行；release 测试进程找不到仓库路径，须设 `KARU_TYPE_TABLES`），报告写到 `.build/m17-baseline/t1711b-bench-<config>.txt`；
  带签名摘要的成员弹窗截图：`KARU_T1711B_SHOTS=<目录> swift test --filter TypeInferenceScreenshots`。
  `PerfLog` 事件 `completion.inference`（`docLen`、`members`，-1 为未知类型）。
- 项目文件夹索引（M17 T17.12，`Workspace/`）：库在 `~/Library/Application Support/dev.enkin.TinyEditor/Index/<hash>.sqlite`
  （裸二进制无 bundle ID 时为 `…/Application Support/Karu/Index/`），文件名是标准化路径的 FNV-1a 64 位十六进制，
  `meta` 表记录对应文件夹。只读查看：`sqlite3 "file:<库>?mode=ro" "select value from meta where key='folder'"`、
  `"select count(*) from files"`、`"select f.path, s.name, s.kind, s.container, s.line, s.signature from symbols s join files f on f.id = s.file_id where s.name = 'X'"`；
  不要在 Karu 运行时写库，清除请用设置里的「清除索引」。测试一律用注入的根目录和临时文件夹（`IndexFixture`）。
  首次全量与增量时延：`KARU_T1712_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter WorkspaceIndexBenchmark`
  （单独运行；`KARU_T1712_CPYTHON` 可改 CPython 标准库来源）。真实 App 配对内存：`KARU_DIAGNOSTIC_DIRECTORY=<临时目录>
  KARU_INDEX_FOLDER=<绝对路径> .build/release/KaruApp` 只把该文件夹索引进 `<临时目录>/Index`，使用隔离的文件夹列表，
  与不带 `KARU_INDEX_FOLDER` 的同环境启动交替对照。
- 导入语句补全（T17.16，`Imports/ImportCompletion.swift`）：按键到弹窗的主线程时延、首次目录列表的队列耗时与列表字节数用
  `KARU_TYPE_TABLES=$PWD/assets/typetables KARU_T1716_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter ImportCompletionBenchmark`
  （单独运行；合成 venv 2,000 个包、`node_modules` 1,500 个包、源码目录 400 个文件），报告写到 `.build/m17-baseline/t1716-bench-<config>.txt`。
  测试一律用注入的项目根与解释器（`ImportHarness`），`RecordingFileSystem.touchedOnMainThread` 断言主线程不读盘。
- `mem-benchmark.sh` 可用 `KARU_BENCH_APP_BIN=<二进制>` 指定被测构建（同机 A/B，跳过构建）；正式三轮之后
  另有两轮「推断样本（参考）」（`Tests/Fixtures/M17/inference/sample_1000.py` / `.ts`，只查 99 MB 上限）。
  各轮以 kill 结束，整体运行时应设置 `KARU_DIAGNOSTIC_DIRECTORY`，否则下一轮会恢复上一轮打开的文件。
- 采样为稳定采样：每轮持续轮询 phys_footprint，最近 2 s 波动不超过 0.5 MB 才取值，最长等 20 s
  （超时取最后读数并标“未稳定”）；表格末列「稳定于」为读数稳定的时刻（距启动秒数）。旧版固定 3 s
  采样会随时序落在启动期一次约 +20 MB 阶跃的前或后，产生假回归；与旧记录对比时注意口径不同。
  阈值可用 `KARU_BENCH_STABLE_SECONDS`、`KARU_BENCH_STABLE_TOLERANCE_KB`、`KARU_BENCH_MAX_WAIT_SECONDS` 调整。
  `KARU_BENCH_MIN_WAIT_SECONDS`（T17.15d，默认 0，与旧版相同）是最短观察时间：启动后这段时间内的读数不参与稳定判定，
  稳定区间必须整个落在它之后，读数最早在「最短观察时间 + 稳定窗口」取得；最长等待不足这个值时自动延长。
  用于主线程阻塞、内存暂时不动而会被提前取值的构建（v0.12.0 打开 10 MB 时 1.2 s 取到台阶前的 63 MB），
  例如对照 v0.12.0 的 10 MB 场景设 `KARU_BENCH_MIN_WAIT_SECONDS=8`。
  A/B 对照应交替运行 2–3 轮并记录负载（`uptime`）。
- 与 `/Applications/Karu.app` 的已发布二进制做 A/B 时注意（T17.15b）：它用 `dev.enkin.TinyEditor` 偏好域，会读用户自己的窗口尺寸与字号，
  诊断目录不隔离这些；裸二进制 `.build/release/KaruApp` 用 `KaruApp` 域（800×600、默认字号）。把已发布二进制拷出包外运行会因签名失效被 SIGKILL。
  需要同口径时给候选在命令行参数域传同样的值（如 `-editor.fontSize 18 "-NSWindow Frame EditorWindow" "<基线的窗口串>"`，不写偏好域；
  AppKit 之后可能把窗口尺寸写回 `KaruApp` 域，跑完要恢复）。另外稳定采样可能在主线程阻塞、内存暂时不动时提前取值（v0.12.0 打开 10 MB 时
  1.2 s 取到 63 MB，3.7 s 才跳到 104 MB），对照大文件时同时看长窗口读数（启动后追 14 s，取最后 2 s 平均）。
- M17 质量报告（T17.15b，`docs/M17-QUALITY-REPORT.md`）的复现：`KARU_M17_BASELINE=1 KARU_M17_OUT=<临时目录>` 让基线套件把着色导出与候选
  TSV / 汇总写到该目录，冻结的 `Tests/Fixtures/M17/baseline/` 不被覆盖（不设时行为不变，仍写 baseline/）；再用 `compare-colors.py` 和 T17.0 的
  `completion-baseline.tsv` 对比。真实窗口验收套件 `KARU_TYPE_TABLES=$PWD/assets/typetables KARU_PERFLOG=<日志> KARU_T1715B_FILES=<文件>[:<文件>…]
  KARU_T1715B_OUT=<报告> swift test -c release -Xswiftc -enable-testing --filter M17AcceptanceBenchmark`（`KARU_T1715B_PAIR=<a>:<b>` 测双窗口）
  逐段记录同步耗时、主线程最长停顿、峰值与在用量，并输出每段的 uptime 区间以切 PerfLog；测试进程里的 footprint 只作参考。
  T17.15d-A 起加 `KARU_T1715B_GAPLOG=1` 时，每段另列超过 20 ms 的主线程空隙（`gaps <段>  <结束 uptime>:<毫秒>`），用来对照 PerfLog 找停顿来源。
  release 测试构建会覆盖 `.build/release/KaruApp`，跑完重新 `swift build -c release` 再做 App 内存测量。
- 会启动 App 的验证先检查用户数据副作用。特别是草稿本探针会写示例内容，不能直接对
  用户真实草稿运行；使用现有隔离入口或由主会话先设计隔离，不声称环境变量天然隔离。
- 内存以 ARCHITECTURE.md 的窗口尺寸和 phys_footprint 口径判断，记录系统/工具链与构建。
- 99 MB 上限只约束三个正式场景（空文档、约 1 MB JSON、约 10 MB Python）。M17 压力夹具中超出的几项经用户判定通过、不做降级（2026-11-15）：
  10 MB 大量不同名字约 113 MB、两个窗口各开一个 10 MB 文件约 146 MB、5 MB 单行 JSON 约 258 MB（TextKit 排版），均低于 v0.12.0 同条件读数；
  复测时与质量报告第 7 节对照，明显变大才算回归。这些只记在开发文档，不写进 README 和更新推送。
  脚本可能回退 RSS 或跳过场景；必须披露，不能据此宣称全部预算通过。
- 单测环境、静态快照与真实通知/滚动路径不同。复现不了时如实记录，结合崩溃栈、
  几何日志或 A/B 证据判断；需要用户实测的项目保持待验收状态。

## 陈旧构建与失败处理

先确认编译成功、运行的是 `.build`、`build/Karu.app` 还是 `/Applications/Karu.app`，
以及旧实例是否仍存活。不要把旧构建的表现归因于新代码。
只有存在陈旧构建证据时才安排干净重建；由主会话串行处理缓存，避免删除未保存的诊断证据。
失败报告写清命令、退出码、复现输入、关键日志与已排除因素，避免重复无变化的尝试。

## 收口与知识维护

- 主会话检查最终 diff、验收结果和用户已有改动是否完好；代理完成不等于任务已经验收。
- 更新台账时区分“实现完成”“自动化通过”“本机待实测”“用户确认”“已发布”，
  不仅打一个完成勾。历史测试数量不是当前验收门槛，应记录实际结果。
- 行为变化更新用户文档，架构变化更新 ARCHITECTURE.md；流程经验更新本文件或 RELEASE.md。
  不建立第二份独立任务台账，不依赖 Claude 私有记忆才能接手。
- 草稿本在其他 App 全屏 Space 中的输入法候选窗问题，T15.6 在 macOS 27 beta 上
  记录为平台限制。该结论有环境边界；系统变化后再复测，不写成永久平台事实。
- 提交、推送按用户本次任务授权执行；正式发布遵守 RELEASE.md。

## Codex 配置维护

根 AGENTS.md 保留常用约束与入口，详细流程按需读取。项目 config 仅启用代理并限制
同时运行两个子代理（不含主会话），模型、推理强度与权限继承用户/会话设置。
角色文件不固定模型；reviewer 请求只读沙箱，并始终以指令禁止修改。
客户端实时权限覆盖或组织策略可能影响沙箱设置，不能把角色文件视为绝对隔离保证。
角色不可用时主会话直接执行；不要为了获得角色启动第二套后台 Codex 会话。
路由、角色描述和实际权限改动后检查一致性；配置在新会话加载，当前对话的工具不保证热更新。

2026-10-09 本机验证：0.162.0-alpha.2 已读取项目 config，`agents.enabled=true`、
`max_concurrent_threads_per_session=2` 生效，根 AGENTS.md 进入模型输入。
三个角色 TOML 已通过格式和必需字段检查；当前对话的 spawn 接口未暴露自定义角色选择，
尚未验证三个角色的实际加载/执行。后续在支持该入口的会话中验证，在此之前使用上面的回退规则。
