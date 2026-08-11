import CoreGraphics
import Foundation

struct FilesPanelImageDocument: @unchecked Sendable {
    let sourcePath: String
    let image: CGImage

    var estimatedByteCost: Int {
        image.bytesPerRow * image.height
    }
}
