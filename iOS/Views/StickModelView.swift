import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// The real StickS3 enclosure (M5Stack's official model) rendered live:
/// spins in, settles at three-quarters, then turns slowly. Drag to spin it.
/// Everything visual comes from `look`, so the Lab can tune it live.
struct StickModelView: UIViewRepresentable {
    enum Screen: Equatable {
        case ready
        case working
        case done
    }

    var look: StickLook
    var screen: Screen = .ready
    /// Change to play the entrance again.
    var replay = 0
    /// Change to play the "connected" turn.
    var celebrate = 0

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let parts = StickScene.make()
        view.scene = parts.scene
        view.pointOfView = parts.camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.isPlaying = true
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        let coordinator = context.coordinator
        coordinator.parts = parts
        coordinator.look = look
        coordinator.replay = replay
        coordinator.celebrate = celebrate
        parts.apply(look)
        parts.show(screen)
        coordinator.spinIn()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.look = look
        coordinator.parts?.apply(look)
        coordinator.parts?.show(screen)
        if coordinator.replay != replay {
            coordinator.replay = replay
            coordinator.spinIn()
        }
        if coordinator.celebrate != celebrate {
            coordinator.celebrate = celebrate
            coordinator.celebrateTurn()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// SceneKit calls action timing and completion blocks on its render thread,
    /// so those closures are @Sendable and hop back to the main actor themselves.
    @MainActor
    final class Coordinator: NSObject {
        var parts: StickScene.Parts?
        var look = StickLook()
        var replay = 0
        var celebrate = 0
        private static let idleKey = "idle"

        func spinIn() {
            guard let model = parts?.model else { return }
            model.removeAllActions()
            let resting = Float(look.restingYaw)
            model.eulerAngles.y = resting - .pi * 2 * Float(look.spinTurns)
            let spin = SCNAction.rotateTo(x: 0, y: CGFloat(resting), z: 0, duration: look.spinDuration, usesShortestUnitArc: false)
            spin.timingFunction = { @Sendable t in 1 - pow(1 - t, 3) } // fast start, soft landing
            run(.sequence([spin, .wait(duration: 1.2)]))
        }

        /// One quick extra turn with a small lift, the moment the Stick connects.
        func celebrateTurn() {
            guard let model = parts?.model else { return }
            model.removeAllActions()
            let duration = look.celebrateDuration
            let turn = SCNAction.rotateBy(x: 0, y: .pi * 2 * CGFloat(look.celebrateTurns), z: 0, duration: duration)
            turn.timingFunction = { @Sendable t in 1 - pow(1 - t, 3) }
            let lift = SCNAction.sequence([
                .scale(to: CGFloat(look.celebrateScale), duration: duration * 0.35),
                .scale(to: 1, duration: duration * 0.65),
            ])
            lift.timingMode = .easeInEaseOut
            run(.sequence([.group([turn, lift]), .wait(duration: 1.0)]))
        }

        private func run(_ action: SCNAction) {
            parts?.model.runAction(action) { @Sendable [weak self] in
                Task { @MainActor in self?.idle() }
            }
        }

        /// A slow turn so the object feels present without demanding attention.
        private func idle() {
            guard look.idlePeriod > 0 else { return }
            parts?.model.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: look.idlePeriod)), forKey: Self.idleKey)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let model = parts?.model, let view = gesture.view else { return }
            let sensitivity = Float(look.dragSensitivity)
            switch gesture.state {
            case .began:
                model.removeAllActions()
            case .changed:
                model.eulerAngles.y += Float(gesture.translation(in: view).x) * sensitivity
                gesture.setTranslation(.zero, in: view)
            case .ended, .cancelled:
                // Carry the finger's speed, then ease back into the idle turn.
                let velocity = Float(gesture.velocity(in: view).x) * sensitivity
                let coast = SCNAction.rotateBy(x: 0, y: CGFloat(velocity * 0.35), z: 0, duration: 0.9)
                coast.timingFunction = { @Sendable t in 1 - pow(1 - t, 3) }
                run(.sequence([coast, .wait(duration: 1.5)]))
            default:
                break
            }
        }
    }
}

enum StickScene {
    /// The nodes and materials a `StickLook` drives.
    @MainActor
    final class Parts {
        let scene: SCNScene
        let model: SCNNode
        let camera: SCNNode
        let body: SCNMaterial
        let cover: SCNMaterial
        let button: SCNMaterial
        let glass: SCNMaterial
        let key: SCNLight
        let fill: SCNLight
        let rim: SCNLight
        private var shown: StickModelView.Screen?

        init(scene: SCNScene, model: SCNNode, camera: SCNNode, body: SCNMaterial, cover: SCNMaterial, button: SCNMaterial,
             glass: SCNMaterial, key: SCNLight, fill: SCNLight, rim: SCNLight) {
            self.scene = scene; self.model = model; self.camera = camera
            self.body = body; self.cover = cover; self.button = button; self.glass = glass
            self.key = key; self.fill = fill; self.rim = rim
        }

        func apply(_ look: StickLook) {
            body.diffuse.contents = look.bodyColor.uiColor
            body.roughness.contents = look.bodyRoughness
            cover.diffuse.contents = look.coverColor.uiColor
            cover.roughness.contents = look.coverRoughness
            cover.clearCoat.contents = look.coverClearcoat
            button.diffuse.contents = look.buttonColor.uiColor
            button.clearCoat.contents = look.buttonClearcoat
            glass.emission.intensity = look.screenGlow

            scene.lightingEnvironment.intensity = look.environment
            key.intensity = look.keyLight
            fill.intensity = look.fillLight
            rim.intensity = look.rimLight

            guard let lens = camera.camera else { return }
            lens.exposureOffset = look.exposure
            lens.fieldOfView = look.fieldOfView
            let pitch = Float(look.cameraPitch), distance = Float(look.cameraDistance)
            camera.position = SCNVector3(0, -sin(pitch) * distance, cos(pitch) * distance)
            camera.look(at: SCNVector3(0, 0, 0))
        }

        /// What the Stick's own glass shows, mirroring the pairing step.
        func show(_ screen: StickModelView.Screen) {
            guard screen != shown else { return }
            shown = screen
            switch screen {
            case .ready: glass.emission.contents = StickScene.screenImage(symbol: "mic.fill", color: .white, size: 110)
            case .working: glass.emission.contents = StickScene.screenImage(symbol: "ellipsis", color: .white, size: 120)
            case .done: glass.emission.contents = StickScene.screenImage(symbol: "checkmark", color: .white, size: 170)
            }
        }
    }

    @MainActor
    static func make() -> Parts {
        let scene = SCNScene()
        let model = SCNNode()

        let body = material(roughness: 0.5)
        let cover = material(roughness: 0.34, coatRoughness: 0.22)
        let button = material(roughness: 0.28, coatRoughness: 0.08)
        model.addChildNode(part("shell", body))
        model.addChildNode(part("cover", cover))
        model.addChildNode(part("button", button))

        // The STL has no display: black glass in the cover's opening, a dark
        // block behind it so the hollow shell doesn't show through.
        let glassFront = material(roughness: 0.03, clearcoat: 1, coatRoughness: 0.02)
        glassFront.diffuse.contents = UIColor.black
        let glassSide = material(roughness: 0.95)
        glassSide.diffuse.contents = UIColor.black
        let glass = SCNBox(width: 14.9, height: 25.2, length: 0.6, chamferRadius: 0.2)
        glass.materials = [glassFront, glassSide, glassSide, glassSide, glassSide, glassSide]
        let screen = SCNNode(geometry: glass)
        screen.position = SCNVector3(12, 30.8, -0.75)
        model.addChildNode(screen)
        let backingMaterial = material(roughness: 1)
        backingMaterial.diffuse.contents = UIColor(white: 0.02, alpha: 1)
        let backing = SCNNode(geometry: SCNBox(width: 18, height: 28, length: 5, chamferRadius: 0))
        backing.geometry?.materials = [backingMaterial]
        backing.position = SCNVector3(12, 31, -3.8)
        model.addChildNode(backing)

        // The STL has no back cover either (the magnet hole and cavity show when
        // it turns); close it with a plate in the body material just inside the rim.
        let backPlate = SCNNode(geometry: SCNBox(width: 22.4, height: 46.4, length: 0.8, chamferRadius: 2.5))
        backPlate.geometry?.materials = [body]
        backPlate.position = SCNVector3(12, 24.06, -13.4)
        model.addChildNode(backPlate)

        // Spin around the body's own centre (model units are mm).
        model.pivot = SCNMatrix4MakeTranslation(12, 24.06, -6.58)
        scene.rootNode.addChildNode(model)

        scene.lightingEnvironment.contents = studioEnvironment()
        let key = light(at: SCNVector3(-40, 90, 60), in: scene)
        let fill = light(at: SCNVector3(70, 10, 50), in: scene)
        let rim = light(at: SCNVector3(60, 40, -90), in: scene)

        let lens = SCNCamera()
        lens.zNear = 1
        lens.zFar = 1000
        let camera = SCNNode()
        camera.camera = lens
        scene.rootNode.addChildNode(camera)

        return Parts(scene: scene, model: model, camera: camera, body: body, cover: cover, button: button,
                     glass: glassFront, key: key, fill: fill, rim: rim)
    }

    private static func part(_ name: String, _ material: SCNMaterial) -> SCNNode {
        guard let url = Bundle.main.url(forResource: name, withExtension: "stl"),
              let mesh = MDLAsset(url: url).object(at: 0) as? MDLMesh else { return SCNNode() }
        // STL is faceted; weld + crease so curves shade smoothly but corners stay crisp.
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.35)
        let node = SCNNode(mdlObject: mesh)
        node.geometry?.materials = [material]
        return node
    }

    private static func material(roughness: CGFloat, clearcoat: CGFloat = 0, coatRoughness: CGFloat = 0.2) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        m.clearCoat.contents = clearcoat
        m.clearCoatRoughness.contents = coatRoughness
        return m
    }

    private static func light(at position: SCNVector3, in scene: SCNScene) -> SCNLight {
        let light = SCNLight()
        light.type = .directional
        light.temperature = 5800
        let node = SCNNode()
        node.light = light
        node.position = position
        node.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(node)
        return light
    }

    /// Dim room with softboxes: the long highlights on the bevels come from these.
    private static func studioEnvironment() -> UIImage {
        let size = CGSize(width: 1024, height: 512)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let space = CGColorSpaceCreateDeviceGray()
            let room = CGGradient(colorsSpace: space, colors: [UIColor(white: 0.32, alpha: 1).cgColor,
                                                                UIColor(white: 0.12, alpha: 1).cgColor,
                                                                UIColor(white: 0.05, alpha: 1).cgColor] as CFArray,
                                  locations: [0, 0.5, 1])!
            cg.drawLinearGradient(room, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            func softbox(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ white: CGFloat) {
                let rect = CGRect(x: x * size.width, y: (1 - y - h) * size.height, width: w * size.width, height: h * size.height)
                let box = CGGradient(colorsSpace: space, colors: [UIColor(white: white, alpha: 0).cgColor,
                                                                   UIColor(white: white, alpha: 1).cgColor,
                                                                   UIColor(white: white, alpha: 1).cgColor,
                                                                   UIColor(white: white, alpha: 0).cgColor] as CFArray,
                                     locations: [0, 0.18, 0.82, 1])!
                cg.saveGState()
                cg.clip(to: rect)
                cg.drawLinearGradient(box, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
                cg.restoreGState()
            }
            softbox(0.58, 0.55, 0.16, 0.34, 1.0)
            softbox(0.30, 0.60, 0.07, 0.30, 0.85)
            softbox(0.05, 0.62, 0.05, 0.28, 0.6)
            softbox(0.40, 0.88, 0.30, 0.08, 0.7)
        }
    }

    /// The Stick's own screen with one centred symbol.
    static func screenImage(symbol: String, color: UIColor, size pointSize: CGFloat) -> UIImage {
        let size = CGSize(width: 270, height: 480)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.015, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            if let image = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal) {
                image.draw(at: CGPoint(x: (size.width - image.size.width) / 2, y: (size.height - image.size.height) / 2))
            }
        }
    }
}
