import SwiftUI
import ARKit
import SceneKit

struct OverlayModelView: View {
    @Environment(\.presentationMode) var mode: Binding<PresentationMode>
    @State private var showAlert = false
    @State private var alertMessage = ""
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ARWireframeView(showAlert: $showAlert, alertMessage: $alertMessage)
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

struct ARWireframeView: UIViewRepresentable {
    @Binding var showAlert: Bool
    @Binding var alertMessage: String

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true
        arView.delegate = context.coordinator
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        // Load and add the most recent OBJ model as wireframe
        if let node = loadMostRecentOBJWireframe() {
            node.position = SCNVector3(0, 0, -0.5) // Place in front of camera
            arView.scene.rootNode.addChildNode(node)
        } else {
            alertMessage = "No OBJ file found or failed to load."
            showAlert = true
        }
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, ARSCNViewDelegate {}

    func loadMostRecentOBJWireframe() -> SCNNode? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
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
                return nil
            }
            let scene = try SCNScene(url: mostRecent)
            let parentNode = SCNNode()
            for node in scene.rootNode.childNodes {
                setWireframe(node: node)
                parentNode.addChildNode(node)
            }
            // Center the model
            let (minVec, maxVec) = parentNode.boundingBox
            let dxAxis = (minVec.x + maxVec.x) / 2
            let dyAxis = (minVec.y + maxVec.y) / 2
            let dzAxis = (minVec.z + maxVec.z) / 2
            parentNode.position = SCNVector3(-dxAxis, -dyAxis, -dzAxis)
            return parentNode
        } catch {
            return nil
        }
    }

    func setWireframe(node: SCNNode) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                material.fillMode = .lines // Wireframe mode
                material.diffuse.contents = UIColor.green
                material.lightingModel = .constant
            }
        }
        for child in node.childNodes {
            setWireframe(node: child)
        }
    }
} 