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

fragment float4 spiral_fs(SVSOut in [[stage_in]],
                          constant SpiralUniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float r = length(uv);
    float theta = atan2(uv.y, uv.x);

    float pitch = 0.085;
    float armCount = 2.0;
    float armSpacing = pitch / armCount;
    float speed = 0.22 + u.bass * 0.45;
    float offset = u.time * speed;

    // Phase distance to nearest arm of the 2-arm Archimedean spiral
    float phase = fmod(r - offset - pitch * theta / (2.0 * M_PI_F), armSpacing);
    if (phase < 0.0) phase += armSpacing;
    float dist = min(phase, armSpacing - phase);

    float strokeHW = 0.012 + u.bass * 0.008;
    float intensity = smoothstep(strokeHW, 0.0, dist);

    // Secondary "shadow" stroke for a bit of 3D
    float strokeHW2 = strokeHW * 2.2;
    float intensity2 = smoothstep(strokeHW2, strokeHW, dist) * 0.35;

    float hue = u.time * 0.06 + r * 1.25 + u.treble * 0.35;
    float3 base = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));

    float3 color = base * intensity + base * 0.2 * intensity2;

    // Warm bg fill
    float3 bg = float3(0.03, 0.015, 0.04) + float3(0.02, 0.01, 0.03) * (1.0 - r);
    color += bg;

    // Vignette
    color *= smoothstep(1.05, 0.0, r);

    color = pow(max(color, float3(0.0)), float3(0.4545));
    return float4(color, 1.0);
}
