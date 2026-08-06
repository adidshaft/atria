# Atria onboarding — image asset prompts (GPT Image 2)

Hand this whole file to Codex. Each section = one asset: where it goes, what to
export, the generation prompt (copy-paste block), and what to avoid. Claude has
already created the empty asset slots and wired the app to use them, so once the
PNGs are dropped in, they appear automatically (no code changes needed).

---

## Shared art direction (paste this at the top of any generation request)

> **Product:** Atria — a calm, premium, iOS-native health app that reads
> **recovery, sleep and strain** from a wearable strap. It is the honest,
> no-subscription alternative to the big fitness apps.
> **Aesthetic:** clean, minimal, "liquid glass," lots of soft diffuse light,
> Apple-keynote restraint. Nothing loud, nothing salesy.
> **Palette:** recovery = green, sleep = indigo/violet, strain = blue; the
> onboarding surface is light/airy (and also has a dark-mode variant).
> **Hard rules for every image:** absolutely **no brand logos, wordmarks, or
> text of any kind**; no watermarks; no smartwatch / no screen or watch-face;
> photoreal or clean 3D only, never clip-art.

GPT Image 2 supported sizes: `1024x1024`, `1536x1024` (landscape), `1024x1536`
(portrait). Sizes below use those. Export **PNG**.

---

## Asset 1 — `AtriaStrapHero` (the strap, hero image)

- **Directory:** `Atria/Atria/Assets.xcassets/AtriaStrapHero.imageset/`
- **Export:** one PNG, **1536×1024**, **transparent background (alpha)**. Save as
  `atria-strap-hero.png` in that folder, then set the imageset `Contents.json` to:
  ```json
  {
    "images" : [
      { "filename" : "atria-strap-hero.png", "idiom" : "universal", "scale" : "1x" },
      { "idiom" : "universal", "scale" : "2x" },
      { "idiom" : "universal", "scale" : "3x" }
    ],
    "info" : { "author" : "xcode", "version" : 1 },
    "properties" : { "preserves-vector-representation" : true }
  }
  ```
- **How it's used:** it renders `scaledToFit` inside a soft blue "glass" panel at
  the top of the *Connect your strap* page — so a wide, centered subject on a
  transparent background is ideal.

### Prompt (primary — photoreal render)
```
Premium studio product render of a modern, unbranded wellness wearable BAND
(not a smartwatch), shown at a gentle three-quarter top angle, floating with a
soft contact shadow. Form: a smooth continuous loop of matte charcoal
woven-fabric strap, with one compact rounded-square sensor module seamlessly
set into the band — the module has a brushed dark-graphite bezel and a smooth
glassy black top face (no screen, no display, no UI, no buttons, no ports), with
a faint cyan-blue sensor light glowing gently on its underside. Lighting: soft
even key light from the upper-left plus a delicate cyan-to-blue rim light
tracing one edge for a cool "liquid glass" sheen; clean highlights, subtle
reflections. Style: minimalist Apple-keynote product photography — extremely
clean, high fidelity, photoreal, sharp focus, gentle depth of field. Composition:
the band centered with generous negative space. Background: fully transparent
(alpha) — no floor, no gradient, no props. No brand logos, wordmarks, or writing
anywhere.
```
**Avoid:** any logo/text/wordmark; a smartwatch, watch face, or screen with UI;
buttons or charging ports made prominent; cluttered background or props; neon or
oversaturated colors; plastic-toy look.

### Prompt (alternative — clean 3D illustration, if the photoreal one clashes with the flat UI)
```
A clean, premium semi-3D illustration of a modern, unbranded wellness wearable
BAND (not a smartwatch): a smooth charcoal fabric loop with one small rounded
sensor module and a faint cyan sensor glow. Soft studio lighting, subtle
gradients, gentle ambient occlusion, matte materials, minimal and calm. Apple-
keynote clarity, no hard outlines. Centered subject, generous negative space,
fully transparent background. No logos, no text, no screen, no watch face.
```

---

## Asset 2 — `AtriaOnboardingBackdrop` (ambient background, light + dark)

- **Directory:** `Atria/Atria/Assets.xcassets/AtriaOnboardingBackdrop.imageset/`
- **Export:** two PNGs, **1024×1536** (portrait), **opaque**. Save as
  `backdrop-light.png` and `backdrop-dark.png`, then set `Contents.json` to:
  ```json
  {
    "images" : [
      { "filename" : "backdrop-light.png", "idiom" : "universal" },
      { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
        "filename" : "backdrop-dark.png", "idiom" : "universal" }
    ],
    "info" : { "author" : "xcode", "version" : 1 }
  }
  ```
- **How it's used:** full-bleed behind the whole onboarding flow (aspect-fill, so
  the top/bottom may crop slightly — keep detail away from the exact edges).
  **Critical:** the centre must stay quiet so onboarding text stays perfectly
  legible on top.

### Light prompt
```
A soft, premium ambient background for a wellness app onboarding screen, vertical
2:3 orientation. An almost-white base (near #F5F6F8) with gentle, extremely
desaturated color blooms — pale mint-green drifting in from the top, soft
lavender-violet in the lower-left, faint sky-blue in the lower-right — all
blurred into smooth, glassy, out-of-focus light. Keep the central vertical third
nearly clean and bright so dark UI text remains perfectly legible over it. Calm,
airy, minimal, Apple-like. No objects, no shapes, no lines, no text — only soft
diffuse light. High resolution, smooth gradient with fine grain to avoid banding.
```

### Dark prompt
```
A soft, premium ambient background for a wellness app onboarding in dark mode,
vertical 2:3 orientation. A deep near-black base (near #0A0D12) with faint, moody
color glows — a subtle emerald-green haze near the top, a dim indigo-violet glow
lower-left, a faint deep-blue glow lower-right — all very low intensity, blurred
and glassy. Keep the central vertical third dark and clean so light UI text stays
perfectly legible. Calm, premium, cinematic, minimal. No objects, no shapes, no
text — only soft diffuse light. High resolution, smooth, fine grain, no banding.
```
**Avoid (both):** hard shapes, geometric patterns, high contrast, busy detail,
anything in the central band that would fight text, text/watermarks, heavy vignette.

---

## Optional extras (only if you want them — ask Claude and I'll add slots + wiring)

- **Worn lifestyle shot** — the same band on a forearm, soft natural light,
  shallow depth of field, neutral skin-tone-inclusive, transparent or blurred
  background. Good for a warmer first screen. (1536×1024)
- **Per-metric ambient accents** — three faint circular glows (green / violet /
  blue) as decorative haloes behind the recovery-sleep-strain tiles. (1024×1024
  each, transparent) — low priority; the code-drawn rings already cover this.

---

## Handoff back to Claude

Once the PNGs are in the two imagesets above (and their `Contents.json` set as
shown), tell Claude. The strap hero already renders from `AtriaStrapHero`; Claude
will then wire `AtriaOnboardingBackdrop` behind the onboarding flow (with the
existing gradient as the reduce-transparency / no-image fallback) and screenshot-
verify text legibility over it.

---

# REVISION 2 — WHOOP-calibrated product renders (2026-07-30)

The first renders were competent but **flat, side-on loops on a solid background**.
The reference look (WHOOP onboarding) is a **dynamic angled 3/4 hero** with
**cinematic, high-contrast studio lighting**, deep shadows and a cool rim light,
the sensor module heroed toward camera. Regenerate with the prompts below. Keep
**transparent backgrounds** — Claude will put them on a dark "showcase" panel so
the highlights + cyan glow pop (see Integration at the end).

**The three fixes that matter most:** (1) angled 3/4 view, NOT a flat side loop;
(2) dramatic directional lighting with real shadow + specular, NOT flat even light;
(3) the sensor module clearly facing the camera as the focal point.

## R2 · Strap hero (primary → `AtriaStrapHero` / `AtriaStrapHero3D`)
1536×1024, transparent PNG.
```
Ultra-premium 3D product HERO render of an unbranded fitness/wellness wearable BAND
(NOT a smartwatch), captured at a dynamic three-quarter angle so the band sweeps
diagonally through the frame and its sensor module faces the camera as the focal
point. The band is a matte charcoal-black woven/knit elastic strap with crisp,
realistic fabric texture. A single compact rounded-rectangular sensor module sits
on the band: smooth glossy black glass top face, a brushed dark-gunmetal frame, and
a soft cyan-blue sensor glow spilling from underneath it onto the fabric. Cinematic
studio lighting — one strong soft key light from the upper left, deep controlled
shadows, crisp specular highlights on the metal and glass, and a cool blue rim light
tracing the far edge. High-contrast, Apple-keynote hero photography, photoreal,
razor-sharp focus with a subtle shallow depth of field, floating with a soft drop
shadow. Fully transparent background (alpha). No brand logos, wordmarks, "W" mark,
lettering, screen, watch face, or props of any kind.
```
Avoid: flat side-on bracelet view; smartwatch / display / watch face; any logo or
text; flat even lighting; plastic-toy look; busy or colored background.

## R2 · Optional set (mirrors the reference flow)
Ask Claude to add slots + wiring if you want these as extra onboarding steps.
- **"Unbox" — band + charger pod together** (1536×1024, transparent):
  ```
  Ultra-premium 3D product render, unbranded fitness BAND (matte charcoal woven
  strap + glossy-black sensor module with cyan under-glow) beside a small squircle
  matte-black charging pod, both floating at a three-quarter angle with soft drop
  shadows. Cinematic key light upper-left, deep shadows, cool rim light, photoreal,
  Apple-keynote hero. Transparent background. No logos, no text, no screen.
  ```
- **Sensor / clasp macro** (1536×1024, transparent):
  ```
  Ultra-premium macro product render of the sensor module on an unbranded fitness
  band: glossy black glass face, brushed gunmetal frame, a bright cyan-blue pairing
  light glowing along one edge, fine woven-fabric texture around it. Dramatic raking
  light, deep shadow, crisp speculars, shallow depth of field, photoreal, cinematic.
  Transparent background. No logos, no text, no watch face.
  ```
- **Worn lifestyle (improved)** (1536×1024, transparent or softly blurred bg):
  ```
  Editorial lifestyle photo: the unbranded matte-charcoal fitness band worn snug on
  a forearm/wrist, tasteful and inclusive skin tone, natural soft directional light,
  shallow depth of field, calm premium mood. The sensor module (glossy black, faint
  cyan glow) reads clearly. Clean, un-distracting background. No logos, no text.
  ```

## R2 · Integration (Claude will do this)
The reference renders live on a **dark gradient**. To match, keep the renders
**transparent** and Claude will switch the onboarding strap-hero panel (currently a
soft blue gradient) to a **dark premium "showcase" gradient** so the metal
highlights and cyan glow pop — working in both light and dark onboarding. Just say
"make the hero panel dark" and it's done + screenshot-verified.
