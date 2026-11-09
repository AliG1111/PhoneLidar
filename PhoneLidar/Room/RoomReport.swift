import Foundation
import RoomPlan
import simd

/// Turns a CapturedRoom into readable summary lines and a spreadsheet-friendly CSV.
struct RoomReport {
    let summaryLines: [String]
    let csv: String

    init(room: CapturedRoom) {
        var rows: [[String]] = [["type", "category", "number",
                                 "width_m", "height_m", "depth_m",
                                 "width_ft_in", "height_ft_in", "depth_ft_in",
                                 "center_x_m", "center_y_m", "center_z_m",
                                 "confidence"]]

        func addRow(_ type: String, _ category: String, _ number: Int,
                    _ dims: simd_float3, _ transform: simd_float4x4, _ confidence: String) {
            let c = transform.columns.3
            rows.append([type, category, "\(number)",
                         RoomReport.f(dims.x), RoomReport.f(dims.y), RoomReport.f(dims.z),
                         Units.feetInches(Double(dims.x)), Units.feetInches(Double(dims.y)),
                         Units.feetInches(Double(dims.z)),
                         RoomReport.f(c.x), RoomReport.f(c.y), RoomReport.f(c.z),
                         confidence])
        }

        for (i, s) in room.walls.enumerated() {
            addRow("wall", "\(s.category)", i + 1, s.dimensions, s.transform, "\(s.confidence)")
        }
        for (i, s) in room.doors.enumerated() {
            addRow("door", "\(s.category)", i + 1, s.dimensions, s.transform, "\(s.confidence)")
        }
        for (i, s) in room.windows.enumerated() {
            addRow("window", "\(s.category)", i + 1, s.dimensions, s.transform, "\(s.confidence)")
        }
        for (i, s) in room.openings.enumerated() {
            addRow("opening", "\(s.category)", i + 1, s.dimensions, s.transform, "\(s.confidence)")
        }
        for (i, s) in room.floors.enumerated() {
            addRow("floor", "\(s.category)", i + 1, s.dimensions, s.transform, "\(s.confidence)")
        }
        for (i, o) in room.objects.enumerated() {
            addRow("object", "\(o.category)", i + 1, o.dimensions, o.transform, "\(o.confidence)")
        }

        var lines: [String] = []
        let wallLength = room.walls.reduce(0.0) { $0 + Double($1.dimensions.x) }
        let wallHeight = room.walls.map { Double($0.dimensions.y) }.max() ?? 0

        var floorArea = room.floors.reduce(0.0) { $0 + RoomReport.polygonArea($1.polygonCorners) }
        if floorArea == 0 {
            floorArea = room.floors.reduce(0.0) { $0 + Double($1.dimensions.x * $1.dimensions.y) }
        }

        lines.append("Walls: \(room.walls.count), total length \(Units.format(meters: wallLength))")
        if wallHeight > 0 {
            lines.append("Wall height (max): \(Units.format(meters: wallHeight))")
        }
        if floorArea > 0 {
            lines.append("Floor area: \(Units.formatArea(squareMeters: floorArea))")
        }
        lines.append("Doors: \(room.doors.count)   Windows: \(room.windows.count)   Openings: \(room.openings.count)   Objects: \(room.objects.count)")

        for (i, s) in room.walls.enumerated() {
            lines.append("Wall \(i + 1): \(Units.short(Double(s.dimensions.x))) W × \(Units.short(Double(s.dimensions.y))) H")
        }
        for (i, s) in room.doors.enumerated() {
            lines.append("Door \(i + 1): \(Units.short(Double(s.dimensions.x))) W × \(Units.short(Double(s.dimensions.y))) H")
        }
        for (i, s) in room.windows.enumerated() {
            lines.append("Window \(i + 1): \(Units.short(Double(s.dimensions.x))) W × \(Units.short(Double(s.dimensions.y))) H")
        }
        for (i, o) in room.objects.enumerated() {
            let d = o.dimensions
            lines.append("\(o.category) \(i + 1): \(Units.short(Double(d.x))) W × \(Units.short(Double(d.y))) H × \(Units.short(Double(d.z))) D")
        }

        summaryLines = lines
        csv = CSV.make(rows)
    }

    static func f(_ value: Float) -> String {
        String(format: "%.4f", value)
    }

    /// Area of a planar polygon in any orientation (half the length of the summed cross products).
    static func polygonArea(_ points: [simd_float3]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = simd_float3(repeating: 0)
        for i in 0..<points.count {
            sum += simd_cross(points[i], points[(i + 1) % points.count])
        }
        return Double(simd_length(sum)) / 2
    }
}
