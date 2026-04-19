#include <metal_stdlib>
using namespace metal;

struct WavesUniforms {
    float time;
    float bass;
    float treble;
    float ringScale;   // base ring spacing
    float spin;        // 0..1 overall spin speed
    float2 resolution;
    float2 atlasGrid;
};

struct WVSOut {
    float4 position [[position]];
    float2 uv;
    float emojiIndex;
};

constant int RINGS = 6;
constant int PER_RING = 12;

vertex WVSOut waves_vs(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       constant WavesUniforms& u [[buffer(0)]]) {
    int ring = int(iid) / PER_RING;
    int slot = int(iid) % PER_RING;

    // Radius grows per ring; bass adds shimmer
    float radius = (float(ring) + 1.0) * u.ringScale;
    radius *= (1.0 + u.bass * 0.18);

    // Angle: evenly distributed, with per-ring spin offset
    float ringSpin = u.time * (0.15 + u.spin * 0.6) * (ring % 2 == 0 ? 1.0 : -1.0);
    float angle = float(slot) / float(PER_RING) * 2.0 * M_PI_F + ringSpin;

    float aspect = u.resolution.x / u.resolution.y;
    float2 center_world = float2(cos(angle), sin(angle)) * radius;
    float2 center_clip = float2(center_world.x / aspect, center_world.y);

    // Emoji size pulses with bass, shrinks at outer rings
    float size_world = 0.06 * (1.0 - float(ring) * 0.05) * (1.0 + u.bass * 0.35);
    float size_x = size_world / aspect;
    float size_y = size_world;

    float cx = (vid & 1u) == 0u ? -1.0 : 1.0;
    float cy = (vid & 2u) == 0u ? -1.0 : 1.0;

    WVSOut o;
    o.position = float4(center_clip.x + cx * size_x,
                        center_clip.y + cy * size_y,
                        0.0, 1.0);
    o.uv = float2((cx + 1.0) * 0.5, 1.0 - (cy + 1.0) * 0.5);
    // Ring picks emoji: cycle through atlas
    o.emojiIndex = float(ring % 12);
    return o;
}

fragment float4 waves_fs(WVSOut in [[stage_in]],
                         texture2d<float> atlas [[texture(0)]],
                         constant WavesUniforms& u [[buffer(0)]]) {
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
    return color;
}
