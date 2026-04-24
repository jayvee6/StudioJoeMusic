#include <metal_stdlib>
using namespace metal;

struct KaleidoUniforms {
    float  camZ;        // CPU-accumulated camera depth (tunnel progress)
    float  hue;         // 0..1, CPU-accumulated color rotation
    float  bass;
    float  mid;
    float  treble;
    float  twist;       // CPU-accumulated twist (mid-freq driven)
    float2 resolution;
    float  valence;
    float  energy;
    float  danceability;
    float  tempoBPM;
};

struct KVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex KVSOut kaleido_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    KVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// HSL → RGB (same formula used across all visualizers)
static float3 khsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
                       0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

fragment float4 kaleido_fs(KVSOut in [[stage_in]],
                            constant KaleidoUniforms& u [[buffer(0)]]) {
    float asp = u.resolution.x / u.resolution.y;
    float2 p  = (in.uv - 0.5) * float2(asp, 1.0);

    float r = length(p);
    // Guard against the singularity at the exact screen centre
    if (r < 0.002) { return float4(0.0, 0.0, 0.0, 1.0); }

    float a = atan2(p.y, p.x);

    // ── Tunnel coordinate ────────────────────────────────────────────────────
    // 1/r maps screen-centre to infinite depth; camZ advances the viewer forward.
    float depth   = 1.0 / r;
    float tunnelV = depth + u.camZ;

    // ── 6-fold kaleidoscope fold ─────────────────────────────────────────────
    const float K      = 6.0;
    const float sector = (2.0 * M_PI_F) / K;          // 60°

    // Mid-frequency twist: rotates the fold with accumulated depth
    float twisted_a = a + u.twist * (depth * 0.04);

    // Fold into one sector, then mirror for left-right symmetry within sector
    float fa = fmod(twisted_a + 2.0 * M_PI_F * 4.0, sector); // fmod needs positive arg
    float mirrored_a = (fa > sector * 0.5) ? (sector - fa) : fa;
    float tunnelU = mirrored_a / (sector * 0.5);             // 0 = mirror plane, 1 = middle

    // ── Structural patterns ───────────────────────────────────────────────────
    // Rings: bright bands at regular depth intervals (feel like flying through arches)
    float ringPhase    = fract(tunnelV * 0.5) * 2.0 * M_PI_F;
    float ringBright   = 0.5 + 0.5 * cos(ringPhase);
    ringBright         = ringBright * ringBright * ringBright;   // sharpen

    // Secondary ring harmonic adds visual complexity
    float ring2Phase   = fract(tunnelV * 1.5 + 0.25) * 2.0 * M_PI_F;
    float ring2Bright  = max(0.0, 0.5 + 0.5 * cos(ring2Phase));
    ring2Bright       *= ring2Bright;

    // Spokes: bright along mirror planes (tunnelU ≈ 0) and sector mid-lines (tunnelU ≈ 1)
    float spokeMirror  = exp(-tunnelU * tunnelU * 14.0);
    float spokeMiddle  = exp(-(1.0 - tunnelU) * (1.0 - tunnelU) * 14.0) * 0.55;
    float spokeBright  = spokeMirror + spokeMiddle;

    // Bright nodes where spokes cross rings — the classic kaleidoscope "gem" look
    float gemBright    = spokeBright * ringBright;

    // ── Color ─────────────────────────────────────────────────────────────────
    // Hue: cycles with time (via hue accumulator), depth (far end is different hue),
    //      and angle position within sector.
    float hue = u.hue + tunnelV * 0.10 + tunnelU * 0.55 + u.bass * 0.12;
    // Valence nudges the palette warm (happy) or cool (sad)
    hue += (u.valence - 0.5) * 0.20;

    float sat = 0.88 + u.bass * 0.12;
    float lum = 0.12 + ringBright * 0.22 + ring2Bright * 0.08 + spokeBright * 0.18;
    lum *= (0.70 + u.mid * 0.60);
    lum  = min(lum, 0.85);

    float3 col = khsl2rgb(fract(hue), sat, lum);

    // Hot-white gem flare at spoke/ring intersections
    col += gemBright * float3(0.90, 0.95, 1.00) * 0.75 * (0.6 + u.treble * 0.6);

    // ── Depth fog ────────────────────────────────────────────────────────────
    // Screen centre (r→0, depth→∞) fades to black — gives the tunnel its depth.
    float centerFade = smoothstep(0.0, 0.06, r);
    col *= centerFade;

    // Slight vignette at the screen edges
    float vignette = 1.0 - smoothstep(0.42, 0.52, r / max(asp, 1.0 / asp));
    col *= vignette;

    return float4(saturate(col), 1.0);
}
