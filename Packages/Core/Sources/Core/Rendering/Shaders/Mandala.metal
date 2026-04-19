#include <metal_stdlib>
using namespace metal;

struct MandalaUniforms {
    float time;
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

// Stroke of a polygon SDF with a soft core + wide glow halo.
// width scales with bass (web spec: 1.5 + bass*4 pixels, normalized to uv space).
static float strokeWithGlow(float d, float width, float glowStrength) {
    float absD = abs(d);
    float core = smoothstep(width, width * 0.3, absD);       // thin bright core
    float glow = exp(-absD * (8.0 - glowStrength * 4.0)) * glowStrength;
    return core + glow * 0.6;
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float3 color = float3(0.0);

    const int ringCount = 6;
    for (int i = 0; i < ringCount; i++) {
        int sides = (i % 2 == 0) ? 6 : 3;
        float ringScale = 0.09 + float(i) * 0.07 + u.bass * 0.035;
        float direction = (i % 2 == 0) ? 1.0 : -1.0;
        float ringAngle = u.time * 0.22 * (1.0 - float(i) * 0.12) * direction;
        float2 rotated = rot2(uv, ringAngle);

        // Stroke width modulates with bass like the web version (1.5 + bass*4 px, normalized).
        float width = 0.003 + u.bass * 0.009;
        float glow = 0.35 + u.bass * 0.75;

        // Primary polygon
        float d1 = sdPolygon(rotated, sides, ringScale);
        float s1 = strokeWithGlow(d1, width, glow);

        // Secondary polygon offset by half-sector at 0.72× scale (web's overlapping double).
        float halfSector = M_PI_F / float(sides);
        float2 rotated2 = rot2(rotated, halfSector);
        float d2 = sdPolygon(rotated2, sides, ringScale * 0.72);
        float s2 = strokeWithGlow(d2, width, glow);

        // Hue offset per layer: 42° (web value).
        float hue = u.time * 0.04 + float(i) * (42.0 / 360.0) + u.treble * 0.35;
        float3 base = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));

        // Additive blend both layers so their overlapping intersections brighten.
        color += base * (s1 + s2 * 0.9) * (0.45 + u.bass * 0.55);
    }

    // Subtle center haze so the cumulative bloom doesn't look flat.
    float centerHaze = smoothstep(0.5, 0.0, length(uv)) * 0.05 * (0.5 + u.bass);
    color += float3(0.2, 0.22, 0.35) * centerHaze;

    return float4(max(color, float3(0.0)), 1.0);
}
