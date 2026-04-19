#include <metal_stdlib>
using namespace metal;

struct SpiralUniforms {
    float time;
    float bass;
    float treble;
    float2 resolution;
};

struct SVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex SVSOut spiral_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    SVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Desaturate to `s` fraction (0 = grey, 1 = full colour) via luminance mix.
static float3 desaturate(float3 col, float s) {
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    return mix(float3(lum), col, s);
}

fragment float4 spiral_fs(SVSOut in [[stage_in]],
                          constant SpiralUniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float r = length(uv);
    float theta = atan2(uv.y, uv.x);

    // 2-arm Archimedean spiral. Pitch is radial spacing per revolution; armSpacing is
    // pitch / armCount so fmod gives distance to the nearest of the two interleaved arms.
    float pitch = 0.12;
    float armCount = 2.0;
    float armSpacing = pitch / armCount;
    float speed = 0.18;                    // constant — bass drives amplitude, not speed
    float offset = u.time * speed;

    float phase = fmod(r - offset - pitch * theta / (2.0 * M_PI_F), armSpacing);
    if (phase < 0.0) phase += armSpacing;
    float dist = min(phase, armSpacing - phase);

    // Base hue cycles with time/radius/treble, full-saturation palette.
    float hue = u.time * 0.06 + r * 1.25 + u.treble * 0.35;
    float3 baseHue = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));

    // Width is the "full stroke" half-width. Each pass uses a fraction of it.
    // Staying under armSpacing/2 = 0.03 keeps the 2 arms distinct.
    float width = 0.018 + u.bass * 0.008;
    width = min(width, armSpacing * 0.48);

    // Painter's 5-pass stroke (match web prototype):
    //   1 deep shadow  (widest, near-black)
    //   2 dark base    (saturated mid-dark)
    //   3 main + glow  (mid lightness, exponential halo)
    //   4 highlight    (narrower, lighter)
    //   5 rim          (thinnest, near-white)
    float3 col = float3(0.0);

    // 1 — deep shadow (80% sat, 10% lightness).
    float w1 = width * 2.4;
    float m1 = smoothstep(w1, w1 * 0.55, dist);
    col = mix(col, desaturate(baseHue, 0.8) * 0.10, m1);

    // 2 — dark base (100% sat, 28% lightness).
    float w2 = width;
    float m2 = smoothstep(w2, w2 * 0.55, dist);
    col = mix(col, baseHue * 0.28, m2);

    // 3 — main + glow: lightness 50 + bass*14%, plus exponential halo.
    float w3 = width * 0.78;
    float m3 = smoothstep(w3, w3 * 0.35, dist);
    float glow = exp(-dist * (5.0 - u.bass * 2.0)) * (0.30 + u.bass * 0.25);
    float3 mainColor = baseHue * (0.50 + u.bass * 0.14);
    col = mix(col, mainColor + baseHue * glow, m3);
    col += baseHue * glow * 0.5;     // additive halo beyond the edge

    // 4 — upper highlight (68 + bass*12%).
    float w4 = width * 0.42;
    float m4 = smoothstep(w4, w4 * 0.3, dist);
    col = mix(col, baseHue * (0.68 + u.bass * 0.12), m4);

    // 5 — bright rim (70% sat, 92% lightness).
    float w5 = width * 0.14;
    float m5 = smoothstep(w5, 0.0, dist);
    float3 rim = desaturate(baseHue, 0.7) * 0.92;
    col = mix(col, rim, m5 * 0.65);

    // Center-hole fill: hides degenerate arm endpoints near r=0, matches web's
    // `pitch * 1.4` disc drawn in main color + glow.
    float holeR = pitch * 0.7;
    float holeFade = smoothstep(holeR * 1.05, holeR * 0.6, r);
    if (holeFade > 0.0) {
        float3 holeCore = baseHue * (0.55 + u.bass * 0.18) + baseHue * 0.25;
        col = mix(col, holeCore, holeFade);
    }

    // Warm bg fill — web: hsl((spiralHue+25)%360, 50%, 30+bass*8%).
    float3 bgHue = 0.5 + 0.5 * cos(6.28318 *
        (hue + 25.0 / 360.0 + float3(0.0, 0.33, 0.67)));
    float3 bg = desaturate(bgHue, 0.5) * (0.18 + u.bass * 0.08);
    // Only show bg where the stroke passes haven't painted — rough coverage mask.
    float coverage = max(max(m1, m2), max(m3, max(m4, m5)));
    col += bg * (1.0 - coverage) * 0.85;

    // Vignette
    col *= smoothstep(1.08, 0.0, r);

    return float4(max(col, float3(0.0)), 1.0);
}
