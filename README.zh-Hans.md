# Karu（軽）

[English](README.md) | **简体中文** | [日本語](README.ja.md)

一款刻意做得极小的原生 macOS 纯文本编辑器。**约 30 MB 常驻内存，
冷启动不到一秒。**

Karu（軽，日语中意为"轻"）建立在一个信念之上：文本编辑器理应几乎不消耗任何资源。
每一项功能都要通过严格的内存预算审查，装不下的功能就会被拒绝——就像 kei car
（日本轻型车）之所以保持轻巧，是因为规则要求它们必须如此。

## 功能

- 支持 20 种语言的语法高亮（Markdown、JSON/JSONL、YAML、TOML、Python、HTML、CSS、
  JavaScript/TypeScript、C、C++、C#、Java、Go、Rust、Swift、Bash、SQL、XML/plist）
  ——仅渲染可见区域，采用 VS Code Modern 风格配色，支持浅色与深色主题
- 代码折叠、行号、VS Code 风格的缩进彩虹
- 一键折叠/展开（⌥⌘[ / ⌥⌘]）、全部折叠/展开（⌘K ⌘0 / ⌘K ⌘J），折叠状态在编辑后
  依然保留
- 正则表达式查找与替换
- 光标所在单词高亮、不可见字符与双向控制字符警示、CSS 颜色值内嵌色块预览
- 补全：关键字、文档内单词、文档内符号
- 符号跳转（⌘⇧O），JSON/JSONL/XML/plist 一键排版（⌥⇧F）
- 注释切换（⌘/）、行移动/复制/删除（⌥↑↓ / ⇧⌥↑↓ / ⌘⇧K）、括号与引号自动闭合
  及选中内容包裹、括号配对高亮与跳转（⌘⇧\）
- 命令面板（⌘⇧P）
- 仅粘贴纯文本（粘贴时自动剥离富文本格式）
- 编码自动检测 + 手动重新打开并指定回退编码
- 换行符（LF/CRLF/CR）显示与转换
- 缩进宽度自动检测，支持按语言配置
- 界面支持英文 / 简体中文 / 日本語，可实时切换
- 功能模块（高亮 / 补全 / 排版）可单独关闭，彻底释放其运行时状态
- 失焦自动保存（可选，默认关闭）、选中字符数统计、字体缩放（⌘+ / ⌘- / ⌘0）
- `karu` 命令行工具：从终端直接打开文件
- 应用内一键更新（Sparkle，v0.7.0 起）

- 草稿本有序列表中间回车时，后续连续同级编号自动重排，支持一次撤销。
- Python f-string 中的变量、表达式和格式字段独立高亮。
- 设置 → 全部快捷键：搜索、录制、清除、恢复默认及应用内冲突提示，包含草稿本全局热键。

设置还提供“默认打开方式”和 JSON 配置导出/导入。默认应用按系统文件类型设置，同类型扩展名会一起变更，可能需要 macOS 确认；系统识别为非文本的歧义格式不列出。备份包含 Karu 偏好和快捷键，不含文档、草稿内容、会话及系统文件关联；导入会替换这些偏好，未保存的选项恢复默认。

XML/plist 格式化保留文本值、混合内容与 `xml:space="preserve"`。从 Finder 或命令行打开文件时，也会恢复崩溃草稿。草稿本保存失败时保留窗口并阻止退出，可重试或另存内容。

## 预算（强制执行，而非愿景）

| 指标 | 上限 |
|---|---|
| 空文档，空闲状态 | 35 MB |
| 打开 1 MB 文件 | 50 MB |
| 打开 10 MB 文件 | 65 MB |
| 应用体积 | 10 MB |
| 冷启动 | < 1 秒 |

每次发布都会通过 `scripts/mem-benchmark.sh` 进行测量。以下内容被刻意永久排除在外：
LSP/语言服务器、tree-sitter、Electron/web view、重型格式化工具、插件系统。

## 安装

从 [Releases](https://github.com/enkin-japan/karu/releases) 下载已公证的 DMG，
拖入 Applications 文件夹。

命令行工具（可选）：

```sh
ln -s /Applications/Karu.app/Contents/Resources/karu /usr/local/bin/karu
```

## 从源码构建

仅需 Swift（命令行工具即可，无需 Xcode），macOS 13+。

```sh
swift build            # 调试构建
swift test             # 运行全部测试
bash scripts/bundle-macos.sh   # → build/Karu.app（SIGN_IDENTITY=- 用于 ad-hoc 签名）
```

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 预算表以及保持 Karu 精简的设计
  原则（中文）
- [docs/LEDGER.md](docs/LEDGER.md) —— 完整的工程记录（中文）

## 许可证

[MIT](LICENSE) © 2026 enkin
