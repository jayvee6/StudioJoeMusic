#include <metal_stdlib>
using namespace metal;

// Framebuffer-feedback mandala: three shaders share one fullscreen vertex fn.
//   mandala_fs_trail_fade_fs — paints rgba(0,0,0,0.18) for the 18% alpha wash
//   mandala_fs_trail_draw_fs — paints this frame's polygon lines additively
//   mandala_fs_trail_blit_fs — samples the accumulation texture 1:1 to the drawable
//
// All three use the same fullscreen-triangle vertex:

struct MTVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex MTVSOut mandala_fs_trail_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    MTVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ── Pass 1: alpha wash ─────────────────────────────────────────────────────
fragment float4 mandala_fs_trail_fade_fs(MTVSOut in [[stage_in]]) {
    // Pipeline blend = (srcAlpha, 1-srcAlpha). With src = (0,0,0,0.18) the
    // destination is multiplied by 0.82 each frame → ghosts fade exponentially.
    return float4(0.0, 0.0, 0.0, 0.18);
}

// ── Pass 3: blit ───────────────────────────────────────────────────────────
fragment float4 mandala_fs_trail_blit_fs(MTVSOut in [[stage_in]],
                                         texture2d<float> accum [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 col = accum.sample(s, in.uv);
    // Force alpha = 1 so the drawable is fully opaque. The accumulator's alpha channel
    // decays each frame (the fade pass's srcAlpha=0.18 blend subtracts from dst.a too),
    // which would otherwise let the underlying BlueHourBackground leak through as
    // navy wedges in any pixel that wasn't just overdrawn by the current frame's polygon.
    return float4(col.rgb, 1.0);
}

// ── Pass 2: polygon draw ───────────────────────────────────────────────────

struct MandalaFrameUniforms {
    float rot;
    float hue;
    float bass;
    float treble;
    float2 resolution;
};

static float3 hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(
        abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
        0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

static float sdPolygon(float2 p, int n, float r) {
    float angle = atan2(p.y, p.x);
    float dist = length(p);
    float sector = 2.0 * M_PI_F / float(n);
    float a = fmod(angle + sector * 0.5 + sector, sector) - sector * 0.5;
    float inscribed = r * cos(a);
    return dist - inscribed;
}

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

fragment float4 mandala_fs_trail_draw_fs(MTVSOut in [[stage_in]],
                                         constant MandalaFrameUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    // Fill factor so the mandala grows into the screen's long dimension.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    // Thicker crisp outline + narrow halo. The goal: polygon corners pop out clearly,
    // trails handle the "dancing" motion, bloom adds just enough neon warmth without
    // hiding the geometry.
    float maxR = 0.38 * fillFactor;
    float lineW = 0.005 + u.bass * 0.008;
    float haloW = 0.008 + u.bass * 0.015;           // much narrower than before
    float radiusScale = 0.40 + u.bass * 0.90;

    // 6 distinct polygons — triangle, square, pentagon, hex, hept, oct.
    const int SIDES[6] = {3, 4, 5, 6, 7, 8};

    float3 accum = float3(0.0);

    for (int i = 0; i < 6; i++) {
        int sides = SIDES[i];
        float dir = (i % 2 == 0) ? 1.0 : -1.0;

        // Each layer gets an additional phase offset of i * π / LAYERS (matches web).
        float layerRot = u.rot * dir + float(i) * M_PI_F / 6.0;
        float2 p = rot2(uv, layerRot);

        float r = maxR * (float(i) + 1.0) / 6.0 * radiusScale;

        // Web: hsl(hue + i*42°, 100%, 65%) at alpha 0.35 + bass*0.65.
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0), 1.0);
        float alpha = 0.35 + u.bass * 0.65;
        float3 lineCol = hsl2rgb(layerHue, 1.0, 0.65);

        float d = sdPolygon(p, sides, r);
        float absD = abs(d);

        // Sharp core — the polygon outline. Hard edge so corners stay pointy.
        float core = smoothstep(lineW, lineW * 0.15, absD);
        accum += lineCol * alpha * core;

        // Narrow halo — adds a bit of neon warmth near the line but doesn't bloom
        // outward far enough to merge with the neighboring polygon.
        float glow = exp(-absD / haloW);
        accum += lineCol * alpha * glow * 0.25;
    }

    // Return additive contribution + full alpha so the fade pass doesn't decay the
    // alpha channel to zero over time (which would cause background bleed-through).
    return float4(accum, 1.0);
}

// ── Legacy single-pass entry point kept so the old VisualizerFactory.makeMandala
//    call site compiles until it's switched to MandalaRenderer. Can be removed
//    once the factory is updated.

struct MandalaUniforms {
    float rot;
    float hue;
    float bass;
    float treble;
    float2 resolution;
};

struct MVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex MVSOut mandala_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    MVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    // No-op fallback — the factory now routes to MandalaRenderer (trail version).
    return float4(0.0);
}
