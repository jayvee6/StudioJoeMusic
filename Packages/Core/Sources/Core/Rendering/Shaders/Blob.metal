#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    float audio;
    float2 resolution;
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

static float sceneFn(float3 p, float t, float a) {
    float wobble = sin(p.x * 4.0 + t * 1.1) *
                   sin(p.y * 3.5 + t * 0.75) *
                   sin(p.z * 4.5 + t * 0.9) *
                   (0.07 + a * 0.38);
    return sdSphere(p, 0.65 + a * 0.28) + wobble;
}

static float3 getNormal(float3 p, float t, float a) {
    const float2 e = float2(0.001, 0.0);
    return normalize(float3(
        sceneFn(p + e.xyy, t, a) - sceneFn(p - e.xyy, t, a),
        sceneFn(p + e.yxy, t, a) - sceneFn(p - e.yxy, t, a),
        sceneFn(p + e.yyx, t, a) - sceneFn(p - e.yyx, t, a)));
}

fragment float4 blob_fs(VSOut in [[stage_in]],
                        constant Uniforms& u [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * float2(u.resolution.x / u.resolution.y, 1.0);
    float3 ro = float3(0.0, 0.0, 2.2);
    float3 rd = normalize(float3(uv, -1.3));
    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 96; ++i) {
        float d = sceneFn(ro + rd * t, u.time, u.audio);
        if (d < 0.0008) { hit = true; break; }
        if (t > 8.0) break;
        t += d * 0.92;
    }
    float3 col = float3(0.0);
    if (hit) {
        float3 p = ro + rd * t;
        float3 n = getNormal(p, u.time, u.audio);
        float3 l1 = normalize(float3( 1.0, 1.2, 2.0));
        float3 l2 = normalize(float3(-1.0, 0.3, 1.0));
        float d1 = max(dot(n, l1), 0.0);
        float d2 = max(dot(n, l2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-l1, n), -rd), 0.0), 40.0);
        float hue = u.time * 0.08 + u.audio * 0.6 + n.y * 0.4 + n.x * 0.3;
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
