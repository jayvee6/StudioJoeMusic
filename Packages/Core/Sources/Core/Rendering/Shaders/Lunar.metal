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

// ── Moon SDF ─────────────────────────────────────────────────────────────────

// Quartic bowl: smooth depression, C¹ at rim. Per-crater Lipschitz ≈ 0.12.
static float craterBowl(float3 p, float3 c, float r) {
    float d = saturate(length(p - c) / r);
    float w = 1.0 - d * d;
    return -w * w * r * 0.08;
}

static float moonSDF(float3 p, float bass) {
    float R   = 0.65 + bass * 0.04;
    float sdf = length(p) - R;
    // Craters spread across the full sphere so all rotation angles look interesting
    sdf += craterBowl(p, normalize(float3( 0.30,  0.55,  0.78)) * R, 0.22);
    sdf += craterBowl(p, normalize(float3(-0.55,  0.20,  0.81)) * R, 0.15);
    sdf += craterBowl(p, normalize(float3( 0.12, -0.60,  0.79)) * R, 0.17);
    sdf += craterBowl(p, normalize(float3( 0.82,  0.10,  0.56)) * R, 0.12);
    sdf += craterBowl(p, normalize(float3(-0.40, -0.30,  0.86)) * R, 0.11);
    sdf += craterBowl(p, normalize(float3(-0.10,  0.83,  0.55)) * R, 0.14);
    sdf += craterBowl(p, normalize(float3( 0.40, -0.55, -0.74)) * R, 0.19);
    sdf += craterBowl(p, normalize(float3(-0.70,  0.25, -0.67)) * R, 0.13);
    sdf += (lfbm(p * 4.0) - 0.5) * 0.025;   // fine surface roughness
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
    // Bright sparse layer with treble-driven twinkling
    {
        float3 cell = floor(d * 100.0);
        float  r    = lh1(cell);
        if (r > 0.989) {
            float twinkle = 0.7 + 0.3 * sin(time * 4.0 + r * 43.0 + treble * 10.0);
            s += twinkle;
        }
    }
    // Faint dense layer — no twinkling
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

    const float tilt   = 0.18;    // ~10° axis tilt for realism
    const float boundR = 0.75;    // bounding sphere radius (R_base + margins)

    // Fast reject: ray vs bounding sphere centred at origin
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
            // Rotate world point into moon-local space (inverse of moon rotation)
            float3 lp = lrotX(lrotY(wp, -u.rotY), -tilt);
            float  d  = moonSDF(lp, u.bass);
            if (d < 0.001) { hit = true; hitLocal = lp; break; }
            if (t > tEnd + 0.1) break;
            t += max(d * 0.88, 0.001);
        }

        if (hit) {
            float3 n = moonNormal(hitLocal, u.bass);

            // Albedo: FBM-driven dark maria vs bright highlands
            float mariaV = lfbm(hitLocal * 1.9 + 3.1);
            float alb    = mix(0.22, 0.82, smoothstep(0.38, 0.62, mariaV));
            float3 surf  = float3(alb) * float3(0.87, 0.90, 0.93);

            // Cool directional moonlight
            float3 L   = normalize(float3(-0.9, 1.3, 0.7));
            float  NdL = max(0.0, dot(n, L));
            // Soft terminator roll-off instead of hard shadow boundary
            float  lit = smoothstep(0.0, 0.12, NdL) * NdL;

            col = surf * float3(0.92, 0.95, 1.0) * (0.04 + lit);
            col *= (1.0 + u.energy * 0.25);

            // Limb darkening — grazing-angle surfaces appear darker
            float3 V   = normalize(lrotX(lrotY(-rd, -u.rotY), -tilt));
            float  NdV = max(0.0, dot(n, V));
            col *= (0.45 + 0.55 * NdV);
        } else {
            showBg = true;
        }
    }

    if (showBg) {
        float  s   = starField(rd, u.time, u.treble);
        col = float3(s) * float3(0.92, 0.95, 1.0);
        // Faint nebula haze tinted by mood valence
        float  neb = lfbm(float3(rd.xy * 0.9 + float2(u.time * 0.012, 0.3), 0.5));
        float3 nc  = mix(float3(0.0, 0.01, 0.04), float3(0.02, 0.0, 0.05), u.valence);
        col += nc * neb * 0.35;
    }

    return float4(max(col, float3(0.0)), 1.0);
}
