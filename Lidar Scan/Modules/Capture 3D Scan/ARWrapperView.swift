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
        let coordinator = Coordinator(parent: self)
        // Start the timer after the coordinator is fully initialized.
        coordinator.startCeilingMeshTimer()
        return coordinator
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
        
        // --- Properties for Ceiling Detection ---
        private var pendingCeilingFaces: [(vertices: [SIMD3<Float>], normal: SIMD3<Float>, center: SIMD3<Float>)] = []
        private let pendingCeilingFacesQueue = DispatchQueue(label: "pendingCeilingFacesQueue")
        private var latestCeilingMesh: ([SIMD3<Float>], [UInt32])?
        private let latestCeilingMeshQueue = DispatchQueue(label: "latestCeilingMeshQueue")
        private var ceilingMeshTimer: Timer?
        private let ceilingHeightTolerance: Float = 0.3 // 30cm tolerance for ceiling height variation

        init(parent: ARWrapperView) {
            self.parent = parent
        }

        deinit {
            ceilingMeshTimer?.invalidate()
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            let meshAnchors = session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }) ?? []
            if meshAnchors.isEmpty { return }
            
            DispatchQueue.global().async {
                let (meshResource, positions, indices) = self.generateLiveMeshAndStore(meshAnchors)
                DispatchQueue.main.async {
                    self.originalPositions = positions
                    self.originalIndices = indices

                    if self.parent.showMeshOverlay {
                        // If the overlay should be shown, run the existing logic.
                        if self.parent.shouldSmoothMesh {
                            self.showSmoothedMesh()
                        } else {
                            self.showOriginalMesh(meshResource)
                        }
                    } else {
                        // If the overlay should be hidden, remove the entities.
                        if let entity = self.customMeshEntity {
                            entity.removeFromParent()
                            self.customMeshEntity = nil
                        }
                        if let entity = self.smoothedMeshEntity {
                            entity.removeFromParent()
                            self.smoothedMeshEntity = nil
                        }
                    }

                    // Update the ceiling mesh if new data is available
                    self.updateCeilingEntityIfNeeded()
                }
            }
        }

        func makeEmptyMesh() -> MeshResource {
            let emptyDescriptor = MeshDescriptor(name: "EmptyMesh")
            let mesh = try! MeshResource.generate(from: [emptyDescriptor])
            return mesh
        }
        
        private func generateLiveMeshAndStore(_ meshAnchors: [ARMeshAnchor]) -> (MeshResource, [SIMD3<Float>], [UInt32]) {
            var allVertices: [SIMD3<Float>] = []
            var allIndices: [UInt32] = []
            var vertexCountOffset: UInt32 = 0
            struct Edge: Hashable {
                let a: UInt32
                let b: UInt32
                init(_ a: UInt32, _ b: UInt32) {
                    if a < b {
                        self.a = a
                        self.b = b
                    } else {
                        self.a = b
                        self.b = a
                    }
                }
            }
            var edgeToTriangles: [Edge: [Int]] = [:]
            var triangles: [(indices: [UInt32], normal: SIMD3<Float>)] = []

            for anchor in meshAnchors {
                let geometry = anchor.geometry
                let transform = anchor.transform

                for i in 0..<geometry.vertices.count {
                    let localVertex = geometry.vertex(at: UInt32(i))
                    let worldVertex = (transform * SIMD4<Float>(localVertex, 1)).xyz
                    allVertices.append(worldVertex)
                }
                
                // Detect ceiling faces to be processed in the background
                detectCeilingFaces(geometry: geometry, transform: transform)
                
                let faces = geometry.faces
                if faces.primitiveType == .triangle {
                    if faces.bytesPerIndex == 4 {
                        let pointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
                        for i in 0..<faces.count {
                            let base = i * faces.indexCountPerPrimitive
                            let v0 = pointer[base + 0] + vertexCountOffset
                            let v1 = pointer[base + 1] + vertexCountOffset
                            let v2 = pointer[base + 2] + vertexCountOffset
                            let triIndices = [v0, v1, v2]
                            let normal = normalForTriangle(v0, v1, v2, allVertices)
                            triangles.append((triIndices, normal))
                            for e in [(v0,v1), (v1,v2), (v2,v0)] {
                                let edge = Edge(e.0, e.1)
                                edgeToTriangles[edge, default: []].append(triangles.count-1)
                            }
                        }
                    } else {
                        let pointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
                        for i in 0..<faces.count {
                            let base = i * faces.indexCountPerPrimitive
                            let v0 = UInt32(pointer[base + 0]) + vertexCountOffset
                            let v1 = UInt32(pointer[base + 1]) + vertexCountOffset
                            let v2 = UInt32(pointer[base + 2]) + vertexCountOffset
                            let triIndices = [v0, v1, v2]
                            let normal = normalForTriangle(v0, v1, v2, allVertices)
                            triangles.append((triIndices, normal))
                            for e in [(v0,v1), (v1,v2), (v2,v0)] {
                                let edge = Edge(e.0, e.1)
                                edgeToTriangles[edge, default: []].append(triangles.count-1)
                            }
                        }
                    }
                }
                vertexCountOffset += UInt32(geometry.vertices.count)
            }

            // Denoising logic removed, now collecting all triangle indices
            for tri in triangles {
                allIndices.append(contentsOf: tri.indices)
            }

            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(allVertices)
            descriptor.primitives = .triangles(allIndices)
            let mesh = (try? MeshResource.generate(from: [descriptor])) ?? makeEmptyMesh()
            return (mesh, allVertices, allIndices)
        }

        // Helper to compute normal for a triangle
        private func normalForTriangle(_ v0: UInt32, _ v1: UInt32, _ v2: UInt32, _ vertices: [SIMD3<Float>]) -> SIMD3<Float> {
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

        // --- Ceiling Detection Methods ---

        public func startCeilingMeshTimer() {
            // This timer triggers the background processing of collected ceiling faces.
            self.ceilingMeshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.processCeilingFacesInBackground()
            }
        }

        private func detectCeilingFaces(geometry: ARMeshGeometry, transform: simd_float4x4) {
            // This function runs in-line with the mesh update to identify potential ceiling faces.
            let faces = geometry.faces
            guard faces.primitiveType == .triangle else { return }

            if faces.bytesPerIndex == 4 { // UInt32
                let pointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
                for i in 0..<faces.count {
                    let base = i * faces.indexCountPerPrimitive
                    let v0 = geometry.vertex(at: pointer[base])
                    let v1 = geometry.vertex(at: pointer[base + 1])
                    let v2 = geometry.vertex(at: pointer[base + 2])
                    processCeilingFace(v0: v0, v1: v1, v2: v2, transform: transform)
                }
            } else { // UInt16
                let pointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
                for i in 0..<faces.count {
                    let base = i * faces.indexCountPerPrimitive
                    let v0 = geometry.vertex(at: UInt32(pointer[base]))
                    let v1 = geometry.vertex(at: UInt32(pointer[base + 1]))
                    let v2 = geometry.vertex(at: UInt32(pointer[base + 2]))
                    processCeilingFace(v0: v0, v1: v1, v2: v2, transform: transform)
                }
            }
        }

        private func processCeilingFace(v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>, transform: simd_float4x4) {
            // This function calculates the normal and adds the face to a pending queue if it's a ceiling candidate.
            let worldV0 = (transform * SIMD4<Float>(v0, 1)).xyz
            let worldV1 = (transform * SIMD4<Float>(v1, 1)).xyz
            let worldV2 = (transform * SIMD4<Float>(v2, 1)).xyz

            let edge1 = worldV1 - worldV0
            let edge2 = worldV2 - worldV0
            let normal = normalize(cross(edge1, edge2))

            // A downward-pointing normal is a strong indicator of a ceiling surface.
            if normal.y < -0.3 {
                let center = (worldV0 + worldV1 + worldV2) / 3.0
                let faceData = (vertices: [worldV0, worldV1, worldV2], normal: normal, center: center)
                // Add the face data to the queue for background processing.
                pendingCeilingFacesQueue.async {
                    self.pendingCeilingFaces.append(faceData)
                }
            }
        }

        private func processCeilingFacesInBackground() {
            // This function moves the collected faces to a local array and kicks off the mesh building.
            pendingCeilingFacesQueue.async {
                let faces = self.pendingCeilingFaces
                self.pendingCeilingFaces.removeAll()
                
                guard !faces.isEmpty else { return }
                
                let (vertices, indices) = self.buildCeilingMesh(from: faces)
                
                // Once the mesh is built, store it for the main thread to pick up.
                self.latestCeilingMeshQueue.async {
                    self.latestCeilingMesh = (vertices, indices)
                }
            }
        }

        private func buildCeilingMesh(from faces: [(vertices: [SIMD3<Float>], normal: SIMD3<Float>, center: SIMD3<Float>)]) -> ([SIMD3<Float>], [UInt32]) {
            // This function identifies the primary ceiling height and builds a mesh from faces in that cluster.
            guard !faces.isEmpty else { return ([], []) }

            let heights = faces.map { $0.center.y }
            let sortedHeights = heights.sorted()
            
            // Use a sliding window to find the densest cluster of heights.
            var bestCount = 0
            var bestStart = 0
            for i in 0..<sortedHeights.count {
                let startHeight = sortedHeights[i]
                let endHeight = startHeight + ceilingHeightTolerance
                let count = sortedHeights[i...].prefix { $0 <= endHeight }.count
                if count > bestCount {
                    bestCount = count
                    bestStart = i
                }
            }

            if bestCount == 0 || bestStart >= sortedHeights.count { return ([], []) }
            
            let ceilingBase = sortedHeights[bestStart]
            let ceilingMax = ceilingBase + ceilingHeightTolerance
            let ceilingFaces = faces.filter { $0.center.y >= ceilingBase && $0.center.y <= ceilingMax }
            if ceilingFaces.isEmpty { return ([], []) }

            var ceilingVertices: [SIMD3<Float>] = []
            var ceilingIndices: [UInt32] = []

            // Create a new mesh from the filtered ceiling faces.
            for face in ceilingFaces {
                let baseIndex = UInt32(ceilingVertices.count)
                ceilingVertices.append(contentsOf: face.vertices)
                ceilingIndices.append(baseIndex)
                ceilingIndices.append(baseIndex + 1)
                ceilingIndices.append(baseIndex + 2)
            }

            return (ceilingVertices, ceilingIndices)
        }

        private func updateCeilingEntityIfNeeded() {
            // This function checks if a new ceiling mesh is available and, if so, dispatches an update on the main thread.
            latestCeilingMeshQueue.sync {
                if let (vertices, indices) = self.latestCeilingMesh {
                    DispatchQueue.main.async {
                        self.updateCeilingEntityWith(vertices: vertices, indices: indices)
                    }
                    self.latestCeilingMesh = nil
                }
            }
        }

        private func updateCeilingEntityWith(vertices: [SIMD3<Float>], indices: [UInt32]) {
            // This function runs on the main thread to safely update the RealityKit scene.
            guard !vertices.isEmpty, !indices.isEmpty else { return }
            
            var descriptor = MeshDescriptor()
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
                print("Debug: Failed to update/create ceiling mesh: \(error)")
            }
        }
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}
