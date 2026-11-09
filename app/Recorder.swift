// Recorder.swift – starts ffmpeg and shows how it's doing. The frames themselves are pushed
// into ffmpeg's stdin by the C core (core.c) on its own thread. Same parameters as record.sh:
// lossless FFV1, every frame on its own, 16 slices with checksums, top field first.
//
// Flow: Record -> Stop -> watch (looping in the window) -> Save or Discard.
// Until then the recording only lives in the app's work folder. Only the save dialog sets
// place and name; then name.mp4 is made for watching and name.mkv as the lossless original.

import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class Recorder {
    static let shared = Recorder()

    private(set) var isRecording = false
    private(set) var isFinishing = false        // Stop pressed, ffmpeg is still finishing the file
    private(set) var elapsed = "00:00:00"
    private(set) var size = "0.0 GB"
    private(set) var freeGB = 0
    private(set) var lostFrames = 0
    private(set) var message: String?
    private(set) var isPlaying = false          // window shows the finished recording instead of live
    private(set) var isUnsaved = false          // done recording, not decided yet
    private(set) var isConverting = false
    private(set) var progress: Int?             // percent while converting, nil = unknown
    private(set) var savedURL: URL?             // the finished .mp4
    // An HDMI-to-AV converter squashes the Mac's 16:9 into 4:3. Measured on the picture: the full
    // 720x576 is 16:9 (pixels 64:45). Display only: the pixels in the .mkv stay as they come in.
    var widescreen = UserDefaults.standard.object(forKey: "widescreen") as? Bool ?? true {
        didSet { UserDefaults.standard.set(widescreen, forKey: "widescreen") }
    }

    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    private static let minFreeGB = 1            // stop below this, before the disk is completely full
    private static let folderKey = "saveFolder"

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var done: DispatchSemaphore?
    @ObservationIgnored private var log: URL?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var player: Process?
    @ObservationIgnored private var playerTimer: Timer?
    @ObservationIgnored private var converter: Process?
    @ObservationIgnored private var converterDone: DispatchSemaphore?
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var duration = 0.0  // seconds of the unsaved recording

    private var workFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "easycap")
    }
    private var rawFile: URL { workFolder.appendingPathComponent("recording.mkv") }
    private var convertedFile: URL { workFolder.appendingPathComponent("converting.mp4") }

    private func fileSize(_ u: URL) -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return (a?[.size] as? Int64) ?? 0
    }

    // At app launch: a recording nobody has decided about yet is never lost.
    func restore() {
        guard fileSize(rawFile) > 0 else { return }
        isUnsaved = true
        duration = 0
        startPlayback()
    }

    func toggle() {
        if isRecording { stop() } else if isUnsaved { save() } else { start() }
    }

    func start() {
        guard !isRecording, !isFinishing, !isPlaying, !isUnsaved, !isConverting else { return }
        message = nil
        savedURL = nil
        do {
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        } catch {
            message = "Can't create the work folder"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: Self.ffmpeg) else {
            message = "ffmpeg not found"
            return
        }
        let free = freeSpaceGB()
        guard free > Self.minFreeGB else {
            message = "Only \(free) GB free"
            return
        }
        try? FileManager.default.removeItem(at: rawFile)

        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("easycap-ffmpeg-\(ProcessInfo.processInfo.processIdentifier).log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-nostdin",
            "-f", "rawvideo", "-pixel_format", "yuyv422", "-video_size", "720x576", "-framerate", "25", "-i", "-",
            "-vf", "setparams=field_mode=tff:range=tv:colorspace=bt470bg:color_primaries=bt470bg:color_trc=smpte170m,setsar=\(widescreen ? "64/45" : "59/54")",
            "-c:v", "ffv1", "-level", "3", "-g", "1", "-slices", "16", "-slicecrc", "1", "-context", "1",
            "-pix_fmt", "yuv422p",
            "-color_range", "tv", "-colorspace", "bt470bg", "-color_primaries", "bt470bg", "-color_trc", "smpte170m",
            rawFile.path,
        ]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = (try? FileHandle(forWritingTo: logFile)) ?? FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }

        do {
            try p.run()
        } catch {
            message = "ffmpeg won't start"
            return
        }
        // The read end only for ffmpeg, otherwise the writer thread never notices when ffmpeg dies.
        // The core gets its own copy of the write end and closes it itself at the end.
        try? pipe.fileHandleForReading.close()
        let fd = dup(pipe.fileHandleForWriting.fileDescriptor)
        try? pipe.fileHandleForWriting.close()
        guard fd >= 0, core_rec_start(fd) == 0 else {
            if fd >= 0 { close(fd) }
            p.terminate()
            message = "Recording won't start"
            return
        }

        process = p
        done = sem
        log = logFile
        isRecording = true
        freeGB = free
        lostFrames = 0
        elapsed = "00:00:00"
        size = "0.0 GB"
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        guard isRecording, !isFinishing else { return }
        let s = Int(core_rec_frames()) / 25
        elapsed = String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        size = String(format: "%.1f GB", Double(fileSize(rawFile)) / 1e9)
        freeGB = freeSpaceGB()
        lostFrames = Int(core_rec_lost())

        if core_rec_active() == 0 {
            stop()                              // ffmpeg quit, the reason shows up in the status bar afterwards
        } else if freeGB < Self.minFreeGB {
            stop(reason: "Disk almost full, recording stopped")
        }
    }

    func stop(reason: String? = nil) {
        guard isRecording, !isFinishing else { return }
        isFinishing = true
        timer?.invalidate()
        timer = nil
        let sem = done
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            core_rec_stop()
            sem?.wait()
            DispatchQueue.main.async { [self] in finished(reason: reason) }
        }
    }

    // When the app quits: the main thread may wait here, otherwise the process would be gone first.
    // The recording stays in the work folder and shows up again at the next launch.
    func stopAndWait() {
        if isConverting {
            cancelled = true
            converter?.terminate()
            _ = converterDone?.wait(timeout: .now() + 5)
            try? FileManager.default.removeItem(at: convertedFile)
        }
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        core_rec_stop()
        _ = done?.wait(timeout: .now() + 30)
    }

    private func finished(reason: String?) {
        let code = process?.terminationStatus ?? 0
        var text = reason
        if code != 0, text == nil {
            let lines = (log.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                .split(separator: "\n")
            text = "ffmpeg: " + (lines.last.map(String.init) ?? "error \(code)")
        }
        let exists = fileSize(rawFile) > 0
        if !exists, text == nil { text = "Nothing recorded" }
        message = text
        if let l = log { try? FileManager.default.removeItem(at: l) }
        duration = Double(core_rec_frames()) / 25
        process = nil
        done = nil
        log = nil
        isRecording = false
        isFinishing = false
        if exists {
            isUnsaved = true
            startPlayback()
        }
    }

    // ------------------------------------------------------------ Playback --

    // FFV1 doesn't open in QuickTime, so the app plays the recording itself, looping, through
    // the same display as the live picture. ffmpeg only unpacks it, nothing else changes.
    private func startPlayback() {
        guard isUnsaved, !isRecording, !isFinishing, !isPlaying else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-stream_loop", "-1", "-i", rawFile.path,
            "-f", "rawvideo", "-pix_fmt", "yuyv422", "-",
        ]
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            message = "Playback won't start"
            return
        }
        try? pipe.fileHandleForWriting.close()
        let fd = dup(pipe.fileHandleForReading.fileDescriptor)
        try? pipe.fileHandleForReading.close()
        guard fd >= 0, core_play_start(fd) == 0 else {
            if fd >= 0 { close(fd) }
            p.terminate()
            message = "Playback won't start"
            return
        }
        player = p
        isPlaying = true
        playerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if core_play_active() == 0 { self?.backToLive() }
        }
    }

    func backToLive() {
        guard isPlaying else { return }
        playerTimer?.invalidate()
        playerTimer = nil
        player?.terminate()
        core_play_stop()
        player = nil
        isPlaying = false
    }

    // -------------------------------------------------------- Save, discard --

    // The name stays empty: only a person picks it. Cancel changes nothing.
    func save() {
        guard isUnsaved, !isConverting else { return }
        let panel = NSSavePanel()
        panel.title = "Save recording"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ""
        let last = UserDefaults.standard.string(forKey: Self.folderKey)
        panel.directoryURL = last.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        UserDefaults.standard.set(target.deletingLastPathComponent().path, forKey: Self.folderKey)
        convert(to: target)
    }

    func discard() {
        guard isUnsaved, !isConverting else { return }
        let a = NSAlert()
        a.messageText = "Discard recording?"
        a.informativeText = "It will be deleted permanently."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Discard")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        backToLive()
        try? FileManager.default.removeItem(at: rawFile)
        isUnsaved = false
        message = nil
    }

    // For the .mp4 the fields are filled up to 50 frames/s, otherwise players show combing.
    // Everything stays in the work folder and only moves to the target when done: never half files there.
    private func convert(to target: URL) {
        backToLive()
        message = nil
        isUnsaved = false
        isConverting = true
        progress = duration > 0 ? 0 : nil
        cancelled = false
        try? FileManager.default.removeItem(at: convertedFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-nostdin", "-progress", "pipe:1",
            "-i", rawFile.path,
            "-vf", "bwdif=mode=send_field:parity=tff," + (widescreen ? "scale=1024:576:flags=lanczos,setsar=1" : "setsar=59/54"),
            "-c:v", "libx264", "-preset", "fast", "-crf", "14", "-pix_fmt", "yuv420p",
            "-color_range", "tv", "-colorspace", "bt470bg", "-color_primaries", "bt470bg", "-color_trc", "smpte170m",
            "-movflags", "+faststart", convertedFile.path,
        ]
        let pipe = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .utility
        let total = duration
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard total > 0, let text = String(data: h.availableData, encoding: .utf8),
                  let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }),
                  let us = Double(line.dropFirst("out_time_us=".count)) else { return }
            let percent = min(max(Int(us / 1e6 / total * 100), 0), 99)
            DispatchQueue.main.async { self?.progress = percent }
        }
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { [weak self] q in
            pipe.fileHandleForReading.readabilityHandler = nil
            sem.signal()
            guard let self, !self.cancelled else { return }
            let code = q.terminationStatus
            DispatchQueue.global(qos: .userInitiated).async {      // copying to another disk can take a while
                let error = code == 0 ? self.moveIntoPlace(at: target) : "Conversion failed"
                DispatchQueue.main.async { self.converted(target: target, error: error) }
            }
        }
        do {
            try p.run()
        } catch {
            isConverting = false
            isUnsaved = true
            message = "ffmpeg won't start"
            return
        }
        converter = p
        converterDone = sem
    }

    // Returns the text for the status bar on errors
    private func moveIntoPlace(at target: URL) -> String? {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }   // the dialog already asked about overwriting
            try fm.moveItem(at: convertedFile, to: target)
        } catch {
            return "Can't save the video there"
        }
        let folder = target.deletingLastPathComponent()
        let name = target.deletingPathExtension().lastPathComponent
        var original = folder.appendingPathComponent(name + ".mkv")
        var n = 2
        while fm.fileExists(atPath: original.path) {        // never overwrite an old original
            original = folder.appendingPathComponent("\(name) \(n).mkv")
            n += 1
        }
        do {
            try fm.moveItem(at: rawFile, to: original)
        } catch {
            return "Can't save the original (.mkv) there"
        }
        return nil
    }

    private func converted(target: URL, error: String?) {
        converter = nil
        converterDone = nil
        isConverting = false
        progress = nil
        message = error
        if FileManager.default.fileExists(atPath: target.path), error == nil { savedURL = target }
        if fileSize(rawFile) > 0 {                  // error: the recording is still there, trying again works
            isUnsaved = true
            startPlayback()
        }
    }

    func openVideo() {
        if let f = savedURL { NSWorkspace.shared.open(f) }
    }

    func showInFinder() {
        if let f = savedURL { NSWorkspace.shared.activateFileViewerSelecting([f]) }
    }

    private func freeSpaceGB() -> Int {
        let path = FileManager.default.fileExists(atPath: workFolder.path) ? workFolder.path : NSHomeDirectory()
        let a = try? FileManager.default.attributesOfFileSystem(forPath: path)
        let n = (a?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return Int(n / 1_000_000_000)
    }
}
