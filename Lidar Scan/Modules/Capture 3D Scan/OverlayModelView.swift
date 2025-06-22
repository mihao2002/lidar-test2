import SwiftUI
import RealityKit
import ARKit

struct OverlayModelView: View {
    @Environment(\.presentationMode) var mode: Binding<PresentationMode>
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var modelLoaded = false
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ARViewContainer(modelLoaded: $modelLoaded, showAlert: $showAlert, alertMessage: $alertMessage)
                .edgesIgnoringSafeArea(.all)
            Button(action: {
                self.mode.wrappedValue.dismiss()
            }) {
                Image(systemName: "chevron.left")
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .padding()
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    @Binding var modelLoaded: Bool
    @Binding var showAlert: Bool
    @Binding var alertMessage: String

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.automaticallyConfigureSession = false
        if !modelLoaded {
            loadMostRecentOBJModel(arView: arView)
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func loadMostRecentOBJModel(arView: ARView) {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            alertMessage = "Could not access documents directory."
            showAlert = true
            return
        }
        let folderName = "OBJ_FILES"
        let folderURL = documentsDirectory.appendingPathComponent(folderName)
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let objFiles = fileURLs.filter { $0.pathExtension == "obj" }
            guard let mostRecent = objFiles.sorted(by: { (a, b) -> Bool in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return aDate > bDate
            }).first else {
                alertMessage = "No OBJ files found."
                showAlert = true
                return
            }
            if let entity = parseOBJToModelEntity(url: mostRecent) {
                let transform = loadTransform(for: mostRecent) ?? matrix_identity_float4x4
                let anchor = AnchorEntity(world: transform)
                anchor.addChild(entity)
                arView.scene.anchors.append(anchor)
                addCoordinateAxes(arView: arView)
                modelLoaded = true
            } else {
                alertMessage = "Failed to parse OBJ file."
                showAlert = true
            }
        } catch {
            alertMessage = "Failed to load OBJ files: \(error.localizedDescription)"
            showAlert = true
        }
    }

    // Simple OBJ parser for vertices and faces (triangles only)
    func parseOBJToModelEntity(url: URL) -> ModelEntity? {
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
                        // Only handle triangles (f v1 v2 v3)
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

    func addCoordinateAxes(arView: ARView) {
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