# Nebula

Nebula is GalaxyAI's touch: hands-free gesture control for the Mac. Comet is text, Orbit is voice, Nova is sight, Zenith will be time. It follows `NEBULA_PLAN.md` (in NovaAI) exactly: the same ten v1 gestures, movements and actions.

Three things are the product: it recognizes the right gesture, it controls the right window, and it reacts in real time. Nebula proves each one with numbers and won't let a gesture act until those numbers meet their targets on your own recordings.

## Build and install

You need a Mac with Xcode (or its command-line tools) and Swift 5.10 or later.

```bash
git clone https://github.com/Zebra0723/NebulaAI && cd NebulaAI
git checkout claude/laughing-shannon-7j3yyk
```

**First build: the recording build.** There's nothing to prove gestures on yet, so nothing can fire. It's for recording.

```bash
scripts/build-app.sh --recorder --install
```

Then follow [docs/RECORDING.md](docs/RECORDING.md) (about two hours, spread over two days), and in Nebula use **Settings → Train and report**. Then build for real:

```bash
scripts/build-app.sh --install
```

That build runs the unit tests, the latency benchmark (recognizer p95 ≤ 2 ms) and the accuracy report on your held-out test sessions, and **refuses to build if any target is missed**. To build with only the gestures that passed switched on:

```bash
scripts/build-app.sh --ship-passing --install
```

Keep permissions across rebuilds by signing with your development identity (the build uses Nova's if you've set it):

```bash
export NEBULA_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
```

## Permissions

| Permission | When it's asked | Why |
|---|---|---|
| **Camera** | The first time you turn Nebula on (fn F1) or start Practice | Hand pose. Frames stay in memory for one detection; only 21 points per hand are used, never saved or sent. |
| **Accessibility** | At first launch (System Settings → Privacy & Security → Accessibility → Nebula) | Keystrokes and scrolls to the window in front, and reading which window that is. |
| **Automation** | App by app, the first time Safari, Chrome, Arc, Keynote, Spotify or Music comes to the front while Nebula is running | Play/pause, slides and tracks through that app's own interface. |
| Safari / Chrome / Arc: **Allow JavaScript from Apple Events** | Once, in each browser's Develop (Safari) or View → Developer (Chrome) menu | Open palm plays and pauses the video or audio in the active tab. |
| Keychain | The first time you use Create | Nebula reads Nova's Anthropic key (`ai.galaxy.nova` / `anthropic-api-key`), or its own if you set one in Settings. |

## Using it

- **fn F1** turns Nebula on and off. It's off by default, and the camera is on only while it's on (the green light). It turns itself off after 5 minutes with no hand, on screen lock or sleep, or when you wave.
- **Approval mode:** when a Galaxy body is waiting on your yes or no, the camera turns on for 60 seconds for a thumbs up or down. This needs the Galaxy Link approvals patch in [galaxy-patch/](galaxy-patch/README.md).
- A ring fills in the HUD at the top of the screen the moment Nebula sees a pose, then the HUD names what was controlled: "Next tab · Safari", "Paused · YouTube", "Orbit muted", "Nothing to control in Notes".
- Menu bar → **That was wrong** saves the last three seconds as a hard negative for the next training run.

| Gesture | Movement | Action |
|---|---|---|
| Open palm | Flat hand, fingers together, palm to the screen, held still | Play/pause in the frontmost window |
| Thumbs up / down | Fist, thumb up / down, held | Approve / reject the pending Galaxy approval |
| Peace sign | Index and middle up in a V, palm to the screen, held | Summon Nova (⌃Space) |
| Finger to lips | Index up, held against the lips | Mute Orbit until unmuted |
| Hand to ear | Cupped hand behind the ear, held | Unmute Orbit |
| Swipe left / right | Open flat hand moved quickly sideways, about shoulder width | Previous / next tab, slide, page or track |
| Scroll | Index and middle together and up, hand moved up or down | Scroll the frontmost window |
| Volume knob | Pinch as if holding a small knob, twist | Mac volume |
| Wave | Open hand waved side to side 2–3 times | Turn Nebula off |

## Targeting tests with real windows

The targeting rules are unit-tested in `swift test`. The end-to-end tests open real windows (two Safari windows plus TextEdit, two Preview documents, two TextEdit windows with the pointer over the back one, Keynote if it's installed, a second display if one is connected), fire gestures through the real action router, and check that only the frontmost window changed. They run inside the installed app, so they use Nebula's own permissions:

```bash
scripts/test-targeting.sh
```

They open and close windows in those apps, so run them when you aren't using them.

## How it works

```
camera ─▶ Vision (21 joints) ─▶ features ─▶ Judge A (rules) ┐
                                         └▶ Judge B (network) ┴▶ decision ─▶ target ─▶ action ─▶ check
```

- **Camera:** the highest frame rate the camera offers at the smallest size (640×480 by default, 1280×720 in Settings to compare), with the frame duration pinned so dim light can't lower the frame rate (Practice warns you if the room is too dark to hold it). Late frames are discarded; a stale frame is dropped, never acted on.
- **Pipeline:** one userInteractive serial queue runs Vision (one reused request and sequence handler), the recognizer and the actions. Face *rectangles* come from a second queue ten times a second and are only used to place "finger to lips" and "hand to ear". Only the HUD and the window touch the main thread.
- **Features** (`Sources/NebulaCore/Features.swift`): wrist at the origin, scaled by the palm, rotated to the palm's axis, left hands mirrored; per-finger curl, reach, spread and thumb distances, palm facing, orientation, face-relative position, and motion from a low-lag One Euro filter.
- **Judge A** (`Rules.swift`): each pose as explicit conditions with tolerance bands. **Judge B** (`MLP.swift`): a 35→64→10 network with a "nothing" class, trained on your sessions. A gesture fires only when both agree, B is confident with a clear lead, and the pose is held (80% agreement, hysteresis, release and cooldown). Swipes and waves fire on the frame the movement completes; scroll and the knob update every frame, with short-horizon prediction.
- **Targeting** (`Targeting.swift`, `TargetTracker.swift`): the frontmost app and its focused window are cached on activation and focus changes and re-checked just before posting. A gesture that began in another app, no focused window, or Nebula or a system window in front means nothing happens. Keys and scrolls go to that app's pid only; media and slides go through that app's own interface. There is never a global media key.
- **Proof:** `nebula-report` (bundled in the app, and buildable with `swift build`) trains, tunes for precision first, and reports on held-out sessions. `swift test` proves the per-frame path never allocates and gates its time at 2 ms p95.

```bash
swift run nebula-report report --data ~/Library/Application\ Support/Nebula/Recordings
swift run nebula-report diagnose   # why a gesture doesn't register
swift run nebula-report trace --gesture peace
```

## Repository

| Path | What |
|---|---|
| `Sources/NebulaCore` | Recognizer, features, judges, decision, recording format, training, evaluation, targeting rules, custom-gesture checks. Pure Swift; builds and tests on Linux too. |
| `Sources/Nebula` | The Mac app: camera, Vision, actions, adapters, HUD, Galaxy Link, the Create screen's designer, the four screens. |
| `Sources/NebulaReport` | `nebula-report`. |
| `Sources/NebulaSim` | A synthetic hand for testing the pipeline before real data exists. Its numbers are always labelled synthetic and can't pass the gate. |
| `Tests/NebulaCoreTests` | Unit tests and the build gates. |
| `galaxy-patch/` | The Galaxy Link approvals API, as a patch for NovaAI's `galaxy/`. |
| `docs/` | The recording plan and the Comet write-up. |
