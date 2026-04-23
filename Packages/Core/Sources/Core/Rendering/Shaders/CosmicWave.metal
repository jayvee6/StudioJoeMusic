#include <metal_stdlib>
using namespace metal;

// Layout (48 bytes — matches Swift CosmicWaveUniforms exactly):
//   [0..3]   time        float
//   [4..7]   bass        float
//   [8..11]  mid         float
//   [12..15] treble      float
//   [16..19] spinAngle   float — CPU-accumulated ring rotation
//   [20..23] _pad0       float — brings float2 to 8-byte boundary at offset 24
//   [24..31] resolution  float2
//   [32..35] valence     float
//   [36..39] energy      float
//   [40..43] danceability float
//   [44..47] tempoBPM    float
struct CosmicWaveUniforms {
    float  time;
    float  bass;
    float  mid;
    float  treble;
    float  spinAngle;
    float  _pad0;
    float2 resolution;
    float  valence;
    float  energy;
    float  danceability;
    float  tempoBPM;
};

struct CWVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex CWVSOut cosmicwave_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    CWVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ── Utilities ─────────────────────────────────────────────────────────────────

static float3 cw_hsl2rgb(float h, float s, float l) {
    float3 rgb = clamp(abs(fmod(h * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0,
                       0.0, 1.0);
    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    return l + c * (rgb - 0.5);
}

static float cw_hash(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float cw_noise(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(cw_hash(i),               cw_hash(i + float3(1,0,0)), f.x),
            mix(cw_hash(i + float3(0,1,0)), cw_hash(i + float3(1,1,0)), f.x), f.y),
        mix(mix(cw_hash(i + float3(0,0,1)), cw_hash(i + float3(1,0,1)), f.x),
            mix(cw_hash(i + float3(0,1,1)), cw_hash(i + float3(1,1,1)), f.x), f.y), f.z);
}

static float cw_fbm(float3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * cw_noise(p);
        p  = p * 2.01 + float3(3.1, 7.4, 1.9);
        a *= 0.5;
    }
    return v;
}

// ── Transforms ────────────────────────────────────────────────────────────────

static float3 cw_rotY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(c*p.x + s*p.z, p.y, -s*p.x + c*p.z);
}

// ── Frequency-modulated torus (XY plane, hole axis = Z) ───────────────────────
// 32 FFT bins are mapped uniformly around the full circumference.
// tube radius = baseR + mags[bin] * modDepth
static float cw_torusSDF(float3 p, float majorR, float baseR,
                          constant float* mags, float modDepth) {
    float angle = atan2(p.y, p.x);                         // -π..π
    float t     = (angle + M_PI_F) / (2.0 * M_PI_F);      // 0..1
    float binF  = t * 31.0;
    int   b0    = int(binF);
    int   b1    = min(b0 + 1, 31);
    float mag   = mix(mags[b0], mags[b1], fract(binF));
    float tubeR = baseR + mag * modDepth;
    float2 q    = float2(length(p.xy) - majorR, p.z);
    return length(q) - tubeR;
}

// Analytic XY-plane torus normal
static float3 cw_torusNormal(float3 p, float majorR) {
    float pxyLen = max(length(p.xy), 1e-4);
    float2 q     = float2(pxyLen - majorR, p.z);
    float3 dqx   = float3(p.x / pxyLen, p.y / pxyLen, 0.0);
    return normalize(q.x * dqx + q.y * float3(0, 0, 1));
}

// ── Fragment ──────────────────────────────────────────────────────────────────

fragment float4 cosmicwave_fs(CWVSOut in [[stage_in]],
                               constant CosmicWaveUniforms& u [[buffer(0)]],
                               constant float*              mags [[buffer(1)]]) {
    float asp = u.resolution.x / u.resolution.y;
    float2 uv = (in.uv - 0.5) * float2(asp, 1.0);

    float3 ro = float3(0.0, 0.0, 2.6);
    float3 rd = normalize(float3(uv, -1.6));

    // Bounding-sphere fast-reject (radius 1.1 covers all 3 rings)
    const float BOUND = 1.1;
    float b2   = dot(ro, rd);
    float disc = b2 * b2 - (dot(ro, ro) - BOUND * BOUND);

    const float MAJOR_R   = 0.62;   // torus major radius
    const float BASE_R    = 0.010;  // minimum tube radius (silence)
    const float MOD_DEPTH = 0.088;  // FFT magnitude modulates tube by this much

    // Three rings — face-on (0°) + tilted ±60° around Y: gyroscope triple halo
    const float TILT = 1.0472;      // 60° in radians

    float3 col    = float3(0.0);
    bool   showBg = true;

    if (disc >= 0.0) {
        float tNear = max(0.001, -b2 - sqrt(disc) - 0.05);
        float tFar  = -b2 + sqrt(disc) + 0.05;
        float t     = tNear;

        bool   hit     = false;
        int    hitRing = 0;
        float3 hitP    = float3(0.0);

        for (int i = 0; i < 90; i++) {
            float3 wp = ro + rd * t;

            // Slow global spin rotates the frequency spectrum around the rings
            float cs = cos(u.spinAngle), ss = sin(u.spinAngle);
            float3 ps = float3(cs*wp.x - ss*wp.y, ss*wp.x + cs*wp.y, wp.z);

            // Ring 0: face-on in XY plane
            float3 p0 = ps;
            // Ring 1: tilted +60° around Y
            float3 p1 = cw_rotY(ps,  TILT);
            // Ring 2: tilted -60° around Y
            float3 p2 = cw_rotY(ps, -TILT);

            float d0 = cw_torusSDF(p0, MAJOR_R, BASE_R, mags, MOD_DEPTH);
            float d1 = cw_torusSDF(p1, MAJOR_R, BASE_R, mags, MOD_DEPTH);
            float d2 = cw_torusSDF(p2, MAJOR_R, BASE_R, mags, MOD_DEPTH);

            float d = d0; hitRing = 0; hitP = p0;
            if (d1 < d) { d = d1; hitRing = 1; hitP = p1; }
            if (d2 < d) { d = d2; hitRing = 2; hitP = p2; }

            if (d < 0.0009) { hit = true; showBg = false; break; }
            if (t > tFar + 0.1) break;
            t += max(d * 0.40, 0.0009);
        }

        if (hit) {
            // Ring-local angle → frequency position → hue
            float ringAngle = atan2(hitP.y, hitP.x) + u.spinAngle;
            float tPos      = (ringAngle + M_PI_F) / (2.0 * M_PI_F);  // 0..1

            float binF = tPos * 31.0;
            int   b0   = int(binF);
            int   b1   = min(b0 + 1, 31);
            float mag  = mix(mags[b0], mags[b1], fract(binF));

            // Hue: bass (low tPos) → red (0.0), treble (high tPos) → violet (0.75)
            float hue = tPos * 0.75 + float(hitRing) * 0.06;

            float sat = 0.92 + mag * 0.08;
            float lum = 0.24 + mag * 0.56;
            lum *= (0.65 + u.energy * 0.70);
            lum  = min(lum, 0.90);

            col = cw_hsl2rgb(fract(hue), sat, lum);

            // Diffuse + rim highlight
            float3 n   = cw_torusNormal(hitP, MAJOR_R);
            float3 L   = normalize(float3(0.8, 1.0, 0.6));
            float  NdL = max(0.25, dot(n, L));
            col *= NdL;
            float rim = NdL * NdL * NdL;
            col += float3(rim) * 0.28 * (0.5 + u.energy * 0.6);
        }
    }

    if (showBg) {
        // Deep space: very dark base + two-layer nebula + sparse stars
        float3 bg  = float3(0.0, 0.0, 0.018);
        float3 rdn = normalize(rd);

        float neb1 = cw_fbm(rdn * 0.55 + float3(u.time * 0.003,  0.15, 0.50));
        float neb2 = cw_fbm(rdn * 1.10 + float3(0.40, u.time * 0.005, 0.90));
        float3 nc1 = mix(float3(0.010, 0.0,   0.045), float3(0.0, 0.012, 0.040), u.valence);
        float3 nc2 = mix(float3(0.018, 0.005, 0.0),   float3(0.006, 0.018, 0.010), u.valence);
        bg += nc1 * neb1 * (0.40 + u.energy * 0.50);
        bg += nc2 * neb2 * (0.24 + u.energy * 0.30);

        // Sparse stars — brighter for the top-1% cells
        float3 cell = floor(rdn * 140.0);
        float  r    = cw_hash(cell);
        if (r > 0.990) bg += float3(0.5 + 0.5 * r) * (r > 0.997 ? 1.2 : 0.7);

        col = bg;
    }

    return float4(max(col, float3(0.0)), 1.0);
}
