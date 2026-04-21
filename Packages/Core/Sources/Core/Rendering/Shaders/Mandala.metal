#include <metal_stdlib>
using namespace metal;

// Uniforms carry state accumulated on the CPU side (rot, hue) so motion is
// frame-rate-correct and doesn't jitter on beats — matches web's mandalaRot / mandalaHue.
struct MandalaUniforms {
    float rot;        // radians, accumulated; base layer rotation
    float hue;        // 0..1, accumulated; base hue
    float bass;       // 0..1, current frame
    float treble;     // 0..1, current frame
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

// HSL → RGB (CSS semantics). h in [0..1], s in [0..1], l in [0..1].
static float3 hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(
        abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
        0.0, 1.0
    );
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

// Regular-polygon SDF. p is a point in world units, n = #sides, r = inscribed radius.
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

// Canvas-2D-like stroke: thin core of width `w`, plus exponential glow halo whose
// falloff is widened by `glowAmount` (matches web's shadowBlur: 8 + bass*24 px).
static float strokeWithGlow(float d, float w, float glowAmount) {
    float absD = abs(d);
    float core = smoothstep(w, w * 0.35, absD);
    float glowWidth = 0.008 + glowAmount * 0.022;
    float halo = exp(-absD / glowWidth);
    return core + halo * glowAmount * 0.45;
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    // Square the viewport on the short side so the mandala scale matches min(W,H).
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    float3 color = float3(0.0);

    // Web: 6 layers, maxR = shortSide * 0.38 in px; in our [-0.5, 0.5] unit space that's 0.38.
    // Per layer: r = maxR * (i+1)/6 * (0.4 + bass*0.9).
    const float maxR = 0.38;
    const int ringCount = 6;
    float radiusScale = 0.40 + u.bass * 0.90;

    // Stroke width (web: 1.5 + bass*4 px, ~1.5/shortSide ≈ 0.002 baseline).
    float lineW = 0.0025 + u.bass * 0.006;
    float glowAmount = 0.35 + u.bass * 0.95;

    for (int i = 0; i < ringCount; i++) {
        int sides = (i % 2 == 0) ? 6 : 3;

        // Layer rotation — even indices +rot, odd -rot (web parity flip).
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float layerRot = u.rot * dir;
        float2 p = rot2(uv, layerRot);

        // Layer radius
        float r = maxR * (float(i) + 1.0) / float(ringCount) * radiusScale;

        // Layer hue: web uses `(hue + i*42) % 360`.
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0), 1.0);
        // Main stroke: HSL(hue, 100%, 65%) at alpha-like intensity 0.35 + bass*0.65.
        float3 base = hsl2rgb(layerHue, 1.0, 0.65);
        float intensity = 0.35 + u.bass * 0.65;

        // Primary polygon
        float d1 = sdPolygon(p, sides, r);
        float s1 = strokeWithGlow(d1, lineW, glowAmount);

        // Secondary polygon, web's overlapping double: offset by half sector, r * 0.72.
        float halfSector = M_PI_F / float(sides);
        float2 p2 = rot2(p, halfSector);
        float d2 = sdPolygon(p2, sides, r * 0.72);
        float s2 = strokeWithGlow(d2, lineW, glowAmount);

        color += base * (s1 + s2 * 0.9) * intensity;
    }

    // Center haze — keeps the cumulative bloom from looking flat on heavy bass.
    float centerHaze = smoothstep(0.45, 0.0, length(uv)) * 0.06 * (0.5 + u.bass);
    color += float3(0.22, 0.24, 0.38) * centerHaze;

    return float4(max(color, float3(0.0)), 1.0);
}
