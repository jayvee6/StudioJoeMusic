#include <metal_stdlib>
using namespace metal;

struct SpiralUniforms {
    float offset;     // in pitches, CPU-accumulated
    float hue;        // 0..1, CPU-accumulated
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

static float3 hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(
        abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
        0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

fragment float4 spiral_fs(SVSOut in [[stage_in]],
                          constant SpiralUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;
    float r = length(uv);
    float theta = atan2(uv.y, uv.x);

    // Fill factor so the spiral extends further into the long dimension of the screen.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    // Web: pitch = 50 px on shortSide; our shortSide is 1.0 (unit [-0.5, 0.5]).
    // Scaled by fillFactor so the spiral fills more of the tall/wide screen.
    float pitch = 0.08 * fillFactor;
    const float armCount = 2.0;
    float armSpacing = pitch / armCount;

    // Offset is in pitches (CPU-integrated). For the spiral phase, convert to pitch units.
    float phase = fmod((r / pitch) - u.offset - theta / (2.0 * M_PI_F), 1.0 / armCount);
    if (phase < 0.0) phase += 1.0 / armCount;
    float dist = min(phase, 1.0 / armCount - phase) * pitch;   // back to radial units

    // Line width — web: lineW = 3 + bass*10 px, ≈ 0.005 + bass*0.016 baseline.
    float lineW = 0.006 + u.bass * 0.010;
    lineW = min(lineW, armSpacing * 0.48);             // never bleed into neighboring arm

    // Painter's 5-pass stroke using HSL lightness progression from the web:
    //   1 shadow     hsl(hue, 80%,  10%)  @ lineW + 8/shortSide  (≈ lineW + 0.012)
    //   2 dark base  hsl(hue, 100%, 28%)  @ lineW
    //   3 main+glow  hsl(hue, 100%, 50 + bass*14%) @ lineW*0.78, exp halo
    //   4 highlight  hsl(hue, 100%, 68 + bass*12%) @ lineW*0.42
    //   5 rim        hsla(hue, 70%, 92%, 0.6) @ lineW*0.12
    float3 col = float3(0.0);

    float w1 = lineW + 0.012;
    float m1 = smoothstep(w1, w1 * 0.55, dist);
    col = mix(col, hsl2rgb(u.hue, 0.80, 0.10), m1);

    float w2 = lineW;
    float m2 = smoothstep(w2, w2 * 0.55, dist);
    col = mix(col, hsl2rgb(u.hue, 1.00, 0.28), m2);

    float w3 = lineW * 0.78;
    float m3 = smoothstep(w3, w3 * 0.35, dist);
    float glow = exp(-dist * (4.0 - u.bass * 1.5)) * (0.35 + u.bass * 0.30);
    float3 main3 = hsl2rgb(u.hue, 1.00, 0.50 + u.bass * 0.14);
    col = mix(col, main3, m3);
    col += main3 * glow;

    float w4 = lineW * 0.42;
    float m4 = smoothstep(w4, w4 * 0.3, dist);
    col = mix(col, hsl2rgb(u.hue, 1.00, 0.68 + u.bass * 0.12), m4);

    float w5 = lineW * 0.14;
    float m5 = smoothstep(w5, 0.0, dist);
    col = mix(col, hsl2rgb(u.hue, 0.70, 0.92), m5 * 0.65);

    // Center-hole fill: web draws a disc at pitch*1.4 in main color + glow.
    float holeR = pitch * 1.4;
    float holeFade = smoothstep(holeR * 1.08, holeR * 0.70, r);
    col = mix(col, main3 + main3 * 0.35, holeFade);

    // Warm background fill: hsl((hue+25°) % 1, 50%, 30 + bass*8%).
    float bgHue = fmod(u.hue + 25.0 / 360.0, 1.0);
    float3 bg = hsl2rgb(bgHue, 0.50, 0.18 + u.bass * 0.08);

    // Paint bg only where the stroke passes haven't covered.
    float coverage = max(max(max(m1, m2), max(m3, m4)), m5);
    col += bg * (1.0 - coverage);

    // Vignette
    col *= smoothstep(1.12, 0.0, r);

    return float4(max(col, float3(0.0)), 1.0);
}
