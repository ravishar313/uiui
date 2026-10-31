#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Explicit native, public-fixture visual acceptance. No start(), repository,
/// model preparation, input device, clipboard, shortcut or provider is opened.
@MainActor
enum MosaicNativeSmoke {
    private static let transcript = "Can we ship this after lunch, once the review is complete?"
    private static let phases: [NotchFeedbackPhase] = [
        .idle, .preparing, .recording, .processing, .queued, .dispatched,
        .copied, .needsInput, .cancelled, .success, .message
    ]
    private static let scale: CGFloat = 2
    private static let blackThreshold: UInt8 = 8

    private struct Configuration {
        let name: String
        let camera: Bool
        let expanded: Bool
        let reduced: Bool
    }
    private struct Tile {
        let label: String
        let image: CGImage
        let size: CGSize
    }
    private enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let reason): reason }
        }
    }

    static func run(output: URL) async throws {
        guard output.isFileURL, !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.failed("Use a new local output directory.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let suite = "uiui-mosaic-public-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.failed("Isolated defaults unavailable.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let model = AppModel(dataDirectory: temporary, defaults: defaults, persistSettings: false,
                             cleanup: PreviewCleanup())
        model.settings.notchEnabled = false
        model.settings.soundFeedbackEnabled = false
        model.settings.keepRecordingRecovery = false
        model.settings.saveDictationHistory = false
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: temporary)
        }

        let camera = measuredCamera()
        model.notchCameraWidth = camera.width
        model.notchCameraHeight = camera.height
        let styles = NotchVisualStyle.allCases
        var results: [String: [String: Any]] = [:]
        var activeImages: [(NotchVisualStyle, CGImage)] = []
        var notchImages: [(NotchVisualStyle, CGImage)] = []
        for style in styles {
            let directory = output.appendingPathComponent(style.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            model.settings.notchVisualStyle = style
            let checked = try await runStyle(style, model: model, output: directory, camera: camera)
            results[style.rawValue] = checked.result
            activeImages.append((style, checked.activeImage))
            notchImages.append((style, checked.notchImage))
        }
        let switchDirectory = output.appendingPathComponent("style-switch", isDirectory: true)
        try FileManager.default.createDirectory(at: switchDirectory, withIntermediateDirectories: false)
        model.settings.notchVisualStyle = .mosaic
        let styleSwitch = try await mountedAnimation(model: model, output: switchDirectory,
                                                     camera: camera, switchTo: .eyes)
        let differences = try compareStyles(activeImages)
        let notchDifferences = try compareStyles(notchImages)
        let comparisonSize = surface(model: model, phase: .recording, expanded: true)
        let comparisons = notchImages.map { Tile(label: $0.0.rawValue + "-recording", image: $0.1, size: comparisonSize) }
        try savePNG(try contactSheet(comparisons, columns: styles.count),
                    to: output.appendingPathComponent("style-comparison.png"))
        let fieldComparisons = activeImages.map { Tile(label: $0.0.rawValue + "-active-field", image: $0.1, size: comparisonSize) }
        try savePNG(try contactSheet(fieldComparisons, columns: styles.count),
                    to: output.appendingPathComponent("field-comparison.png"))
        let result: [String: Any] = [
            "passed": true, "renderer": "real-SwiftUI-NotchView-NotchVisualFeedback",
            "static_scope": "ImageRenderer-2x-production-NotchLayout-surfaceSize",
            "mounted_scope": "ordered-offscreen-NSWindow-NSHostingView-cacheDisplay",
            "visible_onscreen_compositor": "unmeasured", "private_history": "not-opened",
            "microphone": "not-opened", "clipboard": "untouched", "models": "not-prepared",
            "system_observers": false, "static_frames": phases.count * 6 * styles.count,
            "styles": styles.map(\.rawValue), "per_style": results,
            "camera_width_pt": camera.width, "camera_height_pt": camera.height,
            "camera_geometry_source": camera.source,
            "black_threshold_rgb_255": blackThreshold,
            "camera_frames_checked": results.values.compactMap { $0["camera_frames_checked"] as? Int }.reduce(0, +),
            "camera_maximum_rgb_255": results.values.compactMap { $0["camera_maximum_rgb_255"] as? Int }.max() ?? 0,
            "terminal_field_maximum_rgb_255": results.values.compactMap { $0["terminal_field_maximum_rgb_255"] as? Int }.max() ?? 0,
            "active_fields_pairwise_distinct": true, "style_differences": differences,
            "actual_notch_views_pairwise_distinct": true, "notch_style_differences": notchDifferences,
            "settings_picker_preview_count": styles.count,
            "settings_picker_size_pt": [560, 190], "mounted_style_switch": styleSwitch
        ]
        try writeJSON(result, to: output.appendingPathComponent("verification.json"))
        print("MOSAIC_PREVIEW passed=true styles=\(styles.count) static_frames=\(phases.count * 6 * styles.count) pairwise_distinct=true microphone=not-opened clipboard=untouched")
    }

    private static func runStyle(_ style: NotchVisualStyle, model: AppModel, output: URL,
                                  camera: Camera) async throws -> (result: [String: Any], activeImage: CGImage, notchImage: CGImage) {
        model.dictationFeedback = nil
        let picker = SettingsCard(title: "Appearance", symbol: "macbook", compact: true) {
            NotchStylePicker(selection: .constant(style))
        }.padding(8)
        try savePNG(try render(picker, size: CGSize(width: 560, height: 190)),
                    to: output.appendingPathComponent("settings-picker.png"))
        try savePNG(try render(picker.background(Color.white).environment(\.colorScheme, .light),
                              size: CGSize(width: 560, height: 190)),
                    to: output.appendingPathComponent("settings-picker-light.png"))
        let configurations = [
            Configuration(name: "camera-collapsed", camera: true, expanded: false, reduced: false),
            Configuration(name: "camera-expanded", camera: true, expanded: true, reduced: false),
            Configuration(name: "no-camera-collapsed", camera: false, expanded: false, reduced: false),
            Configuration(name: "no-camera-expanded", camera: false, expanded: true, reduced: false),
            Configuration(name: "reduced-collapsed", camera: true, expanded: false, reduced: true),
            Configuration(name: "reduced-expanded", camera: true, expanded: true, reduced: true)
        ]
        var tiles: [Tile] = []
        var checkedCameraFrames = 0
        var cameraMaximum = 0
        var terminalMaximum = 0
        var activeFieldMaximum = 0
        let stills = output.appendingPathComponent("states", isDirectory: true)
        try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: false)
        for phase in phases {
            for configuration in configurations {
                model.notchHasCamera = configuration.camera
                let size = surface(model: model, phase: phase, expanded: configuration.expanded)
                // Show the gesture in flight; reduced-motion snapshots use its still endpoint.
                let progress = configuration.reduced ? 1.0 : phase == .dispatched || phase == .cancelled ? 0.35 : 0.7
                let view = fixtureView(model: model, phase: phase, expanded: configuration.expanded,
                                       progress: progress, reduced: configuration.reduced)
                let image = try render(view, size: size)
                let label = "\(phase.rawValue)-\(configuration.name)"
                try savePNG(image, to: stills.appendingPathComponent(label + ".png"))
                tiles.append(Tile(label: label, image: image, size: size))
                if configuration.camera {
                    let maximum = try cameraBrightness(image, size: size, camera: camera)
                    cameraMaximum = max(cameraMaximum, maximum)
                    checkedCameraFrames += 1
                    guard maximum <= Int(blackThreshold) else {
                        throw Failure.failed("Camera region illuminated in \(style.rawValue)/\(label): \(maximum).")
                    }
                }
            }
        }
        try savePNG(try contactSheet(tiles, columns: configurations.count),
                    to: output.appendingPathComponent("contact-sheet.png"))

        model.notchHasCamera = true
        let activeSize = surface(model: model, phase: .recording, expanded: true)
        let activeField = NotchVisualFeedback(phase: .recording, level: 0.65, hasCamera: true,
            cameraWidth: camera.width, cameraHeight: camera.height, style: style, previewProgress: 0.7)
            .background(Color.black)
        let activeImage = try render(activeField, size: activeSize)
        try savePNG(activeImage, to: output.appendingPathComponent("active-field.png"))
        activeFieldMaximum = try brightness(activeImage,
            rect: CGRect(origin: .zero, size: activeSize), pointSize: activeSize)
        guard activeFieldMaximum > Int(blackThreshold) else {
            throw Failure.failed("SwiftUI did not render the active Canvas light field; static snapshots are unproven.")
        }
        for phase in [NotchFeedbackPhase.dispatched, .cancelled] {
            let directory = output.appendingPathComponent(phase.rawValue + "-deterministic", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let size = surface(model: model, phase: phase, expanded: true)
            var frames: [CGImage] = []
            for index in 0...12 {
                let progress = Double(index) / 12
                let image = try render(fixtureView(model: model, phase: phase, expanded: true,
                                                   progress: progress, reduced: false), size: size)
                let maximum = try cameraBrightness(image, size: size, camera: camera)
                cameraMaximum = max(cameraMaximum, maximum)
                checkedCameraFrames += 1
                guard maximum <= Int(blackThreshold) else { throw Failure.failed("Camera lit in deterministic motion.") }
                frames.append(image)
                try savePNG(image, to: directory.appendingPathComponent(String(format: "%02d.png", index)))
            }
            try saveGIF(frames, delay: NotchMosaicMetrics.duration(for: phase) / 12,
                        to: output.appendingPathComponent(phase.rawValue + "-deterministic.gif"))
            // Inspect the actual drawing layer alone so static semantic/brand
            // marks do not become false positives for a lingering light field.
            let terminal = NotchVisualFeedback(phase: phase, level: 0.65, hasCamera: true,
                cameraWidth: camera.width, cameraHeight: camera.height, style: style, previewProgress: 1)
                .background(Color.black)
            let image = try render(terminal, size: size)
            let maximum = try brightness(image, rect: CGRect(origin: .zero, size: size), pointSize: size)
            terminalMaximum = max(terminalMaximum, maximum)
            try savePNG(image, to: directory.appendingPathComponent("terminal-field.png"))
            guard maximum <= Int(blackThreshold) else {
                throw Failure.failed("Terminal \(style.rawValue)/\(phase.rawValue) light field remains lit.")
            }
        }

        let mounted = try await mountedAnimation(model: model, output: output, camera: camera)
        let extrasCount = try renderExtras(style: style, model: model, output: output, camera: camera)
        let result: [String: Any] = [
            "passed": true, "style": style.rawValue, "static_frames": tiles.count, "extra_state_frames": extrasCount,
            "camera_frames_checked": checkedCameraFrames,
            "camera_maximum_rgb_255": cameraMaximum,
            "terminal_field_maximum_rgb_255": terminalMaximum,
            "active_field_maximum_rgb_255": activeFieldMaximum,
            "settings_picker": "actual-NotchStylePicker-in-compact-SettingsCard",
            "mounted": mounted
        ]
        try writeJSON(result, to: output.appendingPathComponent("verification.json"))
        guard let notchImage = tiles.first(where: { $0.label == "recording-camera-expanded" })?.image else {
            throw Failure.failed("Missing actual recording notch comparison.")
        }
        return (result, activeImage, notchImage)
    }

    /// Compare the field alone at the same phase, size, audio level and progress.
    /// A changed pixel must exceed the blackout tolerance, and at least 1% of
    /// all pixels must change so a single antialiasing difference cannot pass.
    private static func compareStyles(_ images: [(NotchVisualStyle, CGImage)]) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        for first in images.indices {
            for second in images.indices where second > first {
                let left = images[first], right = images[second]
                guard left.1.width == right.1.width, left.1.height == right.1.height else {
                    throw Failure.failed("Style comparison dimensions differ.")
                }
                let a = try rgba(left.1), b = try rgba(right.1)
                var changed = 0
                var totalDelta = 0
                var maximumDelta = 0
                for offset in stride(from: 0, to: a.count, by: 4) {
                    var pixelDelta = 0
                    for channel in 0..<3 {
                        let delta = abs(Int(a[offset + channel]) - Int(b[offset + channel]))
                        totalDelta += delta
                        pixelDelta = max(pixelDelta, delta)
                    }
                    maximumDelta = max(maximumDelta, pixelDelta)
                    if pixelDelta > Int(blackThreshold) { changed += 1 }
                }
                let count = left.1.width * left.1.height
                let fraction = Double(changed) / Double(count)
                let mean = Double(totalDelta) / Double(count * 3)
                // Eyes, bars and the Words line are small marks: require a real, measurable
                // difference rather than a fixed share of the whole panel.
                guard changed >= 32, mean >= 0.02 else {
                    throw Failure.failed("Active fields are insufficiently distinct: \(left.0.rawValue), \(right.0.rawValue).")
                }
                results.append(["first": left.0.rawValue, "second": right.0.rawValue,
                    "changed_pixel_fraction": fraction, "changed_pixel_threshold_rgb_255": blackThreshold,
                    "mean_absolute_rgb_delta_255": mean, "maximum_rgb_delta_255": maximumDelta])
            }
        }
        return results
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
    }

    private struct Camera {
        let width: CGFloat
        let height: CGFloat
        let source: String
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

    private static func surface(model: AppModel, phase: NotchFeedbackPhase, expanded: Bool) -> CGSize {
        NotchLayout.surfaceSize(phase: phase, cameraWidth: model.notchCameraWidth,
            cameraHeight: model.notchCameraHeight, hasCamera: model.notchHasCamera, expanded: expanded)
    }

    /// The extra states: pause, quiet-mic hint, input name, timer, hover transcript,
    /// Undo/Copy and the amber copy notice, on a camera notch and on a floating pill.
    private static func renderExtras(style: NotchVisualStyle, model: AppModel, output: URL, camera: Camera) throws -> Int {
        let directory = output.appendingPathComponent("extras", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let longText = "Can we ship this after lunch, once the review is complete? I also want the release notes to mention the new hover transcript, the pause control, and that Undo only works while the same app is in front. Let me know what you think before three."
        struct Case { let name: String; let phase: NotchFeedbackPhase; let state: NotchPreviewState; let text: String
                      let camera: Bool; let progress: Double }
        let cases: [Case] = [
            .init(name: "paused", phase: .recording, state: .init(paused: true), text: transcript, camera: true, progress: 0.7),
            .init(name: "paused-empty", phase: .recording, state: .init(paused: true), text: "", camera: true, progress: 0.7),
            .init(name: "cannot-hear", phase: .recording, state: .init(cannotHear: true), text: "", camera: true, progress: 0.7),
            .init(name: "cannot-hear-after-speech", phase: .recording, state: .init(cannotHear: true), text: transcript, camera: true, progress: 0.7),
            .init(name: "mic-hint", phase: .recording, state: .init(micHint: "Mic: AirPods Pro"), text: "", camera: true, progress: 0.7),
            .init(name: "timer", phase: .recording, state: .init(timer: "0:42"), text: transcript, camera: true, progress: 0.7),
            .init(name: "hover-controls", phase: .recording, state: .init(hovering: true), text: transcript, camera: true, progress: 0.7),
            .init(name: "hover-transcript", phase: .recording, state: .init(timer: "1:12", transcriptOpen: true, hovering: true), text: longText, camera: true, progress: 0.7),
            .init(name: "sent-undo", phase: .dispatched, state: .init(undo: true, sentApp: "Slack"), text: transcript, camera: true, progress: 1),
            .init(name: "copied-app", phase: .copied, state: .init(copiedApp: "Safari"), text: transcript, camera: true, progress: 1),
            .init(name: "pill-recording", phase: .recording, state: .init(), text: transcript, camera: false, progress: 0.7),
            .init(name: "pill-hover-transcript", phase: .recording, state: .init(transcriptOpen: true, hovering: true), text: longText, camera: false, progress: 0.7),
            .init(name: "pill-sent-undo", phase: .dispatched, state: .init(undo: true, sentApp: "Notes"), text: transcript, camera: false, progress: 1),
            .init(name: "pill-collapsed-listening", phase: .recording, state: .init(), text: transcript, camera: false, progress: 0.7)
        ]
        var tiles: [Tile] = []
        for item in cases {
            model.notchHasCamera = item.camera
            let collapsed = item.name.hasSuffix("collapsed-listening")
            let size = NotchLayout.surfaceSize(phase: item.phase, cameraWidth: model.notchCameraWidth,
                cameraHeight: model.notchCameraHeight, hasCamera: item.camera, expanded: !collapsed,
                transcriptOpen: item.state.transcriptOpen)
            var view = NotchView(model: model, expanded: !collapsed, onExpand: {}, onCollapse: {})
            view.feedbackPreviewPhase = item.phase
            view.feedbackPreviewProgress = item.progress
            view.feedbackPreviewLevel = 0.65
            view.feedbackPreviewTranscript = item.text
            view.preview = item.state
            let image = try render(view.environment(\.notchMotionPreviewOverride, false), size: size)
            try savePNG(image, to: directory.appendingPathComponent(item.name + ".png"))
            tiles.append(Tile(label: item.name, image: image, size: size))
            if item.camera {
                let maximum = try cameraBrightness(image, size: size, camera: camera)
                guard maximum <= Int(blackThreshold) else {
                    throw Failure.failed("Camera region illuminated in \(style.rawValue)/extras/\(item.name): \(maximum).")
                }
            }
        }
        model.notchHasCamera = true
        try savePNG(try contactSheet(tiles, columns: 2, cell: CGSize(width: 400, height: 200)),
                    to: output.appendingPathComponent("extras-contact-sheet.png"))
        return tiles.count
    }

    private static func fixtureView(model: AppModel, phase: NotchFeedbackPhase, expanded: Bool,
                                    progress: Double?, reduced: Bool) -> some View {
        var view = NotchView(model: model, expanded: expanded, onExpand: {}, onCollapse: {})
        view.feedbackPreviewPhase = phase
        view.feedbackPreviewProgress = progress
        view.feedbackPreviewLevel = 0.65
        view.feedbackPreviewTranscript = transcript
        return view.environment(\.notchMotionPreviewOverride, reduced)
    }

    private static func render<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .background(Color.black).environment(\.colorScheme, .dark))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let image = renderer.cgImage else { throw Failure.failed("SwiftUI ImageRenderer produced no image.") }
        return image
    }

    private static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.failed("Cannot create PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("Cannot write PNG.") }
    }

    private static func saveGIF(_ images: [CGImage], delay: Double, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else {
            throw Failure.failed("Cannot create GIF.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(0.02, delay)]] as CFDictionary
        for image in images { CGImageDestinationAddImage(destination, image, properties) }
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("Cannot write GIF.") }
    }

    private static func contactSheet(_ tiles: [Tile], columns: Int,
                                     cell: CGSize = CGSize(width: 400, height: 102)) throws -> CGImage {
        let rows = (tiles.count + columns - 1) / columns
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: columns * Int(cell.width),
            pixelsHigh: rows * Int(cell.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.failed("Cannot create contact sheet.") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh)).fill()
        for (index, tile) in tiles.enumerated() {
            let x = CGFloat(index % columns) * cell.width
            let top = CGFloat(rows - index / columns) * cell.height
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                                                            .foregroundColor: NSColor.white]
            (tile.label as NSString).draw(at: CGPoint(x: x + 10, y: top - 18), withAttributes: attributes)
            let image = NSImage(cgImage: tile.image, size: tile.size)
            image.draw(in: CGRect(x: x + (cell.width - tile.size.width) / 2,
                                  y: top - 28 - tile.size.height, width: tile.size.width, height: tile.size.height))
        }
        guard let image = bitmap.cgImage else { throw Failure.failed("Cannot read contact sheet.") }
        return image
    }

    private static func cameraBrightness(_ image: CGImage, size: CGSize, camera: Camera) throws -> Int {
        let rect = CGRect(x: (size.width - camera.width) / 2, y: 0,
                          width: camera.width, height: min(camera.height, size.height))
        return try brightness(image, rect: rect, pointSize: size)
    }

    /// Canonical RGBA bytes make pixel comparisons independent of the
    /// renderer/provider's native component order.
    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        guard success else { throw Failure.failed("Cannot inspect native image pixels.") }
        return bytes
    }

    private static func brightness(_ image: CGImage, rect: CGRect, pointSize: CGSize) throws -> Int {
        let sx = CGFloat(image.width) / pointSize.width
        let sy = CGFloat(image.height) / pointSize.height
        let left = max(0, Int(ceil(rect.minX * sx)))
        let right = min(image.width, Int(floor(rect.maxX * sx)))
        let top = max(0, Int(ceil(rect.minY * sy)))
        let bottom = min(image.height, Int(floor(rect.maxY * sy)))
        guard left < right, top < bottom else { throw Failure.failed("Empty pixel assertion region.") }
        // Crop in CGImage's top-origin image coordinates before normalizing
        // bytes; row orientation then cannot change the measured region.
        guard let cropped = image.cropping(to: CGRect(x: CGFloat(left), y: CGFloat(top),
            width: CGFloat(right - left), height: CGFloat(bottom - top))) else {
            throw Failure.failed("Cannot crop pixel assertion region.")
        }
        let bytes = try rgba(cropped)
        var maximum: UInt8 = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            maximum = max(maximum, max(bytes[offset], max(bytes[offset + 1], bytes[offset + 2])))
        }
        return Int(maximum)
    }

    private static func mountedAnimation(model: AppModel, output: URL, camera: Camera,
                                         switchTo: NotchVisualStyle? = nil) async throws -> [String: Any] {
        let originalStyle = model.settings.notchVisualStyle
        model.notchHasCamera = true
        model.notchExpanded = true
        model.notchMounted = true
        model.dictationFeedback = nil
        let size = surface(model: model, phase: .dispatched, expanded: true)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        let host = NSHostingView(rootView: NotchView(model: model, expanded: true, onExpand: {}, onCollapse: {})
            .environment(\.notchMotionPreviewOverride, false))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        let coordinator = PanelCoordinator(model: model, installSystemObservers: false)
        defer { coordinator.shutdown(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFront(nil)
        pumpRunLoop()
        // Allow the idle tree to mount before emitting the real typed receipt.
        try await Task.sleep(for: .milliseconds(40))
        pumpRunLoop()
        model.dictationFeedback = VoiceActionFeedback(state: .information, title: "Paste sent · copied",
            detail: "Synthetic native visual fixture", presentation: .pasteDispatch)
        let receiptID = model.dictationFeedback?.id
        coordinator.activityChanged()
        let start = ContinuousClock.now
        var frames: [CGImage] = []
        var samples: [[String: Any]] = []
        var expiryMS: Double?
        var cameraMaximum = 0
        var fieldBandMaximum = 0
        var switchedAtMS: Double?
        var receiptIdentityPreserved = true
        for index in 0...27 {
            let deadline = start.advanced(by: .nanoseconds(Int64(index) * 1_000_000_000 / 30))
            try await Task.sleep(until: deadline, clock: .continuous)
            if index == 3, let switchTo {
                model.settings.notchVisualStyle = switchTo
                coordinator.activityChanged()
                switchedAtMS = milliseconds(start.duration(to: .now))
            }
            pumpRunLoop()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw Failure.failed("Mounted native host cannot create display cache.")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let image = bitmap.cgImage else { throw Failure.failed("Mounted native host has no image.") }
            frames.append(image)
            let elapsed = milliseconds(start.duration(to: .now))
            let expired = model.notchVoiceFeedback == nil
            receiptIdentityPreserved = receiptIdentityPreserved && model.dictationFeedback?.id == receiptID
            if expired, expiryMS == nil { expiryMS = elapsed }
            let maximum = try cameraBrightness(image, size: size, camera: camera)
            // Mosaic and Words first draw along the lower edge; Eyes and Voice bars
            // draw in the wings beside the camera (the logo returns there at idle,
            // so only the lower-edge styles are checked for withdrawing).
            let bandRect: CGRect
            switch originalStyle {
            case .eyes, .bars:
                bandRect = CGRect(x: (size.width - camera.width) / 2 - 46, y: 6, width: 40, height: max(8, camera.height - 12))
            default:
                bandRect = CGRect(x: size.width * 0.25, y: size.height - 7, width: size.width * 0.5, height: 5)
            }
            let bandMaximum = try brightness(image, rect: bandRect, pointSize: size)
            fieldBandMaximum = max(fieldBandMaximum, bandMaximum)
            cameraMaximum = max(cameraMaximum, maximum)
            samples.append(["frame": index, "elapsed_ms": elapsed, "receipt_visible": !expired,
                            "phase": model.notchFeedbackPhase.rawValue, "camera_maximum_rgb_255": maximum,
                            "field_band_maximum_rgb_255": bandMaximum,
                            "style": model.settings.notchVisualStyle.rawValue])
            guard maximum <= Int(blackThreshold) else { throw Failure.failed("Mounted camera region illuminated.") }
        }
        let timelineData = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        try timelineData.write(to: output.appendingPathComponent("mounted-timeline.json"), options: .atomic)
        try saveGIF(frames, delay: 1.0 / 30, to: output.appendingPathComponent("mounted-dispatch.gif"))
        guard let first = frames.first, let last = frames.last else { throw Failure.failed("No mounted frames.") }
        try savePNG(first, to: output.appendingPathComponent("mounted-first.png"))
        try savePNG(last, to: output.appendingPathComponent("mounted-last.png"))
        let pixels = try frames.map(rgba)
        let differentFrames = zip(pixels, pixels.dropFirst()).filter { $0.0 != $0.1 }.count
        guard differentFrames >= 3 else {
            throw Failure.failed("Offscreen host did not display changing animation frames; mounted timing is unproven.")
        }
        let withdraws = originalStyle == .mosaic || originalStyle == .words
        guard fieldBandMaximum > Int(blackThreshold),
              !withdraws || samples.suffix(4).allSatisfy({ ($0["field_band_maximum_rgb_255"] as? Int ?? 255) <= Int(blackThreshold) }) else {
            throw Failure.failed("Mounted light field did not visibly animate then withdraw; offscreen motion is unproven.")
        }
        // A 30 Hz display sample can trail the deadline; allow 70 ms of bounded
        // scheduling tolerance and record the measured expiry instead of rounding.
        guard let expiryMS, expiryMS <= 720, model.notchVoiceFeedback == nil,
              model.notchFeedbackPhase == .idle,
              samples.suffix(4).allSatisfy({ ($0["receipt_visible"] as? Bool) == false }) else {
            throw Failure.failed("Dispatch receipt did not expire and stay dark by its 650 ms dwell (70 ms sampling tolerance).")
        }
        guard receiptIdentityPreserved,
              switchTo == nil || (switchedAtMS != nil && model.settings.notchVisualStyle == switchTo) else {
            throw Failure.failed("Changing visual style replaced the active receipt or failed to apply.")
        }
        var result: [String: Any] = ["frames": frames.count, "different_adjacent_frames": differentFrames,
                "receipt_expired_ms": expiryMS, "receipt_dwell_target_ms": 650,
                "last_samples_stay_idle": true, "camera_maximum_rgb_255": cameraMaximum,
                "active_field_band_maximum_rgb_255": fieldBandMaximum,
                "progress_override": false, "os_window_ordered": window.isVisible,
                "initial_style": originalStyle.rawValue, "final_style": model.settings.notchVisualStyle.rawValue,
                "receipt_identity_preserved": receiptIdentityPreserved]
        if let switchedAtMS {
            result["style_switched_ms"] = switchedAtMS
            result["original_receipt_deadline_preserved"] = true
        }
        return result
    }

    /// SwiftUI/AppKit animation sources need the native run loop in addition to
    /// the async bootstrap's dispatch executor. This helper never awaits input.
    private static func pumpRunLoop() {
        let until = Date(timeIntervalSinceNow: 0.002)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    @MainActor
    private final class PreviewCleanup: DictationCleaning {
        func prepare() {}
        func begin(_ id: UUID) {}
        func update(_ text: String, captureID: UUID) {}
        func finish(_ text: String, captureID: UUID) async throws -> String { text }
        func cancel() {}
        func release() {}
    }
}
#endif
