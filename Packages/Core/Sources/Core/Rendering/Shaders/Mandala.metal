#include <metal_stdlib>
using namespace metal;

struct MandalaUniforms {
    float rot;        // radians, CPU-accumulated
    float hue;        // 0..1, CPU-accumulated
    float bass;
    float treble;
    float2 resolution;
    // Track-mood tail — matches Swift MandalaUniforms field order.
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
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

// TRUE-distance signed distance function for a regular polygon — Iñigo Quilez.
// https://iquilezles.org/articles/distfunctions2d/
static float sdRegularPolygon(float2 p, float r, int n) {
    float an  = M_PI_F / float(n);
    float2 acs = float2(cos(an), sin(an));

    // Normalize theta to [0, 2π) so fmod gives consistent results; Metal's fmod
    // can return negatives (unlike GLSL's mod which wraps to [0, y)).
    float theta = atan2(p.x, p.y);
    if (theta < 0.0) theta += 2.0 * M_PI_F;
    float bn = fmod(theta, 2.0 * an) - an;
    p = length(p) * float2(cos(bn), abs(sin(bn)));

    // True perpendicular distance to one edge treated as a line segment.
    p -= r * acs;
    p.y += clamp(-p.y, 0.0, r * acs.y);
    return length(p) * sign(p.x);
}

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Source-over composite helper — paint `src` over the existing accumulator.
static float4 over(float4 dst, float3 srcRGB, float srcAlpha) {
    return float4(srcRGB * srcAlpha + dst.rgb * (1.0 - srcAlpha),
                  srcAlpha         + dst.a   * (1.0 - srcAlpha));
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    float maxR = 0.38 * fillFactor;
    float lineW = 0.0022 + u.bass * 0.0030;
    float haloW = 0.005  + u.bass * 0.007;
    float radiusScale = 0.55 + u.bass * 0.60;
    float baseAlpha = 0.75 + u.bass * 0.25;

    float4 accum = float4(0.0);

    // Web recipe: 6 layers, sides = (i % 2 == 0) ? 6 : 3.
    // Each layer is drawn TWICE — primary polygon + secondary offset by
    // half-sector at 0.72× radius. Two triangles at 60° offset = hexagram
    // (Star of David); two hexagons at 30° offset = a 12-pointed star — that's
    // where the "variety" in the reference comes from, not from varying `sides`.
    for (int i = 0; i < 6; i++) {
        int sides = (i % 2 == 0) ? 6 : 3;

        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float layerRot = u.rot * dir + float(i) * M_PI_F / 6.0;

        float r = maxR * (float(i) + 1.0) / 6.0 * radiusScale;

        // Valence biases the layer palette; add 1.0 before fmod to keep positive
        // before wrapping. Neutral 0.5 = zero offset.
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0) + (u.valence - 0.5) * 0.4 + 1.0, 1.0);
        // Energy fades saturation; neutral 0.5 → 0.8 (close to legacy 1.0 full).
        float3 lineCol = hsl2rgb(layerHue, 0.6 + u.energy * 0.4, 0.62);

        // Primary polygon.
        {
            float2 p = rot2(uv, layerRot);
            float d = sdRegularPolygon(p, r, sides);
            float absD = abs(d);
            float core = smoothstep(lineW, lineW * 0.1, absD);
            float glow = exp(-absD / haloW) * 0.32;
            float srcA = clamp(baseAlpha * (core + glow), 0.0, 1.0);
            accum = over(accum, lineCol, srcA);
        }

        // Secondary polygon — half-sector offset, 0.72× scale. This is the trick
        // that turns the triangle layers into hexagrams and the hex layers into
        // 12-pointed stars.
        {
            float halfSector = M_PI_F / float(sides);
            float2 p = rot2(uv, layerRot + halfSector);
            float d = sdRegularPolygon(p, r * 0.72, sides);
            float absD = abs(d);
            float core = smoothstep(lineW, lineW * 0.1, absD);
            float glow = exp(-absD / haloW) * 0.32;
            float srcA = clamp(baseAlpha * (core + glow), 0.0, 1.0);
            accum = over(accum, lineCol, srcA);
        }
    }

    return float4(accum.rgb, 1.0);
}
