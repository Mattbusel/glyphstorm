# Glyphstorm

Photos and video, rebuilt out of text characters that have weight and move like it.

An iOS app, authored entirely on Windows, built and submitted by a cloud macOS
runner. Nobody touches a Mac.

---

## What you have to do

Four things. Everything else is automated.

### 1. Push this to GitHub

```bash
git add -A
git commit -m "Glyphstorm v1"
git remote add origin git@github.com:Mattbusel/ascii-motion.git
git push -u origin main
```

### 2. Add four repository secrets

`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | `7ZMV4Z7XB8` |
| `ASC_ISSUER_ID` | `5673d5a6-4fcb-46aa-8f10-7e1af68f8143` |
| `ASC_KEY_CONTENT` | the `.p8` file, base64 encoded (below) |
| `DEVELOPMENT_TEAM` | your ten character Team ID, from developer.apple.com → Membership |

To get `ASC_KEY_CONTENT`, in PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Downloads\AuthKey_7ZMV4Z7XB8.p8"))
```

Paste the whole line as the secret value. **Do not commit the `.p8`** — it is in
`.gitignore` for a reason: that key is full Admin access to your developer
account.

### 3. Turn on GitHub Pages

`Settings → Pages → Source: Deploy from a branch → main → /docs`

This publishes the support and privacy pages at
`https://mattbusel.github.io/ascii-motion/`, which are the two URLs Apple
requires and which `fastlane/metadata/en-US/` already points at. Apple rejects
submissions where the privacy URL does not load, so check it before submitting.

### 4. Create the app record in App Store Connect

Once, by hand, because the first record needs the bundle ID registered:

- **Name:** Glyphstorm
- **Bundle ID:** `com.mattbusel.asciimotion` (register it under
  Certificates → Identifiers first)
- **SKU:** `ascii-motion-1`
- **Price:** Tier 8 (US$7.99)

Then run the pipeline: `Actions → App Store → Run workflow`.

---

## The three pipeline modes

Pick one when you run the workflow.

| Mode | What it does |
| --- | --- |
| `screenshots` | Boots a simulator, drives the app, captures the store screenshots and hands them back as a downloadable artifact. Nothing is uploaded. **Run this first.** |
| `dry_run` | Builds, signs, uploads the binary, the metadata and the screenshots to App Store Connect. Does **not** submit. Look at the listing, then submit by hand or run `release`. |
| `release` | Everything, including Submit for Review. Irreversible. |

Run `screenshots` first and actually look at them. It is the only way either of
us finds out what the app looks like, since none of this has been run yet.

---

## How it works

The interesting part is `Sources/Engine/`.

- **`GlyphField.swift`** — the substrate. Every cell of the source image becomes
  a glyph with a home, a velocity and a spring holding it in place. The source
  sets each glyph's *character and colour* and never its position, which is what
  lets a video's frames change underneath a field that keeps moving.
- **`Shaders.metal`** — one instanced draw call for the whole picture. Every
  glyph is built from its own instance record, so forty thousand characters cost
  the GPU one command.
- **`FontAtlas.swift`** — the ramp, drawn into one texture at launch.
- **`Exporter.swift`** — renders through the same renderer the preview uses, at a
  fixed timestep so an export is deterministic rather than depending on how busy
  the phone was.

Physics runs on the CPU and rendering on the GPU. The preview and the exporter
never run at once: `EditorModel.isExporting` pauses the MTKView, and that is the
entire concurrency story.

---

## Status

**This has never been compiled.** It was written on Windows, where no Swift
toolchain or iOS SDK exists. The first CI run is also the first build, and it
will probably surface some errors. Fix them and run it again — that is the
expected path, not a sign anything is wrong.
