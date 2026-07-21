import Foundation
import Testing
@testable import KaruCore

// Pure-function coverage for the iCloud open path (T10.4). The AppKit wiring
// (window de-duplication, download poll timer) is verified by code review — no
// test iCloud environment exists — but every decision it delegates to is here.

// MARK: - URL identity (de-duplication)

@Test func sameFileMatchesIdenticalURLs() {
    let a = URL(fileURLWithPath: "/Users/me/Documents/notes.txt")
    let b = URL(fileURLWithPath: "/Users/me/Documents/notes.txt")
    #expect(UbiquitousFile.sameFile(a, b))
}

@Test func sameFileIgnoresSpellingDifferences() {
    // Trailing slash, redundant "." and ".." components resolve to one path.
    let plain = URL(fileURLWithPath: "/Users/me/Documents/notes.txt")
    let dotted = URL(fileURLWithPath: "/Users/me/./Documents/notes.txt")
    let dotdot = URL(fileURLWithPath: "/Users/me/Documents/sub/../notes.txt")
    #expect(UbiquitousFile.sameFile(plain, dotted))
    #expect(UbiquitousFile.sameFile(plain, dotdot))
}

@Test func sameFileResolvesSymlinkPrefix() throws {
    // /tmp is a symlink to /private/tmp on macOS; both spellings are one file.
    // Symlink resolution only fires for a path that exists on disk, so create
    // a real file and compare its two equivalent spellings.
    let name = "karu-dedup-\(UUID().uuidString).txt"
    let short = URL(fileURLWithPath: "/tmp/\(name)")
    let full = URL(fileURLWithPath: "/private/tmp/\(name)")
    try Data("x".utf8).write(to: short)
    defer { try? FileManager.default.removeItem(at: short) }
    #expect(UbiquitousFile.sameFile(short, full))
}

@Test func sameFileRejectsDifferentFiles() {
    let a = URL(fileURLWithPath: "/Users/me/Documents/a.txt")
    let b = URL(fileURLWithPath: "/Users/me/Documents/b.txt")
    #expect(!UbiquitousFile.sameFile(a, b))
}

// MARK: - iCloud placeholder names

@Test func detectsPlaceholderSpelling() {
    let placeholder = URL(fileURLWithPath: "/iCloud/Docs/.Report.pages.icloud")
    #expect(UbiquitousFile.isPlaceholder(placeholder))
}

@Test func ordinaryFileIsNotPlaceholder() {
    #expect(!UbiquitousFile.isPlaceholder(URL(fileURLWithPath: "/iCloud/Docs/Report.pages")))
    // A visible ".icloud"-suffixed but non-hidden name is not the placeholder form.
    #expect(!UbiquitousFile.isPlaceholder(URL(fileURLWithPath: "/iCloud/Docs/Report.icloud")))
    // Degenerate ".icloud" (no real name inside) is not a placeholder.
    #expect(!UbiquitousFile.isPlaceholder(URL(fileURLWithPath: "/iCloud/Docs/.icloud")))
}

@Test func placeholderResolvesToRealFileName() {
    let placeholder = URL(fileURLWithPath: "/iCloud/Docs/.Report.pages.icloud")
    let resolved = UbiquitousFile.resolvedURL(for: placeholder)
    #expect(resolved.path == "/iCloud/Docs/Report.pages")
}

@Test func placeholderWithMultipleDotsResolvesCorrectly() {
    let placeholder = URL(fileURLWithPath: "/iCloud/Docs/.archive.tar.gz.icloud")
    #expect(UbiquitousFile.resolvedURL(for: placeholder).path == "/iCloud/Docs/archive.tar.gz")
}

@Test func nonPlaceholderURLIsReturnedUnchanged() {
    let plain = URL(fileURLWithPath: "/iCloud/Docs/Report.pages")
    #expect(UbiquitousFile.resolvedURL(for: plain) == plain)
}

// MARK: - Download decision

@Test func ordinaryLocalFileNeverNeedsDownload() {
    #expect(!UbiquitousFile.needsDownload(isUbiquitous: false, status: nil))
    // Even if a status somehow rode along, non-ubiquitous short-circuits.
    #expect(!UbiquitousFile.needsDownload(isUbiquitous: false, status: .notDownloaded))
}

@Test func notDownloadedUbiquitousItemNeedsDownload() {
    #expect(UbiquitousFile.needsDownload(isUbiquitous: true, status: .notDownloaded))
}

@Test func presentUbiquitousItemDoesNotNeedDownload() {
    #expect(!UbiquitousFile.needsDownload(isUbiquitous: true, status: .current))
    #expect(!UbiquitousFile.needsDownload(isUbiquitous: true, status: .downloaded))
}

@Test func ubiquitousItemWithNoStatusIsTreatedAsReady() {
    #expect(!UbiquitousFile.needsDownload(isUbiquitous: true, status: nil))
}

// MARK: - Download completion (poll loop exit)

@Test func downloadCompleteWhenPresentOnDisk() {
    #expect(UbiquitousFile.isDownloadComplete(status: .current))
    #expect(UbiquitousFile.isDownloadComplete(status: .downloaded))
}

@Test func downloadNotCompleteWhileStillNotDownloaded() {
    #expect(!UbiquitousFile.isDownloadComplete(status: .notDownloaded))
}

@Test func downloadCompleteWhenStatusVanishes() {
    // nil (no longer reported ubiquitous) stops the poll and hands off to a
    // normal read/report path.
    #expect(UbiquitousFile.isDownloadComplete(status: nil))
}
