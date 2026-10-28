import SFTPStorage
import SwiftUI

/// Asks whether to trust a server's SSH host key the first time Ferry connects to it.
struct HostKeyPromptView: View {
    let key: SFTPHostKey
    let knownHosts: KnownHostsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Trust “\(key.host)”?")
                    .font(.headline)
            } icon: {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(.orange)
            }
            Text("Trust this server only if the fingerprint matches the one from its administrator.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(key.algorithm) {
                Text(key.fingerprint)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { knownHosts.answer(trust: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust") { knownHosts.answer(trust: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}
