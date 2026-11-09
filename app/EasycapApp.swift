// EasycapApp.swift – easycap: VHS into the Mac. A window with the live picture from the grabber.
// The stick code (hw.c + core.c) runs inside the app, on its own thread.
//
// Build note: with SDK 27, SwiftUI's @State is a macro whose plugin is missing from the
// Command Line Tools. State therefore goes through @Observable (that plugin is included).

import SwiftUI
import CoreText

@main
struct EasycapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let stick = Stick()

    init() {
        // Inter ships inside the app (Contents/Resources), not in the system
        if let url = Bundle.main.url(forResource: "Inter", withExtension: "woff2") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    var body: some Scene {
        Window("easycap", id: "main") {
            MainWindow(stick: stick)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 800)        // 16:9 picture + control panel
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ n: Notification) {
        // Otherwise macOS throttles the app ("App Nap") as soon as the window is covered. USB
        // packets would then be handled too late and get lost – bad above all while recording.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Live video from the grabber")
        core_start()
        Recorder.shared.restore()               // a recording from last time that was never saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.bringWindowIntoView() }
    }

    // An HDMI-to-AV converter shows up as a regular display. At launch the window can land there,
    // where nobody sees it: then move it to the largest real monitor. Dragging it over by hand
    // later (feedback loop) still works.
    private func bringWindowIntoView() {
        let isConverter = { (s: NSScreen) in s.localizedName.uppercased().contains("MACROSILICON") }
        guard let w = NSApp.windows.first(where: { $0.title == "easycap" }) else { return }
        if let s = w.screen, !isConverter(s) { return }
        let real = NSScreen.screens.filter { !isConverter($0) }
        guard let target = real.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
        let v = target.visibleFrame
        let width = min(1600, v.width), height = min(800, v.height)
        w.setFrame(NSRect(x: v.midX - width / 2, y: v.midY - height / 2, width: width, height: height), display: true)
        w.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ n: Notification) {
        Recorder.shared.backToLive()
        Recorder.shared.stopAndWait()           // finish a running recording cleanly
        core_stop()                             // release the stick cleanly
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

struct MainWindow: View {
    let stick: Stick

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    LiveView(stick: stick)
                        .aspectRatio(pictureAspectRatio, contentMode: .fit)
                    if let m = notice {
                        VStack(spacing: 6) {
                            Text(m.title)
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
                StatusBar(stick: stick)
            }
            ControlPanel(stick: stick)
        }
        .frame(minWidth: 680, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(Color(white: 0.1))
        .preferredColorScheme(.dark)
    }

    private var notice: (title: String, text: String)? {
        if Recorder.shared.isPlaying { return nil }
        switch stick.state {
        case CORE_MISSING:
            return ("No stick found", "Plug in the grabber. easycap connects on its own.")
        case CORE_BUSY:
            return ("The stick is in use", "Is preview.sh or record.sh still running?\neasycap connects on its own once they are closed.")
        default:
            return nil
        }
    }
}

// One line below the picture: the stick on the left, the recording on the right. Errors only when there are any.
struct StatusBar: View {
    let stick: Stick

    var body: some View {
        HStack(spacing: 0) {
            if !Recorder.shared.isPlaying {
                Circle()
                    .fill(stick.signal ? Color(red: 0.4, green: 0.78, blue: 0.5) : Color(white: 0.32))
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 8)
            }
            switch Recorder.shared.isPlaying ? -1 : stick.state {
            case -1:
                Text("Playback")
                    .foregroundStyle(Color(white: 0.95))
            case CORE_RUNNING:
                Text(stick.signal ? "Signal" : "No signal")
                separator
                Text("\(stick.fieldsPerSecond) fields/s")
                if stick.usbErrors > 0 {
                    separator
                    Text("\(stick.usbErrors) USB errors")
                }
            case CORE_BUSY:
                Text("Stick in use")
            case CORE_MISSING:
                Text("No stick")
            default:
                Text("Connecting …")
            }
            Spacer(minLength: 12)
            recordingInfo
        }
        .font(.custom("Inter", size: 12).monospacedDigit())    // fixed digit width, nothing jumps around
        .foregroundStyle(Color(white: 0.6))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    // While recording: running time, file size, free space. Afterwards: where the file is.
    @ViewBuilder private var recordingInfo: some View {
        let r = Recorder.shared
        if r.isRecording {
            Text(r.elapsed)
                .foregroundStyle(Color(white: 0.95))
            separator
            Text(r.size)
            separator
            Text("\(r.freeGB) GB free")
            if r.lostFrames > 0 {
                separator
                Text("\(r.lostFrames) frames lost")
                    .foregroundStyle(Color(white: 0.95))
            }
        } else if let m = r.message {
            Text(m)
                .foregroundStyle(Color(white: 0.95))
        } else if let f = r.savedURL {
            Text("Saved: \(f.lastPathComponent)")
        } else if r.isPlaying {
            Text("Not saved yet")
        }
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(Color(white: 0.3))
            .padding(.horizontal, 8)
    }
}
