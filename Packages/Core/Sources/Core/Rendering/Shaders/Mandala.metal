#include <metal_stdlib>
using namespace metal;

struct MandalaUniforms {
    float rot;        // radians, CPU-accumulated
    float hue;        // 0..1, CPU-accumulated
    float bass;
    float treble;
    float2 resolution;
};

struct MVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex MVSOut mandala_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    MVSOut o;
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

// Regular-polygon SDF.
static float sdPolygon(float2 p, int n, float r) {
    float angle = atan2(p.y, p.x);
    float dist = length(p);
    float sector = 2.0 * M_PI_F / float(n);
    float a = fmod(angle + sector * 0.5 + sector, sector) - sector * 0.5;
    float inscribed = r * cos(a);
    return dist - inscribed;
}

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// Crisp stroke with just a hint of halo. `w` is the full half-width of the sharp line.
// Hard-edge smoothstep (w → w*0.05) keeps polygon corners visibly angular; halo is
// deliberately dim so the geometry reads as polygons, not rounded rings.
static float strokeContribution(float d, float w, float glowWidth) {
    float absD = abs(d);
    float core = smoothstep(w, w * 0.05, absD);
    float halo = exp(-absD / max(glowWidth, 0.00001)) * 0.18;
    return core + halo;
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    // Short-side square projection so sizes match min(W,H).
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    // Fill factor — expands the visualizer into the long dimension of the screen so
    // portrait doesn't feel like a small centered square. Capped so the outermost
    // layer doesn't clip off the short side too aggressively.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    float3 color = float3(0.0);

    // 6 distinct polygon shapes — triangle, square, pentagon, hex, hept, oct —
    // stacked outward so each ring has its own recognizable silhouette.
    const int SIDES[6] = {3, 4, 5, 6, 7, 8};
    float maxR = 0.38 * fillFactor;
    const int ringCount = 6;
    float radiusScale = 0.40 + u.bass * 0.90;

    // Thin laser line. Kept small on purpose — a laser is a hairline, not a painted stroke.
    float lineW = 0.0020 + u.bass * 0.0040;

    for (int i = 0; i < ringCount; i++) {
        int sides = SIDES[i];

        // Adjacent rings spin opposite directions for a counter-rotating feel.
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float2 p = rot2(uv, u.rot * dir);

        float r = maxR * (float(i) + 1.0) / float(ringCount) * radiusScale;

        // Web layer hue: (hue + i*42°) wrapped. HSL(hue, 100%, 55%) keeps colour saturated
        // so the neon halo reads as colour even with a white-biased core.
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0), 1.0);
        float3 base = hsl2rgb(layerHue, 1.0, 0.55);

        // Primary polygon stroke.
        float d1 = sdPolygon(p, sides, r);
        float absD1 = abs(d1);

        // Laser core — nearly-white at the line, bass pushes it fully white.
        float core1 = smoothstep(lineW, lineW * 0.08, absD1);
        float3 coreCol1 = mix(base, float3(1.0), 0.45 + u.bass * 0.35);
        color = max(color, coreCol1 * core1 * (0.85 + u.bass * 0.30));

        // Neon halo — wide colored bloom, additive so adjacent polygons add warmth.
        float haloNear1 = exp(-absD1 / (lineW * 3.5)) * 0.42;
        float haloFar1  = exp(-absD1 / (lineW * 10.0)) * 0.12;
        color += base * (haloNear1 + haloFar1) * (0.65 + u.bass * 0.55);

        // Secondary polygon: half-sector-offset, 0.72× scale. Reduced core, same halo
        // math so the inner shape still participates in the bloom without competing
        // for attention with the primary silhouette.
        float halfSector = M_PI_F / float(sides);
        float2 p2 = rot2(p, halfSector);
        float d2 = sdPolygon(p2, sides, r * 0.72);
        float absD2 = abs(d2);

        float core2 = smoothstep(lineW * 0.85, lineW * 0.08, absD2);
        float3 coreCol2 = mix(base, float3(1.0), 0.40);
        color = max(color, coreCol2 * core2 * 0.55);

        float haloNear2 = exp(-absD2 / (lineW * 3.0)) * 0.28;
        color += base * haloNear2 * (0.55 + u.bass * 0.40);
    }

    // Subtle center haze so full-bass frames don't feel empty at the core.
    float centerHaze = smoothstep(0.45, 0.0, length(uv)) * 0.05 * (0.4 + u.bass);
    color += float3(0.22, 0.24, 0.38) * centerHaze;

    return float4(max(color, float3(0.0)), 1.0);
}
