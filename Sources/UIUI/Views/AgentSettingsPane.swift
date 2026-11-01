import AppKit
import SwiftUI
import UIUICore

/// Everything about agents, in one place: what it is, how to connect, how to try it.
struct AgentSettingsPane: View {
    @Bindable var model: AppModel
    @State private var agents = AgentConnections.known()
    @State private var issue: String?
    @State private var copied = false

    private var installed: [AgentConnection] { agents.filter(\.isInstalled) }

    var body: some View {
        SettingsCard(title: "Let your agent ask you", symbol: "questionmark.bubble", compact: true) {
            Text("uiui has no agent of its own. This lets the coding agent you already use ask you a question in the notch, and you answer out loud from any app, without going back to the terminal.")
                .font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            Toggle(isOn: $model.settings.agentAskEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let agents ask you").font(.system(size: 12, weight: .medium))
                    Text("Hold \(model.agentAnswerKey.title) to answer, or tap it to talk for longer. Only your press opens the microphone.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            if model.settings.agentAskEnabled {
                Button("Send a test question") { model.sendTestAgentQuestion() }
                    .controlSize(.small).help("Shows a question in the notch. Your answer goes nowhere.")
            }
        }
        SettingsCard(title: "Connect your agents", symbol: "link", compact: true) {
            Text("Connecting adds a small skill to that agent, which teaches it the uiui ask command. It isn't a plugin or a server, and there's no account or login.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if installed.isEmpty {
                Text("No Claude Code, Codex or OpenCode found on this Mac.").font(.system(size: 12))
            }
            ForEach(installed) { agent in
                HStack {
                    Text(agent.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    if agent.isConnected {
                        Label("Connected", systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Disconnect") { change { try AgentConnections.disconnect(agent) } }.controlSize(.small)
                    } else {
                        Button("Connect") { change { try AgentConnections.connect(agent) } }.controlSize(.small)
                    }
                }
            }
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("A new agent session picks it up. You can also just tell your agent to use uiui ask.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Using another agent?").font(.system(size: 12, weight: .medium))
                Text("Copy these instructions into its instructions file.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button(copied ? "Copied" : "Copy instructions") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentConnections.instructions(commandPath: AgentConnections.commandPath), forType: .string)
                    copied = true
                }.controlSize(.small)
            }
        }
        SettingsCard(title: "What your agent gets", symbol: "lock", compact: true) {
            Text("Only the words you say in answer, as text. Your answer may then go to that agent's own service, which is up to the agent. uiui doesn't keep questions or answers in History, and agents can't read your dictations or open the microphone.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func change(_ action: () throws -> Void) {
        do { try action(); issue = nil }
        catch { issue = "That didn't work. A skill named \(AgentConnections.skillName) may already exist, and uiui won't overwrite it." }
        agents = AgentConnections.known()
    }
}
