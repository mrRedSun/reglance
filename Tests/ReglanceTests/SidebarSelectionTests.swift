import AppKit
import SwiftUI
import Testing
@testable import Reglance

@MainActor
@Test func sidebarIconsHaveContrastOnSelectedBackgrounds() throws {
    for isDestination in [true, false] {
        let row = SidebarRow(title: "Archive", systemImage: "archivebox", isDestination: isDestination)
            .frame(width: 260)
            .foregroundStyle(.white)
            .background(Color.blue)
            .environment(\.backgroundProminence, .increased)
            .environment(\.colorScheme, .light)
        let image = try #require(ImageRenderer(content: row).cgImage)
        let stride = image.width * 4
        var pixels = [UInt8](repeating: 0, count: stride * image.height)
        try pixels.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height,
                                                bitsPerComponent: 8, bytesPerRow: stride,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        // The icon owns the first 20pt column. The title starts at 30pt, outside
        // this crop, so white text can't hide a blue-on-blue icon regression.
        let whiteIconPixels = (0..<image.height).reduce(0) { count, y in
            count + (0..<min(20, image.width)).filter { x in
                let offset = y * stride + x * 4
                return pixels[offset] > 220 && pixels[offset + 1] > 220 && pixels[offset + 2] > 220
            }.count
        }
        #expect(whiteIconPixels > 8, "Selected sidebar icon must contrast with its blue background")
    }
}
