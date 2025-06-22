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
                    try ExportViewModel().export(asset: asset, fileName: submittedName, cameraTransform: camera.transform)
                } catch {
                    print("Export Failed: \(error)")
                }
            } else {
                print("No mesh anchors found or asset conversion failed.")
            }
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
    func export(asset: MDLAsset, fileName: String, cameraTransform: simd_float4x4) throws {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "com.original.creatingLidarModel", code: 153)
        }
        let folderName = "OBJ_FILES"
        let folderURL = directory.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
        let baseName = fileName.isEmpty ? UUID().uuidString : fileName
        let url = folderURL.appendingPathComponent("\(baseName).obj")
        print("Exporting to: \(url)")
        do {
            try asset.export(to: url)
            print("Object saved successfully at \(url)")
            // Save transform as JSON
            let transform = cameraTransform
            let transformArray = [
                transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
                transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
                transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
            ]
            let transformURL = folderURL.appendingPathComponent("\(baseName)_transform.json")
            let jsonData = try? JSONSerialization.data(withJSONObject: transformArray)
            try? jsonData?.write(to: transformURL)
            print("Transform saved at \(transformURL)")
        } catch {
            print("Export error: \(error)")
        }
    }
}
