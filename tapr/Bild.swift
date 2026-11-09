// Bild.swift – Live-Bild ueber Metal (Grafikchip).
// Ansicht "Roehre": Jedes Halbbild kommt einzeln auf den Schirm, 50 pro Sekunde. Die Zeilen
// dazwischen werden aus den beiden Nachbarzeilen aufgefuellt – wie eine Roehre, die pro
// Durchgang nur jede zweite Zeile schreibt. Nichts geschaerft, nichts ueber Bilder gemittelt.
// Ansicht "Verzahnt": beide Halbbilder ineinander, 25 Vollbilder, wie vorschau.sh roh.

import SwiftUI
import MetalKit

// 16:9 entstaucht das, was der HDMI2AV zusammendrueckt. Sonst sind PAL-Pixel etwas breiter
// als hoch (59:54), wie setsar in vorschau.sh.
var bildSeitenverhaeltnis: Double {
    Aufnahme.shared.breitbild ? 16.0 / 9.0 : Double(TAPR_WIDTH) * 59 / 54 / Double(TAPR_HEIGHT)
}

struct LiveBild: NSViewRepresentable {
    let stick: Stick

    func makeCoordinator() -> Renderer { Renderer(stick: stick) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.delegate = context.coordinator
        v.colorPixelFormat = .bgra8Unorm
        v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 120    // so oft nachsehen, ob ein neues Halbbild da ist
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {}
}

final class Renderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    private let stick: Stick
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    // [0] Halbbild auf den geraden Vollbild-Zeilen, [1] auf den ungeraden. Je drei im Wechsel,
    // damit die GPU nie in ein Bild liest, das gerade ueberschrieben wird.
    private let texturen: [[MTLTexture]]
    private var aktuell = [0, 0]
    private var hat = [false, false]
    private var zuletzt = 0                 // Lage des neuesten Halbbilds
    private var puffer = [UInt8](repeating: 0, count: Int(TAPR_FIELD_BYTES))
    private var gesehen = 0                 // laufende Nummer des zuletzt geholten Halbbilds
    private var neuZeichnen = true
    private var warVerzahnt = false

    // TAPR_LOG=1: einmal pro Sekunde gezeigte/uebersprungene Halbbilder nach stderr
    private let log = ProcessInfo.processInfo.environment["TAPR_LOG"] != nil
    private var gezeigt = 0, uebersprungen = 0, sekunde = Date()

    private struct Param {
        var zeige: Int32                    // Roehre: welche Lage (0/1) gezeigt wird
        var verzahnt: Int32
    }

    init(stick: Stick) {
        self.stick = stick
        queue = device.makeCommandQueue()!
        let lib = try! device.makeLibrary(source: shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs")
        d.fragmentFunction = lib.makeFunction(name: "fs")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: d)

        // gbgr422 = Bytes Y0 Cb Y1 Cr, genau das YUYV vom Stick. Die GPU packt es selbst aus.
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .gbgr422, width: Int(TAPR_WIDTH), height: Int(TAPR_FIELD_LINES), mipmapped: false)
        td.usage = .shaderRead
        let gpu = device
        texturen = (0..<2).map { _ in (0..<3).map { _ in gpu.makeTexture(descriptor: td)! } }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        neuZeichnen = true
    }

    func draw(in view: MTKView) {
        let verzahnt = stick.verzahnt
        if verzahnt != warVerzahnt {
            warVerzahnt = verzahnt
            neuZeichnen = true
        }

        var top: Int32 = 0
        let nr = puffer.withUnsafeMutableBufferPointer { tapr_field(gesehen, $0.baseAddress, &top) }
        if nr != gesehen {
            if hat[zuletzt] && nr - gesehen > 1 { uebersprungen += nr - gesehen - 1 }
            gesehen = nr
            // oberes Halbbild auf die geraden Zeilen, getauscht auf die ungeraden (wie row_offset in ezcap.c).
            // In einer Aufnahme ist das Tauschen schon drin, bei der Wiedergabe also nicht nochmal.
            let lage = (top != 0) != (stick.tauschen && !Aufnahme.shared.spielt) ? 0 : 1
            aktuell[lage] = (aktuell[lage] + 1) % 3
            texturen[lage][aktuell[lage]].replace(
                region: MTLRegionMake2D(0, 0, Int(TAPR_WIDTH), Int(TAPR_FIELD_LINES)),
                mipmapLevel: 0, withBytes: puffer, bytesPerRow: Int(TAPR_LINE_BYTES))
            hat[lage] = true
            zuletzt = lage
            gezeigt += 1
            // Verzahnt: erst nach dem unteren Halbbild ist ein Vollbild fertig (25/s, wie ezcap)
            if !verzahnt || top == 0 { neuZeichnen = true }
        }
        guard neuZeichnen else { return }
        neuZeichnen = false

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if hat[zuletzt] {
            var p = Param(zeige: Int32(zuletzt), verzahnt: verzahnt ? 1 : 0)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texturen[0][aktuell[0]], index: 0)
            enc.setFragmentTexture(texturen[1][aktuell[1]], index: 1)
            enc.setFragmentBytes(&p, length: MemoryLayout<Param>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        if log && Date().timeIntervalSince(sekunde) >= 1 {
            FileHandle.standardError.write("\(gezeigt) Halbbilder/s geholt, \(uebersprungen) uebersprungen\n".data(using: .utf8)!)
            gezeigt = 0
            uebersprungen = 0
            sekunde = Date()
        }
    }
}

private let shader = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct Param { int zeige; int verzahnt; };

// Ein Dreieck, das den ganzen View bedeckt. uv: (0,0) oben links, (1,1) unten rechts.
vertex VOut vs(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o;
    o.pos = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

// gerade/ungerade: neuestes Halbbild, das auf den geraden bzw. ungeraden Vollbild-Zeilen liegt
fragment float4 fs(VOut in [[stage_in]],
                   texture2d<float> gerade [[texture(0)]], texture2d<float> ungerade [[texture(1)]],
                   constant Param &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c;
    if (p.verzahnt) {
        // Jede Vollbild-Zeile genau aus ihrem Halbbild, senkrecht nichts gemischt
        float zeile = min(floor(in.uv.y * 576.0), 575.0);
        float2 t = float2(in.uv.x, (floor(zeile * 0.5) + 0.5) / 288.0);
        c = fmod(zeile, 2.0) < 1.0 ? gerade.sample(s, t) : ungerade.sample(s, t);
    } else {
        float zeile = in.uv.y * 576.0 - 0.5;                // Vollbild-Zeile, ganze Zahl = Zeilenmitte
        float feldzeile = (zeile - float(p.zeige)) * 0.5;   // ,5 = Luecke, wird aus beiden Nachbarn gemischt
        float2 t = float2(in.uv.x, (feldzeile + 0.5) / 288.0);
        c = p.zeige == 0 ? gerade.sample(s, t) : ungerade.sample(s, t);
    }

    // BT.601, begrenzter Bereich (Y 16-235, Farbe 16-240), wie in vorschau.sh.
    // g = Y, b = Cb, r = Cr. Ueber Weiss und unter Schwarz wird abgeschnitten wie am Fernseher.
    float y  = (c.g * 255.0 - 16.0) / 219.0;
    float cb = (c.b * 255.0 - 128.0) / 224.0;
    float cr = (c.r * 255.0 - 128.0) / 224.0;
    float3 rgb = float3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb);
    return float4(saturate(rgb), 1.0);
}
"""
