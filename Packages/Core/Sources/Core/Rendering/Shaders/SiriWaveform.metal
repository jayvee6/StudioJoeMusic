#include <metal_stdlib>
using namespace metal;

// Siri Waveform — Metal port of viz/siri-waveform.js (web).
//
// Web draws 4 semi-transparent neon sin layers additively on a Canvas 2D
// context (globalCompositeOperation = 'lighter'), with a parabolic width
// attenuation so each strand pinches to zero at the edges. Each layer uses
// a two-pass stroke — a wide 10px "glow" plus a narrow 2px "core" — so the
// cores read crisp while the halos cross-mix into warm neon where strands
// overlap.
//
// The Metal port composites all 4 layers in-shader in a single pass. We
// approximate the two-pass stroke with two gaussians at different sigmas:
// one wide (glow halo) and one narrow (bright core), summed in the same
// additive pass. Because we're adding in linear RGB, overlapping peaks
// still converge toward white exactly like the web's 'lighter' blending.
//
// Per-layer constants MUST mirror viz/siri-waveform.js exactly (parity rule
// — see .claude/skills/studiojoe-viz/references/parity.md). The web `speed`
// values are ms-scaled (time = Date.now() in ms, multiplied by e.g. 0.00060);
// on iOS we pass `time` in seconds and multiply by 1000× the web coefficient
// (i.e. 0.60 instead of 0.00060) for identical phase rate.
//
// Uniform layout (must match Swift SiriWaveformUniforms — 48 bytes):
//   offset  0: time        (float)  — CPU-accumulated seconds
//   offset  4: beatPulse   (float)  — 0..1 broadband beat
//   offset  8: _pad0       (float)  — align bandEnergy to 16B
//   offset 12: _pad1       (float)
//   offset 16: bandEnergy  (float4) — per-layer mel-band mean: .x magenta,
//                                     .y cyan, .z blue, .w violet
//   offset 32: resolution  (float2) — drawable size in pixels
//   offset 40: _pad2       (float)
//   offset 44: _pad3       (float)
// Total: 48 bytes.

struct SiriWaveformUniforms {
    float time;
    float beatPulse;
    float _pad0;
    float _pad1;
    float4 bandEnergy;
    float2 resolution;
    float _pad2;
    float _pad3;
};

struct SiriVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex SiriVSOut siriwave_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    SiriVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Per-layer constants — mirrored 1:1 from web LAYERS in viz/siri-waveform.js.
// Order: magenta (sub/bass), cyan (low-mids), blue (mids), violet (treble).
// The `speed` values are the WEB constants multiplied by 1000 (ms → s rebase).
constant float3 LAYER_RGB[4] = {
    float3(255.0, 43.0, 214.0) / 255.0,   // magenta
    float3(  0.0, 229.0, 255.0) / 255.0,  // cyan
    float3( 61.0, 107.0, 255.0) / 255.0,  // blue
    float3(200.0, 115.0, 255.0) / 255.0,  // violet
};
constant float LAYER_ALPHA[4] = { 0.50, 0.50, 0.50, 0.50 };
constant float LAYER_SPEED[4] = { 0.60,  0.95,  0.78,  1.30  }; // web × 1000
constant float LAYER_AMP[4]   = { 0.22,  0.20,  0.17,  0.15  };
constant float LAYER_FREQ[4]  = { 2.8,   4.2,   5.6,   7.9   };
constant float LAYER_PHASE[4] = { 0.0,   1.7,   3.1,   4.8   };

// Idle breath — each layer seeded with its own phase so the 4 strands don't
// sway together during silence. Mirror of web idleBreath(t, seed) with the
// web's ms-scaled rates (0.00071, 0.00134, 0.00262) rebased to seconds by
// ×1000 (→ 0.71, 1.34, 2.62).
static float idleBreath(float t, float seed) {
    return 0.35
         + 0.12 * sin(t * 0.71 + seed * 1.3)
         + 0.08 * sin(t * 1.34 + 1.3 + seed * 2.1)
         + 0.05 * sin(t * 2.62 + 2.7 + seed * 0.7);
}

fragment float4 siriwave_fs(SiriVSOut in [[stage_in]],
                            constant SiriWaveformUniforms& u [[buffer(0)]]) {
    // Web uses Canvas 2D with Y pointing down (top = 0). MTKView hands us
    // uv.y = 0 at top (after the p*2-1 flip in our VS) when using the
    // standard `uv = p` mapping. Match the web convention: center y=0.5,
    // positive wave = below center visually.
    float2 uv = in.uv;
    float nx = uv.x * 2.0 - 1.0;              // [-1, 1], 0 center
    float att = 1.0 - nx * nx;                // parabolic attenuation
    float yScreen = uv.y;                     // 0 top → 1 bottom
    const float yCenter = 0.5;

    // Beat is broadband — nudges every layer together on drops, but scaled
    // down so each strand's band-energy dominates its motion. Mirrors web
    // `beatKick = beat * 0.35 * react` (react = 1.0 default on iOS).
    float beatKick = u.beatPulse * 0.35;

    float3 col = float3(0.0);
    float time = u.time;

    // Unroll 4 layers — small, identical structure, no dynamic indexing.
    // Index-into `bandEnergy` with .x/.y/.z/.w since Metal has no dynamic
    // float4 subscripting on constant buffers.
    float bandE[4];
    bandE[0] = u.bandEnergy.x;
    bandE[1] = u.bandEnergy.y;
    bandE[2] = u.bandEnergy.z;
    bandE[3] = u.bandEnergy.w;

    for (int i = 0; i < 4; i++) {
        float e = bandE[i];
        // amp: idle breath + per-band reactivity (×1.8) + broadband beat kick,
        // floored at 0.15 so silence still shows a baseline wave.
        float amp = max(0.15, idleBreath(time, float(i)) + e * 1.8 + beatKick);
        // Treble within this layer's band tightens its own frequency (×0.5).
        float freq = LAYER_FREQ[i] * (1.0 + e * 0.5);

        // Wave y in uv-space. LAYER_AMP is in units of viewport height
        // (matches web `amplitude * h` where h is logical canvas height).
        float wave = sin(nx * freq + time * LAYER_SPEED[i] + LAYER_PHASE[i]);
        float yLayer = yCenter + wave * att * LAYER_AMP[i] * amp;
        float dy = yScreen - yLayer;
        float dy2 = dy * dy;

        // Two gaussians — wide halo + narrow core — approximate the web's
        // two-pass 10px glow + 2px stroke. Sigmas tuned for the ~720p
        // logical-pixel feel of the web viz (10px / ~720 screen height ≈
        // 0.014 in uv-space → sigma² ≈ 0.0002 for the tight core, ≈ 0.003
        // for the glow halo). Numbers below were dialed in by feel.
        float glow = exp(-dy2 / 0.0025);      // wide halo
        float core = exp(-dy2 / 0.00008);     // narrow bright core

        col += LAYER_RGB[i] * LAYER_ALPHA[i] * (glow * 0.12 + core);
    }

    // Background clamp — web fills #0B0B1A (0.043, 0.043, 0.102) first, then
    // draws additively on top. We don't clear separately; just max() so dark
    // regions read as the web's deep-navy backdrop instead of true black.
    col = max(col, float3(0.043, 0.043, 0.102));

    return float4(col, 1.0);
}
