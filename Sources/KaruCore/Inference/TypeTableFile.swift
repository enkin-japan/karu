import Foundation
#if canImport(Darwin)
import Darwin
#endif

// M17 T17.10 — read-only, memory-mapped type-table files (`.ktt`).
//
// Written by scripts/m17/ktt_writer.py (shared by gen_python_types.py and
// gen-ts-types.mjs). All integers little-endian; every region 4-byte aligned.
//
//   Header (16 bytes)
//     0  "KTT1"
//     4  u16 format version (1)      6  u16 language (1 Python, 2 TypeScript)
//     8  u32 section count           12 u32 reserved
//   Section directory (32 bytes per section)
//     u32 section id (1 Python modules, 2 TS ES globals, 3 TS DOM globals)
//     u32 entry count
//     u32 index offset    -> entry count × { u32 name string id, u32 blob offset
//                            (relative to the blobs region), u32 blob length },
//                            sorted by the names' UTF-8 bytes (binary search)
//     u32 strings offset  -> u32 string count, u32 offsets[count + 1] (relative
//                            to the byte area that follows), UTF-8 bytes.
//                            String id 0 is always "".
//     u32 strings length, u32 blobs offset, u32 blobs length, u32 reserved
//   Per-entry blob: a sequence of unsigned LEB128 varints; strings are ids into
//   the section's string table. Each blob decodes on its own (see
//   TypeTableDecoder), so opening a table touches only the header, and a query
//   touches the index, the strings it compares or decodes, and one blob.
//
// Sections are self-contained (own index, strings and blobs), so querying ES
// symbols never reads a page of the DOM section.

/// One section's location inside a mapped file.
struct TypeTableSection: Sendable {
    let id: UInt32
    let entryCount: Int
    let indexOffset: Int
    let stringsOffset: Int
    let stringsLength: Int
    let blobsOffset: Int
    let blobsLength: Int
    /// Number of strings; read from the first word of the strings region.
    let stringCount: Int
}

/// A `.ktt` file mapped with `mmap(PROT_READ, MAP_PRIVATE)`. Immutable after
/// init and the mapping is read-only, so it is safe to share across threads.
final class MappedTypeTable: @unchecked Sendable {
    static let magic: [UInt8] = Array("KTT1".utf8)
    static let formatVersion: UInt16 = 1

    let url: URL
    let language: UInt16
    let sections: [TypeTableSection]
    let length: Int
    private let base: UnsafeRawPointer

    /// Maps `url` and validates the header and the section directory. Returns
    /// nil for a missing, truncated or foreign file. Does not decode entries.
    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size >= 16, st.st_size < Int64(Int32.max) else { return nil }
        let length = Int(st.st_size)
        guard let raw = mmap(nil, length, PROT_READ, MAP_PRIVATE, fd, 0), raw != MAP_FAILED else { return nil }
        let base = UnsafeRawPointer(raw)
        func u16(_ o: Int) -> UInt16 { UInt16(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt16.self)) }
        func u32(_ o: Int) -> Int { Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: o, as: UInt32.self))) }

        var ok = (0..<4).allSatisfy { base.load(fromByteOffset: $0, as: UInt8.self) == Self.magic[$0] }
            && u16(4) == Self.formatVersion
        let sectionCount = ok ? u32(8) : 0
        ok = ok && sectionCount <= 16 && 16 + 32 * sectionCount <= length
        var sections: [TypeTableSection] = []
        if ok {
            for i in 0..<sectionCount {
                let d = 16 + 32 * i
                let entryCount = u32(d + 4), indexOffset = u32(d + 8)
                let stringsOffset = u32(d + 12), stringsLength = u32(d + 16)
                let blobsOffset = u32(d + 20), blobsLength = u32(d + 24)
                guard indexOffset + entryCount * 12 <= length,
                      stringsLength >= 8, stringsOffset + stringsLength <= length,
                      blobsOffset + blobsLength <= length else { ok = false; break }
                let stringCount = u32(stringsOffset)
                guard 4 + 4 * (stringCount + 1) <= stringsLength else { ok = false; break }
                sections.append(TypeTableSection(
                    id: UInt32(u32(d)), entryCount: entryCount, indexOffset: indexOffset,
                    stringsOffset: stringsOffset, stringsLength: stringsLength,
                    blobsOffset: blobsOffset, blobsLength: blobsLength, stringCount: stringCount))
            }
        }
        guard ok else {
            munmap(raw, length)
            return nil
        }
        self.url = url
        self.base = base
        self.length = length
        self.language = u16(6)
        self.sections = sections
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: base), length)
    }

    func section(id: UInt32) -> TypeTableSection? {
        sections.first { $0.id == id }
    }

    @inline(__always)
    func u32(_ offset: Int) -> Int {
        Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    /// UTF-8 bytes of string `id` in `section`, or nil when out of range.
    func stringBytes(_ section: TypeTableSection, _ id: Int) -> UnsafeRawBufferPointer? {
        guard id >= 0, id < section.stringCount else { return nil }
        let table = section.stringsOffset + 4
        let start = u32(table + 4 * id), end = u32(table + 4 * (id + 1))
        let area = table + 4 * (section.stringCount + 1)
        guard start <= end, area + end <= section.stringsOffset + section.stringsLength else { return nil }
        return UnsafeRawBufferPointer(start: base + area + start, count: end - start)
    }

    func string(_ section: TypeTableSection, _ id: Int) -> String? {
        guard let bytes = stringBytes(section, id) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Name string id and blob of index entry `i`.
    func indexEntry(_ section: TypeTableSection, _ i: Int) -> (nameID: Int, blob: UnsafeRawBufferPointer)? {
        guard i >= 0, i < section.entryCount else { return nil }
        let e = section.indexOffset + 12 * i
        let nameID = u32(e), offset = u32(e + 4), count = u32(e + 8)
        guard offset + count <= section.blobsLength else { return nil }
        return (nameID, UnsafeRawBufferPointer(start: base + section.blobsOffset + offset, count: count))
    }

    /// Binary search of the sorted index by UTF-8 bytes. Touches only the
    /// index and the compared names of this section.
    func find(_ section: TypeTableSection, name: String) -> Int? {
        var query = name
        return query.withUTF8 { q -> Int? in
            var lo = 0, hi = section.entryCount
            while lo < hi {
                let mid = (lo + hi) / 2
                guard let entry = indexEntry(section, mid),
                      let candidate = stringBytes(section, entry.nameID) else { return nil }
                let n = min(candidate.count, q.count)
                var c = n == 0 ? 0 : memcmp(candidate.baseAddress!, q.baseAddress!, n)
                if c == 0 { c = candidate.count < q.count ? -1 : (candidate.count > q.count ? 1 : 0) }
                if c == 0 { return mid }
                if c < 0 { lo = mid + 1 } else { hi = mid }
            }
            return nil
        }
    }

    /// All entry names of a section, in index order (allocates; for listings).
    func names(_ section: TypeTableSection) -> [String] {
        (0..<section.entryCount).compactMap { i in indexEntry(section, i).flatMap { string(section, $0.nameID) } }
    }
}
