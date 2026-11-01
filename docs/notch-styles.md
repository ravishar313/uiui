# Notch styles

Choose a visual in **Settings → Appearance → Notch style**. The three compact preview cards use the actual native renderer. Selection applies immediately and saves automatically; opening Settings or previewing a style never starts the microphone.

| Style | Appearance |
| --- | --- |
| Mosaic | Fine tiles moving together, with voice-responsive illumination. The default; its drawing is unchanged. |
| Eyes | The uiui logo's two rounded-pill eyes, one each side of the camera, in the accent colour. They grow with the real voice level, blink occasionally, glance down toward the text, squint while processing, close on send and droop on cancel. |
| Voice bars | Nine thin rounded bars each side of the camera, driven by the smoothed real level with a 45 ms delay per bar. A shimmer travels outward while processing; the bars settle to baseline on send. |
| Words first | The live transcript is the visual: slightly larger text scrolling left, plus a thin line along the lower edge (breathing with the voice, sweeping while processing, one confirming sweep on send). |

Liquid and Ribbon were removed. Stored `liquid`, `ribbon` or unknown values load as Mosaic and keep every other preference.

In every style, the newest words in the transcript appear in the accent colour and fade to white over five words.

Every style covers starting, listening, processing, queued, send, cancellation and amber copy/error states. Reduced Motion draws still states, and the physical camera stays black.

## Capture behaviour

- **Can't hear you**: shown when no level reaches 0.01 RMS and no words arrive within 3 s of start, or when the input is electrically dead (below 0.0004 RMS) for 4 s after speech. A normal pause keeps a microphone noise floor above that and never triggers it. Clears when signal returns. Thresholds live in `NotchSignalPolicy`.
- **Input hint**: the default input device name ("Mic: ...") shows for 2.5 s at start unless it is the built-in microphone.
- **Timer**: elapsed time sits in the right wing for the whole recording, excluding paused time. Eyes and Voice bars paint that wing themselves, so their time shows only in the hover transcript.
- **Hover**: resting the pointer on a recording opens the full transcript, scrollable, without taking focus; it closes shortly after the pointer leaves.
- **Backspace**: while the microphone is listening, Backspace removes the last word from the live text, and holding it keeps removing words. Keep talking and new words continue from there. Nothing reaches the app behind. Command- and Control-Backspace pass through, and when the microphone is off Backspace behaves normally. Backspace is the only extra key the capture filter recognises, and it needs Accessibility access to work in other apps.
- **Pause**: pause/resume button on the left wing while hovering, or Control-Option-P (a single registered hot key, present only while a capture is active). While paused no buffer reaches the recogniser and the notch shows Paused; the transcript, capture identity and recovery are unchanged, so finish and cancel still work and delivery happens once. The audio engine stays open while paused (the system microphone indicator stays on); only audio delivery stops.
- **After a paste**: the sent state stays for 3 s with Undo and Copy (the light still ends at 460 ms). Undo posts one layout-aware Command-Z only if the same app is still frontmost and no newer capture started; it never presses Return. Copy uses the ordinary (non-transient) clipboard path. Without that offer the receipt still expires at 650 ms.
- **Paste failure**: "Copied, press ⌘V in <app>" (app name when known).
- **Which display**: while in use, the notch appears on the display with keyboard focus and stays there until it finishes. Opening it with the pointer keeps it on the display you pointed at. A display without a camera shows a rounded floating pill centred below the menu bar, and the pill draws nothing at rest. The decision is the pure `NotchPlacement.decide`.
- **Accessibility**: pause, finish, cancel, Undo and Copy are labelled; Listening, Paused, Processing, Sent, Copied, Cancelled and Can't hear you are announced as short phrases, never transcript text.

## Implementation and compatibility

`UIUISettings.notchVisualStyle` stores a `NotchVisualStyle` string in the existing settings payload. Missing, unrecognized and malformed style values fall back to Mosaic while retaining other preferences and dictionary entries. Normal settings observation persists choices; no second preference store or OS side-effect owner is added.

One persistent `NotchVisualFeedback` owns the existing TimelineView, Canvas, camera mask and audio smoothing. Mosaic retains its existing drawing; Eyes, Voice bars and the Words line use a few rounded paths in that Canvas (`NotchNativeStyles.swift`), and Words first draws its text in the transcript row. Steady fields use 30 Hz; short phase handoffs and send/cancel gestures use 60 Hz, with no idle recurring frames and the same receipt lifecycle. The three Settings previews have fixed progress and no active animation schedule. No model, network request, image, shader, web runtime or new dependency is added.

## Verification

- Swift suite covers existing behaviour plus the signal policy, timer, input hint, undo policy, placement, layout, eye/bar motion, level history, announcements, pause (hold, resume, finish once, cancel) and setting migration.
- `--notch-style-preview OUTPUT` (debug builds only: `swift build`, then `.build/debug/UIUI --notch-style-preview OUTPUT`) renders every phase in camera, no-camera and Reduced Motion configurations for all four styles, plus an extras sheet per style (paused, Can't hear you, input hint, timer, hover transcript, Undo/Copy, amber copy notice, floating pill). It checks the camera region stays black, terminal fields go dark, styles differ, and the mounted receipt expires by its deadline. It uses no microphone, clipboard or private history. Hover transcript previews use a static layout because ImageRenderer cannot draw a ScrollView.
- Not exercised with real hardware: microphone levels and the Can't hear you thresholds, pause on each speech engine, Undo in a real app, the hot key, an external display.

## Installation


