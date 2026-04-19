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

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float3 color = float3(0.0);

    const int ringCount = 6;
    for (int i = 0; i < ringCount; i++) {
        int sides = (i % 2 == 0) ? 6 : 3;
        float ringScale = 0.10 + float(i) * 0.085 + u.bass * 0.035;
        float ringAngle = u.time * 0.22 * (1.0 - float(i) * 0.12)
                          + u.treble * 1.6 * (1.0 + float(i) * 0.05);
        float2 rotated = rot2(uv, ringAngle);

        float d = sdPolygon(rotated, sides, ringScale);
        float edge = smoothstep(0.0045, 0.0, abs(d));

        float hue = u.time * 0.04 + float(i) * 0.17 + u.treble * 0.35;
        float3 base = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
        color += base * edge * (0.45 + u.bass * 0.55);
    }

    // subtle vignette
    float vign = smoothstep(1.05, 0.2, length(uv));
    color *= vign;

    color = pow(max(color, float3(0.0)), float3(0.4545));
    return float4(color, 1.0);
}
