import Foundation
import CryptoKit

/// What a document last knew about its file on disk (R01).
///
/// Two parts:
/// - `stamp`: a cheap `stat` summary (device, inode, size, modification time in
///   nanoseconds). Comparing stamps is the fast path — equal stamps mean "nobody
///   touched the file".
/// - `digest`: SHA-256 of the file's raw bytes (32 bytes, never any text). Only
///   consulted when the stamps differ, so a `touch` or a byte-identical rewrite
///   is not mistaken for an external edit, and a non-UTF-8 file compares by its
///   on-disk bytes rather than by the decoded text.
///
/// `Codable` so it can travel in a crash-draft header.
public struct DiskState: Equatable, Sendable, Codable {
    public struct Stamp: Equatable, Sendable, Codable {
        public var device: UInt64
        public var inode: UInt64
        public var size: Int64
        public var modificationSeconds: Int64
        public var modificationNanoseconds: Int64

        public init(device: UInt64, inode: UInt64, size: Int64,
                    modificationSeconds: Int64, modificationNanoseconds: Int64) {
            self.device = device
            self.inode = inode
            self.size = size
            self.modificationSeconds = modificationSeconds
            self.modificationNanoseconds = modificationNanoseconds
        }

        init(_ info: stat) {
            self.init(device: UInt64(UInt32(bitPattern: info.st_dev)),
                      inode: UInt64(info.st_ino),
                      size: Int64(info.st_size),
                      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
        }

        /// `stat` of `url`, following symlinks. `nil` when nothing exists there
        /// (or it cannot be stat'ed at all).
        public static func of(_ url: URL) -> Stamp? {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return stat(path, &info)
            }
            return result == 0 ? Stamp(info) : nil
        }
    }

    public var stamp: Stamp
    /// SHA-256 of the file's bytes; always 32 bytes.
    public var digest: Data

    public init(stamp: Stamp, digest: Data) {
        self.stamp = stamp
        self.digest = digest
    }

    /// SHA-256 of an in-memory buffer (the bytes about to be written).
    public static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// SHA-256 of the bytes currently at `url` (following symlinks). Streams the
    /// file in fixed-size chunks, so nothing larger than one chunk is resident
    /// and a concurrent truncation cannot fault a mapped page.
    public static func digest(of url: URL) throws -> Data {
        try read(url).digest
    }

    /// Opens `url` once and returns the `fstat` stamp of the opened file plus the
    /// digest of the bytes read from that same descriptor, so both describe the
    /// same inode even if the path is replaced meanwhile. The stamp is taken
    /// before the bytes are read: an in-place write racing with the read leaves
    /// a stamp older than the file, which later surfaces as a (digest-checked)
    /// change rather than being missed.
    public static func read(_ url: URL) throws -> DiskState {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let stamp = Stamp(info)
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return DiskState(stamp: stamp, digest: Data(hasher.finalize()))
    }
}
