import ARKit

class ARWrapperView: UIView {

    private var parent: ARWrapperView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.parent = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.parent = self
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // We use didUpdate frame instead of didUpdate anchors to get access to the camera image
        let meshAnchors = frame.anchors.compactMap({ $0 as? ARMeshAnchor })
        if meshAnchors.isEmpty { return }
        
        DispatchQueue.global().async {
            // ... existing code ...
        }
    }
} 