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
    @Binding var overlayExportedMesh: Bool
    let arView = ARView(frame: .zero)
    func makeUIView(context: Context) -> ARView {
        addCoordinateAxes()
        return arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {
        let viewModel = ExportViewModel()
        setARViewOptions(arView)
        let configuration = buildConfigure()
        if submittedExportRequest || overlayExportedMesh {
            guard let camera = arView.session.currentFrame?.camera else { print("No camera found"); return }
            let meshAnchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
            print("Mesh anchors found: \(meshAnchors.count)")
            if !meshAnchors.isEmpty {
                do {
                    print("Attempting manual export...")
                    try manualExport(meshAnchors: meshAnchors, fileName: submittedName)
                } catch {
                    print("Manual Export Failed: \(error)")
                }
            } else {
                print("No mesh anchors found.")
            }
        }
        if overlayExportedMesh {
            overlayMostRecentOBJMesh()
        }
        if pauseSession {
            arView.session.pause()
        } else {
            arView.session.run(configuration)
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
    private func setARViewOptions(_ arView: ARView) {
        arView.debugOptions.insert(.showSceneUnderstanding)
    }
    private func overlayMostRecentOBJMesh() {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folderName = "OBJ_FILES"
        let folderURL = documentsDirectory.appendingPathComponent(folderName)
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let objFiles = fileURLs.filter { $0.pathExtension == "obj" }
            guard let mostRecent = objFiles.sorted(by: { (a, b) -> Bool in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return aDate > bDate
            }).first else { return }
            if let entity = parseOBJToModelEntity(url: mostRecent) {
                let anchor = AnchorEntity(world: matrix_identity_float4x4)
                anchor.addChild(entity)
                arView.scene.anchors.append(anchor)
                addOverlayCoordinateAxes()
            }
        } catch {
            print("Failed to overlay OBJ mesh: \(error)")
        }
    }
    private func parseOBJToModelEntity(url: URL) -> ModelEntity? {
        do {
            let content = try String(contentsOf: url)
            var positions: [SIMD3<Float>] = []
            var indices: [UInt32] = []
            for line in content.components(separatedBy: .newlines) {
                let parts = line.split(separator: " ")
                if parts.count > 0 {
                    if parts[0] == "v" && parts.count >= 4 {
                        if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                            positions.append([x, y, z])
                        }
                    } else if parts[0] == "f" && parts.count >= 4 {
                        for i in 1...3 {
                            let vertex = parts[i].split(separator: "/")[0]
                            if let idx = Int(vertex), idx > 0 {
                                indices.append(UInt32(idx - 1))
                            }
                        }
                    }
                }
            }
            guard !positions.isEmpty && !indices.isEmpty else { return nil }
            var meshDesc = MeshDescriptor()
            meshDesc.positions = MeshBuffer(positions)
            meshDesc.primitives = .triangles(indices)
            let mesh = try MeshResource.generate(from: [meshDesc])
            let material = SimpleMaterial(color: .green, isMetallic: false)
            return ModelEntity(mesh: mesh, materials: [material])
        } catch {
            print("OBJ parse error: \(error)")
            return nil
        }
    }
    private func addCoordinateAxes() {
        let axisLength: Float = 0.1 // 10cm
        
        // X-axis (Red)
        let xAxis = ModelEntity(mesh: .generateBox(size: [axisLength, 0.002, 0.002]))
        xAxis.model?.materials = [SimpleMaterial(color: .red, isMetallic: false)]
        xAxis.position = [axisLength/2, 0, 0]
        
        // Y-axis (Green) 
        let yAxis = ModelEntity(mesh: .generateBox(size: [0.002, axisLength, 0.002]))
        yAxis.model?.materials = [SimpleMaterial(color: .green, isMetallic: false)]
        yAxis.position = [0, axisLength/2, 0]
        
        // Z-axis (Blue)
        let zAxis = ModelEntity(mesh: .generateBox(size: [0.002, 0.002, axisLength]))
        zAxis.model?.materials = [SimpleMaterial(color: .blue, isMetallic: false)]
        zAxis.position = [0, 0, axisLength/2]
        
        let axesAnchor = AnchorEntity(world: matrix_identity_float4x4)
        axesAnchor.addChild(xAxis)
        axesAnchor.addChild(yAxis)
        axesAnchor.addChild(zAxis)
        arView.scene.anchors.append(axesAnchor)
    }
    private func addOverlayCoordinateAxes() {
        let axisLength: Float = 0.2 // 20cm (longer)
        let axisThickness: Float = 0.004 // Thicker
        
        // X-axis (Magenta)
        let xAxis = ModelEntity(mesh: .generateBox(size: [axisLength, axisThickness, axisThickness]))
        xAxis.model?.materials = [SimpleMaterial(color: .magenta, isMetallic: false)]
        xAxis.position = [axisLength/2, 0, 0]
        
        // Y-axis (Cyan) 
        let yAxis = ModelEntity(mesh: .generateBox(size: [axisThickness, axisLength, axisThickness]))
        yAxis.model?.materials = [SimpleMaterial(color: .cyan, isMetallic: false)]
        yAxis.position = [0, axisLength/2, 0]
        
        // Z-axis (Yellow)
        let zAxis = ModelEntity(mesh: .generateBox(size: [axisThickness, axisThickness, axisLength]))
        zAxis.model?.materials = [SimpleMaterial(color: .yellow, isMetallic: false)]
        zAxis.position = [0, 0, axisLength/2]
        
        let axesAnchor = AnchorEntity(world: matrix_identity_float4x4)
        axesAnchor.addChild(xAxis)
        axesAnchor.addChild(yAxis)
        axesAnchor.addChild(zAxis)
        arView.scene.anchors.append(axesAnchor)
    }
    private func manualExport(meshAnchors: [ARMeshAnchor], fileName: String) throws {
        var objString = "# Manually exported OBJ\n"
        var vertexCountOffset: UInt32 = 0

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let transform = anchor.transform

            // Add vertices to string
            for i in 0..<geometry.vertices.count {
                let localVertex = geometry.vertex(at: UInt32(i))
                let worldVertex4 = transform * SIMD4<Float>(localVertex.x, localVertex.y, localVertex.z, 1)
                let worldVertex = SIMD3<Float>(worldVertex4.x, worldVertex4.y, worldVertex4.z)
                objString += "v \(worldVertex.x) \(worldVertex.y) \(worldVertex.z)\n"
            }

            // Add faces to string
            let faces = geometry.faces
            if faces.primitiveType == .triangle {
                if faces.bytesPerIndex == 4 { // UInt32
                    let typedPointer = faces.buffer.contents().bindMemory(to: UInt32.self, capacity: faces.count * faces.indexCountPerPrimitive)
                    for i in 0..<faces.count {
                        let base = i * faces.indexCountPerPrimitive
                        let v0 = typedPointer[base + 0] + vertexCountOffset
                        let v1 = typedPointer[base + 1] + vertexCountOffset
                        let v2 = typedPointer[base + 2] + vertexCountOffset
                        objString += "f \(v0 + 1) \(v1 + 1) \(v2 + 1)\n" // OBJ indices are 1-based
                    }
                } else { // UInt16
                    let typedPointer = faces.buffer.contents().bindMemory(to: UInt16.self, capacity: faces.count * faces.indexCountPerPrimitive)
                     for i in 0..<faces.count {
                        let base = i * faces.indexCountPerPrimitive
                        let v0 = UInt32(typedPointer[base + 0]) + vertexCountOffset
                        let v1 = UInt32(typedPointer[base + 1]) + vertexCountOffset
                        let v2 = UInt32(typedPointer[base + 2]) + vertexCountOffset
                        objString += "f \(v0 + 1) \(v1 + 1) \(v2 + 1)\n" // OBJ indices are 1-based
                    }
                }
            }

            vertexCountOffset += UInt32(geometry.vertices.count)
        }

        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "com.original.creatingLidarModel", code: 153)
        }
        let folderName = "OBJ_FILES"
        let folderURL = directory.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
        
        let baseName = fileName.isEmpty ? UUID().uuidString : fileName
        let url = folderURL.appendingPathComponent("\(baseName).obj")
        
        try objString.write(to: url, atomically: true, encoding: .utf8)
        print("Manual export saved successfully at \(url)")
    }
}

class ExportViewModel: NSObject, ObservableObject, ARSessionDelegate {
    // This class is no longer used for OBJ export but may be kept for other purposes.
}
