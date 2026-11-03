import AppKit
import CoreImage
import ModelIO
import SceneKit
import SceneKit.ModelIO

// usage: render <modelDir> <outDir>
let args = CommandLine.arguments
let modelDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let ci = CIContext()

// MARK: Textures

/// Fine bead-blast grain: tiny random bumps read as a matte, machined surface
/// instead of flat CG plastic.
func grainNormalMap(size: Int, strength: Float) -> CGImage {
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    // Height → normal: centre around flat (0.5, 0.5, 1) with small x/y tilt.
    let tilt = CIFilter(name: "CIColorMatrix", parameters: [
        kCIInputImageKey: noise,
        "inputRVector": CIVector(x: CGFloat(strength), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: CGFloat(strength), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: CGFloat(0.5 - strength / 2), y: CGFloat(0.5 - strength / 2), z: 1, w: 0),
    ])!.outputImage!
    return ci.createCGImage(tilt, from: CGRect(x: 0, y: 0, width: size, height: size))!
}

/// Roughness that wanders a little, so highlights break up like a real finish.
func roughnessMap(size: Int, base: CGFloat, variation: CGFloat) -> CGImage {
    let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    let mapped = CIFilter(name: "CIColorMatrix", parameters: [
        kCIInputImageKey: noise,
        "inputRVector": CIVector(x: variation, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: variation, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: variation, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: base - variation / 2, y: base - variation / 2, z: base - variation / 2, w: 0),
    ])!.outputImage!
    return ci.createCGImage(mapped, from: CGRect(x: 0, y: 0, width: size, height: size))!
}

/// Equirectangular studio: dim grey room with large softboxes, so curved
/// edges pick up long, soft highlights.
func studioEnvironment() -> NSImage {
    let size = NSSize(width: 2048, height: 1024)
    return NSImage(size: size, flipped: false) { rect in
        NSGradient(colors: [NSColor(white: 0.32, alpha: 1), NSColor(white: 0.12, alpha: 1), NSColor(white: 0.05, alpha: 1)])!
            .draw(in: rect, angle: -90)
        func softbox(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ white: CGFloat) {
            let box = NSRect(x: x * size.width, y: y * size.height, width: w * size.width, height: h * size.height)
            NSGradient(colors: [NSColor(white: white, alpha: 0), NSColor(white: white, alpha: 1), NSColor(white: white, alpha: 1), NSColor(white: white, alpha: 0)],
                       atLocations: [0, 0.18, 0.82, 1], colorSpace: .deviceGray)!
                .draw(in: box, angle: 0)
        }
        softbox(0.58, 0.55, 0.16, 0.34, 1.0)   // large key, front-left
        softbox(0.30, 0.60, 0.07, 0.30, 0.85)  // strip, right
        softbox(0.05, 0.62, 0.05, 0.28, 0.6)   // rim, behind
        softbox(0.40, 0.88, 0.30, 0.08, 0.7)   // overhead
        return true
    }
}

/// What the Stick's own screen shows in the hero: its parrot, lit.
func screenImage() -> NSImage {
    let size = NSSize(width: 270, height: 480)
    let rows = [
        "......####....",
        ".....######...",
        ".....###.#####",
        ".....######..#",
        "....#######...",
        "...########...",
        "...#######....",
        "..######......",
        ".####.#.#.....",
        "####..........",
    ]
    return NSImage(size: size, flipped: true) { rect in
        NSColor(white: 0.015, alpha: 1).setFill()
        rect.fill()
        let cell: CGFloat = 11
        let origin = CGPoint(x: (size.width - cell * CGFloat(rows[0].count)) / 2,
                             y: (size.height - cell * CGFloat(rows.count)) / 2)
        NSColor(calibratedRed: 236 / 255, green: 186 / 255, blue: 64 / 255, alpha: 1).setFill()
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() where ch == "#" {
                NSRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(r) * cell, width: cell, height: cell).fill()
            }
        }
        return true
    }
}

// MARK: Materials

func material(_ color: NSColor, roughness: Any, clearcoat: CGFloat = 0, coatRoughness: CGFloat = 0.2,
              normal: CGImage? = nil, normalScale: CGFloat = 6) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = color
    m.roughness.contents = roughness
    m.metalness.contents = 0.0
    m.clearCoat.contents = clearcoat
    m.clearCoatRoughness.contents = coatRoughness
    if let normal {
        m.normal.contents = normal
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.contentsTransform = SCNMatrix4MakeScale(normalScale, normalScale, 1)
        m.normal.intensity = 1
    }
    return m
}

func part(_ name: String, _ material: SCNMaterial) -> SCNNode {
    let asset = MDLAsset(url: modelDir.appendingPathComponent(name + ".stl"))
    let mesh = asset.object(at: 0) as! MDLMesh
    mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.35)
    // Box-projected UVs so the grain textures have somewhere to land.
    mesh.addUnwrappedTextureCoordinates(forAttributeNamed: MDLVertexAttributeTextureCoordinate)
    let node = SCNNode(mdlObject: mesh)
    node.geometry?.materials = [material]
    node.castsShadow = true
    return node
}

let grain = grainNormalMap(size: 1024, strength: 0.07)
let bodyColor = NSColor(calibratedRed: 0.115, green: 0.12, blue: 0.13, alpha: 1)
let coverColor = NSColor(calibratedRed: 0.135, green: 0.14, blue: 0.15, alpha: 1)
// The real StickS3's key blue (M5Stack's product photo).
let keyBlue = NSColor(calibratedRed: 0.0, green: 0.36, blue: 0.92, alpha: 1)

let scene = SCNScene()
scene.background.contents = NSColor.clear
let model = SCNNode()
model.addChildNode(part("shell", material(bodyColor, roughness: roughnessMap(size: 256, base: 0.5, variation: 0.1), normal: grain, normalScale: 14)))
model.addChildNode(part("cover", material(coverColor, roughness: roughnessMap(size: 256, base: 0.34, variation: 0.08), clearcoat: 0.55, coatRoughness: 0.22, normal: grain, normalScale: 16)))
model.addChildNode(part("button", material(keyBlue, roughness: 0.28, clearcoat: 0.8, coatRoughness: 0.08)))

// The STL has no display; fill the cover's opening (x 4.75–19.25, y 19–43.25 mm) with lit black glass.
let glass = SCNBox(width: 14.9, height: 25.2, length: 0.6, chamferRadius: 0.2)
let glassFront = material(NSColor.black, roughness: 0.03, clearcoat: 1, coatRoughness: 0.02)
glassFront.emission.contents = screenImage()
glassFront.emission.intensity = 1.6
let glassSide = material(NSColor.black, roughness: 0.95)
glass.materials = [glassFront, glassSide, glassSide, glassSide, glassSide, glassSide]
let screen = SCNNode(geometry: glass)
screen.position = SCNVector3(12, 30.8, -0.75)
model.addChildNode(screen)

// The enclosure is hollow (no PCB in the STL); a dark block behind the glass
// stops light leaking through the gap around the opening.
let backing = SCNNode(geometry: SCNBox(width: 18, height: 28, length: 5, chamferRadius: 0))
backing.geometry?.materials = [material(NSColor(white: 0.02, alpha: 1), roughness: 1)]
backing.position = SCNVector3(12, 31, -3.8)
model.addChildNode(backing)

let (minB, maxB) = model.boundingBox
let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
model.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
scene.rootNode.addChildNode(model)

scene.lightingEnvironment.contents = studioEnvironment()
scene.lightingEnvironment.intensity = 3.8

// Key + fill as real lights so the front reads; a shadow-only floor grounds it.
func light(_ type: SCNLight.LightType, intensity: CGFloat, position: SCNVector3, shadows: Bool = false) -> SCNNode {
    let l = SCNLight()
    l.type = type
    l.intensity = intensity
    l.temperature = 5800
    if shadows {
        l.castsShadow = true
        l.shadowMode = .deferred
        l.shadowRadius = 18
        l.shadowSampleCount = 32
        l.shadowColor = NSColor(white: 0, alpha: 0.35)
        l.shadowMapSize = CGSize(width: 4096, height: 4096)
        l.orthographicScale = 60
    }
    let n = SCNNode()
    n.light = l
    n.position = position
    n.look(at: SCNVector3(0, 0, 0))
    return n
}
scene.rootNode.addChildNode(light(.directional, intensity: 900, position: SCNVector3(-40, 90, 60), shadows: true))
scene.rootNode.addChildNode(light(.directional, intensity: 350, position: SCNVector3(70, 10, 50)))
// Rim from behind-right: separates the dark body from a light page.
scene.rootNode.addChildNode(light(.directional, intensity: 420, position: SCNVector3(60, 40, -90)))

let floor = SCNFloor()
floor.reflectivity = 0
let floorMaterial = SCNMaterial()
floorMaterial.lightingModel = .shadowOnly
floor.materials = [floorMaterial]
let floorNode = SCNNode(geometry: floor)
floorNode.position = SCNVector3(0, Float(-(maxB.y - minB.y) / 2) - 0.05, 0)
scene.rootNode.addChildNode(floorNode)

let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
renderer.scene = scene
renderer.autoenablesDefaultLighting = false

func shot(_ name: String, yaw: CGFloat, pitch: CGFloat, size: CGSize, distance: CGFloat = 125,
          orthoHalfHeight: CGFloat? = nil, floor showFloor: Bool) {
    floorNode.isHidden = !showFloor
    let camera = SCNCamera()
    camera.fieldOfView = 24
    camera.zNear = 1
    camera.zFar = 1000
    camera.wantsHDR = true
    camera.exposureOffset = 0.55
    camera.whitePoint = 1.1
    camera.screenSpaceAmbientOcclusionIntensity = 1.4
    camera.screenSpaceAmbientOcclusionRadius = 1.6
    camera.screenSpaceAmbientOcclusionNormalThreshold = 0.3
    camera.bloomIntensity = 0.12
    camera.bloomThreshold = 0.9
    camera.contrast = 0.08
    camera.saturation = 1.04
    if let orthoHalfHeight {
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(orthoHalfHeight)
    }
    let cameraNode = SCNNode()
    cameraNode.camera = camera
    let pivot = SCNNode()
    pivot.eulerAngles = SCNVector3(pitch, yaw, 0)
    cameraNode.position = SCNVector3(0, 0, distance)
    pivot.addChildNode(cameraNode)
    scene.rootNode.addChildNode(pivot)
    renderer.pointOfView = cameraNode
    // HDR snapshots come back opaque, so render over black and over white and
    // recover alpha from the difference (soft shadow edges stay translucent).
    scene.background.contents = NSColor.black
    let onBlack = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    scene.background.contents = NSColor.white
    let onWhite = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    pivot.removeFromParentNode()
    guard let png = matte(black: onBlack, white: onWhite) else { return }
    try? png.write(to: outDir.appendingPathComponent(name + ".png"))
    print("wrote", name)
}

func bitmap(_ image: NSImage) -> NSBitmapImageRep {
    NSBitmapImageRep(data: image.tiffRepresentation!)!
}

func matte(black: NSImage, white: NSImage) -> Data? {
    let b = bitmap(black), w = bitmap(white)
    let width = b.pixelsWide, height = b.pixelsHigh
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: width * 4, bitsPerPixel: 32) else { return nil }
    for y in 0..<height {
        for x in 0..<width {
            guard let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let cw = w.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let alpha = max(0, min(1, 1 - ((cw.redComponent - cb.redComponent) + (cw.greenComponent - cb.greenComponent) + (cw.blueComponent - cb.blueComponent)) / 3))
            let unpremultiply = alpha > 0.001 ? 1 / alpha : 0
            out.setColor(NSColor(deviceRed: min(cb.redComponent * unpremultiply, 1), green: min(cb.greenComponent * unpremultiply, 1),
                                 blue: min(cb.blueComponent * unpremultiply, 1), alpha: alpha), atX: x, y: y)
        }
    }
    return out.representation(using: .png, properties: [:])
}

shot("stick-hero", yaw: -0.48, pitch: -0.16, size: CGSize(width: 1200, height: 1500), floor: false)
// The app draws live screen content over the front view, so its glass stays dark.
glassFront.emission.intensity = 0
shot("stick-front", yaw: 0, pitch: 0, size: CGSize(width: 780, height: 1500), orthoHalfHeight: 25, floor: false)
