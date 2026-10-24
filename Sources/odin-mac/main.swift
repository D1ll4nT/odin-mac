import Foundation
import OdinCore

let usage = """
usage: odin-mac [--bl F] [--ap F] [--cp F] [--csc F] [--ums F] [--port /dev/cu.usbmodemX] [--dry-run] [--yes] [--no-reboot]

  No files      connect, print the device PIT, disconnect (no writes).
  --dry-run     also verify/unpack files and show which partition each would go to (no writes).
  --yes         required to actually flash.
"""

struct Fail: Error, CustomStringConvertible { let description: String }

var slots: [(String, URL)] = []
var port: String?
var dryRun = false, yes = false, reboot = true
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--bl", "--ap", "--cp", "--csc", "--ums":
        guard let v = args.popFirst() else { print(usage); exit(2) }
        slots.append((String(a.dropFirst(2)).uppercased(), URL(fileURLWithPath: v)))
    case "--port": port = args.popFirst()
    case "--dry-run": dryRun = true
    case "--yes": yes = true
    case "--no-reboot": reboot = false
    default: print(usage); exit(a == "-h" || a == "--help" ? 0 : 2)
    }
}
// Odin's slot order.
let order = ["BL", "AP", "CP", "CSC", "UMS"]
slots.sort { order.firstIndex(of: $0.0)! < order.firstIndex(of: $1.0)! }
let flashing = !slots.isEmpty && !dryRun
if flashing && !yes { print("Refusing to flash without --yes. Run with --dry-run first.\n\n\(usage)"); exit(2) }

let work = FileManager.default.temporaryDirectory.appendingPathComponent("odin-mac-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: work) }

func main() throws {
    var files: [(slot: String, member: Member)] = []
    for (slot, url) in slots {
        if url.lastPathComponent.hasPrefix("CSC_") { print("! \(url.lastPathComponent): full CSC wipes user data (HOME_CSC keeps it)") }
        if url.pathExtension.lowercased() == "md5" {
            print("[\(slot)] checking MD5 of \(url.lastPathComponent)...")
            try verifyMD5(url)
        }
        print("[\(slot)] unpacking...")
        let (members, skipped) = try extract(url, into: work.appendingPathComponent(slot))
        for s in skipped { print("[\(slot)] skipping \(s) (not a partition image)") }
        files += members.map { (slot, $0) }
    }

    let candidates = SerialPort.candidates()
    guard let path = port ?? (candidates.count == 1 ? candidates[0] : nil) else {
        throw Fail(description: candidates.isEmpty
            ? "no Samsung serial device found. Put the phone in Download Mode and connect it (or pass --port)."
            : "several devices, pick one with --port: \(candidates.joined(separator: " "))")
    }
    print("Connecting \(path)...")
    let session = Session(port: try SerialPort(path: path))
    try session.handshake()
    try session.begin()
    print("Device protocol v\(session.deviceProtocol)")
    if flashing { try session.setTotalBytes(files.reduce(0) { $0 + UInt64($1.member.size) }) }

    let pit = try parsePIT(try session.dumpPIT())
    print("\nID   DEV BIN  PARTITION          FILE")
    func col(_ v: Any, _ w: Int) -> String { "\(v)".padding(toLength: w, withPad: " ", startingAt: 0) }
    for e in pit { print(col(e.identifier, 5) + col(e.deviceType, 4) + col(e.binaryType, 5) + col(e.partitionName, 19) + e.flashFilename) }

    // Resolve every file before sending a byte.
    var plan: [(Member, PitEntry)] = []
    var unmapped: [String] = []
    for (slot, m) in files {
        if let e = pit.first(where: { $0.flashFilename == m.name }) {
            plan.append((m, e))
            print("[\(slot)] \(m.name) (\(m.size) B) -> \(e.partitionName)")
        } else { unmapped.append(m.name) }
    }
    if !unmapped.isEmpty || !flashing {
        try session.close(reboot: false)
        if !unmapped.isEmpty { throw Fail(description: "no PIT partition for: \(unmapped.joined(separator: ", "))") }
        print("\nDry run done, nothing written.")
        return
    }

    for (m, e) in plan {
        print("\nFlashing \(m.name) -> \(e.partitionName)")
        try session.flash(file: m.url, entry: e) { sent, total in
            print("\r  \(total == 0 ? 100 : sent * 100 / total)%", terminator: "")
            fflush(stdout)
        }
    }
    try session.close(reboot: reboot)
    print("\n\nDone\(reboot ? ", rebooting" : "").")
}

do { try main() } catch {
    print("\nFAIL: \(error)")
    exit(1)
}
