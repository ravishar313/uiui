#if DEBUG
import AppKit
import SwiftUI
import UIUICore

/// Debug-only visual check of Settings and the setup guide. Uses an isolated
/// settings suite, a throwaway data directory and invented dictionary words.
/// No repository, keychain, microphone, shortcut or user data is opened.
@MainActor
enum SettingsNativeSmoke {
    private struct Frame { let name: String; let size: CGSize; let make: (AppModel) -> AnyView }

    static func run(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suiteName = "uiui.settings-preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = AppModel(dataDirectory: scratch, defaults: defaults, persistSettings: false)
        model.settings.vocabulary = [
            VocabularyEntry(heard: "priya", replacement: "Priya"),
            VocabularyEntry(heard: "q three", replacement: "Q3"),
            VocabularyEntry(heard: "ship it", replacement: "ship it", project: "Launch")
        ]
        model.settings.customProjects = ["Personal", "Launch"]
        model.settings.trackpadFeedbackEnabled = true
        model.speechPreparationStatus = "Ready · local transcription. Press your voice key to start."

        var frames: [Frame] = SettingsPane.allCases.map { pane in
            Frame(name: "settings-\(pane.rawValue)", size: CGSize(width: 600, height: 540)) { model in
                AnyView(SettingsView(model: model, pane: pane))
            }
        }
        for step in OnboardingView.Step.allCases {
            frames.append(Frame(name: "setup-\(step.rawValue)-\(step.title.lowercased().replacingOccurrences(of: " ", with: "-"))", size: CGSize(width: 620, height: 600)) { model in
                AnyView(OnboardingView(model: model, initialStep: step, onFinish: {}))
            })
        }
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for frame in frames {
                model.lastTypedText = ""
                let image = try await render(frame, model: model, appearance: appearance, dictated: frame.name.hasPrefix("setup-6") ? "Kal Rahul se baat karo, then send the Q3 deck to Priya." : nil)
                let url = output.appendingPathComponent("\(frame.name)-\(scheme).png")
                try image.write(to: url)
                print("SETTINGS_PREVIEW wrote \(url.lastPathComponent)")
            }
        }
    }

    private struct Backdrop: View {
        let content: AnyView
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            content.background(UIUIStyle.paper(scheme))
                .tint(scheme == .dark ? UIUIStyle.lime : Color(red: 0.30, green: 0.42, blue: 0.12))
        }
    }

    private static func render(_ frame: Frame, model: AppModel, appearance: NSAppearance.Name, dictated: String?) async throws -> Data {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: frame.size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: Backdrop(content: frame.make(model)).frame(width: frame.size.width, height: frame.size.height))
        window.contentView = host
        window.setContentSize(frame.size)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        if let dictated { model.lastTypedText = dictated; try await Task.sleep(for: .milliseconds(300)) }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.orderOut(nil)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
#endif
