import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct FirmwareError: Error, CustomStringConvertible {
    public let description: String
}

/// `.tar.md5` = tar bytes + "<32 hex>  <name>\n". Returns the expected hash and how many leading bytes it covers.
public func md5Trailer(_ tail: [UInt8], fileSize: Int) -> (hash: String, covered: Int)? {
    var end = tail.count
    while end > 0, tail[end - 1] == 0x0A || tail[end - 1] == 0x0D { end -= 1 }
    var start = end
    while start > 0, tail[start - 1] != 0x0A, tail[start - 1] != 0 { start -= 1 }
    let line = String(decoding: tail[start..<end], as: UTF8.self)
    guard line.count > 34, line.prefix(32).allSatisfy(\.isHexDigit), line.dropFirst(32).hasPrefix("  ") else { return nil }
    return (line.prefix(32).lowercased(), fileSize - (tail.count - start))
}

public func verifyMD5(_ url: URL) throws {
    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }
    let size = Int(try fh.seekToEnd())
    try fh.seek(toOffset: UInt64(max(0, size - 1024)))
    guard let t = md5Trailer([UInt8](try fh.readToEnd() ?? Data()), fileSize: size) else {
        throw FirmwareError(description: "\(url.lastPathComponent): no MD5 trailer")
    }
    try fh.seek(toOffset: 0)
    var md5 = Insecure.MD5()
    var left = t.covered
    while left > 0, let d = try fh.read(upToCount: min(8 << 20, left)), !d.isEmpty {
        md5.update(data: d)
        left -= d.count
    }
    let got = md5.finalize().map { String(format: "%02x", $0) }.joined()
    guard got == t.hash else { throw FirmwareError(description: "\(url.lastPathComponent): MD5 mismatch (\(got) != \(t.hash))") }
}

@discardableResult
func run(_ exe: String, _ args: [String]) throws -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw FirmwareError(description: "\(exe) \(args.joined(separator: " ")) exited \(p.terminationStatus)") }
    return String(decoding: data, as: UTF8.self)
}

func lz4Path() throws -> String {
    for p in ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/opt/local/bin/lz4", "/usr/bin/lz4"] where FileManager.default.isExecutableFile(atPath: p) { return p }
    throw FirmwareError(description: "lz4 not found (brew install lz4, or apt install lz4)")
}

public struct Member {
    public let name: String   // name as flashed, without .lz4
    public let url: URL
    public let size: Int
}

/// Extracts a firmware tar into `dir` with the system bsdtar (which stops at the end-of-archive
/// marker, so the MD5 trailer is ignored) and decompresses `.lz4` members. Keeps tar order.
// ponytail: needs free disk ≈ decompressed firmware size; stream from the tar if that becomes a problem.
/// Members inside sub-directories (e.g. `meta-data/fota.zip`) are not partition images and are returned as `skipped`.
public func extract(_ url: URL, into dir: URL) throws -> (members: [Member], skipped: [String]) {
    if url.pathExtension.lowercased() == "smd" { throw FirmwareError(description: ".smd is not supported") }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let all = try run("/usr/bin/tar", ["-tf", url.path]).split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
    // Names come from the (untrusted) archive listing; `--` stops tar's option parser and the
    // dash filter drops any member that would still be read as a flag.
    let names = all.filter { !$0.contains("/") && !$0.hasPrefix("-") }
    try run("/usr/bin/tar", ["-xf", url.path, "-C", dir.path, "--"] + names)
    return (try names.map { name in
        var file = dir.appendingPathComponent(name)
        if name.hasSuffix(".lz4") {
            let out = file.deletingPathExtension()
            try run(try lz4Path(), ["-d", "-q", "-f", "--rm", file.path, out.path])
            file = out
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return Member(name: file.lastPathComponent, url: file, size: size)
    }, all.filter { $0.contains("/") })
}

#if !canImport(CryptoKit)
/// Same `Insecure.MD5` calls as CryptoKit, for hosts that do not ship that module.
enum Insecure {
    struct MD5 {
        private var a: UInt32 = 0x67452301
        private var b: UInt32 = 0xEFCDAB89
        private var c: UInt32 = 0x98BADCFE
        private var d: UInt32 = 0x10325476
        private var pending = [UInt8]()
        private var total: UInt64 = 0

        mutating func update(data: Data) {
            total += UInt64(data.count)
            pending.append(contentsOf: data)
            var i = 0
            while i + 64 <= pending.count {
                process(Array(pending[i..<(i + 64)]))
                i += 64
            }
            if i > 0 { pending.removeFirst(i) }
        }

        func finalize() -> [UInt8] {
            var copy = self
            copy.pending.append(0x80)
            while copy.pending.count % 64 != 56 { copy.pending.append(0) }
            var bits = copy.total &* 8
            for _ in 0..<8 {
                copy.pending.append(UInt8(truncatingIfNeeded: bits))
                bits >>= 8
            }
            var i = 0
            while i + 64 <= copy.pending.count {
                copy.process(Array(copy.pending[i..<(i + 64)]))
                i += 64
            }
            var out = [UInt8]()
            out.reserveCapacity(16)
            for v in [copy.a, copy.b, copy.c, copy.d] {
                out.append(UInt8(truncatingIfNeeded: v))
                out.append(UInt8(truncatingIfNeeded: v >> 8))
                out.append(UInt8(truncatingIfNeeded: v >> 16))
                out.append(UInt8(truncatingIfNeeded: v >> 24))
            }
            return out
        }

        private mutating func process(_ block: [UInt8]) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                m[i] = UInt32(block[i * 4])
                    | (UInt32(block[i * 4 + 1]) << 8)
                    | (UInt32(block[i * 4 + 2]) << 16)
                    | (UInt32(block[i * 4 + 3]) << 24)
            }
            var aa = a, bb = b, cc = c, dd = d
            for i in 0..<64 {
                let f: UInt32
                let g: Int
                if i < 16 {
                    f = (bb & cc) | (~bb & dd)
                    g = i
                } else if i < 32 {
                    f = (dd & bb) | (~dd & cc)
                    g = (5 * i + 1) % 16
                } else if i < 48 {
                    f = bb ^ cc ^ dd
                    g = (3 * i + 5) % 16
                } else {
                    f = cc ^ (bb | ~dd)
                    g = (7 * i) % 16
                }
                let sum = aa &+ f &+ Self.k[i] &+ m[g]
                let rotated = (sum << Self.s[i]) | (sum >> (32 - Self.s[i]))
                aa = dd
                dd = cc
                cc = bb
                bb = bb &+ rotated
            }
            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        private static let s: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]

        private static let k: [UInt32] = [
            0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE, 0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
            0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE, 0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
            0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA, 0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
            0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED, 0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
            0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C, 0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
            0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05, 0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
            0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039, 0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
            0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1, 0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
        ]
    }
}
#endif
