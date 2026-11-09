// Stick.swift – was die Oberflaeche vom Stick weiss und was sie an ihm verstellt.
// Liest zweimal pro Sekunde aus kern.c. Regler-Wuensche gehen sofort an kern.c,
// geschrieben werden sie dort im USB-Thread. Tasten wie im Terminal-ezcap.

import AppKit
import Observation

@Observable
final class Stick {
    private(set) var zustand = TAPR_SUCHT
    private(set) var signal = false
    private(set) var halbbilderProSekunde = 0
    private(set) var usbFehler = 0
    private(set) var regs = [Int](repeating: -1, count: TAPR_NREG)     // -1 = nicht verbunden
    private(set) var start = [Int](repeating: -1, count: TAPR_NREG)    // Grundeinstellung beim Verbinden
    var tauschen = false {      // Halbbilder tauschen (f), wirkt auf Anzeige und Aufnahme
        didSet { tapr_rec_swap(tauschen ? 1 : 0) }
    }
    var mehrOffen = false       // Leiste: die selteneren Schalter eingeblendet
    var verzahnt = false        // Ansicht: beide Halbbilder ineinander, 25 Bilder/s, wie vorschau.sh roh
    @ObservationIgnored private var takt: Timer?
    @ObservationIgnored private var tasten: Any?

    init() {
        takt = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.abfragen()
        }
        tasten = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, !(e.window is NSPanel),      // Tippen im Speichern-Dialog ist kein Regler
                  e.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                  let c = e.charactersIgnoringModifiers?.lowercased().first,
                  self.taste(c) else { return e }
            return nil
        }
    }

    // Nur bei Aenderung zuweisen, sonst zeichnet SwiftUI jedes Mal alles neu
    private func abfragen() {
        let z = Int(tapr_state()), s = tapr_signal() != 0
        let r = Int(tapr_rate()), f = tapr_usb_errors()
        let rg = (0..<TAPR_NREG).map { Int(tapr_reg(Int32($0))) }
        let st = (0..<TAPR_NREG).map { Int(tapr_reg_start(Int32($0))) }
        if z != zustand { zustand = z }
        if s != signal { signal = s }
        if r != halbbilderProSekunde { halbbilderProSekunde = r }
        if f != usbFehler { usbFehler = f }
        if rg != regs { regs = rg }
        if st != start { start = st }
    }

    // ------------------------------------------------------------ Register --

    var verbunden: Bool { regs[0] >= 0 }

    func wert(_ r: Int) -> Int { max(regs[r], 0) }

    // Kontrast, Saettigung, Farbton sind vorzeichenbehaftet: -128 bis 127
    func signiert(_ r: Int) -> Int { Int(Int8(truncatingIfNeeded: wert(r))) }

    func verstellt(_ r: Int, _ maske: Int = 0xff) -> Bool {
        verbunden && (regs[r] ^ start[r]) & maske != 0
    }

    func setze(_ r: Int, _ v: Int) {
        guard verbunden else { return }
        regs[r] = v & 0xff
        tapr_reg_set(Int32(r), Int32(v & 0xff))
    }

    func setzeBits(_ r: Int, _ maske: Int, _ bits: Int) { setze(r, wert(r) & ~maske | bits & maske) }
    func kippe(_ r: Int, _ maske: Int) { setze(r, wert(r) ^ maske) }

    // Was als "verstellt" zaehlt: je Regler ein Register mit seinen Bits, wie in ezcap.c
    private static let reglerBits: [(Int, Int)] = [
        (TAPR_R08, 0x18), (TAPR_R08, 0x04), (TAPR_R08, 0x03), (TAPR_R08, 0xc0),
        (TAPR_R03, 0x08), (TAPR_R0F, 0x80),
        (TAPR_R11, 0x01), (TAPR_R09, 0x80), (TAPR_R0E, 0x03), (TAPR_R0C, 0xff), (TAPR_R0D, 0xff),
        (TAPR_R0B, 0xff),
    ]

    var anzahlVerstellt: Int {
        Self.reglerBits.filter { verstellt($0.0, $0.1) }.count + (tauschen ? 1 : 0)
    }

    func zuruecksetzen() {
        for r in 0..<TAPR_NREG where regs[r] != start[r] { setze(r, start[r]) }
        tauschen = false
    }

    // -------------------------------------------------------------- Tasten --

    // Dieselben Buchstaben wie im Terminal (ezcap.c), dazu r fuer die Ansicht
    private func taste(_ c: Character) -> Bool {
        if Aufnahme.shared.spielt && c != "r" { return false }  // bei der Wiedergabe wirkt kein Regler
        switch c {
        case "s":                                           // TV -> VTR -> schnell -> TV
            let htc = (wert(TAPR_R08) >> 3) & 3
            setzeBits(TAPR_R08, 0x18, (htc == 0 ? 1 : htc == 1 ? 3 : 0) << 3)
        case "p": kippe(TAPR_R08, 0x04)
        case "v": setzeBits(TAPR_R08, 0x03, wert(TAPR_R08) + 1)
        case "n": setze(TAPR_R08, (wert(TAPR_R08) & ~0x80) ^ 0x40)   // Auto aus, 50/60 umschalten
        case "a": kippe(TAPR_R03, 0x08)
        case "g": kippe(TAPR_R0F, 0x80)
        case "c": kippe(TAPR_R11, 0x01)
        case "t": kippe(TAPR_R09, 0x80)
        case "b": setzeBits(TAPR_R0E, 0x03, wert(TAPR_R0E) + 1)
        case "u": setze(TAPR_R0D, wert(TAPR_R0D) + 32)                // +45 Grad
        case "i": setze(TAPR_R0B, -signiert(TAPR_R0B))
        case "k": setze(TAPR_R0C, -signiert(TAPR_R0C))
        case "f": tauschen.toggle()
        case "r": verzahnt.toggle()
        case "0": zuruecksetzen()
        default: return false
        }
        return true
    }
}
