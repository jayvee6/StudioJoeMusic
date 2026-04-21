#include <metal_stdlib>
using namespace metal;

struct FerroUniforms {
    float time;
    float hue;            // 0..1, CPU-accumulated fluidHue
    float bass;
    float treble;
    int spikeCount;
    uint _pad0;           // match Swift's explicit pad — documents the 8-byte float2 alignment
    float2 resolution;
    // Track-mood tail — matches Swift FerroUniforms field order. Four plain floats
    // after the float2 pack without further padding.
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
};

struct FerroVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FerroVSOut ferrofluid_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FerroVSOut o;
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

static float tent(float x) {
    float a = max(0.0, 1.0 - abs(x));
    return a * a * a;
}

fragment float4 ferrofluid_fs(FerroVSOut in [[stage_in]],
                              constant FerroUniforms& u [[buffer(0)]],
                              constant float* heights [[buffer(1)]]) {
    float2 uv = in.uv;
    int N = u.spikeCount;
    float Nf = float(N);

    float spikeX = uv.x * (Nf - 1.0);
    int iCenter = clamp(int(spikeX), 0, N - 1);

    // Fluid surface — max-of-tent influence window + raised valley.
    float surface = 0.0;
    for (int dx = -2; dx <= 2; dx++) {
        int idx = clamp(iCenter + dx, 0, N - 1);
        float offset = (float(idx) - spikeX) / 1.25;
        surface = max(surface, heights[idx] * tent(offset));
    }
    int iL = clamp(iCenter, 0, N - 1);
    int iR = clamp(iCenter + 1, 0, N - 1);
    float valley = (heights[iL] + heights[iR]) * 0.30;
    surface = max(surface, valley);

    float poolY = 0.04;
    // Energy scales the maximum spike height — amp of displacement. Neutral 0.5 → 1.0.
    float energyMul = 0.6 + u.energy * 0.8;
    float maxH = 0.55 * energyMul;
    float surfaceY = poolY + surface * maxH;
    float pixelY = uv.y;

    float4 outCol = float4(0.0);

    if (pixelY < poolY) {
        // Pool: HSL(hue, 100%, 22-36%) blended with very dark.
        float t = pixelY / poolY;
        float3 poolDark = float3(0.015, 0.018, 0.025);
        float3 poolGlow = hsl2rgb(u.hue, 1.0, 0.22 + u.bass * 0.14);
        float3 pool = poolDark + poolGlow * (0.40 + u.bass * 0.55) * (0.4 + t * 0.6);
        outCol = float4(pool, 1.0);
    } else if (pixelY < surfaceY) {
        // Body: HSL(hue, 20-25%, 3-10%) vertical gradient — dark metallic with
        // barely-there colored tint.
        float tNorm = (pixelY - poolY) / max(surfaceY - poolY, 0.001);
        float3 bodyLow  = hsl2rgb(u.hue, 0.20, 0.03);
        float3 bodyMid  = hsl2rgb(u.hue, 0.22, 0.07);
        float3 bodyHigh = hsl2rgb(u.hue, 0.25, 0.10);
        float3 body = mix(bodyLow, bodyMid, smoothstep(0.0, 0.55, tNorm));
        body = mix(body, bodyHigh, smoothstep(0.55, 1.0, tNorm));

        // Specular streak on left face, colored per web: HSL(hue, 60-80%, 42-88%).
        // Valence brightens gloss on happy tracks, mutes it on sad ones. Neutral 0.5 → 1.0.
        float valenceMul = 0.8 + u.valence * 0.4;
        float phase = spikeX - floor(spikeX);
        float leftFace = smoothstep(0.45, 0.05, phase);
        float upperHalf = smoothstep(0.40, 0.92, tNorm);
        float specAmount = leftFace * upperHalf * (0.55 + u.bass * 0.35) * valenceMul;
        float specL = 0.50 + u.bass * 0.30;
        float3 specColor = hsl2rgb(u.hue, 0.65, specL);
        body = mix(body, specColor, specAmount);

        // Pool shimmer line at y=poolY.
        float shimmer = smoothstep(0.02, 0.0, abs(pixelY - poolY));
        body += hsl2rgb(u.hue, 1.0, 0.30 + u.bass * 0.38) * shimmer;

        outCol = float4(body, 1.0);
    } else {
        outCol = float4(0.0);
    }

    return outCol;
}
