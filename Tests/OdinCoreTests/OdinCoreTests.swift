import Foundation
import XCTest
@testable import OdinCore

final class OdinCoreTests: XCTestCase {
    func testControlPacketLayout() {
        let p = controlPacket(Cmd.file, 3, [0, 0x1234_5678])
        XCTAssertEqual(p.count, 1024)
        XCTAssertEqual(Array(p[0..<8]), [0x66, 0, 0, 0, 3, 0, 0, 0])
        XCTAssertEqual(Array(p[12..<16]), [0x78, 0x56, 0x34, 0x12])
        XCTAssertTrue(p[16...].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(controlPacket(Cmd.session, 0, [odinProtocolVersion])[8..<12]), [4, 0, 0, 0])
    }

    func testTotalBytesUsesOdinDivisor() {
        XCTAssertEqual(totalBytesArgs(5), [5, 0])
        XCTAssertEqual(totalBytesArgs(0x1_0000_0000), [1, 1]) // 2^32 = 1*0xFFFFFFFF + 1
    }

    func testSequencing() {
        XCTAssertEqual(sequenceSizes(fileSize: 70 << 20, limit: 30 << 20), [30 << 20, 30 << 20, 10 << 20])
        XCTAssertEqual(sequenceSizes(fileSize: 0, limit: 30 << 20), [])
        XCTAssertEqual(announcedSize(1), 0x20000)
        XCTAssertEqual(announcedSize(0x20000), 0x20000)
        XCTAssertEqual(announcedSize(0x20001), 0x40000)
        XCTAssertNil(sequenceLimit(deviceType: 4))
        XCTAssertEqual(sequenceLimit(deviceType: 8), 30 << 20)
    }

    func testPITParse() throws {
        var d = [UInt8](repeating: 0, count: 28 + 2 * 132)
        func put(_ o: Int, _ v: UInt32) { for b in 0..<4 { d[o + b] = UInt8(truncatingIfNeeded: v >> (8 * b)) } }
        func str(_ o: Int, _ s: String) { for (i, c) in s.utf8.enumerated() { d[o + i] = c } }
        put(0, pitMagic); put(4, 2)
        let e1 = 28 + 132
        put(e1, 0); put(e1 + 4, 8); put(e1 + 8, 21)
        str(e1 + 36, "BOOT"); str(e1 + 68, "boot.img")
        let pit = try parsePIT(d)
        XCTAssertEqual(pit.count, 2)
        XCTAssertEqual(pit[1].identifier, 21)
        XCTAssertEqual(pit[1].deviceType, 8)
        XCTAssertEqual(pit[1].partitionName, "BOOT")
        XCTAssertEqual(pit[1].flashFilename, "boot.img")
        XCTAssertEqual(endTransferArgs(bytes: 7, entry: pit[1], isLast: true), [0, 7, 0, 8, 21, 1, 0, 0])
        XCTAssertThrowsError(try parsePIT([UInt8](repeating: 0, count: 28)))
    }

    /// Real .tar.md5 built with the system tools: MD5 check, bsdtar ignoring the trailer, lz4 unpack.
    func testTarMd5RoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("odin-mac-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let img = Data((0..<100_000).map { UInt8($0 % 251) })
        try img.write(to: dir.appendingPathComponent("boot.img"))
        try OdinCore.run(try lz4Path(), ["-q", "-f", dir.appendingPathComponent("boot.img").path, dir.appendingPathComponent("boot.img.lz4").path])
        try Data("x".utf8).write(to: dir.appendingPathComponent("vbmeta.img"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("meta-data"), withIntermediateDirectories: true)
        try Data("z".utf8).write(to: dir.appendingPathComponent("meta-data/fota.zip"))
        let tar = dir.appendingPathComponent("AP_TEST.tar")
        try OdinCore.run("/usr/bin/tar", ["--format", "ustar", "-cf", tar.path, "-C", dir.path, "boot.img.lz4", "meta-data/fota.zip", "vbmeta.img"])
        let hash = try OdinCore.run("/sbin/md5", ["-q", tar.path]).trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = try Data(contentsOf: tar)
        bytes += Data("\(hash)  AP_TEST.tar\n".utf8)
        let md5File = dir.appendingPathComponent("AP_TEST.tar.md5")
        try bytes.write(to: md5File)

        XCTAssertNoThrow(try verifyMD5(md5File))
        let (members, skipped) = try extract(md5File, into: dir.appendingPathComponent("out"))
        XCTAssertEqual(members.map(\.name), ["boot.img", "vbmeta.img"])
        XCTAssertEqual(skipped, ["meta-data/fota.zip"])
        XCTAssertEqual(try Data(contentsOf: members[0].url), img)

        bytes[10] ^= 1
        try bytes.write(to: md5File)
        XCTAssertThrowsError(try verifyMD5(md5File))
    }
}
