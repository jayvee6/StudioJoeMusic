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
                         constant HypnoUniforms& u [[buffer(0)]],
                         constant float* bassHistory [[buffer(1)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float r = length(uv);

    // Constant-rate offset. Speed modulated by bass caused jumps; brightness
    // modulation lives below, in the color path, which is jump-safe.
    float speed = 0.22;
    float spacing = 0.055;
    float bigOffset = u.time * speed;

    float ringR = r - bigOffset;
    float ringIdx = floor(ringR / spacing);

    // Outward traveling bass wave: ring N reads bassHistory[N] so each ring
    // lags one frame behind the one inside it. Clamp index to buffer length.
    int historyIdx = clamp(int(ringIdx) % 16, 0, 15);
    if (historyIdx < 0) historyIdx += 16;
    float delayedBass = bassHistory[historyIdx];

    // Parity: alternating light / dark stripes. +256 keeps mod2 stable with negatives.
    float parity = fmod(abs(ringIdx) + 256.0, 2.0);

    // Hue cycles slowly with time + treble.
    float hue = u.time * 0.05 + u.treble * 0.45;
    float3 warm = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));

    // Light stripes: near-white, brighter on delayed bass (wave propagates outward).
    float3 lightStripe = float3(0.82 + delayedBass * 0.18);
    // Dark stripes: colored, warm hue, also brighter on bass but much dimmer baseline.
    float3 darkStripe = warm * (0.15 + u.bass * 0.30);

    float3 color = parity < 1.0 ? lightStripe : darkStripe;

    // Soften stripe edges for less aliasing
    float localPhase = fract(ringR / spacing);
    float edge = min(localPhase, 1.0 - localPhase);
    float softness = smoothstep(0.0, 0.06, edge);
    color *= (0.6 + softness * 0.4);

    // Bass flash: when bass crosses 0.5, blend toward bright warm color as a strobe.
    float flash = smoothstep(0.5, 0.85, u.bass);
    color = mix(color, warm * 1.2, flash * 0.35);

    // Radial falloff
    color *= smoothstep(0.98, 0.05, r);

    return float4(max(color, float3(0.0)), 1.0);
}
