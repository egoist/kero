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
    struct Key: Hashable {
        let scalar: UInt32
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
    }

    private static let dimension = 2048

    let texture: MTLTexture
    private let scale: CGFloat
    private var entries: [Key: Entry] = [:]

    /// Shelf state, in device pixels.
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var isFull = false

    private var metrics: AlacrittyMetrics

    init?(device: MTLDevice, metrics: AlacrittyMetrics, scale: CGFloat) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Self.dimension,
            height: Self.dimension,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
        self.metrics = metrics
        self.scale = max(scale, 1)
    }

    /// Drops every glyph. Called when the font or the backing scale changes,
    /// since both invalidate the rasterization.
    func reset(metrics: AlacrittyMetrics, scale: CGFloat) {
        guard metrics.cellWidth != self.metrics.cellWidth
            || metrics.cellHeight != self.metrics.cellHeight
            || metrics.regular != self.metrics.regular
            || scale != self.scale
        else { return }
        self.metrics = metrics
        entries.removeAll(keepingCapacity: true)
        shelfX = 0
        shelfY = 0
        shelfHeight = 0
        isFull = false
    }

    /// The atlas entry for a glyph, rasterizing it on first use. Nil for a
    /// glyph with no ink (a space) or once the atlas is full.
    func entry(for key: Key) -> Entry? {
        if let cached = entries[key] { return cached }
        guard !isFull, let scalar = Unicode.Scalar(key.scalar) else { return nil }
        guard let rasterized = rasterize(scalar: scalar, bold: key.bold, italic: key.italic)
        else { return nil }
        entries[key] = rasterized
        return rasterized
    }

    // MARK: - Rasterization

    private func rasterize(scalar: Unicode.Scalar, bold: Bool, italic: Bool) -> Entry? {
        let font = metrics.font(bold: bold, italic: italic)
        // CTLine rather than raw glyph drawing: it runs the system fallback
        // chain, so emoji and Nerd Font icons rasterize the same way they did
        // on the CPU path instead of coming out as missing-glyph boxes.
        let attributed = NSAttributedString(
            string: String(scalar),
            attributes: [.font: font, .foregroundColor: NSColor.white]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // A pixel of bleed on each side keeps linear sampling from picking up
        // a neighbour's ink along the shared edge.
        let padding: CGFloat = 1
        let pixelWidth = Int(((bounds.width + padding * 2) * scale).rounded(.up))
        let pixelHeight = Int(((bounds.height + padding * 2) * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= Self.dimension, pixelHeight <= Self.dimension
        else { return nil }

        guard let origin = allocate(width: pixelWidth, height: pixelHeight) else { return nil }

        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
        let space = CGColorSpaceCreateDeviceGray()
        guard let context = pixels.withUnsafeMutableBytes({ raw in
            CGContext(
                data: raw.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(true)
        // Draw relative to the glyph's own bounds so the bearing below is the
        // only thing that positions it in the cell.
        context.textPosition = CGPoint(x: -bounds.minX + padding, y: -bounds.minY + padding)
        CTLineDraw(line, context)

        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: pixelWidth
        )

        let dimension = Float(Self.dimension)
        return Entry(
            uvOrigin: SIMD2(Float(origin.x) / dimension, Float(origin.y) / dimension),
            uvSize: SIMD2(Float(pixelWidth) / dimension, Float(pixelHeight) / dimension),
            size: SIMD2(Float(pixelWidth) / Float(scale), Float(pixelHeight) / Float(scale)),
            bearing: SIMD2(Float(bounds.minX - padding), Float(bounds.minY - padding))
        )
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        if shelfX + width > Self.dimension {
            // Start a new shelf below the tallest glyph on this one.
            shelfX = 0
            shelfY += shelfHeight
            shelfHeight = 0
        }
        guard shelfY + height <= Self.dimension else {
            isFull = true
            return nil
        }
        let origin = (x: shelfX, y: shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }
}
