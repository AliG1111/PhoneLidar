import Foundation

/// TopoGrid.bin: the stitched topographic grid of a line recording, used by the real-time replay.
///
/// Layout (little endian): "PLTG", version (UInt32), columns, rows (UInt32), cell size, qMin, xMin (Float64, mm),
/// height mode (UInt32: 1 = heights above the baseline, 0 = distances from the camera), reserved (UInt32),
/// then rows × columns Float32 values in mm, row-major (rows = across the material, top → bottom of the screen;
/// columns = along the travel, left → right of the screen). NaN = no data.
struct TopoGridFile {
    static let fileName = "TopoGrid.bin"
    static let headerSize = 48

    var columns: Int
    var rows: Int
    /// Cell size, mm.
    var cell: Double
    /// Map coordinate (mm) of the left edge of column 0. q = sign · travel − y, fixed to the material.
    var qMin: Double
    /// Across position (mm from the image centre line) of the top edge of row 0.
    var xMin: Double
    var heightMode: Bool
    /// rows × columns, NaN = no data.
    var values: [Float]

    static func write(to url: URL, columns: Int, rows: Int, cell: Double, qMin: Double, xMin: Double,
                      heightMode: Bool, zRef: Float, means: [Float], hits: [UInt16]) throws {
        let count = columns * rows
        guard count > 0, means.count >= count, hits.count >= count else { return }
        var data = Data()
        data.reserveCapacity(headerSize + count * 4)
        data.append(contentsOf: Array("PLTG".utf8))
        data.appendUInt32(1)
        data.appendUInt32(UInt32(columns))
        data.appendUInt32(UInt32(rows))
        data.appendFloat64(cell)
        data.appendFloat64(qMin)
        data.appendFloat64(xMin)
        data.appendUInt32(heightMode ? 1 : 0)
        data.appendUInt32(0)
        var values = [Float](repeating: .nan, count: count)
        for i in 0..<count where hits[i] > 0 {
            values[i] = zRef + means[i]
        }
        data.append(values.withUnsafeBufferPointer { Data(buffer: $0) })
        try data.write(to: url, options: .atomic)
    }

    static func load(from folder: URL) -> TopoGridFile? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName), options: .alwaysMapped),
              data.count >= headerSize,
              String(decoding: data.prefix(4), as: UTF8.self) == "PLTG" else { return nil }
        let columns = Int(data.readUInt32(at: 8))
        let rows = Int(data.readUInt32(at: 12))
        let count = columns * rows
        guard columns > 0, rows > 0, data.count >= headerSize + count * 4 else { return nil }
        let cell = data.readFloat64(at: 16)
        let qMin = data.readFloat64(at: 24)
        let xMin = data.readFloat64(at: 32)
        let heightMode = data.readUInt32(at: 40) == 1
        guard cell > 0, cell.isFinite, qMin.isFinite, xMin.isFinite else { return nil }
        var values = [Float](repeating: .nan, count: count)
        let start = data.startIndex + headerSize
        values.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            _ = data.copyBytes(to: bytes, from: start..<(start + count * 4))
        }
        return TopoGridFile(columns: columns, rows: rows, cell: cell, qMin: qMin, xMin: xMin,
                            heightMode: heightMode, values: values)
    }
}

extension Data {
    mutating func appendFloat64(_ value: Double) {
        let bits = value.bitPattern
        appendUInt32(UInt32(truncatingIfNeeded: bits))
        appendUInt32(UInt32(truncatingIfNeeded: bits >> 32))
    }

    func readFloat64(at offset: Int) -> Double {
        let low = UInt64(readUInt32(at: offset))
        let high = UInt64(readUInt32(at: offset + 4))
        return Double(bitPattern: low | (high << 32))
    }
}
