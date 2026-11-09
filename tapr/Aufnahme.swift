// Aufnahme.swift – startet ffmpeg und zeigt, wie es laeuft. Die Bilder selbst schiebt der
// C-Kern (kern.c) in einem eigenen Thread in die stdin von ffmpeg. Parameter wie aufnahme.sh:
// FFV1 verlustfrei, jedes Bild einzeln, 16 Slices mit Pruefsumme, oberes Halbbild zuerst.
//
// Ablauf: Aufnehmen -> Stoppen -> ansehen (Schleife im Fenster) -> Speichern oder Verwerfen.
// Bis dahin liegt die Aufnahme nur im Arbeitsordner der App. Erst der Speichern-Dialog legt
// Ort und Namen fest; dann entsteht name.mp4 zum Ansehen und name.mkv als verlustfreies Original.

import AppKit
import Observation
import UniformTypeIdentifiers

@Observable
final class Aufnahme {
    static let shared = Aufnahme()

    private(set) var laeuft = false
    private(set) var schliesst = false          // Stopp gedrueckt, ffmpeg schreibt noch fertig
    private(set) var laufzeit = "00:00:00"
    private(set) var groesse = "0,0 GB"
    private(set) var freiGB = 0
    private(set) var verloren = 0
    private(set) var meldung: String?
    private(set) var spielt = false             // Fenster zeigt die fertige Aufnahme statt Live
    private(set) var ungespeichert = false      // fertig aufgenommen, noch nicht entschieden
    private(set) var wandeltUm = false
    private(set) var fortschritt: Int?          // Prozent beim Umwandeln, nil = unbekannt
    private(set) var gespeichert: URL?          // die fertige .mp4
    // Der HDMI2AV drueckt die 16:9 vom Mac auf 4:3. Gemessen am Bild: Das volle 720x576 ist
    // 16:9 (Pixel 64:45). Nur Darstellung: Die Pixel in der .mkv bleiben, wie sie reinkommen.
    var breitbild = UserDefaults.standard.object(forKey: "breitbild") as? Bool ?? true {
        didSet { UserDefaults.standard.set(breitbild, forKey: "breitbild") }
    }

    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    private static let mindestFreiGB = 1        // darunter stoppen, bevor die Platte ganz voll ist
    private static let ordnerSchluessel = "speicherOrdner"

    @ObservationIgnored private var prozess: Process?
    @ObservationIgnored private var fertig: DispatchSemaphore?
    @ObservationIgnored private var log: URL?
    @ObservationIgnored private var takt: Timer?
    @ObservationIgnored private var abspieler: Process?
    @ObservationIgnored private var abspielTakt: Timer?
    @ObservationIgnored private var wandler: Process?
    @ObservationIgnored private var wandlerFertig: DispatchSemaphore?
    @ObservationIgnored private var abgebrochen = false
    @ObservationIgnored private var dauer = 0.0     // Sekunden der ungespeicherten Aufnahme

    private var arbeitsordner: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "TAPR")
    }
    private var roh: URL { arbeitsordner.appendingPathComponent("aufnahme.mkv") }
    private var umwandlung: URL { arbeitsordner.appendingPathComponent("umwandlung.mp4") }

    private func dateigroesse(_ u: URL) -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return (a?[.size] as? Int64) ?? 0
    }

    // Beim App-Start: Eine Aufnahme, ueber die noch nicht entschieden wurde, geht nie verloren.
    func wiederherstellen() {
        guard dateigroesse(roh) > 0 else { return }
        ungespeichert = true
        dauer = 0
        ansehen()
    }

    func umschalten() {
        if laeuft { stoppen() } else if ungespeichert { speichern() } else { starten() }
    }

    func starten() {
        guard !laeuft, !schliesst, !spielt, !ungespeichert, !wandeltUm else { return }
        meldung = nil
        gespeichert = nil
        do {
            try FileManager.default.createDirectory(at: arbeitsordner, withIntermediateDirectories: true)
        } catch {
            meldung = "Arbeitsordner lässt sich nicht anlegen"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: Self.ffmpeg) else {
            meldung = "ffmpeg nicht gefunden"
            return
        }
        let frei = freierPlatzGB()
        guard frei > Self.mindestFreiGB else {
            meldung = "Nur noch \(frei) GB frei"
            return
        }
        try? FileManager.default.removeItem(at: roh)

        let logDatei = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapr-ffmpeg-\(ProcessInfo.processInfo.processIdentifier).log")
        FileManager.default.createFile(atPath: logDatei.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-nostdin",
            "-f", "rawvideo", "-pixel_format", "yuyv422", "-video_size", "720x576", "-framerate", "25", "-i", "-",
            "-vf", "setparams=field_mode=tff:range=tv:colorspace=bt470bg:color_primaries=bt470bg:color_trc=smpte170m,setsar=\(breitbild ? "64/45" : "59/54")",
            "-c:v", "ffv1", "-level", "3", "-g", "1", "-slices", "16", "-slicecrc", "1", "-context", "1",
            "-pix_fmt", "yuv422p",
            "-color_range", "tv", "-colorspace", "bt470bg", "-color_primaries", "bt470bg", "-color_trc", "smpte170m",
            roh.path,
        ]
        let rohr = Pipe()
        p.standardInput = rohr
        p.standardOutput = FileHandle.nullDevice
        p.standardError = (try? FileHandle(forWritingTo: logDatei)) ?? FileHandle.nullDevice
        p.qualityOfService = .userInitiated
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }

        do {
            try p.run()
        } catch {
            meldung = "ffmpeg startet nicht"
            return
        }
        // Lese-Ende nur fuer ffmpeg, sonst merkt der Schreib-Thread nie, wenn ffmpeg stirbt.
        // Das Schreib-Ende bekommt der Kern als eigene Kopie und schliesst es am Ende selbst.
        try? rohr.fileHandleForReading.close()
        let fd = dup(rohr.fileHandleForWriting.fileDescriptor)
        try? rohr.fileHandleForWriting.close()
        guard fd >= 0, tapr_rec_start(fd) == 0 else {
            if fd >= 0 { close(fd) }
            p.terminate()
            meldung = "Aufnahme startet nicht"
            return
        }

        prozess = p
        fertig = sem
        log = logDatei
        laeuft = true
        freiGB = frei
        verloren = 0
        laufzeit = "00:00:00"
        groesse = "0,0 GB"
        takt = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.abfragen()
        }
    }

    private func abfragen() {
        guard laeuft, !schliesst else { return }
        let s = Int(tapr_rec_frames()) / 25
        laufzeit = String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        groesse = String(format: "%.1f GB", Double(dateigroesse(roh)) / 1e9).replacingOccurrences(of: ".", with: ",")
        freiGB = freierPlatzGB()
        verloren = Int(tapr_rec_lost())

        if tapr_rec_active() == 0 {
            stoppen()                           // ffmpeg ist ausgestiegen, Grund steht danach in der Statuszeile
        } else if freiGB < Self.mindestFreiGB {
            stoppen(grund: "Platte fast voll, Aufnahme gestoppt")
        }
    }

    func stoppen(grund: String? = nil) {
        guard laeuft, !schliesst else { return }
        schliesst = true
        takt?.invalidate()
        takt = nil
        let sem = fertig
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            tapr_rec_stop()
            sem?.wait()
            DispatchQueue.main.async { [self] in abgeschlossen(grund: grund) }
        }
    }

    // Beim Beenden der App: Hauptthread darf hier warten, sonst waere der Prozess vorher weg.
    // Die Aufnahme bleibt im Arbeitsordner und taucht beim naechsten Start wieder auf.
    func stoppenUndWarten() {
        if wandeltUm {
            abgebrochen = true
            wandler?.terminate()
            _ = wandlerFertig?.wait(timeout: .now() + 5)
            try? FileManager.default.removeItem(at: umwandlung)
        }
        guard laeuft else { return }
        takt?.invalidate()
        takt = nil
        tapr_rec_stop()
        _ = fertig?.wait(timeout: .now() + 30)
    }

    private func abgeschlossen(grund: String?) {
        let code = prozess?.terminationStatus ?? 0
        var text = grund
        if code != 0, text == nil {
            let zeilen = (log.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
                .split(separator: "\n")
            text = "ffmpeg: " + (zeilen.last.map(String.init) ?? "Fehler \(code)")
        }
        let da = dateigroesse(roh) > 0
        if !da, text == nil { text = "Nichts aufgenommen" }
        meldung = text
        if let l = log { try? FileManager.default.removeItem(at: l) }
        dauer = Double(tapr_rec_frames()) / 25
        prozess = nil
        fertig = nil
        log = nil
        laeuft = false
        schliesst = false
        if da {
            ungespeichert = true
            ansehen()
        }
    }

    // ---------------------------------------------------------- Wiedergabe --

    // FFV1 oeffnet nicht in QuickTime, also zeigt TAPR die Aufnahme selbst, in Dauerschleife und
    // ueber dieselbe Anzeige wie das Live-Bild. ffmpeg packt nur aus, sonst aendert sich nichts.
    private func ansehen() {
        guard ungespeichert, !laeuft, !schliesst, !spielt else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostdin", "-stream_loop", "-1", "-i", roh.path,
            "-f", "rawvideo", "-pix_fmt", "yuyv422", "-",
        ]
        let rohr = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = rohr
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            meldung = "Wiedergabe startet nicht"
            return
        }
        try? rohr.fileHandleForWriting.close()
        let fd = dup(rohr.fileHandleForReading.fileDescriptor)
        try? rohr.fileHandleForReading.close()
        guard fd >= 0, tapr_play_start(fd) == 0 else {
            if fd >= 0 { close(fd) }
            p.terminate()
            meldung = "Wiedergabe startet nicht"
            return
        }
        abspieler = p
        spielt = true
        abspielTakt = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if tapr_play_active() == 0 { self?.zurueckZuLive() }
        }
    }

    func zurueckZuLive() {
        guard spielt else { return }
        abspielTakt?.invalidate()
        abspielTakt = nil
        abspieler?.terminate()
        tapr_play_stop()
        abspieler = nil
        spielt = false
    }

    // ------------------------------------------------- Speichern, Verwerfen --

    // Der Name bleibt leer: Den legt nur der Mensch fest. Abbrechen aendert nichts.
    func speichern() {
        guard ungespeichert, !wandeltUm else { return }
        let panel = NSSavePanel()
        panel.title = "Aufnahme speichern"
        panel.prompt = "Speichern"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ""
        let letzter = UserDefaults.standard.string(forKey: Self.ordnerSchluessel)
        panel.directoryURL = letzter.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let ziel = panel.url else { return }
        UserDefaults.standard.set(ziel.deletingLastPathComponent().path, forKey: Self.ordnerSchluessel)
        umwandeln(nach: ziel)
    }

    func verwerfen() {
        guard ungespeichert, !wandeltUm else { return }
        let a = NSAlert()
        a.messageText = "Aufnahme verwerfen?"
        a.informativeText = "Sie wird endgültig gelöscht."
        a.addButton(withTitle: "Abbrechen")
        a.addButton(withTitle: "Verwerfen")
        guard a.runModal() == .alertSecondButtonReturn else { return }
        zurueckZuLive()
        try? FileManager.default.removeItem(at: roh)
        ungespeichert = false
        meldung = nil
    }

    // Halbbilder werden fuer die .mp4 zu 50 Vollbildern/s aufgefuellt, sonst zeigen Player Kaemme.
    // Alles bleibt erst im Arbeitsordner und wandert erst fertig ans Ziel: nie halbe Dateien dort.
    private func umwandeln(nach ziel: URL) {
        zurueckZuLive()
        meldung = nil
        ungespeichert = false
        wandeltUm = true
        fortschritt = dauer > 0 ? 0 : nil
        abgebrochen = false
        try? FileManager.default.removeItem(at: umwandlung)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.ffmpeg)
        p.arguments = [
            "-hide_banner", "-loglevel", "error", "-nostats", "-nostdin", "-progress", "pipe:1",
            "-i", roh.path,
            "-vf", "bwdif=mode=send_field:parity=tff," + (breitbild ? "scale=1024:576:flags=lanczos,setsar=1" : "setsar=59/54"),
            "-c:v", "libx264", "-preset", "fast", "-crf", "14", "-pix_fmt", "yuv420p",
            "-color_range", "tv", "-colorspace", "bt470bg", "-color_primaries", "bt470bg", "-color_trc", "smpte170m",
            "-movflags", "+faststart", umwandlung.path,
        ]
        let rohr = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = rohr
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .utility
        let gesamt = dauer
        rohr.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard gesamt > 0, let text = String(data: h.availableData, encoding: .utf8),
                  let zeile = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }),
                  let us = Double(zeile.dropFirst("out_time_us=".count)) else { return }
            let prozent = min(max(Int(us / 1e6 / gesamt * 100), 0), 99)
            DispatchQueue.main.async { self?.fortschritt = prozent }
        }
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { [weak self] q in
            rohr.fileHandleForReading.readabilityHandler = nil
            sem.signal()
            guard let self, !self.abgebrochen else { return }
            let code = q.terminationStatus
            DispatchQueue.global(qos: .userInitiated).async {      // Kopieren auf andere Platte kann dauern
                let fehler = code == 0 ? self.ablegen(nach: ziel) : "Umwandeln hat nicht geklappt"
                DispatchQueue.main.async { self.umgewandelt(ziel: ziel, fehler: fehler) }
            }
        }
        do {
            try p.run()
        } catch {
            wandeltUm = false
            ungespeichert = true
            meldung = "ffmpeg startet nicht"
            return
        }
        wandler = p
        wandlerFertig = sem
    }

    // Gibt bei Fehlern den Text fuer die Statuszeile zurueck
    private func ablegen(nach ziel: URL) -> String? {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: ziel.path) { try fm.removeItem(at: ziel) }   // Ueberschreiben hat der Dialog schon gefragt
            try fm.moveItem(at: umwandlung, to: ziel)
        } catch {
            return "Video lässt sich dort nicht speichern"
        }
        let ordner = ziel.deletingLastPathComponent()
        let name = ziel.deletingPathExtension().lastPathComponent
        var original = ordner.appendingPathComponent(name + ".mkv")
        var n = 2
        while fm.fileExists(atPath: original.path) {       // ein altes Original nie ueberschreiben
            original = ordner.appendingPathComponent("\(name) \(n).mkv")
            n += 1
        }
        do {
            try fm.moveItem(at: roh, to: original)
        } catch {
            return "Original (.mkv) lässt sich dort nicht speichern"
        }
        return nil
    }

    private func umgewandelt(ziel: URL, fehler: String?) {
        wandler = nil
        wandlerFertig = nil
        wandeltUm = false
        fortschritt = nil
        meldung = fehler
        if FileManager.default.fileExists(atPath: ziel.path), fehler == nil { gespeichert = ziel }
        if dateigroesse(roh) > 0 {                  // Fehler: Aufnahme ist noch da, nochmal versuchen geht
            ungespeichert = true
            ansehen()
        }
    }

    func videoOeffnen() {
        if let d = gespeichert { NSWorkspace.shared.open(d) }
    }

    func imOrdnerZeigen() {
        if let d = gespeichert { NSWorkspace.shared.activateFileViewerSelecting([d]) }
    }

    private func freierPlatzGB() -> Int {
        let pfad = FileManager.default.fileExists(atPath: arbeitsordner.path) ? arbeitsordner.path : NSHomeDirectory()
        let a = try? FileManager.default.attributesOfFileSystem(forPath: pfad)
        let n = (a?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return Int(n / 1_000_000_000)
    }
}
