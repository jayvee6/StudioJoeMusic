#include <metal_stdlib>
using namespace metal;

struct CosmicWaveUniforms {
    float  time;
    float  bass;
    float  mid;
    float  treble;
    float  spinAngle;   // CPU-accumulated rotation of the colour spectrum
    float  _pad0;       // explicit pad — aligns float2 to 8-byte boundary
    float2 resolution;
    float  valence;
    float  energy;
    float  danceability;
    float  tempoBPM;
};

struct CVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex CVSOut cosmicwave_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    CVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ── Utilities ─────────────────────────────────────────────────────────────────

static float3 chsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
                       0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

static float ch1(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float cn3(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(ch1(i),                ch1(i+float3(1,0,0)), f.x),
            mix(ch1(i+float3(0,1,0)), ch1(i+float3(1,1,0)), f.x), f.y),
        mix(mix(ch1(i+float3(0,0,1)), ch1(i+float3(1,0,1)), f.x),
            mix(ch1(i+float3(0,1,1)), ch1(i+float3(1,1,1)), f.x), f.y), f.z);
}

static float cfbm(float3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * cn3(p);
        p  = p * 2.01 + float3(3.1, 7.4, 1.9);
        a *= 0.5;
    }
    return v;
}

// ── Transforms ────────────────────────────────────────────────────────────────

static float3 crotY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(c*p.x + s*p.z, p.y, -s*p.x + c*p.z);
}

static float3 crotZ(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(c*p.x - s*p.y, s*p.x + c*p.y, p.z);
}

// ── Frequency-modulated torus (XY-plane, hole axis = Z) ───────────────────────
// The torus major radius is R; tube radius = minorR + mags[bin] * scale.
// This is an approximate SDF — step multiplier kept conservative (0.4).
static float freqTorusSDF(float3 p, float majorR, float minorR,
                           constant float* mags, float energy) {
    // Angle around the torus ring (for frequency bin lookup)
    float  angle = atan2(p.y, p.x);
    float  t     = (angle + M_PI_F) / (2.0 * M_PI_F);   // 0..1

    // Linearly interpolate between adjacent bins
    float binF = t * 31.0;
    int   bin0 = int(binF);
    int   bin1 = min(bin0 + 1, 31);
    float mag  = mix(mags[bin0], mags[bin1], fract(binF));

    float tubeR = minorR + mag * 0.09 * (0.55 + energy * 0.9);

    // Standard torus (XY plane) SDF
    float2 q = float2(length(p.xy) - majorR, p.z);
    return length(q) - tubeR;
}

// Analytic torus normal (gradient of the standard XY-plane torus SDF)
static float3 torusNormal(float3 p, float majorR) {
    float pxy = max(length(p.xy), 0.0001);
    float qx  = pxy - majorR;
    float2 q  = float2(qx, p.z);
    float  ql = length(q);
    float3 dqx_dp = float3(p.x / pxy, p.y / pxy, 0.0);
    return normalize(q.x * dqx_dp + q.y * float3(0, 0, 1)) / max(ql, 0.0001);
}

// ── Fragment ──────────────────────────────────────────────────────────────────

fragment float4 cosmicwave_fs(CVSOut in [[stage_in]],
                               constant CosmicWaveUniforms& u [[buffer(0)]],
                               constant float*              mags [[buffer(1)]]) {
    float asp = u.resolution.x / u.resolution.y;
    float2 uv = (in.uv - 0.5) * float2(asp, 1.0);

    float3 ro = float3(0.0, 0.0, 2.5);
    float3 rd = normalize(float3(uv, -1.5));

    // ── Bounding sphere fast-reject ───────────────────────────────────────────
    const float boundR = 1.0;
    float b2   = dot(ro, rd);
    float disc = b2 * b2 - (dot(ro, ro) - boundR * boundR);

    const float R      = 0.65;   // major radius shared by all rings
    const float r_base = 0.012;  // minimum tube radius (mag=0)

    // Tilt angles for Ring 1 and Ring 2 around the Y axis (±50°)
    const float tiltAngle = 0.873;   // ~50° in radians

    float3 col    = float3(0.0);
    bool   showBg = true;

    if (disc >= 0.0) {
        float tStart = max(0.001, -b2 - sqrt(disc) - 0.05);
        float tEnd   = -b2 + sqrt(disc) + 0.05;
        float t      = tStart;

        bool  hit     = false;
        int   hitRing = 0;
        float3 hitP   = float3(0.0);

        for (int i = 0; i < 80; i++) {
            float3 wp = ro + rd * t;

            // Apply slow global spin (rotates colour spectrum around rings)
            float3 ps = crotZ(wp, u.spinAngle);

            // Ring 0: face-on in XY plane
            float3 p0 = ps;
            // Ring 1: tilted +50° around Y
            float3 p1 = crotY(ps, tiltAngle);
            // Ring 2: tilted -50° around Y — gyroscope-like triple halo
            float3 p2 = crotY(ps, -tiltAngle);

            float d0 = freqTorusSDF(p0, R, r_base, mags, u.energy);
            float d1 = freqTorusSDF(p1, R, r_base, mags, u.energy);
            float d2 = freqTorusSDF(p2, R, r_base, mags, u.energy);

            // Union — track closest ring for later coloring
            float d = d0; hitRing = 0; hitP = p0;
            if (d1 < d) { d = d1; hitRing = 1; hitP = p1; }
            if (d2 < d) { d = d2; hitRing = 2; hitP = p2; }

            if (d < 0.001) { hit = true; showBg = false; break; }
            if (t > tEnd + 0.1) break;
            // Conservative step: approximate SDF, variable tube radius
            t += max(d * 0.4, 0.001);
        }

        if (hit) {
            // ── Surface color ────────────────────────────────────────────────
            // Angle in ring-local space → frequency bin → hue
            float angle = atan2(hitP.y, hitP.x) + u.spinAngle;
            float tPos  = (angle + M_PI_F) / (2.0 * M_PI_F);   // 0..1

            float binF = tPos * 31.0;
            int   bin0 = int(binF);
            int   bin1 = min(bin0 + 1, 31);
            float mag  = mix(mags[bin0], mags[bin1], fract(binF));

            // Hue: bass at 0 (red), treble at 0.75 (blue-violet)
            float hue = tPos * 0.75;
            // Each ring offset so they differ slightly
            hue += float(hitRing) * 0.07;

            float lum = 0.30 + mag * 0.55;
            lum *= (0.65 + u.energy * 0.70);
            lum  = min(lum, 0.92);

            col = chsl2rgb(fract(hue), 0.95, lum);

            // ── Simple diffuse lighting ───────────────────────────────────────
            float3 n   = torusNormal(hitP, R);
            float3 L   = normalize(float3(1.0, 1.0, 0.8));
            float  NdL = max(0.3, dot(n, L));
            col *= NdL;
            // Specular rim for tube glow
            col += float3(NdL * NdL * NdL) * 0.25 * (0.6 + u.energy * 0.6);
        }
    }

    if (showBg) {
        // Deep space with nebula and distant stars
        float3 bg = float3(0.0, 0.0, 0.018);

        float3 rdn = normalize(rd);
        float  neb = cfbm(float3(rdn.xy * 0.6 + float2(u.time * 0.004, 0.2), 0.4));
        float3 nc  = mix(float3(0.012, 0.0, 0.05), float3(0.0, 0.015, 0.04), u.valence);
        bg += nc * neb * (0.45 + u.energy * 0.45);

        // Sparse star field
        float3 cell = floor(rdn * 130.0);
        float  r    = ch1(cell);
        if (r > 0.991) bg += float3(0.6) * (0.5 + 0.5 * r);

        col = bg;
    }

    return float4(max(col, float3(0.0)), 1.0);
}
