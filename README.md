# Glyphstorm

Photos and video for iPhone, rebuilt out of text characters that have weight and move like it.

![iOS 17+](https://img.shields.io/badge/iOS-17%2B-black) ![SwiftUI + Metal](https://img.shields.io/badge/SwiftUI-Metal-orange) ![Built on GitHub Actions](https://img.shields.io/badge/built%20on-GitHub%20Actions%20macOS-2088FF)

**Coming to the App Store.**

<p align="center">
  <img src="fastlane/screenshots/en-US/iPhone%2017%20Pro%20Max-01_Fluid.png" width="250" alt="Glyphstorm screenshot">
  <img src="fastlane/screenshots/en-US/iPhone%2017%20Pro%20Max-02_Burst.png" width="250" alt="Glyphstorm screenshot">
  <img src="fastlane/screenshots/en-US/iPhone%2017%20Pro%20Max-03_Drift.png" width="250" alt="Glyphstorm screenshot">
</p>

Most ASCII filters paste flat text over a picture. In Glyphstorm every character is an object with mass, held to its home by a spring, so when the field is disturbed the picture flexes, tears and pulls itself back together. Heavy characters lag, light ones fly, and the image stays readable because everything is trying to get home. The whole thing renders in one instanced Metal draw call.

## Features

- Pick a photo or a video with the system picker (no photo library permission needed)
- Three motions: **Fluid** (currents, like something suspended in water), **Burst** (a shockwave the image keeps pulling back from) and **Drift** (every glyph wanders on its own)
- Controls for how much movement and how big the characters are
- Video works too: the characters chase the moving image instead of being redrawn each frame
- Export the result and share it anywhere

## Privacy

No network code at all: Glyphstorm makes no requests and collects no data. It uses the system photo picker and only ever sees the one file you choose. No account, no subscription.

## How it works

The interesting part is `Sources/Engine/`.

| File | What it does |
| --- | --- |
| `GlyphField.swift` | The substrate. Every cell of the source becomes a glyph with a home, a velocity and a spring. The source sets each glyph's character and colour, never its position, which is what lets a video's frames change underneath a field that keeps moving. |
| `Shaders.metal` / `GlyphRenderer.swift` | One instanced draw call for the whole picture: every glyph is built from its own instance record, so tens of thousands of characters cost the GPU one command. |
| `FontAtlas.swift` | The character ramp, drawn into one texture at launch, darkest coverage last. |
| `ImageSampler.swift` | Reduces a picture to one pixel per glyph. |
| `VideoSource.swift` | A looping video (AVFoundation) that hands out whatever frame is showing now. |
| `Exporter.swift` | Renders through the same renderer as the preview, at a fixed timestep, so an export is deterministic regardless of how busy the phone was. |

Physics runs on the CPU and rendering on the GPU. The preview and the exporter never run at once: `EditorModel.isExporting` pauses the `MTKView`, and that is the entire concurrency story. `Sources/App/` holds the two SwiftUI screens (home and editor) around it.

## Built without a Mac

Glyphstorm was written on a Windows PC and has never been opened in Xcode by a person. Everything runs on GitHub Actions macOS runners through one manual workflow, `.github/workflows/appstore.yml`:

| Mode | What it does |
| --- | --- |
| `compile` | Generate the project and build, no simulator boot |
| `screenshots` | Drive the app in a simulator with a UI test (`Tests/ScreenshotTests`, fastlane `snapshot`) and hand back the store screenshots as an artifact |
| `dry_run` | Build, sign, upload the binary, metadata and screenshots; do not submit |
| `release` | Everything, including Submit for Review |

- `project.yml` is an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated on the runner and never committed.
- Signing imports a distribution certificate from a secret into a throwaway keychain, and [fastlane](https://fastlane.tools) fetches the App Store profile with an App Store Connect API key.
- `Store/asc.py`, `Store/listing.py` and `Store/signing.py` talk to the App Store Connect API from Windows (Python) for the bundle id, metadata, listing and certificate.
- `docs/` is the GitHub Pages site with the support and privacy pages the listing links to.

## Build and run

With a Mac and Xcode 26:

```bash
brew install xcodegen
xcodegen generate
open ASCIIMotion.xcodeproj
```

Run the `ASCIIMotion` scheme (the project's internal name; bundle id `com.mattbusel.asciimotion`) on a real device for Metal performance, or on a simulator. Without a Mac: fork, then run the App Store workflow in `compile` or `screenshots` mode. Releasing needs the secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `DEVELOPMENT_TEAM`, `DIST_CERT_P12` and `DIST_CERT_PASSWORD`.

## Status

Builds, signs and screenshots in CI; not yet on the App Store.

---

**More apps built the same way:** [Chain](https://github.com/Mattbusel/chain), [Ironbook](https://github.com/Mattbusel/ironbook), [Quiver](https://github.com/Mattbusel/quiver), [Race Fuel](https://github.com/Mattbusel/race-fuel), [Minder](https://github.com/Mattbusel/minder), [Baseline Ledger](https://github.com/Mattbusel/baseline-ledger), [Fairway Ledger](https://github.com/Mattbusel/fairway-ledger), [Odometer](https://github.com/Mattbusel/odometer), [Rooms](https://github.com/Mattbusel/rooms), [Clockout](https://github.com/Mattbusel/clockout), [Curve](https://github.com/Mattbusel/curve), [Pricebook](https://github.com/Mattbusel/pricebook), [Chores](https://github.com/Mattbusel/chores), [Pawprint](https://github.com/Mattbusel/pawprint), [Pocket Beings](https://github.com/Mattbusel/pocket-beings), [Clear the Strait](https://github.com/Mattbusel/clear-the-strait).


## Hire the author

I designed, built and shipped this app myself. **Want one like it for your business?** I build native iOS apps from prototype to App Store launch, fixed price. [Services and pricing](https://mattbusel.github.io/) · [Email](mailto:mattbusel@gmail.com) · [LinkedIn](https://www.linkedin.com/in/matthewbusel/)
