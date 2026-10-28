import SwiftUI

struct SSHConnectionOverlay: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    private var controller: BaseTerminalController? {
        surfaceView.window?.windowController as? BaseTerminalController
    }

    private var closeLabel: String {
        (controller?.surfaceTree.root?.leaves().count ?? 1) > 1 ? "Close Pane" : "Close Tab ⌘W"
    }

    var body: some View {
        if let channel = surfaceView.sshChannel, let status = surfaceView.sshStatus {
            switch status.connection {
            case .waiting:
                VStack(spacing: 12) {
                    Text(channel.alias).font(.headline)
                    if let reason = status.reconnectBlock {
                        Text(blockMessage(reason, alias: channel.alias))
                        closeButton
                    } else {
                        Text("\(channel.binding.displayDestination ?? channel.alias) · not connected")
                            .foregroundStyle(.secondary)
                        connectButton(channel, title: "Connect ↩")
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .lost(exitStatus, everConnected):
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let reason = status.reconnectBlock {
                                Text(blockMessage(reason, alias: channel.alias))
                            } else {
                                Text(everConnected ? "Connection to \(channel.alias) lost." : "Couldn't connect to \(channel.alias).")
                                Text("ssh exited with status \(exitStatus).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if status.reconnectBlock == nil {
                            connectButton(channel, title: "Reconnect ↩")
                        }
                        closeButton
                    }
                    .padding(12)
                    .background(.regularMaterial)
                }
            case .connecting, .connected:
                EmptyView()
            }
        }
    }

    private func connectButton(_ channel: SSHPaneChannel, title: String) -> some View {
        Button(title) { channel.requestConnect() }
            .accessibilityLabel(title)
    }

    private var closeButton: some View {
        Button(closeLabel) { controller?.closeSurface(surfaceView, withConfirmation: false) }
            .accessibilityLabel(closeLabel)
    }

    private func blockMessage(_ reason: SSHReconnectBlock, alias: String) -> String {
        switch reason {
        case .hostRemoved: return "\(alias) was removed from SSH hosts. Reconnecting is disabled."
        case .aliasInvalid: return "\(alias) is not a valid SSH alias. Reconnecting is disabled."
        case .configUnreadable: return "SSH configuration cannot be read. Reconnecting is disabled."
        }
    }
}
