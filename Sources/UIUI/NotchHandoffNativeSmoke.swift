import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Explicit public-fixture acceptance of the real mounted stage. Capture hardware,
/// cleanup and delivery are inert fixtures; no application services are started.
@MainActor
enum NotchHandoffNativeSmoke {
    private static let words = "Can we ship this after lunch, once the review is complete?"
    private static let blackThreshold = 8
    private enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
    }
    private struct Camera {
        let width: CGFloat
        let height: CGFloat
        let source: String
    }
    private struct Pixels {
        let image: CGImage
        let bytes: [UInt8]
        @MainActor func region(_ rect: CGRect, pointSize: CGSize) throws -> (maximum: Int, colored: Int) {
            let sx = CGFloat(image.width) / pointSize.width, sy = CGFloat(image.height) / pointSize.height
            let x0 = max(0, Int(ceil(rect.minX * sx))), x1 = min(image.width, Int(floor(rect.maxX * sx)))
            let y0 = max(0, Int(ceil(rect.minY * sy))), y1 = min(image.height, Int(floor(rect.maxY * sy)))
            guard x0 < x1, y0 < y1,
                  let crop = image.cropping(to: CGRect(x: CGFloat(x0), y: CGFloat(y0),
                    width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))) else {
                throw Failure.failed("Native pixel assertion region is empty.")
            }
            // Crop in top-origin image coordinates before normalizing bytes;
            // the provider's storage row direction cannot move the camera.
            let sample = try NotchHandoffNativeSmoke.decode(crop)
            var maximum = 0, colored = 0
            for offset in stride(from: 0, to: sample.bytes.count, by: 4) {
                let r = Int(sample.bytes[offset]), g = Int(sample.bytes[offset + 1]), b = Int(sample.bytes[offset + 2])
                maximum = max(maximum, max(r, max(g, b)))
                // The transcript is white. The field's lime has less blue, so
                // glyph antialiasing cannot masquerade as a lit field here.
                if min(r, g) - b > 3 && max(r, g) > blackThreshold { colored += 1 }
            }
            return (maximum, colored)
        }
    }
    private final class Trace {
        var stoppedAt: ContinuousClock.Instant?
        var receiptAt: ContinuousClock.Instant?
        var receiptID: UUID?
        var error: Error?
    }

    static func run(output: URL) async throws {
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.failed("Use a new local handoff preview directory.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let camera = measuredCamera()
        var results: [[String: Any]] = []
        for style in NotchVisualStyle.allCases {
            for delay in [40, 200] {
                let directory = output.appendingPathComponent("\(style.rawValue)-send-\(delay)ms", isDirectory: true)
                results.append(try await sequence(style: style, processingMS: delay, cancellation: false,
                                                   camera: camera, output: directory))
            }
            let directory = output.appendingPathComponent("\(style.rawValue)-cancel", isDirectory: true)
            results.append(try await sequence(style: style, processingMS: 0, cancellation: true,
                                               camera: camera, output: directory))
        }
        try json(["passed": true, "sequences": results, "sequence_count": results.count,
                  "renderer": "real-NotchStage-in-ordered-offscreen-NSWindow",
                  "visible_onscreen_compositor": "unmeasured", "microphone": "not-opened",
                  "clipboard": "untouched", "models": "not-prepared", "history": "not-opened",
                  "system_observers": false, "sampling_hz": 60, "gif_timing": "quantized-frame-delays-native-timeline-is-authoritative", "camera_width_pt": camera.width,
                  "camera_height_pt": camera.height, "camera_geometry_source": camera.source,
                  "smoothness_scope": "boundary-pixel-differences-recorded-without-subjective-pass-threshold"],
                 to: output.appendingPathComponent("verification.json"))
        print("NOTCH_HANDOFF_PREVIEW passed=true sequences=\(results.count) microphone=not-opened clipboard=untouched")
    }

    private static func sequence(style: NotchVisualStyle, processingMS: Int, cancellation: Bool,
                                  camera: Camera, output: URL) async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let suite = "uiui-handoff-public-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.failed("Isolated defaults unavailable.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let capture = FixtureCapture(), delivery = FixtureDelivery()
        let voice = TriggeredVoice(capture: capture)
        let model = AppModel(dataDirectory: temporary, defaults: defaults, persistSettings: false,
                             delivery: delivery, cleanup: FixtureCleanup(), voice: voice)
        model.settings.notchEnabled = false
        model.settings.notchVisualStyle = style
        model.settings.soundFeedbackEnabled = false
        model.settings.keepRecordingRecovery = false
        model.settings.saveDictationHistory = false
        model.notchHasCamera = true
        model.notchCameraWidth = camera.width
        model.notchCameraHeight = camera.height
        model.notchExpanded = true
        model.notchMounted = true
        // Keep the real state/partial projection but sever OS destination and
        // final inference/delivery callbacks at their explicit fixture seams.
        voice.onTrigger = {}
        voice.onCommand = { _ in }
        voice.onFinalization = nil
        let coordinator = PanelCoordinator(model: model, installSystemObservers: false)
        let size = layout(model, phase: .recording)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        var stage = NotchStage(model: model, onExpand: {}, onCollapse: {})
        stage.feedbackPreviewIsVisible = true
        let host = NSHostingView(rootView: stage.environment(\.notchMotionPreviewOverride, false))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        defer {
            coordinator.shutdown()
            model.shutdown()
            window.orderOut(nil); window.contentView = nil; window.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }
        window.orderFront(nil)
        pump()
        try await Task.sleep(for: .milliseconds(35))
        try await voice.start(locale: "en-IN", contextualStrings: [])
        let trace = Trace()
        let start = ContinuousClock.now
        let transition = Task { @MainActor in
            do {
                try await Task.sleep(until: start.advanced(by: .milliseconds(250)), clock: .continuous)
                trace.stoppedAt = .now
                if cancellation {
                    model.cancelVoiceInputFromEscape()
                } else {
                    voice.finish(userInitiated: true)
                    model.dictationFeedback = VoiceActionFeedback(state: .working, title: "Processing dictation",
                                                                  detail: "Microphone off")
                    try await Task.sleep(for: .milliseconds(processingMS))
                    capture.complete()
                    voice.setWorking(false)
                    model.dictationFeedback = VoiceActionFeedback(state: .information, title: "Paste sent · copied",
                        detail: "Synthetic visual acceptance", presentation: .pasteDispatch)
                }
                trace.receiptAt = .now
                trace.receiptID = model.notchVoiceFeedback?.id
                coordinator.activityChanged()
                // Disabled production panels cannot open. Restore only this
                // isolated stage's expansion before yielding to the renderer.
                model.notchExpanded = true
                model.notchMounted = true
            } catch { trace.error = error }
        }
        defer { transition.cancel() }
        let durationMS = cancellation ? 850 : 250 + processingMS + 900
        let frameCount = Int(ceil(Double(durationMS) * 60 / 1_000))
        var frames: [CGImage] = [], timeline: [[String: Any]] = []
        var boundaryDeltas: [[String: Any]] = []
        var previous: Pixels?, previousPhase: NotchFeedbackPhase?
        var seenPhases: Set<String> = []
        var expiryMS: Double?, cameraMaximum = 0, terminalChecks = 0, activeChecks = 0
        var accessibility: [String: [String]] = [:]
        for index in 0...frameCount {
            try await Task.sleep(until: start.advanced(by: .nanoseconds(Int64(index) * 1_000_000_000 / 60)), clock: .continuous)
            pump()
            if let error = trace.error { throw error }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); window.displayIfNeeded()
            let image = try snapshot(host)
            try png(image, to: output.appendingPathComponent(String(format: "%03d.png", index)))
            let pixels = try decode(image)
            let phase = model.notchFeedbackPhase
            let elapsed = ms(start.duration(to: .now))
            let phaseSize = layout(model, phase: phase)
            guard phase != .recording || capture.active,
                  ![NotchFeedbackPhase.processing, .dispatched, .cancelled, .idle].contains(phase) || !capture.active else {
                throw Failure.failed("Visible phase disagrees with the synthetic input owner's active state.")
            }
            if phase == .recording || phase == .processing {
                guard model.voiceTranscript == words else { throw Failure.failed("Public transcript was lost during handoff.") }
            }
            if [.preparing, .recording, .processing, .queued, .dispatched].contains(phase) {
                guard phaseSize == size, host.bounds.size == size else {
                    throw Failure.failed("Active layout hopped during \(style.rawValue)/\(phase.rawValue).")
                }
            }
            let cameraRect = CGRect(x: (size.width - camera.width) / 2, y: 0,
                                    width: camera.width, height: min(camera.height, size.height))
            let cameraLight = try pixels.region(cameraRect, pointSize: size).maximum
            cameraMaximum = max(cameraMaximum, cameraLight)
            guard cameraLight <= blackThreshold else { throw Failure.failed("Camera illuminated during native handoff.") }
            // Probe the bottom band and outer wings, outside both header marks.
            // Processing can quiet the reading row substantially; a dark bottom
            // sample alone must not falsely call the whole field blank.
            let probes = [
                CGRect(x: size.width * 0.25, y: max(0, phaseSize.height - 8), width: size.width * 0.5, height: 6),
                CGRect(x: 0, y: 8, width: 20, height: max(1, camera.height - 12)),
                CGRect(x: size.width - 20, y: 8, width: 20, height: max(1, camera.height - 12))
            ]
            let readings = try probes.map { try pixels.region($0, pointSize: size) }
            let field = (maximum: readings.map { $0.maximum }.max() ?? 0,
                         colored: readings.map { $0.colored }.reduce(0, +))
            if (phase == .recording && elapsed > 150) || phase == .processing {
                activeChecks += 1
                guard field.colored > 0 else { throw Failure.failed("Blank active light field during \(style.rawValue)/\(phase.rawValue).") }
            }
            let receiptAge = trace.receiptAt.map { ms($0.duration(to: .now)) }
            if let receiptAge, receiptAge >= (cancellation ? 260 : 460) + 70 {
                terminalChecks += 1
                guard field.colored == 0, field.maximum <= blackThreshold else {
                    throw Failure.failed("Send/cancel field exceeded its hard terminal deadline.")
                }
            }
            if trace.receiptAt != nil, model.notchVoiceFeedback == nil, expiryMS == nil {
                expiryMS = receiptAge
            }
            if let receiptID = trace.receiptID, model.dictationFeedback?.id != receiptID {
                throw Failure.failed("The receipt was replaced during handoff.")
            }
            let labels: [String]
            if !seenPhases.contains(phase.rawValue) {
                labels = accessibleLabels(host)
                accessibility[phase.rawValue] = labels
                seenPhases.insert(phase.rawValue)
                // SwiftUI may not materialize its owned accessibility tree for
                // an offscreen window. Record that coverage gap explicitly;
                // real capture-state/pixel checks remain mandatory below.
                if !labels.isEmpty { try validateLabels(labels, phase: phase) }
            } else { labels = [] }
            var row: [String: Any] = ["frame": index, "elapsed_ms": elapsed, "phase": phase.rawValue,
                "capture_state": voice.state, "microphone_fixture_active": capture.active,
                "layout_width_pt": phaseSize.width, "layout_height_pt": phaseSize.height,
                "camera_maximum_rgb_255": cameraLight, "field_colored_pixels": field.colored,
                "field_maximum_rgb_255": field.maximum, "receipt_visible": model.notchVoiceFeedback != nil]
            if let receiptAge { row["receipt_age_ms"] = receiptAge }
            if !labels.isEmpty { row["accessibility_labels"] = labels }
            if let previous {
                let delta = difference(previous.bytes, pixels.bytes)
                row["mean_absolute_rgb_delta_255"] = delta.mean
                row["changed_pixel_fraction"] = delta.fraction
                if previousPhase != phase {
                    boundaryDeltas.append(["from": previousPhase?.rawValue ?? "none", "to": phase.rawValue,
                        "elapsed_ms": elapsed, "mean_absolute_rgb_delta_255": delta.mean,
                        "changed_pixel_fraction": delta.fraction])
                }
            }
            timeline.append(row); frames.append(image)
            previous = pixels; previousPhase = phase
        }
        await transition.value
        if let error = trace.error { throw error }
        try json(["frames": timeline, "boundary_differences": boundaryDeltas],
                 to: output.appendingPathComponent("timeline.json"))
        try gif(frames, to: output.appendingPathComponent("handoff.gif"))
        let deadline = cancellation ? 280.0 : 650.0
        guard let expiryMS, expiryMS <= deadline + 70, model.notchVoiceFeedback == nil,
              terminalChecks > 0, activeChecks > 0, delivery.calls == 0,
              timeline.suffix(4).allSatisfy({ $0["phase"] as? String == "idle" }) else {
            throw Failure.failed("Receipt expiry, terminal darkness or isolated delivery verification failed.")
        }
        guard seenPhases.contains("recording"), seenPhases.contains(cancellation ? "cancelled" : "dispatched"),
              cancellation || seenPhases.contains("processing") else {
            throw Failure.failed("Native frames did not expose every expected handoff state.")
        }
        let result: [String: Any] = ["passed": true, "style": style.rawValue,
            "cancellation": cancellation, "requested_processing_ms": processingMS,
            "actual_processing_ms": trace.stoppedAt.flatMap { stop in trace.receiptAt.map { ms(stop.duration(to: $0)) } } ?? 0,
            "frames": frames.count, "active_field_checks": activeChecks, "terminal_checks": terminalChecks,
            "field_probe_scope": "bottom-center-and-outer-wings-excluding-header-marks",
            "camera_maximum_rgb_255": cameraMaximum, "receipt_expired_ms": expiryMS,
            "receipt_deadline_ms": deadline, "sampling_tolerance_ms": 70,
            "active_footprint_width_pt": size.width, "active_footprint_height_pt": size.height,
            "accessibility_labels": accessibility,
            "accessibility_probe_scope": accessibility.values.allSatisfy { !$0.isEmpty }
                ? "owned-tree-inspected" : "not-fully-exposed-by-offscreen-host",
            "boundary_differences": boundaryDeltas,
            "smoothness_judgment": "requires-visual-review", "progress_override": false]
        try json(result, to: output.appendingPathComponent("verification.json"))
        return result
    }

    private static func layout(_ model: AppModel, phase: NotchFeedbackPhase) -> CGSize {
        NotchLayout.surfaceSize(phase: phase, cameraWidth: model.notchCameraWidth,
            cameraHeight: model.notchCameraHeight, hasCamera: model.notchHasCamera, expanded: true)
    }
    private static func measuredCamera() -> Camera {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            return Camera(width: right.minX - left.maxX, height: screen.safeAreaInsets.top,
                          source: "NSScreen-auxiliary-areas-safeAreaInsets")
        }
        return Camera(width: 220, height: 38, source: "explicit-representative-220x38")
    }
    private static func snapshot(_ host: NSView) throws -> CGImage {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure.failed("Native stage cannot create a display cache.")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw Failure.failed("Native stage cache is empty.") }
        return image
    }
    private static func decode(_ image: CGImage) throws -> Pixels {
        // Full-frame byte orientation is immaterial for adjacent-frame deltas;
        // pixel regions are cropped from the CGImage before normalization.
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard success else { throw Failure.failed("Cannot inspect stage pixels.") }
        return Pixels(image: image, bytes: bytes)
    }
    private static func difference(_ first: [UInt8], _ second: [UInt8]) -> (mean: Double, fraction: Double) {
        guard first.count == second.count, !first.isEmpty else { return (255, 1) }
        var total = 0, changed = 0
        for offset in stride(from: 0, to: first.count, by: 4) {
            var maximum = 0
            for channel in 0..<3 {
                let delta = abs(Int(first[offset + channel]) - Int(second[offset + channel]))
                maximum = max(maximum, delta); total += delta
            }
            if maximum > blackThreshold { changed += 1 }
        }
        let count = first.count / 4
        return (Double(total) / Double(count * 3), Double(changed) / Double(count))
    }
    private static func accessibleLabels(_ host: NSView) -> [String] {
        var labels: Set<String> = [], visited = 0
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        func walk(_ value: Any, depth: Int) {
            guard depth < 10, visited < 250, let element = value as? NSObject else { return }
            visited += 1
            // Objective-C getters also cover SwiftUI's private owned AX nodes,
            // without relying on their concrete class or protocol import name.
            if element.responds(to: labelSelector),
               let label = element.perform(labelSelector)?.takeUnretainedValue() as? String,
               !label.isEmpty { labels.insert(label) }
            if element.responds(to: childrenSelector),
               let children = element.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
                for child in children { walk(child, depth: depth + 1) }
            }
        }
        walk(host, depth: 0)
        return labels.sorted()
    }
    private static func validateLabels(_ labels: [String], phase: NotchFeedbackPhase) throws {
        guard !labels.isEmpty else { throw Failure.failed("Owned native stage has no inspectable accessibility labels.") }
        let joined = labels.joined(separator: " ").lowercased()
        if phase == .recording {
            guard joined.contains("microphone on") else { throw Failure.failed("Recording accessibility never states microphone on.") }
        } else {
            guard !joined.contains("microphone on"), joined.contains("microphone off") else {
                throw Failure.failed("Stopped accessibility state misstates microphone ownership.")
            }
        }
        if phase == .recording || phase == .processing {
            guard labels.contains(where: { $0.contains(words) }) else {
                throw Failure.failed("Public transcript is missing from recording/processing accessibility.")
            }
        }
    }
    private static func png(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.failed("Cannot create native frame PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("Cannot save native frame PNG.") }
    }
    private static func gif(_ frames: [CGImage], to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw Failure.failed("Cannot create handoff GIF.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 60]] as CFDictionary
        for image in frames { CGImageDestinationAddImage(destination, image, properties) }
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("Cannot save handoff GIF.") }
    }
    private static func json(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func pump() {
        let until = Date(timeIntervalSinceNow: 0.002)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
    }
    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private final class FixtureCapture: TriggeredVoiceCapture {
        var active = false
        var onPartial: ((String) -> Void)?, onFinal: ((String) -> Void)?
        var onCompletion: ((SpeechCompletion) -> Void)?, onError: ((String) -> Void)?
        var onRecovery: ((String) -> Void)?, onAudioLevel: ((Float) -> Void)?
        var onFinalization: ((Double) -> Void)?
        func requestAuthorization() async -> Bool { true }
        func start(locale: String, contextualStrings: [String]) async throws {
            active = true; onPartial?(words); onAudioLevel?(0.05)
        }
        func stop() { active = false }
        func cancel() { active = false }
        func complete() { onCompletion?(SpeechCompletion(text: words, reason: .final, wasExplicitlyStopped: true)) }
    }
    private final class FixtureCleanup: DictationCleaning {
        func prepare() {}
        func begin(_ id: UUID) {}
        func update(_ text: String, captureID: UUID) {}
        func finish(_ text: String, captureID: UUID) async throws -> String { text }
        func cancel() {}
        func release() {}
    }
    private final class FixtureDelivery: TextDelivering {
        var calls = 0
        func deliver(_ text: String, to target: DeliveryTarget?) async -> DeliveryResult {
            calls += 1
            return .held("Visual fixture never delivers text.")
        }
        func cancel() {}
    }
}
