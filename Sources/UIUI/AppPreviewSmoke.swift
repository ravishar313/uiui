#if DEBUG
import AppKit
import ImageIO
import SwiftUI
import UIUICore
import UniformTypeIdentifiers

/// Debug-only: renders the main window screens from authored public fixture text
/// in an isolated data directory and defaults suite. It never opens the real
/// library, microphone, clipboard, shortcut or any provider.
@MainActor
enum AppPreviewSmoke {
    private enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { switch self { case .failed(let reason): reason } }
    }


    @MainActor private final class PreviewCleanup: DictationCleaning {
        func prepare() {}
        func begin(_ id: UUID) {}
        func update(_ text: String, captureID: UUID) {}
        func finish(_ text: String, captureID: UUID) async throws -> String { text }
        func cancel() {}
        func release() {}
    }

    static func run(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        // Populated model: a week of authored fixture dictations.
        let full = try await makeModel(populated: true)
        let empty = try await makeModel(populated: false)
        defer { full.cleanup(); empty.cleanup() }
        let model = full.model

        let slack = "Slack", mail = "Mail", notes = "Notes", xcode = "Xcode"
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let fixtures: [CaptureItem] = [
            item("Thanks for the update. I will review the draft this afternoon and send comments before the end of the day.", ago(18), slack),
            item("Reminder to self: book the venue for the offsite and ask the team for dietary preferences.", ago(140), notes),
            item("Hi Priya, the quarterly summary is attached. Please let me know if any of the figures need another look.", ago(300), mail),
            item("Can we move the review to Thursday morning? Zelda is out on Wednesday.", ago(60 * 27), slack),
            item("Refactor the settings view so the shortcut recorder owns its own state.", ago(60 * 30), xcode),
            item("Draft opening line: small tools that stay out of the way are the ones people keep.", ago(60 * 24 * 4), notes),
            item("A short thought with no destination app recorded.", ago(60 * 24 * 12), nil),
            item(String(repeating: "Planning notes for the next release cycle. ", count: 40), ago(60 * 24 * 3), mail),
            { var pinned = item("Pinned: the standing agenda for the Monday sync, keep it under five items.", ago(60 * 24 * 20), notes); pinned.isPinned = true; return pinned }()
        ]
        for fixture in fixtures { _ = await model.persist(fixture) }
        model.lastTypedText = fixtures[0].body
        // Unfinished recordings for the notice.
        model.settings.keepRecordingRecovery = true
        for (index, text) in ["Notes from the call, the second point about pricing was", "Remember to follow up on the invoice and"].enumerated() {
            let id = UUID()
            model.recordingRecovery.begin(id: id, project: "Personal", kind: .dictation, startedAt: ago(Double(40 + index * 90)))
            model.recordingRecovery.update(id: id, text: text)
            model.recordingRecovery.finish(id: id, preserving: true)
        }
        await model.recordingRecovery.flush()
        await model.reload()

        // The real fix flow against the isolated library.
        let target = model.items.first { $0.body.contains("Zelda") }
        var fix: HistoryWordFix?
        if let target, case .fixed(let applied) = await model.fixWord(in: target, heard: "Zelda,", correction: "Zelta") { fix = applied }
        guard let fix else { throw Failure.failed("The word fix did not apply.") }
        guard model.settings.vocabulary.contains(where: { $0.heard == "zelda" && $0.replacement == "Zelta" }),
              model.items.first(where: { $0.id == fix.after.id })?.body.contains("Zelta") == true,
              model.items.first(where: { $0.id == fix.after.id })?.rawText?.contains("Zelda") == true else {
            throw Failure.failed("The word fix was not stored.")
        }
        let fixedItem = model.items.first { $0.id == fix.after.id } ?? fix.after

        for scheme in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let name = scheme.0, appearance = NSAppearance(named: scheme.1)
            try save(render(LibraryView(model: model), size: CGSize(width: 780, height: 760), appearance: appearance), output, "home-history-\(name)")
            try save(render(LibraryView(model: empty.model), size: CGSize(width: 780, height: 560), appearance: appearance), output, "home-new-user-\(name)")
            try save(render(HistoryListView(model: model, initialAppFilter: "Slack").frame(maxHeight: 420).background(UIUIStyle.paper(name == "dark" ? .dark : .light)),
                            size: CGSize(width: 780, height: 420), appearance: appearance), output, "history-slack-filter-\(name)")
            try save(render(SavedTextView(model: model, item: fixedItem, startsInFixMode: true, previousFix: fix)
                .background(UIUIStyle.paper(name == "dark" ? .dark : .light)),
                            size: CGSize(width: 780, height: 460), appearance: appearance), output, "fix-word-\(name)")
            try save(render(FixWordForm(word: "Zelda", onCancel: {}, onSubmit: { _ in nil })
                .background(UIUIStyle.paper(name == "dark" ? .dark : .light)),
                            size: CGSize(width: 268, height: 180), appearance: appearance), output, "fix-word-popover-\(name)")
            try save(render(RecordingRecoveryReview(model: model, onDone: {}), size: CGSize(width: 540, height: 440), appearance: appearance), output, "recovery-review-\(name)")
        }

        // Menu-bar titles from the same populated model (text rendering of the menu).
        let menu = StatusMenuController(model: model, actions: .init(openWindow: {}, openSettings: {}, openSetupGuide: {}, checkForUpdates: {}, quit: {}))
        menu.prepareForInspection()
        try menu.titles.joined(separator: "\n").write(to: output.appendingPathComponent("menu-bar-titles.txt"), atomically: true, encoding: .utf8)
        print("APP_PREVIEW wrote \(output.path)")
    }

    private static func item(_ body: String, _ date: Date, _ app: String?) -> CaptureItem {
        CaptureItem(title: TextProcessing.title(for: body), body: body, kind: .dictation,
                    createdAt: date, updatedAt: date, sourceApp: app)
    }

    private struct Fixture {
        let model: AppModel
        let cleanup: () -> Void
    }

    private static func makeModel(populated: Bool) async throws -> Fixture {
        let suite = "uiui-app-preview-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.failed("Isolated defaults unavailable.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let model = AppModel(dataDirectory: directory, defaults: defaults, persistSettings: false, cleanup: PreviewCleanup())
        model.settings.notchEnabled = false
        model.settings.soundFeedbackEnabled = false
        model.settings.keepRecordingRecovery = false
        await model.start(installSystemServices: false)
        return Fixture(model: model) {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance?) throws -> CGImage {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFront(nil)
        for _ in 0..<12 {
            let until = Date(timeIntervalSinceNow: 0.02)
            while Date() < until { _ = RunLoop.main.run(mode: .default, before: until) }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.failed("No display cache.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw Failure.failed("No image.") }
        return image
    }

    private static func save(_ image: CGImage, _ directory: URL, _ name: String) throws {
        let url = directory.appendingPathComponent(name + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.failed("Cannot create PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("Cannot write PNG.") }
    }
}
#endif
