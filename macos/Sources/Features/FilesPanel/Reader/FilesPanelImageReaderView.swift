import AppKit
import SwiftUI

struct FilesPanelImageReaderView: View {
    let document: FilesPanelImageDocument
    @Binding private var mode: TerminalReaderStore.ViewState.ImageScaleMode
    @Binding private var zoom: Double

    init(
        document: FilesPanelImageDocument,
        mode: Binding<TerminalReaderStore.ViewState.ImageScaleMode> = .constant(.fit),
        zoom: Binding<Double> = .constant(1)
    ) {
        self.document = document
        self._mode = mode
        self._zoom = zoom
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Image Size", selection: $mode) {
                    ForEach(TerminalReaderStore.ViewState.ImageScaleMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                if mode == .custom {
                    Slider(value: $zoom, in: 0.1...4)
                        .frame(width: 180)
                    Text("\(Int(zoom * 100))%")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                Spacer()
                Text("\(document.image.width) × \(document.image.height)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(8)
            Divider()
            imageCanvas
        }
    }

    @ViewBuilder
    private var imageCanvas: some View {
        if mode == .fit {
            GeometryReader { proxy in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .padding(24)
            }
            .background(canvasColor)
        } else {
            ScrollView([.horizontal, .vertical]) {
                image
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: CGFloat(document.image.width) * effectiveZoom,
                        height: CGFloat(document.image.height) * effectiveZoom
                    )
                    .padding(24)
            }
            .background(canvasColor)
        }
    }

    private var image: Image {
        Image(decorative: document.image, scale: 1)
    }

    private var effectiveZoom: CGFloat {
        mode == .actual ? 1 : CGFloat(zoom)
    }

    private var canvasColor: Color {
        Color(nsColor: NSColor.windowBackgroundColor.blended(
            withFraction: 0.12,
            of: NSColor.labelColor
        ) ?? .windowBackgroundColor)
    }
}
