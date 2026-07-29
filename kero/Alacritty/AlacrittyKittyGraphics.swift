//
//  AlacrittyKittyGraphics.swift
//  kero
//

import Foundation

struct AlacrittyKittyImageKey: Hashable {
    let imageID: UInt32
    let generation: UInt64
}

struct AlacrittyKittyPlacement {
    let placementSerial: UInt64
    let imageID: UInt32
    let placementID: UInt32
    let png: Data
    let imageWidth: Int
    let imageHeight: Int
    let imageGeneration: UInt64
    let viewportRow: Int
    let column: Int
    let sourceX: Int
    let sourceY: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let displayColumns: Int
    let displayRows: Int
    let occupiedColumns: Int
    let occupiedRows: Int
    let xOffset: Int
    let yOffset: Int
    let zIndex: Int

    var imageKey: AlacrittyKittyImageKey {
        AlacrittyKittyImageKey(imageID: imageID, generation: imageGeneration)
    }

    init(_ placement: KeroKittyPlacement, png: Data) {
        placementSerial = placement.placement_serial
        imageID = placement.image_id
        placementID = placement.placement_id
        self.png = png
        imageWidth = Int(placement.image_width)
        imageHeight = Int(placement.image_height)
        imageGeneration = placement.image_generation
        viewportRow = Int(placement.viewport_row)
        column = Int(placement.column)
        sourceX = Int(placement.source_x)
        sourceY = Int(placement.source_y)
        sourceWidth = Int(placement.source_width)
        sourceHeight = Int(placement.source_height)
        displayColumns = Int(placement.display_columns)
        displayRows = Int(placement.display_rows)
        occupiedColumns = Int(placement.occupied_columns)
        occupiedRows = Int(placement.occupied_rows)
        xOffset = Int(placement.x_offset)
        yOffset = Int(placement.y_offset)
        zIndex = Int(placement.z_index)
    }
}
