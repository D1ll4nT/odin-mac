import CryptoKit
import Foundation

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
    for p in ["/opt/homebrew/bin/lz4", "/usr/local/bin/lz4", "/opt/local/bin/lz4"] where FileManager.default.isExecutableFile(atPath: p) { return p }
    throw FirmwareError(description: "lz4 not found (brew install lz4)")
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
    let names = all.filter { !$0.contains("/") }
    try run("/usr/bin/tar", ["-xf", url.path, "-C", dir.path] + names)
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
