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
        var originalPositions: [SIMD3<Float>] = []
        var originalIndices: [UInt32] = []

        init(parent: ARWrapperView) {
            self.parent = parent
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            let meshAnchors = session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }) ?? []
            if meshAnchors.isEmpty { return }
            
            DispatchQueue.global().async {
                let (meshResource, positions, indices) = self.generateLiveMeshAndStore(meshAnchors)
                DispatchQueue.main.async {
                    self.originalPositions = positions
                    self.originalIndices = indices
                    if self.parent.shouldSmoothMesh {
                        self.showSmoothedMesh()
                    } else {
                        self.showOriginalMesh(meshResource)
                    }
                }
            }
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

            // Denoising: Remove one triangle from each pair of nearly coplanar adjacent triangles
            let angleThreshold: Float = .pi / 18 // 10 degrees
            var toRemove = Set<Int>()
            for (_, triIndices) in edgeToTriangles where triIndices.count == 2 {
                let t0 = triIndices[0]
                let t1 = triIndices[1]
                let n0 = triangles[t0].normal
                let n1 = triangles[t1].normal
                let dot = simd_dot(simd_normalize(n0), simd_normalize(n1))
                if dot > cos(angleThreshold) {
                    toRemove.insert(t1)
                }
            }
            for (i, tri) in triangles.enumerated() where !toRemove.contains(i) {
                allIndices.append(contentsOf: tri.indices)
            }

            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(allVertices)
            descriptor.primitives = .triangles(allIndices)
            let mesh = (try? MeshResource.generate(from: [descriptor])) ?? MeshResource(from: <#MeshResource.Contents#>)
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
            let smoothedMesh = try? MeshResource.generate(from: [descriptor])
            return (smoothedMesh ?? MeshResource(from: <#MeshResource.Contents#>), indices)
        }
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}
