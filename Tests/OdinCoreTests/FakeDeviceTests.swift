import Foundation
import XCTest
@testable import OdinCore

/// Drives the real SerialPort + Session against a scripted fake bootloader on a pty pair.
final class FakeDeviceTests: XCTestCase {
    func testFullSessionOverPty() throws {
        var master: Int32 = 0, slave: Int32 = 0
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        let slavePath = String(cString: ptsname(master))

        var pitBytes = [UInt8](repeating: 0, count: 28 + 132)
        func put(_ o: Int, _ v: UInt32) { for b in 0..<4 { pitBytes[o + b] = UInt8(truncatingIfNeeded: v >> (8 * b)) } }
        put(0, pitMagic); put(4, 1); put(28 + 4, 2); put(28 + 8, 13)
        for (i, c) in "boot.img".utf8.enumerated() { pitBytes[28 + 68 + i] = c }
        let fileSize = filePacketSize + 1000

        func readN(_ n: Int) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: n), got = 0
            while got < n { got += b.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress! + got, n - got) } }
            return b
        }
        func reply(_ t: UInt32, _ v: UInt32) { let p = controlPacket(t, v); _ = p.withUnsafeBytes { Darwin.write(master, $0.baseAddress, 8) } }
        func send(_ b: [UInt8]) { _ = b.withUnsafeBytes { Darwin.write(master, $0.baseAddress, b.count) } }

        var log: [[UInt32]] = []
        let device = Thread {
            XCTAssertEqual(readN(4), Array("ODIN".utf8)); send(Array("LOKE".utf8))
            func packet() -> [UInt32] { let p = readN(1024); let w = (0..<10).map { le32(p, $0 * 4) }; log.append(w); return w }
            _ = packet(); reply(0x64, 4 << 16)                  // begin, protocol v4
            _ = packet(); reply(0x64, 0)                        // packet size
            _ = packet(); reply(0x65, UInt32(pitBytes.count))   // PIT size
            _ = packet(); send(pitBytes)                        // PIT part 0 (raw, no ack)
            _ = packet(); reply(0x65, 0)                        // PIT end
            _ = packet(); reply(0x66, 0)                        // flash start
            _ = packet(); reply(0x66, 0)                        // announced size
            for part: UInt32 in 0..<2 { _ = readN(filePacketSize); reply(0, part) }
            _ = packet(); reply(0x66, 0)                        // end transfer
            _ = packet(); reply(0x67, 0)                        // close
            _ = packet(); reply(0x67, 0)                        // reboot
        }
        device.start()

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("odin-mac-fake-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(count: fileSize).write(to: file)

        let s = Session(port: try SerialPort(path: slavePath))
        try s.handshake()
        try s.begin()
        XCTAssertEqual(s.deviceProtocol, 4)
        let pit = try parsePIT(try s.dumpPIT())
        XCTAssertEqual(pit.first?.flashFilename, "boot.img")
        try s.flash(file: file, entry: pit[0]) { _, _ in }
        try s.close(reboot: true)

        XCTAssertEqual(log[0][0...2], [0x64, 0, 4])
        XCTAssertEqual(log[1][0...2], [0x64, 5, UInt32(filePacketSize)])
        XCTAssertEqual(log[3][0...2], [0x65, 2, 0])
        XCTAssertEqual(log[6][0...2], [0x66, 2, announcedSize(fileSize)])
        XCTAssertEqual(Array(log[7][0...9]), [0x66, 3, 0, UInt32(fileSize), 0, 2, 13, 1, 0, 0])
        XCTAssertEqual(log[9][0...1], [0x67, 1])
        close(master); close(slave)
    }
}
