//  Camera.swift — Chinon ES-3000 serial protocol.
//
//  Swift port of chinon_camera.py from github.com/lustrinomatt/chinon-es3000-windows (MIT).
//  Link: 9600 baud 8E1, woken with a ~200 ms BREAK. Commands are 8 bytes
//  (CMD 00 a b c d e 1A); the camera answers D1 (accepted) or E1 (rejected), does the
//  work, then sends one completion byte (00 = success). Data packets are N bytes plus an
//  XOR checksum and are acknowledged with D2. All methods block: call them off the main thread.

import Foundation

class CameraError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
/// The camera accepted a command but reported a failure code (the link is still fine).
final class CameraFailed: CameraError {}
/// The camera answered E1 (e.g. no such picture); retrying won't help.
final class CameraRejected: CameraError {}

struct CameraStatus {
    let raw: [UInt8]
    var picturesLeft: Int { Int(raw[11]) }
    var clock: Date { Camera.cameraTime(Camera.le32(raw, 14)) }
    var zoom: Int { Int(raw[21] & 0x0F) }
    var focus: Int { Int((raw[21] >> 4) & 3) }
    var zoomMode: Int { Int((raw[21] >> 6) & 1) }
    var timer: Bool { raw[22] != 0 }
    var resolution: Int { Int(raw[23]) }
    var flash: Int { Int(raw[24]) }
    var battery: Int { Int(raw[29]) }
    /// Like the original software: zoom only works in zoom mode 0 and not in Macro focus.
    var zoomLocked: Bool { zoomMode == 1 || focus == 2 }
}

struct PictureInfo {
    let number: Int
    let resolution: Resolution
    let raw: [UInt8]
    var dataSize: Int { Camera.le32(raw, 6) }
    /// Time taken, or nil when the camera clock had never been set.
    var taken: Date? {
        let d = Camera.cameraTime(Camera.le32(raw, 10))
        return Calendar.current.component(.year, from: d) > 1995 ? d : nil
    }
}

final class Camera {
    let port: SerialPort
    var fastBaud = 57600
    var log: (String) -> Void
    private var lastCommand = Date.distantPast

    init(path: String, log: @escaping (String) -> Void = { _ in }) throws {
        port = try SerialPort(path: path, baudRate: 9600)
        self.log = log
    }

    // MARK: Time

    /// The camera counts half-seconds since 1994-01-01 00:00 local time.
    static let epoch: Date = {
        var c = DateComponents(); c.year = 1994; c.month = 1; c.day = 1
        return Calendar.current.date(from: c)!
    }()
    static func cameraTime(_ t: Int) -> Date { epoch.addingTimeInterval(Double(t) / 2) }
    static func le32(_ b: [UInt8], _ o: Int) -> Int {
        guard b.count >= o + 4 else { return 0 }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    // MARK: Low level

    private func sleep(_ s: Double) { if s > 0 { usleep(useconds_t(s * 1_000_000)) } }

    private func readExact(_ n: Int, timeout: Double = 2.0) throws -> [UInt8] {
        let d = try port.read(n, timeout: timeout)
        if d.count != n { throw CameraError("Timed out (wanted \(n) bytes, got \(d.count)).") }
        return d
    }

    private func drain(_ wait: Double = 0.2) {
        sleep(wait)
        _ = try? port.read(65_536, timeout: 0.05)
    }

    private func command(_ cmd: UInt8, _ a: UInt8 = 0, _ b: UInt8 = 0, _ c: UInt8 = 0,
                         _ d: UInt8 = 0, _ e: UInt8 = 0) throws {
        sleep(0.1 - Date().timeIntervalSince(lastCommand))   // ≥100 ms between commands
        let pkt: [UInt8] = [cmd, 0, a, b, c, d, e, 0x1A]
        port.flushInput()
        try port.write(pkt)
        lastCommand = Date()
        let r = try readExact(1)
        log("> " + hex(pkt) + "  < " + hex(r))
        if r[0] != 0xD1 {
            throw CameraRejected(String(format: "Camera rejected command %02X (reply %02X).", cmd, r[0]))
        }
    }

    /// Waits for the completion byte (00 = success).
    private func finish(_ timeout: Double) throws {
        let r = try readExact(1, timeout: timeout)
        if r[0] != 0 { throw CameraFailed(String(format: "Camera reported code %02X.", r[0])) }
    }

    private func simple(_ cmd: UInt8, _ value: UInt8 = 0, timeout: Double = 5) throws {
        try command(cmd, value)
        try finish(timeout)
    }

    private static func xor(_ d: ArraySlice<UInt8>) -> UInt8 { d.reduce(0, ^) }

    private func readPacket(_ size: Int) throws -> [UInt8] {
        let p = try readExact(size + 1)
        if Self.xor(p[0..<size]) != p[size] { throw CameraError("Checksum error.") }
        try port.write([0xD2])
        return Array(p[0..<size])
    }

    private func readShortBlock() throws -> [UInt8] {
        let d = try readPacket(256)
        drain()
        return d
    }

    private static let speeds: [Int: (UInt8, UInt8)] = [
        9600: (0x96, 0x00), 19200: (0x19, 0x20), 38400: (0x38, 0x40),
        57600: (0x57, 0x60), 115200: (0x11, 0x52)]

    private func setSpeed(_ baud: Int) throws {
        if port.baudRate == baud { return }
        guard let arg = Self.speeds[baud] else { return }
        try command(0x41, arg.0, arg.1)
        port.drainOutput()
        sleep(0.05)
        try port.setBaudRate(baud)
    }

    // MARK: Session

    func connect(attempts: Int = 5) throws {
        for _ in 0..<attempts {
            try? port.setBaudRate(9600)
            port.sendBreak(seconds: 0.2)
            sleep(0.1)
            do {
                try command(0x7E)
                drain()
                return
            } catch {
                log("hello failed: \(error.localizedDescription)")
                sleep(0.3)
            }
        }
        throw CameraError("Could not connect. Is the lens cover open (camera on), the cable in, and are the batteries fresh?")
    }

    func close() {
        try? setSpeed(9600)
        port.close()
    }

    // MARK: Queries

    func status(retries: Int = 4) throws -> CameraStatus {
        for i in 0..<retries {
            do {
                try command(0x7F)
                return CameraStatus(raw: try readShortBlock())
            } catch {
                if i == retries - 1 { throw error }
                sleep(0.8)          // camera busy (e.g. lens still moving)
                drain()
            }
        }
        throw CameraError("No status.")
    }

    func info(_ n: Int, retries: Int = 3) throws -> [UInt8] {
        for i in 0..<retries {
            do {
                try command(0x55, 0, UInt8(n))
                return try readShortBlock()
            } catch let e as CameraRejected {
                throw e
            } catch {
                if i == retries - 1 { throw error }
                sleep(0.8)
                drain()
            }
        }
        throw CameraError("No picture info.")
    }

    /// Polls until the camera answers again (it is silent while processing a shot).
    @discardableResult
    func waitReady(timeout: Double = 30) throws -> CameraStatus {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if let st = try? status(retries: 1) { return st }
            sleep(1.0)
            drain()
        }
        throw CameraError("The camera did not become ready.")
    }

    /// Lists pictures in the camera's active memory: the PC card when one is inserted,
    /// otherwise internal memory. Picture numbers are one byte, so 255 is the ceiling.
    func listPictures(maximum: Int = 255) -> [PictureInfo] {
        var pics: [PictureInfo] = []
        for n in 1...maximum {
            guard let inf = try? info(n) else { drain(0.3); break }
            if Int(inf[2]) != n { break }
            pics.append(PictureInfo(number: n, resolution: Resolution(rawValue: Int(inf[4])) ?? .superfine, raw: inf))
        }
        return pics
    }

    /// Sends cmd for picture n and collects its 1 KB packets until the 00 completion byte.
    private func readBlocks(_ cmd: UInt8, _ n: Int, progress: ((Int) -> Void)?) throws -> [UInt8] {
        try command(cmd, 0, UInt8(n))
        var data = [UInt8]()
        while true {
            let first = try readExact(1, timeout: 3)
            var rest = try port.read(1024, timeout: 0.25)
            if rest.isEmpty && first[0] == 0x00 { break }   // completion byte
            if rest.count < 1024 { rest += try readExact(1024 - rest.count) }
            let p = first + rest
            if Self.xor(p[0..<1024]) != p[1024] {
                throw CameraError("Checksum error in packet \(data.count / 1024 + 1).")
            }
            data += p[0..<1024]
            try port.write([0xD2])
            progress?(data.count)
        }
        return data
    }

    /// Runs body at the fast transfer speed. If a speed above 57600 fails, recovers the
    /// link, falls back to 57600 for the rest of the session and retries once.
    private func fast<T>(_ body: () throws -> T) throws -> T {
        defer {
            do { try setSpeed(9600) } catch { try? port.setBaudRate(9600) }
        }
        do {
            try setSpeed(fastBaud)
            return try body()
        } catch let e as CameraError {
            if fastBaud <= 57600 { throw e }
            log("\(fastBaud) baud failed (\(e.message)), falling back to 57600.")
            fastBaud = 57600
            try? port.setBaudRate(9600)
            drain(1.0)
            try connect()
            try setSpeed(57600)
            return try body()
        }
    }

    func image(_ n: Int, progress: ((Int) -> Void)? = nil) throws -> [UInt8] {
        try fast { try readBlocks(0x51, n, progress: progress) }
    }

    /// Fetches several thumbnails in one fast-speed session.
    func thumbnails(_ numbers: [Int], cancel: () -> Bool, each: (Int, [UInt8]) -> Void) throws {
        var todo = numbers
        try fast {
            while let n = todo.first {
                if cancel() { return }
                each(n, try readBlocks(0x56, n, progress: nil))
                todo.removeFirst()
            }
        }
    }

    func downloadDCT(_ n: Int, resolution: Resolution, progress: ((Int) -> Void)? = nil) throws -> Data {
        let raw = try image(n, progress: progress)
        return dctHeader(rawLength: raw.count, resolution: resolution) + Data(raw)
    }

    // MARK: Control

    func setResolution(_ v: Int) throws { try simple(0x71, UInt8(v)) }          // 0 SF, 1 F, 2 N
    func setFlash(_ v: Int) throws { try simple(0x72, UInt8(v)) }               // 0 Auto, 1 Fill, 2 Off
    func setFocus(_ v: Int) throws { try simple(0x73, UInt8(v), timeout: 10); sleep(1.0) }
    func setZoomLevel(_ v: Int) throws { try simple(0x78, UInt8(v), timeout: 10); sleep(1.5) }
    func setTimer(_ on: Bool) throws { try simple(0x74, on ? 1 : 0) }

    /// Sets the camera clock to the given local time.
    @discardableResult
    func setClock(_ when: Date = Date()) throws -> Int {
        let t = Int(when.timeIntervalSince(Self.epoch)) * 2
        try command(0x75, UInt8(t & 0xFF), UInt8((t >> 8) & 0xFF), UInt8((t >> 16) & 0xFF), UInt8((t >> 24) & 0xFF), 0)
        try finish(5)
        return t
    }

    func shoot(resolution: Int) throws {
        let timeout = Double([25, 20, 11][min(max(resolution, 0), 2)] + 15)
        try simple(0x77, 0, timeout: timeout)
        sleep(1.0)
        try waitReady()
    }

    /// Erases the active memory. A full flash card takes far longer than internal memory,
    /// so this allows the 240 s the original software allowed for card erases.
    func eraseAll() throws {
        try simple(0x7A, 0, timeout: 240)
        sleep(1.0)
        try waitReady(timeout: 60)
    }
}

func hex<C: Collection>(_ d: C) -> String where C.Element == UInt8 {
    d.map { String(format: "%02X", $0) }.joined(separator: " ")
}
