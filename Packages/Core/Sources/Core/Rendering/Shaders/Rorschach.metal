#include <metal_stdlib>
using namespace metal;

// Fluid-ink Rorschach — port of the fluid-ink showcase (see
// .claude/skills/studiojoe-viz/showcase/fluid-ink.html) and the web driver at
// musicplayer-viz/viz/rorschach.js. Replaces the earlier "parchment + black
// inkblot" look; the new interior is a cyan→magenta gradient over a near-
// black background with a cool-blue edge glow that pulses per beat.
//
// Uniform layout (must match Swift RorschachUniforms exactly — 52 bytes):
//   offset  0: time         (float)   — monotonic; drives FBM edge displacement
//   offset  4: bass         (float)   — EMA-smoothed CPU-side
//   offset  8: mid          (float)   — EMA-smoothed (unused by shader, kept
//                                       for struct stability / future hooks)
//   offset 12: treble       (float)   — EMA-smoothed
//   offset 16: resolution   (float2)  — 8-byte aligned ✓
//   offset 24: beatPulse    (float)   — RAW per-frame beat (not smoothed) so
//                                       splatter + glow punch sharply
//   offset 28: valence      (float)   — unused by shader (kept for layout)
//   offset 32: energy       (float)   — unused by shader (kept for layout)
//   offset 36: danceability (float)   — unused by shader (kept for layout)
//   offset 40: tempoBPM     (float)   — unused by shader (kept for layout)
//   offset 44: nodeT        (float)   — oscillating drift time; drives ink
//                                       node positions + breath, sweeps fwd/back
//   offset 48: sizeMul      (float)   — CPU-side size multiplier; default 1.0
//                                       (mirrors the web `size` slider slot)
// Total: 52 bytes.
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
    float nodeT;
    float sizeMul;       // appended after prior float fields — 52 bytes total
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
    return v;
}

// 7 metaball nodes on the right half-plane. Bilateral fold (`abs(uv.x)`) in
// the fragment mirrors them across the y-axis for symmetric ink. Node budget
// + radii are lifted line-for-line from the fluid-ink showcase (see the web
// driver for the numbered breakdown: spine, inner wings, outer tips, two
// beat-punched splatter droplets).
//
// `nt`    = oscillating node-drift time (see CPU dual-time driver).
// `scale` = breath × bass-driven radius multiplier × CPU sizeMul.
// `speed` = bass-driven node drift speed.
// `beat`  = raw beatPulse — punches the two splatter droplets per onset.
static float inkSDF(float2 p, float nt, float scale, float speed, float beat) {
    float d = 1e6;

    // Central spine — anchors the seam without dominating.
    {
        float2 n = float2(0.030, 0.000)
            + float2(sin(nt * 0.31 * speed)        * 0.018,
                     cos(nt * 0.27 * speed)        * 0.025);
        d = smin(d, length(p - n) - 0.090 * scale, 0.045);
    }
    // Inner upper wing.
    {
        float2 n = float2(0.220, 0.145)
            + float2(sin(nt * 0.41 * speed + 1.10) * 0.032,
                     cos(nt * 0.37 * speed + 2.30) * 0.028);
        d = smin(d, length(p - n) - 0.078 * scale, 0.045);
    }
    // Inner lower wing.
    {
        float2 n = float2(0.225, -0.150)
            + float2(sin(nt * 0.29 * speed + 3.70) * 0.030,
                     cos(nt * 0.43 * speed + 0.90) * 0.028);
        d = smin(d, length(p - n) - 0.076 * scale, 0.045);
    }
    // Outer upper tip.
    {
        float2 n = float2(0.330, 0.075)
            + float2(sin(nt * 0.53 * speed + 2.10) * 0.038,
                     cos(nt * 0.23 * speed + 4.10) * 0.032);
        d = smin(d, length(p - n) - 0.062 * scale, 0.040);
    }
    // Outer lower tip.
    {
        float2 n = float2(0.315, -0.088)
            + float2(sin(nt * 0.47 * speed + 5.10) * 0.036,
                     cos(nt * 0.61 * speed + 1.70) * 0.032);
        d = smin(d, length(p - n) - 0.060 * scale, 0.040);
    }

    // Outlier splatter droplets — punched by raw beat so each detected onset
    // momentarily bulges these two far nodes beyond the main shape.
    float beatPulseR = 0.35 + beat * 1.65;
    {
        float2 n = float2(0.410, 0.240)
            + float2(sin(nt * 0.57 * speed + 1.80) * 0.050,
                     cos(nt * 0.39 * speed + 3.10) * 0.050);
        d = smin(d, length(p - n) - 0.036 * scale * beatPulseR, 0.028);
    }
    {
        float2 n = float2(0.395, -0.235)
            + float2(sin(nt * 0.49 * speed + 4.60) * 0.045,
                     cos(nt * 0.33 * speed + 0.70) * 0.050);
        d = smin(d, length(p - n) - 0.034 * scale * beatPulseR, 0.028);
    }

    return d;
}

fragment float4 rorschach_fs(VSOut in [[stage_in]],
                              constant Uniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    // Coordinate space: y ∈ [-0.5, 0.5], x ∈ [-aspect/2, +aspect/2].
    float2 uv = (in.uv - 0.5) * float2(aspect, 1.0);

    // Bilateral symmetry: fold to the right half-plane.
    float2 p = float2(abs(uv.x), uv.y);

    float t  = u.time;    // monotonic — drives edge noise
    float nt = u.nodeT;   // oscillating — drives node drift + breath

    // Slow organic breath — nodeT so it inhales/exhales bidirectionally.
    float breath = 1.0 + sin(nt * 0.19) * 0.035 + cos(nt * 0.13) * 0.020;
    float scale  = breath * (1.0 + u.bass * 0.55 + u.beatPulse * 0.20) * u.sizeMul;
    float speed  = 0.65 + u.bass * 0.80;

    float d = inkSDF(p, nt, scale, speed, u.beatPulse);

    // Two-layer FBM edge displacement — coarse wobble + fine grain. Both
    // kicked by beat so splatter explodes outward on drops. Uses monotonic
    // `t` so the splatter never reverses.
    float splashKick = 1.0 + u.beatPulse * 0.6;
    float2 nCoord1 = p * 8.0  + float2(t * 0.20, t *  0.15);
    float2 nCoord2 = p * 28.0 + float2(t * 0.13, t * -0.09);
    float coarse = fbm3(nCoord1) * (0.050 + u.treble * 0.035) * splashKick;
    float fine   = fbm3(nCoord2) * (0.018 + u.treble * 0.018) * splashKick;
    d += coarse + fine;

    float edgeW   = 0.006;
    float inkMask = 1.0 - smoothstep(-edgeW, edgeW, d);

    // Cyan → magenta depth gradient. `depth` grows as we move deeper inside
    // the shape; outer edge reads cool (cyan/blue) and interior core reads
    // warm (magenta). Squared for a softer rolloff near the edge.
    float depth    = clamp(-d / 0.25, 0.0, 1.0);
    float3 inkInner = mix(float3(0.05, 0.90, 0.98), float3(0.95, 0.35, 0.90), depth);
    float3 inkEdge  = float3(0.06, 0.50, 0.85);
    float3 inkCol   = mix(inkEdge, inkInner, depth * depth);

    float3 bgCol = float3(0.02, 0.03, 0.06);
    float3 col   = mix(bgCol, inkCol, inkMask);

    // Edge glow — exp-decay from the zero-crossing. Beat kicks the glow
    // intensity so each onset briefly flares around the ink.
    float glow = exp(-abs(d) * 30.0) * 0.6;
    col += float3(0.3, 0.6, 0.9) * glow * (0.5 + u.beatPulse * 1.2);

    return float4(col, 1.0);
}
