//  SerialPort.swift — minimal POSIX serial port (termios) for USB-to-RS232 adapters.

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SerialError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func posix(_ what: String) -> SerialError {
        SerialError(message: "\(what): \(String(cString: strerror(errno)))")
    }
}

final class SerialPort {
    let path: String
    private var fd: Int32 = -1
    private(set) var baudRate: Int = 9600

    /// Opens the port at 9600 baud, 8 data bits, EVEN parity, 1 stop bit, no flow control.
    init(path: String, baudRate: Int = 9600) throws {
        self.path = path
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { throw SerialError.posix("Cannot open \(path)") }
        #if canImport(Darwin)
        if ioctl(fd, TIOCEXCL_) == -1 { /* exclusive access is best effort */ }
        #endif
        do {
            try configure(baudRate: baudRate)
            // Back to blocking mode; reads use poll() for timeouts.
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            setModemLines()
            flushInput()
        } catch {
            Darwin_close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin_close() }
    }

    private func Darwin_close() {
        _ = tcflush(fd, TCIOFLUSH)
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
        fd = -1
    }

    private func speedConstant(_ baud: Int) throws -> speed_t {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        default: throw SerialError(message: "Unsupported baud rate \(baud)")
        }
    }

    private func configure(baudRate: Int) throws {
        var t = termios()
        if tcgetattr(fd, &t) != 0 { throw SerialError.posix("tcgetattr") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~(tcflag_t(CSIZE) | tcflag_t(CSTOPB) | tcflag_t(PARODD) | tcflag_t(CRTSCTS))
        t.c_cflag |= tcflag_t(CS8 | PARENB)                 // 8 data bits, even parity, 1 stop bit
        t.c_iflag &= ~tcflag_t(INPCK | ISTRIP | IXON | IXOFF | IXANY | INLCR | IGNCR | ICRNL | IGNBRK | PARMRK)
        t.c_oflag &= ~tcflag_t(OPOST)
        t.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG | IEXTEN)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        let sp = try speedConstant(baudRate)
        cfsetispeed(&t, sp)
        cfsetospeed(&t, sp)
        if tcsetattr(fd, TCSANOW, &t) != 0 { throw SerialError.posix("Cannot configure \(path)") }
        self.baudRate = baudRate
    }

    /// Changes the speed of an open port (waits for pending output first).
    func setBaudRate(_ baud: Int) throws {
        guard baud != baudRate else { return }
        drainOutput()
        try configure(baudRate: baud)
    }

    /// Raise DTR and RTS, as most serial libraries do on open.
    private func setModemLines() {
        #if canImport(Darwin)
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = withUnsafeMutablePointer(to: &bits) { ioctl(fd, TIOCMBIS_, $0) }
        #else
        var bits: Int32 = Int32(TIOCM_DTR | TIOCM_RTS)
        _ = withUnsafeMutablePointer(to: &bits) { ioctl(fd, UInt(TIOCMBIS), UnsafeMutableRawPointer($0)) }
        #endif
    }

    /// Holds the line in BREAK for the given time (wakes the camera).
    func sendBreak(seconds: Double) {
        #if canImport(Darwin)
        _ = ioctl(fd, TIOCSBRK_)
        usleep(useconds_t(seconds * 1_000_000))
        _ = ioctl(fd, TIOCCBRK_)
        #else
        _ = ioctl(fd, UInt(TIOCSBRK))
        usleep(useconds_t(seconds * 1_000_000))
        _ = ioctl(fd, UInt(TIOCCBRK))
        #endif
    }

    func write(_ bytes: [UInt8]) throws {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { buf in
                #if canImport(Darwin)
                Darwin.write(fd, buf.baseAddress, buf.count)
                #else
                Glibc.write(fd, buf.baseAddress, buf.count)
                #endif
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialError.posix("Write to \(path) failed")
            }
            off += n
        }
    }

    func drainOutput() { _ = tcdrain(fd) }
    func flushInput() { _ = tcflush(fd, TCIFLUSH) }

    /// Reads up to `count` bytes, returning early (possibly with fewer) once `timeout` passes.
    func read(_ count: Int, timeout: Double) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: max(count, 1))
        while out.count < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, Int32(max(1, Int(remaining * 1000))))
            if r < 0 {
                if errno == EINTR { continue }
                throw SerialError.posix("Read from \(path) failed")
            }
            if r == 0 { break }
            if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && pfd.revents & Int16(POLLIN) == 0 {
                throw SerialError(message: "The serial adapter was disconnected.")
            }
            let n = buf.withUnsafeMutableBytes { b in
                #if canImport(Darwin)
                Darwin.read(fd, b.baseAddress, count - out.count)
                #else
                Glibc.read(fd, b.baseAddress, count - out.count)
                #endif
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialError.posix("Read from \(path) failed")
            }
            if n == 0 { continue }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Serial devices on this Mac. Prefers USB adapters (cu.usbserial-*, cu.usbmodem*, …)
    /// and leaves out Bluetooth and debug ports.
    static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let skip = ["Bluetooth", "debug-console", "wlan", "MALS", "SOC", "BLTH"]
        return names
            .filter { $0.hasPrefix("cu.") && !skip.contains(where: $0.contains) }
            .sorted { a, b in
                let ua = a.contains("usb"), ub = b.contains("usb")
                return ua != ub ? ua : a < b
            }
            .map { "/dev/" + $0 }
    }
}

#if canImport(Darwin)
// ioctl request codes from <sys/ttycom.h>; these are function-like macros Swift can't import.
private let TIOCEXCL_: UInt = 0x2000_740D   // _IO('t', 13)
private let TIOCSBRK_: UInt = 0x2000_747B   // _IO('t', 123)
private let TIOCCBRK_: UInt = 0x2000_747A   // _IO('t', 122)
private let TIOCMBIS_: UInt = 0x8004_746C   // _IOW('t', 108, int)
#endif
