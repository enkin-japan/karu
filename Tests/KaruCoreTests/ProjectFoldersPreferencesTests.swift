import AppKit
import Foundation
import Testing
@testable import KaruCore

// The Project Folders sheet as a table. The index is never started here, so
// every folder reports `.paused` with no work queued; nothing is indexed.

private func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
}

private typealias Controller = ProjectFoldersPreferencesController

@MainActor
private extension ProjectFoldersPreferencesController {
    /// The cell for (row, column), laid out at the column's width and the row height.
    func laidOutCell(_ row: Int, _ column: Column) -> NSTableCellView? {
        guard let cell = cellView(row: row, column: column.identifier) as? NSTableCellView,
              let width = table.tableColumns.first(where: { $0.identifier == column.identifier })?.width
        else { return nil }
        cell.frame = NSRect(x: 0, y: 0, width: width, height: Controller.rowHeight)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    func buttons(row: Int) -> [NSButton] {
        guard let cell = laidOutCell(row, .actions) else { return [] }
        return allViews(cell).compactMap { $0 as? NSButton }
    }
}

/// `count` sibling folders added to a never-started index (all `.paused`).
@MainActor
private func makeFolders(_ fixture: IndexFixture, count: Int, name: (Int) -> String = { "folder\($0)" }) -> WorkspaceIndex {
    let index = fixture.makeIndex()
    for i in 0..<count {
        let url = fixture.base.appendingPathComponent(name(i), isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(index.addFolder(url))
    }
    return index
}

@Suite("Project folders table", .serialized)
@MainActor
struct ProjectFoldersPreferencesTests {
    @Test(arguments: [
        (WorkspaceIndex.State.indexing, "arrow.triangle.2.circlepath", L10nKey.projectFolderStateIndexing, false),
        (.upToDate, "checkmark.circle", .projectFolderStateUpToDate, false),
        (.overLimit, "exclamationmark.triangle", .projectFolderStateOverLimit, true),
        (.unreadable, "xmark.octagon", .projectFolderStateUnreadable, true),
        (.paused, "pause.circle", .projectFolderStatePaused, false),
    ])
    func everyStateHasASymbolTextAndColour(state: WorkspaceIndex.State, symbol: String, key: L10nKey, orange: Bool) throws {
        let status = WorkspaceIndex.FolderStatus(path: "/tmp/some/project", state: state, indexedFiles: 12, diskBytes: 4096)
        let row = Controller.Row(status)
        #expect(row.symbolName == symbol)
        #expect(row.statusText == L10n.t(key))
        #expect(row.isWarning == orange)
        #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)

        // The rendered cell: symbol plus text, never colour alone.
        let fixture = IndexFixture()
        let controller = Controller(index: fixture.makeIndex(), center: fixture.center) { $0(nil) }
        defer { controller.close() }
        let cell = try #require(controller.statusCell(for: row))
        let image = try #require(cell.imageView)
        let text = try #require(cell.textField)
        #expect(image.image != nil && !image.isAccessibilityElement())
        #expect(text.stringValue == L10n.t(key))
        if orange {
            #expect(image.contentTintColor == .systemOrange && text.textColor == .systemOrange)
        } else {
            #expect(image.contentTintColor == .secondaryLabelColor && text.textColor == .labelColor)
        }
    }

    @Test func folderCellShowsNameAndPathAndLongPathsDoNotWidenTheSheet() throws {
        let fixture = IndexFixture()
        let long = (0..<12).map { "very-long-directory-name-\($0)" }.joined(separator: "/")
        let index = makeFolders(fixture, count: 1) { _ in long }
        let controller = Controller(index: index, center: fixture.center) { $0(nil) }
        defer { controller.close() }
        let path = try #require(index.folderPaths.first)
        let cell = try #require(controller.laidOutCell(0, .folder))
        let labels = allViews(cell).compactMap { $0 as? NSTextField }
        let name = try #require(labels.first { $0.identifier?.rawValue == "projectFolders.name" })
        let shown = try #require(labels.first { $0.identifier?.rawValue == "projectFolders.path" })
        #expect(name.stringValue == "very-long-directory-name-11")
        #expect(shown.stringValue == (path as NSString).abbreviatingWithTildeInPath)
        #expect(shown.lineBreakMode == .byTruncatingMiddle)
        #expect(name.toolTip == path && shown.toolTip == path && cell.toolTip == path)
        // The path is cut in the middle rather than widening the cell or sheet.
        #expect(shown.frame.maxX <= cell.bounds.width)
        #expect(controller.window?.contentView?.fittingSize.width == Controller.sheetWidth)
        #expect(controller.window?.contentView?.frame.width == Controller.sheetWidth)
    }

    @Test func scrollViewGrowsUpToSixRows() {
        var heights: [CGFloat] = []
        for count in [1, 2, 6, 7, 10] {
            let fixture = IndexFixture()
            let controller = Controller(index: makeFolders(fixture, count: count), center: fixture.center) { $0(nil) }
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(controller.table.numberOfRows == count)
            #expect(!controller.scrollView.isHidden && controller.emptyLabel.isHidden)
            heights.append(controller.scrollView.frame.height)
            controller.close()
        }
        #expect(heights[0] < heights[1] && heights[1] < heights[2])
        #expect(heights[2] == heights[3] && heights[3] == heights[4])
        // One row more each time, by the row height.
        #expect(abs(heights[1] - heights[0] - Controller.rowHeight) < 0.5)
        #expect(abs(heights[2] - heights[0] - 5 * Controller.rowHeight) < 0.5)
    }

    @Test func actionButtonsActOnTheirRowAndClearFollowsTheModule() async throws {
        let fixture = IndexFixture()
        let index = makeFolders(fixture, count: 3)
        let controller = Controller(index: index, center: fixture.center) { $0(nil) }
        defer { controller.close() }
        // Never started: the module is off, so Clear Index is disabled.
        #expect(!index.isEnabled)
        for row in 0..<3 {
            let buttons = controller.buttons(row: row)
            let clear = try #require(buttons.first { $0.identifier?.rawValue == "projectFolders.clear" })
            let remove = try #require(buttons.first { $0.identifier?.rawValue == "projectFolders.remove" })
            #expect(!clear.isEnabled && remove.isEnabled)
            #expect(clear.tag == row && remove.tag == row)
            if controller.equalActionWidths { #expect(abs(clear.frame.width - remove.frame.width) < 0.5) }
        }
        controller.reload()
        let before = controller.rows.map(\.path)
        // Remove on the middle row removes that folder only.
        let middle = try #require(controller.buttons(row: 1).first { $0.identifier?.rawValue == "projectFolders.remove" })
        middle.performClick(nil)
        #expect(index.folderPaths == [before[0], before[2]])
        #expect(controller.rows.map(\.path) == [before[0], before[2]])
        #expect(controller.table.numberOfRows == 2)

        // Started with the module on: Clear Index is enabled.
        fixture.modules.setEnabled(true, for: .crossFileIndex)
        index.start()
        #expect(await settle(index))
        controller.reload()
        #expect(index.isEnabled)
        let clear = try #require(controller.buttons(row: 0).first { $0.identifier?.rawValue == "projectFolders.clear" })
        #expect(clear.isEnabled)
    }
}

// Switches `UserDefaults.standard`'s language quietly (no
// `L10n.didChangeNotification`), as `SettingsWindowLanguageTests` does, so no
// other observer runs on the temporary language.
@Suite(.serialized)
@MainActor
struct ProjectFoldersLanguageTests {
    private func setQuietly(_ raw: String?) {
        if let raw {
            UserDefaults.standard.set(raw, forKey: L10n.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.defaultsKey)
        }
    }

    @Test func nothingTruncatesInAnyLanguage() throws {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        for language in AppLanguage.allCases {
            setQuietly(language.rawValue)
            #expect(L10n.current == language)
            let fixture = IndexFixture()
            // Paused rows: the longest status text in every language.
            let controller = Controller(index: makeFolders(fixture, count: 2), center: fixture.center) { $0(nil) }
            defer { controller.close() }
            let content = try #require(controller.window?.contentView)
            content.layoutSubtreeIfNeeded()
            #expect(content.frame.width == Controller.sheetWidth, "\(language)")

            // Column titles fit their columns, and the columns fit the table.
            var total: CGFloat = 0
            for column in controller.table.tableColumns {
                #expect(column.headerCell.cellSize.width <= column.width + 0.5, "\(language) \(column.title)")
                #expect(column.width >= 30, "\(language) \(column.identifier.rawValue): \(column.width)")
                total += column.width + controller.table.intercellSpacing.width
            }
            #expect(total <= controller.scrollView.contentSize.width + 0.5, "\(language) columns: \(total)")
            #expect(controller.table.tableColumns.allSatisfy { !$0.title.isEmpty || $0.identifier.rawValue.hasSuffix("actions") })

            // Sheet labels and buttons.
            for view in allViews(content) where !view.isHiddenOrHasHiddenAncestor {
                if view.isDescendant(of: controller.scrollView) { continue }
                let isLabel = (view as? NSTextField).map { !$0.isEditable && !$0.isBezeled } ?? false
                guard view is NSButton || isLabel else { continue }
                #expect(view.frame.width + 0.5 >= view.fittingSize.width,
                        "\(language): \((view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue ?? "")")
                let right = view.convert(view.alignmentRect(forFrame: view.bounds), to: content).maxX
                #expect(right <= Controller.sheetWidth - Controller.insets.right + 0.5, "\(language) overflows: \(right)")
            }

            // Cells: buttons, numbers and the status text (which may wrap to
            // two lines, but is never cut).
            for column in [Controller.Column.files, .disk, .status, .actions] {
                let cell = try #require(controller.laidOutCell(0, column))
                for view in allViews(cell) {
                    #expect(view.frame.maxX <= cell.bounds.width + 0.5, "\(language) \(column) overflows")
                    if let button = view as? NSButton {
                        #expect(button.frame.width + 0.5 >= button.fittingSize.width, "\(language): \(button.title)")
                    } else if let text = view as? NSTextField {
                        // Measured without the field's line limit, so a cut
                        // last line would show up as a taller need.
                        let free = NSTextField(wrappingLabelWithString: text.stringValue)
                        free.font = text.font
                        let needed = free.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: text.frame.width,
                                                                           height: 1000))
                        #expect(text.frame.height + 0.5 >= needed.height, "\(language): \(text.stringValue)")
                        #expect(needed.height <= Controller.rowHeight, "\(language): \(text.stringValue) too tall")
                        #expect(text.frame.width > 0)
                    }
                }
            }
            let folderWidth = controller.table.tableColumns[0].width
            // Japanese paused rows are the worst case (long status and
            // button titles): about 98 pt; name and path then truncate.
            #expect(folderWidth >= 90, "\(language) folder column: \(folderWidth)")
        }
    }
}
