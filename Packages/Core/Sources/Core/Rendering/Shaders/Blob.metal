#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    float audio;
    float2 resolution;
    // Track-mood tail — matches Swift BlobUniforms field order.
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut blob_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

static float sdSphere(float3 p, float r) { return length(p) - r; }

// `dance` scales wobble frequency so danceable tracks ripple faster. At the
// neutral default (0.5), the multiplier is exactly 1.0 so output matches legacy.
static float sceneFn(float3 p, float t, float a, float dance) {
    float freqScale = 0.7 + dance * 0.6;   // 1.0 at dance=0.5, 0.7..1.3 range
    float wobble = sin(p.x * 4.0 * freqScale + t * 1.1) *
                   sin(p.y * 3.5 * freqScale + t * 0.75) *
                   sin(p.z * 4.5 * freqScale + t * 0.9) *
                   (0.07 + a * 0.38);
    return sdSphere(p, 0.65 + a * 0.28) + wobble;
}

static float3 getNormal(float3 p, float t, float a, float dance) {
    const float2 e = float2(0.001, 0.0);
    return normalize(float3(
        sceneFn(p + e.xyy, t, a, dance) - sceneFn(p - e.xyy, t, a, dance),
        sceneFn(p + e.yxy, t, a, dance) - sceneFn(p - e.yxy, t, a, dance),
        sceneFn(p + e.yyx, t, a, dance) - sceneFn(p - e.yyx, t, a, dance)));
}

fragment float4 blob_fs(VSOut in [[stage_in]],
                        constant Uniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    // Fill factor — shrinks the ray's xy footprint so the blob fills more of the
    // long dimension (equivalent to a wider FOV in portrait / narrower in landscape).
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));
    float2 uv = (in.uv - 0.5) * float2(aspect, 1.0) / fillFactor;
    float3 ro = float3(0.0, 0.0, 2.2);
    float3 rd = normalize(float3(uv, -1.3));
    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 96; ++i) {
        float d = sceneFn(ro + rd * t, u.time, u.audio, u.danceability);
        if (d < 0.0008) { hit = true; break; }
        if (t > 8.0) break;
        t += d * 0.92;
    }
    float3 col = float3(0.0);
    if (hit) {
        float3 p = ro + rd * t;
        float3 n = getNormal(p, u.time, u.audio, u.danceability);
        float3 l1 = normalize(float3( 1.0, 1.2, 2.0));
        float3 l2 = normalize(float3(-1.0, 0.3, 1.0));
        float d1 = max(dot(n, l1), 0.0);
        float d2 = max(dot(n, l2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-l1, n), -rd), 0.0), 40.0);
        // Valence shifts hue warmer (happy) or cooler (sad). Neutral 0.5 = zero offset.
        float hue = u.time * 0.08 + u.audio * 0.6 + n.y * 0.4 + n.x * 0.3
                    + (u.valence - 0.5) * 0.3;
        float3 base = 0.5 + 0.5 * cos(6.28318 * (hue + float3(0.0, 0.33, 0.67)));
        col = base * (d1 + d2 + 0.12) + float3(spec * 0.8) + base * u.audio * 0.45;
    } else {
        float fog = exp(-length(uv) * 1.8);
        float3 gCol = 0.5 + 0.5 * cos(6.28318 *
            (u.time * 0.04 + float3(0.0, 0.33, 0.67)));
        col = gCol * fog * 0.15 * (0.4 + u.audio);
    }
    return float4(max(col, float3(0.0)), 1.0);
}
