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

fragment float4 ferrofluid_fs(FerroVSOut in [[stage_in]],
                              constant FerroUniforms& u [[buffer(0)]],
                              constant float* heights [[buffer(1)]]) {
    float2 uv = in.uv;            // 0..1 — origin bottom-left
    float pixelY = uv.y;          // 0 bottom, 1 top
    float N = float(u.spikeCount);
    float col = uv.x * N;
    int idx = int(col);
    idx = max(0, min(u.spikeCount - 1, idx));

    float colCenter = (float(idx) + 0.5) / N;
    float spikeHalfWidth = 0.38 / N;     // how wide each spike is

    // Smooth between adjacent spikes using horizontal distance
    float dx = uv.x - colCenter;
    float widthShape = smoothstep(spikeHalfWidth, 0.0, abs(dx));

    float h = heights[idx] * 0.55 + 0.02;

    // Vertical shape: spike rises from y=0 to y=h with a rounded tip
    float tipSoftness = 0.012;
    float bodyMask = smoothstep(h + tipSoftness, h - tipSoftness, pixelY);
    // Multiply by widthShape to get the actual alpha
    float alpha = bodyMask * widthShape;

    // Metallic gradient: bright near tip, dark near pool
    float tipT = saturate(pixelY / max(h, 0.001));
    float3 metalDark = float3(0.09, 0.10, 0.13);
    float3 metalMid  = float3(0.42, 0.44, 0.50);
    float3 metalLight = float3(0.92, 0.92, 0.96);
    float3 body = mix(metalDark, metalMid, tipT);
    body = mix(body, metalLight, smoothstep(0.8, 1.0, tipT));

    // Horizontal specular stripe at column center
    float specular = pow(widthShape, 6.0) * 0.35 * (0.5 + u.bass * 1.2);
    body += float3(1.0) * specular;

    // Subtle color tint from bass — warm shift
    float hue = u.time * 0.03 + u.bass * 0.25;
    float3 tint = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
    body = mix(body, body * (0.7 + tint * 0.5), 0.22);

    // Pool at the bottom — subtle reflective sheet
    float poolMask = smoothstep(0.03, 0.0, pixelY);
    float3 poolColor = float3(0.04, 0.05, 0.06) * (1.0 + u.bass * 0.4);

    float3 color = body * alpha + poolColor * poolMask * (1.0 - alpha);
    float finalAlpha = max(alpha, poolMask * 0.9);

    return float4(max(color, float3(0.0)) * finalAlpha, finalAlpha);
}
