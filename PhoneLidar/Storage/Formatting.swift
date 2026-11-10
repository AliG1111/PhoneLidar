import Foundation

enum Units {
    /// "2.438 m  (8' 0.0")"
    static func format(meters: Double) -> String {
        String(format: "%.3f m", meters) + "  (" + feetInches(meters) + ")"
    }

    /// "8' 0.0""
    static func feetInches(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        let totalInches = (abs(meters) / 0.0254 * 10).rounded() / 10
        // Sign after rounding: a tiny negative value that rounds to zero prints as 0' 0.0", not -0' 0.0".
        let sign = meters < 0 && totalInches > 0 ? "-" : ""
        var feet = Int(totalInches / 12)
        var inches = totalInches - Double(feet) * 12
        if inches >= 11.95 {
            feet += 1
            inches = 0
        }
        return sign + String(format: "%ld' %.1f\"", feet, inches)
    }

    static func short(_ meters: Double) -> String {
        String(format: "%.2f m", meters)
    }

    static func formatArea(squareMeters: Double) -> String {
        String(format: "%.2f m²  (%.1f ft²)", squareMeters, squareMeters * 10.7639)
    }

    /// "12.4 MB"
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum CSV {
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func make(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// The totals block of RoomReport.csv (E-4): an empty line, its own header (`summary_item,value,unit`), then one
    /// row per value and unit, so no total sits in an element column such as `width_m`. Appended after the
    /// element rows, which keep their own header and columns. The wall-height rows are left out when there are
    /// no walls (`wallHeightM` 0).
    static func roomSummary(wallCount: Int, wallLengthM: Double, wallHeightM: Double,
                            floorAreaM2: Double) -> [[String]] {
        var rows: [[String]] = [[""], ["summary_item", "value", "unit"]]
        rows.append(["wall_count", "\(wallCount)", "count"])
        rows.append(["total_wall_length", String(format: "%.4f", wallLengthM), "m"])
        rows.append(["total_wall_length", Units.feetInches(wallLengthM), "ft_in"])
        if wallHeightM > 0 {
            rows.append(["wall_height_max", String(format: "%.4f", wallHeightM), "m"])
            rows.append(["wall_height_max", Units.feetInches(wallHeightM), "ft_in"])
        }
        rows.append(["floor_area", String(format: "%.3f", floorAreaM2), "m2"])
        rows.append(["floor_area", String(format: "%.2f", floorAreaM2 * 10.7639), "ft2"])
        return rows
    }

    static func measurements(_ items: [PointMeasurement]) -> String {
        var rows: [[String]] = [["label", "distance_m", "distance_ft_in",
                                 "start_x_m", "start_y_m", "start_z_m",
                                 "end_x_m", "end_y_m", "end_z_m"]]
        for m in items {
            let s = m.start + [0, 0, 0]
            let e = m.end + [0, 0, 0]
            rows.append([m.label,
                         String(format: "%.4f", m.meters),
                         Units.feetInches(m.meters),
                         String(format: "%.4f", s[0]), String(format: "%.4f", s[1]), String(format: "%.4f", s[2]),
                         String(format: "%.4f", e[0]), String(format: "%.4f", e[1]), String(format: "%.4f", e[2])])
        }
        return make(rows)
    }
}
