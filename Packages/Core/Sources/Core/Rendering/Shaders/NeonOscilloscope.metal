#include <metal_stdlib>
using namespace metal;

// Neon Oscilloscope — Metal port of viz/neon-oscilloscope.js (web).
//
// Web draws 4 Z-stacked Three.js PlaneGeometry ribbons (cyan / magenta /
// purple / blue), CPU-displaces their Y verts per frame from the
// time-domain waveform envelope, and runs the result through
// UnrealBloomPass for the neon glow. Each ribbon is band-tagged (lows,
// mids, highs, full) and its peak height is driven by its band's energy.
//
// The iOS port compresses all 4 ribbons into a single fragment pass.
// Per-pixel we compute each ribbon's Y line, then sum two gaussians
// (wide halo + tight core) per layer — same trick used in Siri
// Waveform to approximate a two-pass neon stroke + bloom. Frequency-domain
// magnitudes replace the web's time-domain waveform (which is 0 on DRM
// Spotify playback anyway); mean-band energy drives per-ribbon amplitude.
//
// Per-layer constants mirror web LAYERS in viz/neon-oscilloscope.js:
//   magenta  bands 0..4   (lows)     gain 6.5
//   cyan     bands 5..12  (low-mids) gain 5.8
//   purple   bands 13..20 (mids)     gain 5.0
//   blue     bands 21..31 (full)     gain 4.2
// See .claude/skills/studiojoe-viz/references/parity.md — any tuning here
// must land on the web side too.
//
// Uniform layout (must match Swift NeonOscilloscopeUniforms — 48 bytes):
//   offset  0: time        (float)  — seconds, monotonic
//   offset  4: beatPulse   (float)  — 0..1 broadband beat
//   offset  8: _pad0       (float)  — align bandEnergy to 16B
//   offset 12: _pad1       (float)
//   offset 16: bandEnergy  (float4) — mean band energy per ribbon: .x=mag,
//                                     .y=cyan, .z=purple, .w=blue
//   offset 32: resolution  (float2) — drawable size in pixels
//   offset 40: _pad2       (float)  — pad to 16B multiple
//   offset 44: _pad3       (float)
// Total: 48 bytes.

struct NeonOscilloscopeUniforms {
    float time;
    float beatPulse;
    float _pad0;
    float _pad1;
    float4 bandEnergy;
    float2 resolution;
    float _pad2;
    float _pad3;
};

struct NeonOscVSOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen-triangle VS — three verts at clip-space corners, uv mapped
// through p*2-1 so a single triangle covers the viewport without a quad.
vertex NeonOscVSOut neonosc_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    NeonOscVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Per-layer constants — mirror of web RIBBON_COLORS / RIBBON_GAIN.
// Colors are in hex in the web; rgb/255 here.
// Order matches bandEnergy.xyzw: magenta, cyan, purple, blue.
constant float3 LAYER_RGB[4] = {
    float3(255.0,  43.0, 214.0) / 255.0,  // magenta (lows)
    float3(  0.0, 255.0, 255.0) / 255.0,  // cyan    (low-mids)
    float3(180.0,  75.0, 255.0) / 255.0,  // purple  (mids)
    float3( 61.0, 107.0, 255.0) / 255.0,  // blue    (full)
};
constant float LAYER_GAIN[4]  = { 6.5, 5.8, 5.0, 4.2 };
// Per-ribbon ribbon-flow constants — give each strand its own phase/freq
// so they don't stack into a single strand when silent. No web counterpart
// (web samples the time-domain waveform which provides this variation for
// free); tuned here by eye to produce visible misalignment at rest.
constant float LAYER_SPEED[4] = { 0.60, 0.80, 1.00, 1.20 };
constant float LAYER_FREQ[4]  = { 3.0,  4.5,  6.0,  7.5  };
constant float LAYER_PHASE[4] = { 0.0,  1.8,  3.2,  4.7  };

// Per-ribbon ribbon Y-center offset in uv-space. Web uses 4 meshes at
// z = [-7.5, -2.5, 2.5, 7.5] on a perspective-projected plane; on iOS
// we fake that depth-stacking by placing the ribbons at slightly
// different Y-centers so they don't overlap into one strand at rest.
// At full audio energy the peaks still fan out so this just resolves
// the quiet baseline.
constant float LAYER_Y_CENTER[4] = { 0.30, 0.43, 0.57, 0.70 };

fragment float4 neonosc_fs(NeonOscVSOut in [[stage_in]],
                           constant NeonOscilloscopeUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float nx = uv.x * 2.0 - 1.0;              // [-1, 1]
    // Web tapers with sin(π * xNorm), which pinches to zero at both ends
    // and peaks at x=center. Identical shape in uv-space.
    float taper = sin(3.14159265358979 * uv.x);
    if (taper < 0.0) taper = 0.0;

    float yScreen = uv.y;
    float time    = u.time;
    float beat    = u.beatPulse;

    // Per-ribbon band-energy lookup (no dynamic indexing on float4).
    float bandE[4];
    bandE[0] = u.bandEnergy.x;
    bandE[1] = u.bandEnergy.y;
    bandE[2] = u.bandEnergy.z;
    bandE[3] = u.bandEnergy.w;

    float3 col = float3(0.0);

    for (int i = 0; i < 4; i++) {
        float e     = bandE[i];
        float gain  = LAYER_GAIN[i];
        // Peak scale — mirror web `waveAmplitude`:
        //   peakScale = 0.15 + bandVal * bandGain + beat * 0.7
        // Web then multiplies by ambient dual-sine + synthetic-spike
        // product. On iOS we do not sample a waveform array, so we let
        // the band energy drive amplitude directly and let the per-ribbon
        // sine below provide the ribbon-flow motion.
        float amp = 0.15 + e * gain * 0.15 + beat * 0.30;

        // Ribbon Y line in uv-space. LAYER_FREQ is cycles across the
        // full width (nx ∈ [-1, 1]) so `nx * freq` gives that many phase
        // turns from left edge to right edge. Amplitude is in uv fraction
        // of viewport height — scaled modestly (0.15) so ribbons don't
        // clip off-screen at peaks.
        float wave = sin(nx * LAYER_FREQ[i] + time * LAYER_SPEED[i] + LAYER_PHASE[i]);
        float yLine = LAYER_Y_CENTER[i] + wave * taper * amp * 0.15;

        float dy  = yScreen - yLine;
        float dy2 = dy * dy;

        // Two gaussians per ribbon — wide halo + narrow core. Sigmas
        // tuned by feel to approximate web's UnrealBloomPass(0.7, 0.6,
        // 0.45) + additive 0.5-opacity MeshBasicMaterial stack. Not a
        // 1:1 reproduction — a real bloom would need a separate render
        // pass + gaussian blur MRT chain, which is a sizable
        // infrastructure investment. This is the same trade-off
        // Siri Waveform makes.
        float glow = exp(-dy2 / 0.0030);
        float core = exp(-dy2 / 0.00010);

        col += LAYER_RGB[i] * (glow * 0.15 + core);
    }

    // Background: deep near-black to let the additive neon pop. Web uses
    // 0x000005 scene background; we clamp with max() so cells below any
    // ribbon still read as that color rather than pure black.
    col = max(col, float3(0.0, 0.0, 0.02));

    return float4(col, 1.0);
}
