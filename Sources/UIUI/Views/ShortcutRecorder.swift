import AppKit
import SwiftUI
import UIUICore

/// Records the voice trigger from one key press inside uiui's own window: a lone
/// modifier (tap and release it) or any key with modifiers. The local monitor
/// exists only while recording and consumes what it reads; nothing is stored
/// except the chosen key code, modifiers and the key's printed label.
struct ShortcutRecorder: View {
    @Bindable var model: AppModel
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?
    @State private var issue: String?

    private var recording: Bool { monitor != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(recording ? "Press a key or combination…" : model.settings.voiceTriggerKey.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(recording ? .secondary : .primary)
                    .padding(.horizontal, 12).frame(minWidth: 170, minHeight: 30, alignment: .leading)
                    .background(.primary.opacity(recording ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(recording ? UIUIStyle.accent : Color.primary.opacity(0.12), lineWidth: recording ? 1.5 : 0.75)
                    }
                    .accessibilityLabel(recording ? "Recording shortcut" : "Voice shortcut \(model.settings.voiceTriggerKey.title)")
                Button(recording ? "Cancel" : "Record shortcut…") { recording ? stop() : start() }
                    .disabled(model.voiceIsRecording)
                Menu("Presets") {
                    ForEach(VoiceTriggerKey.presets) { key in
                        Button(key.title) { stop(); choose(key) }
                    }
                }.fixedSize().disabled(model.voiceIsRecording)
            }
            Text(issue ?? (recording
                ? "Tap a single modifier such as Fn or Right ⌘, or press a combination such as ⌃⌥Space or F5. Esc cancels."
                : "Any single modifier key, function key or key combination works."))
                .font(.system(size: 10)).foregroundStyle(issue == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { stop() }
    }

    private func choose(_ key: VoiceTriggerKey) {
        issue = nil
        model.settings.voiceTriggerKey = key
    }

    private func start() {
        issue = nil
        pendingModifier = nil
        model.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
        if model.isRecordingShortcut { model.isRecordingShortcut = false }
    }

    private static let modifierFlags: [UInt16: NSEvent.ModifierFlags] = [
        63: .function, 59: .control, 62: .control, 58: .option, 61: .option,
        55: .command, 54: .command, 56: .shift, 60: .shift
    ]

    private func handle(_ event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        if event.type == .flagsChanged {
            guard let flag = Self.modifierFlags[event.keyCode] else { return }
            if held.contains(flag) {
                // A lone modifier going down becomes a candidate; a second
                // modifier means the user is building a combination instead.
                pendingModifier = held == flag && pendingModifier == nil ? event.keyCode : nil
            } else if pendingModifier == event.keyCode {
                stop()
                choose(VoiceTriggerKey(keyCode: event.keyCode))
            }
            return
        }
        guard event.type == .keyDown, !event.isARepeat else { return }
        pendingModifier = nil
        if event.keyCode == 53, held.subtracting(.function).isEmpty { stop(); return }
        var modifiers: VoiceTriggerKey.Modifiers = []
        if held.contains(.command) { modifiers.insert(.command) }
        if held.contains(.option) { modifiers.insert(.option) }
        if held.contains(.control) { modifiers.insert(.control) }
        if held.contains(.shift) { modifiers.insert(.shift) }
        let key = VoiceTriggerKey(keyCode: event.keyCode, modifiers: modifiers, label: event.charactersIgnoringModifiers)
        if let reason = key.unsuitableReason { issue = reason; return }
        stop()
        choose(key)
    }
}

/// A compact physical-key hint; the full key name stays available to accessibility.
struct VoiceTriggerKeycap: View {
    let key: VoiceTriggerKey
    var body: some View {
        HStack(spacing: 4) {
            if key == .fn {
                Text("fn").font(.system(size: 10, weight: .medium))
                Image(systemName: "globe").font(.system(size: 9))
            } else if key.isModifierOnly {
                Text(key.title.hasPrefix("Left") ? "L" : "R")
                    .font(.system(size: 7, weight: .medium)).foregroundStyle(.tertiary)
                Image(systemName: key.symbol).font(.system(size: 11, weight: .medium))
            } else {
                Text(key.title).font(.system(size: 10, weight: .medium, design: .rounded))
            }
        }.foregroundStyle(.primary.opacity(0.7))
            .padding(.horizontal, 7).frame(height: 22)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.10)) }
            .fixedSize(horizontal: true, vertical: false)
            .help(key.title).accessibilityLabel(key.title)
    }
}
