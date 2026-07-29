//
//  TerminalMetalRenderer.swift
//  kero
//

import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

/// GPU renderer for a terminal grid.
///
/// One instanced draw call covers a frame: every cell background, glyph,
/// underline, strikethrough and the cursor becomes a quad in a single buffer.
/// Quad corners are generated in the vertex shader from `vertex_id`, so there
/// is no geometry to upload — only the per-instance array.
///
/// Glyphs are still rasterized by CoreText (see `TerminalGlyphAtlas`); Metal
/// only composites them. That keeps font matching and fallback identical to
/// Kero's editor and to the Ghostty backend, which is the whole reason the
/// text stack stays on the platform side.
final class TerminalMetalRenderer {
    /// Mirrors `Instance` in the shader below. Field order and padding must
    /// stay in step with it.
    private struct Instance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        /// 0 solid, 1 foreground-tinted glyph, 2 intrinsic-color glyph,
        /// 3 Kitty graphics texture.
        var kind: UInt32
        var padding: UInt32 = 0
    }

    private struct RowInstances {
        var instances: [Instance]
        var backgroundCount: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let textureLoader: MTKTextureLoader
    private var atlas: TerminalGlyphAtlas?
    private var kittyTextures: [AlacrittyKittyImageKey: MTLTexture] = [:]

    private var instances: [Instance] = []
    private var instanceBuffer: MTLBuffer?

    /// Draw instances per grid row, kept between frames.
    ///
    /// Building a row means an atlas lookup, a colour unpack and a flag test
    /// per cell — the bulk of a frame's CPU cost. Almost every change touches
    /// one row (a prompt redraw, a cursor blink), so rows the emulator did not
    /// damage are reused verbatim and only the dirty ones are rebuilt.
    private var rowInstances: [RowInstances] = []
    /// Rebuilt rows are only valid for the geometry they were built at.
    private var cachedColumns = 0
    private var cachedRows = 0

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        textureLoader = MTKTextureLoader(device: device)

        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "kero_terminal_vertex"),
              let fragmentFunction = library.makeFunction(name: "kero_terminal_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Glyph coverage arrives as alpha, so quads blend rather than replace.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        // The terminal framebuffer is always opaque. Preserve that alpha so
        // the IOSurface retained for an inactive window composites exactly
        // like the opaque CAMetalLayer; multiplying glyph coverage into alpha
        // a second time makes antialiased edges look thinner after focus loss.
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        else { return nil }
        self.pipeline = pipeline

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        self.sampler = sampler
    }

    // MARK: - Frame

    @discardableResult
    func render(
        snapshot: KeroSnapshot,
        kittyPlacements: [AlacrittyKittyPlacement],
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        scale: CGFloat,
        dirtyRows: [Int]?,
        in drawable: CAMetalDrawable,
        viewportSize: CGSize,
        onPresented: (@Sendable () -> Void)? = nil,
        waitUntilCompleted: Bool = false
    ) -> Bool {
        if atlas == nil {
            atlas = TerminalGlyphAtlas(device: device, metrics: metrics, scale: scale)
        }
        guard let atlas else { return false }
        let generationBeforeReset = atlas.generation
        atlas.reset(metrics: metrics, scale: scale)
        let resetAtlas = atlas.generation != generationBeforeReset

        let atlasGenerationBeforeBuild = atlas.generation
        build(
            snapshot: snapshot, metrics: metrics, padding: padding,
            atlas: atlas,
            dirtyRows: resetAtlas ? nil : dirtyRows,
            viewportSize: viewportSize
        )
        if atlas.generation != atlasGenerationBeforeBuild {
            // The atlas outgrew its initial texture while building this
            // frame. Its old UVs are invalid, including those in cached clean
            // rows, so rebuild the complete grid once against the new atlas.
            build(
                snapshot: snapshot, metrics: metrics, padding: padding,
                atlas: atlas, dirtyRows: nil, viewportSize: viewportSize
            )
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let background = Self.color(snapshot.background)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.x),
            green: Double(background.y),
            blue: Double(background.z),
            alpha: 1
        )

        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return false }

        drawKittyGraphics(
            kittyPlacements.filter { $0.zIndex < 0 },
            metrics: metrics,
            padding: padding,
            viewportSize: viewportSize,
            with: encoder
        )
        if !instances.isEmpty, let buffer = uploadInstances() {
            var viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: instances.count
            )
        }
        drawKittyGraphics(
            kittyPlacements.filter { $0.zIndex >= 0 },
            metrics: metrics,
            padding: padding,
            viewportSize: viewportSize,
            with: encoder
        )
        let activeImageKeys = Set(kittyPlacements.map(\.imageKey))
        kittyTextures = kittyTextures.filter { activeImageKeys.contains($0.key) }

        encoder.endEncoding()
        if let onPresented {
            drawable.addPresentedHandler { _ in onPresented() }
        }
        commands.present(drawable)
        commands.commit()
        if waitUntilCompleted {
            commands.waitUntilCompleted()
            return commands.status != .error
        }
        return true
    }

    private func drawKittyGraphics(
        _ placements: [AlacrittyKittyPlacement],
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        viewportSize: CGSize,
        with encoder: MTLRenderCommandEncoder
    ) {
        guard !placements.isEmpty else { return }
        var viewport = SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(
            &viewport,
            length: MemoryLayout<SIMD2<Float>>.stride,
            index: 1
        )
        encoder.setFragmentSamplerState(sampler, index: 0)

        for placement in placements {
            guard placement.imageWidth > 0,
                  placement.imageHeight > 0,
                  placement.sourceWidth > 0,
                  placement.sourceHeight > 0,
                  placement.displayColumns > 0,
                  placement.displayRows > 0,
                  let texture = kittyTexture(for: placement)
            else { continue }

            let destinationWidth = Float(placement.displayColumns) * Float(metrics.cellWidth)
            let destinationHeight = Float(placement.displayRows) * Float(metrics.cellHeight)
            var instance = Instance(
                origin: SIMD2(
                    Float(padding.x)
                        + Float(placement.column) * Float(metrics.cellWidth)
                        + Float(placement.xOffset),
                    Float(padding.y)
                        + Float(placement.viewportRow) * Float(metrics.cellHeight)
                        + Float(placement.yOffset)
                ),
                size: SIMD2(destinationWidth, destinationHeight),
                color: SIMD4(repeating: 1),
                uvOrigin: SIMD2(
                    Float(placement.sourceX) / Float(placement.imageWidth),
                    Float(placement.sourceY) / Float(placement.imageHeight)
                ),
                uvSize: SIMD2(
                    Float(placement.sourceWidth) / Float(placement.imageWidth),
                    Float(placement.sourceHeight) / Float(placement.imageHeight)
                ),
                kind: 3
            )
            encoder.setVertexBytes(
                &instance,
                length: MemoryLayout<Instance>.stride,
                index: 0
            )
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: 1
            )
        }
    }

    private func kittyTexture(for placement: AlacrittyKittyPlacement) -> MTLTexture? {
        if let texture = kittyTextures[placement.imageKey] {
            return texture
        }
        guard let texture = try? textureLoader.newTexture(
            data: placement.png,
            options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false,
            ]
        ) else {
            return nil
        }
        kittyTextures[placement.imageKey] = texture
        return texture
    }

    private func uploadInstances() -> MTLBuffer? {
        let length = MemoryLayout<Instance>.stride * instances.count
        // Grow only: a terminal's instance count is bounded by its grid, so
        // the buffer settles after the first few frames.
        if instanceBuffer == nil || instanceBuffer!.length < length {
            instanceBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        }
        guard let buffer = instanceBuffer else { return nil }
        instances.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: length)
        }
        return buffer
    }

    // MARK: - Instance building

    private func build(
        snapshot: KeroSnapshot,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        atlas: TerminalGlyphAtlas,
        dirtyRows: [Int]?,
        viewportSize: CGSize
    ) {
        instances.removeAll(keepingCapacity: true)
        guard let cells = snapshot.cells else { return }

        let columns = snapshot.columns
        let rows = snapshot.rows

        // A geometry change invalidates every cached row: positions are baked
        // into the instances. Rebuild every row even if the emulator only
        // reported partial damage for this frame.
        let geometryChanged = cachedColumns != columns || cachedRows != rows
        if geometryChanged {
            rowInstances = Array(
                repeating: RowInstances(instances: [], backgroundCount: 0),
                count: rows
            )
            cachedColumns = columns
            cachedRows = rows
        }

        // nil means rebuild everything — a full-damage frame, or a host-side
        // change the emulator never saw.
        let rowsToBuild: [Int]
        if geometryChanged {
            rowsToBuild = Array(0..<rows)
        } else if let dirtyRows {
            rowsToBuild = dirtyRows.filter { $0 >= 0 && $0 < rows }
        } else {
            rowsToBuild = Array(0..<rows)
        }
        for row in rowsToBuild {
            rowInstances[row] = buildRow(
                row: row, cells: cells, columns: columns,
                snapshot: snapshot, metrics: metrics, padding: padding,
                atlas: atlas, viewportSize: viewportSize
            )
        }

        instances.reserveCapacity(
            rowInstances.reduce(0) { $0 + $1.instances.count } + 1
        )
        for row in rowInstances {
            instances.append(contentsOf: row.instances)
        }
        appendCursor(
            snapshot: snapshot,
            metrics: metrics,
            padding: padding,
            blockInsertionIndex: blockCursorInsertionIndex(snapshot: snapshot)
        )
    }

    private func buildRow(
        row: Int,
        cells: UnsafePointer<KeroCell>,
        columns: Int,
        snapshot: KeroSnapshot,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        atlas: TerminalGlyphAtlas,
        viewportSize: CGSize
    ) -> RowInstances {
        var instances: [Instance] = []
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let originX = Float(padding.x)
        let originY = Float(padding.y)
        let defaultBackground = snapshot.background

        let top = originY + Float(row) * cellHeight
        var column = 0

        // Backgrounds first, coalescing equal-coloured runs into one quad.
        while column < columns {
            let cell = cells[row * columns + column]
            let background = AlacrittyRenderer.background(of: cell, default: defaultBackground)
            var span = 1
            while column + span < columns {
                let next = cells[row * columns + column + span]
                guard AlacrittyRenderer.background(of: next, default: defaultBackground)
                    == background else { break }
                span += 1
            }
            if background != defaultBackground {
                let reachesLeftEdge = column == 0
                let reachesRightEdge = column + span == columns
                let reachesTopEdge = row == 0
                let reachesBottomEdge = row + 1 == snapshot.rows
                let left = reachesLeftEdge
                    ? 0 : originX + Float(column) * cellWidth
                let right = reachesRightEdge
                    ? Float(viewportSize.width)
                    : originX + Float(column + span) * cellWidth
                let runTop = reachesTopEdge ? 0 : top
                let bottom = reachesBottomEdge
                    ? Float(viewportSize.height) : top + cellHeight
                instances.append(Instance(
                    origin: SIMD2(left, runTop),
                    size: SIMD2(max(right - left, 0), max(bottom - runTop, 0)),
                    color: Self.color(background),
                    uvOrigin: .zero,
                    uvSize: .zero,
                    kind: 0
                ))
            }
            column += span
        }
        let backgroundCount = instances.count

        for column in 0..<columns {
            let cell = cells[row * columns + column]
            guard cell.flags & UInt16(KERO_CELL_HIDDEN) == 0,
                  cell.flags & UInt16(KERO_CELL_WIDE_SPACER) == 0
            else { continue }

            var foreground = AlacrittyRenderer.foreground(of: cell, default: defaultBackground)
            let isCursorCell = snapshot.cursor_line == row
                && snapshot.cursor_column == column
                && snapshot.cursor_shape == 0
            if isCursorCell {
                foreground = AlacrittyRenderer.background(of: cell, default: defaultBackground)
            }
            let color = Self.color(foreground)
            let left = originX + Float(column) * cellWidth

            if cell.ch != 0,
               cell.text_len > 0 || cell.ch != UInt32(UInt8(ascii: " ")) {
                let content: TerminalGlyphAtlas.Content
                let offset = Int(cell.text_offset)
                let length = Int(cell.text_len)
                if length > 0,
                   let text = snapshot.text,
                   offset >= 0,
                   offset + length <= snapshot.text_len {
                    content = .cluster(Data(bytes: text.advanced(by: offset), count: length))
                } else {
                    content = .scalar(cell.ch)
                }
                let key = TerminalGlyphAtlas.Key(
                    content: content,
                    bold: cell.flags & UInt16(KERO_CELL_BOLD) != 0,
                    italic: cell.flags & UInt16(KERO_CELL_ITALIC) != 0
                )
                if let entry = atlas.entry(for: key) {
                    // The atlas stores bearings relative to the text
                    // origin; y grows downward here, so the ascent above
                    // the baseline becomes a negative offset.
                    let baseline = top + Float(metrics.baseline)
                    instances.append(Instance(
                        origin: SIMD2(
                            left + entry.bearing.x,
                            baseline - entry.bearing.y - entry.size.y
                        ),
                        size: entry.size,
                        color: color,
                        uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize,
                        kind: entry.isColor ? 2 : 1
                    ))
                }
            }

            if cell.flags & UInt16(KERO_CELL_UNDERLINE) != 0 {
                instances.append(Instance(
                    origin: SIMD2(left, top + Float(metrics.baseline) + cellHeight * 0.12),
                    size: SIMD2(cellWidth, 1),
                    color: color,
                    uvOrigin: .zero, uvSize: .zero, kind: 0
                ))
            }
            if cell.flags & UInt16(KERO_CELL_STRIKEOUT) != 0 {
                instances.append(Instance(
                    origin: SIMD2(left, top + Float(metrics.baseline) - cellHeight * 0.22),
                    size: SIMD2(cellWidth, 1),
                    color: color,
                    uvOrigin: .zero, uvSize: .zero, kind: 0
                ))
            }
        }

        return RowInstances(
            instances: instances,
            backgroundCount: backgroundCount
        )
    }

    /// Places a block cursor after its row backgrounds but before its glyphs,
    /// while outline cursors sit above all cell content.
    private func appendCursor(
        snapshot: KeroSnapshot,
        metrics: AlacrittyMetrics,
        padding: CGPoint,
        blockInsertionIndex: Int?
    ) {
        guard snapshot.cursor_line >= 0, snapshot.cursor_column >= 0 else { return }
        let cellWidth = Float(metrics.cellWidth)
        let cellHeight = Float(metrics.cellHeight)
        let left = Float(padding.x) + Float(snapshot.cursor_column) * cellWidth
        let top = Float(padding.y) + Float(snapshot.cursor_line) * cellHeight
        let color = Self.color(snapshot.cursor_color)

        if snapshot.cursor_shape == 3 {
            // Hollow cursor is four narrow quads.
            instances.append(contentsOf: [
                Instance(
                    origin: SIMD2(left, top), size: SIMD2(cellWidth, 1),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
                Instance(
                    origin: SIMD2(left, top + cellHeight - 1), size: SIMD2(cellWidth, 1),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
                Instance(
                    origin: SIMD2(left, top), size: SIMD2(1, cellHeight),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
                Instance(
                    origin: SIMD2(left + cellWidth - 1, top), size: SIMD2(1, cellHeight),
                    color: color, uvOrigin: .zero, uvSize: .zero, kind: 0
                ),
            ])
            return
        }

        let (origin, size): (SIMD2<Float>, SIMD2<Float>) = switch snapshot.cursor_shape {
        case 1: (SIMD2(left, top + cellHeight - 2), SIMD2(cellWidth, 2))
        case 2: (SIMD2(left, top), SIMD2(2, cellHeight))
        default: (SIMD2(left, top), SIMD2(cellWidth, cellHeight))
        }
        let cursor = Instance(
            origin: origin, size: size, color: color,
            uvOrigin: .zero, uvSize: .zero, kind: 0
        )
        if snapshot.cursor_shape == 0, let blockInsertionIndex {
            instances.insert(cursor, at: blockInsertionIndex)
        } else {
            instances.append(cursor)
        }
    }

    /// Row instances are backgrounds followed by glyphs and decorations. Use
    /// the boundary captured with the cached row so partial damage cannot mix
    /// current snapshot backgrounds with stale instance counts.
    private func blockCursorInsertionIndex(snapshot: KeroSnapshot) -> Int? {
        let row = snapshot.cursor_line
        let column = snapshot.cursor_column
        guard row >= 0, row < snapshot.rows,
              row < rowInstances.count,
              column >= 0, column < snapshot.columns
        else { return nil }

        let precedingInstances = rowInstances[..<row].reduce(0) {
            $0 + $1.instances.count
        }
        return precedingInstances + rowInstances[row].backgroundCount
    }

    private static func color(_ packed: UInt32) -> SIMD4<Float> {
        SIMD4(
            Float((packed >> 16) & 0xff) / 255,
            Float((packed >> 8) & 0xff) / 255,
            Float(packed & 0xff) / 255,
            1
        )
    }

    // MARK: - Shaders

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float2 origin;
        float2 size;
        float4 color;
        float2 uvOrigin;
        float2 uvSize;
        uint kind;
        uint padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
        uint kind;
    };

    // Quad corners come from vertex_id, so only the instance array is uploaded.
    constant float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };

    vertex VertexOut kero_terminal_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device Instance *instances [[buffer(0)]],
        constant float2 &viewport [[buffer(1)]]
    ) {
        Instance instance = instances[instanceID];
        float2 corner = corners[vertexID];
        float2 point = instance.origin + corner * instance.size;

        // Points, y-down from the top-left, into clip space.
        float2 normalized = point / viewport;
        float2 clip = float2(normalized.x * 2.0 - 1.0, 1.0 - normalized.y * 2.0);

        VertexOut out;
        out.position = float4(clip, 0, 1);
        out.color = instance.color;
        out.uv = instance.uvOrigin + corner * instance.uvSize;
        out.kind = instance.kind;
        return out;
    }

    fragment float4 kero_terminal_fragment(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        if (in.kind == 0) {
            return in.color;
        }
        float4 sample = atlas.sample(atlasSampler, in.uv);
        if (in.kind == 3) {
            return sample;
        }
        if (in.kind == 2) {
            // CGContext stores premultiplied pixels. The pipeline uses
            // straight-alpha blending, so undo that multiplication here.
            return sample.a > 0.0
                ? float4(sample.rgb / sample.a, sample.a)
                : float4(0.0);
        }
        // Monochrome glyphs use the texture alpha as coverage; their RGB is
        // deliberately ignored so the terminal cell owns the foreground.
        float coverage = sample.a;
        return float4(in.color.rgb, in.color.a * coverage);
    }
    """
}
