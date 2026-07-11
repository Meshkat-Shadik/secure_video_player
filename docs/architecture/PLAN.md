# Architecture Documentation Plan — secure_video_player

Goal: layered technical-theory documentation for every subsystem — three depth tiers per doc:
1. **Tier 1 — "Explain to a kid"**: analogy-driven, zero jargon (grade 2/3 readable).
2. **Tier 2 — Engineer**: precise mechanics, data flow, API contracts, code references (`file:line`).
3. **Tier 3 — PhD deep-dive**: theory (AES-CTR mathematics, media container theory, streaming pipelines, IPC serialization, texture rendering), formal properties, threat model, complexity analysis.

Every doc ends with **Limitations (today)** and **Performance: how to make it insane** (concrete, measurable optimizations with expected impact).

Every subsystem gets a `.drawio` diagram (native mxGraphModel XML — no CLI available, so XML authored directly). Diagrams must be 100% faithful to code: node names = real class/method names, edges = real call/data paths.

## Output layout

```
docs/architecture/
  00-system-overview.md        + diagrams/00-system-overview.drawio
  01-dart-api-layer.md         + diagrams/01-dart-api-layer.drawio
  02-widgets-ui.md             + diagrams/02-widgets-ui.drawio
  03-crypto-svp-protocol.md    + diagrams/03-crypto-pipeline.drawio
  04-android-platform.md       + diagrams/04-android-platform.drawio
  05-ios-platform.md           + diagrams/05-ios-platform.drawio
  06-pigeon-bridge.md          + diagrams/06-pigeon-bridge.drawio
  07-limitations-and-performance.md + diagrams/07-perf-roadmap.drawio
```

## Source inventory (ground truth — read before writing)

| Area | Files |
|------|-------|
| Dart API | `lib/secure_video_player.dart`, `lib/src/controller.dart`, `lib/src/player_options.dart`, `lib/src/errors.dart`, `lib/src/protocol.dart` |
| Crypto (Dart) | `lib/src/crypto_scheme.dart`, `lib/src/encryptor.dart` |
| Widgets | `lib/src/widgets/player_view.dart`, `lib/src/widgets/controls.dart` |
| Pigeon | `pigeons/messages.dart`, `lib/src/messages.g.dart`, `Messages.g.kt`, `Messages.g.swift` |
| Android | `SecureVideoPlayerPlugin.kt`, `PlayerInstance.kt`, `CipherDataSource.kt`, `CipherAdapter.kt`, `FileCryptor.kt`, `SvpProtocol.kt`, `MediaInfoProbe.kt` |
| iOS | `SecureVideoPlayerPlugin.swift`, `PlayerInstance.swift`, `CipherResourceLoaderDelegate.swift`, `CipherAdapter.swift`, `FileCryptor.swift`, `SvpProtocol.swift`, `MediaInfoProbe.swift` |
| Tests | `test/controller_test.dart`, `test/player_view_test.dart` |

## Work packages (parallel Opus 4.8 subagents)

- **WP-A**: 01 + 02 (Dart API layer, widgets/UI)
- **WP-B**: 03 (crypto + SVP protocol, both platforms' cipher code)
- **WP-C**: 04 + 05 (Android Media3/ExoPlayer platform, iOS AVPlayer platform)
- **WP-D**: 00 + 06 + 07 (system overview, pigeon bridge, cross-cutting limitations & performance roadmap)

## Accuracy rules (binding on all agents)

1. Read every listed source file fully before writing. No invented behavior — every claim traceable to a `file:line`.
2. Diagram node labels use real identifiers from code (`SecureVideoController`, `CipherDataSource`, `AVAssetResourceLoaderDelegate`…).
3. `.drawio` XML rules: root cells `id="0"` and `id="1"`; all cells `parent="1"`; every edge has child `<mxGeometry relative="1" as="geometry"/>`; NO XML comments; escape `&amp; &lt; &gt; &quot;`; unique ids; explicit x/y/width/height geometry, generous spacing (no overlaps).
4. Tier 1 must be genuinely simple (locked-box/secret-key analogies); Tier 3 must be genuinely deep (CTR-mode keystream math, seek-offset→counter derivation, byte-range vs full-file IO, ExoPlayer LoadControl theory, AVAssetResourceLoader contract, platform-texture vs platform-view rendering tradeoffs).
5. Limitations must be real ones found in code (e.g. current cipher scheme properties, buffering config, main-thread hops, texture copies), not generic filler.
