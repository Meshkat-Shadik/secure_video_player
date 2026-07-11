# 02 — Widgets / UI Layer

The Flutter widget tree that renders a `SecureVideoController`: the
`SecureVideoPlayer` host widget, its texture-vs-platform-view rendering paths, the
`SecureVideoControls` overlay, the fullscreen route, gesture handling, and the
rebuild/repaint behavior that ties it all back to the controller.

Scope: `lib/src/widgets/player_view.dart`, `lib/src/widgets/controls.dart`.
Behavioral evidence: `test/player_view_test.dart`.

---

## Tier 1 — Explain to a kid

Think of a picture frame on the wall with a see-through sheet of glass in front.

Behind the glass is the **moving picture** — that comes straight from the TV
(doc 01's remote-controlled TV). The widget layer is the **frame** that holds the
picture the right way up and the right size. If the video was filmed sideways on a
phone, the frame quietly turns it upright so you never see it tilted.

On the **glass** in front, someone draws buttons: a big play button, a slider you
can drag, little icons for sound and full-screen. That drawing is
`SecureVideoControls`. Tap the glass once and the buttons appear; wait a few
seconds and they politely fade away so they don't cover the movie. Tap the far
right of the glass twice to jump ahead, the far left to jump back.

The **full-screen button** is special. Press it and the picture jumps out of its
little frame to fill the whole wall, and the room's lights (your phone's rotation)
turn sideways to match. Press it again and everything goes back exactly how it
was — and it even remembers if your app was only ever supposed to stand upright,
so it doesn't leave your phone stuck sideways.

There are two kinds of frame. The usual one (**texture**) lets Flutter draw its
own buttons on the glass. The other one (**platform view**) is when the phone's
own built-in movie player comes with its *own* buttons already attached, so
Flutter doesn't draw any.

---

## Tier 2 — Engineer

### Widget tree overview

```
SecureVideoPlayer (StatefulWidget)           player_view.dart:47
└─ _SecureVideoPlayerState                    player_view.dart:91
   ├─ owns PlayerUiState _ui                  player_view.dart:92
   ├─ owns ValueNotifier<controller> _controller  player_view.dart:98
   └─ build → _PlayerSurface (inline)         player_view.dart:164-176
              _PlayerSurface (StatelessWidget) player_view.dart:180
              └─ ValueListenableBuilder<SecureVideoValue>  player_view.dart:203
                 ├─ error   → _ErrorView                    player_view.dart:206
                 ├─ !init   → black + CircularProgressIndicator  player_view.dart:209
                 └─ ready   → ListenableBuilder(_ui)         player_view.dart:216
                              └─ ColoredBox › Stack
                                 ├─ video: _texture | _platformView  player_view.dart:219-224
                                 ├─ buffering spinner (if buffering)  player_view.dart:232
                                 └─ SecureVideoControls (texture + !pip + showControls)  player_view.dart:237-248
```

Fullscreen replaces the inline `_PlayerSurface` with a second one inside a pushed
route (`player_view.dart:129-156`) — same widget, `isFullscreen: true`.

### `PlayerUiState` — presentation state, separate from playback

`PlayerUiState extends ChangeNotifier` (`player_view.dart:13-42`) holds *pure
presentation* state that must survive across the inline↔fullscreen boundary:
- `_fit` (BoxFit), cycled `contain → cover → fill` by `cycleFit()`
  (`player_view.dart:16,33-36`); `fitLabel` maps to "Fit"/"Crop"/"Stretch"
  (`player_view.dart:27-31`).
- `_extraQuarterTurns` — the user's manual rotation, cycled 0–3 by `rotate()`
  (`player_view.dart:38-41`).

The class comment (`player_view.dart:10-12`) states the design rule: playback
state lives in `SecureVideoController`; this object is presentation only. The
inline and fullscreen surfaces share the *same* `_ui` instance
(`player_view.dart:143,193`), so a fit/rotate change made in one is visible in the
other.

### The controller-swap indirection (playlist support)

`_SecureVideoPlayerState` wraps the controller in
`_controller = ValueNotifier(widget.controller)` (`player_view.dart:98`) and
updates it in `didUpdateWidget` (`player_view.dart:101-104`). The comment
(`player_view.dart:94-98`) explains why: the fullscreen route is a *separate
element tree* that never rebuilds when this widget does, so when a playlist
`onNext`/`onPrevious` swaps `widget.controller` (and disposes the old one), the
fullscreen route must observe the change through this `ValueNotifier` — otherwise
fullscreen keeps rendering a disposed player (black frame). Inside the fullscreen
route, `ValueListenableBuilder<SecureVideoController>` (`player_view.dart:137-139`)
rebuilds the surface against the current controller. The inline build path reads
`widget.controller` directly (`player_view.dart:166`) since it *does* rebuild
normally. This is verified by `test/player_view_test.dart:63-76` ("swapping
controllers re-targets the rendered texture").

### Rendering: texture vs platform view — what the code actually does

`_PlayerSurface.build` (`player_view.dart:202-256`) gates on
`controller.renderMode` (`player_view.dart:220`):

**Texture path** (`_texture`, `player_view.dart:261-285`) — the default:
- Reads display size from `value.size`, defaulting to 16×9 if zero
  (`player_view.dart:262-263`).
- Wraps `Texture(textureId: controller.textureId!)` (`player_view.dart:266`).
- Applies `rotationCorrection` (`player_view.dart:264,267-280`): when non-zero,
  wraps the texture in a `RotatedBox(quarterTurns: correction ~/ 90)` around a
  `SizedBox` sized to the **raw (stored) dimensions** — swapping width/height for
  90/270 so the rotated result lands at display size. When zero, a plain
  display-sized `SizedBox`. This is the exact fix the tests pin down
  (`test/player_view_test.dart:38-61`): rotated → raw-sized SizedBox inside a
  RotatedBox; unrotated → display-sized, no RotatedBox.
- Then applies the user's `_extraQuarterTurns` as an outer `RotatedBox`
  (`player_view.dart:281-283`).
- Finally `FittedBox(fit: ui.fit, clipBehavior: Clip.hardEdge)`
  (`player_view.dart:284`) scales to the available box per the fit mode.

**Platform-view path** (`_platformView`, `player_view.dart:287-306`):
- View type is `SvpChannels.platformViewType`
  (`secure_video_player/platform_view`), creation params `{'playerId': id}`
  (`player_view.dart:288-289`).
- Android → `AndroidView`, iOS → `UiKitView`, both with
  `StandardMessageCodec` (`player_view.dart:290-302`); anything else →
  `_ErrorView` (`player_view.dart:303-304`).
- Native controls travel with the native view, so the Flutter controls overlay is
  *suppressed* in platform-view mode (the `renderMode == texture` guard at
  `player_view.dart:239`, and the class doc's advice to set `showControls: false`,
  `player_view.dart:45-46`).

### Controls widget structure and state

`SecureVideoControls extends StatefulWidget` (`controls.dart:12`). Its state
(`controls.dart:49-64`):
- `_visible` + `_hideTimer` — auto-hide (`autoHide` default 3s,
  `controls.dart:50-51,80-90`). Timer only hides while `isPlaying`
  (`controls.dart:83`).
- `_dragValue` — the in-flight scrub position while dragging the slider
  (`controls.dart:52`).
- HUD feedback: `_hudIcon/_hudText/_hudFraction/_hudTimer` — the transient
  center overlay for seek/brightness/volume, auto-clears after 700ms
  (`controls.dart:54-58,99-109`).
- Vertical-swipe bookkeeping: `_dragIsBrightness/_dragStartValue/_dragAccum`
  (`controls.dart:60-63`).

`build` (`controls.dart:167-208`) wraps everything in a transparent `Material`
(needed because the controls render over a raw `Texture` with no Material
ancestor in fullscreen/PiP routes — `controls.dart:168-172`), then a
`LayoutBuilder` to get the box size, then a `GestureDetector`
(`behavior: HitTestBehavior.opaque`) whose child is a `Stack` of the fading
overlay (`AnimatedOpacity` + `IgnorePointer`, `controls.dart:190-200`) and the
transient HUD (`controls.dart:201`). The overlay content is built by
`_buildOverlay` inside a `ValueListenableBuilder<SecureVideoValue>`
(`controls.dart:195-198`), so only the overlay subtree rebuilds on playback events.

`_buildOverlay` (`controls.dart:245-379`) is a three-row `Column` over a gradient
scrim:
- **Top row** (`controls.dart:266-296`): speed menu (`_speedButton`,
  `controls.dart:391-404`), fit button (if `ui != null`), rotate button (if
  `ui != null && isFullscreen`, `controls.dart:280-288`), PiP button, tracks
  button (`_tracksButton`, `controls.dart:406-423`).
- **Center row** (`controls.dart:297-331`): previous (if `onPrevious`), a big
  play/pause/replay button whose icon depends on `state == completed` /
  `isPlaying` (`controls.dart:305-325`), next (if `onNext`). Completed → seek to
  zero then play (`controls.dart:315-317`).
- **Bottom row** (`controls.dart:332-375`): elapsed time, a `Slider` with
  `secondaryTrackValue` = buffered (`controls.dart:340-357`), total time, a
  mute toggle (`controls.dart:362-365`), and the fullscreen toggle (if
  `onToggleFullscreen != null`, `controls.dart:366-372`).

The **track sheet** (`_TrackSheet`, `controls.dart:426-496`) is a modal bottom
sheet built from three `getTracks` calls (audio/subtitle/video,
`controls.dart:411-413`) with Quality/Audio/Subtitles sections; "Auto"/"Off"
rows call `selectTrack(type, null)` (`controls.dart:477-480`).

### Fullscreen flow, including `restoreOrientationsAfterFullscreen`

`_enterFullscreen` (`player_view.dart:113-161`):
1. Compute display aspect from `controller.value.aspectRatio`, inverting it if
   `extraQuarterTurns` is odd (`player_view.dart:116-117`).
2. Choose orientations: `widget.fullscreenOrientations` if given, else portrait
   when `aspect < 1`, else the two landscape orientations
   (`player_view.dart:118-124`).
3. `SystemChrome.setEnabledSystemUIMode(immersiveSticky)` +
   `setPreferredOrientations(orientations)` (`player_view.dart:125-126`).
4. Push a `PageRouteBuilder` (opaque, 200ms fade) whose page is a black
   `Scaffold` wrapping the `ValueListenableBuilder<controller>` → `_PlayerSurface`
   with `isFullscreen: true` and `onToggleFullscreen` = pop
   (`player_view.dart:129-156`).
5. **After the route pops** (`player_view.dart:158-160`): restore
   `SystemUiMode.edgeToEdge` and call `setPreferredOrientations(
   widget.restoreOrientationsAfterFullscreen ?? DeviceOrientation.values)`.

The `restoreOrientationsAfterFullscreen` parameter (`player_view.dart:74-78`)
exists because the default restore (`DeviceOrientation.values` — all
orientations) would *override* an app-level orientation lock on exit. An app
locked to portrait must pass `[DeviceOrientation.portraitUp]` here or it becomes
rotatable after the user leaves fullscreen once. Default is null (all
orientations) to stay non-breaking (`player_view.dart:77`).

### Gesture handling

All gestures live on the `GestureDetector` in `SecureVideoControls.build`
(`controls.dart:177-186`):
- **Single tap** → `_toggleVisible` (`controls.dart:87-90,179`).
- **Double-tap down** → `_onDoubleTapDown` (`controls.dart:113-130,180`): divides
  the box in thirds; left third seeks back `doubleTapSeek`, right third seeks
  forward (both clamped to `[0, duration]`), middle toggles visibility. Shows a
  rewind/forward HUD.
- **Vertical drag** (only when `isFullscreen`, `controls.dart:181-186`):
  `_onVerticalDragStart` decides brightness (left half) vs volume (right half)
  from the touch x (`controls.dart:134-143`); `_onVerticalDragUpdate` accumulates
  `-delta.dy / box.height` and applies it to `setScreenBrightness` or
  `setVolume`, with a HUD fraction bar (`controls.dart:145-165`). Brightness
  seeds from `getScreenBrightness()`, defaulting to 0.5 when the system reports -1
  (`controls.dart:138-139`).

The slider is its own gesture surface: `onChangeStart` cancels the hide timer,
`onChanged` sets `_dragValue` locally (scrubbing preview), `onChangeEnd` clears
it, seeks, and reschedules hide (`controls.dart:350-356`).

### Rebuild / repaint behavior

The layer is built around *scoped* rebuilds:
- `_PlayerSurface` rebuilds on **every** `SecureVideoValue` change via the outer
  `ValueListenableBuilder` (`player_view.dart:203`), and additionally on `_ui`
  changes via the inner `ListenableBuilder` (`player_view.dart:216`). The
  branch order matters: error/uninitialized short-circuit *before* the `_ui`
  listener is even attached (`player_view.dart:206-214`).
- The controls overlay isolates its playback-driven rebuilds to `_buildOverlay`
  through its own `ValueListenableBuilder` (`controls.dart:195-198`) so the
  gesture `Stack`/`Material` scaffold above it is built once per visibility/HUD
  `setState`, not per position event.
- `Texture` is a leaf that composites the native surface directly on the GPU;
  Flutter does not repaint video pixels — only the layout wrappers
  (`SizedBox`/`RotatedBox`/`FittedBox`) participate in the widget/layout tree.

---

## Tier 3 — PhD deep-dive

### Why raw-sized-child-inside-RotatedBox is the correct rotation model

The native side reports **display** dimensions (Media3 already swaps w/h for
90/270 rotations) *plus* a `rotationCorrection` for the raw decoder frames, which
land un-rotated on an `ImageReader`/`AVPlayerItemVideoOutput` surface
(`player_view.dart:258-260`, `test/player_view_test.dart:28-32`). A naive
"rotate the display-sized box" is wrong: `RotatedBox` performs a *layout-time*
rotation — it lays out its child, then swaps the child's width/height to compute
its own size. So to end at a display-sized box after a 90° turn, the child must be
laid out at **raw** (pre-swap) dimensions. Concretely for a portrait phone clip
(display 1920×1080, stored 1080×1920, correction 90): the code makes a
1080×1920 `SizedBox` (raw), wraps it in `RotatedBox(quarterTurns:1)`, and the
RotatedBox reports 1920×1080 (display) with upright content
(`player_view.dart:267-280`, asserted at `test/player_view_test.dart:44-49`). The
test-file header notes this bug "shipped twice" (`test/player_view_test.dart:28`)
— it is subtle precisely because display-vs-raw dimension confusion produces
correct *aspect* but wrong *size*, invisible until composited against a real box.

The transform stack is therefore ordered: raw-`SizedBox` → correction-`RotatedBox`
(→ display size) → user-`RotatedBox` (`extraQuarterTurns`) → `FittedBox` (scale to
container). Composition order matters — user rotation is applied *outside* the
correction so the two compose as group elements of ℤ/4 (quarter-turn rotations),
and the FittedBox scaling is last so it always operates on already-upright content.

### Texture composition vs platform views — the rendering tradeoff

The texture path uses Flutter's external-texture mechanism: the native decoder
writes frames into a `SurfaceTexture`/`CVPixelBuffer` registered with the Flutter
engine under `textureId`, and `Texture` inserts a `TextureLayer` into the layer
tree. The GPU composites that layer with the rest of the Flutter scene in a single
pass — no pixel copy into Dart, and the video is a first-class citizen of the
widget tree (it can be transformed, clipped, stacked, animated). This is why
controls, spinners, and HUDs can be drawn *over* video with correct z-order and
why multiple players compose freely (`player_options.dart:25-26`).

Platform views (`AndroidView`/`UiKitView`) instead embed a native OS view into the
Flutter hierarchy. On Android this historically means either a virtual display or
hybrid composition (texture-copy or view-hierarchy interleaving) with real
overhead and gesture-arena complications; the payoff is the platform's *own*
player UI and native features that don't route through a texture. The code's
choice — suppress Flutter controls in platform-view mode
(`player_view.dart:237-239`), keep them in texture mode — reflects exactly this
gesture-ownership boundary: in a platform view the native side owns touch, so
overlaying a Flutter `GestureDetector` would fight the arena.

### The controller-swap ValueNotifier: element-tree topology

The fullscreen route is pushed onto the root `Navigator`
(`player_view.dart:129`), creating an element subtree that is a *sibling* of the
inline widget's subtree, not a descendant. Flutter rebuilds propagate down a
single element tree; a `setState`/`didUpdateWidget` on `_SecureVideoPlayerState`
cannot reach the route's builder. The `ValueNotifier<SecureVideoController>`
(`player_view.dart:98`) bridges the two subtrees as an explicit observable: it is
updated in `didUpdateWidget` (`player_view.dart:103`) and listened to inside the
route (`player_view.dart:137`). This is the canonical Flutter pattern for pushing
parent state into a pushed route without `InheritedWidget` — and it is *necessary*
here because the old controller is disposed on swap, so a stale reference in the
route would render a dead texture (the black-frame failure the comment cites,
`player_view.dart:94-97`).

### Auto-hide and HUD timers as soft state

`_visible` and the HUD are pure local `setState` state guarded by `mounted`
checks in every timer callback (`controls.dart:83,107`). The auto-hide timer is
conditioned on `isPlaying` (`controls.dart:83`) so controls never vanish over a
paused frame — a deliberate UX invariant. Note that `_hideTimer` is cancelled at
several interaction points (slider drag start `controls.dart:350`, tracks open
`controls.dart:410`) and rescheduled on completion, forming a debounce: any
interaction resets the 3s countdown. This is a hand-rolled debounce rather than a
reactive stream, chosen because the trigger set is heterogeneous (tap, drag,
menu) and cheap to wire directly.

### Complexity / cost model

- Video repaint: **O(0)** Dart work — GPU composites the `TextureLayer`.
- Playback-event rebuild: O(size of `_buildOverlay` subtree) per event, isolated
  by the inner `ValueListenableBuilder` (`controls.dart:195`); the outer
  gesture/Material scaffold is untouched.
- `_PlayerSurface` rebuild: O(subtree) on every value change *and* every `_ui`
  change, since both listenables wrap the whole surface
  (`player_view.dart:203,216`). Fit/rotate changes are rare, so this is
  acceptable, but position events do rebuild the whole surface tree (see
  Limitation #2).
- Track sheet open: 3 sequential `getTracks` round-trips (`controls.dart:411-413`)
  before the sheet shows — O(3 IPC) latency.

---

## Limitations (today)

1. **Platform-view mode has zero Flutter fullscreen/gesture support.** Fullscreen,
   double-tap seek, and edge-swipe brightness/volume all live in
   `SecureVideoControls`, which is only mounted in texture mode
   (`player_view.dart:237-239`). Platform-view users get whatever the native
   player offers and nothing from this package's UI.

2. **The whole `_PlayerSurface` rebuilds on every position event.** The outer
   `ValueListenableBuilder` (`player_view.dart:203`) wraps the video *and*
   controls, so a 4 Hz position update re-runs `_PlayerSurface.build` including
   the `renderMode` branch and `_texture` layout wrappers — not just the seek bar.
   The controls' inner listener limits *its* damage, but the surface itself isn't
   as scoped.

3. **Track sheet fetches tracks serially and shows nothing until all three
   return** (`controls.dart:411-414`). Three awaited round-trips add latency; a
   slow platform stalls the settings menu with no spinner.

4. **Brightness restore on fullscreen exit is not handled.** `_enterFullscreen`
   restores orientation and UI mode (`player_view.dart:158-160`) but does not
   reset screen brightness changed via the edge-swipe gesture — if the user dimmed
   the screen in fullscreen, it stays dimmed after exit (the controller doc notes
   `setScreenBrightness(-1)` restores default, but nothing calls it here).

5. **`extraQuarterTurns` rotate button only appears in fullscreen**
   (`controls.dart:280`) — inline rotation isn't reachable through the UI even
   though `PlayerUiState.rotate()` and the outer `RotatedBox`
   (`player_view.dart:281-283`) would honor it inline.

6. **Slider max is clamped to `1` when duration is 0** (`controls.dart:344`) and
   the play button's completed→replay logic assumes a valid duration; live streams
   or unknown-duration sources get a degenerate seek bar.

---

## Performance: how to make it insane

1. **Split the surface listener from the video layout.** Move the
   `ValueListenableBuilder` down so `_texture`/`_platformView` is built from a
   `Selector`-style listener on `(size, rotationCorrection, state)` only, and let
   position events reach *only* the controls. This stops re-running the rotation
   math and `FittedBox` layout at 4 Hz (Limitation #2). Expected impact: video
   subtree rebuilds drop from ~4/s to only on genuine size/rotation changes.

2. **Parallelize the track sheet fetch.** Replace the three sequential awaits
   (`controls.dart:411-413`) with `Future.wait([...])` and show the sheet with a
   spinner immediately. Cuts settings-open latency from 3×RTT to 1×RTT.

3. **Wrap the video subtree in a `RepaintBoundary`.** The `Texture` composites on
   the GPU, but the surrounding scrim/HUD `AnimatedOpacity` invalidates a shared
   layer; isolating the video with a `RepaintBoundary` guarantees control-fade
   animations never re-raster the video region. Expected impact: control
   animations stay on the compositor thread, no video-region repaint.

4. **Debounce/interpolate the seek bar off a client clock** (mirrors doc 01's
   perf item): drive the `Slider` position from an interpolated clock rather than
   raw `position` events, so it advances smoothly at 60 Hz without more IPC and
   without rebuilding on every event.

5. **Cache `getTracks` results on the controller** and invalidate on
   `videoSize`/track-change events, so reopening the settings sheet is instant
   instead of re-round-tripping (`controls.dart:406-423`).

6. **Hoist the transparent `Material` once** at the surface level instead of
   inside `SecureVideoControls.build` (`controls.dart:172`) so it isn't part of
   the per-visibility rebuild path — micro win, but removes a wrapper from the hot
   rebuild subtree.
