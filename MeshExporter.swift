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

/// Merges ARKit mesh anchors into one world-space mesh (metres, Y up) and writes OBJ, PLY and USDZ.
@MainActor
enum MeshExporter {
    static func export(anchors: [ARMeshAnchor], to folder: URL, baseName: String) throws -> MeshExportResult {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for anchor in anchors {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let rotation = simd_float3x3(columns: (
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
            let base = UInt32(positions.count)

            let vertexSource = geometry.vertices
            let normalSource = geometry.normals
            for i in 0..<vertexSource.count {
                let local = vertexSource.float3(at: i)
                let world = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
                positions.append(SIMD3<Float>(world.x, world.y, world.z))

                var n = rotation * normalSource.float3(at: i)
                let len = simd_length(n)
                n = len > 0 ? n / len : SIMD3<Float>(0, 1, 0)
                normals.append(n)
            }

            let faces = geometry.faces
            let perFace = faces.indexCountPerPrimitive
            guard perFace == 3 else { continue }
            for f in 0..<faces.count {
                for k in 0..<3 {
                    indices.append(base + faces.index(primitive: f, corner: k))
                }
            }
        }

        guard !positions.isEmpty, !indices.isEmpty else { throw ScanError.noMesh }

        var minP = positions[0]
        var maxP = positions[0]
        for p in positions {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }

        try writeOBJ(positions: positions, normals: normals, indices: indices,
                     to: folder.appendingPathComponent("\(baseName).obj"))
        try writePLY(positions: positions, normals: normals, indices: indices,
                     to: folder.appendingPathComponent("\(baseName).ply"))
        let usdzOK = writeUSDZ(positions: positions, normals: normals, indices: indices,
                               to: folder.appendingPathComponent("\(baseName).usdz"))

        return MeshExportResult(vertexCount: positions.count,
                                faceCount: indices.count / 3,
                                usdzWritten: usdzOK,
                                boundsMin: minP,
                                boundsMax: maxP)
    }

    // MARK: - Writers

    private static func writeOBJ(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                                 indices: [UInt32], to url: URL) throws {
        var text = "# Phone LiDAR mesh export\n# Units: metres, Y up\n"
        text.reserveCapacity(positions.count * 64 + indices.count * 12)
        for p in positions {
            text += "v \(p.x) \(p.y) \(p.z)\n"
        }
        for n in normals {
            text += "vn \(n.x) \(n.y) \(n.z)\n"
        }
        var i = 0
        while i + 2 < indices.count {
            let a = indices[i] + 1
            let b = indices[i + 1] + 1
            let c = indices[i + 2] + 1
            text += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            i += 3
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writePLY(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                                 indices: [UInt32], to url: URL) throws {
        let faceCount = indices.count / 3
        let header = """
        ply
        format binary_little_endian 1.0
        comment Phone LiDAR mesh export, units metres, Y up
        element vertex \(positions.count)
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
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + positions.count * 24 + faceCount * 13)

        func appendFloat(_ value: Float) {
            var le = value.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendInt(_ value: Int32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        for i in 0..<positions.count {
            let p = positions[i]
            let n = normals[i]
            appendFloat(p.x); appendFloat(p.y); appendFloat(p.z)
            appendFloat(n.x); appendFloat(n.y); appendFloat(n.z)
        }
        for f in 0..<faceCount {
            data.append(UInt8(3))
            appendInt(Int32(bitPattern: indices[f * 3]))
            appendInt(Int32(bitPattern: indices[f * 3 + 1]))
            appendInt(Int32(bitPattern: indices[f * 3 + 2]))
        }
        try data.write(to: url, options: .atomic)
    }

    /// USDZ lets the scan open in AR Quick Look (walk around it at real size). Returns false if SceneKit can't write it.
    private static func writeUSDZ(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                                  indices: [UInt32], to url: URL) -> Bool {
        let vertexSource = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
        let normalSource = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.78, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "LidarMesh"
        let scene = SCNScene()
        scene.rootNode.addChildNode(node)
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
