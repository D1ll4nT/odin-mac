import Foundation

public struct ProtocolError: Error, CustomStringConvertible {
    public let description: String
}

/// Odin's Download Mode flow: handshake → begin → (total) → PIT → files → close/reboot.
public final class Session {
    let port: SerialPort
    public private(set) var deviceProtocol: UInt32 = 0

    public init(port: SerialPort) { self.port = port }

    /// Odin sub_434300: send "ODIN", expect "LOKE".
    public func handshake() throws {
        try port.write(Array("ODIN".utf8))
        let r = try port.read(4, timeout: 5)
        guard r == Array("LOKE".utf8) else { throw ProtocolError(description: "handshake: expected LOKE, got \(r)") }
    }

    /// Writes a control packet and returns the 8-byte ack's value. Odin fails on type 0xFFFFFFFF or a type mismatch.
    @discardableResult
    func request(_ type: UInt32, _ req: UInt32, _ args: [UInt32] = [], timeout: TimeInterval = 30) throws -> UInt32 {
        try port.write(controlPacket(type, req, args))
        let r = try port.read(8, timeout: timeout)
        let got = le32(r, 0), value = le32(r, 4)
        guard got == type else {
            throw ProtocolError(description: String(format: "request 0x%02X/%d failed (response 0x%08X, value 0x%08X)", type, req, got, value))
        }
        return value
    }

    /// Odin sub_434560.
    public func begin() throws {
        let r = try request(Cmd.session, 0, [odinProtocolVersion])
        deviceProtocol = r >> 16
        if deviceProtocol >= 2 { try request(Cmd.session, 5, [UInt32(filePacketSize)]) }
    }

    public func setTotalBytes(_ total: UInt64) throws {
        try request(Cmd.session, 2, totalBytesArgs(total))
    }

    /// Odin sub_434d00: size from 0x65/1, then 0x65/2 [i] followed by raw 500-byte chunks (no ack), then 0x65/3.
    public func dumpPIT() throws -> [UInt8] {
        let size = Int(try request(Cmd.pit, 1))
        guard size > 0, size < 1 << 20 else { throw ProtocolError(description: "implausible PIT size \(size)") }
        var pit: [UInt8] = []
        for i in 0..<((size - 1) / pitChunkSize + 1) {
            try port.write(controlPacket(Cmd.pit, 2, [UInt32(i)]))
            pit += try port.read(min(pitChunkSize, size - i * pitChunkSize), timeout: 10)
        }
        try request(Cmd.pit, 3)
        return pit
    }

    /// Odin sub_432900 (uncompressed path), applied per sequence:
    /// 0x66/0, 0x66/2 [announced], 1 MiB zero-padded parts each acked, 0x66/3 [end args].
    public func flash(file: URL, entry: PitEntry, progress: (Int, Int) -> Void) throws {
        // Below v2 no 1 MiB part size was negotiated; older bootloaders expect a different framing.
        guard deviceProtocol >= 2 else { throw ProtocolError(description: "device protocol v\(deviceProtocol) is not supported by this POC") }
        guard let limit = sequenceLimit(deviceType: entry.deviceType) else {
            throw ProtocolError(description: "\(entry.partitionName): unsupported PIT device type \(entry.deviceType)")
        }
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        let size = Int(try fh.seekToEnd())
        try fh.seek(toOffset: 0)
        let seqs = sequenceSizes(fileSize: size, limit: limit)
        var sent = 0
        for (s, seqBytes) in seqs.enumerated() {
            try request(Cmd.file, 0)
            try request(Cmd.file, 2, [announcedSize(seqBytes)])
            var left = seqBytes, part: UInt32 = 0
            while left > 0 {
                var chunk = [UInt8](try fh.read(upToCount: min(filePacketSize, left)) ?? Data())
                guard !chunk.isEmpty else { throw ProtocolError(description: "\(file.lastPathComponent): short read") }
                left -= chunk.count
                sent += chunk.count
                chunk += [UInt8](repeating: 0, count: filePacketSize - chunk.count)
                try port.write(chunk)
                let ack = try port.read(8, timeout: 60)
                guard le32(ack, 4) == part else {
                    throw ProtocolError(description: "\(entry.partitionName): part ack \(le32(ack, 4)) != \(part) (type 0x\(String(le32(ack, 0), radix: 16)))")
                }
                part += 1
                progress(sent, size)
            }
            // Bootloader writes to storage before acking; Odin warns "about 2 minutes".
            try request(Cmd.file, 3, endTransferArgs(bytes: seqBytes, entry: entry, isLast: s == seqs.count - 1), timeout: 300)
        }
    }

    /// Odin sub_435770: 0x67/0 close, then 0x67/1 reboot when AutoReboot is on.
    public func close(reboot: Bool) throws {
        try request(Cmd.end, 0)
        if reboot { try request(Cmd.end, 1) }
    }
}
