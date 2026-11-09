// LiveView.swift – live picture through Metal (the GPU).
// "Tube" view: every field goes on screen on its own, 50 per second. The lines in between are
// filled from the two neighboring lines – like a tube that only writes every other line per
// pass. Nothing sharpened, nothing averaged across frames.
// "Interlaced" view: both fields woven together, 25 frames, like preview.sh raw.

import SwiftUI
import MetalKit

// 16:9 un-squeezes what an HDMI-to-AV converter squashes. Otherwise PAL pixels are slightly
// wider than tall (59:54), like setsar in preview.sh.
var pictureAspectRatio: Double {
    Recorder.shared.widescreen ? 16.0 / 9.0 : Double(CORE_WIDTH) * 59 / 54 / Double(CORE_HEIGHT)
}

struct LiveView: NSViewRepresentable {
    let stick: Stick

    func makeCoordinator() -> Renderer { Renderer(stick: stick) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: context.coordinator.device)
        v.delegate = context.coordinator
        v.colorPixelFormat = .bgra8Unorm
        v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 120    // check this often whether a new field has arrived
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {}
}

final class Renderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()!
    private let stick: Stick
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    // [0] field on the even frame lines, [1] on the odd ones. Three of each in rotation,
    // so the GPU never reads a picture that is being overwritten.
    private let textures: [[MTLTexture]]
    private var current = [0, 0]
    private var has = [false, false]
    private var latest = 0                  // position of the newest field
    private var buffer = [UInt8](repeating: 0, count: Int(CORE_FIELD_BYTES))
    private var seen = 0                    // sequence number of the last field fetched
    private var needsRedraw = true
    private var wasInterlaced = false

    // EASYCAP_LOG=1: once per second, fields shown/skipped to stderr
    private let log = ProcessInfo.processInfo.environment["EASYCAP_LOG"] != nil
    private var shown = 0, skipped = 0, second = Date()

    private struct Param {
        var show: Int32                     // Tube: which position (0/1) is shown
        var interlaced: Int32
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

        // gbgr422 = bytes Y0 Cb Y1 Cr, exactly the YUYV from the stick. The GPU unpacks it itself.
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .gbgr422, width: Int(CORE_WIDTH), height: Int(CORE_FIELD_LINES), mipmapped: false)
        td.usage = .shaderRead
        let gpu = device
        textures = (0..<2).map { _ in (0..<3).map { _ in gpu.makeTexture(descriptor: td)! } }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        let interlaced = stick.interlaced
        if interlaced != wasInterlaced {
            wasInterlaced = interlaced
            needsRedraw = true
        }

        var top: Int32 = 0
        let nr = buffer.withUnsafeMutableBufferPointer { core_field(seen, $0.baseAddress, &top) }
        if nr != seen {
            if has[latest] && nr - seen > 1 { skipped += nr - seen - 1 }
            seen = nr
            // Top field on the even lines, swapped onto the odd ones (like row_offset in ezcap.c).
            // A recording already has the swap baked in, so not again during playback.
            let position = (top != 0) != (stick.swapFields && !Recorder.shared.isPlaying) ? 0 : 1
            current[position] = (current[position] + 1) % 3
            textures[position][current[position]].replace(
                region: MTLRegionMake2D(0, 0, Int(CORE_WIDTH), Int(CORE_FIELD_LINES)),
                mipmapLevel: 0, withBytes: buffer, bytesPerRow: Int(CORE_LINE_BYTES))
            has[position] = true
            latest = position
            shown += 1
            // Interlaced: a frame is only complete after the bottom field (25/s, like ezcap)
            if !interlaced || top == 0 { needsRedraw = true }
        }
        guard needsRedraw else { return }
        needsRedraw = false

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if has[latest] {
            var p = Param(show: Int32(latest), interlaced: interlaced ? 1 : 0)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(textures[0][current[0]], index: 0)
            enc.setFragmentTexture(textures[1][current[1]], index: 1)
            enc.setFragmentBytes(&p, length: MemoryLayout<Param>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        if log && Date().timeIntervalSince(second) >= 1 {
            FileHandle.standardError.write("\(shown) fields/s fetched, \(skipped) skipped\n".data(using: .utf8)!)
            shown = 0
            skipped = 0
            second = Date()
        }
    }
}

private let shader = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };
struct Param { int show; int interlaced; };

// One triangle that covers the whole view. uv: (0,0) top left, (1,1) bottom right.
vertex VOut vs(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o;
    o.pos = float4(p * 2 - 1, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}

// even/odd: newest field that sits on the even or odd frame lines
fragment float4 fs(VOut in [[stage_in]],
                   texture2d<float> even [[texture(0)]], texture2d<float> odd [[texture(1)]],
                   constant Param &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 c;
    if (p.interlaced) {
        // Every frame line exactly from its own field, nothing mixed vertically
        float line = min(floor(in.uv.y * 576.0), 575.0);
        float2 t = float2(in.uv.x, (floor(line * 0.5) + 0.5) / 288.0);
        c = fmod(line, 2.0) < 1.0 ? even.sample(s, t) : odd.sample(s, t);
    } else {
        float line = in.uv.y * 576.0 - 0.5;                 // frame line, whole number = line center
        float fieldLine = (line - float(p.show)) * 0.5;     // .5 = gap, mixed from both neighbors
        float2 t = float2(in.uv.x, (fieldLine + 0.5) / 288.0);
        c = p.show == 0 ? even.sample(s, t) : odd.sample(s, t);
    }

    // BT.601, limited range (Y 16-235, color 16-240), as in preview.sh.
    // g = Y, b = Cb, r = Cr. Above white and below black gets clipped, like on a TV.
    float y  = (c.g * 255.0 - 16.0) / 219.0;
    float cb = (c.b * 255.0 - 128.0) / 224.0;
    float cr = (c.r * 255.0 - 128.0) / 224.0;
    float3 rgb = float3(y + 1.402 * cr, y - 0.344136 * cb - 0.714136 * cr, y + 1.772 * cb);
    return float4(saturate(rgb), 1.0);
}
"""
