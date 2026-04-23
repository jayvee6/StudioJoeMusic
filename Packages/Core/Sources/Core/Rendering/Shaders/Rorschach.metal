#include <metal_stdlib>
using namespace metal;

// Layout must match Swift RorschachUniforms exactly (48 bytes total).
// 4 floats (16 bytes) before float2 resolution keeps it 8-byte aligned.
// `nodeT` is an oscillating drift-time (see CPU-side RorschachState) used
// only for metaball positions + breath; `time` is monotonic real time and
// drives the edge noise animation so splatter never reverses.
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
    float nodeT;         // replaces earlier _metalPad — same 48-byte total
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

// 2D smooth-union metaball SDF — 9 nodes in the right half-plane, plus 2
// beat-triggered tertiary droplets (only visible when beat > 0.25). Nodes
// are spread wider in x and use tight smin radii so distinct blobs form
// with narrow bridges — the fragmented character of real Rorschach cards.
//
// `nt`    = oscillating node-drift time (see CPU dual-time driver).
// `scale` = bass/beat-driven radius multiplier.
// `speed` = mid-driven node drift speed.
// `beat`  = raw beatPulse — punches outlier nodes to sync drops with onsets.
static float inkSDF(float2 p, float nt, float scale, float speed, float beat) {
    float d = 1e6;

    // Node 0: central spine — small, anchors the seam without dominating
    {
        float2 n = float2(0.025, 0.000)
            + float2(sin(nt * 0.31 * speed)        * 0.018,
                     cos(nt * 0.27 * speed)        * 0.025);
        d = smin(d, length(p - n) - 0.085 * scale, 0.045);
    }
    // Node 1: upper inner wing (pushed outward from 0.110 to 0.220)
    {
        float2 n = float2(0.220, 0.145)
            + float2(sin(nt * 0.41 * speed + 1.10) * 0.032,
                     cos(nt * 0.37 * speed + 2.30) * 0.028);
        d = smin(d, length(p - n) - 0.078 * scale, 0.045);
    }
    // Node 2: lower inner wing
    {
        float2 n = float2(0.225, -0.150)
            + float2(sin(nt * 0.29 * speed + 3.70) * 0.030,
                     cos(nt * 0.43 * speed + 0.90) * 0.028);
        d = smin(d, length(p - n) - 0.076 * scale, 0.045);
    }
    // Node 3: outer upper tip (0.175 to 0.330)
    {
        float2 n = float2(0.330, 0.075)
            + float2(sin(nt * 0.53 * speed + 2.10) * 0.038,
                     cos(nt * 0.23 * speed + 4.10) * 0.032);
        d = smin(d, length(p - n) - 0.062 * scale, 0.040);
    }
    // Node 4: outer lower tip
    {
        float2 n = float2(0.315, -0.088)
            + float2(sin(nt * 0.47 * speed + 5.10) * 0.036,
                     cos(nt * 0.61 * speed + 1.70) * 0.032);
        d = smin(d, length(p - n) - 0.060 * scale, 0.040);
    }
    // Node 5: upper head
    {
        float2 n = float2(0.075, 0.365)
            + float2(sin(nt * 0.36 * speed + 0.50) * 0.025,
                     cos(nt * 0.51 * speed + 3.30) * 0.032);
        d = smin(d, length(p - n) - 0.072 * scale, 0.040);
    }
    // Node 6: lower tail
    {
        float2 n = float2(0.068, -0.355)
            + float2(sin(nt * 0.33 * speed + 4.20) * 0.022,
                     cos(nt * 0.44 * speed + 1.20) * 0.028);
        d = smin(d, length(p - n) - 0.066 * scale, 0.038);
    }

    // Beat-driven pulse on outlier nodes — near-invisible at rest (0.35×
    // radius), big-drop at beat peak (~2.0×). Gives the ink-drops-on-the-
    // beat feel without affecting the core shape.
    float beatPulseR = 0.35 + beat * 1.65;

    // Node 7: outlier splatter upper-far
    {
        float2 n = float2(0.410, 0.240)
            + float2(sin(nt * 0.57 * speed + 1.80) * 0.050,
                     cos(nt * 0.39 * speed + 3.10) * 0.050);
        d = smin(d, length(p - n) - 0.036 * scale * beatPulseR, 0.028);
    }
    // Node 8: outlier splatter lower-far
    {
        float2 n = float2(0.395, -0.235)
            + float2(sin(nt * 0.49 * speed + 4.60) * 0.045,
                     cos(nt * 0.33 * speed + 0.70) * 0.050);
        d = smin(d, length(p - n) - 0.034 * scale * beatPulseR, 0.028);
    }

    // Tertiary droplets — only visible on strong beats, giving the "splash
    // of far-flung drops" look that real Rorschach images often have.
    if (beat > 0.25) {
        float2 n9 = float2(0.490, 0.180)
            + float2(sin(nt * 0.71 + 2.40) * 0.030,
                     cos(nt * 0.43 + 0.90) * 0.030);
        d = smin(d, length(p - n9) - 0.020 * scale * beat, 0.020);
        float2 n10 = float2(0.480, -0.175)
            + float2(sin(nt * 0.63 + 5.10) * 0.030,
                     cos(nt * 0.37 + 3.70) * 0.030);
        d = smin(d, length(p - n10) - 0.018 * scale * beat, 0.020);
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

    float t  = u.time;    // monotonic — drives edge noise
    float nt = u.nodeT;   // oscillating — drives node drift + breath

    // Slow organic breathing — uses nodeT so breath inhales/exhales with the
    // same bidirectional drift as the blob positions.
    float breath = 1.0 + sin(nt * 0.19) * 0.035 + cos(nt * 0.13) * 0.020;

    // u.bass / u.mid / u.treble / u.beatPulse arrive heavily EMA-smoothed on
    // the CPU side (see RorschachState time constants).
    float scale = breath * (1.0 + u.bass * 0.55 + u.beatPulse * 0.20);

    // Mid + danceability govern how chaotically the nodes drift.
    float speed = 0.55 + u.mid * 1.30 + (u.danceability - 0.5) * 0.30;

    // Raw metaball SDF — beat param uses RAW beatPulse (not EMA'd) so drops
    // pop sharply and decay via OnsetBPMDetector's exp(-8*dt) envelope.
    float d = inkSDF(p, nt, scale, speed, u.beatPulse);

    // Two-layer edge displacement — coarse drift + fine splatter — so the
    // boundary reads as jagged/torn ink rather than soft curves. Both layers
    // kick out further on beats for a per-beat "splash" feel. Uses monotonic
    // t so the splatter never reverses.
    float splashKick = 1.0 + u.beatPulse * 0.6;
    float2 nCoord1 = p * 8.0  + float2(t * 0.20, t * 0.15);
    float2 nCoord2 = p * 28.0 + float2(t * 0.13, -t * 0.09);
    float coarse = fbm3(nCoord1) * (0.050 + u.treble * 0.035) * splashKick;
    float fine   = fbm3(nCoord2) * (0.018 + u.treble * 0.018) * splashKick;
    d += coarse + fine;

    // Tight edge threshold — lets the noise displacement read as crisp
    // jagged ink instead of a feathered halo.
    float edgeW = 0.006;
    float inkMask = 1.0 - smoothstep(-edgeW, edgeW, d);

    // Interior is mostly flat black (matches real Rorschach cards); subtle
    // navy only shows up far inside dense nodes, valence-modulated.
    float depth    = clamp(-d / 0.22, 0.0, 1.0);
    float navyAmt  = depth * depth * clamp(0.9 - u.valence * 1.1, 0.0, 0.4);
    float3 inkColor = mix(float3(0.0), float3(0.04, 0.05, 0.20), navyAmt);

    // Warm parchment background — classic Rorschach card
    float3 bgColor = float3(0.962, 0.952, 0.938);

    float3 col = mix(bgColor, inkColor, inkMask);
    return float4(col, 1.0);
}
