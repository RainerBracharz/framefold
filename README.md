<div align="center">

<img src="docs/icon.png" width="120" alt="FrameFold" />

# FrameFold

**Turn a video of your working process into an automatic stop-motion — entirely on your iPhone.**

[![iOS Build](https://github.com/RainerBracharz/framefold/actions/workflows/ios-build.yml/badge.svg)](https://github.com/RainerBracharz/framefold/actions/workflows/ios-build.yml)
&nbsp;·&nbsp; SwiftUI &nbsp;·&nbsp; On-device computer vision &nbsp;·&nbsp; iOS 17+

</div>

<div align="center">
<img src="docs/app.png" width="880" alt="FrameFold — home, projects and export, auto-shutter camera" />
</div>

---

FrameFold records a working process on video and condenses it into a stop-motion animation on its own: it finds the calm moments, drops every frame where hands are in the shot, stabilises hand-held footage, and assembles the result — all locally, nothing leaves the device.

It was built as a **bespoke tool for the Austrian artist [Aldo Tolino](https://www.aldotolino.com/)**, whose practice folds printed photographs into sculptural objects and photographs them again — *“every image can be printed, therefore folded; a folded object can be photographed and become an image again — an endless loop between image and object.”* FrameFold is an instrument inside that loop: its whole design and language are drawn from his work.

## What it does

- **Video → stop-motion, automatically.** Samples the footage, scores motion and sharpness, and keeps one clean frame per “rest” moment.
- **Hands removed.** Frames with visible hands are discarded via Apple’s Vision hand-pose detection (with an optional path to a custom-trained RF-DETR CoreML model).
- **Auto-shutter camera.** Put the phone on a tripod; it captures a frame by itself whenever your hands leave the frame and the scene settles. The camera then **locks exposure, focus and white balance** so nothing drifts between frames, snaps the shutter speed to the mains frequency to avoid LED flicker, and offers **tap-to-focus**, an **interval (time-lapse) trigger**, a live motion gauge, spirit level, thirds grid and haptic shutter.
- **Onion skin & drift check.** Overlay the previous frame — or the **very first** frame of the session — at adjustable opacity, plus an optional external reference image, to catch drift early. The screen stays awake for the whole session.
- **Review before render.** Every candidate frame shown as a contact sheet; deselect with a tap, play the selection as a live loop before committing.
- **Hand-held stabilisation.** Each frame is aligned to a fixed reference (verified block-matching) so free-hand footage sits still.
- **Projects & archive.** Works organised in series, collected across many sessions, with a 30-day trash, a print-ready **contact-sheet PDF** and a **fold-template PDF** for printing and re-folding.
- **Exhibition reel.** Assemble several works into one continuous reel with catalogue title cards.
- **Private by design.** All processing is on-device. No account, no upload, no server.

## Three modes

| Mode | For |
|---|---|
| **Simple** | Pick a video, get a stop-motion. Nothing else on screen. |
| **Advanced** | Frame rate, aspect, resolution, playback mode, stabilisation. |
| **Aldo Tolino** | Everything, plus the studio effects below. |

**The Tolino stage:** *print look* (black & white on a warm paper tone), *paper relief* (each facet catching the light differently — as if the image had been folded and re-photographed), *image echo* (each frame lingering in the next — a recursion of its own image), and fold transitions in three styles — **crease**, **facets** and **weave**, the last drawn from his woven paper works.

## How it works

```
Video ─▶ sample ~10 fps ─▶ motion + sharpness scoring ─▶ Otsu “rest” detection
      ─▶ hand removal (Vision / RF-DETR) ─▶ dedup ─▶ review ─▶ stabilise ─▶ assemble (AVAssetWriter)
```

The signal-processing core (rest detection, sharpness, perceptual hashing, crop geometry, shift estimation) is isolated in a single dependency-free file and covered by **60+ tests that run on every push**, so the maths is verified independently of the Apple frameworks.

## Design — “Crack & Light”

The language is drawn from Tolino’s 2024 series (*Full-Blown*, *Cracked*, the reliefs): crushed white paper on luminous gradient fields, colour glowing **through** the sheet, and **amber** as his recurring signal. The gallery is a light wall with a soft vertical light gradient; the darkroom stays warm for capture. Colour enters as light behind the paper — amber first, then teal and slate; muted sage, marble and moss carry the per-work accents.

The home screen doesn’t describe folding, it **crumples**: an irregular fractured paper field, filled with the frames of your latest work, hung with a soft shadow like a print on the wall. **Tilt the phone and the light travels across the facets** — as if you were turning the print under gallery light: image → object → image, made physical. The finished stop-motion is presented like his editions — sealed under acrylic glass, with a gloss, a shadow and an edition line (“Serie von 8 · datiert 2026”).

Typography pairs **Fraunces** (serif — with the *italic* as the speaking voice, as on his website) with **Inter** (the annotation-on-the-back-of-a-print voice), both bundled and registered at runtime. Selection is marked by inversion — an ink block — never by colour.

**The mark** is not a letter. A sheet whose folded corner contains a sheet, whose folded corner contains a sheet — Tolino’s endless loop *image → object → image* drawn as a figure, with amber marking the layer you currently stand on. Its concentric squares nod to Albers, whom he cites directly when he asks “whether the surface itself can generate images”.

## Engineering

| | |
|---|---|
| **UI** | SwiftUI (iOS 17+) |
| **Vision / capture** | AVFoundation, Vision, CoreMotion, Core Image |
| **On-device ML** | Apple Vision hand-pose; CoreML-ready for a custom RF-DETR model |
| **Persistence** | File-based projects with JSON manifests |
| **CI/CD** | GitHub Actions on macOS — builds the app and runs the test suite on every commit |
| **Tests** | 60+ unit tests on the pure algorithmic core |

## Build & run

1. Download the repository (green **Code → Download ZIP**) and open `FrameFold.xcodeproj`.
2. Select your Team under **Signing & Capabilities** (a free Apple ID is enough).
3. Connect an iPhone, hit **⌘R**.

## Credits

Designed and built by **[Bracharz Consulting](https://www.bracharz.com)** — Rainer Bracharz, Certified Digital Consultant — as a bespoke commission for artist **[Aldo Tolino](https://www.aldotolino.com/)**. Developed rapidly with AI-assisted engineering and a fully automated build-and-verify pipeline.

Typefaces: [Fraunces](https://github.com/undercasetype/Fraunces) and [Inter](https://github.com/rsms/inter), both under the SIL Open Font License (see `FrameFold/Fonts-Licenses/`).

*Status: beta, in active development.*

---

© 2026 Bracharz Consulting. All rights reserved. Artwork and process shown belong to Aldo Tolino.
