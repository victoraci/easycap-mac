// Regler.swift – die Leiste rechts neben dem Bild. Oben Aufnehmen, darunter das, was man im
// Bild sieht: Farbe, Farbton, Kontrast, Zeilen, Senkrecht. Seltenes liegt hinter "Mehr".
// Alle Tasten aus Stick.swift funktionieren weiter, auch fuer das, was hier nicht steht.
// Alles selbst gezeichnet, damit ueberall Inter steht (Mac-Standardelemente nehmen die
// Systemschrift). Was von der Grundeinstellung abweicht, ist hell.

import SwiftUI

private enum Farbe {
    static let leiste = Color(white: 0.125)
    static let text = Color(white: 0.62)
    static let hell = Color(white: 0.95)
    static let leise = Color(white: 0.42)
    static let flaeche = Color(white: 0.165)
    static let gewaehlt = Color(white: 0.28)
    static let spur = Color(white: 0.22)
    static let rec = Color(red: 0.86, green: 0.25, blue: 0.22)
}

private func inter(_ size: CGFloat) -> Font { .custom("Inter", size: size) }

// 100 % = wie beim Verbinden, negativ = invertiert
private func prozent(_ v: Int, _ start: Int) -> String {
    let p = Int((Double(v) * 100 / Double(start == 0 ? 64 : abs(start))).rounded())
    return "\(p) %".replacingOccurrences(of: "-", with: "−")
}

// Farbton: 1,4 Grad pro Schritt
private func grad(_ v: Int) -> String {
    let g = Int((Double(v) * 180 / 128).rounded())
    return g == 0 ? "0°" : (g > 0 ? "+\(g)°" : "−\(-g)°")
}

struct ReglerLeiste: View {
    let stick: Stick

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AufnahmeKnopf(stick: stick)
                .padding(.horizontal, 16)
                .padding(.top, 34)
                .padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Auswahl(titel: "Format", optionen: ["4:3", "16:9"], aktiv: Aufnahme.shared.breitbild ? 1 : 0,
                            verstellt: false) { i in
                        Aufnahme.shared.breitbild = i == 1
                    }
                    schieber("Farbe", TAPR_R0C) { prozent($0, $1) }
                    schieber("Farbton", TAPR_R0D) { v, _ in grad(v) }
                    schieber("Kontrast", TAPR_R0B) { prozent($0, $1) }

                    Auswahl(titel: "Zeilen", optionen: ["Ruhig", "Zittern", "Reißen"], aktiv: zeilen,
                            verstellt: stick.verstellt(TAPR_R08, 0x1c)) { i in
                        let start = max(stick.start[TAPR_R08], 0) & 0x18
                        stick.setzeBits(TAPR_R08, 0x1c, [start, 0x18, start | 0x04][i])
                    }
                    Auswahl(titel: "Senkrecht", optionen: ["Steht", "Springt", "Rollt"], aktiv: senkrecht,
                            verstellt: stick.verstellt(TAPR_R08, 0x03)) { i in
                        stick.setzeBits(TAPR_R08, 0x03, [0, 3, 2][i])
                    }

                    HStack {
                        Text(stick.mehrOffen ? "Weniger" : "Mehr")
                            .contentShape(Rectangle())
                            .onTapGesture { stick.mehrOffen.toggle() }
                        Spacer()
                        if stick.anzahlVerstellt > 0 {
                            Text("Alles zurück")
                                .foregroundStyle(Farbe.hell)
                                .contentShape(Rectangle())
                                .onTapGesture { stick.zuruecksetzen() }
                        }
                    }
                    .font(inter(12))
                    .foregroundStyle(Farbe.text)

                    if stick.mehrOffen { mehr }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            // Die Regler wirken nur live, nicht auf eine fertige Aufnahme
            .opacity(stick.verbunden && !Aufnahme.shared.spielt ? 1 : 0.4)
            .allowsHitTesting(stick.verbunden && !Aufnahme.shared.spielt)
        }
        .frame(width: 240)
        .background(Farbe.leiste)
    }

    private var mehr: some View {
        VStack(alignment: .leading, spacing: 14) {
            Schalter(titel: "Farbmuster", an: stick.wert(TAPR_R09) & 0x80 != 0,
                     verstellt: stick.verstellt(TAPR_R09, 0x80)) { stick.kippe(TAPR_R09, 0x80) }
            Schalter(titel: "Farbrauschen", an: stick.wert(TAPR_R11) & 0x01 != 0,
                     verstellt: stick.verstellt(TAPR_R11, 0x01)) { stick.kippe(TAPR_R11, 0x01) }
            Schalter(titel: "Farbe verschmiert", an: stick.wert(TAPR_R0E) & 0x03 == 0,
                     verstellt: stick.verstellt(TAPR_R0E, 0x03)) {
                let an = stick.wert(TAPR_R0E) & 0x03 == 0
                stick.setzeBits(TAPR_R0E, 0x03, an ? max(stick.start[TAPR_R0E], 0) : 0)
            }
            Schalter(titel: "Helligkeit einfrieren", an: stick.wert(TAPR_R03) & 0x08 != 0,
                     verstellt: stick.verstellt(TAPR_R03, 0x08)) { stick.kippe(TAPR_R03, 0x08) }
            Schalter(titel: "Farbstärke einfrieren", an: stick.wert(TAPR_R0F) & 0x80 != 0,
                     verstellt: stick.verstellt(TAPR_R0F, 0x80)) { stick.kippe(TAPR_R0F, 0x80) }
            Schalter(titel: "Falscher Takt (60 Hz)", an: stick.wert(TAPR_R08) & 0xc0 == 0x40,
                     verstellt: stick.verstellt(TAPR_R08, 0xc0)) {
                let an = stick.wert(TAPR_R08) & 0xc0 == 0x40
                stick.setzeBits(TAPR_R08, 0xc0, an ? max(stick.start[TAPR_R08], 0) : 0x40)
            }
            Schalter(titel: "Bewegung zuckt", an: stick.tauschen, verstellt: stick.tauschen) {
                stick.tauschen.toggle()
            }
            Auswahl(titel: "Ansicht", optionen: ["Röhre", "Verzahnt"], aktiv: stick.verzahnt ? 1 : 0,
                    verstellt: false) { i in
                stick.verzahnt = i == 1
            }
        }
    }

    // Ruhig = Grundeinstellung, Zittern = schnell nachregeln, Reissen = Regelung offen.
    // Der TV-Modus (nur Taste s) zeigt keine der drei Stufen.
    private var zeilen: Int? {
        let r = stick.wert(TAPR_R08), htc = r & 0x18
        if r & 0x04 != 0 { return 2 }
        if htc == 0x18 { return 1 }
        return htc == max(stick.start[TAPR_R08], 0) & 0x18 ? 0 : nil
    }

    // Steht = normal, Springt = Rauschunterdrueckung aus, Rollt = Sync frei. "schnell" nur ueber Taste v.
    private var senkrecht: Int? {
        [0, nil, 2, 1][stick.wert(TAPR_R08) & 0x03]
    }

    private func schieber(_ titel: String, _ r: Int, _ anzeige: @escaping (Int, Int) -> String) -> some View {
        let start = Int(Int8(truncatingIfNeeded: max(stick.start[r], 0)))
        return Schieber(titel: titel, wert: stick.signiert(r), start: start, verstellt: stick.verstellt(r),
                        anzeige: { anzeige($0, start) }) { v in
            stick.setze(r, v)
        }
    }
}

// Der eine grosse Knopf, je nach Lage: Aufnehmen, Stoppen oder Speichern. Laeuft auch dann
// noch, wenn der Stick weg ist, damit man stoppen und speichern kann.
private struct AufnahmeKnopf: View {
    let stick: Stick

    var body: some View {
        let a = Aufnahme.shared
        let frei = (a.laeuft || a.ungespeichert || stick.verbunden) && !a.schliesst && !a.wandeltUm
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if a.wandeltUm {
                    Text(a.fortschritt.map { "Wird umgewandelt … \($0) %" } ?? "Wird umgewandelt …")
                } else if a.schliesst {
                    Text("Wird abgeschlossen …")
                } else if a.ungespeichert {
                    Text("Speichern …")
                } else if a.laeuft {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Farbe.hell)
                        .frame(width: 9, height: 9)
                    Text("Stoppen")
                } else {
                    Circle()
                        .fill(Farbe.rec)
                        .frame(width: 9, height: 9)
                    Text("Aufnehmen")
                }
            }
            .font(inter(13).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(frei ? Farbe.hell : Farbe.text)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 7).fill(a.laeuft && !a.schliesst ? Farbe.rec : Farbe.gewaehlt))
            .contentShape(Rectangle())
            .onTapGesture { a.umschalten() }
            .opacity(frei || a.wandeltUm || a.schliesst ? 1 : 0.4)
            .allowsHitTesting(frei)

            if a.ungespeichert, !a.wandeltUm {
                HStack {
                    Spacer()
                    knopf("Verwerfen") { a.verwerfen() }
                    Spacer()
                }
            } else if a.gespeichert != nil, !a.laeuft, !a.schliesst {
                HStack {
                    knopf("Video öffnen") { a.videoOeffnen() }
                    Spacer()
                    knopf("Im Ordner zeigen") { a.imOrdnerZeigen() }
                }
            }
        }
    }

    private func knopf(_ titel: String, _ tu: @escaping () -> Void) -> some View {
        Text(titel)
            .font(inter(12))
            .foregroundStyle(Farbe.text)
            .contentShape(Rectangle())
            .onTapGesture(perform: tu)
    }
}

// Mehrere feste Stufen nebeneinander, eine ist gewaehlt
private struct Auswahl: View {
    let titel: String
    let optionen: [String]
    let aktiv: Int?
    let verstellt: Bool
    let waehle: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(titel)
                .font(inter(12.5))
                .foregroundStyle(verstellt ? Farbe.hell : Farbe.text)
            HStack(spacing: 2) {
                ForEach(optionen.indices, id: \.self) { i in
                    Text(optionen[i])
                        .font(inter(11.5))
                        .foregroundStyle(i == aktiv ? Farbe.hell : Farbe.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(i == aktiv ? Farbe.gewaehlt : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { waehle(i) }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Farbe.flaeche))
        }
    }
}

// An/aus, die ganze Zeile ist klickbar
private struct Schalter: View {
    let titel: String
    let an: Bool
    let verstellt: Bool
    let umschalten: () -> Void

    var body: some View {
        HStack {
            Text(titel)
                .font(inter(12.5))
                .foregroundStyle(verstellt ? Farbe.hell : Farbe.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            ZStack(alignment: an ? .trailing : .leading) {
                Capsule()
                    .fill(an ? Color(white: 0.78) : Farbe.spur)
                    .frame(width: 24, height: 14)
                Circle()
                    .fill(an ? Color(white: 0.12) : Color(white: 0.5))
                    .frame(width: 10, height: 10)
                    .padding(2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: umschalten)
    }
}

// Stufenlos von −128 bis 127. Der Strich markiert die Null, die Fuellung geht von dort
// bis zum Wert – nach links heisst negativ (invertiert). Doppelklick = Grundeinstellung.
private struct Schieber: View {
    let titel: String
    let wert: Int
    let start: Int
    let verstellt: Bool
    let anzeige: (Int) -> String
    let setzen: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(titel)
                    .font(inter(12.5))
                Spacer(minLength: 4)
                Text(anzeige(wert))
                    .font(inter(12).monospacedDigit())
            }
            .foregroundStyle(verstellt ? Farbe.hell : Farbe.text)
            .lineLimit(1)
            GeometryReader { geo in
                let breite = geo.size.width - 10
                let x = { (v: Int) -> CGFloat in 5 + CGFloat(v + 128) / 255 * breite }
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Farbe.spur)
                        .frame(height: 2)
                        .padding(.horizontal, 5)
                    Rectangle()
                        .fill(verstellt ? Color(white: 0.8) : Color(white: 0.5))
                        .frame(width: abs(x(wert) - x(0)), height: 2)
                        .offset(x: min(x(wert), x(0)))
                    Rectangle()
                        .fill(Color(white: 0.4))
                        .frame(width: 1, height: 8)
                        .offset(x: x(0))
                    Circle()
                        .fill(Color(white: 0.85))
                        .frame(width: 10, height: 10)
                        .offset(x: x(wert) - 5)
                }
                .frame(width: geo.size.width, height: 14)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let v = Int(((g.location.x - 5) / breite * 255).rounded()) - 128
                    setzen(min(max(v, -128), 127))
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { setzen(start) })
            }
            .frame(height: 14)
        }
    }
}
