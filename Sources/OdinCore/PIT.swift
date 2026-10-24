public struct PitEntry: Equatable {
    public var binaryType, deviceType, identifier, attributes, updateAttributes: UInt32
    public var blockSize, blockCount, fileOffset, fileSize: UInt32
    public var partitionName, flashFilename, fotaFilename: String
}

public struct PitError: Error, CustomStringConvertible {
    public let description: String
}

public let pitMagic: UInt32 = 0x1234_9876
let pitHeaderSize = 28
let pitEntrySize = 132

public func parsePIT(_ d: [UInt8]) throws -> [PitEntry] {
    guard d.count >= pitHeaderSize, le32(d, 0) == pitMagic else { throw PitError(description: "not a PIT (bad magic)") }
    let count = Int(le32(d, 4))
    guard d.count >= pitHeaderSize + count * pitEntrySize else { throw PitError(description: "PIT truncated: \(count) entries, \(d.count) bytes") }
    return (0..<count).map { i in
        let o = pitHeaderSize + i * pitEntrySize
        func u(_ k: Int) -> UInt32 { le32(d, o + k * 4) }
        func s(_ at: Int) -> String {
            let raw = d[(o + at)..<(o + at + 32)]
            return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return PitEntry(binaryType: u(0), deviceType: u(1), identifier: u(2), attributes: u(3), updateAttributes: u(4),
                        blockSize: u(5), blockCount: u(6), fileOffset: u(7), fileSize: u(8),
                        partitionName: s(36), flashFilename: s(68), fotaFilename: s(100))
    }
}
