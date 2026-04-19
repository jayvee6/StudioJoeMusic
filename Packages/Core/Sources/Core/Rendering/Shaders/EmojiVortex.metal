#include <metal_stdlib>
using namespace metal;

struct VortexUniforms {
    float time;
    float bass;
    float treble;
    float twist;           // radians per unit radius (web's phylloSpread * 0.00025 analog)
    float scale;           // overall radial zoom
    float rippleAmp;       // how far bass-history ripple displaces each step
    float2 resolution;
    float2 atlasGrid;
};

struct VVSOut {
    float4 position [[position]];
    float2 uv;
    float emojiIndex;
    float alpha;
};

constant int ARMS = 12;
constant int STEPS = 13;

vertex VVSOut vortex_vs(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        constant VortexUniforms& u [[buffer(0)]],
                        constant float* bassHistory [[buffer(1)]]) {
    int arm = int(iid) / STEPS;
    int step = int(iid) % STEPS;

    // Step normalized 0..~1 for size/alpha ramps (skip the exact centre).
    float t = float(step + 1) / float(STEPS + 1);

    // Base radial position: minR inner, maxR outer, mapped linearly by t.
    float minR = 0.10 * u.scale;
    float maxR = 0.82 * u.scale;
    float baseRadius = mix(minR, maxR, t);

    // Bass-history ripple — each step lags one frame behind the inner one,
    // producing the signature outward-traveling wave. Matches web's
    // bassHistory[step * rippleStepSize] with rippleStepSize=1.
    int historyIdx = clamp(step, 0, 15);
    float delayedBass = bassHistory[historyIdx];
    float radius = baseRadius + delayedBass * u.rippleAmp;

    // Phyllotaxis: each arm starts at baseAngle and twists with r.
    float baseAngle = float(arm) * (2.0 * M_PI_F / float(ARMS));
    float swirl = u.time * 0.24;                 // constant-rate tunnel rotation
    float angle = baseAngle + radius * u.twist + swirl;

    float aspect = u.resolution.x / u.resolution.y;
    float2 center_world = float2(cos(angle), sin(angle)) * radius;
    float2 center_clip = float2(center_world.x / aspect, center_world.y);

    // Emoji size: grows outward, plus strong treble flash (web's 1 + treble*1.2).
    float size_world = 0.028 + t * 0.08;
    size_world *= (1.0 + u.treble * 1.0);
    float size_x = size_world / aspect;
    float size_y = size_world;

    // Alpha ramp: inner dimmer, outer brighter — matches web's 0.35 + t*0.65.
    float alpha = 0.35 + t * 0.65;

    float cx = (vid & 1u) == 0u ? -1.0 : 1.0;
    float cy = (vid & 2u) == 0u ? -1.0 : 1.0;

    VVSOut o;
    o.position = float4(center_clip.x + cx * size_x,
                        center_clip.y + cy * size_y,
                        0.0, 1.0);
    o.uv = float2((cx + 1.0) * 0.5, 1.0 - (cy + 1.0) * 0.5);
    o.emojiIndex = float(arm);
    o.alpha = alpha;
    return o;
}

fragment float4 vortex_fs(VVSOut in [[stage_in]],
                          texture2d<float> atlas [[texture(0)]],
                          constant VortexUniforms& u [[buffer(0)]]) {
    int idx = int(in.emojiIndex);
    int cols = int(u.atlasGrid.x);
    int rows = int(u.atlasGrid.y);
    int col = idx % cols;
    int row = idx / cols;

    float2 cellSize = float2(1.0 / float(cols), 1.0 / float(rows));
    float2 cellOrigin = float2(float(col), float(row)) * cellSize;
    float2 atlasUV = cellOrigin + in.uv * cellSize;

    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float4 color = atlas.sample(s, atlasUV);
    // Premultiplied alpha so blend math stays correct.
    color.rgb *= in.alpha;
    color.a   *= in.alpha;
    return color;
}
