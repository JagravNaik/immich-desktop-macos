#if canImport(SwiftUI) && canImport(AppKit) && canImport(SceneKit)
import SwiftUI
import AppKit
import SceneKit

struct PanoramaSceneView: NSViewRepresentable {
  let image: NSImage

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> InteractivePanoramaView {
    let view = InteractivePanoramaView(frame: .zero)
    view.configure(with: image, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ nsView: InteractivePanoramaView, context: Context) {
    nsView.configure(with: image, coordinator: context.coordinator)
  }

  final class Coordinator {
    var yaw: Float = 0
    var pitch: Float = 0
    var fieldOfView: CGFloat = 72
    var lastDragLocation: CGPoint?
  }
}

final class InteractivePanoramaView: SCNView {
  private let panoramaScene = SCNScene()
  private let cameraNode = SCNNode()
  private let sphereNode = SCNNode()
  private weak var panoramaCoordinator: PanoramaSceneView.Coordinator?

  override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
    super.init(frame: frameRect, options: options)
    scene = panoramaScene
    backgroundColor = .black
    allowsCameraControl = false
    preferredFramesPerSecond = 60
    rendersContinuously = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with image: NSImage, coordinator: PanoramaSceneView.Coordinator) {
    panoramaCoordinator = coordinator

    if cameraNode.parent == nil {
      let camera = SCNCamera()
      camera.wantsHDR = true
      camera.fieldOfView = coordinator.fieldOfView
      camera.zNear = 0.01
      camera.zFar = 100
      cameraNode.camera = camera
      cameraNode.position = SCNVector3Zero
      panoramaScene.rootNode.addChildNode(cameraNode)
      pointOfView = cameraNode
    }

    let sphereGeometry: SCNSphere
    if let existing = sphereNode.geometry as? SCNSphere {
      sphereGeometry = existing
    } else {
      sphereGeometry = SCNSphere(radius: 8)
      sphereGeometry.segmentCount = 96
      let material = SCNMaterial()
      material.diffuse.contents = image
      material.isDoubleSided = true
      material.lightingModel = .constant
      sphereGeometry.firstMaterial = material
      sphereNode.geometry = sphereGeometry
      sphereNode.scale = SCNVector3(x: -1, y: 1, z: 1)
      panoramaScene.rootNode.addChildNode(sphereNode)
    }

    sphereGeometry.firstMaterial?.diffuse.contents = image
    applyCameraState()
  }

  override func mouseDown(with event: NSEvent) {
    panoramaCoordinator?.lastDragLocation = convert(event.locationInWindow, from: nil)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let panoramaCoordinator else { return }

    let point = convert(event.locationInWindow, from: nil)
    let previousPoint = panoramaCoordinator.lastDragLocation ?? point
    let deltaX = point.x - previousPoint.x
    let deltaY = point.y - previousPoint.y

    panoramaCoordinator.yaw -= Float(deltaX) * 0.006
    panoramaCoordinator.pitch = max(min(panoramaCoordinator.pitch + Float(deltaY) * 0.0045, .pi / 2.3), -.pi / 2.3)
    panoramaCoordinator.lastDragLocation = point

    applyCameraState()
  }

  override func mouseUp(with event: NSEvent) {
    panoramaCoordinator?.lastDragLocation = nil
  }

  override func scrollWheel(with event: NSEvent) {
    guard let panoramaCoordinator else { return }
    panoramaCoordinator.fieldOfView = max(35, min(90, panoramaCoordinator.fieldOfView + event.scrollingDeltaY * 0.05))
    applyCameraState()
  }

  private func applyCameraState() {
    guard let panoramaCoordinator else { return }
    cameraNode.eulerAngles = SCNVector3(panoramaCoordinator.pitch, panoramaCoordinator.yaw, 0)
    cameraNode.camera?.fieldOfView = panoramaCoordinator.fieldOfView
  }
}
#endif
