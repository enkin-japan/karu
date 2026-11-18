# Karu 全面工程审查：功能增长已快于可靠性建设

审查日期：2026-11-18。源码基线：`31860ea`，开始审查时工作区干净。

## 结论

Karu 的问题不是功能少，也不是缺少优化意识，而是**已经承担了小型代码编辑器的复杂度，却仍有若干关键路径停留在小工具的可靠性水平**。保存覆盖、恢复副本、正则搜索和格式化，都是用户最容易把信任交给编辑器的地方；本轮恰好在这些地方找到了实质缺口。

“轻量”目前较多地由特定场景的测量和开发者纪律维持，尚未成为所有输入路径都必须遵守的系统属性。部分预算只是结果缓存的上限，不能约束计算期间的内存和耗时；部分验收脚本可以在口径变化、场景缺失或状态污染时给出成功退出码。继续增加语言规则和代码智能，会进一步放大这类薄弱环节。

建议把下一轮工作的优先级放在数据保全、输入工作量上限和可重复验收上。无需推翻 AppKit、TextKit 1、SPM 或手写解析器，也不需要引入 LSP、后台服务或一套庞大的插件架构。

## 审查边界与证据等级

这是覆盖主要子系统的工程审查，不是声称逐行证明全部源码正确，也不是一次完整发布验收。

- 当前有 184 个 Swift 源文件、79,508 行源码（含注释与空行），131 个 Swift 测试文件；22 个源文件超过 1,000 行。数字用于描述规模，不直接证明质量。
- 阅读了架构、开发、发布约束及相关最新台账；按调用链重点审查文档保存、崩溃恢复、草稿本、查找替换、格式化、分析调度、导入缓存、项目索引、运行与安装、测试及发布脚本。
- 对高亮、补全、推断、布局和设置做结构与关键边界抽查，没有逐条验证所有语言规则、所有设置或所有系统版本。
- 本轮只新增报告和更新台账；没有修复应用代码，没有启动或安装 Karu，没有改动用户文档或偏好，没有签名、发布或联网下载工具链。

证据等级：**实测**＝本轮直接编译仓库生产代码并在临时目录复现；**静态确认**＝可由当前调用链或分支直接推出；**设计风险**＝既有策略的代价，或尚待实际交互验证的风险；**历史待查**＝以前报告留下的未决事项，不当作本轮复现。

优先级：P1＝可能丢失内容、长时间阻塞交互，或使重要验收失真；P2＝明确的可靠性、性能、维护性缺口；P3＝文档和使用契约不清。没有把任何事项定为“必然发生于所有用户”的 P0。

| 编号 | 优先级 | 问题 | 证据 |
|---|---|---|---|
| R01 | P1 | 保存无外部修改冲突检测，直接覆盖新磁盘内容 | 实测 + 静态确认 |
| R02 | P1 | 草稿本读取失败被当成空内容，随后可能覆盖原文件 | 实测 + 静态确认 |
| R03 | P1 | 搜索在主线程执行无预算正则，极短输入也能长时间阻塞 | 实测 + 静态确认 |
| R04 | P1 | 格式化的全文 Character 数组与 4 倍瞬时预算不相容 | 静态确认 + 类型大小实测 |
| R05 | P2 | 草稿检查点没有最大等待时间，失败也不可观测 | 静态确认 |
| R06 | P2 | 草稿正文与元数据不构成一个原子事务 | 中断状态模拟 + 静态确认 |
| R07 | P2 | 恢复冲突策略直接删除一份可能独有的内容 | 既有用户决策的设计风险 |
| R08 | P2 | 导入缓存永远保护最新条目，字节上限不是硬上限 | 静态确认 |
| R09 | P2 | 导入读取和目录枚举的工作量未被结果上限约束 | 静态确认 |
| R10 | P2 | XML 格式化器的接受/拒绝边界与“XML”承诺不一致 | 实测 |
| R11 | P1 | 内存验收脚本不能独立证明预算通过 | 静态确认 |
| R12 | P2 | 视觉脚本默认未隔离应用状态，覆盖面也很窄 | 静态确认 |
| R13 | P2 | 发布质量门禁主要靠人执行，签名工具缓存缺少身份核对 | 静态确认 |
| R14 | P2 | 单一逻辑 target 与大型控制器承载过多职责 | 结构审查 |
| R15 | P2 | 测试数量不能弥补系统矩阵、真实交互和故障注入缺口 | 仓库证据 + 本轮验证边界 |
| R16 | P3 | 用户文档与当前能力、验证方式及编码语义脱节 | 静态确认 |

## 一、数据保全：优先修理，而不是继续叠功能

### R01：原子写入不等于安全保存

位置：[DocumentController.swift](../Sources/KaruCore/App/DocumentController.swift)，`save` / `write`，159–177 行；[EditorWindowController.swift](../Sources/KaruCore/Editor/EditorWindowController.swift)，`autoSaveOnFocusLoss`，1676 行。

`baselineDigest` 只用于比较内存文本与上次载入/保存的文本。真正保存前没有重新核对磁盘版本，也没有文件协调或冲突处理；`.atomic` 仅保护一次写入的替换过程。

本轮复现：打开内容 `base` → 外部把文件改成 `external-change` → 当前文档保存 `local-change`。保存成功，磁盘变成 `local-change`，`isDirty=false`，外部内容没有留下副本。开启失焦自动保存后，这条路径甚至不需要用户再次按保存键。自动保存默认关闭，降低了默认暴露面，但没有解决手动保存的问题。

**改进与验收：**保存前检测文件身份和版本变化；发生冲突时保留双方内容并让用户选择。检测与替换之间的竞态也要处理，不能只加一次孤立的 mtime 判断。至少覆盖外部编辑、删除重建、同步软件替换、两窗口指向同一文件；冲突失败不得清 dirty 或删除恢复副本。

### R02：草稿本把“没有内容”和“无法读取内容”混为一谈

位置：[ScratchpadStore.swift](../Sources/KaruCore/Scratchpad/ScratchpadStore.swift)，85–104 行；[ScratchpadController.swift](../Sources/KaruCore/Scratchpad/ScratchpadController.swift)，`makePanel` 中读取、`hide`、`flushNow`。

`read()` 对不存在、读失败和 UTF-8 解码失败都返回 `""`。面板随后把这个空串当作有效内容，隐藏和退出会无条件尝试写回。现有写失败保护只能保护已载入的内存副本，无法保护从未成功读进来的原文件。

本轮向临时 `content.txt` 写入不可解码的三个字节；`read()` 返回空串；调用控制器最终会使用的 `write(loaded)` 后，文件变成零字节。完整 GUI 路径未运行，但读取与覆盖的生产存储代码已直接复现。

**改进与验收：**返回“缺失 / 成功 / 失败”三种状态；失败时禁止自动写回，保留原文件并提供重试或导出路径。对损坏内容、短暂读取失败、权限变化分别做故障注入，验证隐藏/退出不把空视图写成事实。

### R05：崩溃保护没有可承诺的最大丢失窗口

位置：[EditorWindowController.swift](../Sources/KaruCore/Editor/EditorWindowController.swift)，730–759 行；[ScratchpadController.swift](../Sources/KaruCore/Scratchpad/ScratchpadController.swift)，525–553 行；[DraftStore.swift](../Sources/KaruCore/App/DraftStore.swift)，81–93 行。

两种草稿都采用每次输入重置的 1.5 秒去抖。只要连续输入的间隔一直小于 1.5 秒，检查点就可以无限延后；“1.5 秒自动备份”不能理解为最多丢 1.5 秒。普通编辑器的 `DraftStore.write` 还会吞掉所有错误，不向调用方返回备份失败状态。

普通文档的草稿写入放到后台队列是正确方向，但 `flushDraftNow()` 仍先在主线程把全文转为 UTF-8 数据并计算 SHA-256；草稿本则直接在主线程写全文。“后台写入”没有覆盖全部成本，“草稿本只放小笔记”也没有输入大小限制来落实。

**改进与验收：**保留去抖，同时设置最大检查点间隔；合并后台待写快照，防止慢磁盘积压；公开最近一次备份成功/失败状态。持续输入测试要证明定期落盘，失败测试要证明不误报安全，大小文件分别测主线程耗时。这里尚未实测大文件检查点时延，不虚报毫秒数。

### R06：两个分别原子写入的文件，不是一个原子提交

位置：[DraftStore.swift](../Sources/KaruCore/App/DraftStore.swift)，文件头承诺、81–90 行、111–130 行。

正文先覆盖固定的 `<uuid>`，元数据再覆盖 `<uuid>.json`。首次写入时，元数据可以近似充当提交标记；覆盖已有草稿时，旧元数据一直存在。如果两次写入之间崩溃或第二次失败，读取方会接受“新正文 + 旧路径/旧时间”。

本轮模拟这个中断状态：先正常写入 `old-content`、`/old-path`，再只原子替换正文为 `new-content`。`drafts()` 返回 `new-content|/old-path`，没有识别版本不一致。这是可接受混合状态的直接证据，不是声称已在真机上撞中了崩溃窗口。旧时间还会干扰 R07 的冲突判断。

**改进与验收：**使用带代次的正文文件和最终原子替换的 manifest，或一个原子容器；写完才切换提交指针。对每个持久化步骤注入失败/中断，恢复结果只能是完整旧版或完整新版，不能拼接两代数据。

### R07：恢复冲突以删除一份内容收场，策略过于激进

位置：[AppDelegate.swift](../Sources/KaruCore/App/AppDelegate.swift)，`restoreDrafts`，898–925 行。

当前规则是磁盘修改时间晚于草稿时间时直接 `remove` 草稿，只闪现状态栏提示。代码明确标注这是用户决策；本报告不把它伪装成实现违约，也不建议未经确认改变语义。

但“较新”不等于“包含另一份内容”。用户未保存的修改与外部修改可以各自有价值。mtime 也不能表达文件身份或内容继承关系。为避免自动覆盖磁盘而删除唯一恢复副本，是把冲突交给数据损失解决。

**建议重新评估：**磁盘仍可作为默认打开版本，同时把冲突草稿保留为未命名文档或有保留期的恢复副本。验收应包含双方分别新增不同段落、仅更新时间戳、文件替换等情形。决策未改变前，应明确告知这一限制。

## 二、响应速度与资源预算：上限要约束过程

### R03：搜索把任意正则直接放到主线程

位置：[SearchEngine.swift](../Sources/KaruCore/Search/SearchEngine.swift)，43–51 行；[FindBarController.swift](../Sources/KaruCore/Search/FindBarController.swift)，427–429、455–480、564–575 行。

搜索框每次变化同步执行全文 `regex.matches`，没有取消、时间预算或匹配数量上限。匹配结果全部保留，并逐个写入临时背景属性。这也使大量普通匹配成为成本问题，不只是不良正则的问题。

本轮直接调用生产 `SearchEngine.matches`：输入 32 个 `a` 加 `!`，模式 `^(a+)+$`。隔离子进程超过 3 秒仍未返回，由外层超时终止。结合 UI 的同步调用链，可以确认该工作会阻塞交互；没有在用户应用里制造卡死。

**改进与验收：**搜索脱离 UI 同步路径；按文档版本丢弃过期结果；设置可终止的工作预算和结果上限，装饰只处理可见区域。仅移动到一个后台队列还不够，取消必须能停止昂贵匹配本身。验收同时覆盖病态正则、单字符百万次命中、编辑过程中旧搜索返回及替换撤销。

### R04：格式化的底层表示已经击穿书面预算

位置：[JSONFormatter.swift](../Sources/KaruCore/Format/JSONFormatter.swift)，107 行；[XMLFormatter.swift](../Sources/KaruCore/Format/XMLFormatter.swift)，65 行；[EditorWindowController.swift](../Sources/KaruCore/Editor/EditorWindowController.swift)，1343–1364 行。

JSON 和 XML 都先 `Array(text)`，形成完整 `[Character]`，之后再保留 token 或节点并生成输出。本轮当前工具链的 `MemoryLayout<Character>.stride` 是 16 字节。对 ASCII 输入，仅这一个数组的元素存储就约为文件字节数的 16 倍，尚未计入原文、token、AST、输出和撤销内容。

因此，架构中“格式化瞬时峰值上限＝文件大小 × 4”没有被这个实现满足。这个判断是表示层分配下界，不是将 RSS 冒充本轮 phys_footprint 峰值。尝试用 `/usr/bin/time -l` 获取进程峰值时被环境的 `sysctl kern.clockrate` 权限限制阻止，未得到有效峰值数据。

格式化还在主线程同步运行，递归解析/渲染缺少明确的深度及输出大小限制。极深输入可能消耗大量栈和缩进输出；这部分是静态风险，本轮未故意触发栈溢出。

**改进与验收：**采用 UTF-8/UTF-16 游标和流式输出，限制深度、输出增长和执行预算；把计算与最终一次可撤销编辑分开。先统一峰值的测量口径，再对含长字符串、空白、密集 token、深嵌套的合法输入测量；不能只用打开文件后的空闲内存替代格式化峰值。

### R08：LRU 的“最新条目保护”使硬上限失效

位置：[ImportSummaryCache.swift](../Sources/KaruCore/Imports/ImportSummaryCache.swift)，125–191 行；[ImportService.swift](../Sources/KaruCore/Imports/ImportService.swift)，63–68 行。

`insert` 对大模块降级为名字摘要，但未保证降级结果本身小于总预算。`enforceLimits(keeping:)` 的降级和淘汰都排除 `newest`。于是一个 names-only 条目若单独超过 `byteLimit`，清空其余条目后仍然超限，并正常返回。

这是可直接推出的边界反例：空缓存 + 一个成本大于预算的条目。现有 LRU 测试覆盖多个普通条目的淘汰，不能证明这个边界。本轮没有测得默认 8 MB 配置实际被某个日常项目突破，不能混淆实现缺口与发生频率。

**改进与验收：**最新条目也必须遵守预算；名字摘要进一步截断或拒绝缓存，并对调用方表达不完整性。测试至少断言单条超大、降级后仍超大、极小注入预算时，任何一次插入结束都满足约束。

### R09：读取全部内容后再截断结果，不能限制峰值和工作量

位置：[ImportService.swift](../Sources/KaruCore/Imports/ImportService.swift)，1026–1046、1060–1068 行；[ImportFileSystem.swift](../Sources/KaruCore/Imports/ImportFileSystem.swift)，`contents` / `list`；[ImportCompletion.swift](../Sources/KaruCore/Imports/ImportCompletion.swift)，592–595 行。

导入解析先读取整个文件并解码，之后才按 2 MB 阈值选择 names-only。这个阈值控制摘要形态，不控制输入读取量。目录补全同样先 `contentsOfDirectory` 列出全部名称并全量排序，最后才取前 2,000 项。极大生成文件或包目录仍可在后台消耗大量内存和 CPU。

WorkspaceIndex 有自己的 2 MB 文件上限，这是已有防线；不能把它当作 ImportService 也有同样上限的证据。

**改进与验收：**在文件读取和枚举入口设真实工作上限；大文件分块扫描或明确降级，目录采用有界枚举/选择。结果截断需要可观测。用超过阈值的文件、数万项目录验证峰值与取消响应，而不是只断言最终候选不超过 2,000 个。

## 三、格式与产品契约

### R10：XML 格式化器既拒绝合法构造，也放过明显错误

位置：[XMLFormatter.swift](../Sources/KaruCore/Format/XMLFormatter.swift)，`parseDoctype`、`parseElement`、`scanTagRemainder`。

本轮生产代码探针结果：

| 输入 | 当前结果 |
|---|---|
| `<root><?work item?></root>` | 拒绝：把元素内处理指令当成普通元素解析 |
| `<!DOCTYPE root [<!ELEMENT root EMPTY>]><root/>` | 拒绝：DOCTYPE 扫描在内部声明的第一个 `>` 就结束 |
| `<root a=unquoted/>` | 接受：属性余部只按原始字符串收集，没有检查引号 |

保留词法原文、避免重编码是有价值的选择，但不能因此把宽松的标签扫描器宣传成完整 XML 有效性判断器。

**改进与验收：**明确支持的 XML 子集，或补齐解析规则并保持原文保真；先增加这些正反例，继续覆盖混合内容、CDATA、实体和 `xml:space`。不要仅靠“格式化成功”推断输入合法。

### R16：README 的承诺和运行事实需要重新对齐

位置：[README.zh-Hans.md](../README.zh-Hans.md)，功能、预算、源码构建段；[DocumentController.swift](../Sources/KaruCore/App/DocumentController.swift)，175–177 行；[DEVELOPMENT.md](DEVELOPMENT.md)。

- README 仍介绍“关键字、文档内单词、文档内符号”补全，模块列表只列高亮/补全/排版，未充分描述当前导入、类型推断、跨文件索引与运行能力及边界。用户难以理解新增成本来自哪里。
- README 推荐完整测试运行 `swift test`，开发流程已明确要求限并行宽度的 `scripts/test.sh`。首次贡献者最容易照着过时入口操作。
- “编码自动检测 + 手动重开”没有同等醒目地说明所有保存都转换为 UTF-8。源码明确这么设计，但打开旧编码后保存会改变字节格式；这是一项应告知用户的行为，不应偷偷当作保真编辑。
- README 的 1 MB/10 MB 内存表比内部正式夹具与窗口口径更宽泛。“强制执行”尤其需要 R11 的实际门禁支撑。

**验收：**三语 README 与当前设置、保存语义、测试入口逐项比对；将适用口径说清楚。报告只指出差异，本轮不替用户改写产品承诺。

## 四、测试和发布：脚本的成功不一定代表验收成功

### R11：内存基准存在可静态确认的成功误判路径

位置：[mem-benchmark.sh](../scripts/mem-benchmark.sh)，121–149、195–225、270–327、344–396 行。

1. `footprint` 不可用时回退到 RSS，函数只返回数字，不携带测量类型；后续仍打印 `phys_footprint` 并用相同阈值判定。两个口径不能悄悄混用。
2. 正式三轮默认不隔离会话，而各轮通过 `kill` 结束。脚本自己承认下一轮会恢复上一轮文档，却只给后面的参考轮补隔离。正确性取决于调用者记住外部环境变量。
3. 正式场景为 `SKIPPED` 时不设置失败；未稳定读数仍可按数值判 PASS。结束语虽然写“全部已执行轮次”，退出码仍不足以作为发布门禁。
4. 是否支持打开文件靠搜索源码关键词判断；既不证明本次二进制确实加载了指定文件，也不能证明 `KARU_BENCH_APP_BIN` 指向的外部构建与当前源码一致。

开发文档已经提醒这些限制，说明团队知道问题；但提醒没有被固化进执行入口，仍是缺陷。本轮未运行有状态的内存脚本，也没有宣称当前应用超出正式常驻预算。

**改进与验收：**默认每轮独立诊断存储；记录进程路径、构建、实际打开文件、窗口尺寸、分配器模式和测量类型。正式门禁对缺场景、RSS 回退、未稳定、文件打开失败返回“不具备通过证据”。用假采样器测试这些失败分支，不必每次启动真实 App 才检查脚本判定逻辑。

### R12：视觉冒烟对状态隔离和断言强度的要求过低

位置：[visual-smoke.sh](../scripts/visual-smoke.sh)，14、48–49 行；[AppDelegate.swift](../Sources/KaruCore/App/AppDelegate.swift)，51–64 行及快照入口。

脚本启动裸二进制时没有默认设置 `KARU_DIAGNOSTIC_DIRECTORY`。因裸二进制和安装包的偏好域不同，不能直接宣称会清空正式版用户资料；但开发态会话、草稿、索引及恢复窗口可能参与验证，结果可被旧状态影响。

第一项断言只统计整图亮/暗像素比例，不能确认编辑正文、光标、候选窗或工具栏正确。折叠几何检查则针对一个固定 JSON 示例。它们对各自历史回归有用，却不能承担广泛的 UI 验收结论。

**改进与验收：**脚本内建独立存储，验证实际测试窗口身份；把整图统计补成编辑区关键几何和可见内容检查。滚动合成、输入法、全屏 Space、VoiceOver 必须有各自的真实交互记录，不扩大冒烟通过的含义。

### R13：发布链缺少与源码版本绑定的可执行质量门禁

位置：[release-macos.sh](../scripts/release-macos.sh)；[bundle-macos.sh](../scripts/bundle-macos.sh)；[RELEASE.md](RELEASE.md)。

发布脚本完成构建、签名、公证和产物生成，但不运行或核对测试、视觉、内存验收凭据，也不把验收证据绑定到源码树。人工发布流程写得较完整；问题在于脚本单独成功仍可能产出未经本轮质量验证的包。这里不能据此断言既往发布跳过了检查。

`build/sparkle-tools/bin/sign_update` 只按“文件存在且可执行”决定是否复用；已有缓存不核对它对应的 Sparkle 版本。下载分支以 `curl -sL | tar` 取得并解包工具，没有固定摘要核对。HTTPS 和 SPM 对框架依赖的锁定不能替代对这份独立下载的发布工具的校验。没有证据表明工具已遭篡改，也不把此项夸大为已发生的供应链入侵。

**改进与验收：**建立签名前的 preflight，绑定 commit、工作树摘要、工具链、验收结果与产物摘要；按版本管理发布工具并验证来源和完整性。确认旧工具缓存、缺验收报告或验收后源码变化会阻止正式产物宣称通过。凭据继续只经既有钥匙串引用。

### R15：测试资产丰富，但缺少持续、跨环境的可靠性闭环

证据：[Package.swift](../Package.swift)、[test.sh](../scripts/test.sh)、[M17-QUALITY-REPORT.md](M17-QUALITY-REPORT.md) 第 10、11 节及最新台账。

- 仓库没有纳入版本控制的 `.github`、GitLab CI 或 CircleCI 配置。不能排除存在仓库外自动化，但从仓库本身无法复现一个持续执行的质量门禁。
- 测试宽度依赖 `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`。脚本注释也承认它可能随工具链变化失效；需要验证“限宽确实生效”，而不是只设置变量。
- 部署声明支持 macOS 13，近期实测主要来自当前开发系统；台账仍明确保留 macOS 13–15 外观、部分旁白和真实交互待验项。支持范围大于可见的验证范围。
- 边界测试应补到失败机制上：本轮 R01、R02、R03、R06、R08、R10 均不能由普通成功路径的数量来覆盖。
- 历史报告记录 5 MB 单行 JSON 关窗后 malloc 在用量仍增加约 150 MB，台账也标“待查”。本轮未复现、未归因为泄漏；后续应首先检查真实对象存活和测试夹具持有情况，不能用“分配器保留页”直接结案。

**验收：**建立不含签名密钥的 macOS 构建/测试自动化；隔离默认偏好和存储；明确支持系统矩阵及人工验收日期。故障注入、属性测试或受限模糊测试优先覆盖保存状态机、UTF-16 编辑边界、解析深度与取消路径。并行限宽只是运行条件，不是产品质量证明。

## 五、架构与维护成本

### R14：“少依赖”和“单一 target”不代表低复杂度

位置：[Package.swift](../Package.swift)、[EditorWindowController.swift](../Sources/KaruCore/Editor/EditorWindowController.swift)、[AppDelegate.swift](../Sources/KaruCore/App/AppDelegate.swift)、[AnalysisScheduler.swift](../Sources/KaruCore/Analysis/AnalysisScheduler.swift)。

所有逻辑都在 KaruCore。`EditorWindowController` 有 1,887 行，承担视图组合、语言识别、分析接线、保存、恢复、提示、命令和运行宿主；`AppDelegate` 有 1,181 行，混合应用生命周期与大量诊断入口。更大的解析与声明扫描文件达到 2,000–3,000 行。行数本身不是罪名，但这些职责确实在跨领域共享状态和时序。

模块开关、关闭窗口、恢复、格式化和语言切换都需要正确取消任务、释放状态并更新多个消费者。当前大量约束存在于注释和调用顺序中。TextKit 的历史崩溃说明时序错误并非理论风险；现有 `viewWillDraw` 预布局和延迟装饰修复必须保留，但不能指望每个后续功能都靠作者记忆避坑。

同时，`AnalysisScheduler` 的约 4 ms 切片是协作式期限：它无法抢占一个不及时返回的 `step`，完成回调也在同一主线程。不能把“使用了调度器”当作每条工作路径已满足时延上限。

**改进方向：**先在现有 target 内提取持久化协调、恢复决策与诊断宿主等明确职责，用版本化状态和取消契约减少跨模块隐式约定；无需为了拆文件增加运行时。关键边界建立定向测试后再逐步拆分，不建议一次性重写解析器或迁移文本引擎。

### 已有基础应保留，但不能作为豁免理由

纯文本事实源、共享 LineIndex、可见区域高亮、按版本发布分析结果、SQLite 事务、后台索引、导入不执行项目代码、运行使用 argv 而非拼接 shell、进程组停止、工具链下载后摘要核对、草稿本写失败保留窗口，都体现了明确的工程纪律。

本轮没有发现足够证据把 TextKit 1、自研解析器、非沙箱编辑器或唯一外部依赖 Sparkle 本身列为缺陷。工具链安装的解包边界、取消后资源回收、运行子进程脱离进程组等场景仍可扩充对抗测试；没有实测前不宣称任意路径写入或进程残留漏洞成立。

## 六、建议处理顺序与完成条件

1. **先保住内容：R01、R02，其次 R05–R07。**完成条件是外部冲突与持久化失败不再删除唯一版本，并有可重放的故障注入证据；R07 先形成供用户评估的明确方案。
2. **让输入成本可控：R03、R04、R08、R09、R10。**完成条件是病态输入可取消、缓存插入满足不变量、格式化满足明确峰值预算，正确性边界有正反例。
3. **让“通过”可相信：R11–R13、R15。**完成条件是默认隔离、失败可传播、证据绑定源码和产物，正式场景缺失不能获得正式 PASS。
4. **再降低维护成本并对齐承诺：R14、R16。**围绕上述真实缺陷拆职责，不做脱离收益的代码美化；三语说明与当前能力保持一致。

这不是第二份执行台账。后续修复状态仍统一记入 [LEDGER.md](LEDGER.md)，在条目中引用本报告编号；不要把“报告写完”标成“问题修好”。

## 七、本轮验证记录与可重现输入

环境：macOS 27.2.1（26B131），arm64，Apple Swift 6.4.2。全部探针在临时目录中运行；源码直接参与 `swiftc -O` 编译，没有复用已安装 App 或旧测试二进制。

| 验证 | 本轮结果 | 限制 |
|---|---|---|
| 生产代码存储/搜索/XML 探针编译与运行 | 成功；R01、R02、R06、R10 如上复现 | 存储及纯逻辑级；非 GUI 交互 |
| 病态正则子进程 | 3 秒未返回，外层终止 | 证明超过该时间，未测最终完成时间 |
| Character 存储跨度 | 16 字节 | 分配下界，非应用峰值采样 |
| 1 MiB 合法 JSON 格式化 | 返回 `[]` | 峰值采集因 `sysctl` 权限受限失败 |
| 4 个既有 Swift Testing 用例过滤运行 | 未能进入测试执行 | 见下方环境错误，不算测试失败或通过 |
| 全量测试、视觉冒烟、真实 App 内存与交互 | 未执行 | 本轮不提供发布验收结论 |

尝试的过滤条件：`savingClearsDirty|saveThenLoadRoundTripsUnicode|plainTextCaseInsensitiveMatchesAllCasings|regexDigitRunsAreMatched`。首次运行因默认模块缓存不可写退出；改用临时缓存后，SPM 嵌套 `sandbox-exec` 被环境拒绝；关闭 SPM 自身嵌套沙箱、保留当前会话权限边界后，构建服务仍无法写入 `.build/out/.../XCBuildData/.../manifest.json`（Code 513 / Operation not permitted）。三次均退出 1，没有执行上述测试。没有清理共享构建缓存，也没有把环境错误列为产品缺陷。

下面的最小探针可从仓库根目录复现核心观察。将 Swift 代码保存为临时 `Probe.swift`，用随后的命令编译；不要把测试路径换成用户文件。

```swift
import Foundation
@main struct Probe {
    static func main() throws {
        if CommandLine.arguments.contains("regex") {
            _ = SearchEngine.matches(in: String(repeating: "a", count: 32) + "!",
                pattern: "^(a+)+$", options: .init(regex: true))
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("base".utf8).write(to: file)
        let doc = DocumentController()
        try doc.load(from: file)
        doc.markEdited()
        try Data("external-change".utf8).write(to: file)
        try doc.save(text: "local-change")
        print(try String(contentsOf: file, encoding: .utf8), doc.isDirty)
        let pad = ScratchpadStore(directory: root.appendingPathComponent("pad"))
        try FileManager.default.createDirectory(at: pad.directory, withIntermediateDirectories: true)
        let padFile = pad.directory.appendingPathComponent("content.txt")
        try Data([0xff, 0xfe, 0x41]).write(to: padFile)
        try pad.write(pad.read()).get()
        print("pad bytes:", try Data(contentsOf: padFile).count)
        let drafts = DraftStore(directory: root.appendingPathComponent("drafts"))
        let id = UUID()
        drafts.write(id: id, content: "old-content", originalPath: "/old-path")
        try Data("new-content".utf8).write(
            to: drafts.directory.appendingPathComponent(id.uuidString), options: .atomic)
        print(drafts.drafts())
        print("Character stride:", MemoryLayout<Character>.stride)
        for xml in ["<root><?work item?></root>",
                    "<!DOCTYPE root [<!ELEMENT root EMPTY>]><root/>",
                    "<root a=unquoted/>"] {
            do { print("accepted:", try XMLFormatter.prettyPrint(xml)) }
            catch { print("rejected:", error) }
        }
    }
}
```

```sh
# AUDIT_DIR 为存有上述 Probe.swift 的独立临时目录。
swiftc -O -module-cache-path "$AUDIT_DIR/module-cache" \
  Sources/KaruCore/App/DocumentController.swift \
  Sources/KaruCore/App/TextEncoding.swift \
  Sources/KaruCore/App/DraftStore.swift \
  Sources/KaruCore/Scratchpad/ScratchpadStore.swift \
  Sources/KaruCore/Settings/EditorFontSettings.swift \
  Sources/KaruCore/Search/SearchEngine.swift \
  Sources/KaruCore/Format/XMLFormatter.swift \
  "$AUDIT_DIR/Probe.swift" -o "$AUDIT_DIR/probe"
"$AUDIT_DIR/probe"
python3 - "$AUDIT_DIR/probe" <<'PY'
import subprocess, sys
try:
    subprocess.run([sys.argv[1], 'regex'], timeout=3, check=True)
except subprocess.TimeoutExpired:
    print('regex exceeded 3 seconds; isolated child terminated')
PY
```

预期观察：外部文本被替换且 dirty 为 false；草稿本文件成为 0 字节；恢复条目含新正文和旧路径；XML 前两例被拒绝、后一例被接受。正则超时是本轮环境的结果，其他机器应记录自身耗时；不要直接在主应用中执行这个输入来验证卡死。
