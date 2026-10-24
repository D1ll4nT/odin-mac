// Wire format recovered from Odin3 v3.13.3 (sub_431490 / sub_431680), cross-checked with Heimdall.
// All integers are little-endian u32.

public enum Cmd {
    public static let session: UInt32 = 0x64
    public static let pit: UInt32 = 0x65
    public static let file: UInt32 = 0x66
    public static let end: UInt32 = 0x67
}

/// Odin always sends this in BEGIN_SESSION (`this[0x66d] = 4` before `0x64/0`); Heimdall mainline sends nothing.
public let odinProtocolVersion: UInt32 = 4
public let controlPacketSize = 1024
public let filePacketSize = 1 << 20
public let pitChunkSize = 500

/// 1024 zeroed bytes: [type, request, args...].
public func controlPacket(_ type: UInt32, _ request: UInt32, _ args: [UInt32] = []) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: controlPacketSize)
    for (i, v) in ([type, request] + args).enumerated() {
        for b in 0..<4 { p[i * 4 + b] = UInt8(truncatingIfNeeded: v >> (8 * b)) }
    }
    return p
}

public func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) }
}

/// Odin splits the 64-bit total with _aullrem/_aulldiv by 0xFFFFFFFF (not 2^32).
public func totalBytesArgs(_ total: UInt64) -> [UInt32] {
    [UInt32(total % 0xFFFF_FFFF), UInt32(total / 0xFFFF_FFFF)]
}

/// Max bytes per transfer sequence by PIT device type (Odin sub_435970 jump table).
/// Type 0 (OneNAND) is computed from block size in Odin and is not supported here.
public func sequenceLimit(deviceType: UInt32) -> Int? {
    switch deviceType {
    case 1, 2, 8: return 30 << 20
    case 6: return 4 << 20
    case 7: return 1 << 20
    default: return nil
    }
}

public func sequenceSizes(fileSize: Int, limit: Int) -> [Int] {
    stride(from: 0, to: fileSize, by: limit).map { min(limit, fileSize - $0) }
}

/// Size announced in `0x66/2`: Odin rounds the sequence up to 128 KiB.
public func announcedSize(_ sequenceBytes: Int) -> UInt32 {
    UInt32(((sequenceBytes - 1) >> 17) + 1) << 17
}

/// `0x66/3` args for the phone destination: [dest=0, bytes, binaryType, deviceType, identifier, isLast, 0, 0].
public func endTransferArgs(bytes: Int, entry: PitEntry, isLast: Bool) -> [UInt32] {
    [0, UInt32(bytes), entry.binaryType, entry.deviceType, entry.identifier, isLast ? 1 : 0, 0, 0]
}
