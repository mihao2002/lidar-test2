//
//  ARWrapperView.swift
//  Lidar Scan
//
//  Created by Cedan Misquith on 27/04/25.
//

import SwiftUI
import RealityKit
import ARKit

struct ARWrapperView: UIViewRepresentable {
    @Binding var submittedExportRequest: Bool
    @Binding var submittedName: String
    @Binding var pauseSession: Bool
    @Binding var shouldSmoothMesh: Bool
    @Binding var showMeshOverlay: Bool
    let arView = ARView(frame: .zero)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ARView {
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        addCoordinateAxes()
        
        let configuration = buildConfigure()
        arView.session.run(configuration)
        
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        if submittedExportRequest {
            guard let meshAnchors = uiView.session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }), !meshAnchors.isEmpty else {
                print("No mesh anchors to export.")
                return
            }
            do {
                print("Attempting manual export...")
                try manualExport(meshAnchors: meshAnchors, fileName: submittedName)
                // Reset the request to prevent re-exporting on every view update
                DispatchQueue.main.async {
                    self.submittedExportRequest = false
                }
            } catch {
                print("Manual Export Failed: \(error)")
            }
        }
        
        if pauseSession {
            uiView.session.pause()
        }
    }
    
    private func buildConfigure() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        arView.automaticallyConfigureSession = false
        configuration.sceneReconstruction = .meshWithClassification
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        }
        return configuration
    }
    
    private func addCoordinateAxes() {
        let axisLength: Float = 0.1
        let axisThickness: Float = 0.002
        
        let axes = [
            (color: UIColor.red, size: SIMD3<Float>(axisLength, axisThickness, axisThickness), position: SIMD3<Float>(axisLength/2, 0, 0)),
            (color: UIColor.green, size: SIMD3<Float>(axisThickness, axisLength, axisThickness), position: SIMD3<Float>(0, axisLength/2, 0)),
            (color: UIColor.blue, size: SIMD3<Float>(axisThickness, axisThickness, axisLength), position: SIMD3<Float>(0, 0, axisLength/2))
        ]
        
        let axesAnchor = AnchorEntity(world: matrix_identity_float4x4)
        for axisInfo in axes {
            let axisEntity = ModelEntity(mesh: .generateBox(size: axisInfo.size))
            axisEntity.model?.materials = [SimpleMaterial(color: axisInfo.color, isMetallic: false)]
            axisEntity.position = axisInfo.position
            axesAnchor.addChild(axisEntity)
        }
        arView.scene.addAnchor(axesAnchor)
    }
    
    private func manualExport(meshAnchors: [ARMeshAnchor], fileName: String) throws {
        var objString = "# Manually exported OBJ\n"
        var vertexCountOffset: UInt32 = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            for i in 0..<geometry.vertices.count {
                let localVertex = geometry.vertex(at: UInt32(i))
                let worldVertex = (transform * SIMD4<Float>(localVertex, 1)).xyz
                objString += "v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)\n"
            }

            let faces = geometry.faces
            if faces.primitiveType == .triangle {
                if faces.bytesPerIndex == 4 { // UInt32
                    let pointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
                    for i in 0..<faces.count {
                        let base = i * faces.indexCountPerPrimitive
                        let v0 = pointer[base + 0] + vertexCountOffset
                        let v1 = pointer[base + 1] + vertexCountOffset
                        let v2 = pointer[base + 2] + vertexCountOffset
                        objString += "f \(v0 + 1) \(v1 + 1) \(v2 + 1)\n"
                    }
                } else { // UInt16
                    let pointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
                    for i in 0..<faces.count {
                        let base = i * faces.indexCountPerPrimitive
                        let v0 = UInt32(pointer[base + 0]) + vertexCountOffset
                        let v1 = UInt32(pointer[base + 1]) + vertexCountOffset
                        let v2 = UInt32(pointer[base + 2]) + vertexCountOffset
                        objString += "f \(v0 + 1) \(v1 + 1) \(v2 + 1)\n"
                    }
                }
            }
            vertexCountOffset += UInt32(geometry.vertices.count)
        }

        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folderURL = directory.appendingPathComponent("OBJ_FILES")
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        
        let baseName = fileName.isEmpty ? UUID().uuidString : fileName
        let url = folderURL.appendingPathComponent("\(baseName).obj")
        
        try objString.write(to: url, atomically: true, encoding: .utf8)
        print("Manual export saved successfully at \(url)")
    }

    class Coordinator: NSObject, ARSessionDelegate {
        var parent: ARWrapperView
        weak var arView: ARView?
        var customMeshEntity: ModelEntity?
        var smoothedMeshEntity: ModelEntity?
        var ceilingMeshEntity: ModelEntity?
        var originalPositions: [SIMD3<Float>] = []
        var originalIndices: [UInt32] = []

        // --- New properties for Concave Polygon Ceiling Detection ---
        private var ceilingPolygon: [SIMD2<Float>] = []
        private var ceilingHeight: Float?
        private let pointInPolygonProximity: Float = 0.1 // 10cm tolerance

        init(parent: ARWrapperView) {
            self.parent = parent
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            let meshAnchors = session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }) ?? []
            if meshAnchors.isEmpty { return }

            DispatchQueue.global().async {
                let (meshResource, positions, indices, polygonUpdated) = self.generateLiveMeshAndStore(meshAnchors)
                DispatchQueue.main.async {
                    self.originalPositions = positions
                    self.originalIndices = indices

                    if self.parent.showMeshOverlay {
                        if self.parent.shouldSmoothMesh {
                            self.showSmoothedMesh()
                        } else {
                            self.showOriginalMesh(meshResource)
                        }
                    } else {
                        if let entity = self.customMeshEntity {
                            entity.removeFromParent()
                            self.customMeshEntity = nil
                        }
                        if let entity = self.smoothedMeshEntity {
                            entity.removeFromParent()
                            self.smoothedMeshEntity = nil
                        }
                    }

                    // If the ceiling polygon was updated, redraw the ceiling mesh
                    if polygonUpdated {
                        self.updateCeilingEntityFromPolygon()
                    }
                }
            }
        }

        func makeEmptyMesh() -> MeshResource {
            let emptyDescriptor = MeshDescriptor(name: "EmptyMesh")
            let mesh = try! MeshResource.generate(from: [emptyDescriptor])
            return mesh
        }

        private func generateLiveMeshAndStore(_ meshAnchors: [ARMeshAnchor]) -> (MeshResource, [SIMD3<Float>], [UInt32], Bool) {
            var allVertices: [SIMD3<Float>] = []
            var allIndices: [UInt32] = []
            var vertexCountOffset: UInt32 = 0
            var polygonUpdated = false

            struct Edge: Hashable {
                let a: UInt32
                let b: UInt32
                init(_ a: UInt32, _ b: UInt32) {
                    self.a = a < b ? a : b
                    self.b = a < b ? b : a
                }
            }
            var edgeToTriangles: [Edge: [Int]] = [:]
            var triangles: [(indices: [UInt32], normal: SIMD3<Float>)] = []

            for anchor in meshAnchors {
                let geometry = anchor.geometry
                let transform = anchor.transform

                let verticesStartIndex = allVertices.count
                for i in 0..<geometry.vertices.count {
                    let localVertex = geometry.vertex(at: UInt32(i))
                    let worldVertex = (transform * SIMD4<Float>(localVertex, 1)).xyz
                    allVertices.append(worldVertex)
                }

                if detectAndUpdateCeilingPolygon(geometry: geometry, transform: transform) {
                    polygonUpdated = true
                }

                let faces = geometry.faces
                if faces.primitiveType == .triangle {
                    if faces.bytesPerIndex == 4 { // UInt32
                        let pointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
                        for i in 0..<faces.count {
                            let base = i * faces.indexCountPerPrimitive
                            let v0 = pointer[base + 0] + vertexCountOffset
                            let v1 = pointer[base + 1] + vertexCountOffset
                            let v2 = pointer[base + 2] + vertexCountOffset
                            let triIndices = [v0, v1, v2]
                            let normal = normalForTriangle(v0, v1, v2, allVertices)
                            triangles.append((triIndices, normal))
                        }
                    } else { // UInt16
                        let pointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
                        for i in 0..<faces.count {
                            let base = i * faces.indexCountPerPrimitive
                            let v0 = UInt32(pointer[base + 0]) + vertexCountOffset
                            let v1 = UInt32(pointer[base + 1]) + vertexCountOffset
                            let v2 = UInt32(pointer[base + 2]) + vertexCountOffset
                            let triIndices = [v0, v1, v2]
                            let normal = normalForTriangle(v0, v1, v2, allVertices)
                            triangles.append((triIndices, normal))
                        }
                    }
                }
                vertexCountOffset += UInt32(geometry.vertices.count)
            }

            for tri in triangles {
                allIndices.append(contentsOf: tri.indices)
            }

            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(allVertices)
            descriptor.primitives = .triangles(allIndices)
            let mesh = (try? MeshResource.generate(from: [descriptor])) ?? makeEmptyMesh()
            return (mesh, allVertices, allIndices, polygonUpdated)
        }

        private func normalForTriangle(_ v0: UInt32, _ v1: UInt32, _ v2: UInt32, _ vertices: [SIMD3<Float>]) -> SIMD3<Float> {
            guard Int(v0) < vertices.count, Int(v1) < vertices.count, Int(v2) < vertices.count else { return .zero }
            let p0 = vertices[Int(v0)]
            let p1 = vertices[Int(v1)]
            let p2 = vertices[Int(v2)]
            return simd_cross(p1 - p0, p2 - p0)
        }

        private func showOriginalMesh(_ resource: MeshResource) {
            if let smoothed = smoothedMeshEntity {
                smoothed.removeFromParent()
                smoothedMeshEntity = nil
            }
            if let entity = customMeshEntity {
                entity.model?.mesh = resource
            } else {
                let material = SimpleMaterial(color: .green, isMetallic: false)
                let newEntity = ModelEntity(mesh: resource, materials: [material])
                let anchor = AnchorEntity(world: matrix_identity_float4x4)
                anchor.addChild(newEntity)
                arView?.scene.addAnchor(anchor)
                customMeshEntity = newEntity
            }
        }
        
        private func showSmoothedMesh() {
            if let original = customMeshEntity {
                original.removeFromParent()
                customMeshEntity = nil
            }
            if let smoothed = smoothedMeshEntity {
                // Re-smooth and update
                let (smoothedMesh, _) = self.laplacianSmooth(self.originalPositions, self.originalIndices)
                smoothed.model?.mesh = smoothedMesh
            } else {
                let (smoothedMesh, _) = self.laplacianSmooth(self.originalPositions, self.originalIndices)
                let material = SimpleMaterial(color: .blue, isMetallic: false)
                let newEntity = ModelEntity(mesh: smoothedMesh, materials: [material])
                let anchor = AnchorEntity(world: matrix_identity_float4x4)
                anchor.addChild(newEntity)
                arView?.scene.addAnchor(anchor)
                smoothedMeshEntity = newEntity
            }
        }
        
        private func laplacianSmooth(_ positions: [SIMD3<Float>], _ indices: [UInt32], iterations: Int = 1) -> (MeshResource, [UInt32]) {
            var positions = positions
            let indices = indices
            // Build adjacency
            var adjacency = Array(repeating: Set<Int>(), count: positions.count)
            for i in stride(from: 0, to: indices.count, by: 3) {
                let v0 = Int(indices[i])
                let v1 = Int(indices[i+1])
                let v2 = Int(indices[i+2])
                adjacency[v0].formUnion([v1, v2])
                adjacency[v1].formUnion([v0, v2])
                adjacency[v2].formUnion([v0, v1])
            }
            // Smooth
            for _ in 0..<iterations {
                var newPositions = positions
                for i in 0..<positions.count {
                    let neighbors = adjacency[i]
                    guard !neighbors.isEmpty else { continue }
                    var avg = SIMD3<Float>(repeating: 0)
                    for n in neighbors { avg += positions[n] }
                    avg /= Float(neighbors.count)
                    newPositions[i] = avg
                }
                positions = newPositions
            }
            // Create new mesh
            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(positions)
            descriptor.primitives = .triangles(indices)
            let smoothedMesh = (try? MeshResource.generate(from: [descriptor])) ?? makeEmptyMesh()
            return (smoothedMesh, indices)
        }

        // --- New Ceiling Detection Methods ---

        private func detectAndUpdateCeilingPolygon(geometry: ARMeshGeometry, transform: simd_float4x4) -> Bool {
            let faces = geometry.faces
            guard faces.primitiveType == .triangle else { return false }
            var polygonWasUpdated = false

            let processFace = { (v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>) in
                let worldV0 = (transform * SIMD4<Float>(v0, 1)).xyz
                let worldV1 = (transform * SIMD4<Float>(v1, 1)).xyz
                let worldV2 = (transform * SIMD4<Float>(v2, 1)).xyz
                let normal = normalize(cross(worldV1 - worldV0, worldV2 - worldV0))

                if normal.y < -0.5 { // Stricter downward normal check
                    let faceCenterY = (worldV0.y + worldV1.y + worldV2.y) / 3.0
                    if self.ceilingHeight == nil {
                        self.ceilingHeight = faceCenterY
                        self.ceilingPolygon = [worldV0.xz, worldV1.xz, worldV2.xz].uniquePoints(minDistance: self.pointInPolygonProximity)
                        polygonWasUpdated = true
                        return
                    }

                    guard abs(faceCenterY - self.ceilingHeight!) < 0.3 else { return }

                    for vertex in [worldV0, worldV1, worldV2] {
                        if self.addPointToConcavePolygon(point: vertex.xz) {
                            polygonWasUpdated = true
                        }
                    }
                }
            }

            if faces.bytesPerIndex == 4 {
                let pointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
                for i in 0..<faces.count {
                    let base = i * faces.indexCountPerPrimitive
                    processFace(geometry.vertex(at: pointer[base]), geometry.vertex(at: pointer[base + 1]), geometry.vertex(at: pointer[base + 2]))
                }
            } else {
                let pointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
                for i in 0..<faces.count {
                    let base = i * faces.indexCountPerPrimitive
                    processFace(geometry.vertex(at: UInt32(pointer[base])), geometry.vertex(at: UInt32(pointer[base + 1])), geometry.vertex(at: UInt32(pointer[base + 2])))
                }
            }
            return polygonWasUpdated
        }

        private func addPointToConcavePolygon(point: SIMD2<Float>) -> Bool {
            guard !isPointInsidePolygon(point: point, polygon: ceilingPolygon, tolerance: pointInPolygonProximity) else {
                return false
            }

            var closestEdgeIndex = -1
            var minDistance = Float.greatestFiniteMagnitude

            for i in 0..<ceilingPolygon.count {
                let p1 = ceilingPolygon[i]
                let p2 = ceilingPolygon[(i + 1) % ceilingPolygon.count]
                let edgeCenter = (p1 + p2) / 2
                let distance = simd_distance(point, edgeCenter)
                if distance < minDistance {
                    minDistance = distance
                    closestEdgeIndex = i
                }
            }

            if closestEdgeIndex != -1 {
                ceilingPolygon.insert(point, at: closestEdgeIndex + 1)
                return true
            }
            return false
        }

        private func isPointInsidePolygon(point: SIMD2<Float>, polygon: [SIMD2<Float>], tolerance: Float) -> Bool {
            guard !polygon.isEmpty else { return false }

            // 1. Check proximity to edges first
            for i in 0..<polygon.count {
                let p1 = polygon[i]
                let p2 = polygon[(i + 1) % polygon.count]
                if distanceToEdge(point: point, edgeP1: p1, edgeP2: p2) < tolerance {
                    return true
                }
            }

            // 2. Ray-casting algorithm
            var crossings = 0
            for i in 0..<polygon.count {
                let p1 = polygon[i]
                let p2 = polygon[(i + 1) % polygon.count]

                if ((p1.y > point.y) != (p2.y > point.y)) &&
                   (point.x < (p2.x - p1.x) * (point.y - p1.y) / (p2.y - p1.y) + p1.x) {
                    crossings += 1
                }
            }
            return (crossings % 2) == 1
        }

        private func distanceToEdge(point: SIMD2<Float>, edgeP1: SIMD2<Float>, edgeP2: SIMD2<Float>) -> Float {
            let l2 = simd_distance_squared(edgeP1, edgeP2)
            if l2 == 0.0 { return simd_distance(point, edgeP1) }
            let t = max(0, min(1, simd_dot(point - edgeP1, edgeP2 - edgeP1) / l2))
            let projection = edgeP1 + t * (edgeP2 - edgeP1)
            return simd_distance(point, projection)
        }

        private func updateCeilingEntityFromPolygon() {
            guard ceilingPolygon.count >= 3, let height = ceilingHeight else { return }

            let vertices = ceilingPolygon.map { SIMD3<Float>($0.x, height, $0.y) }
            
            var indices: [UInt32] = []
            for i in 1..<(vertices.count - 1) {
                indices.append(0)
                indices.append(UInt32(i))
                indices.append(UInt32(i + 1))
            }

            var descriptor = MeshDescriptor(name: "ceiling")
            descriptor.positions = MeshBuffer(vertices)
            descriptor.primitives = .triangles(indices)

            do {
                let mesh = try MeshResource.generate(from: [descriptor])
                if let entity = ceilingMeshEntity {
                    entity.model?.mesh = mesh
                } else {
                    let material = SimpleMaterial(color: .orange, isMetallic: false)
                    let newEntity = ModelEntity(mesh: mesh, materials: [material])
                    let anchor = AnchorEntity(world: matrix_identity_float4x4)
                    anchor.addChild(newEntity)
                    arView?.scene.addAnchor(anchor)
                    ceilingMeshEntity = newEntity
                }
            } catch {
                print("Failed to create ceiling mesh from polygon: \(error)")
            }
        }
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}

extension SIMD3 where Scalar == Float {
    var xz: SIMD2<Float> {
        SIMD2<Float>(x, z)
    }
}

extension Array where Element == SIMD2<Float> {
    func uniquePoints(minDistance: Float) -> [Element] {
        var unique = [Element]()
        for point in self {
            if !unique.contains(where: { simd_distance($0, point) < minDistance }) {
                unique.append(point)
            }
        }
        return unique
    }
}
