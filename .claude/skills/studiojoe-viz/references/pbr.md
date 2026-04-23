# PBR — Three.js r128 ↔ Metal

Physically based rendering cheat sheet for music viz that want realistic lighting (Chrome disco ball, future HDR sphere viz, any scene with visible material + lighting interplay).

## Philosophy

Music viz don't need film-accurate PBR. They need "looks correct under lights and tone-mapped output" — enough fidelity that chrome reads as chrome and a stage light reads as a spotlight, not a flashlight. That means:

- Linear-space rendering (`outputEncoding = sRGBEncoding` on the renderer, sRGB textures decoded to linear on read).
- Physically-correct light falloff (`physicallyCorrectLights = true` on r128 renderer; Metal analogs below).
- Tone-mapped output (ACES Filmic is the default choice — matches Chrome viz's look).
- HDR-ish internal values (> 1.0 in linear space is fine; the tone mapper compresses to display).

## Three.js r128 setup

### Renderer state

r128's defaults differ from r160. If a viz wants PBR, save + restore these in init/teardown (see `patterns.md` §4):

```js
r.physicallyCorrectLights = true;
r.toneMapping             = THREE.ACESFilmicToneMapping;
r.toneMappingExposure     = 1.0;
r.outputEncoding          = THREE.sRGBEncoding;
```

### Materials

Prefer `MeshPhysicalMaterial` for anything that needs roughness/metalness/clearcoat/IOR. It's a superset of `MeshStandardMaterial`:

```js
const mat = new THREE.MeshPhysicalMaterial({
  color:        0xffffff,
  metalness:    1.0,        // 1.0 for chrome/mirror, 0.0 for plastic/dielectric
  roughness:    0.15,       // 0 = mirror, 1 = fully diffuse
  clearcoat:    0.0,
  envMap:       myCubeOrPMREM,  // the lighting rig
  envMapIntensity: 1.0,
});
```

For chrome/disco surfaces, metalness=1.0 + roughness≈0.1 + a bright `envMap` is the recipe. The envMap is what gives chrome its "reflected room" look — without it, metalness=1.0 renders as black.

### Environment map (the single most load-bearing thing)

Chrome + mirror surfaces are 90% envMap. Use `PMREMGenerator` to prefilter a scene or HDR image:

```js
const pmrem = new THREE.PMREMGenerator(renderer);
pmrem.compileEquirectangularShader();   // one-time setup
const envRT = pmrem.fromScene(myLightingScene, 0.04);
scene.environment = envRT.texture;
// assign to materials' envMap too if not using scene.environment
```

Lighting scene can be a procedural room: a dark sphere with a few colored `MeshBasicMaterial` "stage lights" placed at specific positions. Chrome viz does exactly this — see its init for reference.

### Lights

With `physicallyCorrectLights = true`, light intensities use lumens-adjacent units. Starting values:
- `DirectionalLight`: intensity ~3–5 (sun-like)
- `PointLight`: intensity ~50–200 at distance ~5
- `AmbientLight`: intensity ~0.3 (don't rely on this; an envMap is better ambient)

Shadow-casting needs `.castShadow = true` on the light + mesh, plus `renderer.shadowMap.enabled = true`. Disco ball doesn't need shadows — the envMap fakes them via reflection darkening.

### Postprocessing

EffectComposer chain for a typical PBR viz:

```js
const composer = new THREE.EffectComposer(renderer);
composer.addPass(new THREE.RenderPass(scene, camera));
composer.addPass(new THREE.UnrealBloomPass(
  new THREE.Vector2(innerWidth, innerHeight),
  1.5,    // strength
  1.0,    // radius
  0.1     // threshold — values above this bloom
));
// ... render via composer.render() instead of renderer.render() in your render loop
```

Bloom is what sells the "chrome reflects bright stage lights" look — the highlights blow out and glow.

## Metal PBR (iOS)

### Light + material model

iOS viz currently use single-pass fragment shaders (no deferred pipeline). For a future PBR viz, the per-pixel lighting loop looks like:

```metal
// GGX specular + Lambertian diffuse
float3 pbr(float3 albedo, float metallic, float roughness,
           float3 N, float3 V, float3 L, float3 lightColor) {
    float3 H = normalize(V + L);
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float NdotH = max(dot(N, H), 0.0);
    float VdotH = max(dot(V, H), 0.0);

    float a  = roughness * roughness;
    float a2 = a * a;

    // Trowbridge-Reitz GGX distribution
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    float D = a2 / (M_PI_F * denom * denom);

    // Smith + Schlick geometry
    float k  = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    float G1L = NdotL / (NdotL * (1.0 - k) + k);
    float G1V = NdotV / (NdotV * (1.0 - k) + k);
    float G  = G1L * G1V;

    // Fresnel-Schlick
    float3 F0 = mix(float3(0.04), albedo, metallic);
    float3 F  = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);

    float3 spec = (D * G * F) / max(4.0 * NdotV * NdotL, 0.001);
    float3 kd   = (1.0 - F) * (1.0 - metallic);

    return (kd * albedo / M_PI_F + spec) * lightColor * NdotL;
}
```

### Tone mapping in Metal

Apply ACES at the end of the fragment:

```metal
// Narkowicz 2015 approximation
float3 acesFilm(float3 x) {
    float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}
```

Pair with the `MTLPixelFormat` you render into — if it's sRGB (e.g., `bgra8Unorm_srgb`), Metal does the gamma conversion automatically on write; you only need the tone mapper before that.

### Apple samples for Metal PBR

See `metal-samples-index.md`:
- **RenderingASceneWithDeferredLightingInSwift** — HIGH tier. Deferred G-buffer + light accumulation; closest to a multi-light PBR pipeline. Use when a future viz needs many small lights (disco ball with per-tile spotlights, etc.).
- **ProcessingHDRImagesWithMetal** — MEDIUM tier. HDR pipeline + tone-mapping operators.
- **RenderingASceneWithForwardPlusLightingUsingTileShaders** — MEDIUM tier. Tile-based forward+ for many-light scenes.

## Parity notes

If you ship a PBR viz on both platforms:

- Roughness/metalness numeric values must match (they're unitless ratios, not platform-specific).
- Light intensities must match numerically IF the Metal side also uses `physicallyCorrectLights`-equivalent scaling.
- envMap HDR values must match — prefilter both sides from the same source if possible.
- Tone mapper must match (both ACES), and exposure value must match.

See `parity.md` for the tuning-propagation rule.
