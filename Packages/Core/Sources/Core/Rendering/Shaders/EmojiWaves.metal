#include <metal_stdlib>
using namespace metal;

struct WavesUniforms {
    float time;
    float bass;
    float treble;
    float ringScale;
    float spin;
    float2 resolution;
    float2 atlasGrid;
};

struct WVSOut {
    float4 position [[position]];
    float2 uv;
    float emojiIndex;
    float alpha;
};

// Variable emoji counts per ring (matches web prototype): 1, 6, 12, 18, 24, 30 = 91 total.
constant int kRingCount = 6;

vertex WVSOut waves_vs(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       constant WavesUniforms& u [[buffer(0)]],
                       constant float* bassHistory [[buffer(1)]]) {
    int id = int(iid);

    // Cumulative counts: ring 0 holds 1 emoji (centerpiece), ring i holds i*6.
    // Running totals: [1, 7, 19, 37, 61, 91].
    int cum[6] = {1, 7, 19, 37, 61, 91};
    int ring = 0;
    for (int i = 0; i < kRingCount; i++) {
        if (id < cum[i]) { ring = i; break; }
    }
    int ringStart = (ring == 0) ? 0 : cum[ring - 1];
    int slot = id - ringStart;
    int perRing = (ring == 0) ? 1 : ring * 6;

    // Radial position — base spacing times ring index, scaled by bass ripple delayed
    // per ring (matches web's bassHistory[ring*2] outward traveling wave).
    float baseR = (float(ring) + 0.9) * u.ringScale;
    int historyIdx = min(ring * 2, 15);
    float delayedBass = bassHistory[historyIdx];
    float pulseMult = 1.0 + delayedBass * 0.35;
    float radius = (ring == 0) ? 0.0 : baseR * pulseMult;

    // Angular position — alternating spin direction per ring; ring 0 simply rotates.
    float dir = (ring % 2 == 0) ? 1.0 : -1.0;
    float ringSpin = u.time * (0.12 + u.spin * 0.35) * dir;
    float angle = (ring == 0)
        ? ringSpin
        : float(slot) / float(perRing) * 2.0 * M_PI_F + ringSpin;

    float aspect = u.resolution.x / u.resolution.y;
    float2 center_world = float2(cos(angle), sin(angle)) * radius;
    float2 center_clip = float2(center_world.x / aspect, center_world.y);

    // Emoji sizing: inner rings larger, bass pulse, centerpiece bigger.
    float size_world = 0.05 * (1.0 - float(ring) * 0.08) * (1.0 + delayedBass * 0.32);
    if (ring == 0) size_world *= 1.35;

    float size_x = size_world / aspect;
    float size_y = size_world;

    float alpha = 0.75 + delayedBass * 0.25;

    float cx = (vid & 1u) == 0u ? -1.0 : 1.0;
    float cy = (vid & 2u) == 0u ? -1.0 : 1.0;

    WVSOut o;
    o.position = float4(center_clip.x + cx * size_x,
                        center_clip.y + cy * size_y,
                        0.0, 1.0);
    o.uv = float2((cx + 1.0) * 0.5, 1.0 - (cy + 1.0) * 0.5);
    // Emoji pick: web's EMOJIS[(ring*4 + slot) % 12].
    o.emojiIndex = float((ring * 4 + slot) % 12);
    o.alpha = alpha;
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
    color.rgb *= in.alpha;
    color.a   *= in.alpha;
    return color;
}
