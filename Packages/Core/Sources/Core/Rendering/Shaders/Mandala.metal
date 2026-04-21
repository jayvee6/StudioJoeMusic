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

// TRUE-distance signed distance function for a regular polygon — Iñigo Quilez.
// https://iquilezles.org/articles/distfunctions2d/
//
// The previous `sdPolygon(p, n, r) = length(p) - r*cos(a)` had a zero-level set that
// passed through each vertex and edge midpoint but BULGED OUTWARD between them —
// stroking |d| < w rendered a thin band along a CURVE, not a polygon edge. Every
// "polygon" read as a lobed arc, which is why no amount of line-width tuning ever
// produced visible corners.
//
// This version reduces the point to a single sector via rotational + mirror symmetry,
// then computes the TRUE perpendicular distance to one edge of the polygon treated
// as a line segment. The zero-level set IS the regular polygon. Stroke thickness is
// uniform, corners are sharp, vertices pop.
static float sdRegularPolygon(float2 p, float r, int n) {
    float an  = M_PI_F / float(n);
    float2 acs = float2(cos(an), sin(an));

    // Fold into the half-sector [-an, +an] centered on the nearest edge midpoint.
    //
    // GLSL's mod() returns values in [0, y) for positive y; Metal's fmod() can
    // return negatives when the dividend is negative. atan2 returns values in
    // [-π, π], so without normalization the fold was incorrect for points in the
    // left half of the coord system — entire edges of the polygon went undrawn.
    // Normalize to a positive angle first so the fold lands in [-an, +an].
    float theta = atan2(p.x, p.y);
    if (theta < 0.0) theta += 2.0 * M_PI_F;
    float bn = fmod(theta, 2.0 * an) - an;
    p = length(p) * float2(cos(bn), abs(sin(bn)));

    // Distance to the edge treated as a line segment. In the folded frame,
    // x = r*cos(an) is the apothem, y ranges over the segment's half-length.
    p -= r * acs;
    p.y += clamp(-p.y, 0.0, r * acs.y);
    return length(p) * sign(p.x);
}

// Star SDF — Iñigo Quilez. n points, `m` controls pointiness (between 2 and n).
// m = 2 is sharpest (classic pentagram / star-of-david shape); m → n flattens
// toward a regular n-gon.
static float sdStar(float2 p, float r, int n, float m) {
    float an = M_PI_F / float(n);
    float en = M_PI_F / m;
    float2 acs = float2(cos(an), sin(an));
    float2 ecs = float2(cos(en), sin(en));

    float theta = atan2(p.x, p.y);
    if (theta < 0.0) theta += 2.0 * M_PI_F;
    float bn = fmod(theta, 2.0 * an) - an;
    p = length(p) * float2(cos(bn), abs(sin(bn)));

    p -= r * acs;
    p += ecs * clamp(-dot(p, ecs), 0.0, r * acs.y / ecs.y);
    return length(p) * sign(p.x);
}

static float2 rot2(float2 p, float a) {
    float c = cos(a), s = sin(a);
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

fragment float4 mandala_fs(MVSOut in [[stage_in]],
                           constant MandalaUniforms& u [[buffer(0)]]) {
    // Short-side square projection so sizes match min(W,H).
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = in.uv - 0.5;
    if (aspect > 1.0) uv.x *= aspect; else uv.y /= aspect;

    // Fill factor so the mandala grows into the screen's long dimension.
    float fillFactor = min(1.35, max(aspect, 1.0 / aspect));

    // Hairline neon polygons with a tight halo (reference look).
    float maxR = 0.38 * fillFactor;
    float lineW = 0.0022 + u.bass * 0.0030;
    float haloW = 0.005  + u.bass * 0.007;
    float radiusScale = 0.55 + u.bass * 0.60;

    // Six layers with genuinely distinct silhouettes — polygons and stars alternating
    // so adjacent layers look clearly different at a glance. Inner → outer:
    //   Layer 0: triangle
    //   Layer 1: square
    //   Layer 2: 5-point pentagram (star)
    //   Layer 3: hexagon
    //   Layer 4: 6-point star (hexagram / star-of-David)
    //   Layer 5: octagon
    const int   SHAPE_KIND[6]  = {0, 0, 1, 0, 1, 0};  // 0 = polygon, 1 = star
    const int   SHAPE_SIDES[6] = {3, 4, 5, 6, 6, 8};
    const float SHAPE_M[6]     = {0.0, 0.0, 2.0, 0.0, 2.0, 0.0};

    // Alpha-over compositor — each layer paints over earlier ones translucently
    // (matches Canvas 2D's default source-over blend). Preserves layer identity at
    // crossings instead of piling up into an additive flower bloom.
    float4 accum = float4(0.0);

    // Paint from INNER (i=0, smallest shape) outward. Outer layers overlay inner,
    // matching the web's draw order.
    for (int i = 0; i < 6; i++) {
        int sides = SHAPE_SIDES[i];

        // Adjacent rings counter-rotate so the tilts alternate (matches reference).
        float dir = (i % 2 == 0) ? 1.0 : -1.0;
        float layerRot = u.rot * dir + float(i) * M_PI_F / 6.0;
        float2 p = rot2(uv, layerRot);

        float r = maxR * (float(i) + 1.0) / 6.0 * radiusScale;

        // Distinct hue per layer (web: hue + i*42°).
        float layerHue = fmod(u.hue + float(i) * (42.0 / 360.0), 1.0);
        float3 lineCol = hsl2rgb(layerHue, 1.0, 0.62);

        float d;
        if (SHAPE_KIND[i] == 0) {
            d = sdRegularPolygon(p, r, sides);
        } else {
            d = sdStar(p, r, sides, SHAPE_M[i]);
        }
        float absD = abs(d);

        // Sharp hairline core (smoothstep from lineW → ~0 keeps the line opaque at
        // its centerline, fading cleanly to nothing past lineW).
        float core = smoothstep(lineW, lineW * 0.1, absD);

        // Tight neon halo — narrow exponential so it suggests glow without blooming
        // across adjacent layers.
        float glow = exp(-absD / haloW) * 0.32;

        float srcAlpha = (0.75 + u.bass * 0.25) * (core + glow);
        srcAlpha = clamp(srcAlpha, 0.0, 1.0);
        float3 srcRGB = lineCol;

        // Standard source-over: out.rgb = src.rgb*src.a + dst.rgb*(1-src.a).
        accum.rgb = srcRGB * srcAlpha + accum.rgb * (1.0 - srcAlpha);
        accum.a   = srcAlpha          + accum.a   * (1.0 - srcAlpha);
    }

    // Drawable is opaque — force full alpha so the BlueHourBackground doesn't bleed
    // through under the composited mandala.
    return float4(accum.rgb, 1.0);
}
