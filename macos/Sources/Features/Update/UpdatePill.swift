import SwiftUI

/// A pill-shaped button that displays update status and provides access to update actions.
struct UpdatePill: View {
    /// The update view model that provides the current state and information
    @ObservedObject var model: UpdateViewModel

    /// Whether the update popover is currently visible
    @State private var showPopover = false

    /// Task for auto-dismissing the "No Updates" state
    @State private var resetTask: Task<Void, Never>?

    /// Keeps the pill visible as a "Check for Updates" button while idle, so the
    /// area it occupies never appears and disappears with update state.
    var showsWhenIdle = false

    /// The font used for the pill text
    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    var body: some View {
        if showsWhenIdle, case .idle = model.state {
            idleButton
        } else if !model.state.isHidden {
            pillButton
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    UpdatePopoverView(model: model)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .onChange(of: model.state) { newState in
                    resetTask?.cancel()
                    if case .notFound(let notFound) = newState {
                        resetTask = Task {
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled, case .notFound = model.state else { return }
                            model.state = .idle
                            notFound.acknowledgement()
                        }
                    } else {
                        resetTask = nil
                    }
                }
        }
    }

    /// The pill-shaped button view that displays the update badge and text
    @ViewBuilder
    private var pillButton: some View {
        Button(action: {
            if case .notFound(let notFound) = model.state {
                model.state = .idle
                notFound.acknowledgement()
            } else {
                showPopover.toggle()
            }
        }, label: {
            HStack(spacing: 6) {
                UpdateBadge(model: model)
                    .frame(width: 14, height: 14)

                Text(model.text)
                    .font(Font(textFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(model.foregroundColor)
            .contentShape(Capsule())
        })
        .buttonStyle(.plain)
        .help(model.text)
        .accessibilityLabel(model.text)
    }

    /// The resting pill. Clicking it starts a manual update check.
    @ViewBuilder
    private var idleButton: some View {
        Button(action: {
            (NSApp.delegate as? AppDelegate)?.checkForUpdates(nil)
        }, label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .frame(width: 14, height: 14)

                Text("Check for Updates")
                    .font(Font(textFont))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(model.backgroundColor)
            )
            .foregroundColor(.secondary)
            .contentShape(Capsule())
        })
        .buttonStyle(.plain)
        .help("Check for Updates")
        .accessibilityLabel("Check for Updates")
    }

    /// Calculated width for the text to prevent resizing during progress updates
    private var textWidth: CGFloat? {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let size = (model.maxWidthText as NSString).size(withAttributes: attributes)
        return size.width
    }
}
