#include <metal_stdlib>
using namespace metal;

// Layout must match Swift RorschachUniforms exactly.
// 4 floats (16 bytes) before float2 resolution keeps it 8-byte aligned.
struct Uniforms {
    float time;
    float bass;
    float mid;
    float treble;
    float2 resolution;   // offset 16 — 8-byte aligned ✓
    float beatPulse;
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut rorschach_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Polynomial smooth minimum (Inigo Quilez)
static float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Value noise infrastructure for FBM ink-edge texture
static float hash2(float2 p) {
    p = fract(p * float2(127.1, 311.7));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash2(i),               hash2(i + float2(1, 0)), u.x),
               mix(hash2(i + float2(0, 1)), hash2(i + float2(1, 1)), u.x), u.y);
}

// 3-octave FBM — centered at 0 so it only perturbs the SDF boundary, no net drift
static float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * (vnoise(p) - 0.5);
        p   = p * 2.1 + float2(2.71, 1.83);
        a  *= 0.5;
    }
    return v;  // range ≈ [-0.44, 0.44]
}

// 2D smooth-union metaball SDF — 7 nodes in the right half-plane.
// The caller passes the folded point (abs(uv.x), uv.y) for bilateral symmetry.
// `scale` = bass/beat-driven radius multiplier; `speed` = mid-driven node chaos.
static float inkSDF(float2 p, float t, float scale, float speed) {
    float d = 1e6;

    // Node 0: central spine — anchors the whole shape near the seam
    {
        float2 n = float2(0.030, 0.000)
            + float2(sin(t * 0.31 * speed)        * 0.018,
                     cos(t * 0.27 * speed)        * 0.025);
        d = smin(d, length(p - n) - 0.140 * scale, 0.10);
    }
    // Node 1: upper inner wing lobe
    {
        float2 n = float2(0.110, 0.180)
            + float2(sin(t * 0.41 * speed + 1.10) * 0.025,
                     cos(t * 0.37 * speed + 2.30) * 0.025);
        d = smin(d, length(p - n) - 0.110 * scale, 0.09);
    }
    // Node 2: lower inner wing lobe (slight y-asymmetry for naturalism)
    {
        float2 n = float2(0.115, -0.185)
            + float2(sin(t * 0.29 * speed + 3.70) * 0.025,
                     cos(t * 0.43 * speed + 0.90) * 0.025);
        d = smin(d, length(p - n) - 0.108 * scale, 0.09);
    }
    // Node 3: outer upper wing tip
    {
        float2 n = float2(0.175, 0.082)
            + float2(sin(t * 0.53 * speed + 2.10) * 0.030,
                     cos(t * 0.23 * speed + 4.10) * 0.028);
        d = smin(d, length(p - n) - 0.082 * scale, 0.08);
    }
    // Node 4: outer lower wing tip
    {
        float2 n = float2(0.165, -0.093)
            + float2(sin(t * 0.47 * speed + 5.10) * 0.030,
                     cos(t * 0.61 * speed + 1.70) * 0.028);
        d = smin(d, length(p - n) - 0.078 * scale, 0.08);
    }
    // Node 5: upper head / butterfly-top protrusion
    {
        float2 n = float2(0.040, 0.370)
            + float2(sin(t * 0.36 * speed + 0.50) * 0.020,
                     cos(t * 0.51 * speed + 3.30) * 0.030);
        d = smin(d, length(p - n) - 0.080 * scale, 0.075);
    }
    // Node 6: lower tail protrusion
    {
        float2 n = float2(0.038, -0.355)
            + float2(sin(t * 0.33 * speed + 4.20) * 0.018,
                     cos(t * 0.44 * speed + 1.20) * 0.025);
        d = smin(d, length(p - n) - 0.072 * scale, 0.068);
    }

    return d;
}

fragment float4 rorschach_fs(VSOut in [[stage_in]],
                              constant Uniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    // Coordinate space: y ∈ [-0.5, 0.5], x ∈ [-aspect/2, +aspect/2].
    // Portrait phones give a narrow-x, tall-y canvas — matching a real Rorschach card.
    float2 uv = (in.uv - 0.5) * float2(aspect, 1.0);

    // Bilateral symmetry: fold to the right half-plane
    float2 p = float2(abs(uv.x), uv.y);

    float t = u.time;

    // Slow organic breathing (two incommensurate periods so it never repeats exactly)
    float breath = 1.0 + sin(t * 0.38) * 0.035 + cos(t * 0.25) * 0.020;

    // Bass expands blobs; beat-pulse delivers a sharp splat on each onset
    float scale = breath * (1.0 + u.bass * 0.35 + u.beatPulse * 0.22);

    // Mid + danceability govern how chaotically the nodes drift
    float speed = 1.0 + u.mid * 2.0 + (u.danceability - 0.5) * 0.5;

    // Raw metaball SDF
    float d = inkSDF(p, t, scale, speed);

    // Treble drives FBM ripple amplitude along blob edges (fine ink texture)
    float noiseAmp = 0.010 + u.treble * 0.022;
    float2 noiseCoord = p * 10.0 + float2(t * 0.20, t * 0.15);
    d += fbm3(noiseCoord) * noiseAmp;

    // Soft threshold — smooth organic edge, not a hard clip
    float edgeW = 0.013;
    float inkMask = 1.0 - smoothstep(-edgeW, edgeW, d);

    // Depth gradient: 0 = edge, 1 = deep inside.
    // Maps the SDF field to a subtle black → midnight-navy gradient.
    // Valence modulates how pronounced the blue depth tint is:
    //   low valence (melancholic) → richer navy; high valence → near-pure black.
    float depth    = clamp(-d / 0.22, 0.0, 1.0);
    float navyAmt  = depth * depth * clamp(1.3 - u.valence * 1.6, 0.0, 0.8);
    float3 inkColor = mix(float3(0.0),              // pure black at edges
                          float3(0.04, 0.05, 0.20), // deep midnight navy at center
                          navyAmt);

    // Warm parchment background — classic Rorschach card
    float3 bgColor = float3(0.962, 0.952, 0.938);

    float3 col = mix(bgColor, inkColor, inkMask);
    return float4(col, 1.0);
}
