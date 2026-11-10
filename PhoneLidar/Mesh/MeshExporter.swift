import Foundation
import ARKit
import Metal
import SceneKit
import UIKit

struct MeshExportResult {
    var vertexCount: Int
    var faceCount: Int
    var usdzWritten: Bool
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
}

/// One ARMeshAnchor copied out of ARKit so the files can be written off the main thread.
struct MeshAnchorSnapshot {
    var transform: simd_float4x4
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
}

/// Merges ARKit mesh anchors into one world-space mesh (metres, Y up) and writes OBJ, PLY and USDZ.
/// `snapshot` runs on the main actor (ARKit buffers); `write` runs anywhere and streams to disk.
enum MeshExporter {
    @MainActor
    static func snapshot(anchors: [ARMeshAnchor]) throws -> [MeshAnchorSnapshot] {
        var result: [MeshAnchorSnapshot] = []
        for anchor in anchors {
            let geometry = anchor.geometry
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3, faces.count > 0 else { continue }

            let vertexSource = geometry.vertices
            let normalSource = geometry.normals
            var vertices: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            vertices.reserveCapacity(vertexSource.count)
            normals.reserveCapacity(vertexSource.count)
            for i in 0..<vertexSource.count {
                vertices.append(vertexSource.float3(at: i))
                normals.append(i < normalSource.count ? normalSource.float3(at: i) : SIMD3<Float>(0, 1, 0))
            }
            var indices: [UInt32] = []
            indices.reserveCapacity(faces.count * 3)
            for f in 0..<faces.count {
                for k in 0..<3 {
                    indices.append(faces.index(primitive: f, corner: k))
                }
            }
            result.append(MeshAnchorSnapshot(transform: anchor.transform, vertices: vertices,
                                             normals: normals, indices: indices))
        }
        guard !result.isEmpty else { throw ScanError.noMesh }
        return result
    }

    /// `progress` gets a stage name and 0...1 for the whole export.
    static func write(_ snapshot: [MeshAnchorSnapshot], to folder: URL, baseName: String,
                      progress: @escaping (String, Double) -> Void) throws -> MeshExportResult {
        // Move every anchor to world space (in place; the snapshot is a local copy).
        var anchors = snapshot
        var minP = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxP = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var vertexCount = 0
        var faceCount = 0
        for a in 0..<anchors.count {
            let t = anchors[a].transform
            let rotation = simd_float3x3(columns: (
                SIMD3<Float>(t.columns.0.x, t.columns.0.y, t.columns.0.z),
                SIMD3<Float>(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                SIMD3<Float>(t.columns.2.x, t.columns.2.y, t.columns.2.z)))
            for i in 0..<anchors[a].vertices.count {
                let local = anchors[a].vertices[i]
                let world = t * SIMD4<Float>(local.x, local.y, local.z, 1)
                let p = SIMD3<Float>(world.x, world.y, world.z)
                anchors[a].vertices[i] = p
                minP = simd_min(minP, p)
                maxP = simd_max(maxP, p)
                var n = rotation * anchors[a].normals[i]
                let len = simd_length(n)
                n = len > 0 ? n / len : SIMD3<Float>(0, 1, 0)
                anchors[a].normals[i] = n
            }
            vertexCount += anchors[a].vertices.count
            faceCount += anchors[a].indices.count / 3
        }
        guard vertexCount > 0, faceCount > 0 else { throw ScanError.noMesh }

        try writeOBJ(anchors, to: folder.appendingPathComponent("\(baseName).obj")) {
            progress("Writing OBJ…", $0 * 0.4)
        }
        try writePLY(anchors, vertexCount: vertexCount, faceCount: faceCount,
                     to: folder.appendingPathComponent("\(baseName).ply")) {
            progress("Writing PLY…", 0.4 + $0 * 0.3)
        }
        progress("Writing USDZ…", 0.7)
        let usdzOK = writeUSDZ(anchors, to: folder.appendingPathComponent("\(baseName).usdz"))
        progress("Done", 1)

        return MeshExportResult(vertexCount: vertexCount, faceCount: faceCount, usdzWritten: usdzOK,
                                boundsMin: minP, boundsMax: maxP)
    }

    // MARK: - Writers

    /// Streams text to a file in ~1 MB chunks instead of building one huge String.
    private final class ChunkedFile {
        let handle: FileHandle
        var buffer = Data()

        init(url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }

        func append(_ text: String) throws {
            buffer.append(contentsOf: Array(text.utf8))
            if buffer.count >= 1_000_000 { try flush() }
        }

        func flushIfLarge() throws {
            if buffer.count >= 1_000_000 { try flush() }
        }

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        func close() throws {
            try flush()
            try handle.close()
        }
    }

    private static func writeOBJ(_ anchors: [MeshAnchorSnapshot], to url: URL,
                                 progress: (Double) -> Void) throws {
        let file = try ChunkedFile(url: url)
        do {
            try file.append("# Phone LiDAR mesh export\n# Units: metres, Y up\n")
            let total = Double(anchors.count * 3)
            var step = 0.0
            for a in anchors {
                var text = ""
                for p in a.vertices { text += "v \(p.x) \(p.y) \(p.z)\n" }
                try file.append(text)
                step += 1; progress(step / total)
            }
            for a in anchors {
                var text = ""
                for n in a.normals { text += "vn \(n.x) \(n.y) \(n.z)\n" }
                try file.append(text)
                step += 1; progress(step / total)
            }
            var base: UInt32 = 0
            for a in anchors {
                var text = ""
                var i = 0
                while i + 2 < a.indices.count {
                    let x = base + a.indices[i] + 1
                    let y = base + a.indices[i + 1] + 1
                    let z = base + a.indices[i + 2] + 1
                    text += "f \(x)//\(x) \(y)//\(y) \(z)//\(z)\n"
                    i += 3
                }
                try file.append(text)
                base += UInt32(a.vertices.count)
                step += 1; progress(step / total)
            }
            try file.close()
        } catch {
            try? file.handle.close()
            throw error
        }
    }

    private static func writePLY(_ anchors: [MeshAnchorSnapshot], vertexCount: Int, faceCount: Int,
                                 to url: URL, progress: (Double) -> Void) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Phone LiDAR mesh export, units metres, Y up
        element vertex \(vertexCount)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        element face \(faceCount)
        property list uchar int vertex_indices
        end_header

        """
        let file = try ChunkedFile(url: url)
        do {
            try file.append(header)
            func appendFloat(_ value: Float) {
                var le = value.bitPattern.littleEndian
                withUnsafeBytes(of: &le) { file.buffer.append(contentsOf: $0) }
            }
            func appendInt(_ value: Int32) {
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { file.buffer.append(contentsOf: $0) }
            }
            let total = Double(anchors.count * 2)
            var step = 0.0
            for a in anchors {
                for i in 0..<a.vertices.count {
                    let p = a.vertices[i]
                    let n = a.normals[i]
                    appendFloat(p.x); appendFloat(p.y); appendFloat(p.z)
                    appendFloat(n.x); appendFloat(n.y); appendFloat(n.z)
                }
                try file.flushIfLarge()
                step += 1; progress(step / total)
            }
            var base: UInt32 = 0
            for a in anchors {
                var f = 0
                while f + 2 < a.indices.count {
                    file.buffer.append(UInt8(3))
                    appendInt(Int32(bitPattern: base + a.indices[f]))
                    appendInt(Int32(bitPattern: base + a.indices[f + 1]))
                    appendInt(Int32(bitPattern: base + a.indices[f + 2]))
                    f += 3
                }
                base += UInt32(a.vertices.count)
                try file.flushIfLarge()
                step += 1; progress(step / total)
            }
            try file.close()
        } catch {
            try? file.handle.close()
            throw error
        }
    }

    /// USDZ lets the scan open in AR Quick Look (walk around it at real size). Returns false if SceneKit can't write it.
    /// One node per anchor, so the whole mesh is never copied into one more giant array.
    private static func writeUSDZ(_ anchors: [MeshAnchorSnapshot], to url: URL) -> Bool {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
        material.isDoubleSided = true

        let scene = SCNScene()
        for (index, a) in anchors.enumerated() {
            let vertexSource = SCNGeometrySource(vertices: a.vertices.map { SCNVector3($0.x, $0.y, $0.z) })
            let normalSource = SCNGeometrySource(normals: a.normals.map { SCNVector3($0.x, $0.y, $0.z) })
            let element = SCNGeometryElement(indices: a.indices, primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
            geometry.materials = [material]
            let node = SCNNode(geometry: geometry)
            node.name = "LidarMesh_\(index)"
            scene.rootNode.addChildNode(node)
        }
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
    }
}

extension ARGeometrySource {
    /// Reads a float3 vertex/normal at `index` from the Metal buffer.
    func float3(at index: Int) -> SIMD3<Float> {
        let pointer = buffer.contents().advanced(by: offset + stride * index)
        let x = pointer.load(fromByteOffset: 0, as: Float.self)
        let y = pointer.load(fromByteOffset: 4, as: Float.self)
        let z = pointer.load(fromByteOffset: 8, as: Float.self)
        return SIMD3<Float>(x, y, z)
    }
}

extension ARGeometryElement {
    /// Vertex index for one corner of one face.
    func index(primitive: Int, corner: Int) -> UInt32 {
        let byteOffset = (primitive * indexCountPerPrimitive + corner) * bytesPerIndex
        let pointer = buffer.contents().advanced(by: byteOffset)
        if bytesPerIndex == 2 {
            return UInt32(pointer.load(as: UInt16.self))
        }
        return pointer.load(as: UInt32.self)
    }
}
