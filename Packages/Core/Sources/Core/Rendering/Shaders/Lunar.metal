#include <metal_stdlib>
using namespace metal;

struct LunarUniforms {
    float  time;
    float  rotY;
    float  bass;
    float  treble;
    float2 resolution;
    float  valence;
    float  energy;
    float  danceability;
    float  tempoBPM;
};

struct LVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex LVSOut lunar_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    LVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// ── Hash / value noise / FBM ─────────────────────────────────────────────────

static float lh1(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float ln3(float3 x) {
    float3 i = floor(x), f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(mix(lh1(i),                lh1(i+float3(1,0,0)), f.x),
            mix(lh1(i+float3(0,1,0)), lh1(i+float3(1,1,0)), f.x), f.y),
        mix(mix(lh1(i+float3(0,0,1)), lh1(i+float3(1,0,1)), f.x),
            mix(lh1(i+float3(0,1,1)), lh1(i+float3(1,1,1)), f.x), f.y), f.z);
}

static float lfbm(float3 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * ln3(p);
        p  = p * 2.01 + float3(1.7, 9.2, 3.3);
        a *= 0.5;
    }
    return v;
}

// ── Hi-res bump map (shading-only — never fed into the SDF) ──────────────────
// Three widely-separated scale bands: coarse terrain, mid rock, fine grit.
// Using independent noise lookups (not FBM-chained) so each band stays crisp
// and the bump doesn't devolve into mush at high frequency.
static float bumpHeight(float3 p) {
    float h = 0.0;
    h += ln3(p *  6.0 + float3( 1.3, 2.7, 8.1)) * 0.50;   // coarse terrain
    h += ln3(p * 18.0 + float3(11.7, 3.1, 5.9)) * 0.28;   // mid rock
    h += ln3(p * 55.0 + float3( 2.9, 7.3, 1.1)) * 0.14;   // fine grit
    return h;
}

// Finite-difference gradient of the bump height (6 samples, central differences).
static float3 bumpGrad(float3 p) {
    const float e = 0.0025;
    float2 k = float2(e, 0.0);
    float  inv2e = 1.0 / (2.0 * e);
    return float3(
        bumpHeight(p + k.xyy) - bumpHeight(p - k.xyy),
        bumpHeight(p + k.yxy) - bumpHeight(p - k.yxy),
        bumpHeight(p + k.yyx) - bumpHeight(p - k.yyx)) * inv2e;
}

// Micro-crater field — hash-sampled inside a cell grid. Returns an albedo
// darkening factor (0 = no crater here, 1 = strong dimple). The bumpHeight
// function above already supplies high-frequency normal perturbation, so this
// only darkens albedo rather than producing bump normals.
static float microCraterDarken(float3 p, float cellScale) {
    float3 pS   = p * cellScale;
    float3 cell = floor(pS);
    float3 frac = fract(pS);
    float  dark = 0.0;
    for (int dz = -1; dz <= 1; dz++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float3 offset = float3(dx, dy, dz);
                float3 ncell  = cell + offset;
                float  r1     = lh1(ncell);
                if (r1 < 0.70) continue;                     // ~30% of cells have a crater
                float  r2     = lh1(ncell + 77.3);
                float3 center = offset + float3(r2, fract(r1 * 43.0), fract(r2 * 91.0)) * 0.7 + 0.15;
                float  cR     = 0.12 + r2 * 0.25;
                float  d      = length(frac - center) / cR;
                if (d >= 1.0) continue;
                float bowl = 1.0 - d * d;                    // quadratic falloff
                dark += bowl * (0.15 + r2 * 0.20);
            }
        }
    }
    return dark;
}

// ── Moon SDF (kept smooth/low-freq so raymarching stays well-behaved) ────────

// Quartic bowl: smooth depression, C¹ at rim. Per-crater Lipschitz ≈ 0.12.
static float craterBowl(float3 p, float3 c, float r) {
    float d = saturate(length(p - c) / r);
    float w = 1.0 - d * d;
    return -w * w * r * 0.08;
}

static float moonSDF(float3 p, float bass) {
    float R   = 0.65 + bass * 0.04;
    float sdf = length(p) - R;
    // Named craters — big enough to affect the silhouette
    sdf += craterBowl(p, normalize(float3( 0.30,  0.55,  0.78)) * R, 0.22);
    sdf += craterBowl(p, normalize(float3(-0.55,  0.20,  0.81)) * R, 0.15);
    sdf += craterBowl(p, normalize(float3( 0.12, -0.60,  0.79)) * R, 0.17);
    sdf += craterBowl(p, normalize(float3( 0.82,  0.10,  0.56)) * R, 0.12);
    sdf += craterBowl(p, normalize(float3(-0.40, -0.30,  0.86)) * R, 0.11);
    sdf += craterBowl(p, normalize(float3(-0.10,  0.83,  0.55)) * R, 0.14);
    sdf += craterBowl(p, normalize(float3( 0.40, -0.55, -0.74)) * R, 0.19);
    sdf += craterBowl(p, normalize(float3(-0.70,  0.25, -0.67)) * R, 0.13);
    sdf += (lfbm(p * 4.0) - 0.5) * 0.025;   // low-freq silhouette roughness
    return sdf;
}

static float3 moonNormal(float3 p, float bass) {
    const float2 e = float2(0.0015, 0.0);
    return normalize(float3(
        moonSDF(p+e.xyy,bass) - moonSDF(p-e.xyy,bass),
        moonSDF(p+e.yxy,bass) - moonSDF(p-e.yxy,bass),
        moonSDF(p+e.yyx,bass) - moonSDF(p-e.yyx,bass)));
}

// ── Transforms ───────────────────────────────────────────────────────────────

static float3 lrotY(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(c*p.x + s*p.z, p.y, -s*p.x + c*p.z);
}

static float3 lrotX(float3 p, float a) {
    float c = cos(a), s = sin(a);
    return float3(p.x, c*p.y - s*p.z, s*p.y + c*p.z);
}

// ── Star field ────────────────────────────────────────────────────────────────

static float starField(float3 dir, float time, float treble) {
    float3 d = normalize(dir);
    float  s = 0.0;
    {
        float3 cell = floor(d * 100.0);
        float  r    = lh1(cell);
        if (r > 0.989) {
            float twinkle = 0.7 + 0.3 * sin(time * 4.0 + r * 43.0 + treble * 10.0);
            s += twinkle;
        }
    }
    {
        float3 cell = floor(d * 160.0);
        float  r    = lh1(cell + float3(7.3, 2.1, 9.8));
        if (r > 0.996) s += 0.35;
    }
    return min(s, 1.0);
}

// ── Fragment ──────────────────────────────────────────────────────────────────

fragment float4 lunar_fs(LVSOut in [[stage_in]],
                         constant LunarUniforms& u [[buffer(0)]]) {
    float asp = u.resolution.x / u.resolution.y;
    float2 uv = (in.uv - 0.5) * float2(asp, 1.0);

    float3 ro = float3(0.0, 0.0, 2.5);
    float3 rd = normalize(float3(uv, -1.4));

    const float tilt   = 0.18;
    const float boundR = 0.75;

    float  b2   = dot(ro, rd);
    float  disc = b2 * b2 - (dot(ro, ro) - boundR * boundR);

    float3 col    = float3(0.0);
    bool   showBg = false;

    if (disc < 0.0) {
        showBg = true;
    } else {
        float tStart = max(0.001, -b2 - sqrt(disc) - 0.05);
        float tEnd   = -b2 + sqrt(disc) + 0.05;
        float t      = tStart;
        bool  hit    = false;
        float3 hitLocal;

        for (int i = 0; i < 80; i++) {
            float3 wp = ro + rd * t;
            float3 lp = lrotX(lrotY(wp, -u.rotY), -tilt);
            float  d  = moonSDF(lp, u.bass);
            if (d < 0.001) { hit = true; hitLocal = lp; break; }
            if (t > tEnd + 0.1) break;
            t += max(d * 0.88, 0.001);
        }

        if (hit) {
            // ── Base geometric normal from the SDF ───────────────────────────
            float3 nGeom = moonNormal(hitLocal, u.bass);

            // ── High-frequency bump: perturb normal in the tangent plane ─────
            // Removes the component of the bump gradient parallel to the
            // geometric normal so we only tilt within the tangent plane —
            // otherwise the bump would rotate the silhouette and look broken
            // at grazing angles.
            float3 bg       = bumpGrad(hitLocal);
            float3 tangGrad = bg - dot(bg, nGeom) * nGeom;
            float3 n = normalize(nGeom - tangGrad * 0.045);

            // Micro-crater albedo darkening (normal detail already handled by
            // bumpGrad's 55× scale band).
            float microDark = microCraterDarken(hitLocal, 26.0);

            // ── Multi-scale albedo ───────────────────────────────────────────
            // Macro: dark maria vs bright highlands
            float mariaV = lfbm(hitLocal * 1.9 + 3.1);
            float mariaM = smoothstep(0.38, 0.62, mariaV);
            // Meso: rocky mottle across medium patches
            float rockyV = lfbm(hitLocal * 7.5 + 11.0);
            // Micro: dusty fine grit
            float dustV  = lfbm(hitLocal * 24.0 + 3.3);

            float alb = mix(0.22, 0.82, mariaM);
            alb *= mix(0.82, 1.14, rockyV);
            alb *= mix(0.92, 1.08, dustV);
            // Micro-crater dark spots further darken the albedo
            alb *= (1.0 - microDark * 0.22);
            alb  = clamp(alb, 0.14, 0.95);

            // Slightly cooler tint on highlands, warmer on maria (subtle)
            float3 surfTint = mix(float3(0.85, 0.88, 0.91),    // maria (warmer, duskier)
                                  float3(0.90, 0.92, 0.95),    // highlands (cooler)
                                  mariaM);
            float3 surf = float3(alb) * surfTint;

            // ── Lighting: distant orbiting "sun" point light ─────────────────
            // The sun lives in WORLD space and its position drifts so the
            // terminator sweeps naturally across the moon as the moon rotates.
            // A slow elevation wobble keeps the shadow line from being boringly
            // vertical. Converted into moon-local space for dot products with
            // the local-space surface normal.
            float  sunOrbit = u.time * 0.08;                        // ~78s / rev
            float  sunElev  = 0.32 + 0.14 * sin(u.time * 0.035);
            float  ce       = cos(sunElev);
            float3 sunWorld = float3(cos(sunOrbit) * ce,
                                     sin(sunElev),
                                     sin(sunOrbit) * ce) * 6.0;     // r = 6 units
            float3 sunLocal = lrotX(lrotY(sunWorld, -u.rotY), -tilt);

            float3 toSun   = sunLocal - hitLocal;
            float  sunDist = length(toSun);
            float3 L       = toSun / sunDist;

            // Gentle inverse-square-ish falloff — clamped so the whole moon
            // stays visible under natural conditions
            float sunAtten = clamp(36.0 / (sunDist * sunDist), 0.75, 1.15);

            float NdL = max(0.0, dot(n, L));
            // Soft terminator roll-off — the shadow line is never a hard edge
            float lit = smoothstep(0.0, 0.14, NdL) * NdL;

            // Warm sunlight tint (slight yellow), cool ambient sky fill (blue)
            float3 sunColor = float3(1.00, 0.96, 0.88);
            float3 skyFill  = float3(0.32, 0.40, 0.55);

            col  = surf * sunColor * lit * sunAtten;
            // Earthshine-style ambient fill from above, subtle
            col += surf * skyFill * 0.035 * max(0.25, 0.5 + 0.5 * nGeom.y);
            // Very faint base ambient so unlit side isn't pure black
            col += surf * 0.015;

            col *= (1.0 + u.energy * 0.20);

            // Limb darkening
            float3 V   = normalize(lrotX(lrotY(-rd, -u.rotY), -tilt));
            float  NdV = max(0.0, dot(nGeom, V));
            col *= (0.45 + 0.55 * NdV);
        } else {
            showBg = true;
        }
    }

    if (showBg) {
        float  s   = starField(rd, u.time, u.treble);
        col = float3(s) * float3(0.92, 0.95, 1.0);
        float  neb = lfbm(float3(rd.xy * 0.9 + float2(u.time * 0.012, 0.3), 0.5));
        float3 nc  = mix(float3(0.0, 0.01, 0.04), float3(0.02, 0.0, 0.05), u.valence);
        col += nc * neb * 0.35;
    }

    return float4(max(col, float3(0.0)), 1.0);
}
