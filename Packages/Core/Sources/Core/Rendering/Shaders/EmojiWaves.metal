#include <metal_stdlib>
using namespace metal;

struct WavesUniforms {
    float waveSpin;       // CPU-accumulated at 0.008/frame (web: waveSpin += 0.008 * waveSpinSpeed)
    float bass;
    float treble;
    float ringScale;      // base ring spacing
    float2 resolution;
    float2 atlasGrid;
    // Track-mood tail — matches Swift WavesUniforms field order.
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
};

struct WVSOut {
    float4 position [[position]];
    float2 uv;
    float emojiIndex;
    float alpha;
};

constant int kRingCount = 6;

vertex WVSOut waves_vs(uint vid [[vertex_id]],
                       uint iid [[instance_id]],
                       constant WavesUniforms& u [[buffer(0)]],
                       constant float* bassHistory [[buffer(1)]]) {
    int id = int(iid);

    // Web: ring 0 holds 1 emoji, ring i holds i*6. Running totals [1, 7, 19, 37, 61, 91].
    int cum[6] = {1, 7, 19, 37, 61, 91};
    int ring = 0;
    for (int i = 0; i < kRingCount; i++) {
        if (id < cum[i]) { ring = i; break; }
    }
    int ringStart = (ring == 0) ? 0 : cum[ring - 1];
    int slot = id - ringStart;
    int perRing = (ring == 0) ? 1 : ring * 6;

    // Fill factor so rings extend into the long dimension of the screen.
    float aspect = u.resolution.x / u.resolution.y;
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    // Radial position — base spacing * ring index, delayed-bass pulse per ring.
    // Web: baseR = (ring+1) * shortSide * 0.09; pulseR = baseR * (1 + delayedBass * 0.45).
    // Energy scales the bass-driven outward pulse. Neutral 0.5 → 1.0.
    float energyMul = 0.6 + u.energy * 0.8;
    float baseR = (float(ring) + 1.0) * u.ringScale * fillFactor;
    int historyIdx = min(ring * 2, 15);
    float delayedBass = bassHistory[historyIdx];
    float pulseMult = 1.0 + delayedBass * 0.45 * energyMul;
    float radius = (ring == 0) ? 0.0 : baseR * pulseMult;

    // Angular position — alternating spin direction per ring (web's ring i spins i%2 parity).
    float dir = (ring % 2 == 0) ? 1.0 : -1.0;
    float ringSpinPhase = u.waveSpin * dir;
    float angle = (ring == 0)
        ? ringSpinPhase
        : float(slot) / float(perRing) * 2.0 * M_PI_F + ringSpinPhase;

    float2 center_world = float2(cos(angle), sin(angle)) * radius;
    float2 center_clip = float2(center_world.x / aspect, center_world.y);

    // Emoji sizing: web — 14 + ring*3 + delayedBass * 18 px on shortSide.
    // shortSide ≈ 1.0 in our units. 14/shortSide ≈ 0.045 baseline; ring=5 → +0.015; bass → +0.06.
    float size_world = 0.045 + float(ring) * 0.004 + delayedBass * 0.06;
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
    // Web's emoji pick: EMOJIS[(ring*4 + j) % 12]
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
