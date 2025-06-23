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

        init(parent: ARWrapperView) {
            self.parent = parent
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // We use didUpdate frame instead of didUpdate anchors to get access to the camera image
            guard let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor }), !meshAnchors.isEmpty else { return }
            
            DispatchQueue.global().async {
                let (meshResource, texture) = self.generateTexturedMesh(from: meshAnchors, in: frame)
                
                DispatchQueue.main.async {
                    if let mesh = meshResource, let tex = texture {
                        self.updateCustomMesh(with: mesh, texture: tex)
                    }
                }
            }
        }
        
        private func generateTexturedMesh(from meshAnchors: [ARMeshAnchor], in frame: ARFrame) -> (MeshResource?, TextureResource?) {
            var allVertices: [SIMD3<Float>] = []
            var allTexCoords: [SIMD2<Float>] = []
            var allIndices: [UInt32] = []
            var vertexCountOffset: UInt32 = 0
            
            let camera = frame.camera
            let viewportSize = parent.arView.bounds.size

            for anchor in meshAnchors {
                let geometry = anchor.geometry
                let transform = anchor.transform

                for i in 0..<geometry.vertices.count {
                    let localVertex = geometry.vertex(at: UInt32(i))
                    let worldVertex = (transform * SIMD4<Float>(localVertex, 1)).xyz
                    allVertices.append(worldVertex)
                    
                    let projectedPoint = camera.projectPoint(worldVertex, orientation: .portrait, viewportSize: viewportSize)
                    let u = projectedPoint.x / viewportSize.width
                    let v = projectedPoint.y / viewportSize.height
                    allTexCoords.append([Float(u), Float(v)])
                }
                
                let faces = geometry.faces
                if faces.primitiveType == .triangle {
                    if faces.bytesPerIndex == 4 {
                        let pointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * 3)
                        for i in 0..<(faces.count * 3) {
                            allIndices.append(pointer[i] + vertexCountOffset)
                        }
                    } else {
                        let pointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * 3)
                        for i in 0..<(faces.count * 3) {
                            allIndices.append(UInt32(pointer[i]) + vertexCountOffset)
                        }
                    }
                }
                vertexCountOffset += UInt32(geometry.vertices.count)
            }
            
            guard !allVertices.isEmpty, !allIndices.isEmpty else { return (nil, nil) }
            
            var descriptor = MeshDescriptor()
            descriptor.positions = MeshBuffer(allVertices)
            descriptor.primitives = .triangles(allIndices)
            descriptor.textureCoordinates = MeshBuffer(allTexCoords)
            
            do {
                let meshResource = try MeshResource.generate(from: [descriptor])
                let capturedImage = frame.capturedImage
                let ciImage = CIImage(cvPixelBuffer: capturedImage)
                let context = CIContext(options: nil)
                guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return (meshResource, nil) }
                let textureResource = try TextureResource.generate(from: cgImage, options: .init(semantic: .color))
                
                return (meshResource, textureResource)
            } catch {
                print("Failed to generate textured mesh: \(error)")
                return (nil, nil)
            }
        }
        
        private func updateCustomMesh(with resource: MeshResource, texture: TextureResource) {
            if let entity = customMeshEntity {
                entity.model?.mesh = resource
                if var material = entity.model?.materials.first as? UnlitMaterial {
                    material.color = .init(texture: .init(texture))
                    entity.model?.materials = [material]
                }
            } else {
                var material = UnlitMaterial()
                material.color = .init(texture: .init(texture))
                let newEntity = ModelEntity(mesh: resource, materials: [material])
                let anchor = AnchorEntity(world: matrix_identity_float4x4)
                anchor.addChild(newEntity)
                
                arView?.scene.addAnchor(anchor)
                customMeshEntity = newEntity
            }
        }
    }
}

extension SIMD4 {
    var xyz: SIMD3<Scalar> {
        return SIMD3<Scalar>(x, y, z)
    }
}
