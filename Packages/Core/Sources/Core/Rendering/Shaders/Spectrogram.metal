#include <metal_stdlib>
using namespace metal;

// Spectrogram — scrolling mel-over-time heatmap. X axis = time (most recent
// column on the right), Y axis = frequency (bass at the bottom, treble at
// the top), brightness + hue = magnitude. Mirror of the web driver at
// musicplayer-viz/viz/spectrogram.js — the CPU side keeps a 256×32 Uint8
// ring of recent mel magnitudes and uploads it as an r8Unorm 2D texture
// each frame; this fragment samples it and paints the multi-stop magma
// palette.
//
// Uniform layout (must match Swift SpectrogramUniforms exactly — 16 bytes):
//   offset  0: bass       (float) — EMA-smoothed bass 0..1 (× react)
//   offset  4: gamma      (float) — amplitude gamma; <1 flattens, >1 crushes
//   offset  8: resolution (float2) — 8-byte aligned (unused by shader today
//                                    but kept for future viewport-dependent
//                                    effects + Swift layout parity)
// Total: 16 bytes.
struct Uniforms {
    float bass;
    float gamma;
    float2 resolution;   // offset 8 — 8-byte aligned ✓
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut spectrogram_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Multi-stop magma-ish gradient: near-black → deep violet → magenta →
// amber → near-white. Keeps low values readable (subtle violet) while
// peaks pop to near-white without blooming out.
// Stops identical to the web GLSL `palette()` — see viz/spectrogram.js.
static float3 palette(float t) {
    float3 c0 = float3(0.020, 0.005, 0.050);   // near-black violet
    float3 c1 = float3(0.260, 0.050, 0.380);   // deep purple
    float3 c2 = float3(0.850, 0.150, 0.580);   // magenta
    float3 c3 = float3(1.000, 0.650, 0.200);   // amber
    float3 c4 = float3(1.000, 0.980, 0.900);   // warm white
    float3 col = mix(c0, c1, smoothstep(0.00, 0.28, t));
    col = mix(col, c2, smoothstep(0.25, 0.55, t));
    col = mix(col, c3, smoothstep(0.55, 0.82, t));
    col = mix(col, c4, smoothstep(0.82, 0.98, t));
    return col;
}

fragment float4 spectrogram_fs(VSOut in [[stage_in]],
                               constant Uniforms& u [[buffer(0)]],
                               texture2d<float> hist [[texture(0)]],
                               sampler histSampler [[sampler(0)]]) {
    // Bass at the bottom of the frame — invert Y since mel bin 0 is bass
    // and we want it drawn low on screen. Matches web GLSL:
    //   vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
    float2 uv = float2(in.uv.x, 1.0 - in.uv.y);
    float amp = hist.sample(histSampler, uv).r;

    // Gamma on amplitude. gamma < 1 flattens (makes quiet parts readable),
    // gamma > 1 crushes quiet parts so only peaks show.
    float shaped = pow(amp, u.gamma);

    float3 col = palette(shaped);

    // Subtle bass-driven ambient pulse — whole image brightens slightly
    // on each kick so the "chest-punch" reads visually.
    col *= 1.0 + u.bass * 0.12;

    // Soft vertical edge fade so the top/bottom don't look hard-cut.
    // Mirror of web GLSL vfade (uses vUv.y, NOT our flipped uv.y — the
    // fade is a screen-space effect, independent of the data flip).
    float vfade = smoothstep(0.0, 0.04, in.uv.y) * smoothstep(1.0, 0.96, in.uv.y);
    col *= vfade;

    return float4(col, 1.0);
}
