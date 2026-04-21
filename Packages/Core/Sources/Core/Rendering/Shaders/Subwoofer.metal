#include <metal_stdlib>
using namespace metal;

struct SubwooferUniforms {
    float time;
    float bass;
    float beatPulse;
    float2 resolution;
    // Track-mood tail — matches Swift SubwooferUniforms field order.
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
};

struct SubVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex SubVSOut subwoofer_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    SubVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

static float3 hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(
        abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
        0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

fragment float4 subwoofer_fs(SubVSOut in [[stage_in]],
                             constant SubwooferUniforms& u [[buffer(0)]],
                             constant float* bassHistory [[buffer(1)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;
    float r = length(uv);

    // Fill factor so the speaker cone grows into the long dimension.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    // Web ring radii on shortSide: frame 0.46, surround 0.43, cone 0.30, cap 0.09.
    // All scaled by fillFactor so the speaker fills more of the tall/wide screen.
    // Energy scales the cone's reactive displacement — the bass-driven cap expansion
    // is the most visible "mesh displacement" on this visualizer. Neutral 0.5 → 1.0.
    float energyMul = 0.6 + u.energy * 0.8;
    float capR      = 0.085 * fillFactor * (1.0 + u.bass * 0.28 * energyMul);
    float coneR     = 0.30 * fillFactor;
    float surFlex   = bassHistory[8] * 0.014 * fillFactor;
    float surroundR = 0.38 * fillFactor + surFlex;
    float basketR   = 0.43 * fillFactor;
    float cabinetR  = 0.46 * fillFactor;

    // HSL hues for the web's low-saturation steel / amber palette.
    const float hueSteel  = 210.0 / 360.0;
    const float hueAmber  = 30.0  / 360.0;

    float3 color = float3(0.005);

    if (r < capR) {
        // Dust cap — HSL(210°, 7%, 40%) with an off-center specular highlight.
        float t = 1.0 - r / capR;
        float2 hlCenter = float2(-0.022, 0.032);
        float hlDist = length(uv - hlCenter);
        // Valence brightens the specular — happy tracks pop the gloss, sad tracks mute it.
        float valenceMul = 0.8 + u.valence * 0.4;
        float highlight = exp(-hlDist * 34.0) * (0.55 + u.bass * 0.35) * valenceMul;
        float3 capBase = hsl2rgb(hueSteel, 0.07, 0.30 + t * 0.12);
        color = capBase + float3(1.0, 0.98, 0.96) * highlight;
    }
    else if (r < coneR) {
        // Cone — HSL(210°, 5-7%, 7-22%) radial, plus 3 history-driven depth ripples.
        float t = (r - capR) / max(coneR - capR, 0.001);
        float coneL = mix(0.22, 0.07, t);
        float3 coneBase = hsl2rgb(hueSteel, 0.06, coneL);

        // Depth ripples — 3 concentric faint strokes at progressively older history indices.
        for (int i = 0; i < 3; i++) {
            int hi = clamp((i + 1) * 3, 0, 15);
            float hist = bassHistory[hi];
            float rippleR = capR + (coneR - capR) * (0.30 + float(i) * 0.22 + hist * 0.12);
            float rippleDist = abs(r - rippleR);
            float rippleGlow = exp(-rippleDist * 220.0) * hist * 0.30;
            coneBase += hsl2rgb(hueSteel, 0.45, 0.55) * rippleGlow;
        }

        // Inner highlight ring just outside the cap so the cone reads as recessed.
        coneBase += hsl2rgb(hueSteel, 0.15, 0.30) * smoothstep(0.30, 0.0, t);
        color = coneBase;
    }
    else if (r < surroundR) {
        // Rubber surround — HSL(30°, 5-6%, 10-34%), sin(t*π) bulge curve, delayed-bass flex.
        float t = (r - coneR) / max(surroundR - coneR, 0.001);
        float curve = sin(t * M_PI_F);
        float surL = mix(0.10, 0.34, curve);
        float3 rubber = hsl2rgb(hueAmber, 0.055, surL);
        float flexGlow = bassHistory[8] * 0.09 * curve;
        color = rubber + hsl2rgb(hueAmber, 0.3, 0.4) * flexGlow;
    }
    else if (r < basketR) {
        // Basket — warm near-black (#18160f): HSL(42°, 14%, 7%) gradient.
        float t = (r - surroundR) / max(basketR - surroundR, 0.001);
        color = mix(hsl2rgb(0.115, 0.14, 0.09),
                    hsl2rgb(0.115, 0.12, 0.06),
                    t);
    }
    else if (r < cabinetR) {
        // Cabinet — #060606, very dark with a subtle sheen.
        float t = (r - basketR) / max(cabinetR - basketR, 0.001);
        color = mix(float3(0.025), float3(0.012), t);
    }
    else {
        // Outside frame
        float vign = smoothstep(1.15, 0.50, r);
        color = float3(0.002) * vign;
    }

    // Whole-speaker bass breath.
    color *= (0.88 + u.bass * 0.14 + u.beatPulse * 0.08);

    return float4(max(color, float3(0.0)), 1.0);
}
