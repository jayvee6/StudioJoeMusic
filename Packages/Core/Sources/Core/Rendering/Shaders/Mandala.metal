#include <metal_stdlib>
using namespace metal;

struct MandalaUniforms {
    float rot;        // radians, CPU-accumulated
    float hue;        // 0..1, CPU-accumulated
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

static float3 hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(
        abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
        0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

// Regular-polygon SDF.
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

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    // Short-side square projection so sizes match min(W,H).
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    // Fill factor so the mandala grows into the screen's long dimension.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    // Reference shows crisp hairline neon polygons with a tight halo —
    // no bloom clouds, no motion trails. Keep line thin and glow narrow.
    float maxR = 0.38 * fillFactor;
    float lineW = 0.0022 + u.bass * 0.0030;
    float haloW = 0.005  + u.bass * 0.007;
    float radiusScale = 0.55 + u.bass * 0.60;

    // 6 distinct polygons — triangle, square, pentagon, hexagon, heptagon, octagon.
    const int SIDES[6] = {3, 4, 5, 6, 7, 8};

    float3 accum = float3(0.0);

    for (int i = 0; i < 6; i++) {
        int sides = SIDES[i];

        // Adjacent rings counter-rotate so the tilts alternate (matches reference).
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float layerRot = u.rot * dir + float(i) * M_PI_F / 6.0;
        float2 p = rot2(uv, layerRot);

        float r = maxR * (float(i) + 1.0) / 6.0 * radiusScale;

        // Distinct hue per layer (web: hue + i*42°).
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0), 1.0);
        float3 lineCol = hsl2rgb(layerHue, 1.0, 0.62);
        float alpha = 0.75 + u.bass * 0.25;

        float d = sdPolygon(p, sides, r);
        float absD = abs(d);

        // Sharp hairline core — smoothstep from lineW to 0.1*lineW keeps the line
        // opaque right up to its edge, so corners read as corners.
        float core = smoothstep(lineW, lineW * 0.1, absD);
        accum += lineCol * alpha * core;

        // Tight neon halo — narrow and dim so it only suggests a glow.
        float glow = exp(-absD / haloW) * 0.32;
        accum += lineCol * alpha * glow;
    }

    return float4(max(accum, float3(0.0)), 1.0);
}
