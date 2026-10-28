import SwiftUI

struct SSHTabBadge: View {
    var body: some View {
        Text("SSH")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("SSH")
    }
}
