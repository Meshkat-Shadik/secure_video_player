# Architecture Documentation

Layered technical docs for `secure_video_player` — encrypted-at-rest video
playback for Flutter with on-the-fly native decryption. Every doc is written in
three depth tiers (kid-level analogy → engineer → PhD deep-dive) and ends with
**Limitations (today)** and **Performance: how to make it insane**. Each has a
faithful `.drawio` diagram whose node labels are real class/method names.

Start with **[00 — System Overview](00-system-overview.md)**; it traces one video
frame end to end and links every subsystem below.

| # | Doc | What it covers |
|---|-----|----------------|
| 00 | [System Overview](00-system-overview.md) | The whole system, the layer stack, and the journey of one frame from encrypted disk bytes to on-screen pixels. Read first. |
| 01 | [Dart API Layer](01-dart-api-layer.md) | `SecureVideoController`, `SecureVideoValue` state machine, event decoding, `CryptoScheme`, `PlayerOptions`, typed errors. |
| 02 | [Widgets & UI](02-widgets-ui.md) | `SecureVideoPlayer`, texture vs platform-view rendering, controls, fullscreen, rotation, gesture HUD. |
| 03 | [Crypto & SVP Protocol](03-crypto-svp-protocol.md) | AES-CTR keystream math, position-addressable transforms, `CipherAdapter` contract, the encrypt/decrypt file pipeline, ClearKey. |
| 04 | [Android Platform](04-android-platform.md) | Media3/ExoPlayer, `CipherDataSource`, `LoadControl` buffering, tracks, PiP, `MediaSession`. |
| 05 | [iOS Platform](05-ios-platform.md) | AVPlayer, `AVAssetResourceLoaderDelegate`, `AVPlayerItemVideoOutput`, texture output, PiP, feature gaps. |
| 06 | [Pigeon Bridge](06-pigeon-bridge.md) | The control-plane RPC: schema → generated Dart/Kotlin/Swift, codec/serialization, threading, error propagation, why Pigeon over `MethodChannel`. |
| 07 | [Limitations & Performance](07-limitations-and-performance.md) | Cross-cutting honest limitation inventory + prioritized performance roadmap (mechanism / gain / effort / risk), up to the "insane" tier. |

Diagrams live in [`diagrams/`](diagrams/) as native draw.io (`mxGraphModel`) XML;
open them at [app.diagrams.net](https://app.diagrams.net).

Planning notes and accuracy rules: [`PLAN.md`](PLAN.md).
