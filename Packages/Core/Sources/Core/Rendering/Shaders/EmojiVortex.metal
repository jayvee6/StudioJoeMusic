#include <metal_stdlib>
using namespace metal;

struct VortexUniforms {
    float tunnelRot;       // CPU-accumulated from (0.004 + mid*0.008)/frame
    float bass;
    float treble;
    float twist;           // radians per unit radius
    float scale;           // overall radial zoom
    float rippleAmp;       // how far bass-history ripple displaces each step
    float2 resolution;
    float2 atlasGrid;
    // Track-mood tail — matches Swift VortexUniforms field order.
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
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

    // Step normalized to [~0, 1). Web: t = step / 12; radius = minR + (maxR-minR) * t.
    float t = float(step) / float(STEPS - 1);

    // Fill factor so the vortex extends into the long dimension of the screen.
    float aspect = u.resolution.x / u.resolution.y;
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    float minR = 0.10 * u.scale * fillFactor;
    float maxR = 0.82 * u.scale * fillFactor;
    float baseRadius = mix(minR, maxR, t);

    // Bass-history ripple — each step lags one frame behind the inner one.
    int historyIdx = clamp(step, 0, 15);
    float delayedBass = bassHistory[historyIdx];
    float radius = baseRadius + delayedBass * u.rippleAmp;

    // Phyllotaxis arm layout + CPU-integrated tunnel rotation. Danceability
    // scales the accumulated tunnel rotation — neutral 0.5 → 1.0 (baseline).
    float danceMul = 0.7 + u.danceability * 0.6;
    float baseAngle = float(arm) * (2.0 * M_PI_F / float(ARMS));
    float angle = baseAngle + radius * u.twist + u.tunnelRot * danceMul;

    float2 center_world = float2(cos(angle), sin(angle)) * radius;
    float2 center_clip = float2(center_world.x / aspect, center_world.y);

    // Web: emoji size = shortSide * (0.03 + t * 0.11) * (1 + treble * 1.2).
    // `treble` is CPU-smoothed upstream so the flash is punchy but not strobing per frame.
    float size_world = 0.030 + t * 0.10;
    size_world *= (1.0 + u.treble * 0.9);
    float size_x = size_world / aspect;
    float size_y = size_world;

    // Alpha ramp — inner dimmer, outer brighter.
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
    color.rgb *= in.alpha;
    color.a   *= in.alpha;
    return color;
}
