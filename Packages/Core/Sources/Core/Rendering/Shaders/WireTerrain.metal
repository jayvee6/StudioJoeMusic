#include <metal_stdlib>
using namespace metal;

// Wire Terrain — iOS port of viz/wire-terrain.js (musicplayer-viz).
//
// Vertex shader runs a 4-octave value-noise FBM on a dense plane subdivision
// and displaces Y by the height. Orbits scroll the noise on its Y-of-XZ axis
// so the scene feels like "flying over terrain" without moving the camera
// along the terrain's own axis (parity with the web viz).
//
// Fragment shader maps height → violet→blue→cyan palette, adds a subtle
// grid-cell tint so wireframe reads structured, then multiplies brightness by
// bass + beatPulse. FogExp2(0x000008, 0.035) matches the web viz exactly
// (density and color both squared into the exp term). ViewZ varies from the
// vertex stage so the fragment can compute fog depth without extra inputs.
//
// Swift-side `WireTerrainUniforms` must mirror this layout exactly (see
// VisualizerFactory.swift). Binding contract (MeshRenderer.swift):
//   vertex buffer 0 = positions (float3, 16B-strided is fine)
//   vertex buffer 1 = uniforms  (projection | view | audio | res | fog)
//   fragment buffer 0 = same uniforms (cross-stage duplication is cheap)

struct WireTerrainUniforms {
    float4x4 projectionMatrix;   // 64 B, offset   0 — 16B aligned
    float4x4 viewMatrix;         // 64 B, offset  64 — 16B aligned
    float    time;               //  4 B, offset 128
    float    bass;               //  4 B, offset 132
    float    treble;             //  4 B, offset 136
    float    beatPulse;          //  4 B, offset 140
    float2   resolution;         //  8 B, offset 144 — 8B aligned ✓
    float    fogDensity;         //  4 B, offset 152 — web FogExp2 density (0.035)
    float    _pad0;              //  4 B, offset 156 — round total to 16B multiple
    // Total: 160 B.
};

struct WireTerrainVSOut {
    float4 position [[position]];
    float  vHeight;
    float2 vXZ;
    float  viewZ;   // view-space Z (negative forward). Fragment uses |viewZ| as fog depth.
};

// Mirror of the web GLSL helpers. Constants (127.1, 311.7, 19.19, 3.14, 1.59,
// 2.7, 7.1, 3.3) are copied verbatim — tuning these would drift parity.

static float wt_hash2(float2 p) {
    p = fract(p * float2(127.1, 311.7));
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float wt_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(wt_hash2(i),                   wt_hash2(i + float2(1.0, 0.0)), u.x),
               mix(wt_hash2(i + float2(0.0, 1.0)), wt_hash2(i + float2(1.0, 1.0)), u.x),
               u.y);
}

static float wt_fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * wt_vnoise(p);
        p = p * 2.0 + float2(3.14, 1.59);
        a *= 0.5;
    }
    return v;
}

vertex WireTerrainVSOut wireterrain_vs(uint vid [[vertex_id]],
                                       const device float3* verts [[buffer(0)]],
                                       constant WireTerrainUniforms& u [[buffer(1)]]) {
    float3 pos = verts[vid];

    // Scroll noise on the Y-of-XZ axis so the scene sweeps forward in time.
    float2 p  = pos.xz * 0.15 + float2(0.0, u.time * 0.35);
    float n   = wt_fbm(p);
    float n2  = wt_fbm(p * 2.7 + float2(7.1, 3.3));
    float h   = (n  - 0.5) * (2.5 + u.bass   * 3.5)
              + (n2 - 0.5) * (0.6 + u.treble * 0.8);
    h += u.beatPulse * 0.9;
    pos.y = h;

    float4 viewPos = u.viewMatrix * float4(pos, 1.0);

    WireTerrainVSOut o;
    o.position = u.projectionMatrix * viewPos;
    o.vHeight  = h;
    o.vXZ      = pos.xz;
    o.viewZ    = viewPos.z;
    return o;
}

fragment float4 wireterrain_fs(WireTerrainVSOut in [[stage_in]],
                               constant WireTerrainUniforms& u [[buffer(0)]]) {
    // Height → violet→blue→cyan gradient (same three stops + smoothstep
    // bounds as the web fragment shader).
    float h01 = clamp((in.vHeight + 2.5) / 6.0, 0.0, 1.0);
    float3 low  = float3(0.55, 0.10, 0.75);
    float3 mid  = float3(0.20, 0.40, 0.95);
    float3 high = float3(0.20, 0.95, 0.90);
    float3 col  = mix(low, mid, smoothstep(0.0, 0.55, h01));
    col         = mix(col, high, smoothstep(0.45, 1.0, h01));

    // Grid-cell tint so wireframe reads structured, not uniform.
    float cell = sin(in.vXZ.x * 2.0) * sin(in.vXZ.y * 2.0);
    col *= 0.85 + 0.15 * cell;

    // Bass punches brightness; beat adds a quick flash.
    col *= 0.8 + u.bass * 0.45 + u.beatPulse * 0.3;

    // FogExp2(0x000008, density=0.035). Three.js: f = exp(-d*d * z*z) where
    // z is magnitude of view-space Z. Mix from fog-color toward scene color.
    float  fogDepth  = abs(in.viewZ);
    float  fogFactor = exp(-u.fogDensity * u.fogDensity * fogDepth * fogDepth);
    float3 fogColor  = float3(0.0, 0.0, 8.0 / 255.0);   // 0x000008
    col = mix(fogColor, col, clamp(fogFactor, 0.0, 1.0));

    return float4(col, 1.0);
}
