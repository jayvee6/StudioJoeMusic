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
                             constant SubwooferUniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float r = length(uv);

    float pump = 1.0 + u.bass * 0.10 + u.beatPulse * 0.08;
    float capR       = 0.07;
    float coneR      = 0.30 * pump;
    float surroundR  = 0.38 * pump;
    float basketR    = 0.46;
    float cabinetR   = 0.58;

    float3 color = float3(0.015);

    if (r < capR) {
        // Metallic dust cap with a soft off-center highlight
        float t = 1.0 - r / capR;
        float2 hl = uv - float2(-0.018, 0.022);
        float highlight = pow(max(0.0, 1.0 - length(hl) / 0.055), 3.0);
        color = float3(0.82, 0.82, 0.87) * (0.55 + t * 0.35)
              + float3(1.0) * highlight * 0.5;
    } else if (r < coneR) {
        // Cone — dark charcoal, radial shading, highlight near cap
        float t = (r - capR) / max(coneR - capR, 0.001);
        float3 coneBase = mix(float3(0.38), float3(0.08), t);
        coneBase += float3(0.14) * smoothstep(0.35, 0.0, t);
        color = coneBase;
    } else if (r < surroundR) {
        // Rubber surround — very dark with a curved highlight
        float t = (r - coneR) / max(surroundR - coneR, 0.001);
        float curve = sin(t * M_PI_F);
        color = float3(0.035) + float3(0.11) * curve;
    } else if (r < basketR) {
        // Basket — mid-gray metal
        color = float3(0.26);
    } else if (r < cabinetR) {
        // Cabinet — dark
        color = float3(0.06);
    } else {
        // Outside cabinet — subtle vignette
        float vign = smoothstep(1.1, 0.55, r);
        color = float3(0.015) * vign;
    }

    // Bass brightens everything slightly
    color *= (0.85 + u.bass * 0.40);

    color = pow(max(color, float3(0.0)), float3(0.4545));
    return float4(color, 1.0);
}
