import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(IOKit)
import IOKit
import IOKit.serial
#endif

private func sysRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ n: Int) -> Int {
#if canImport(Darwin)
    Darwin.read(fd, buf, n)
#else
    Glibc.read(fd, buf, n)
#endif
}

private func sysWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
#if canImport(Darwin)
    Darwin.write(fd, buf, n)
#else
    Glibc.write(fd, buf, n)
#endif
}

public struct PortError: Error, CustomStringConvertible {
    public let description: String
}

/// Download Mode is CDC-ACM. macOS exposes it as /dev/cu.usbmodem*; Linux as /dev/ttyACM*.
public final class SerialPort {
    let fd: Int32

    public init(path: String) throws {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw PortError(description: "open \(path): \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFL, 0)
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close(fd) }

    /// Serial devices whose USB parent is Samsung (VID 0x04E8); other usbmodem devices (monitors, dev boards) are ignored.
    public static func candidates() -> [String] {
#if canImport(IOKit)
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [String] = []
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            guard let vid = IORegistryEntrySearchCFProperty(s, kIOServicePlane, "idVendor" as CFString, nil, opts) as? Int, vid == 0x04E8,
                  let path = IORegistryEntryCreateCFProperty(s, kIOCalloutDeviceKey as CFString, nil, 0)?.takeRetainedValue() as? String
            else { continue }
            out.append(path)
        }
        return out.sorted()
#else
        return linuxSamsungPorts()
#endif
    }

    public func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { sysWrite(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw PortError(description: "write: \(String(cString: strerror(errno)))")
            }
            off += n
        }
    }

    /// Reads exactly `count` bytes; responses can arrive fragmented.
    public func read(_ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var got = 0
        let deadline = Date().addingTimeInterval(timeout)
        while got < count {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw PortError(description: "timeout: got \(got)/\(count) bytes") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(left, 1) * 1000))
            if r < 0, errno != EINTR { throw PortError(description: "poll: \(String(cString: strerror(errno)))") }
            if r <= 0 { continue }
            let n = out.withUnsafeMutableBytes { sysRead(fd, $0.baseAddress! + got, count - got) }
            if n < 0, errno != EINTR, errno != EAGAIN { throw PortError(description: "read: \(String(cString: strerror(errno)))") }
            if n == 0, p.revents & Int16(POLLHUP) != 0 { throw PortError(description: "device disconnected") }
            got += max(n, 0)
        }
        return out
    }
}

#if !canImport(IOKit)
/// `/dev/ttyACM*` and `/dev/ttyUSB*` whose sysfs parent advertises USB vendor 04e8.
private func linuxSamsungPorts() -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
    return names.compactMap { name -> String? in
        guard name.hasPrefix("ttyACM") || name.hasPrefix("ttyUSB") else { return nil }
        // Keep the `..` in the string so the kernel resolves the device symlink before the parent.
        guard let raw = try? String(contentsOfFile: "/sys/class/tty/\(name)/device/../idVendor", encoding: .utf8) else { return nil }
        let vid = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vid.caseInsensitiveCompare("04e8") == .orderedSame else { return nil }
        return "/dev/\(name)"
    }.sorted()
}
#endif
