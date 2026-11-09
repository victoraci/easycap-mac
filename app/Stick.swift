// Stick.swift – what the interface knows about the stick and what it changes on it.
// Polls core.c twice a second. Control changes go straight to core.c and are written
// there on the USB thread. Same keys as the terminal tool ezcap.

import AppKit
import Observation

@Observable
final class Stick {
    private(set) var state = CORE_SEARCHING
    private(set) var signal = false
    private(set) var fieldsPerSecond = 0
    private(set) var usbErrors = 0
    private(set) var regs = [Int](repeating: -1, count: CORE_NREG)     // -1 = not connected
    private(set) var initial = [Int](repeating: -1, count: CORE_NREG)  // defaults at connect time
    var swapFields = false {    // swap fields (f), affects display and recording
        didSet { core_rec_swap(swapFields ? 1 : 0) }
    }
    var showMore = false        // panel: the less common switches are shown
    var interlaced = false      // view: both fields woven together, 25 frames/s, like preview.sh raw
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyMonitor: Any?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, !(e.window is NSPanel),      // typing in the save dialog is not a control
                  e.modifierFlags.isDisjoint(with: [.command, .control, .option]),
                  let c = e.charactersIgnoringModifiers?.lowercased().first,
                  self.handleKey(c) else { return e }
            return nil
        }
    }

    // Only assign on change, otherwise SwiftUI redraws everything every time
    private func poll() {
        let st = Int(core_state()), s = core_signal() != 0
        let r = Int(core_rate()), e = core_usb_errors()
        let rg = (0..<CORE_NREG).map { Int(core_reg(Int32($0))) }
        let ini = (0..<CORE_NREG).map { Int(core_reg_start(Int32($0))) }
        if st != state { state = st }
        if s != signal { signal = s }
        if r != fieldsPerSecond { fieldsPerSecond = r }
        if e != usbErrors { usbErrors = e }
        if rg != regs { regs = rg }
        if ini != initial { initial = ini }
    }

    // ----------------------------------------------------------- Registers --

    var isConnected: Bool { regs[0] >= 0 }

    func value(_ r: Int) -> Int { max(regs[r], 0) }

    // Contrast, saturation and hue are signed: -128 to 127
    func signed(_ r: Int) -> Int { Int(Int8(truncatingIfNeeded: value(r))) }

    func isChanged(_ r: Int, _ mask: Int = 0xff) -> Bool {
        isConnected && (regs[r] ^ initial[r]) & mask != 0
    }

    func set(_ r: Int, _ v: Int) {
        guard isConnected else { return }
        regs[r] = v & 0xff
        core_reg_set(Int32(r), Int32(v & 0xff))
    }

    func setBits(_ r: Int, _ mask: Int, _ bits: Int) { set(r, value(r) & ~mask | bits & mask) }
    func flip(_ r: Int, _ mask: Int) { set(r, value(r) ^ mask) }

    // What counts as "changed": one register and its bits per control, as in ezcap.c
    private static let controlBits: [(Int, Int)] = [
        (CORE_R08, 0x18), (CORE_R08, 0x04), (CORE_R08, 0x03), (CORE_R08, 0xc0),
        (CORE_R03, 0x08), (CORE_R0F, 0x80),
        (CORE_R11, 0x01), (CORE_R09, 0x80), (CORE_R0E, 0x03), (CORE_R0C, 0xff), (CORE_R0D, 0xff),
        (CORE_R0B, 0xff),
    ]

    var changedCount: Int {
        Self.controlBits.filter { isChanged($0.0, $0.1) }.count + (swapFields ? 1 : 0)
    }

    func reset() {
        for r in 0..<CORE_NREG where regs[r] != initial[r] { set(r, initial[r]) }
        swapFields = false
    }

    // ---------------------------------------------------------------- Keys --

    // The same letters as in the terminal (ezcap.c), plus r for the view
    private func handleKey(_ c: Character) -> Bool {
        if Recorder.shared.isPlaying && c != "r" { return false }  // no control acts on playback
        switch c {
        case "s":                                           // TV -> VTR -> fast -> TV
            let htc = (value(CORE_R08) >> 3) & 3
            setBits(CORE_R08, 0x18, (htc == 0 ? 1 : htc == 1 ? 3 : 0) << 3)
        case "p": flip(CORE_R08, 0x04)
        case "v": setBits(CORE_R08, 0x03, value(CORE_R08) + 1)
        case "n": set(CORE_R08, (value(CORE_R08) & ~0x80) ^ 0x40)   // auto off, toggle 50/60
        case "a": flip(CORE_R03, 0x08)
        case "g": flip(CORE_R0F, 0x80)
        case "c": flip(CORE_R11, 0x01)
        case "t": flip(CORE_R09, 0x80)
        case "b": setBits(CORE_R0E, 0x03, value(CORE_R0E) + 1)
        case "u": set(CORE_R0D, value(CORE_R0D) + 32)                 // +45 degrees
        case "i": set(CORE_R0B, -signed(CORE_R0B))
        case "k": set(CORE_R0C, -signed(CORE_R0C))
        case "f": swapFields.toggle()
        case "r": interlaced.toggle()
        case "0": reset()
        default: return false
        }
        return true
    }
}
