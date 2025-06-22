import SwiftUI
import RealityKit
import ARKit

struct OverlayModelView: View {
    @Environment(\.presentationMode) var mode: Binding<PresentationMode>
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var arView = ARView(frame: .zero)
    @State private var modelLoaded = false
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            ARViewContainer(arView: $arView, modelLoaded: $modelLoaded, showAlert: $showAlert, alertMessage: $alertMessage)
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
    @Binding var arView: ARView
    @Binding var modelLoaded: Bool
    @Binding var showAlert: Bool
    @Binding var alertMessage: String

    func makeUIView(context: Context) -> ARView {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        arView.automaticallyConfigureSession = false
        if !modelLoaded {
            loadMostRecentUSDZModel()
        }
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func loadMostRecentUSDZModel() {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            alertMessage = "Could not access documents directory."
            showAlert = true
            return
        }
        let folderName = "OBJ_FILES"
        let folderURL = documentsDirectory.appendingPathComponent(folderName)
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let usdzFiles = fileURLs.filter { $0.pathExtension == "usdz" }
            guard let mostRecent = usdzFiles.sorted(by: { (a, b) -> Bool in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return aDate > bDate
            }).first else {
                alertMessage = "No USDZ files found."
                showAlert = true
                return
            }
            let cancellable = Entity.loadModelAsync(contentsOf: mostRecent)
                .sink(receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        alertMessage = "Failed to load USDZ model: \(error.localizedDescription)"
                        showAlert = true
                    }
                }, receiveValue: { entity in
                    let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -0.5))
                    anchor.addChild(entity)
                    arView.scene.anchors.append(anchor)
                    modelLoaded = true
                })
            // Store cancellable if you want to keep it alive
            _ = cancellable
        } catch {
            alertMessage = "Failed to load USDZ files: \(error.localizedDescription)"
            showAlert = true
        }
    }
} 