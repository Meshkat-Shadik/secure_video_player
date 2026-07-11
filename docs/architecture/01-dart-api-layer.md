# 01 — Dart API Layer

The public Dart surface of `secure_video_player`: the controller that owns one
native player, the immutable value/state model it publishes, the event stream it
listens on, the error taxonomy it raises, and how it serializes calls onto the
pigeon host API.

Scope: `lib/secure_video_player.dart`, `lib/src/controller.dart`,
`lib/src/player_options.dart`, `lib/src/crypto_scheme.dart`,
`lib/src/errors.dart`, `lib/src/protocol.dart`, plus how the controller drives
`lib/src/messages.g.dart`. Behavioral evidence: `test/controller_test.dart`.

---

## Tier 1 — Explain to a kid

Imagine a TV with a remote control.

The **remote** is `SecureVideoController`. You press its buttons — play, pause,
jump forward — and the actual TV somewhere else does the work.

The TV can't just play any tape. Some tapes are **scrambled on purpose** so a
thief who steals the tape sees garbage. The remote hands the TV a **secret
recipe** (the `CryptoScheme`) that says how to un-scramble it while it plays. The
tape is never un-scrambled onto the floor where someone could grab it — only tiny
pieces, right as the TV shows them.

When you first turn the TV on, it takes a moment to warm up. The remote **waits**
until the TV says "I'm ready, the picture is on" before it lets you do anything
else.

The TV is chatty: about four times a second it shouts back "I'm at 12 seconds
now!" or "I finished!" The remote keeps a little **sticky note** of the latest
news (`SecureVideoValue`) and everyone who cares reads that note instead of
bothering the TV.

If something breaks — wrong recipe, missing tape — the TV doesn't crash the whole
house. It says exactly what went wrong ("wrong key", "file not found") and the
remote passes that message to you politely.

One important safety rule: if you **throw the remote away** while the TV is still
warming up, the TV would otherwise keep running forever in an empty room. So the
remote remembers "I was thrown away" and, the instant the TV finishes warming up,
tells it to switch off.

---

## Tier 2 — Engineer

### Public API surface

Everything the package exports is listed in
`lib/secure_video_player.dart:7-24`. The Dart API layer's slice of that:

| Export | Kind | Source |
|--------|------|--------|
| `SecureVideoController` | controller class | `controller.dart:118` |
| `SecureVideoState` | enum (5 states) | `controller.dart:12` |
| `SecureVideoValue` | immutable snapshot | `controller.dart:46` |
| `VideoTrack` | selectable track DTO | `controller.dart:15` |
| `getMediaInfo` | top-level probe fn | `controller.dart:386` |
| `getScreenBrightness` / `setScreenBrightness` | top-level fns | `controller.dart:376-381` |
| `setScreenCaptureProtection` | top-level fn | `controller.dart:369` |
| `CryptoScheme` (+ subclasses) | sealed scheme model | `crypto_scheme.dart:10` |
| `PlayerOptions`, `BufferConfig`, `RenderMode`, `VideoSource` | options | `player_options.dart` |
| `SecureVideoException`, `SecureVideoErrorCode` | error taxonomy | `errors.dart` |
| `SvpTrackTypes` | track-type constants | `protocol.dart:48` |
| `MediaInfo`, `MediaStreamInfo` | pigeon DTOs re-exported | `messages.g.dart` |

The controller is the only stateful object; the top-level functions
(`setScreenCaptureProtection`, `setScreenBrightness`, `getScreenBrightness`,
`getMediaInfo`) each construct a throwaway `SecureVideoHostApi()` per call
(`controller.dart:370,377,381,389`) because they are window-global or one-shot,
not tied to a player instance.

### Controller construction and identity

`SecureVideoController extends ValueNotifier<SecureVideoValue>`
(`controller.dart:118`), so it *is* a `Listenable` whose value is the current
snapshot. The constructor takes an optional `@visibleForTesting api`
(`controller.dart:119-121`), defaulting to a real `SecureVideoHostApi()`. This is
the sole dependency-injection seam — the test suite passes a `FakeHostApi`
(`test/controller_test.dart:7,99`).

Private mutable fields (`controller.dart:125-131`):
- `_playerId` / `_textureId` — native handles, null until create completes.
- `_renderMode` — cached from options (`controller.dart:127,147`).
- `_eventSub` — the per-player `EventChannel` subscription.
- `_readyCompleter` — the future `initialize()` awaits.
- `_pendingCreate` — the in-flight `create()` future (for mid-create dispose).
- `_disposed` — one-way latch.

Multiple controllers can be live simultaneously; each maps to its own native
player and its own event channel (`controller.dart:116-117`).

### Lifecycle: create → play/pause/seek → dispose

**Create** (`initialize`, `controller.dart:138-199`):

1. `_checkDisposed()` guard, then reject double-init if `_playerId != null`
   with a `StateError` (`controller.dart:143-146`).
2. Cache `_renderMode`, allocate `_readyCompleter` (`controller.dart:147-148`).
3. Build a `CreateRequest` flattening source, scheme, and options, and call
   `_api.create(...)`, storing the future in `_pendingCreate`
   (`controller.dart:152-166`). A `PlatformException` here is converted via
   `SecureVideoException.fromPlatform` and rethrown; `_pendingCreate` is cleared
   (`controller.dart:167-171`). Verified by the "surfaces typed error from
   create" test (`test/controller_test.dart:157-165`).
4. **Mid-create dispose check** (`controller.dart:173-184`): if `_disposed`
   became true while `create()` was awaited, ignore the ready future, call
   `_api.dispose(response.playerId)` to release the just-created native player,
   and throw `SecureVideoErrorCode.disposed`. This is the fix for issue #1
   (widget popped during create → orphaned decoder). Swallows a
   `PlatformException` if the native side is already gone.
5. Store `_playerId`/`_textureId`, transition value to
   `SecureVideoState.buffering` seeding `looping`/`volume`
   (`controller.dart:186-192`).
6. Subscribe to `EventChannel(SvpChannels.playerEvents(playerId))`
   broadcast stream (`controller.dart:194-196`).
7. `await _readyCompleter!.future` (`controller.dart:198`) — returns only once
   the native side emits `initialized` (which completes the completer at
   `controller.dart:213-215`) or errors.

**Commands** all route through `_call<T>` (`controller.dart:320-332`), which:
guards `_checkDisposed()`, resolves `_playerId` (throwing
`SecureVideoErrorCode.unknown` "Controller not initialized" if null), invokes the
supplied closure, and maps any `PlatformException` to `SecureVideoException`.
The command methods:

- `play` / `pause` / `seekTo` — fire-and-forward (`controller.dart:262-267`).
- `setSpeed` / `setLooping` / `setVolume` — await the call, then optimistically
  update `value` (`controller.dart:269-282`). `setVolume` clamps to `0.0–1.0`
  on both the wire call and the local value (`controller.dart:280-281`).
- `position()` — bypasses the event cache to read fresh native position, since
  events only update ~4×/s (`controller.dart:284-288`).
- `getTracks` / `selectTrack` / `addExternalSubtitle` — track management
  (`controller.dart:290-312`); `getTracks` maps pigeon `TrackInfo` → `VideoTrack`.
- `enterPictureInPicture` / `setBackgroundPlayback` (`controller.dart:314-318`).

Command forwarding + optimistic value updates are verified by
`test/controller_test.dart:181-199`.

**Dispose** (`controller.dart:342-364`), idempotent via the `_disposed` latch:
1. Set `_disposed = true`.
2. If a caller is still awaiting `initialize()`, complete the ready future with a
   `disposed` error so it doesn't hang (`controller.dart:346-350`).
3. Cancel the event subscription (`controller.dart:351`).
4. Null out `_playerId`, then `_api.dispose(id)` if it existed, swallowing a
   `PlatformException` (`controller.dart:352-360`).
5. `super.dispose()` (`controller.dart:363`).

Post-dispose method calls throw `SecureVideoErrorCode.disposed` — verified by
`test/controller_test.dart:216-228`. Note the two disposal races are handled in
*different* places: dispose-after-create-returned is cleaned up here; the
dispose-*during*-create case is handled inside `initialize` (step 4 above),
because at that moment `_playerId` is still null so `dispose()` has no id to
release (`controller.dart:352-360` vs `173-184`, cross-referenced by the comment
at `controller.dart:361-362`).

### Value / state model

`SecureVideoState` (`controller.dart:12`): `uninitialized, buffering, ready,
completed, error`.

`SecureVideoValue` (`controller.dart:46-114`) is `@immutable`, all-`final`, with
`copyWith` (`controller.dart:86-113`). Fields include playback position/buffered/
duration, display `size`, `rotationCorrection`, `isPlaying`, `speed`, `volume`,
`looping`, `isPipActive`, and an optional `error`. Derived getters:
`aspectRatio` (falls back to 16/9 when size is zero, `controller.dart:81-82`) and
`isInitialized` (`state != uninitialized`, `controller.dart:84`). Because the
controller is a `ValueNotifier`, every `value = value.copyWith(...)` assignment
notifies listeners — this is the entire reactive contract for the widgets.

`rotationCorrection` (`controller.dart:70-73`) is degrees the *raw* texture must
be rotated to appear upright; non-zero only when the platform surface can't apply
the track's rotation metadata itself. `size` is already the display size (rotation
applied). The interplay is load-bearing for the widget layer (see doc 02).

### Event stream handling

Events arrive as `Map` payloads on the per-player `EventChannel` and are decoded
in `_onEvent` (`controller.dart:201-250`), keyed by `m[SvpEvents.key]`
(the string `'event'`). Handled event names and their effect:

| Event (`protocol.dart`) | Value mutation |
|--------------------------|----------------|
| `initialized` | → `ready`, set duration/size/rotationCorrection, complete `_readyCompleter` |
| `buffering` | → `buffering` |
| `ready` | → `ready` (only if already initialized) |
| `position` | update position + buffered |
| `isPlayingChanged` | update `isPlaying` |
| `videoSize` | update size + rotationCorrection |
| `completed` | → `completed`, `isPlaying=false` |
| `pipChanged` | update `isPipActive` |
| `error` | → `error`, build exception, `completeError` on `_readyCompleter` |

Event names/keys are centralized as constants in `SvpEvents`
(`protocol.dart:12-35`) — the controller never uses raw string literals. The
`ready`-guard (`controller.dart:218-221`) prevents a stray `ready` from
resurrecting a controller still in `uninitialized`. Stream-level errors
(as opposed to `error` events) are caught by `_onEventError`
(`controller.dart:252-260`), which also fails a pending ready completer.
Event-driven value updates are verified by `test/controller_test.dart:201-214`;
error-event completion by `test/controller_test.dart:167-179`.

### Error taxonomy

`SecureVideoErrorCode` (`errors.dart:3-16`): `invalidKey, fileNotFound,
corruptStream, adapterNotRegistered, drmError, platformNotSupported, disposed,
unknown`. `fromWire` (`errors.dart:13-15`) looks up the wire string in the enum
name map and falls back to `unknown` — so an unrecognized native code degrades
gracefully rather than throwing.

`SecureVideoException` (`errors.dart:18-30`) carries `(code, message)`.
`fromPlatform` (`errors.dart:21-23`) reads `PlatformException.code` through
`fromWire` and uses `e.message ?? e.code`. Every boundary that can throw a raw
`PlatformException` — `initialize`, `_call`, `getMediaInfo` — funnels through this
constructor (`controller.dart:169,330,392`), so callers only ever see
`SecureVideoException`.

### Protocol / URI scheme (Dart side)

`SvpChannels` (`protocol.dart:3-9`) defines channel names shared with native:
- `cryptoEvents` = `secure_video_player/crypto_events`
- `platformViewType` = `secure_video_player/platform_view`
- `playerEvents(id)` = `secure_video_player/events_<id>` — the per-player event
  channel the controller subscribes to (`controller.dart:194`,
  `test/controller_test.dart:88`).

`VideoSource` (`player_options.dart:1-22`) is a tagged `(type, value)` pair with
named constructors: `.file`, `.asset`, `.url`, `.contentUri` (Android-only). The
`type` string flows straight onto the wire as `CreateRequest.sourceType`
(`controller.dart:153-154`), verified end-to-end by
`test/controller_test.dart:120-130` (`contentUri` → `create:...:contentUri`).

`CryptoScheme` (`crypto_scheme.dart:10-40`) is a `sealed` class; each variant
exposes `type` (wire id) and `params` (map for `CipherAdapter.init`). From the
Dart API layer's perspective the scheme is opaque: `initialize` copies
`scheme.type` → `schemeType` and `scheme.params` → `schemeParams`
(`controller.dart:155-156`) and never inspects them. Deep crypto semantics are
doc 03.

### Options plumbing

`PlayerOptions` (`player_options.dart:49-65`) bundles `renderMode`, `autoPlay`,
`looping`, `volume`, `startPosition`, and a `BufferConfig`
(`player_options.dart:33-47`, defaults 15s/30s/2.5s, plus a `.lowRam()` preset).
`initialize` flattens every field individually onto `CreateRequest`
(`controller.dart:152-166`) — durations are sent as `inMilliseconds`
(`controller.dart:161`), `renderMode` as `.name` (`controller.dart:158`). Pigeon
has no nested-object option type here, so the flattening is manual.

### How the controller talks to pigeon (`messages.g.dart`)

`SecureVideoHostApi` (`messages.g.dart:543`) is generated. Each method opens a
per-call `BasicMessageChannel<Object?>` named
`dev.flutter.pigeon.secure_video_player.SecureVideoHostApi.<method>` with a
shared `_PigeonCodec` (`messages.g.dart:552,556-563`), sends the args as a
positional `List`, awaits a reply `List`, and runs it through
`_extractReplyValueOrThrow` — which reconstructs a `PlatformException` from the
error slots of the reply envelope. That is exactly why the controller only needs
to catch `PlatformException` at each boundary. The controller depends on this
class purely through the injected `_api` field, so tests substitute a subclass
without any channel plumbing (`test/controller_test.dart:7-77`).

---

## Tier 3 — PhD deep-dive

### The controller as a state machine

The observable state is the product `SecureVideoState × (isPlaying, isPipActive,
error)`, but the *legal transitions* are constrained by two orthogonal machines:

1. **Lifecycle machine** (private): `null → creating → created → disposed`,
   encoded implicitly by `(_playerId, _pendingCreate, _disposed)`. The reachable
   tuples are a small subset of 2³: `_pendingCreate != null` implies
   `_playerId == null`; `_disposed` is absorbing.

2. **Playback machine** (public `SecureVideoState`): `uninitialized →
   buffering → ready ⇄ buffering → completed`, with `error` reachable from any
   node and terminal in practice. Transitions are driven *only* by native events
   (`_onEvent`), never by command methods — commands mutate the scalar sub-fields
   (`speed`, `volume`, `looping`) but not `state`. This separation means the Dart
   side never optimistically predicts buffering/ready; it treats the native
   player as the source of truth for playback state and as a slave for scalar
   settings. The lone exception is `completed` also forcing `isPlaying=false`
   (`controller.dart:236-238`), a defensive coupling since some platforms emit
   `completed` without an accompanying `isPlayingChanged`.

### Concurrency and the mid-create dispose race

The interesting formal property is *no orphaned native player under
concurrent dispose*. Dart is single-threaded (one isolate event loop), so races
are limited to interleavings at `await` suspension points. `initialize` has a
suspension at `await _pendingCreate!` (`controller.dart:166`). `dispose()` can run
during that suspension. Two cases:

- **`_playerId` already set** is impossible here (it is assigned only after the
  await, `controller.dart:186`), so `dispose()`'s own `_api.dispose(id)` path
  (`controller.dart:354-360`) is a no-op — it has no id.
- Therefore the *only* code path that can release the native player created by
  the in-flight `create()` is the post-await check in `initialize`
  (`controller.dart:173-184`). The design deliberately splits the release
  responsibility: whoever holds the `response.playerId` at the moment `_disposed`
  is observed true is responsible for releasing it. This is a hand-off protocol,
  and its correctness rests on Dart's run-to-completion semantics: once
  `initialize` resumes after the await, no other code interleaves until its next
  await, so the `_disposed` read and the `_api.dispose` call are atomic w.r.t.
  `dispose()`.

The completer discipline reinforces this: `dispose()` and the error path both
guard `!(_readyCompleter?.isCompleted ?? true)` before completing
(`controller.dart:346,213,246,257`), making completion idempotent — a completer
can be completed at most once, and every writer checks first.

### Event serialization and back-pressure

The event channel is a Flutter `EventChannel` broadcast stream carrying
`StandardMethodCodec`-encoded `Map`s. There is **no back-pressure**: the native
side sinks events at will (~4 position updates/s per the comment at
`controller.dart:284`), and each becomes a microtask that runs `_onEvent` and
assigns `value`, which synchronously notifies all `ValueNotifier` listeners. For
N mounted widgets listening, one position event costs O(N) rebuilds. At 4 Hz this
is negligible, but it establishes the amortized cost model: rebuild pressure
scales with event frequency × listener count, not with actual frame rate. The
`position()` escape hatch (`controller.dart:285-288`) exists precisely so a UI
needing smooth (60 Hz) scrubbing can poll instead of relying on the coarse event
cadence — trading an IPC round-trip per poll for temporal resolution.

### Type coercion at the wire boundary

`_onEvent` treats every numeric field as `num` then narrows
(`(m[...] as num).toInt()`, `controller.dart:207,224` etc.), because the standard
codec may deliver an `int` from one platform and a `double` from another for the
same logical field. Width/height default to `0` when absent
(`controller.dart:208-209`) so a partial `initialized` payload never throws. This
is defensive deserialization: the contract with native is "these keys, roughly
these types," and the Dart side normalizes rather than asserting — trading strict
validation for resilience against platform drift.

### Complexity

- `initialize`: one IPC round-trip + one event-stream setup; latency dominated by
  native decoder warm-up until `initialized`. O(1) Dart work.
- Each command: one IPC round-trip, O(1).
- `getTracks`: O(T) mapping over T tracks (`controller.dart:290-304`).
- Event dispatch: O(1) decode + O(N) listener notification per event.

---

## Limitations (today)

1. **Double-initialize throws `StateError`, not a `SecureVideoException`**
   (`controller.dart:144-145`). This is the one API-misuse path that escapes the
   uniform error taxonomy — callers wrapping everything in
   `on SecureVideoException` will miss it. A one-controller-one-player contract
   is enforced by exception rather than by returning a fresh controller.

2. **Scalar setters are optimistic and un-reconciled.** `setSpeed`/`setVolume`/
   `setLooping` write `value` immediately after the await returns
   (`controller.dart:271,276,281`). If the native player later clamps or rejects
   the value silently (no error event), the Dart snapshot diverges from reality
   until some other event overwrites that field. There is no `speedChanged`
   event to reconcile `speed`.

3. **No reconnection / re-initialize.** Once `_playerId` is set, `initialize`
   refuses to run again (`controller.dart:144`), and there is no `reset()`. A
   transient native error (`state == error`) is terminal for that controller
   instance; recovery means dispose + construct a new one.

4. **Event stream has no back-pressure and no coalescing.** Every position event
   allocates a new `SecureVideoValue` and notifies all listeners
   (`controller.dart:222-227`); there is no diffing to suppress no-op updates
   (e.g. a `ready` event when already `ready` still allocates).

5. **`position()` round-trips per call** (`controller.dart:285-288`). Smooth
   scrubbing UIs must poll, and each poll is a full pigeon round-trip — there is
   no client-side interpolation between the 4 Hz events.

6. **Global functions construct a fresh `SecureVideoHostApi` each call**
   (`controller.dart:370,377,381,389`) and are not test-injectable — unlike the
   controller, they have no `@visibleForTesting` seam, so brightness/secure-flag
   behavior can't be unit-tested through the public API.

---

## Performance: how to make it insane

1. **Coalesce/interpolate position instead of polling.** Keep the 4 Hz events but
   add a client-side clock: on each `position` event, record
   `(position, wallclock, speed, isPlaying)` and expose an interpolated getter
   `position + (now - wallclock) * speed`. Kills every `position()` round-trip and
   yields true 60 Hz scrub smoothness for **zero extra IPC**. Expected impact:
   eliminates the per-frame channel call for any app doing smooth seeking.

2. **Diff before notifying.** In `_onEvent`, skip the `value =` assignment when
   the new snapshot equals the old (add value equality). At N listeners × 4 Hz
   this removes redundant rebuilds; the win scales with the number of mounted
   `ValueListenableBuilder`s and matters most in list/grid views with many
   players. Expected impact: O(N) rebuilds → 0 on no-op events.

3. **Batch `CreateRequest` option flattening into a nested pigeon struct.** The
   current 13-field flat request (`controller.dart:152-165`) is re-typed by hand
   on both sides; moving `BufferConfig`/`PlayerOptions` to pigeon `class`es
   removes manual plumbing and shrinks the serialized envelope. Marginal runtime
   win, large maintenance win (fewer drift bugs of the kind Limitation #2
   describes).

4. **Pool controllers for list scrolling.** Because each controller is
   1:1 with a native decoder and construction is cheap but native create is not,
   a recycler-style pool (keep K warm controllers, re-`initialize` on scroll)
   avoids repeated decoder warm-up. The mid-create dispose handling
   (`controller.dart:173-184`) already makes rapid create/dispose safe, so the
   infrastructure for aggressive recycling is in place.

5. **Add a `speedChanged`/`volumeChanged` reconcile event** so optimistic setters
   (Limitation #2) converge to ground truth, letting the UI trust `value.speed`
   without a follow-up `position()`-style read.
