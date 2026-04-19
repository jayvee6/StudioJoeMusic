#include <metal_stdlib>
using namespace metal;

struct HypnoUniforms {
    float time;
    float bass;
    float treble;
    float2 resolution;
};

struct HVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex HVSOut hypno_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    HVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

fragment float4 hypno_fs(HVSOut in [[stage_in]],
                         constant HypnoUniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float r = length(uv);

    float speed = 0.18 + u.bass * 0.35;
    float spacing = 0.055;
    float bigOffset = u.time * speed;

    float ringR = r - bigOffset;
    float ringIdx = floor(ringR / spacing);
    float parity = fmod(ringIdx + 256.0, 2.0);  // keeps parity stable w/ negatives

    // Soft edges between rings
    float localPhase = fract(ringR / spacing);
    float edge = min(localPhase, 1.0 - localPhase);
    float softness = smoothstep(0.0, 0.10, edge);

    float hue = u.time * 0.05 + u.treble * 0.5 + ringIdx * 0.03;
    float3 warm = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
    float3 cool = warm * 0.18;
    float3 color = mix(cool, warm, softness);
    color = parity < 1.0 ? color : color.bgr * 0.9 + float3(0.05);

    // Radial falloff
    color *= smoothstep(0.95, 0.0, r);
    // Bass brightens
    color *= (0.75 + u.bass * 0.5);

    return float4(max(color, float3(0.0)), 1.0);
}
