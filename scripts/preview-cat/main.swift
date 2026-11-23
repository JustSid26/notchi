// Renders the Notchi cat to PNG/GIF without launching the app.
// Usage: scripts/preview-cat.sh  → build/cat-poses.png, build/cat-demo.gif
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let k: CGFloat = 4                       // 4× menu-bar size so details are visible
let menuDark = Color(hex: 0x1C1C20)
let menuLight = Color(hex: 0xE9E9EE)
let cellW = CatRenderer.unitW * k + 60, cellH = CatRenderer.unitH * k + 70

func makeEngine() -> CatEngine {
    let e = CatEngine()
    e.configureMenuBar(centerX: 0, notchHalf: 0, range: 0, groundY: 0, catHeight: CatRenderer.unitH * k)
    return e
}

/// Where to put the feet so the cat sits nicely in its cell (on the floor, or on the left "wall").
func rotatedAnchor(_ e: CatEngine, _ size: CGSize) -> CGPoint {
    if e.rotation > 0.8 { return CGPoint(x: 18, y: size.height * 0.62) }
    return CGPoint(x: 30 + CatRenderer.pivotX * k, y: 52 + CatRenderer.ground * k - e.lift)
}

struct CatCell: View {
    let engine: CatEngine
    let palette: CatPalette
    let background: Color
    let label: String?
    var peek = false

    var body: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                if peek {
                    let pk = k * 1.15
                    let ox = (size.width - CatRenderer.peekUnitW * pk) / 2
                    let ledge = 26 + CatRenderer.peekLedge * pk
                    // the "card" the cat is peeking over
                    ctx.fill(Path(roundedRect: CGRect(x: 14, y: ledge, width: size.width - 28, height: size.height),
                                  cornerRadius: 14), with: .color(.white.opacity(0.08)))
                    CatRenderer.drawPeek(in: &ctx, engine: engine, palette: palette,
                                         origin: CGPoint(x: ox, y: 26), k: pk, lookX: engine.lookX)
                } else {
                    CatRenderer.draw(in: &ctx, engine: engine, palette: palette,
                                     anchor: rotatedAnchor(engine, size), k: k)
                }
            }
            .frame(width: cellW, height: cellH)
            .background(RoundedRectangle(cornerRadius: 14).fill(background))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if let label {
                Text(label).font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.75))
            }
        }
    }
}

@MainActor func png(_ view: some View, to path: String) {
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let cg = r.cgImage else { print("render failed"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// MARK: Pose sheet

struct Spec { let name: String; var peek = false; var light = false; let apply: (CatEngine) -> Void }
let specs: [Spec] = [
    Spec(name: "walk") { $0.setPose(walk: 1, phase: 0.4, time: 0.3) },
    Spec(name: "walk") { $0.setPose(walk: 1, phase: 2.0, time: 0.6) },
    Spec(name: "sit") { $0.setPose(sit: 1, time: 1.4) },
    Spec(name: "wave hello") { $0.setPose(stand: 1, happy: 1, time: 0.15) },
    Spec(name: "surprised (hover)") { $0.setPose(crouch: 0.6, perk: 1, mouthO: 1) },
    Spec(name: "vibing to music") { $0.setPose(sit: 1, happy: 0.8, headBob: 1, time: 0.12) },
    Spec(name: "stretch") { $0.setPose(bow: 1, happy: 0.6, time: 0.2) },
    Spec(name: "swat the cursor") { $0.setPose(swat: 1, perk: 1, time: 0.05) },
    Spec(name: "sleep") { $0.setPose(sit: 1, loaf: 1, time: 1.3) },
    Spec(name: "jump into notch") { $0.setPose(air: 1, perk: 1, mouthO: 0.8, lift: 14, scale: 0.9) },
    Spec(name: "peek (island open)", peek: true) { $0.setPose(perk: 0.3, lookX: -0.3, time: 0.4) },
    Spec(name: "peek · waving", peek: true) { $0.setPose(happy: 1, waveArm: 1, time: 0.1) },
    Spec(name: "peek · new song!", peek: true) { $0.setPose(perk: 1, mouthO: 1, lookX: 0.5) },
    Spec(name: "climbing the edge") { $0.setPose(walk: 1, phase: 1.2, facing: -1, rotation: .pi / 2, time: 0.4) },
    Spec(name: "uh-oh (hanging)") { $0.setPose(perk: 1, mouthO: 1, facing: -1, rotation: .pi / 2, time: 0.2) },
    Spec(name: "falling!") { $0.setPose(air: 1, perk: 1, mouthO: 1, facing: -1, lift: 30, rotation: 0.6) },
    Spec(name: "light menu bar", light: true) { $0.setPose(sit: 1, perk: 0.4, time: 2) },
    Spec(name: "light · walk", light: true) { $0.setPose(walk: 1, phase: 3.4, time: 0.9) },
]

let siamese = CatCoat.siamese.palette
let poseCells: [(Spec, CatEngine)] = specs.map { s in let e = makeEngine(); s.apply(e); return (s, e) }
let others: [CatCoat] = CatCoat.allCases.filter { $0 != .siamese }
let coatCells: [(CatCoat, CatEngine)] = others.map { c in let e = makeEngine(); e.setPose(sit: 1, perk: 0.4, time: 2); return (c, e) }

let sheet = VStack(alignment: .leading, spacing: 22) {
    Text("Notchi · Siamese").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.white)
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: 16), count: 5), alignment: .leading, spacing: 18) {
        ForEach(Array(poseCells.enumerated()), id: \.offset) { _, c in
            CatCell(engine: c.1, palette: siamese, background: c.0.light ? menuLight : menuDark,
                    label: c.0.name, peek: c.0.peek)
        }
    }
    Text("Other coats").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9))
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: 16), count: 5), alignment: .leading, spacing: 18) {
        ForEach(Array(coatCells.enumerated()), id: \.offset) { _, c in
            CatCell(engine: c.1, palette: c.0.palette, background: menuDark, label: c.0.name)
        }
    }
}
.padding(28)
.background(Color(hex: 0x111114))

MainActor.assumeIsolated { png(sheet, to: "\(outDir)/cat-poses.png") }

// MARK: Dog & bird sheet

struct PetSpec { let name: String; var peek = false; let apply: (CatEngine) -> Void }
let dogSpecs: [PetSpec] = [
    PetSpec(name: "walk") { $0.setPose(walk: 1, phase: 0.5, time: 0.3) },
    PetSpec(name: "sit + wag") { $0.setPose(sit: 1, happy: 0.5, time: 0.2) },
    PetSpec(name: "happy pant") { $0.setPose(perk: 0.6, happy: 1, time: 0.4) },
    PetSpec(name: "play bow") { $0.setPose(bow: 1, happy: 0.8, time: 0.1) },
    PetSpec(name: "woof!") { $0.setPose(perk: 1, mouthO: 1) },
    PetSpec(name: "jumping at wall") { $0.setPose(stand: 1, happy: 1, facing: -1, time: 0.15) },
    PetSpec(name: "sleep") { $0.setPose(sit: 1, loaf: 1, time: 1.3) },
    PetSpec(name: "peek", peek: true) { $0.setPose(happy: 0.6, lookX: 0.3, time: 0.3) },
    PetSpec(name: "peek · waving", peek: true) { $0.setPose(happy: 1, waveArm: 1, time: 0.1) },
]
let birdSpecs: [PetSpec] = [
    PetSpec(name: "hop") { $0.setPose(walk: 1, phase: 1.3, time: 0.3) },
    PetSpec(name: "perched") { $0.setPose(perk: 0.4, time: 1.0) },
    PetSpec(name: "flying") { $0.setPose(air: 1, happy: 0.5, lift: 18, time: 0.03) },
    PetSpec(name: "peck peck") { $0.setPose(bow: 1, time: 0.17) },
    PetSpec(name: "chirp!") { $0.setPose(perk: 1, mouthO: 1, time: 0.3) },
    PetSpec(name: "wave") { $0.setPose(stand: 1, happy: 1, time: 0.1) },
    PetSpec(name: "fluffed asleep") { $0.setPose(sit: 1, loaf: 1, time: 1.3) },
    PetSpec(name: "peek", peek: true) { $0.setPose(perk: 0.4, lookX: -0.3, time: 0.3) },
    PetSpec(name: "peek · waving", peek: true) { $0.setPose(happy: 1, waveArm: 1, time: 0.1) },
]

func petCells(_ pet: Pet, _ specs: [PetSpec], _ palette: CatPalette) -> [(PetSpec, CatEngine, CatPalette)] {
    specs.map { s in let e = makeEngine(); e.species = pet; s.apply(e); return (s, e, palette) }
}
func row(_ title: String, _ cells: [(PetSpec, CatEngine, CatPalette)]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        Text(title).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9))
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellW), spacing: 14), count: 5), alignment: .leading, spacing: 14) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, c in
                CatCell(engine: c.1, palette: c.2, background: menuDark, label: c.0.name, peek: c.0.peek)
            }
        }
    }
}
let coatRow: [(PetSpec, CatEngine, CatPalette)] =
    DogCoat.allCases.map { c in let e = makeEngine(); e.species = .dog; e.setPose(sit: 1, happy: 0.6, time: 0.5)
        return (PetSpec(name: c.name) { _ in }, e, c.palette) } +
    BirdCoat.allCases.map { c in let e = makeEngine(); e.species = .bird; e.setPose(perk: 0.4, time: 0.5)
        return (PetSpec(name: c.name) { _ in }, e, c.palette) }

let petSheet = VStack(alignment: .leading, spacing: 26) {
    Text("Notchi · dog & bird").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.white)
    row("Dog · Shiba", petCells(.dog, dogSpecs, DogCoat.shiba.palette))
    row("Bird · Budgie", petCells(.bird, birdSpecs, BirdCoat.budgie.palette))
    row("All breeds", coatRow)
}
.padding(28)
.background(Color(hex: 0x111114))
MainActor.assumeIsolated { png(petSheet, to: "\(outDir)/pets.png") }

// MARK: Animated demo: walk → notice cursor → wave → sit → vibe → doze off

func smooth(_ x: Double) -> Double { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
func window(_ t: Double, _ a: Double, _ b: Double, fade: Double = 0.35) -> Double {
    smooth((t - a) / fade) * (1 - smooth((t - b) / fade))
}

let fps = 30.0, seconds = 9.0
let gifURL = URL(fileURLWithPath: "\(outDir)/cat-demo.gif") as CFURL
let frameCount = Int(fps * seconds)
if let dest = CGImageDestinationCreateWithURL(gifURL, UTType.gif.identifier as CFString, frameCount, nil) {
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
    var phase = 0.0
    for i in 0..<frameCount {
        let t = Double(i) / fps
        let e = makeEngine()
        let walkAmt = 1 - smooth((t - 1.6) / 0.4)
        phase += walkAmt * 0.42
        let stand = window(t, 1.9, 3.4)
        let sit = window(t, 3.6, 8.6)
        let bob = window(t, 4.4, 6.2)
        let loaf = window(t, 6.6, 8.6, fade: 0.8)
        let blink = (t > 3.9 && t < 4.06) ? sin((t - 3.9) / 0.16 * .pi) : 0
        let happy = max(stand, bob * 0.8)
        e.setPose(walk: walkAmt, phase: phase, sit: sit, loaf: loaf, stand: stand, blink: blink,
                  perk: window(t, 1.6, 3.4), happy: happy, headBob: bob, time: t)
        let frame = CatCell(engine: e, palette: siamese, background: menuDark, label: nil)
            .padding(10).background(Color(hex: 0x111114))
        let r = MainActor.assumeIsolated { () -> CGImage? in
            let rr = ImageRenderer(content: frame); rr.scale = 1.5; return rr.cgImage
        }
        if let cg = r { CGImageDestinationAddImage(dest, cg, frameProps) }
    }
    if CGImageDestinationFinalize(dest) { print("wrote \(outDir)/cat-demo.gif") }
}
