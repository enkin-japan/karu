# Karu（軽）

[English](README.md) | **简体中文** | [日本語](README.ja.md)

一款刻意做得极小的原生 macOS 纯文本编辑器。**1.4 MB 应用体积，约 30 MB
常驻内存，零依赖。**

Karu（軽，日语中意为"轻"）建立在一个信念之上：文本编辑器理应几乎不消耗任何资源。
每一项功能都要通过严格的内存预算审查，装不下的功能就会被拒绝——就像 kei car
（日本轻型车）之所以保持轻巧，是因为规则要求它们必须如此。

## 功能

- 支持 15 种语言的语法高亮（Markdown、JSON/JSONL、Python、HTML、CSS、
  JavaScript/TypeScript、C、C++、C#、Java、Bash、SQL、XML/plist）——仅渲染可见区域，
  采用 VS Code Modern 风格配色，支持浅色与深色主题
- 代码折叠、行号、VS Code 风格的缩进彩虹
- 正则表达式查找与替换
- 补全：关键字、文档内单词、文档内符号
- 符号跳转（⌘⇧O），JSON/JSONL/XML/plist 一键排版（⌥⇧F）
- 仅粘贴纯文本（粘贴时自动剥离富文本格式）
- 编码自动检测 + 手动重新打开并指定回退编码
- 换行符（LF/CRLF/CR）显示与转换
- 缩进宽度自动检测，支持按语言配置
- 界面支持英文 / 简体中文 / 日本語，可实时切换
- 功能模块（高亮 / 补全 / 排版）可单独关闭，彻底释放其运行时状态
- `karu` 命令行工具：从终端直接打开文件

## 预算（强制执行，而非愿景）

| 指标 | 上限 |
|---|---|
| 空文档，空闲状态 | 35 MB |
| 打开 1 MB 文件 | 50 MB |
| 打开 10 MB 文件 | 65 MB |
| 应用体积 | 5 MB（实际：1.4 MB） |
| 冷启动 | < 1 秒 |

每次发布都会通过 `scripts/mem-benchmark.sh` 进行测量。以下内容被刻意永久排除在外：
LSP/语言服务器、tree-sitter、Electron/web view、重型格式化工具、插件系统。

## 安装

**Homebrew**（自动安装 `karu` 命令行工具）：

```sh
brew tap enkin-japan/tap
brew trust enkin-japan/tap   # 新版 Homebrew 要求信任第三方 tap
brew install --cask karu
```

**手动安装**：从 [Releases](https://github.com/enkin-japan/karu/releases)
下载已公证的 DMG，拖入 Applications 文件夹。命令行工具（可选）：

```sh
ln -s /Applications/Karu.app/Contents/Resources/karu /usr/local/bin/karu
```

## 从源码构建

仅需 Swift（命令行工具即可，无需 Xcode），macOS 13+。

```sh
swift build            # 调试构建
swift test             # 340+ 测试
bash scripts/bundle-macos.sh   # → build/Karu.app（SIGN_IDENTITY=- 用于 ad-hoc 签名）
```

## 文档

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 预算表以及保持 Karu 精简的设计
  原则（中文）
- [docs/LEDGER.md](docs/LEDGER.md) —— 完整的工程记录（中文）

## 许可证

[MIT](LICENSE) © 2026 enkin
