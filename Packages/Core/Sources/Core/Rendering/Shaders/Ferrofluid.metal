#include <metal_stdlib>
using namespace metal;

struct FerroUniforms {
    float time;
    float bass;
    float treble;
    int spikeCount;
    float2 resolution;
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

// Polynomial tent falloff. Peaks at 1 when |x|<=0 and falls to 0 at |x|=1.
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

    // Spike index space at this x column.
    float spikeX = uv.x * (Nf - 1.0);
    int iCenter = clamp(int(spikeX), 0, N - 1);

    // Compute the fluid surface height by taking the MAX influence from a window of
    // neighbor spikes (tent falloff), then floor it with a "connected body" raised
    // valley so the fluid stays a single mass. Matches web's cubic-bezier surface.
    float surface = 0.0;
    for (int dx = -2; dx <= 2; dx++) {
        int idx = clamp(iCenter + dx, 0, N - 1);
        float offset = (float(idx) - spikeX) / 1.25;
        surface = max(surface, heights[idx] * tent(offset));
    }
    int iL = clamp(iCenter, 0, N - 1);
    int iR = clamp(iCenter + 1, 0, N - 1);
    float valley = (heights[iL] + heights[iR]) * 0.30;   // web spec: 30% raise
    surface = max(surface, valley);

    // Map logical surface height (0..~1) to screen uv.y.
    float poolY = 0.04;
    float maxH = 0.55;
    float surfaceY = poolY + surface * maxH;

    float pixelY = uv.y;

    // Hue drifts slowly, snaps up on bass kicks. Matches web's fluidHue += 0.06 + bass*1.8.
    float hue = u.time * 0.03 + u.bass * 0.30;
    float3 baseHue = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
    float lum = dot(baseHue, float3(0.299, 0.587, 0.114));
    float3 desat = float3(lum);

    float4 outCol = float4(0.0);

    if (pixelY < poolY) {
        // Pool: dark base with colored bass glow.
        float t = pixelY / poolY;                         // 0 bottom, 1 top of pool
        float3 poolDark = float3(0.015, 0.018, 0.025);
        float3 poolGlow = mix(desat, baseHue, 0.6) * (0.10 + u.bass * 0.35);
        float3 pool = poolDark + poolGlow * (0.4 + t * 0.6);
        outCol = float4(pool, 1.0);
    } else if (pixelY < surfaceY) {
        // Fluid body — dark metallic gradient, vertical lightening toward the tip.
        float tNorm = (pixelY - poolY) / max(surfaceY - poolY, 0.001);   // 0 pool, 1 tip
        float3 bodyLow  = float3(0.025, 0.028, 0.036);
        float3 bodyMid  = mix(desat * 0.22, baseHue * 0.18, 0.6);
        float3 bodyHigh = mix(desat * 0.58, baseHue * 0.50, 0.45);
        float3 body = mix(bodyLow, bodyMid, smoothstep(0.0, 0.55, tNorm));
        body = mix(body, bodyHigh, smoothstep(0.55, 1.0, tNorm));

        // Specular streak on the "left face" of the nearest spike. Strongest on
        // the upper half of each spike, drops off rapidly as spikeX passes spike center.
        float phase = spikeX - floor(spikeX);        // 0..1 within column
        float leftFace = smoothstep(0.45, 0.05, phase);
        float upperHalf = smoothstep(0.40, 0.92, tNorm);
        float specAmount = leftFace * upperHalf * (0.55 + u.bass * 0.35);
        float3 specColor = mix(desat, baseHue, 0.45) * 0.90;
        body = mix(body, specColor, specAmount);

        // Pool shimmer line at the surface exactly at poolY — matches web's shimmer.
        float shimmer = smoothstep(0.02, 0.0, abs(pixelY - poolY));
        body += baseHue * shimmer * (0.18 + u.bass * 0.30);

        outCol = float4(body, 1.0);
    } else {
        // Above the fluid — transparent so the background shows through.
        outCol = float4(0.0);
    }

    return outCol;
}
