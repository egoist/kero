//
//  TerminalGlyphAtlas.swift
//  kero
//

import AppKit
import CoreText
import Metal
import simd

/// Rasterized glyphs packed into one Metal texture.
///
/// The GPU renderer draws a textured quad per cell, so every glyph has to
/// exist somewhere in a texture first. CoreText does the rasterizing — the
/// same path the CPU renderer used — which keeps font matching, hinting and
/// the system fallback chain identical to the rest of Kero. Only the
/// compositing moves to the GPU.
///
/// Packing is a shelf allocator: glyphs are appended along a row until it is
/// full, then a new row starts below. A monospace grid draws from a small,
/// quickly-saturating set of glyphs, so the simplest scheme that never
/// fragments badly is enough — there is no eviction, and a full atlas simply
/// stops accepting new glyphs rather than thrashing.
final class TerminalGlyphAtlas {
    enum Content: Hashable {
        case scalar(UInt32)
        case cluster(Data)

        var string: String? {
            switch self {
            case .scalar(let value):
                Unicode.Scalar(value).map(String.init)
            case .cluster(let data):
                String(data: data, encoding: .utf8)
            }
        }
    }

    struct Key: Hashable {
        let content: Content
        let bold: Bool
        let italic: Bool
    }

    /// Where a glyph lives in the atlas, and how to place it in its cell.
    struct Entry {
        /// Normalized texture coordinates.
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        /// Size in points.
        let size: SIMD2<Float>
        /// Offset from the cell's text origin to the glyph's bottom-left.
        let bearing: SIMD2<Float>
        /// Color glyphs (emoji) carry their own RGB values instead of using
        /// the terminal cell's foreground color.
        let isColor: Bool
    }

    private static let initialDimension = 1024
    private static let maximumDimension = 2048

    private let device: MTLDevice
    private(set) var texture: MTLTexture
    private(set) var generation: UInt64 = 0
    private var dimension: Int
    private var scale: CGFloat
    private var entries: [Key: Entry] = [:]

    /// Shelf state, in device pixels.
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var isFull = false

    private var metrics: AlacrittyMetrics

    init?(device: MTLDevice, metrics: AlacrittyMetrics, scale: CGFloat) {
        let dimension = Self.initialDimension
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.device = device
        self.texture = texture
        self.dimension = dimension
        self.metrics = metrics
        self.scale = max(scale, 1)
    }

    /// Drops every glyph. Called when the font or the backing scale changes,
    /// since both invalidate the rasterization.
    func reset(metrics: AlacrittyMetrics, scale: CGFloat) {
        guard metrics.cellWidth != self.metrics.cellWidth
            || metrics.cellHeight != self.metrics.cellHeight
            || metrics.regular != self.metrics.regular
            || metrics.fontThicken != self.metrics.fontThicken
            || scale != self.scale
        else { return }
        self.metrics = metrics
        self.scale = max(scale, 1)
        entries.removeAll(keepingCapacity: true)
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        isFull = false
        generation &+= 1
    }

    /// The atlas entry for a glyph, rasterizing it on first use. Nil for a
    /// glyph with no ink (a space) or once the atlas is full.
    func entry(for key: Key) -> Entry? {
        if let cached = entries[key] { return cached }
        guard !isFull, let text = key.content.string else { return nil }
        guard let rasterized = rasterize(text: text, bold: key.bold, italic: key.italic)
        else { return nil }
        entries[key] = rasterized
        return rasterized
    }

    // MARK: - Rasterization

    private func rasterize(text: String, bold: Bool, italic: Bool) -> Entry? {
        let font = metrics.font(bold: bold, italic: italic)
        // CTLine rather than raw glyph drawing: it runs the system fallback
        // chain, so emoji and Nerd Font icons rasterize the same way they did
        // on the CPU path instead of coming out as missing-glyph boxes.
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        var attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        let isColor = containsColorGlyphs(line)
        if metrics.fontThicken, !isColor {
            // CoreText's negative stroke width fills and expands the glyph.
            // Two percent is close to Ghostty's subtle one-pixel thickening
            // without changing the grid advance. Color emoji keep their
            // original artwork rather than receiving a white outline.
            attributes[.strokeColor] = NSColor.white
            attributes[.strokeWidth] = -2
            attributed = NSAttributedString(string: text, attributes: attributes)
            line = CTLineCreateWithAttributedString(attributed)
        }
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // A pixel of bleed on each side keeps linear sampling from picking up
        // a neighbour's ink along the shared edge.
        let padding: CGFloat = 1
        let pixelWidth = Int(((bounds.width + padding * 2) * scale).rounded(.up))
        let pixelHeight = Int(((bounds.height + padding * 2) * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= dimension, pixelHeight <= dimension
        else { return nil }

        guard let origin = allocate(width: pixelWidth, height: pixelHeight) else { return nil }

        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: space,
                bitmapInfo: bitmapInfo
            )
        }) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        // The atlas stores grayscale coverage, not an opaque LCD surface.
        // Core Graphics font smoothing strengthens that coverage even when
        // `fontThicken` is off, making Alacritty's regular face look heavier
        // than the same font in Ghostty. Keep normal antialiasing, and let the
        // explicit stroke above be the only opt-in thickening pass.
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        // Draw relative to the glyph's own bounds so the bearing below is the
        // only thing that positions it in the cell.
        context.textPosition = CGPoint(x: -bounds.minX + padding, y: -bounds.minY + padding)
        CTLineDraw(line, context)

        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: pixelWidth * 4
        )

        let atlasDimension = Float(dimension)
        return Entry(
            uvOrigin: SIMD2(
                Float(origin.x) / atlasDimension,
                Float(origin.y) / atlasDimension
            ),
            uvSize: SIMD2(
                Float(pixelWidth) / atlasDimension,
                Float(pixelHeight) / atlasDimension
            ),
            size: SIMD2(Float(pixelWidth) / Float(scale), Float(pixelHeight) / Float(scale)),
            bearing: SIMD2(Float(bounds.minX - padding), Float(bounds.minY - padding)),
            isColor: isColor
        )
    }

    /// CoreText's fallback run tells us whether the resolved face has an
    /// intrinsic color table (`sbix`, `COLR`, or SVG). Checking the actual run
    /// matters: the configured monospace face is not a color font, but its
    /// fallback for emoji is Apple Color Emoji.
    private func containsColorGlyphs(_ line: CTLine) -> Bool {
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { continue }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).rawValue & (1 << 13) != 0 {
                return true
            }
        }
        return false
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if shelfX + width > dimension {
            // Start a new shelf below the tallest glyph on this one.
            shelfX = 0
            shelfY += shelfHeight
            shelfHeight = 0
        }
        if shelfY + height > dimension, grow() {
            return allocate(width: width, height: height)
        }
        guard shelfY + height <= dimension else {
            isFull = true
            return nil
        }
        let origin = (x: shelfX, y: shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }

    /// Most terminal sessions use far fewer than a thousand distinct glyph
    /// variants, which fit comfortably in a 1024² atlas (4 MiB). Grow to the
    /// previous 2048² capacity only for a session that actually needs it.
    ///
    /// Growth invalidates every existing UV. The renderer observes
    /// `generation` and rebuilds all cached rows once against the new texture.
    private func grow() -> Bool {
        guard dimension < Self.maximumDimension else { return false }
        let nextDimension = min(dimension * 2, Self.maximumDimension)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: nextDimension,
            height: nextDimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let nextTexture = device.makeTexture(descriptor: descriptor) else {
            return false
        }

        texture = nextTexture
        dimension = nextDimension
        entries.removeAll(keepingCapacity: true)
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        isFull = false
        generation &+= 1
        return true
    }
}
