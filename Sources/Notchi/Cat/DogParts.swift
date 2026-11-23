import SwiftUI

/// Dog-specific drawing. The dog reuses the cat's body rig (legs, gait, poses), and swaps
/// in its own head, tail behaviour and a little "woof!" bubble.
extension CatRenderer {

    /// Tail wags faster and wider the happier/more excited the dog is; Shibas curl it over the back.
    static func dogTail(_ tail: [CGPoint], engine e: CatEngine, palette pal: CatPalette) -> [CGPoint] {
        var t = tail
        let excite = CGFloat(min(1, e.happy + e.perk * 0.7 + e.walk * 0.3 + e.bow * 0.8))
        let wag = CGFloat(sin(e.time * (9 + 9 * Double(excite)))) * (0.6 + 2.4 * excite)
        let up = 1 - CGFloat(max(e.sit, e.loaf))
        if pal.curlyTail {
            let b = t[0]
            let curl = [b, CGPoint(x: b.x - 4, y: b.y - 3), CGPoint(x: b.x - 3.5, y: b.y - 10.5),
                        CGPoint(x: b.x + 2.5, y: b.y - 9.5)]
            t = zip(t, curl).map { mix($0, $1, up) }
        }
        t[3].x += wag
        t[2].x += wag * 0.5
        return t
    }

    /// Head-local (origin = head centre). `swing` makes floppy ears bounce with the gait.
    static func drawDogHead(_ h: GraphicsContext, r: CGFloat, pal: CatPalette, face f: Face,
                            time: Double, swing: CGFloat) {
        let fr = f.frontal
        let side = 1 - fr
        let ow: CGFloat = 1.15

        // Pointy ears sit behind the head (Shiba).
        if !pal.floppyEars {
            let earLen = 1.36 + 0.08 * f.perk
            for theta in [mix(-2.05, -2.18, fr) - f.earBack, mix(-1.05, -0.96, fr) + f.earBack + f.earTwitch * 0.2] {
                let baseR = r * 0.74, half: CGFloat = 0.5
                let b1 = CGPoint(x: cos(theta - half) * baseR, y: sin(theta - half) * baseR * 0.9)
                let b2 = CGPoint(x: cos(theta + half) * baseR, y: sin(theta + half) * baseR * 0.9)
                let tip = CGPoint(x: cos(theta) * r * earLen, y: sin(theta) * r * earLen * 0.92)
                var path = Path()
                path.move(to: b1)
                path.addLine(to: mix(tip, b1, 0.2))
                path.addQuadCurve(to: mix(tip, b2, 0.2), control: tip)
                path.addLine(to: b2)
                path.closeSubpath()
                h.fill(path, with: .color(pal.fur))
                outlined(h, path, pal)
                let c = CGPoint(x: (b1.x + b2.x + tip.x) / 3, y: (b1.y + b2.y + tip.y) / 3 + 0.7)
                var inner = Path()
                inner.move(to: mix(c, b1, 0.55))
                inner.addLine(to: mix(c, tip, 0.6))
                inner.addLine(to: mix(c, b2, 0.55))
                inner.closeSubpath()
                h.fill(inner, with: .color(pal.cream))
            }
        }

        // Head with a cream lower face.
        let headPath = pal.fluff > 0.6
            ? headPath(r: r * 0.95, fluff: pal.fluff * 0.6)
            : Path(ellipseIn: CGRect(x: -r, y: -0.92 * r, width: 2 * r, height: 1.84 * r))
        h.fill(headPath, with: .color(pal.fur))
        var hc = h
        hc.clip(to: headPath)
        hc.fill(Path(ellipseIn: CGRect(x: side * 0.3 * r - 0.85 * r, y: 0.42 * r - 0.5 * r, width: 1.7 * r, height: 1.05 * r)),
                with: .color(pal.cream))
        outlined(h, headPath, pal, width: ow)

        // Floppy ears hang in front of the head and bounce.
        if pal.floppyEars {
            for s in [CGFloat(-1), 1] {
                let ax = mix(s < 0 ? -0.66 * r : 0.02 * r, s * 0.8 * r, fr)
                let top = CGPoint(x: ax, y: -0.6 * r)
                let angle = -s * 0.22 + swing * 0.12 + CGFloat(sin(time * 2.2 + Double(s))) * 0.04 - f.perk * 0.12 * s
                let ear = Path { p in
                    p.move(to: CGPoint(x: -0.28 * r, y: 0))
                    p.addCurve(to: CGPoint(x: 0, y: 1.05 * r),
                               control1: CGPoint(x: -0.52 * r, y: 0.4 * r), control2: CGPoint(x: -0.36 * r, y: 1.0 * r))
                    p.addCurve(to: CGPoint(x: 0.28 * r, y: 0),
                               control1: CGPoint(x: 0.36 * r, y: 1.0 * r), control2: CGPoint(x: 0.46 * r, y: 0.35 * r))
                    p.closeSubpath()
                }.applying(CGAffineTransform(translationX: top.x, y: top.y).rotated(by: angle))
                h.fill(ear, with: .color(pal.furDark))
                outlined(h, ear, pal)
            }
        }

        // Eyes (+ Shiba "maro" eyebrow dots).
        let eyeL = CGPoint(x: mix(-0.12 * r, -0.4 * r, fr), y: -0.12 * r)
        let eyeR = CGPoint(x: mix(0.44 * r, 0.4 * r, fr), y: -0.14 * r)
        let es = 1 + 0.15 * f.perk
        for c in [eyeL, eyeR] {
            if f.eyesClosed > 0.55 {
                let up = f.happy > 0.5
                let arc = Path { ap in
                    ap.move(to: CGPoint(x: c.x - 1.3, y: c.y + (up ? 0.5 : -0.2)))
                    ap.addQuadCurve(to: CGPoint(x: c.x + 1.3, y: c.y + (up ? 0.5 : -0.2)),
                                    control: CGPoint(x: c.x, y: c.y + (up ? -1.1 : 1.3)))
                }
                h.stroke(arc, with: .color(pal.eye), style: StrokeStyle(lineWidth: 0.95, lineCap: .round))
            } else {
                let cx = c.x + f.lookX * 0.3
                let eh = 2.9 * es * (1 - f.eyesClosed)
                h.fill(Path(ellipseIn: CGRect(x: cx - 1.15 * es, y: c.y - eh / 2, width: 2.3 * es, height: eh)),
                       with: .color(pal.eye))
                if eh > 1.3 {
                    h.fill(Path(ellipseIn: CGRect(x: cx + 0.4 - 0.6, y: c.y - eh * 0.25 - 0.6, width: 1.2, height: 1.2)),
                           with: .color(.white))
                }
            }
            if let b = pal.brows {
                h.fill(Path(ellipseIn: CGRect(x: c.x - 0.9, y: c.y - 0.3 * r - 0.5, width: 1.8, height: 1.0)),
                       with: .color(b))
            }
        }
        // Blush
        let bs = 1 + 0.5 * f.happy
        for c in [CGPoint(x: eyeL.x - 0.9, y: 0.32 * r), CGPoint(x: eyeR.x + 1.4, y: 0.3 * r)] {
            h.fill(Path(ellipseIn: CGRect(x: c.x - 1.4 * bs, y: c.y - 0.7 * bs, width: 2.8 * bs, height: 1.4 * bs)),
                   with: .color(pal.blush.opacity(0.45 + 0.2 * Double(f.happy))))
        }

        // Snout, nose, mouth / tongue / bark.
        let snoutC = CGPoint(x: side * 0.8 * r, y: 0.32 * r)
        let snoutW = mix(1.0 * r, 0.9 * r, fr), snoutH = 0.66 * r
        let snout = Path(ellipseIn: CGRect(x: snoutC.x - snoutW / 2, y: snoutC.y - snoutH / 2, width: snoutW, height: snoutH))
        h.fill(snout, with: .color(pal.cream))
        outlined(h, snout, pal, width: 0.9)
        let noseC = CGPoint(x: snoutC.x + side * snoutW * 0.36, y: snoutC.y - 0.16 * r)
        let nose = Path(ellipseIn: CGRect(x: noseC.x - 0.2 * r, y: noseC.y - 0.13 * r, width: 0.4 * r, height: 0.28 * r))
        h.fill(nose, with: .color(pal.nose ?? pal.eye))
        h.fill(Path(ellipseIn: CGRect(x: noseC.x - 0.06 * r, y: noseC.y - 0.09 * r, width: 0.12 * r, height: 0.07 * r)),
               with: .color(.white.opacity(0.8)))
        let mouthTop = CGPoint(x: noseC.x - side * 0.04 * r, y: noseC.y + 0.13 * r)
        if f.mouthO > 0.25 {
            let o = f.mouthO
            let m = CGRect(x: mouthTop.x - 0.2 * r * o, y: mouthTop.y + 0.12 * r, width: 0.4 * r * o, height: 0.32 * r * o)
            h.fill(Path(ellipseIn: m), with: .color(pal.outline))
            h.fill(Path(ellipseIn: CGRect(x: m.midX - 0.12 * r * o, y: m.maxY - 0.14 * r * o, width: 0.24 * r * o, height: 0.12 * r * o)),
                   with: .color(pal.pink))
        } else {
            let mouth = Path { m in
                m.move(to: mouthTop)
                m.addLine(to: CGPoint(x: mouthTop.x, y: mouthTop.y + 0.12 * r))
                m.addQuadCurve(to: CGPoint(x: mouthTop.x - 0.2 * r, y: mouthTop.y + 0.12 * r),
                               control: CGPoint(x: mouthTop.x - 0.1 * r, y: mouthTop.y + 0.24 * r))
                m.move(to: CGPoint(x: mouthTop.x, y: mouthTop.y + 0.12 * r))
                m.addQuadCurve(to: CGPoint(x: mouthTop.x + 0.2 * r, y: mouthTop.y + 0.12 * r),
                               control: CGPoint(x: mouthTop.x + 0.1 * r, y: mouthTop.y + 0.24 * r))
            }
            if f.happy > 0.35 {
                // Panting tongue.
                let wob = CGFloat(sin(time * 14)) * 0.03 * r
                let tl = 0.38 * r * f.happy
                let tongue = Path(roundedRect: CGRect(x: mouthTop.x - 0.13 * r, y: mouthTop.y + 0.14 * r + wob,
                                                      width: 0.26 * r, height: tl),
                                  cornerRadius: 0.13 * r)
                h.fill(tongue, with: .color(pal.pink))
                outlined(h, tongue, pal, width: 0.55)
            }
            outlined(h, mouth, pal, width: 0.6)
        }
    }

    /// A tiny speech bubble ("woof!") above the head, in un-mirrored space.
    static func drawBark(_ base: GraphicsContext, at p: CGPoint, pal: CatPalette, opacity: Double) {
        var b = base
        b.opacity *= opacity
        let text = b.resolve(Text("woof!").font(.system(size: 4.4, weight: .heavy, design: .rounded))
            .foregroundColor(pal.outline))
        let sz = text.measure(in: CGSize(width: 100, height: 100))
        let rect = CGRect(x: p.x - sz.width / 2 - 1.6, y: p.y - sz.height / 2 - 0.9,
                          width: sz.width + 3.2, height: sz.height + 1.8)
        let bubble = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        b.fill(bubble, with: .color(.white))
        b.stroke(bubble, with: .color(pal.outline), lineWidth: 0.6)
        b.draw(text, at: p)
    }
}
