// Controls.swift – the panel to the right of the picture. Record at the top, below it what you
// see in the picture: color, hue, contrast, lines, vertical. Less common things sit behind "More".
// All keys from Stick.swift keep working, also for what isn't shown here.
// Everything is drawn by hand so that Inter is used everywhere (standard Mac controls use the
// system font). Whatever differs from the defaults is drawn bright.

import SwiftUI

private enum Palette {
    static let panel = Color(white: 0.125)
    static let text = Color(white: 0.62)
    static let bright = Color(white: 0.95)
    static let dim = Color(white: 0.42)
    static let well = Color(white: 0.165)
    static let selected = Color(white: 0.28)
    static let track = Color(white: 0.22)
    static let rec = Color(red: 0.86, green: 0.25, blue: 0.22)
}

private func inter(_ size: CGFloat) -> Font { .custom("Inter", size: size) }

// 100 % = as at connect time, negative = inverted
private func percent(_ v: Int, _ initial: Int) -> String {
    let p = Int((Double(v) * 100 / Double(initial == 0 ? 64 : abs(initial))).rounded())
    return "\(p) %".replacingOccurrences(of: "-", with: "−")
}

// Hue: 1.4 degrees per step
private func degrees(_ v: Int) -> String {
    let d = Int((Double(v) * 180 / 128).rounded())
    return d == 0 ? "0°" : (d > 0 ? "+\(d)°" : "−\(-d)°")
}

struct ControlPanel: View {
    let stick: Stick

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordButton(stick: stick)
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Segments(title: "Format", options: ["4:3", "16:9"], active: Recorder.shared.widescreen ? 1 : 0,
                             changed: false) { i in
                        Recorder.shared.widescreen = i == 1
                    }
                    slider("Color", CORE_R0C) { percent($0, $1) }
                    slider("Hue", CORE_R0D) { v, _ in degrees(v) }
                    slider("Contrast", CORE_R0B) { percent($0, $1) }

                    Segments(title: "Lines", options: ["Calm", "Jitter", "Tear"], active: lines,
                             changed: stick.isChanged(CORE_R08, 0x1c)) { i in
                        let initial = max(stick.initial[CORE_R08], 0) & 0x18
                        stick.setBits(CORE_R08, 0x1c, [initial, 0x18, initial | 0x04][i])
                    }
                    Segments(title: "Vertical", options: ["Steady", "Jump", "Roll"], active: vertical,
                             changed: stick.isChanged(CORE_R08, 0x03)) { i in
                        stick.setBits(CORE_R08, 0x03, [0, 3, 2][i])
                    }

                    HStack {
                        Text(stick.showMore ? "Less" : "More")
                            .contentShape(Rectangle())
                            .onTapGesture { stick.showMore.toggle() }
                        Spacer()
                        if stick.changedCount > 0 {
                            Text("Reset all")
                                .foregroundStyle(Palette.bright)
                                .contentShape(Rectangle())
                                .onTapGesture { stick.reset() }
                        }
                    }
                    .font(inter(12))
                    .foregroundStyle(Palette.text)

                    if stick.showMore { more }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            // The controls only act on the live picture, not on a finished recording
            .opacity(stick.isConnected && !Recorder.shared.isPlaying ? 1 : 0.4)
            .allowsHitTesting(stick.isConnected && !Recorder.shared.isPlaying)
        }
        .frame(width: 240)
        .background(Palette.panel)
    }

    private var more: some View {
        VStack(alignment: .leading, spacing: 14) {
            Switch(title: "Color pattern", on: stick.value(CORE_R09) & 0x80 != 0,
                   changed: stick.isChanged(CORE_R09, 0x80)) { stick.flip(CORE_R09, 0x80) }
            Switch(title: "Color noise", on: stick.value(CORE_R11) & 0x01 != 0,
                   changed: stick.isChanged(CORE_R11, 0x01)) { stick.flip(CORE_R11, 0x01) }
            Switch(title: "Color smear", on: stick.value(CORE_R0E) & 0x03 == 0,
                   changed: stick.isChanged(CORE_R0E, 0x03)) {
                let on = stick.value(CORE_R0E) & 0x03 == 0
                stick.setBits(CORE_R0E, 0x03, on ? max(stick.initial[CORE_R0E], 0) : 0)
            }
            Switch(title: "Freeze brightness", on: stick.value(CORE_R03) & 0x08 != 0,
                   changed: stick.isChanged(CORE_R03, 0x08)) { stick.flip(CORE_R03, 0x08) }
            Switch(title: "Freeze color level", on: stick.value(CORE_R0F) & 0x80 != 0,
                   changed: stick.isChanged(CORE_R0F, 0x80)) { stick.flip(CORE_R0F, 0x80) }
            Switch(title: "Force 60 Hz", on: stick.value(CORE_R08) & 0xc0 == 0x40,
                   changed: stick.isChanged(CORE_R08, 0xc0)) {
                let on = stick.value(CORE_R08) & 0xc0 == 0x40
                stick.setBits(CORE_R08, 0xc0, on ? max(stick.initial[CORE_R08], 0) : 0x40)
            }
            Switch(title: "Jerky motion", on: stick.swapFields, changed: stick.swapFields) {
                stick.swapFields.toggle()
            }
            Segments(title: "View", options: ["Tube", "Interlaced"], active: stick.interlaced ? 1 : 0,
                     changed: false) { i in
                stick.interlaced = i == 1
            }
        }
    }

    // Calm = defaults, Jitter = fast line locking, Tear = line PLL open.
    // TV mode (key s only) shows none of the three.
    private var lines: Int? {
        let r = stick.value(CORE_R08), htc = r & 0x18
        if r & 0x04 != 0 { return 2 }
        if htc == 0x18 { return 1 }
        return htc == max(stick.initial[CORE_R08], 0) & 0x18 ? 0 : nil
    }

    // Steady = normal, Jump = vertical noise reduction off, Roll = free-running sync. "fast" only via key v.
    private var vertical: Int? {
        [0, nil, 2, 1][stick.value(CORE_R08) & 0x03]
    }

    private func slider(_ title: String, _ r: Int, _ label: @escaping (Int, Int) -> String) -> some View {
        let initial = Int(Int8(truncatingIfNeeded: max(stick.initial[r], 0)))
        return ValueSlider(title: title, value: stick.signed(r), initial: initial, changed: stick.isChanged(r),
                           label: { label($0, initial) }) { v in
            stick.set(r, v)
        }
    }
}

// The one big button, depending on the situation: Record, Stop or Save. Keeps working
// when the stick is gone, so you can still stop and save.
private struct RecordButton: View {
    let stick: Stick

    var body: some View {
        let r = Recorder.shared
        let enabled = (r.isRecording || r.isUnsaved || stick.isConnected) && !r.isFinishing && !r.isConverting
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if r.isConverting {
                    Text(r.progress.map { "Converting … \($0) %" } ?? "Converting …")
                } else if r.isFinishing {
                    Text("Finishing …")
                } else if r.isUnsaved {
                    Text("Save …")
                } else if r.isRecording {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Palette.bright)
                        .frame(width: 9, height: 9)
                    Text("Stop")
                } else {
                    Circle()
                        .fill(Palette.rec)
                        .frame(width: 9, height: 9)
                    Text("Record")
                }
            }
            .font(inter(13).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(enabled ? Palette.bright : Palette.text)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 7).fill(r.isRecording && !r.isFinishing ? Palette.rec : Palette.selected))
            .contentShape(Rectangle())
            .onTapGesture { r.toggle() }
            .opacity(enabled || r.isConverting || r.isFinishing ? 1 : 0.4)
            .allowsHitTesting(enabled)

            if r.isUnsaved, !r.isConverting {
                HStack {
                    Spacer()
                    textButton("Discard") { r.discard() }
                    Spacer()
                }
            } else if r.savedURL != nil, !r.isRecording, !r.isFinishing {
                HStack {
                    textButton("Open video") { r.openVideo() }
                    Spacer()
                    textButton("Show in Finder") { r.showInFinder() }
                }
            }
        }
    }

    private func textButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Text(title)
            .font(inter(12))
            .foregroundStyle(Palette.text)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// Several fixed steps side by side, one of them selected
private struct Segments: View {
    let title: String
    let options: [String]
    let active: Int?
    let changed: Bool
    let select: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(inter(12.5))
                .foregroundStyle(changed ? Palette.bright : Palette.text)
            HStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i])
                        .font(inter(11.5))
                        .foregroundStyle(i == active ? Palette.bright : Palette.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(i == active ? Palette.selected : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { select(i) }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.well))
        }
    }
}

// On/off, the whole row is clickable
private struct Switch: View {
    let title: String
    let on: Bool
    let changed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(inter(12.5))
                .foregroundStyle(changed ? Palette.bright : Palette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? Color(white: 0.78) : Palette.track)
                    .frame(width: 24, height: 14)
                Circle()
                    .fill(on ? Color(white: 0.12) : Color(white: 0.5))
                    .frame(width: 10, height: 10)
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

// Continuous from −128 to 127. The tick marks zero, the fill runs from there to the
// value – to the left means negative (inverted). Double-click = defaults.
private struct ValueSlider: View {
    let title: String
    let value: Int
    let initial: Int
    let changed: Bool
    let label: (Int) -> String
    let set: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(inter(12.5))
                Spacer(minLength: 4)
                Text(label(value))
                    .font(inter(12).monospacedDigit())
            }
            .foregroundStyle(changed ? Palette.bright : Palette.text)
            .lineLimit(1)
            GeometryReader { geo in
                let width = geo.size.width - 10
                let x = { (v: Int) -> CGFloat in 5 + CGFloat(v + 128) / 255 * width }
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.track)
                        .frame(height: 2)
                        .padding(.horizontal, 5)
                    Rectangle()
                        .fill(changed ? Color(white: 0.8) : Color(white: 0.5))
                        .frame(width: abs(x(value) - x(0)), height: 2)
                        .offset(x: min(x(value), x(0)))
                    Rectangle()
                        .fill(Color(white: 0.4))
                        .frame(width: 1, height: 8)
                        .offset(x: x(0))
                    Circle()
                        .fill(Color(white: 0.85))
                        .frame(width: 10, height: 10)
                        .offset(x: x(value) - 5)
                }
                .frame(width: geo.size.width, height: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let v = Int(((g.location.x - 5) / width * 255).rounded()) - 128
                    set(min(max(v, -128), 127))
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { set(initial) })
            }
            .frame(height: 14)
        }
    }
}
