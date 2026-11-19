# Karu（軽）

[English](README.md) | **简体中文** | [日本語](README.ja.md)

一款刻意做得极小的原生 macOS 纯文本编辑器。**约 30 MB 常驻内存，
冷启动不到一秒。**

Karu（軽，日语中意为"轻"）建立在一个信念之上：文本编辑器理应几乎不消耗任何资源。
每一项功能都要通过严格的内存预算审查，装不下的功能就会被拒绝——就像 kei car
（日本轻型车）之所以保持轻巧，是因为规则要求它们必须如此。

## 功能

- 支持 21 种语言的语法高亮：Markdown、JSON、JSONL、YAML、TOML、Python、HTML、
  CSS、JavaScript、TypeScript、TSX、C、C++、C#、Java、Go、Rust、Swift、Bash、
  SQL、XML（plist 文件按 XML 处理）。仅对可见部分着色。配色参照 VS Code 的
  Dark Modern 与 Light Modern 主题。嵌入代码按各自的语言高亮：HTML 中的
  `<script>` 和 `<style>`、Markdown 的围栏代码块、JSX 与 TSX
- 代码折叠、行号、VS Code 风格的缩进彩虹
- 一键折叠/展开（⌥⌘[ / ⌥⌘]）、全部折叠/展开（⌘K ⌘0 / ⌘K ⌘J），折叠状态在编辑后
  依然保留
- 正则表达式查找与替换
- 光标所在单词高亮、不可见字符与双向控制字符警示、CSS 颜色值内嵌色块预览
- 根据作用域提供补全候选，标明每项的类别，并将最可能的候选排在前面。输入点号后，
  列出点号前的值的成员：Python 与 JavaScript/TypeScript 使用推断出的类型，
  C、C++、Swift、Go、Rust、Java 与 C# 使用声明的类型。也支持导入语句补全，包括
  Python 虚拟环境或 `node_modules` 中的模块
- 以上全部在 Karu 自身进程内完成：没有语言服务器，没有辅助进程，Karu 也不会
  为了了解项目而执行项目代码
- 项目文件夹：在「设置 › 代码 › 项目文件夹…」中添加文件夹，Karu 会在后台为其建立
  索引。此后，补全会用到其他文件中的符号，通过「编辑 › 工作区符号…」（⌘T）可跳转到
  其中任意符号
- 运行（⌘R，⌘. 停止）：将当前文本（无论是否已保存）作为单文件程序运行，支持
  Python、JavaScript、TypeScript、Bash、C、C++、Swift、Go、Rust、Java、C#。
  运行输出显示在编辑器下方的面板中，程序可以读取你在面板中输入的内容。每种
  语言的工具链可由 Karu 通过「设置 › 运行」安装（Python、Node.js、Go、
  Temurin JDK、.NET SDK，C/C++ 用 Zig；版本固定，下载后核对校验和，存放在
  Karu 自己的 Application Support 文件夹中），也可使用系统 PATH 中找到的工具链，
  或指定自定义路径。Karu 不会修改 PATH 或 shell 配置。Swift 与 Rust 使用系统上
  已安装的工具链
- 符号跳转（⌘⇧O），JSON/JSONL/XML/plist 一键排版（⌥⇧F）
- 注释切换（⌘/）、行移动/复制/删除（⌥↑↓ / ⇧⌥↑↓ / ⌘⇧K）、括号与引号自动闭合
  及选中内容包裹、括号配对高亮与跳转（⌘⇧\）
- 命令面板（⌘⇧P）
- 仅粘贴纯文本（粘贴时自动剥离富文本格式）
- 自动检测编码 + 手动指定回退编码并重新打开；无论以何种编码打开，保存时一律
  存为 UTF-8
- 换行符（LF/CRLF/CR）显示与转换
- 缩进宽度自动检测，支持按语言配置
- 界面支持英文 / 简体中文 / 日本語，可实时切换
- 功能模块（高亮、补全、排版、运行、类型推断、跨文件索引）均可单独关闭，
  关闭后会释放相应的运行时状态
- 失焦自动保存（可选，默认关闭）、选中字符数统计、字体缩放（⌘+ / ⌘- / ⌘0）
- `karu` 命令行工具：从终端直接打开文件
- 应用内一键更新（Sparkle，v0.7.0 起）

- 草稿本有序列表中间回车时，后续连续同级编号自动重排，支持一次撤销。
- Python f-string 中的变量、表达式和格式字段独立高亮。
- 设置 → 全部快捷键：搜索、录制、清除、恢复默认及应用内冲突提示，包含草稿本全局热键。

设置还提供“默认打开方式”和 JSON 配置导出/导入。默认应用按系统文件类型设置，同类型扩展名会一起变更，可能需要 macOS 确认；系统识别为非文本的歧义格式不列出。备份包含 Karu 偏好和快捷键，不含文档、草稿内容、会话及系统文件关联；导入会替换这些偏好，未保存的选项恢复默认。

XML/plist 格式化会保留文本值、混合内容与 `xml:space="preserve"`。「格式化文档」会拒绝处理嵌套超过 512 层或格式化结果会远大于原文的 JSON 或 XML 文档，并保持文档不变。从 Finder 或命令行打开文件时，也会恢复崩溃草稿。草稿本保存失败时，会保留窗口并阻止退出，可重试或另存内容。

在 Karu 打开文件后，如果该文件被其他程序修改过，保存时会先询问（存储为…、覆盖、取消），而不是静默覆盖。通过符号链接打开的文件会保存到链接目标，链接本身保持不变。如果恢复的草稿和磁盘上的文件都已发生变化，Karu 会保留两者：草稿会作为单独的副本打开。

## 预算（强制执行，而非愿景）

| 指标 | 上限 |
|---|---|
| 空文档，空闲状态 | 99 MB |
| 打开 1 MB 文件 | 99 MB |
| 打开 10 MB 文件 | 99 MB |
| 冷启动 | < 1 秒 |

三行内存指标是在默认 800×600 窗口下测得的 `phys_footprint` 读数，由
`scripts/mem-benchmark.sh` 测得（空文档、1 MB 的 JSON 文件、10 MB 的 Python
文件）。每次发布前，`scripts/preflight.sh` 会将该脚本与测试一起运行；如果某次运行
无法证明实际测量了什么，就不算通过。这三种场景之外的压力输入，例如单行的
5 MB 文件，可能超过上限。

以下内容被刻意永久排除在外：LSP/语言服务器、Electron/web view、重型格式化工具、
插件系统。

## 安装

从 [Releases](https://github.com/enkin-japan/karu/releases) 下载已公证的 DMG，
拖入 Applications 文件夹。

命令行工具（可选）：

```sh
ln -s /Applications/Karu.app/Contents/Resources/karu /usr/local/bin/karu
```

## 从源码构建

仅需 Swift（命令行工具即可，无需 Xcode）。部署目标为 macOS 13。近期版本仅在
运行 macOS 27 的 Apple 芯片设备上构建和测试；较旧的 macOS 版本不会在每次发布时重新测试。
发布的 DMG 为 Apple 芯片（arm64）构建版本。

```sh
swift build                    # 调试构建
bash scripts/test.sh           # 运行全部测试
bash scripts/bundle-macos.sh   # → build/Karu.app（SIGN_IDENTITY=- 用于 ad-hoc 签名）
```

`scripts/test.sh` 会限制 `swift test` 的并行度，因为不限制并行度会导致对时序
敏感的测试失败；若只需运行部分测试，可使用 `swift test --filter <name>`。

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 预算表以及保持 Karu 精简的设计
  原则（中文）
- [docs/LEDGER.md](docs/LEDGER.md) —— 完整的工程记录（中文）
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) —— 构建、测试与测量说明（中文）

## 许可证

[MIT](LICENSE) © 2026 enkin
