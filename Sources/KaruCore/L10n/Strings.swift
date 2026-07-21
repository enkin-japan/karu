import Foundation

// The three translation tables. Every `L10nKey` case must appear in each table;
// `L10nTests` asserts this over `L10nKey.allCases` to prevent silent gaps.
//
// Wording follows the platform's own conventions: macOS Simplified-Chinese
// (查找 / 替换 / 设置 / 格式化文档 / 行 / 列) and Japanese (検索 / 置換 / 設定 /
// ドキュメントをフォーマット / 行・桁). Language names and the "pt" font unit are
// left untranslated as proper nouns / universal units.

extension L10n {

    static let enTable: [L10nKey: String] = [
        .appAbout: "About %@",
        .appSettings: "Settings…",
        .appHide: "Hide %@",
        .appQuit: "Quit %@",

        .menuFile: "File",
        .menuNew: "New",
        .menuOpen: "Open…",
        .menuClose: "Close",
        .menuSave: "Save",
        .menuSaveAs: "Save As…",

        .menuReopenWithEncoding: "Reopen with Encoding",
        .reopenConfirmMessage: "Reopen “%@” with a different encoding?",
        .reopenConfirmInfo: "Your unsaved changes will be lost.",
        .reopenDiscardButton: "Reopen",
        .encodingDecodeFailedTitle: "Cannot decode file",
        .encodingDecodeFailedMessage: "This file cannot be decoded using the selected encoding.",

        .menuEdit: "Edit",
        .menuUndo: "Undo",
        .menuRedo: "Redo",
        .menuCut: "Cut",
        .menuCopy: "Copy",
        .menuPaste: "Paste",
        .menuSelectAll: "Select All",

        .menuFind: "Find",
        .menuFindEllipsis: "Find…",
        .menuFindNext: "Find Next",
        .menuFindPrevious: "Find Previous",
        .menuUseSelectionForFind: "Use Selection for Find",

        .menuJumpToSymbol: "Jump to Symbol…",
        .symbolFilterPlaceholder: "Filter symbols",
        .symbolNone: "No symbols",

        .menuFormat: "Format",
        .menuFormatDocument: "Format Document",
        .menuConvertLineEndings: "Convert Line Endings",

        .menuLanguage: "Language",
        .languageAuto: "Auto",

        .toolbarIndentLabel: "Indent",
        .toolbarIndentTooltip: "Indent width",
        .toolbarFeatureModulesTooltip: "Feature modules",
        .toolbarSettingsLabel: "Settings",
        .formatAction: "Format",

        .findPlaceholder: "Find (regex)",
        .replacePlaceholder: "Replace",
        .findRegexTooltip: "Regular expression",
        .findCaseTooltip: "Match case",
        .findPrevTooltip: "Previous match",
        .findNextTooltip: "Next match",
        .findReplaceTooltip: "Replace current match",
        .findReplaceAll: "All",
        .findReplaceAllTooltip: "Replace all matches",
        .findDone: "Done",
        .findDoneTooltip: "Close find bar",
        .findNoResults: "No results",
        .findReplacedCount: "Replaced %d",
        .findFoundCount: "%d found",
        .findMatchPosition: "%d/%d · L%d",

        .formatFailedTitle: "Formatting failed",
        .formatErrorLine: "Line %d: %@",
        .closeConfirmMessage: "Do you want to save the changes made to %@?",
        .closeConfirmInfo: "Your changes will be lost if you don't save them.",
        .dontSave: "Don't Save",
        .cancel: "Cancel",
        .untitled: "Untitled",

        .downloadingTitle: "%@ (Downloading…)",
        .downloadTimeoutTitle: "Download timed out",
        .downloadTimeoutMessage: "“%@” could not be downloaded from iCloud. Please try again.",

        .prefTitle: "Settings",
        .prefModules: "Modules",
        .prefEditor: "Editor",
        .prefIndentWidthLabel: "Indent width:",
        .prefInsertSpaces: "Insert spaces for Tab",
        .prefIndentRainbow: "Indent rainbow",
        .prefFontSizeLabel: "Font size:",
        .prefLanguageLabel: "Language:",
        .prefLanguageSystem: "System",

        .moduleHighlight: "Syntax Highlighting",
        .moduleCompletion: "Completion",
        .moduleFormat: "Formatting",

        .statusLnCol: "Ln %d, Col %d",
        .statusCharOne: "%d char",
        .statusCharMany: "%d chars",
    ]

    static let zhHansTable: [L10nKey: String] = [
        .appAbout: "关于 %@",
        .appSettings: "设置…",
        .appHide: "隐藏 %@",
        .appQuit: "退出 %@",

        .menuFile: "文件",
        .menuNew: "新建",
        .menuOpen: "打开…",
        .menuClose: "关闭",
        .menuSave: "存储",
        .menuSaveAs: "存储为…",

        .menuReopenWithEncoding: "以编码重新打开",
        .reopenConfirmMessage: "以其他编码重新打开“%@”？",
        .reopenConfirmInfo: "你未存储的更改将会丢失。",
        .reopenDiscardButton: "重新打开",
        .encodingDecodeFailedTitle: "无法解码文件",
        .encodingDecodeFailedMessage: "该编码无法解码此文件。",

        .menuEdit: "编辑",
        .menuUndo: "撤销",
        .menuRedo: "重做",
        .menuCut: "剪切",
        .menuCopy: "拷贝",
        .menuPaste: "粘贴",
        .menuSelectAll: "全选",

        .menuFind: "查找",
        .menuFindEllipsis: "查找…",
        .menuFindNext: "查找下一个",
        .menuFindPrevious: "查找上一个",
        .menuUseSelectionForFind: "用所选内容查找",

        .menuJumpToSymbol: "跳转到符号…",
        .symbolFilterPlaceholder: "过滤符号",
        .symbolNone: "无符号",

        .menuFormat: "格式",
        .menuFormatDocument: "格式化文档",
        .menuConvertLineEndings: "转换换行符",

        .menuLanguage: "语言",
        .languageAuto: "自动",

        .toolbarIndentLabel: "缩进",
        .toolbarIndentTooltip: "缩进宽度",
        .toolbarFeatureModulesTooltip: "功能模块",
        .toolbarSettingsLabel: "设置",
        .formatAction: "格式化",

        .findPlaceholder: "查找（正则）",
        .replacePlaceholder: "替换",
        .findRegexTooltip: "正则表达式",
        .findCaseTooltip: "区分大小写",
        .findPrevTooltip: "上一个匹配",
        .findNextTooltip: "下一个匹配",
        .findReplaceTooltip: "替换当前匹配",
        .findReplaceAll: "全部",
        .findReplaceAllTooltip: "替换所有匹配",
        .findDone: "完成",
        .findDoneTooltip: "关闭查找栏",
        .findNoResults: "无结果",
        .findReplacedCount: "已替换 %d 处",
        .findFoundCount: "找到 %d 处",
        .findMatchPosition: "%d/%d · 第 %d 行",

        .formatFailedTitle: "格式化失败",
        .formatErrorLine: "第 %d 行：%@",
        .closeConfirmMessage: "是否存储对“%@”所做的更改？",
        .closeConfirmInfo: "如果不存储，你的更改将会丢失。",
        .dontSave: "不存储",
        .cancel: "取消",
        .untitled: "未命名",

        .downloadingTitle: "%@（下载中…）",
        .downloadTimeoutTitle: "下载超时",
        .downloadTimeoutMessage: "无法从 iCloud 下载“%@”。请重试。",

        .prefTitle: "设置",
        .prefModules: "模块",
        .prefEditor: "编辑器",
        .prefIndentWidthLabel: "缩进宽度：",
        .prefInsertSpaces: "用空格代替 Tab",
        .prefIndentRainbow: "缩进彩虹",
        .prefFontSizeLabel: "字体大小：",
        .prefLanguageLabel: "语言：",
        .prefLanguageSystem: "跟随系统",

        .moduleHighlight: "语法高亮",
        .moduleCompletion: "代码补全",
        .moduleFormat: "格式化",

        .statusLnCol: "行 %d，列 %d",
        .statusCharOne: "%d 个字符",
        .statusCharMany: "%d 个字符",
    ]

    static let jaTable: [L10nKey: String] = [
        .appAbout: "%@ について",
        .appSettings: "設定…",
        .appHide: "%@ を隠す",
        .appQuit: "%@ を終了",

        .menuFile: "ファイル",
        .menuNew: "新規",
        .menuOpen: "開く…",
        .menuClose: "閉じる",
        .menuSave: "保存",
        .menuSaveAs: "別名で保存…",

        .menuReopenWithEncoding: "エンコーディングを指定して再オープン",
        .reopenConfirmMessage: "“%@” を別のエンコーディングで再オープンしますか？",
        .reopenConfirmInfo: "保存していない変更は失われます。",
        .reopenDiscardButton: "再オープン",
        .encodingDecodeFailedTitle: "ファイルをデコードできません",
        .encodingDecodeFailedMessage: "選択したエンコーディングではこのファイルをデコードできません。",

        .menuEdit: "編集",
        .menuUndo: "取り消す",
        .menuRedo: "やり直す",
        .menuCut: "カット",
        .menuCopy: "コピー",
        .menuPaste: "ペースト",
        .menuSelectAll: "すべてを選択",

        .menuFind: "検索",
        .menuFindEllipsis: "検索…",
        .menuFindNext: "次を検索",
        .menuFindPrevious: "前を検索",
        .menuUseSelectionForFind: "選択部分を検索に使用",

        .menuJumpToSymbol: "シンボルへジャンプ…",
        .symbolFilterPlaceholder: "シンボルを絞り込む",
        .symbolNone: "シンボルなし",

        .menuFormat: "フォーマット",
        .menuFormatDocument: "ドキュメントをフォーマット",
        .menuConvertLineEndings: "改行コードを変換",

        .menuLanguage: "言語",
        .languageAuto: "自動",

        .toolbarIndentLabel: "インデント",
        .toolbarIndentTooltip: "インデント幅",
        .toolbarFeatureModulesTooltip: "機能モジュール",
        .toolbarSettingsLabel: "設定",
        .formatAction: "フォーマット",

        .findPlaceholder: "検索（正規表現）",
        .replacePlaceholder: "置換",
        .findRegexTooltip: "正規表現",
        .findCaseTooltip: "大文字と小文字を区別",
        .findPrevTooltip: "前の一致",
        .findNextTooltip: "次の一致",
        .findReplaceTooltip: "現在の一致を置換",
        .findReplaceAll: "すべて",
        .findReplaceAllTooltip: "すべての一致を置換",
        .findDone: "完了",
        .findDoneTooltip: "検索バーを閉じる",
        .findNoResults: "結果なし",
        .findReplacedCount: "%d 件を置換しました",
        .findFoundCount: "%d 件",
        .findMatchPosition: "%d/%d · %d 行目",

        .formatFailedTitle: "フォーマットに失敗しました",
        .formatErrorLine: "%d 行目：%@",
        .closeConfirmMessage: "“%@” への変更を保存しますか？",
        .closeConfirmInfo: "保存しない場合、変更内容は失われます。",
        .dontSave: "保存しない",
        .cancel: "キャンセル",
        .untitled: "無題",

        .downloadingTitle: "%@（ダウンロード中…）",
        .downloadTimeoutTitle: "ダウンロードがタイムアウトしました",
        .downloadTimeoutMessage: "iCloud から“%@”をダウンロードできませんでした。もう一度お試しください。",

        .prefTitle: "設定",
        .prefModules: "モジュール",
        .prefEditor: "エディタ",
        .prefIndentWidthLabel: "インデント幅：",
        .prefInsertSpaces: "タブをスペースに変換",
        .prefIndentRainbow: "インデントレインボー",
        .prefFontSizeLabel: "フォントサイズ：",
        .prefLanguageLabel: "言語：",
        .prefLanguageSystem: "システムに従う",

        .moduleHighlight: "シンタックスハイライト",
        .moduleCompletion: "コード補完",
        .moduleFormat: "フォーマット",

        .statusLnCol: "%d 行、%d 桁",
        .statusCharOne: "%d 文字",
        .statusCharMany: "%d 文字",
    ]
}
