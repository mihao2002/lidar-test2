//
//  ARWrapperView.swift
//  Lidar Scan
//
//  Created by Cedan Misquith on 27/04/25.
//

import SwiftUI
import RealityKit
import ARKit

final class SharedARView {
    static let instance: ARView = {
        let arView = ARView(frame: .zero)
        // Any one-time configuration can go here
        return arView
    }()
}

struct ARWrapperView: UIViewRepresentable {
    @Binding var submittedExportRequest: Bool
    @Binding var submittedName: String
    @Binding var pauseSession: Bool
    @Binding var shouldSmoothMesh: Bool
    @Binding var showMeshOverlay: Bool
    @Binding var ceilingPointCount: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = SharedARView.instance
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        // Only configure session if not already running
        if arView.session.currentFrame == nil {
            let configuration = buildConfigure()
            arView.session.run(configuration)
            addCoordinateAxes(to: arView)
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // Do nothing, or only minimal updates
    }
    
    private func buildConfigure() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.environmentTexturing = .automatic
        configuration.sceneReconstruction = .meshWithClassification
        if type(of: configuration).supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics = .sceneDepth
        }
        return configuration
    }
    
    private func addCoordinateAxes(to arView: ARView) {
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

        // --- New properties for Convex Hull Ceiling Detection ---
        private var ceilingPolygon: [SIMD2<Float>] = [] // The calculated convex hull
        private var ceilingHeight: Float?

        // A serial queue to ensure mesh processing is not concurrent.
        private let meshProcessingQueue = DispatchQueue(label: "com.lidar-test.meshProcessingQueue")

        init(parent: ARWrapperView) {
            self.parent = parent
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            // Only process anchors that have been updated in this frame.
            let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
            if meshAnchors.isEmpty { return }

            meshProcessingQueue.async {
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
                        // Update the point count on the main UI
                        self.parent.ceilingPointCount = self.ceilingPolygon.count

                        //self.parent.ceilingPointCount =  self.ceilingPolygon.count
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

                if detectAndUpdateCeiling(geometry: geometry, transform: transform) {
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

        private func detectAndUpdateCeiling(geometry: ARMeshGeometry, transform: simd_float4x4) -> Bool {
            let vertexCount = geometry.vertices.count
            var newPoints: [SIMD2<Float>] = []
            let heightThreshold: Float = 0.1 // 10cm
            
            // Collect all world vertices to find the ceiling height
            var worldVertices: [SIMD3<Float>] = []
            for i in 0..<vertexCount {
                let localVertex = geometry.vertex(at: UInt32(i))
                let worldVertex = (transform * SIMD4<Float>(localVertex, 1)).xyz
                worldVertices.append(worldVertex)
            }
            
            // Find the ceiling height (highest points in the mesh)
            if self.ceilingHeight == nil {
                // Sort vertices by Y coordinate and take the top 10% as potential ceiling points
                let sortedVertices = worldVertices.sorted { $0.y > $1.y }
                let topCount = max(1, sortedVertices.count / 10) // Top 10%
                let topVertices = Array(sortedVertices.prefix(topCount))
                
                // Calculate average height of top vertices
                let totalHeight = topVertices.reduce(0) { $0 + $1.y }
                self.ceilingHeight = totalHeight / Float(topVertices.count)
                
                print("[Ceiling] Detected ceiling height: \(self.ceilingHeight!)")
            }
            
            guard let ceilingY = self.ceilingHeight else { return false }
            
            // Find points near the ceiling height
            for worldVertex in worldVertices {
                let y = worldVertex.y
                if abs(y - ceilingY) < heightThreshold {
                    newPoints.append(worldVertex.xz)
                }
            }

            if !newPoints.isEmpty {
                print("[Ceiling] New points: \(newPoints.count), Old hull: \(self.ceilingPolygon.count)")
                let pointsToProcess = (self.ceilingPolygon + newPoints).uniquePoints(minDistance: 0.05)
                print("[Ceiling] Points to process for hull: \(pointsToProcess.count)")
                self.ceilingPolygon = self.convexHull(points: pointsToProcess)
                print("[Ceiling] Hull points after convex hull: \(self.ceilingPolygon.count)")
                return true
            }

            return false
        }

        private func convexHull(points: [SIMD2<Float>]) -> [SIMD2<Float>] {
            guard points.count > 2 else { return points }

            // Sort points lexicographically
            let sortedPoints = points.sorted { a, b in
                a.x < b.x || (a.x == b.x && a.y < b.y)
            }

            var lower: [SIMD2<Float>] = []
            for p in sortedPoints {
                while lower.count >= 2 && crossProduct(o: lower[lower.count - 2], a: lower.last!, b: p) <= 0 {
                    lower.removeLast()
                }
                lower.append(p)
            }

            var upper: [SIMD2<Float>] = []
            for p in sortedPoints.reversed() {
                while upper.count >= 2 && crossProduct(o: upper[upper.count - 2], a: upper.last!, b: p) <= 0 {
                    upper.removeLast()
                }
                upper.append(p)
            }
            
            // removeLast() to avoid duplicating the start/end points.
            let hull = Array(lower.dropLast() + upper.dropLast())
            
            // Remove short sides from the polygon
            return removeShortSides(from: hull, minSideLength: 0.2) // 20cm = 0.2m
        }
        
        // Remove sides shorter than minSideLength by extending adjacent sides
        private func removeShortSides(from polygon: [SIMD2<Float>], minSideLength: Float) -> [SIMD2<Float>] {
            guard polygon.count >= 4 else { return polygon } // Need at least 4 points to remove a side
            
            var result = polygon
            var modified = true
            
            while modified && result.count >= 4 {
                modified = false
                
                for i in 0..<result.count {
                    let current = result[i]
                    let next = result[(i + 1) % result.count]
                    let sideLength = simd_distance(current, next)
                    
                    if sideLength < minSideLength {
                        // Find the previous and next points
                        let prev = result[(i - 1 + result.count) % result.count]
                        let nextNext = result[(i + 2) % result.count]
                        
                        // Calculate the direction vectors
                        let prevToCurrent = normalize(current - prev)
                        let nextToNextNext = normalize(nextNext - next)
                        
                        // Find intersection of extended lines
                        if let intersection = lineIntersection(
                            line1Start: prev,
                            line1End: current,
                            line2Start: next,
                            line2End: nextNext
                        ) {
                            // Replace the short side with the intersection point
                            result[i] = intersection
                            result.remove(at: (i + 1) % result.count)
                            
                            // Adjust index if we removed a point before current position
                            if (i + 1) % result.count <= i {
                                // No adjustment needed
                            }
                            
                            modified = true
                            break // Restart the loop since we modified the polygon
                        }
                    }
                }
            }
            
            return result
        }
        
        // Calculate intersection of two lines
        private func lineIntersection(line1Start: SIMD2<Float>, line1End: SIMD2<Float>, 
                                    line2Start: SIMD2<Float>, line2End: SIMD2<Float>) -> SIMD2<Float>? {
            let p1 = line1Start
            let p2 = line1End
            let p3 = line2Start
            let p4 = line2End
            
            let denominator = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
            
            // Lines are parallel
            if abs(denominator) < 1e-6 {
                return nil
            }
            
            let t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / denominator
            
            // Check if intersection is within reasonable bounds
            if t < -10 || t > 10 {
                return nil
            }
            
            let intersection = SIMD2<Float>(
                p1.x + t * (p2.x - p1.x),
                p1.y + t * (p2.y - p1.y)
            )
            
            return intersection
        }
        
        // Helper function to normalize a 2D vector
        private func normalize(_ vector: SIMD2<Float>) -> SIMD2<Float> {
            let length = simd_length(vector)
            guard length > 1e-6 else { return SIMD2<Float>(0, 0) }
            return vector / length
        }
        
        // Helper for convex hull: 2D cross product.
        private func crossProduct(o: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
            return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
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
