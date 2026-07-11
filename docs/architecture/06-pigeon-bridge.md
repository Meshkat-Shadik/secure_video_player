# 06 — The Pigeon Bridge (control plane)

Dart cannot call Kotlin or Swift directly. The **control plane** — `create`,
`play`, `seekTo`, `getTracks`, `getMediaInfo`, and every other command — crosses
that gap through **Pigeon**, Flutter's code-generator for type-safe platform
channels. One schema file (`pigeons/messages.dart`) is the single source of
truth; generated Dart, Kotlin, and Swift keep all three sides in lockstep.

The **event plane** (native → Dart position/state/error events) does *not* use
Pigeon — it uses hand-written `EventChannel`s and is covered where relevant
below and in doc 00.

Diagram: [`diagrams/06-pigeon-bridge.drawio`](diagrams/06-pigeon-bridge.drawio)

---

## Tier 1 — Explain it to a kid

Two friends speak different languages. Dawn speaks Dart; Nate speaks Native.
They can't understand each other, so they hire a **translator who follows one
rulebook**.

The rulebook is written once (`pigeons/messages.dart`). From it, the translator
prints three matching phrasebooks — one for Dawn, one for Nate on an Android
phone, one for Nate on an iPhone. Because all three come from the **same
rulebook**, Dawn can say "make me a player" and Nate hears *exactly* that, with
all the details in the right order, every time.

When Dawn asks a question, she writes it on a card, drops it through a slot, and
waits. Nate reads the card, does the work, and drops an answer card back. If
something went wrong, Nate writes "ERROR" and why — and Dawn's card *pops back as
a complaint she can catch* instead of a mystery.

Announcements ("we're 5 minutes in!") work differently: Nate has a **loudspeaker**
(the event channel) that Dawn tunes into. He can even record announcements before
she tunes in, so she never misses the important first one.

---

## Tier 2 — Engineer's view

### The schema is the contract

`pigeons/messages.dart` declares:

- **Data classes** that cross the wire: `CreateRequest`, `CreateResponse`,
  `TrackInfo`, `MediaStreamInfo`, `MediaInfo` (`pigeons/messages.dart:11`–`126`).
- **One `@HostApi()`**, `SecureVideoHostApi` (`pigeons/messages.dart:128`), whose
  20 methods are the entire Dart → native command set.

The `@ConfigurePigeon` block (`pigeons/messages.dart:3`) pins the three output
paths and the Kotlin package. Regenerate after any edit:

```
dart run pigeon --input pigeons/messages.dart
```

This writes `lib/src/messages.g.dart`,
`android/.../Messages.g.kt`, and `ios/Classes/Messages.g.swift`. **Never
hand-edit the `.g` files** — they are overwritten.

Note there is **no `@FlutterApi`**. Pigeon can generate a native → Dart callback
API, but this package deliberately sends events over classic `EventChannel`s
instead (see "Why not Pigeon for events" below). So the bridge is one-directional
for Pigeon: Dart calls in, results come back on the same call.

### What types cross, and how

Pigeon's codec is `StandardMessageCodec` extended with custom type tags. Every
message is a value list. Primitives use the standard Flutter codec tags (e.g.
`int` → tag `4`, an `Int64`, `messages.g.dart:501`); the five schema data classes
get sequential custom tags **129–133** and are serialized as their `encode()`
field list (`messages.g.dart:497`–`540`):

| Tag | Type |
|-----|------|
| 129 | `CreateRequest` |
| 130 | `CreateResponse` |
| 131 | `TrackInfo` |
| 132 | `MediaStreamInfo` |
| 133 | `MediaInfo` |

The exact same tag table is emitted in `Messages.g.kt`
(`MessagesPigeonCodec`, `Messages.g.kt:524`) and `Messages.g.swift`
(`MessagesPigeonCodec`, `Messages.g.swift:587`), so the three sides agree
byte-for-byte.

Important consequence for crypto params: `schemeParams` is a
`Map<String?, Object?>` (`pigeons/messages.dart:33`). Dart `Uint8List` (the
AES key/nonce) survives as typed data — on iOS it arrives as
`FlutterStandardTypedData` and must be unwrapped as such, which is exactly what
`AesCtrAdapter.initialize` does (`CipherAdapter.swift:105`). Only
channel-serializable values may go in `params` (`README.md:178`).

### Channel naming

Each host method gets its own `BasicMessageChannel`, named
`dev.flutter.pigeon.secure_video_player.SecureVideoHostApi.<method>`
(`messages.g.dart:557` for `create`; the same names appear in the native
`setUp`). The Dart client (`SecureVideoHostApi`, `messages.g.dart:543`) builds a
channel per call and `send`s a one-element (or few-element) argument list.

### Host-API vs Flutter-API direction

| Direction | Mechanism | Example |
|-----------|-----------|---------|
| Dart → native (request/response) | Pigeon `@HostApi` | `create`, `play`, `seekTo`, `getTracks`, `getMediaInfo`, `startCrypto` |
| Native → Dart (events, streamed) | `EventChannel` (not Pigeon) | per-player `secure_video_player/events_<id>` (registered `SecureVideoPlayerPlugin.kt:160`–`169`, `SecureVideoPlayerPlugin.swift:111`–`115`); crypto `secure_video_player/crypto_events` |
| Native → Dart (pixels) | GPU texture / platform view | not a channel at all — only a `textureId` is returned by `create` |

### Wiring on the native side

- **Android**: `SecureVideoPlayerPlugin` *is* the `SecureVideoHostApi`
  implementation (`SecureVideoPlayerPlugin.kt:22`). `onAttachedToEngine` calls
  `SecureVideoHostApi.setUp(binaryMessenger, this)` (`SecureVideoPlayerPlugin.kt:66`),
  which registers a `setMessageHandler` on every method channel
  (`Messages.g.kt:634`).
- **iOS**: `SecureVideoPlayerPlugin` implements `SecureVideoHostApi`
  (`SecureVideoPlayerPlugin.swift:6`) and `register(with:)` calls
  `SecureVideoHostApiSetup.setUp(binaryMessenger:api:)`
  (`SecureVideoPlayerPlugin.swift:18`), wiring each channel's handler
  (`Messages.g.swift:634`).

### Threading — which thread runs the handler

Pigeon supports attaching a background `TaskQueue` to a host method. **This
schema attaches none** (verified: no `TaskQueue` reference exists in any
generated file). Therefore:

- **Android**: message handlers run on the **platform main thread** (the UI
  thread). Every `SecureVideoHostApi` method body executes there.
- **iOS**: handlers run on the **main dispatch queue**.

That is fine for cheap bookkeeping calls (`play`/`pause` just poke
`ExoPlayer`/`AVPlayer`), but it means a *slow synchronous* handler blocks the UI
thread — see Limitations. The heavy work (decrypt) is deliberately kept **off**
this path: it happens on ExoPlayer's loader thread / a per-player iOS
`DispatchQueue`, not in a Pigeon handler. File transforms run on their own
executor via `startCrypto` returning immediately with an `operationId`
(`SecureVideoPlayerPlugin.kt:263`).

### Error propagation across the bridge

The generated code wraps every reply in a two-slot protocol: `wrapResult(value)`
on success, `wrapError(throwable)` on failure (`Messages.g.kt:18`/`22`,
`Messages.g.swift:32`/`36`).

- **Native raises a typed error**: Kotlin throws `FlutterError(code, message,
  details)` (`Messages.g.kt:189`); Swift throws `PigeonError(code:message:details:)`
  (`Messages.g.swift:15`). The plugin uses the `SvpProtocol.ERROR_*` string codes
  (e.g. `SecureVideoPlayerPlugin.kt:113` for `adapterNotRegistered`,
  `SecureVideoPlayerPlugin.swift:63` for `platformNotSupported`).
- **Wire**: the error `[code, message, details]` list comes back on the reply.
- **Dart decodes it** into a `PlatformException` (Flutter's standard), which the
  controller catches and rethrows as a typed `SecureVideoException` via
  `SecureVideoException.fromPlatform` (`controller.dart:167`, `329`; mapping in
  `errors.dart:21`). `fromWire` maps the string code back to the
  `SecureVideoErrorCode` enum, falling back to `unknown` (`errors.dart:13`).

So a native `FlutterError("invalidKey", …)` surfaces in Dart as
`SecureVideoException(SecureVideoErrorCode.invalidKey, …)` — end-to-end typed
errors with no stringly-typed leakage into app code. Asynchronous playback errors
that occur *after* `create` returns take the **event** path instead, arriving as
an `error` event decoded in `controller.dart:241`.

---

## Tier 3 — Deep dive

### Serialization theory

Pigeon rides on Flutter's `StandardMessageCodec`, a tag-length-value binary
format. Each value is prefixed with a one-byte type tag; containers (lists, maps)
recurse. Pigeon's contribution is a **subclassed codec** that reserves tags ≥ 128
for user-defined classes and serializes each as a positional list of its fields
(`messages.g.dart:504`–`518`). This is:

- **Schema-versioned by position, not by name.** Fields are read back by index
  (`CreateRequest.decode`), so the field *order* in `pigeons/messages.dart` is the
  ABI. Reordering fields without regenerating all three outputs would silently
  corrupt data — which is why the three generated codecs are always regenerated
  together and never edited.
- **Zero-reflection.** Both encode and decode are straight-line code, so cost is
  O(field count), no runtime type inspection.

For the biggest message, `CreateRequest` carries 12 fields
(`pigeons/messages.dart:11`) including a nested `Map` for `schemeParams`. A
`create` round trip therefore serializes ~a dozen scalars plus the key/nonce
`Uint8List`s once, at player setup — negligible next to codec init.

### The BinaryMessenger and reply futures

Each Dart call is `channel.send(args)` returning a `Future` completed when the
native reply lands (`messages.g.dart:563`). Under the hood a single
`BinaryMessenger` multiplexes all channels over one platform-message port with an
integer reply-id, so "20 method channels" is not 20 ports — it's one messenger
keyed by channel name string. The per-call `BasicMessageChannel` object is cheap
(just name + codec + messenger).

Ordering guarantee: platform messages on a given channel are delivered in send
order, and because handlers run on the single platform thread, two calls on
different channels from the same isolate are serialized on the native side in
arrival order. There is no built-in coalescing — rapid `seekTo` spam is N round
trips (see Performance).

### Dependency injection seam

`SecureVideoController` accepts an optional `SecureVideoHostApi`
(`controller.dart:119`, `@visibleForTesting`). The generated client also accepts a
`BinaryMessenger` and a `messageChannelSuffix` (`messages.g.dart:547`). Tests
substitute a fake host API to exercise the controller state machine without a
running engine (`test/controller_test.dart`). The suffix mechanism would allow
multiple independent host-api instances on one messenger, though this package
uses the default (empty) suffix.

### Why not Pigeon for events

Pigeon's `@FlutterApi` could deliver native → Dart calls, but it is
request/response-shaped and offers no **buffering before subscription**. Playback
emits a burst of state the instant the engine is ready — `initialized` with
duration/size arrives from `onPlaybackStateChanged`/`status` observers that can
fire before Dart has attached a listener. The hand-rolled `EventChannel` +
`QueuingEventSink` (`PlayerInstance.kt:39`, `PlayerInstance.swift:7`) **queues
events until `onListen`**, eliminating the `initialized` race
(`README.md:203`). A per-player channel (`events_<id>`, `protocol.dart:8`) also
gives natural fan-out isolation for multiple simultaneous players. Pigeon is the
right tool for typed commands; `EventChannel` is the right tool for buffered
streams — the package uses each where it fits.

### Why Pigeon over hand-rolled `MethodChannel`

A hand-written `MethodChannel` would require manually: (a) picking a string
method name per call, (b) packing/unpacking `Map<String, dynamic>` arguments
with no compile-time checking, (c) hand-casting every field on both sides, and
(d) keeping Dart/Kotlin/Swift in sync by discipline alone. Pigeon replaces all
four with generated, type-checked code from one schema: a renamed or retyped
field is a **compile error** in all three languages after regeneration, not a
runtime `ClassCastException` discovered in the field. The cost is a build step and
a rule to never touch the `.g` files.

---

## Limitations (today)

- **Main-thread handlers.** No `TaskQueue` is configured, so every host method
  runs on the platform UI thread. `getMediaInfo` (`SecureVideoPlayerPlugin.kt:234`)
  probes a possibly-large encrypted file synchronously via `MediaInfoProbe` and
  can jank the UI thread; `getTracks` and `create` also run there.
- **No request coalescing.** Each control call is an independent round trip
  (`controller.dart:262`–`318`); a scrubber dragged fast issues one `seekTo` per
  frame.
- **Positional ABI fragility.** Field *order* in `pigeons/messages.dart` is the
  wire format; a partial regeneration (one platform's `.g` file stale) would
  corrupt decoding silently. Mitigation is discipline: regenerate all three.
- **Events are stringly-typed maps**, not Pigeon-typed. `_onEvent` casts
  `Map<String, Object?>` by key (`controller.dart:201`); a typo in a native
  payload key is only caught at runtime. This is the deliberate trade for
  buffered `EventChannel`s.
- **One-directional Pigeon.** No `@FlutterApi`, so any future *synchronous*
  native → Dart request (as opposed to fire-and-forget events) would need new
  wiring.

## Performance: how to make it insane

- **Batch/coalesce control calls.** Debounce `seekTo` in the controller (drop
  intermediate targets during a drag, send the last) to cut N round trips to ~1
  per gesture. *Estimated* meaningful reduction in main-thread churn during
  scrubbing. Low effort; low risk. Mechanism: a pending-target field + microtask
  flush in `controller.dart`.
- **Move slow handlers off the UI thread with a Pigeon `TaskQueue`.** Annotate
  `getMediaInfo` (and any future heavy synchronous call) to run on a background
  `TaskQueue` so probing a large file never blocks compositing. Medium effort
  (schema change + regenerate); low risk. Expected gain: eliminates
  probe-induced jank entirely.
- **Skip the bridge for high-frequency reads.** `getPosition`
  (`controller.dart:285`) is a round trip; the 250 ms event ticker already pushes
  position, so callers rarely need the synchronous variant. Prefer the event
  stream; reserve `getPosition` for exact one-shot reads. Zero code cost — usage
  guidance. (Documented already: events update ~4×/s, `controller.dart:284`.)
- **The pixel plane is already bridge-free.** Frames never cross Pigeon — only a
  `textureId` does (`messages.g.dart` `CreateResponse`, `pigeons/messages.dart:46`).
  No optimization needed here; the correct call was made at design time.

Cross-cutting synthesis and the "insane level" ideas are in **doc 07**.
