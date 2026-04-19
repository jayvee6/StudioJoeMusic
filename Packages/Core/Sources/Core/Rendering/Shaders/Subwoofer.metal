#include <metal_stdlib>
using namespace metal;

struct SubwooferUniforms {
    float time;
    float bass;
    float beatPulse;
    float2 resolution;
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

fragment float4 subwoofer_fs(SubVSOut in [[stage_in]],
                             constant SubwooferUniforms& u [[buffer(0)]],
                             constant float* bassHistory [[buffer(1)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float r = length(uv);

    // Dynamic zone radii.
    //   Cap pumps with current bass (instantaneous piston motion).
    //   Surround flex lags on bassHistory[8] — the delayed-bass outer ripple.
    float capR      = 0.085 * (1.0 + u.bass * 0.22);
    float coneR     = 0.30;
    float surFlex   = bassHistory[8] * 0.018;
    float surroundR = 0.38 + surFlex;
    float basketR   = 0.45;
    float cabinetR  = 0.58;

    float3 color = float3(0.008);

    if (r < capR) {
        // Dust cap: metallic steel with off-center specular highlight.
        float t = 1.0 - r / capR;
        float2 hlCenter = float2(-0.022, 0.032);
        float hlDist = length(uv - hlCenter);
        float highlight = exp(-hlDist * 34.0) * (0.55 + u.bass * 0.35);
        float3 capBase = mix(float3(0.18, 0.20, 0.24),
                             float3(0.55, 0.58, 0.64),
                             t);
        color = capBase + float3(1.0, 0.98, 0.96) * highlight;
    }
    else if (r < coneR) {
        // Cone: dark blue-grey with radial depth, strong highlight ring near cap,
        // plus 3 faint concentric depth ripples driven by bassHistory at
        // progressively older indices — that's the web's traveling depth wave.
        float t = (r - capR) / max(coneR - capR, 0.001);
        float3 coneBase = mix(float3(0.22, 0.23, 0.27),
                              float3(0.035, 0.038, 0.048),
                              t);

        for (int i = 0; i < 3; i++) {
            int hi = clamp((i + 1) * 3, 0, 15);
            float histBass = bassHistory[hi];
            float rippleR = capR + (coneR - capR) * (0.30 + float(i) * 0.22 + histBass * 0.12);
            float rippleDist = abs(r - rippleR);
            float rippleGlow = exp(-rippleDist * 220.0) * histBass * 0.28;
            coneBase += float3(0.55, 0.62, 0.72) * rippleGlow;
        }

        // Highlight ring just outside the cap so the cone looks recessed.
        coneBase += float3(0.14, 0.14, 0.16) * smoothstep(0.30, 0.0, t);
        color = coneBase;
    }
    else if (r < surroundR) {
        // Rubber surround: near-black base with a sin() bulge giving rounded
        // 3D shape; delayed bass brightens the bulge along with the flex.
        float t = (r - coneR) / max(surroundR - coneR, 0.001);
        float curve = sin(t * M_PI_F);
        float3 rubber = float3(0.028, 0.024, 0.022)
                      + float3(0.095, 0.085, 0.078) * curve;
        float flexGlow = bassHistory[8] * 0.10 * curve;
        color = rubber + float3(flexGlow, flexGlow * 0.92, flexGlow * 0.82);
    }
    else if (r < basketR) {
        // Basket: dark metallic with subtle gradient toward the cabinet edge.
        float t = (r - surroundR) / max(basketR - surroundR, 0.001);
        color = mix(float3(0.24, 0.22, 0.18),
                    float3(0.13, 0.12, 0.10),
                    t);
    }
    else if (r < cabinetR) {
        // Cabinet: very dark, subtle radial shading so it doesn't look flat.
        float t = (r - basketR) / max(cabinetR - basketR, 0.001);
        color = mix(float3(0.055, 0.05, 0.045),
                    float3(0.025, 0.022, 0.02),
                    t);
    }
    else {
        // Outside cabinet: near-black vignette edge.
        float vign = smoothstep(1.15, 0.55, r);
        color = float3(0.003) * vign;
    }

    // Bass breathes the whole speaker slightly (exposure simulation).
    color *= (0.88 + u.bass * 0.14 + u.beatPulse * 0.08);

    return float4(max(color, float3(0.0)), 1.0);
}
