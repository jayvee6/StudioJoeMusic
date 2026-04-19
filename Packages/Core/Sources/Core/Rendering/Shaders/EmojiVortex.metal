#include <metal_stdlib>
using namespace metal;

struct VortexUniforms {
    float time;
    float bass;
    float treble;
    float twist;          // spread tightness (world-space rad / unit radius)
    float scale;          // overall zoom
    float2 resolution;
    float2 atlasGrid;     // columns, rows of atlas (e.g. 4, 3)
};

struct VVSOut {
    float4 position [[position]];
    float2 uv;
    float emojiIndex;
};

constant int ARMS = 12;
constant int STEPS = 9;

vertex VVSOut vortex_vs(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        constant VortexUniforms& u [[buffer(0)]]) {
    int arm = int(iid) / STEPS;
    int step = int(iid) % STEPS;

    float pitch = 0.065 * u.scale;
    float radius = float(step + 3) * pitch;   // start far enough out that 12 emojis fit

    float baseAngle = float(arm) * (2.0 * M_PI_F / float(ARMS));
    float swirl = u.time * 0.22 + u.bass * 1.2;
    float angle = baseAngle + radius * u.twist + swirl;

    float aspect = u.resolution.x / u.resolution.y;
    float2 center_world = float2(cos(angle), sin(angle)) * radius;
    float2 center_clip = float2(center_world.x / aspect, center_world.y);

    // Emoji size: small core + mild growth with radius, slight treble pop.
    float emojiSize_world = 0.028 + radius * 0.035;
    emojiSize_world *= (1.0 + u.treble * 0.20);
    float emojiSize_x = emojiSize_world / aspect;
    float emojiSize_y = emojiSize_world;

    // Quad corners from vid (triangle strip 0..3)
    float cx = (vid & 1u) == 0u ? -1.0 : 1.0;
    float cy = (vid & 2u) == 0u ? -1.0 : 1.0;

    VVSOut o;
    o.position = float4(center_clip.x + cx * emojiSize_x,
                        center_clip.y + cy * emojiSize_y,
                        0.0, 1.0);
    // atlas UV local to one cell: y flipped so emoji sits upright
    o.uv = float2((cx + 1.0) * 0.5, 1.0 - (cy + 1.0) * 0.5);
    o.emojiIndex = float(arm);
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
    return color;
}
