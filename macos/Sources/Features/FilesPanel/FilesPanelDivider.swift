import SwiftUI

struct FilesPanelDivider: View {
    @Binding var width: Double
    @State private var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .contentShape(Rectangle().inset(by: -3))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartWidth ?? width
                        dragStartWidth = start
                        width = min(max(start - value.translation.width, 220), 480)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel("Resize Files Panel")
    }
}
