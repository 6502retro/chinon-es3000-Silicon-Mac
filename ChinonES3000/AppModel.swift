//  AppModel.swift — app state and camera jobs.
//
//  Published state lives on the main thread. Every camera operation runs on one serial
//  background queue that owns the Camera object, so the UI never blocks on the serial link.

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
}

final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let autoPort = "Auto"
    struct Speed: Identifiable { let label: String; let baud: Int; var id: Int { baud } }
    static let speeds = [Speed(label: "Standard (57600)", baud: 57600), Speed(label: "Fast (115200)", baud: 115200)]

    // Connection
    @Published var ports: [String] = []
    @Published var selectedPort: String = AppModel.autoPort
    @Published var connected = false
    @Published var statusText = "Not connected. Slide the lens cover open, then Connect."
    @Published var statusOK = false
    @Published var busy = false
    @Published var progress: Double? = nil

    // Pictures
    @Published var pictures: [PictureInfo] = []
    @Published var thumbs: [Int: CGImage] = [:]
    @Published var saved: [Int: URL] = [:]
    @Published var selection: Set<Int> = []
    @Published var preview: CGImage? = nil
    @Published var previewPlaceholder = "Preview"
    @Published var caption = ""
    @Published var log: [LogLine] = []
    @Published var alert: String? = nil

    // Camera settings (mirrors the camera)
    @Published var resolution = 0
    @Published var flash = 0
    @Published var focus = 0
    @Published var zoom = 0
    @Published var timer = false
    @Published var zoomLocked = false
    @Published var cameraInfo = ""

    // Preferences
    @Published var photoDir: URL { didSet { defaults.set(photoDir.path, forKey: "photoDir") } }
    @Published var fastBaud: Int { didSet { defaults.set(fastBaud, forKey: "speed") } }
    @Published var format: ImageFormat { didSet { defaults.set(format.rawValue, forKey: "format") } }
    @Published var keepDCT: Bool { didSet { defaults.set(keepDCT, forKey: "keepDCT") } }
    @Published var verbose: Bool { didSet { defaults.set(verbose, forKey: "verbose") } }
    private var rotations: [String: Int] { didSet { defaults.set(rotations, forKey: "rotations") } }

    let decoder: ChinonDecoder?
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "camera", qos: .userInitiated)
    private var camera: Camera?                      // touched only on `queue`
    private let cancelLock = NSLock()
    private var _cancelThumbs = false
    private var backgroundJobRunning = false         // main thread
    private var warnedBattery = false

    init() {
        let d = UserDefaults.standard
        if let p = d.string(forKey: "photoDir"), FileManager.default.fileExists(atPath: p) {
            photoDir = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            photoDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Chinon ES-3000", isDirectory: true)
        }
        let sp = d.integer(forKey: "speed")
        fastBaud = sp == 115200 ? 115200 : 57600
        format = ImageFormat(rawValue: d.string(forKey: "format") ?? "") ?? .png
        keepDCT = d.object(forKey: "keepDCT") as? Bool ?? true
        verbose = d.bool(forKey: "verbose")
        rotations = d.dictionary(forKey: "rotations") as? [String: Int] ?? [:]
        selectedPort = d.string(forKey: "port") ?? AppModel.autoPort
        if let url = Bundle.main.url(forResource: "chinon_params", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            decoder = try? ChinonDecoder(paramsData: data)
        } else {
            decoder = nil
        }
        refreshPorts()
        if decoder == nil { logLine("The picture decoder could not load its parameters; pictures can't be converted.") }
    }

    // MARK: - Helpers

    private func ui(_ f: @escaping () -> Void) {
        if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
    }

    private func onMain<T>(_ f: () -> T) -> T {
        Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f)
    }

    func logLine(_ s: String) {
        ui {
            self.log.append(LogLine(text: s))
            if self.log.count > 1000 { self.log.removeFirst(self.log.count - 1000) }
        }
    }

    private func detail(_ s: String) {
        if onMain({ verbose }) { logLine(s) }
    }

    private var cancelThumbs: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelThumbs }
        set { cancelLock.lock(); _cancelThumbs = newValue; cancelLock.unlock() }
    }

    private func requireCamera() throws -> Camera {
        guard let c = camera else { throw CameraError("Not connected. Slide the lens cover open and click Connect.") }
        return c
    }

    /// Queues a camera job. Background jobs (thumbnails) give way to user actions.
    private func run(background: Bool = false, _ job: @escaping () throws -> Void) {
        if background {
            backgroundJobRunning = true
            cancelThumbs = false
        } else {
            if busy { logLine("Busy, please wait for the current task."); return }
            busy = true
            if backgroundJobRunning { cancelThumbs = true }
        }
        queue.async { [self] in
            do {
                try job()
            } catch let e as CameraFailed {
                logLine("Camera refused that (\(e.message)).")
                ui { self.alert = "The camera refused that (\(e.message)).\n\nThe connection is still open." }
                try? readSettings()
            } catch let e as CameraError {
                logLine("Error: \(e.message)")
                ui { self.alert = "\(e.message)\n\nTip: close and reopen the lens cover (turns the camera off and on), then Connect again." }
                drop()
            } catch {
                logLine("Error: \(error.localizedDescription)")
                ui { self.alert = error.localizedDescription }
                if error is SerialError { drop() }
            }
            ui {
                if background { self.backgroundJobRunning = false } else { self.busy = false }
                self.progress = nil
            }
        }
    }

    /// Forgets a broken connection (queue only).
    private func drop() {
        camera?.port.close()
        camera = nil
        ui {
            self.connected = false
            self.statusText = "Not connected"; self.statusOK = false
            self.cameraInfo = ""
        }
    }

    // MARK: - Connection

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if selectedPort != AppModel.autoPort && !ports.contains(selectedPort) { selectedPort = AppModel.autoPort }
    }

    func toggleConnection() {
        if connected { run { self.disconnect() } } else {
            let port = selectedPort
            defaults.set(port, forKey: "port")
            run { try self.connect(port) }
        }
    }

    private func disconnect() {
        camera?.close()
        camera = nil
        ui {
            self.connected = false
            self.statusText = "Not connected"; self.statusOK = false
            self.cameraInfo = ""
        }
        logLine("Disconnected.")
    }

    private func connect(_ choice: String) throws {
        var candidates = choice == AppModel.autoPort ? SerialPort.availablePorts() : [choice]
        if let last = defaults.string(forKey: "lastPort"), let i = candidates.firstIndex(of: last) {
            candidates.remove(at: i); candidates.insert(last, at: 0)   // try what worked last time first
        }
        if candidates.isEmpty {
            throw CameraError("No serial ports found. Is the USB-serial adapter plugged in?")
        }
        for path in candidates {
            logLine("Trying \(path)…")
            let cam: Camera
            do {
                cam = try Camera(path: path, log: { [weak self] s in self?.detail(s) })
                try cam.connect(attempts: candidates.count > 1 ? 2 : 5)
            } catch {
                detail("  \(error.localizedDescription)")
                continue
            }
            camera = cam
            defaults.set(path, forKey: "lastPort")
            logLine("Connected on \(path).")
            ui {
                self.connected = true
                self.statusText = "Connected (\((path as NSString).lastPathComponent))"; self.statusOK = true
            }
            try readSettings()
            try listPictures()
            return
        }
        throw CameraError("Camera not found. Check the cable, the batteries, and that the lens cover is open.")
    }

    // MARK: - Status and settings

    private func readSettings() throws {
        let cam = try requireCamera()
        let st: CameraStatus
        do { st = try cam.status() } catch {
            logLine("Could not read camera settings: \(error.localizedDescription)")
            return
        }
        ui {
            if st.resolution < 3 { self.resolution = st.resolution }
            if st.flash < 3 { self.flash = st.flash }
            if st.focus < 3 { self.focus = st.focus }
            if st.zoom <= 6 { self.zoom = st.zoom }
            self.timer = st.timer
        }
        if Calendar.current.component(.year, from: st.clock) < 2000 {
            logLine("The camera clock is not set. Click \"Sync Clock\" so new photos get dates.")
        }
        show(st)
        detail("  status bytes 20-31: " + hex(st.raw[20..<32]))
    }

    private func show(_ st: CameraStatus) {
        let clock = Calendar.current.component(.year, from: st.clock) >= 2000
            ? DateFormatter.localizedString(from: st.clock, dateStyle: .short, timeStyle: .short) : "not set"
        let battery = st.battery == 0 ? "Good" : st.battery == 1 ? "Low" : "? (code \(st.battery))"
        ui {
            self.zoomLocked = st.zoomLocked
            self.cameraInfo = "Battery: \(battery)\nSpace left: \(st.picturesLeft) picture(s)\nCamera clock: \(clock)"
        }
        if st.battery == 1 && !warnedBattery {
            warnedBattery = true
            logLine("Camera batteries are low. Replace them soon; a transfer can fail on weak batteries.")
        }
    }

    private func refreshStatus() {
        guard let cam = camera, let st = try? cam.status() else { return }
        show(st)
    }

    private func control(_ label: String, _ shown: String, _ body: @escaping (Camera) throws -> Void) {
        run {
            let cam = try self.requireCamera()
            try body(cam)
            self.logLine("\(label): \(shown)")
            self.refreshStatus()
        }
    }

    static let resolutionNames = ["Superfine", "Fine", "Normal"]
    static let flashNames = ["Auto", "Fill (on)", "Off"]
    static let focusNames = ["Multi-spot", "Single-spot", "Macro"]

    func setResolution(_ v: Int) { resolution = v; control("Resolution", Self.resolutionNames[v]) { try $0.setResolution(v) } }
    func setFlash(_ v: Int) { flash = v; control("Flash", Self.flashNames[v]) { try $0.setFlash(v) } }
    func setFocus(_ v: Int) { focus = v; control("Focus", Self.focusNames[v]) { try $0.setFocus(v) } }
    func setZoom(_ v: Int) {
        guard !zoomLocked else { return }
        zoom = v; control("Zoom", "\(v)") { try $0.setZoomLevel(v) }
    }
    func setTimer(_ on: Bool) { timer = on; control("Self-timer", on ? "on" : "off") { try $0.setTimer(on) } }

    func syncClock() {
        run {
            let cam = try self.requireCamera()
            try cam.setClock()
            let st = try cam.status()
            self.logLine("Camera clock set to " +
                         DateFormatter.localizedString(from: st.clock, dateStyle: .medium, timeStyle: .medium) + ".")
            self.show(st)
        }
    }

    func takePicture() {
        let res = resolution, withTimer = timer
        run {
            let cam = try self.requireCamera()
            self.logLine("Taking picture" + (withTimer ? " (self-timer)…" : "…"))
            try cam.shoot(resolution: res)
            self.logLine("Picture taken.")
            try self.listPictures()
            self.refreshStatus()
        }
    }

    func eraseAll() {
        run {
            let cam = try self.requireCamera()
            self.logLine("Erasing all pictures (a few minutes with a full card)…")
            try cam.eraseAll()
            self.logLine("Camera erased.")
            var pics: [PictureInfo] = []
            for _ in 0..<12 {                      // camera reports old pictures for a few seconds
                pics = cam.listPictures()
                if pics.isEmpty { break }
                usleep(1_500_000)
            }
            let remaining = pics
            self.ui {
                self.pictures = remaining; self.saved = [:]; self.thumbs = [:]; self.selection = []
                self.preview = nil; self.previewPlaceholder = "Camera is empty."; self.caption = ""
            }
            self.logLine("\(pics.count) picture(s) in camera.")
            self.refreshStatus()
        }
    }

    // MARK: - Picture list

    private func baseURL(_ p: PictureInfo, dir: URL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = p.taken.map { f.string(from: $0) } ?? "\(f.string(from: Date()))_\(String(format: "%02d", p.number))"
        return dir.appendingPathComponent("ES3000_\(stamp)_\(p.resolution.code)")
    }

    /// Finds pictures already downloaded earlier (dated pictures only, matched by file name).
    private func findSaved(_ pics: [PictureInfo], dir: URL, format: ImageFormat, previous: [Int: URL]) -> [Int: URL] {
        var out: [Int: URL] = [:]
        let fm = FileManager.default
        for p in pics {
            if let u = previous[p.number], fm.fileExists(atPath: u.path) { out[p.number] = u; continue }
            guard p.taken != nil else { continue }
            let base = baseURL(p, dir: dir)
            for ext in [format.ext] + ImageFormat.allCases.map(\.ext) {
                let u = base.appendingPathExtension(ext)
                if fm.fileExists(atPath: u.path) { out[p.number] = u; break }
            }
        }
        return out
    }

    func refreshList() { run { try self.listPictures() } }

    private func listPictures() throws {
        let cam = try requireCamera()
        let old = onMain { pictures }
        var pics = cam.listPictures()
        if pics.isEmpty && !old.isEmpty {
            usleep(1_500_000)                      // camera may still be busy; try once more
            pics = cam.listPictures()
        }
        let sameAsBefore = pics.map(\.number) == old.prefix(pics.count).map(\.number)
            && zip(pics, old).allSatisfy { $0.taken == $1.taken && $0.resolution == $1.resolution }
        let (dir, fmt, prevSaved) = onMain { (photoDir, format, sameAsBefore ? saved : [:]) }
        let found = findSaved(pics, dir: dir, format: fmt, previous: prevSaved)
        let result = pics
        ui {
            if !sameAsBefore { self.thumbs = [:] }
            self.pictures = result
            self.saved = found
            self.selection = self.selection.filter { n in result.contains { $0.number == n } }
        }
        let fresh = pics.filter { found[$0.number] == nil }.count
        logLine("\(pics.count) picture(s) in camera" + (pics.isEmpty ? "." : ", \(fresh) not downloaded yet."))
        let have = onMain { Set(thumbs.keys) }
        let missing = pics.filter { !have.contains($0.number) || !sameAsBefore }
        if !missing.isEmpty { ui { self.loadThumbnails(missing) } }
    }

    private func loadThumbnails(_ pics: [PictureInfo]) {
        let baud = fastBaud
        run(background: true) {
            let cam = try self.requireCamera()
            cam.fastBaud = baud
            let byNumber = Dictionary(uniqueKeysWithValues: pics.map { ($0.number, $0) })
            try cam.thumbnails(pics.map(\.number), cancel: { self.cancelThumbs }) { n, data in
                guard let p = byNumber[n], let dec = self.decoder else { return }
                do {
                    let img = try dec.decodeThumbnail(Data(data), resolution: p.resolution).cgImage
                    self.ui { self.thumbs[n] = img }
                } catch {
                    self.detail("thumbnail \(n): \(error.localizedDescription)")
                }
            }
            self.afterTransfer(cam)
        }
    }

    private func afterTransfer(_ cam: Camera) {
        ui {
            if cam.fastBaud == 57600 && self.fastBaud != 57600 {
                self.logLine("This camera or cable doesn't support 115200 baud; switched back to Standard.")
                self.fastBaud = 57600
            }
        }
    }

    /// Thumbnail for the list, with the saved file's rotation applied.
    func listThumbnail(_ n: Int) -> CGImage? {
        guard let t = thumbs[n] else { return nil }
        if let u = saved[n], let r = rotations[u.path], r != 0 { return t.rotated(by: r) }
        return t
    }

    // MARK: - Download

    enum Which { case new, all, selected }

    func download(_ which: Which) {
        let chosen: [PictureInfo]
        switch which {
        case .all: chosen = pictures
        case .new:
            chosen = pictures.filter { saved[$0.number] == nil }
            if chosen.isEmpty && !pictures.isEmpty { logLine("Nothing new: every picture is already downloaded."); return }
        case .selected:
            chosen = pictures.filter { selection.contains($0.number) }
            if chosen.isEmpty { logLine("Select a picture first."); return }
        }
        let dir = photoDir, fmt = format, keep = keepDCT, baud = fastBaud, listEmpty = pictures.isEmpty
        run {
            let cam = try self.requireCamera()
            guard let dec = self.decoder else { throw CameraError("The picture decoder is not available.") }
            cam.fastBaud = baud
            var todo = chosen
            if listEmpty {
                try self.listPictures()
                todo = self.onMain { which == .new ? self.pictures.filter { self.saved[$0.number] == nil } : self.pictures }
            }
            if todo.isEmpty { self.logLine("No pictures to download."); return }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let total = Double(todo.reduce(0) { $0 + $1.resolution.transferSize })
            var done = 0
            let t0 = Date()
            for (i, p) in todo.enumerated() {
                self.logLine("Downloading picture \(p.number) (\(p.resolution.name)) [\(i + 1)/\(todo.count)]…")
                let base = done
                let dct = try cam.downloadDCT(p.number, resolution: p.resolution) { bytes in
                    self.ui { self.progress = Double(base + bytes) / total }
                }
                done += p.resolution.transferSize
                let baseURL = self.baseURL(p, dir: dir)
                let dctURL = baseURL.appendingPathExtension("DCT")
                let imgURL = baseURL.appendingPathExtension(fmt.ext)
                if keep { try dct.write(to: dctURL) }
                let (rgb, _) = try dec.decode(dct)
                guard let cg = rgb.cgImage else { throw CameraError("Could not build the picture.") }
                try cg.save(to: imgURL, format: fmt)
                if let t = p.taken {
                    for u in keep ? [dctURL, imgURL] : [imgURL] {
                        try? FileManager.default.setAttributes([.modificationDate: t, .creationDate: t], ofItemAtPath: u.path)
                    }
                }
                self.ui {
                    self.rotations[imgURL.path] = nil
                    self.saved[p.number] = imgURL
                    self.preview = cg
                    self.caption = String(format: "#%02d  ", p.number) + imgURL.lastPathComponent
                }
                self.logLine("  saved \(imgURL.lastPathComponent)")
            }
            let secs = max(Date().timeIntervalSince(t0), 0.1)
            self.logLine(String(format: "Download finished: %d picture(s) in %.0f s (%.1f KB/s at %d baud).",
                                todo.count, secs, Double(done) / secs / 1024, cam.fastBaud))
            self.afterTransfer(cam)
        }
    }

    // MARK: - Preview, rotate, info

    func selectionChanged() {
        guard let n = selection.sorted().first, let p = pictures.first(where: { $0.number == n }) else { return }
        if let u = saved[n], let img = CGImage.load(u) {
            preview = img
            caption = String(format: "#%02d  ", n) + u.lastPathComponent
        } else if let t = thumbs[n] {
            preview = t
            caption = String(format: "#%02d  ", n) + "camera thumbnail (double-click to download the full picture)"
        } else {
            preview = nil
            previewPlaceholder = "Picture \(p.number) is not downloaded yet.\nDouble-click it to download and view it."
            caption = ""
        }
    }

    func rotate(_ degrees: Int) {
        guard let n = selection.sorted().first, let path = saved[n] else {
            logLine("Rotate works on downloaded pictures. Select one in the list first.")
            return
        }
        let angle = (((rotations[path.path] ?? 0) + degrees) % 360 + 360) % 360
        let dctURL = path.deletingPathExtension().appendingPathExtension("DCT")
        let fmt = ImageFormat.allCases.first { $0.ext == path.pathExtension.lowercased() } ?? .png
        do {
            let img: CGImage
            if FileManager.default.fileExists(atPath: dctURL.path), let dec = decoder,
               let cg = try dec.decode(Data(contentsOf: dctURL)).0.cgImage {
                img = cg.rotated(by: angle)          // re-decode the original: no quality loss
            } else if let cur = CGImage.load(path) {
                img = cur.rotated(by: degrees)
            } else {
                throw CameraError("Cannot open \(path.lastPathComponent).")
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
            try img.save(to: path, format: fmt)
            if let m = attrs?[.modificationDate] as? Date {
                try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: path.path)
            }
            rotations[path.path] = angle == 0 ? nil : angle
            preview = img
            caption = String(format: "#%02d  ", n) + path.lastPathComponent
            objectWillChange.send()
        } catch {
            alert = "Could not rotate \(path.lastPathComponent):\n\(error.localizedDescription)"
        }
    }

    func pictureInfoText() -> String? {
        guard let n = selection.sorted().first, let p = pictures.first(where: { $0.number == n }) else {
            logLine("Select a picture in the list first.")
            return nil
        }
        let size = p.resolution == .normal ? "320 × 240" : "640 × 480"
        var lines = ["Picture #\(n)", "Quality: \(p.resolution.name) (\(size) pixels)"]
        if let t = p.taken {
            lines.append("Taken: " + DateFormatter.localizedString(from: t, dateStyle: .full, timeStyle: .medium))
        } else {
            lines.append("Taken: unknown (the camera clock was not set)")
        }
        if p.dataSize > 0 { lines.append("Data size in camera: \(p.dataSize.formatted()) bytes") }
        if let u = saved[n] {
            lines.append("Saved as: \(u.path)")
            if let r = rotations[u.path] { lines.append("Rotated \(r)° (the .DCT original is unchanged)") }
        } else {
            lines.append("Not downloaded yet")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Folder and conversion

    func choosePhotoFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = photoDir
        if panel.runModal() == .OK, let u = panel.url {
            photoDir = u
            saved = findSaved(pictures, dir: u, format: format, previous: [:])
        }
    }

    func openPhotoFolder() {
        try? FileManager.default.createDirectory(at: photoDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(photoDir)
    }

    func chooseAndConvert() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose Chinon .DCT files to convert"
        if let dct = UTType(filenameExtension: "dct") { panel.allowedContentTypes = [dct] }
        if panel.runModal() == .OK { convert(panel.urls) }
    }

    /// Converts .DCT files next to themselves in the chosen image format.
    func convert(_ urls: [URL]) {
        let files = urls.filter { $0.pathExtension.lowercased() == "dct" }
        guard !files.isEmpty else { return }
        guard let dec = decoder else { alert = "The picture decoder is not available."; return }
        let fmt = format
        DispatchQueue.global(qos: .userInitiated).async {
            for f in files {
                do {
                    let (rgb, res) = try dec.decode(Data(contentsOf: f))
                    guard let cg = rgb.cgImage else { continue }
                    let out = f.deletingPathExtension().appendingPathExtension(fmt.ext)
                    try cg.save(to: out, format: fmt)
                    self.ui {
                        self.rotations[out.path] = nil
                        self.preview = cg
                        self.caption = out.lastPathComponent
                    }
                    self.logLine("Converted \(f.lastPathComponent) (\(res.name)) → \(out.lastPathComponent)")
                } catch {
                    self.logLine("Could not convert \(f.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    func shutdown() {
        let sem = DispatchSemaphore(value: 0)
        cancelThumbs = true
        queue.async { self.camera?.close(); self.camera = nil; sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }
}
