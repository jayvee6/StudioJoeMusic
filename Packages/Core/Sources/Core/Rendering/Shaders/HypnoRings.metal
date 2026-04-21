#include <metal_stdlib>
using namespace metal;

struct HypnoUniforms {
    float offset;        // in ring-spacings, CPU-accumulated
    float colorShift;    // int counter, increments on offset wrap; keeps parity continuous
    float hue;           // 0..1, CPU-accumulated
    float bass;
    float2 resolution;
};

struct HVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex HVSOut hypno_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    HVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

static float3 hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(
        abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
        0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

fragment float4 hypno_fs(HVSOut in [[stage_in]],
                         constant HypnoUniforms& u [[buffer(0)]],
                         constant float* bassHistory [[buffer(1)]]) {
    // Short-side square projection so spacing matches min(W,H).
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;
    float r = length(uv);

    // SPACING in short-side units. Web: 46 px / shortSide ≈ 0.07 at an iPhone portrait viewport.
    const float spacing = 0.07;

    // Ring index at this pixel, accounting for the CPU-integrated offset.
    // Web: R(i) = i*SPACING - ringOffset  ⇒  i = (r + ringOffset)/SPACING
    float ringR = (r / spacing) + u.offset;
    int ringIdx = int(floor(ringR));

    // Bass-history delay: each ring reads bassHistory[i] for the outward-traveling wave.
    int historyIdx = abs(ringIdx) % 16;
    float delayedBass = bassHistory[historyIdx];

    // Parity: web keeps bands coherent across offset wraps via ringColorShift.
    int parityInt = (ringIdx + int(u.colorShift) + 1024) & 1;

    // Web: light stripe = hsl(0, 0%, 82 + delayedBass * 18%); dark stripe = hsl(hue, 100%, 15 + bass*30%).
    float3 light = hsl2rgb(0.0, 0.0, 0.82 + delayedBass * 0.18);
    float3 dark  = hsl2rgb(u.hue, 1.0, 0.15 + u.bass * 0.30);

    // Anti-alias the stripe edges a bit.
    float localPhase = fract(ringR);
    float edge = min(localPhase, 1.0 - localPhase);
    float softness = smoothstep(0.0, 0.08, edge);

    float3 color = (parityInt == 0) ? light : dark;
    color *= (0.70 + softness * 0.30);

    // Web's full-canvas flash when bass > 0.5.
    float flash = smoothstep(0.5, 0.85, u.bass);
    color = mix(color, light * 1.15, flash * 0.35);

    // Radial fade toward edges so the rings melt into the background.
    color *= smoothstep(1.05, 0.05, r);

    return float4(max(color, float3(0.0)), 1.0);
}
