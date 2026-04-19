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

    float pitch = 0.10;
    float armCount = 2.0;
    float armSpacing = pitch / armCount;    // 0.05
    // Constant-rate offset. Bass drives stroke width + brightness, not speed, so the
    // spiral doesn't jump backward on every beat.
    float speed = 0.18;
    float offset = u.time * speed;

    // Phase distance to nearest arm of the 2-arm Archimedean spiral.
    // Mod by armSpacing keeps parity correct across the theta=0 seam.
    float phase = fmod(r - offset - pitch * theta / (2.0 * M_PI_F), armSpacing);
    if (phase < 0.0) phase += armSpacing;
    float dist = min(phase, armSpacing - phase);

    float strokeHW = 0.008 + u.bass * 0.006;   // well under armSpacing/2 = 0.025
    float intensity = smoothstep(strokeHW, 0.0, dist);

    // Soft halo outside the stroke, bounded so it never bleeds into neighbor arms.
    float haloHW = min(strokeHW * 1.6, armSpacing * 0.45);
    float intensity2 = smoothstep(haloHW, strokeHW, dist) * 0.2;

    float hue = u.time * 0.06 + r * 1.25 + u.treble * 0.35;
    float3 base = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));

    float3 color = base * intensity + base * 0.35 * intensity2;

    // Warm bg fill
    float3 bg = float3(0.02, 0.01, 0.025) + float3(0.015, 0.008, 0.02) * (1.0 - r);
    color += bg;

    // Vignette
    color *= smoothstep(1.05, 0.0, r);

    return float4(max(color, float3(0.0)), 1.0);
}
