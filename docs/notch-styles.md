# Notch styles

Choose a visual in **Settings → Appearance → Notch style**. The three compact preview cards use the actual native renderer. Selection applies immediately and saves automatically; opening Settings or previewing a style never starts the microphone.

| Style | Appearance |
| --- | --- |
| Mosaic | Fine tiles moving together, with voice-responsive illumination. This remains the default for existing and new installations. |
| Liquid | Soft pools of moving light and fine flowing curves. |
| Ribbon | A thin light ribbon following the lower edge and perimeter. |

Every style covers starting, listening, processing, queued work, send, cancellation and persistent amber copy/error feedback. The physical camera remains black, the transcript stays in its compact rolling line, and the same hover controls and accessibility actions remain available. Reduced Motion uses still states.

The setting changes only drawing. Switching during a recording preserves its capture identity, words and final delivery. Switching during a send receipt preserves its original expiry: illumination ends at 460 ms and the receipt expires at 650 ms. Escape still cancels capture immediately, then shows a 260 ms withdrawal.

## Implementation and compatibility

`UIUISettings.notchVisualStyle` stores a `NotchVisualStyle` string in the existing settings payload. Missing, unrecognized and malformed style values fall back to Mosaic while retaining other preferences and dictionary entries. Normal settings observation persists choices; no second preference store or OS side-effect owner is added.

One persistent `NotchVisualFeedback` owns the existing TimelineView, Canvas, camera mask and audio smoothing. Mosaic retains its existing drawing; Liquid and Ribbon use bounded paths and gradients in that Canvas. Steady fields use 30 Hz; short phase handoffs and send/cancel gestures use 60 Hz, with no idle recurring frames and the same receipt lifecycle. The three Settings previews have fixed progress and no active animation schedule. No model, network request, image, shader, web runtime or new dependency is added.

## Verification

- Full Swift suite covers existing behavior plus setting migration, future-value fallback, reload, camera geometry and hot style switching during active capture and dispatch.
- `--notch-style-preview OUTPUT` (debug builds only: run `swift build` then `.build/debug/UIUI --notch-style-preview OUTPUT`; release builds and `scripts/build-app.sh` ignore all developer flags) (also available through the earlier `--mosaic-preview` spelling) renders 198 real SwiftUI state configurations across three styles. It checks physical-camera black pixels, terminal darkness, visually distinct output, per-style mounted receipt expiry and a Mosaic-to-Liquid switch during dispatch. The same helper saves actual Settings picker screenshots for layout review.

The helpers use isolated settings, public fixture text and owned windows. They do not open private history or a microphone. Native delivery checks use disposable fields and restore the clipboard only while they still own it.

The final source passed **441 Swift tests** and **198 native rendering configurations**. All inspected camera and terminal-field pixels were black. The three actual notch styles are visibly distinct, and the Settings cards were reviewed in light and dark appearance. Native receipts were observed gone at 672 ms against the 650 ms deadline sampled at 30 Hz; switching Mosaic to Liquid at 102 ms preserved the same receipt and its original deadline. All 66 Mosaic configurations matched the accepted prior render within one 8-bit channel level of native raster rounding.

Review also identified an existing broad settings callback that could release pending cleanup when the shortcut was disabled. Speech warmth now refreshes only for voice-shortcut enablement or language changes; a suspended-cleanup regression verifies style selection still delivers the complete result exactly once.

## Installation


