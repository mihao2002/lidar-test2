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
        return arView
    }
    func updateUIView(_ uiView: ARView, context: Context) {
        let viewModel = ExportViewModel()
        setARViewOptions(arView)
        let configuration = buildConfigure()
        if submittedExportRequest {
            guard let camera = arView.session.currentFrame?.camera else { print("No camera found"); return }
            let meshAnchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
            print("Mesh anchors found: \(meshAnchors.count)")
            if !meshAnchors.isEmpty, let asset = viewModel.convertToAsset(meshAnchor: meshAnchors, camera: camera) {
                do {
                    print("Attempting export...")
                    try ExportViewModel().export(asset: asset, fileName: submittedName)
                } catch {
                    print("Export Failed: \(error)")
                }
            } else {
                print("No mesh anchors found or asset conversion failed.")
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
                addCoordinateAxes()
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
}

class ExportViewModel: NSObject, ObservableObject, ARSessionDelegate {
    func convertToAsset(meshAnchor: [ARMeshAnchor], camera: ARCamera) -> MDLAsset? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil}
        let asset = MDLAsset()
        for anchor in meshAnchor {
            let mdlMesh = anchor.geometry.toMDLMesh(device: device, camera: camera, modelMatrix: anchor.transform)
            asset.add(mdlMesh)
        }
        return asset
    }
    func export(asset: MDLAsset, fileName: String) throws {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "com.original.creatingLidarModel", code: 153)
        }
        let folderName = "OBJ_FILES"
        let folderURL = directory.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
        let url = folderURL.appendingPathComponent("\(fileName.isEmpty ? UUID().uuidString : fileName).obj")
        print("Exporting to: \(url)")
        do {
            try asset.export(to: url)
            print("Object saved successfully at \(url)")
        } catch {
            print("Export error: \(error)")
        }
    }
}
