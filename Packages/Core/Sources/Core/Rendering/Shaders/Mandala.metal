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

// Crisp stroke + narrow tinted halo. `w` is the full half-width of the sharp line;
// `glowWidth` controls only the exponential halo so overlapping polygons don't wash
// into a diffuse field.
static float strokeContribution(float d, float w, float glowWidth) {
    float absD = abs(d);
    // Sharp core — fully opaque at absD = 0, falls to 0 at absD = w.
    float core = smoothstep(w, w * 0.15, absD);
    // Narrow exponential halo that decays quickly, stays near the line.
    float halo = exp(-absD / max(glowWidth, 0.00001)) * 0.35;
    return core + halo;
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    // Short-side square projection so sizes match min(W,H).
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    // Fill factor — expands the visualizer into the long dimension of the screen so
    // portrait doesn't feel like a small centered square. Capped so the outermost
    // layer doesn't clip off the short side too aggressively.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    float3 color = float3(0.0);

    // Web: 6 layers, maxR = shortSide * 0.38. Scaled up by fillFactor for orientation fit.
    float maxR = 0.38 * fillFactor;
    const int ringCount = 6;
    float radiusScale = 0.40 + u.bass * 0.90;

    // Sharp line width (1.5 + bass*4 px ≈ 0.0025 + bass*0.006 baseline).
    float lineW = 0.0028 + u.bass * 0.0055;
    // Glow halo width — narrow so polygons stay crisp.
    float glowWidth = 0.0035 + u.bass * 0.010;

    // Use max() blending instead of additive sum so overlapping layers don't clip to white.
    for (int i = 0; i < ringCount; i++) {
        int sides = (i % 2 == 0) ? 6 : 3;

        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float2 p = rot2(uv, u.rot * dir);

        float r = maxR * (float(i) + 1.0) / float(ringCount) * radiusScale;

        // Web layer hue: (hue + i*42°) wrapped.
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0), 1.0);
        // HSL(hue, 100%, 65%) — bright saturated polygon stroke.
        float3 base = hsl2rgb(layerHue, 1.0, 0.62);
        float intensity = 0.40 + u.bass * 0.55;

        // Primary polygon stroke.
        float d1 = sdPolygon(p, sides, r);
        float s1 = strokeContribution(d1, lineW, glowWidth);
        float3 c1 = base * s1 * intensity;

        // Secondary polygon: offset by half sector, scaled to 0.72×.
        float halfSector = M_PI_F / float(sides);
        float2 p2 = rot2(p, halfSector);
        float d2 = sdPolygon(p2, sides, r * 0.72);
        float s2 = strokeContribution(d2, lineW, glowWidth);
        float3 c2 = base * s2 * intensity * 0.90;

        // Max-blend against the accumulator per-channel so bright polygons dominate
        // without washing overlaps into white.
        color = max(color, c1);
        color = max(color, c2);
    }

    // Subtle center haze so full-bass frames don't feel empty at the core.
    float centerHaze = smoothstep(0.45, 0.0, length(uv)) * 0.05 * (0.4 + u.bass);
    color += float3(0.22, 0.24, 0.38) * centerHaze;

    return float4(max(color, float3(0.0)), 1.0);
}
