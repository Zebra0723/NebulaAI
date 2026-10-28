# Recording plan

Nebula only lets a gesture act once its numbers meet every target on **your** recordings, measured on sessions it never trained on. This is exactly what to record, in what order, and how long each part takes.

Everything is recorded in the app: **Nebula → Practice → Recorder**. Recordings are joint positions and labels only, never images, saved to `~/Library/Application Support/Nebula/Recordings`.

Before you start:
- Build the recording build: `scripts/build-app.sh --recorder --install`. No gesture can act in it.
- Sit as you normally do at the Mac. The face rectangle matters for "finger to lips" and "hand to ear", so stay in view.
- Make each gesture **the way you'd really make it**, not extra slowly or extra carefully. Vary it a little from one repetition to the next.
- During **Get ready**, raise your hand into view. During **Now**, make the gesture and hold or finish it. During **Rest**, lower your hand out of view or onto the desk.

## How sessions are split

Sessions are assigned, per kind, in rotation: train, validation, train, test. So of every four gesture sessions, two teach Judge B, one tunes the thresholds and one is held out for the report. A session is never split by frame.

With four gesture sessions, the test session holds 15 examples of each gesture, so 99% means **15 out of 15**. Eight sessions double that. More sessions are better evidence; the targets don't change.

## 1. Gesture sessions: 4 sessions minimum, 8 recommended (about 14 min each)

Recorder: **Gesture session**, **Of each: 15**. It prompts all 12 labels (the volume knob is two: clockwise and counter-clockwise) 15 times each, shuffled.

| Session | Light | Distance | Hand | Notes |
|---|---|---|---|---|
| 1 | Daylight | 70 cm | Right | Normal posture |
| 2 | Lamp at night | 40 cm | Left | Lean in a little |
| 3 | Backlit (window or lamp behind you) | 100 cm | Both: alternate | Sit back |
| 4 | Overhead / office light | 70 cm | Right | Turn your chair 15–20° to one side |
| 5–8 (recommended) | Repeat 1–4 on different days | | | Swap the hands |

Set the Light, Distance and Hand pickers to match before each one; they're saved with the session.

## 2. Ordinary use ("nothing"): 30 minutes minimum, in 4 sessions

Recorder: **Ordinary use**, **Minutes: 8** (four sessions gives 32 minutes; split across days and lighting like the gesture sessions). Use the Mac normally and do **not** make any gesture. The recorder suggests an activity each minute; cover all of these across the sessions:

- typing (a few minutes each session)
- using the trackpad and the mouse
- drinking, eating a snack
- touching your face and hair, resting your chin on your hand
- talking with your hands (a video call is ideal)
- stretching, leaning back
- holding and using your phone
- reaching across the desk for things

The target is at most **1 false fire per 4 hours**. Thirty minutes can show zero false fires but can't prove that rate; the report says so. Recording ordinary use now and then over the following weeks builds that evidence.

## 3. Near-misses: 4 sessions (about 6 minutes each)

Recorder: **Near-misses**, **Of each: 5**. These are the poses most like a gesture without being one:

an open hand resting on the desk · two fingers loosely raised · a fist with the thumb tucked in · scratching your chin · scratching near your ear · a hand resting near your mouth · pointing up away from your face · a fist with the thumb sideways · touching your hair · an OK sign · the back of a flat hand · an open hand moving slowly, as if talking.

## 4. Enrollment: once, about 9 minutes

Recorder: **Enrollment**. Ten of each gesture. When it finishes, Nebula fits itself to your hands (Judge A's tolerance bands widen to fit you, Judge B retrains with your examples counting three times, and it checks your camera's left/right convention).

## 5. Train, report, build

1. **Settings → Train and report from my recordings.** It trains on the train sessions, tunes the thresholds on validation (precision first, then recall, holds lengthened only where needed) and prints the report: confusion matrix, per-gesture recall and precision, false fires per armed hour, latency, and every risky pair.
2. Turn Nebula on (fn F1) and use it for a while, so the latency log fills (`latency.json`); the report includes it from then on.
3. Build: `scripts/build-app.sh --install`. It refuses to build if any target is missed. `--ship-passing` builds with only the gestures that passed switched on.

If a gesture misses its target, `nebula-report diagnose` shows, gesture by gesture, which of Judge A's conditions fail and what Judge B thinks instead, and `nebula-report trace --gesture peace` steps through every frame of every example.

## Totals

| Part | Minimum | Recommended |
|---|---|---|
| Gesture sessions | 4 × 14 min | 8 × 14 min |
| Ordinary use | 4 × 8 min | 8 × 8 min, more over time |
| Near-misses | 4 × 6 min | 4 × 6 min |
| Enrollment | 9 min | 9 min |
| **Total** | **about 2 hours** | **about 3½ hours** |

Spread it over at least two days so lighting and posture really differ.
