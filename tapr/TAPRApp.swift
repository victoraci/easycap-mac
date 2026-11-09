// TAPRApp.swift – TAPR: VHS rein in den Mac. Fenster mit dem Live-Bild vom ezcap 116.
// Der Stick-Code (hw.c + kern.c) laeuft direkt in der App, in einem eigenen Thread.
//
// Hinweis Bauen: Mit dem SDK 27 ist SwiftUIs @State ein Makro, dessen Plugin den
// Command Line Tools fehlt. Zustand deshalb ueber @Observable (Plugin ist dabei).

import SwiftUI
import CoreText

@main
struct TAPRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let stick = Stick()

    init() {
        // Inter liegt in der App (Contents/Resources), nicht im System
        if let url = Bundle.main.url(forResource: "Inter", withExtension: "woff2") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        Window("TAPR", id: "main") {
            Hauptfenster(stick: stick)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 800)        // Bild 16:9 + Regler-Leiste
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var echtzeit: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Sonst bremst macOS die App ("App Nap"), sobald das Fenster verdeckt ist. Dann kaemen
        // die USB-Pakete zu spaet dran und gingen verloren – schlecht vor allem beim Aufnehmen.
        echtzeit = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Live-Video vom ezcap")
        tapr_start()
        Aufnahme.shared.wiederherstellen()      // noch nicht gespeicherte Aufnahme vom letzten Mal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.fensterHolen() }
    }

    // Der HDMI2AV meldet sich als normaler Bildschirm. Beim Start kann das Fenster deshalb dort
    // landen, wo man es nicht sieht: dann auf den groessten echten Monitor holen. Spaeter von
    // Hand rueberziehen (Feedback-Loop) geht weiter.
    private func fensterHolen() {
        let istWandler = { (s: NSScreen) in s.localizedName.uppercased().contains("MACROSILICON") }
        guard let f = NSApp.windows.first(where: { $0.title == "TAPR" }) else { return }
        if let s = f.screen, !istWandler(s) { return }
        let echte = NSScreen.screens.filter { !istWandler($0) }
        guard let ziel = echte.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let v = ziel.visibleFrame
        let w = min(1600, v.width), h = min(800, v.height)
        f.setFrame(NSRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h), display: true)
        f.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ n: Notification) {
        Aufnahme.shared.zurueckZuLive()
        Aufnahme.shared.stoppenUndWarten()      // laufende Aufnahme sauber abschliessen
        tapr_stop()                             // Stick sauber freigeben
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

struct Hauptfenster: View {
    let stick: Stick

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    LiveBild(stick: stick)
                        .aspectRatio(bildSeitenverhaeltnis, contentMode: .fit)
                    if let m = meldung {
                        VStack(spacing: 6) {
                            Text(m.titel)
                                .font(.custom("Inter", size: 15).weight(.medium))
                                .foregroundStyle(Color(white: 0.85))
                            Text(m.text)
                                .font(.custom("Inter", size: 13))
                                .foregroundStyle(Color(white: 0.5))
                        }
                        .multilineTextAlignment(.center)
                        .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Statuszeile(stick: stick)
            }
            ReglerLeiste(stick: stick)
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(Color(white: 0.1))
        .preferredColorScheme(.dark)
    }

    private var meldung: (titel: String, text: String)? {
        if Aufnahme.shared.spielt { return nil }
        switch stick.zustand {
        case TAPR_FEHLT:
            return ("Kein Stick gefunden", "ezcap einstecken, TAPR verbindet sich von selbst.")
        case TAPR_BELEGT:
            return ("Stick ist belegt", "Läuft noch vorschau.sh oder aufnahme.sh?\nSobald die zu sind, verbindet sich TAPR von selbst.")
        default:
            return nil
        }
    }
}

// Eine Zeile unter dem Bild: links der Stick, rechts die Aufnahme. Fehler nur, wenn es welche gibt.
struct Statuszeile: View {
    let stick: Stick

    var body: some View {
        HStack(spacing: 0) {
            if !Aufnahme.shared.spielt {
                Circle()
                    .fill(stick.signal ? Color(red: 0.4, green: 0.78, blue: 0.5) : Color(white: 0.32))
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 8)
            }
            switch Aufnahme.shared.spielt ? -1 : stick.zustand {
            case -1:
                Text("Wiedergabe")
                    .foregroundStyle(Color(white: 0.95))
            case TAPR_LAEUFT:
                Text(stick.signal ? "Signal" : "Kein Signal")
                trenner
                Text("\(stick.halbbilderProSekunde) Halbbilder/s")
                if stick.usbFehler > 0 {
                    trenner
                    Text("\(stick.usbFehler) USB-Fehler")
                }
            case TAPR_BELEGT:
                Text("Stick belegt")
            case TAPR_FEHLT:
                Text("Kein Stick")
            default:
                Text("Verbinde …")
            }
            Spacer(minLength: 12)
            aufnahmeInfo
        }
        .font(.custom("Inter", size: 12).monospacedDigit())    // feste Ziffernbreite, nichts wackelt
        .foregroundStyle(Color(white: 0.6))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    // Beim Aufnehmen: Laufzeit, Dateigroesse, freier Platz. Danach: wo die Datei liegt.
    @ViewBuilder private var aufnahmeInfo: some View {
        let a = Aufnahme.shared
        if a.laeuft {
            Text(a.laufzeit)
                .foregroundStyle(Color(white: 0.95))
            trenner
            Text(a.groesse)
            trenner
            Text("\(a.freiGB) GB frei")
            if a.verloren > 0 {
                trenner
                Text("\(a.verloren) Bilder verloren")
                    .foregroundStyle(Color(white: 0.95))
            }
        } else if let m = a.meldung {
            Text(m)
                .foregroundStyle(Color(white: 0.95))
        } else if let d = a.gespeichert {
            Text("Gespeichert: \(d.lastPathComponent)")
        } else if a.spielt {
            Text("Noch nicht gespeichert")
        }
    }

    private var trenner: some View {
        Text("·")
            .foregroundStyle(Color(white: 0.3))
            .padding(.horizontal, 8)
    }
}
