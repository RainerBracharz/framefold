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

## Design — “Fold & Flood”

The language is drawn from Tolino’s recent work: matte paper folded over geological and aqueous photography. A warm **bone** gallery for viewing and a warm **darkroom** for capture; ink is a warm black, never a hard neutral. Colour enters only where light breaks in the fold — a single **marine** accent from his flood series, with muted rock, sage and marble as the per-work accents.

The home screen doesn’t describe folding, it **folds**: a triangulated paper field, filled with the frames of your latest work, light travelling slowly across the facets — the whole plate is the way in, with its caption struck along the bottom like a catalogue print.

Typography pairs **Fraunces** (serif, the catalogue voice) with **Inter** (the annotation-on-the-back-of-a-print voice), both bundled and registered at runtime. Selection is marked by inversion — an ink block — never by colour. The mark is an “F” crossed by a single marine crease: a folded sheet catching the light.

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
