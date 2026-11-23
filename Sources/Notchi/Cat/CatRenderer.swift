import SwiftUI

/// Draws the cat as layered vector shapes. Body geometry lives in a 46×34 "unit" box
/// (cat facing right, ground at y = 32.5), scaled to the menu bar height.
enum CatRenderer {
    static let unitW: CGFloat = 46
    static let unitH: CGFloat = 34
    static let ground: CGFloat = 32.5
    static let pivotX: CGFloat = 22

    struct Leg {
        var hip: CGPoint
        var angle: CGFloat   // radians, positive swings the paw forward
        var length: CGFloat
        var alpha: CGFloat
    }

    struct Pose {
        var bodyC: CGPoint
        var bodyS: CGSize
        var bodyTilt: CGFloat
        var headC: CGPoint
        var headR: CGFloat
        var headTilt: CGFloat
        var legs: [Leg]            // farBack, farFront, nearBack, nearFront
        var haunch: CGFloat
        var tail: [CGPoint]        // cubic: start, c1, c2, tip
        var eyesClosed: CGFloat
    }

    struct Face {
        var eyesClosed: CGFloat = 0
        var perk: CGFloat = 0
        var mouthO: CGFloat = 0
        var happy: CGFloat = 0
        var lookX: CGFloat = 0
        var earTwitch: CGFloat = 0
        var earBack: CGFloat = 0
        /// 0 = three-quarter view facing right, 1 = looking straight at you.
        var frontal: CGFloat = 0
    }

    // MARK: - Key poses

    static func walkPose(phase: Double, w: CGFloat, time: Double) -> Pose {
        let bob = CGFloat(cos(2 * phase)) * 0.55 * w
        let hipY = 25.4 + bob
        func leg(_ hx: CGFloat, _ off: Double) -> Leg {
            let p = phase + off
            let a = CGFloat(sin(p)) * 0.5 * w
            let raise = CGFloat(max(0, cos(p))) * 1.5 * w
            return Leg(hip: CGPoint(x: hx, y: hipY), angle: a,
                       length: (ground - hipY) / cos(a) - raise, alpha: 1)
        }
        let sway = CGFloat(sin(time * 2.3)) * 1.3 + CGFloat(sin(phase)) * 0.9 * w
        return Pose(
            bodyC: CGPoint(x: 20, y: 22.4 + bob),
            bodyS: CGSize(width: 22.5, height: 13.2),
            bodyTilt: 0,
            headC: CGPoint(x: 31.4, y: 14.4 + CGFloat(cos(2 * phase - 0.8)) * 0.4 * w),
            headR: 9.2,
            headTilt: CGFloat(sin(time * 0.7)) * 0.03,
            legs: [leg(12.4, .pi), leg(23.6, 0), leg(15.0, 0), leg(26.2, .pi)],
            haunch: 0,
            tail: [CGPoint(x: 9.2, y: 20.4 + bob), CGPoint(x: 4.4, y: 20.2 + bob),
                   CGPoint(x: 1.4 + sway * 0.3, y: 12.8), CGPoint(x: 4.6 + sway, y: 6.6)],
            eyesClosed: 0)
    }

    static func sitPose(time: Double) -> Pose {
        let flick = CGFloat(sin(time * 1.7)) * 0.9 + CGFloat(sin(time * 0.6)) * 0.5
        return Pose(
            bodyC: CGPoint(x: 18.4, y: 22.0),
            bodyS: CGSize(width: 15.2, height: 17.0),
            bodyTilt: -0.2,
            headC: CGPoint(x: 25.0, y: 10.6),
            headR: 9.2,
            headTilt: CGFloat(sin(time * 0.7)) * 0.03,
            legs: [Leg(hip: CGPoint(x: 13.5, y: 27), angle: 0, length: 4, alpha: 0),
                   Leg(hip: CGPoint(x: 21.6, y: 24.2), angle: 0.03, length: ground - 24.2, alpha: 1),
                   Leg(hip: CGPoint(x: 15.5, y: 27), angle: 0, length: 4, alpha: 0),
                   Leg(hip: CGPoint(x: 24.2, y: 24.2), angle: 0, length: ground - 24.2, alpha: 1)],
            haunch: 1,
            tail: [CGPoint(x: 10.2, y: 29.6), CGPoint(x: 5.6, y: 34.2),
                   CGPoint(x: 17, y: 34.6), CGPoint(x: 25.6 + flick, y: 32.6)],
            eyesClosed: 0)
    }

    static func loafPose(time: Double) -> Pose {
        let br = CGFloat(sin(time * 1.4)) * 0.35
        let tuck = { (x: CGFloat) in Leg(hip: CGPoint(x: x, y: 27), angle: 0, length: 2, alpha: 0) }
        return Pose(
            bodyC: CGPoint(x: 20, y: 26.2 - br * 0.4),
            bodyS: CGSize(width: 25 + br, height: 12.6 + br),
            bodyTilt: 0,
            headC: CGPoint(x: 31.2, y: 22.4),
            headR: 8.9,
            headTilt: 0.08,
            legs: [tuck(12.4), tuck(23.6), tuck(15), tuck(26.2)],
            haunch: 0,
            tail: [CGPoint(x: 8.4, y: 28.2), CGPoint(x: 3.8, y: 33.6),
                   CGPoint(x: 15, y: 34.4), CGPoint(x: 25, y: 32.4)],
            eyesClosed: 1)
    }

    static func bowPose(time: Double) -> Pose {
        let wag = CGFloat(sin(time * 5))
        return Pose(
            bodyC: CGPoint(x: 19.6, y: 22.6),
            bodyS: CGSize(width: 23, height: 12.6),
            bodyTilt: 0.28,
            headC: CGPoint(x: 33.2, y: 20.6),
            headR: 9,
            headTilt: -0.06,
            legs: [Leg(hip: CGPoint(x: 12.6, y: 21.4), angle: -0.08, length: ground - 21.4, alpha: 1),
                   Leg(hip: CGPoint(x: 25.4, y: 28.4), angle: 1.25, length: 7.4, alpha: 1),
                   Leg(hip: CGPoint(x: 15.2, y: 21.4), angle: -0.04, length: ground - 21.4, alpha: 1),
                   Leg(hip: CGPoint(x: 28.0, y: 28.4), angle: 1.3, length: 7.6, alpha: 1)],
            haunch: 0,
            tail: [CGPoint(x: 9.4, y: 17.6), CGPoint(x: 6, y: 12),
                   CGPoint(x: 3.6, y: 6.4 + wag * 0.8), CGPoint(x: 7.6 + wag * 1.2, y: 2.6)],
            eyesClosed: 0)
    }

    /// Up on the hind legs, waving one paw.
    static func standPose(time: Double) -> Pose {
        let wave = CGFloat(sin(time * 11)) * 0.38
        let sway = CGFloat(sin(time * 3))
        return Pose(
            bodyC: CGPoint(x: 18.8, y: 19.4),
            bodyS: CGSize(width: 14.2, height: 18.4),
            bodyTilt: -0.36,
            headC: CGPoint(x: 23.6, y: 7.6),
            headR: 9.2,
            headTilt: CGFloat(sin(time * 5.5)) * 0.07,
            legs: [Leg(hip: CGPoint(x: 14.8, y: 26.2), angle: 0.06, length: ground - 26.2, alpha: 1),
                   Leg(hip: CGPoint(x: 22.0, y: 18.8), angle: 0.95, length: 4.6, alpha: 1),
                   Leg(hip: CGPoint(x: 17.4, y: 26.2), angle: -0.02, length: ground - 26.2, alpha: 1),
                   Leg(hip: CGPoint(x: 25.4, y: 17.6), angle: .pi - 1.05 + wave, length: 7.2, alpha: 1)],
            haunch: 0,
            tail: [CGPoint(x: 12.0, y: 26.0), CGPoint(x: 6.0, y: 27.4),
                   CGPoint(x: 3.6, y: 18.0), CGPoint(x: 7.4 + sway, y: 13.0)],
            eyesClosed: 0)
    }

    // MARK: - Blending

    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: mix(a.x, b.x, t), y: mix(a.y, b.y, t))
    }
    static func mix(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        guard t > 0.0001 else { return a }
        guard t < 0.9999 else { return b }
        var p = a
        p.bodyC = mix(a.bodyC, b.bodyC, t)
        p.bodyS = CGSize(width: mix(a.bodyS.width, b.bodyS.width, t), height: mix(a.bodyS.height, b.bodyS.height, t))
        p.bodyTilt = mix(a.bodyTilt, b.bodyTilt, t)
        p.headC = mix(a.headC, b.headC, t)
        p.headR = mix(a.headR, b.headR, t)
        p.headTilt = mix(a.headTilt, b.headTilt, t)
        p.legs = zip(a.legs, b.legs).map { la, lb in
            Leg(hip: mix(la.hip, lb.hip, t), angle: mix(la.angle, lb.angle, t),
                length: mix(la.length, lb.length, t), alpha: mix(la.alpha, lb.alpha, t))
        }
        p.haunch = mix(a.haunch, b.haunch, t)
        p.tail = zip(a.tail, b.tail).map { mix($0, $1, t) }
        p.eyesClosed = mix(a.eyesClosed, b.eyesClosed, t)
        return p
    }

    static func bobOffset(_ e: CatEngine) -> CGFloat {
        CGFloat(sin(e.time * 2 * .pi * 1.9)) * CGFloat(e.headBob)
    }

    static func pose(for e: CatEngine) -> Pose {
        var p = walkPose(phase: e.walkPhase, w: CGFloat(e.walk), time: e.time)
        p = mix(p, sitPose(time: e.time), CGFloat(e.sit))
        p = mix(p, bowPose(time: e.time), CGFloat(e.bow))
        p = mix(p, standPose(time: e.time), CGFloat(e.stand))
        p = mix(p, loafPose(time: e.time), CGFloat(e.loaf))

        let c = CGFloat(e.crouch) + CGFloat(e.swat) * 0.35
        if c > 0.001 {
            p.bodyC.y += 2.4 * c
            p.headC.y += 2.8 * c
            p.bodyS.height *= 1 - 0.1 * c
            p.bodyS.width *= 1 + 0.06 * c
            for i in p.legs.indices {
                p.legs[i].hip.y += 2.4 * c
                p.legs[i].length = max(1.5, p.legs[i].length - 2.4 * c)
            }
        }
        let sw = CGFloat(e.swat)
        if sw > 0.001 {
            p.legs[3].angle = mix(p.legs[3].angle, 1.05 + 0.45 * CGFloat(sin(e.time * 13)), sw)
            p.legs[3].length = mix(p.legs[3].length, p.legs[3].length * 0.85, sw)
        }
        let a = CGFloat(e.air)
        if a > 0.001 {
            for i in p.legs.indices {
                let target: CGFloat = (i == 1 || i == 3) ? 0.85 : -0.85
                p.legs[i].angle = mix(p.legs[i].angle, target, a)
                p.legs[i].length = mix(p.legs[i].length, 7.0, a)
            }
            p.bodyS.width *= 1 + 0.07 * a
            p.tail[3].y -= 3 * a
        }
        let bob = bobOffset(e)
        p.headC.y += bob * 0.9
        p.headTilt += bob * 0.07
        p.eyesClosed = max(p.eyesClosed, CGFloat(e.blink))
        return p
    }

    // MARK: - Shared drawing helpers

    static func outlined(_ ctx: GraphicsContext, _ path: Path, _ pal: CatPalette, width: CGFloat = 1.15) {
        ctx.stroke(path, with: .color(pal.outline), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// Head outline with fluffy cheek tufts.
    static func headPath(r: CGFloat, fluff: CGFloat) -> Path {
        let n = 120
        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            let th = Double(i) / Double(n) * 2 * .pi
            var k = 1.0
            for c in [0.62, Double.pi - 0.62] {
                var d = th - c
                d = atan2(sin(d), cos(d))
                if abs(d) < 0.45 {
                    let w = 1 - abs(d) / 0.45
                    k += Double(fluff) * 0.12 * w * abs(sin(d / 0.45 * .pi * 1.5))
                }
            }
            pts.append(CGPoint(x: cos(th) * 1.08 * r * k, y: sin(th) * 0.95 * r * k))
        }
        return Path { p in p.addLines(pts); p.closeSubpath() }
    }

    /// Draws ears, head, mask and face around the context origin (= head centre).
    static func drawHead(_ h: GraphicsContext, r: CGFloat, pal: CatPalette, face f: Face) {
        let fr = f.frontal
        let noseX = 1.0 * (1 - fr)
        let ow: CGFloat = 1.15

        // Ears
        let earLen = 1.42 + 0.1 * f.perk
        func ear(_ theta: CGFloat) {
            let baseR = r * 0.78, half: CGFloat = 0.42
            let b1 = CGPoint(x: cos(theta - half) * baseR, y: sin(theta - half) * baseR * 0.9)
            let b2 = CGPoint(x: cos(theta + half) * baseR, y: sin(theta + half) * baseR * 0.9)
            let tip = CGPoint(x: cos(theta) * r * earLen, y: sin(theta) * r * earLen * 0.92)
            let t1 = mix(tip, b1, 0.16), t2 = mix(tip, b2, 0.16)
            var path = Path()
            path.move(to: b1)
            path.addLine(to: t1)
            path.addQuadCurve(to: t2, control: tip)
            path.addLine(to: b2)
            path.closeSubpath()
            h.fill(path, with: .color(pal.points ?? pal.fur))
            outlined(h, path, pal)
            let c = CGPoint(x: (b1.x + b2.x + tip.x) / 3, y: (b1.y + b2.y + tip.y) / 3 + 0.6)
            var inner = Path()
            inner.move(to: mix(c, b1, 0.55))
            inner.addLine(to: mix(c, tip, 0.62))
            inner.addLine(to: mix(c, b2, 0.55))
            inner.closeSubpath()
            h.fill(inner, with: .color((pal.innerEar ?? pal.pink).opacity(0.9)))
        }
        ear(mix(-2.1, -2.2, fr) - f.earBack)
        ear(mix(-1.0, -0.94, fr) + f.earBack + f.earTwitch * 0.22)

        // Head + mask/muzzle
        let headPath = headPath(r: r, fluff: pal.fluff)
        h.fill(headPath, with: .color(pal.fur))
        var hc = h
        hc.clip(to: headPath)
        if let mask = pal.mask {
            var m = hc
            m.translateBy(x: noseX, y: 1.8)
            m.scaleBy(x: 1.28, y: 1)
            let R: CGFloat = 6.8
            m.fill(Path(ellipseIn: CGRect(x: -R, y: -R, width: R * 2, height: R * 2)),
                   with: .radialGradient(Gradient(stops: [.init(color: mask, location: 0),
                                                          .init(color: mask, location: 0.55),
                                                          .init(color: mask.opacity(0), location: 1)]),
                                         center: .zero, startRadius: 0, endRadius: R))
        } else {
            hc.fill(Path(ellipseIn: CGRect(x: noseX + 0.3 - 4.6, y: 3.6 - 2.9, width: 9.2, height: 5.8)),
                    with: .color(pal.cream))
        }
        if pal.stripes {
            for (a, b) in [(CGPoint(x: -2.4, y: -7.8), CGPoint(x: -2.0, y: -5.6)),
                           (CGPoint(x: 0.4, y: -8.4), CGPoint(x: 0.4, y: -6.0)),
                           (CGPoint(x: 3.2, y: -7.8), CGPoint(x: 2.8, y: -5.6))] {
                hc.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(pal.furDark),
                          style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            }
        }
        outlined(h, headPath, pal, width: ow)

        // Blush
        let eyeL = CGPoint(x: mix(-2.6, -3.5, fr), y: 0.6)
        let eyeR = CGPoint(x: mix(4.5, 3.5, fr), y: 0.6)
        let bs = 1 + 0.6 * f.happy
        for c in [CGPoint(x: eyeL.x - 1.4, y: 3.7), CGPoint(x: eyeR.x + 1.4, y: 3.7)] {
            h.fill(Path(ellipseIn: CGRect(x: c.x - 1.5 * bs, y: c.y - 0.8 * bs, width: 3 * bs, height: 1.6 * bs)),
                   with: .color(pal.blush.opacity(0.5 + 0.2 * Double(f.happy))))
        }

        // Eyes
        let closed = f.eyesClosed
        let es = 1 + 0.15 * f.perk + 0.1 * f.mouthO
        for c in [eyeL, eyeR] {
            if closed > 0.55 {
                let up = f.happy > 0.5   // happy ^ ^ vs sleepy u u
                let arc = Path { ap in
                    ap.move(to: CGPoint(x: c.x - 1.35, y: c.y + (up ? 0.5 : -0.2)))
                    ap.addQuadCurve(to: CGPoint(x: c.x + 1.35, y: c.y + (up ? 0.5 : -0.2)),
                                    control: CGPoint(x: c.x, y: c.y + (up ? -1.1 : 1.4)))
                }
                h.stroke(arc, with: .color(pal.mask == nil ? pal.eye : pal.outline),
                         style: StrokeStyle(lineWidth: 0.95, lineCap: .round))
            } else if let iris = pal.iris {
                let ew = 2.9 * es, eh = 3.3 * es * (1 - closed)
                let eyeRect = CGRect(x: c.x - ew / 2, y: c.y - eh / 2, width: ew, height: eh)
                h.fill(Path(ellipseIn: eyeRect), with: .color(iris))
                var ec = h
                ec.clip(to: Path(ellipseIn: eyeRect))
                let px = c.x + f.lookX * 0.45
                ec.fill(Path(ellipseIn: CGRect(x: px - 0.95 * es, y: c.y - 1.1 * es, width: 1.9 * es, height: 2.2 * es)),
                        with: .color(pal.eye))
                h.stroke(Path(ellipseIn: eyeRect), with: .color(pal.outline), lineWidth: 0.45)
                if eh > 1.4 {
                    h.fill(Path(ellipseIn: CGRect(x: c.x + 0.55 - 0.72, y: c.y - eh * 0.24 - 0.72, width: 1.44, height: 1.44)),
                           with: .color(.white))
                    h.fill(Path(ellipseIn: CGRect(x: c.x - 0.6 - 0.32, y: c.y + eh * 0.22 - 0.32, width: 0.64, height: 0.64)),
                           with: .color(.white.opacity(0.85)))
                }
            } else {
                let eh = 3.1 * es * (1 - closed)
                let cx = c.x + f.lookX * 0.3
                h.fill(Path(ellipseIn: CGRect(x: cx - 1.2 * es, y: c.y - eh / 2, width: 2.4 * es, height: eh)),
                       with: .color(pal.eye))
                if eh > 1.4 {
                    h.fill(Path(ellipseIn: CGRect(x: cx + 0.45 - 0.62, y: c.y - eh * 0.25 - 0.62, width: 1.24, height: 1.24)),
                           with: .color(.white))
                    h.fill(Path(ellipseIn: CGRect(x: cx - 0.45 - 0.3, y: c.y + eh * 0.22 - 0.3, width: 0.6, height: 0.6)),
                           with: .color(.white.opacity(0.8)))
                }
            }
        }

        // Nose
        var nose = Path()
        nose.move(to: CGPoint(x: noseX - 0.85, y: 2.3))
        nose.addLine(to: CGPoint(x: noseX + 0.85, y: 2.3))
        nose.addLine(to: CGPoint(x: noseX, y: 3.25))
        nose.closeSubpath()
        h.fill(nose, with: .color(pal.nose ?? pal.pink))
        outlined(h, nose, pal, width: 0.45)

        // Mouth: "o" when surprised, a wider ω when happy.
        if f.mouthO > 0.25 {
            let o = f.mouthO
            let mouthRect = CGRect(x: noseX - 0.8 * o, y: 3.9, width: 1.6 * o, height: 1.9 * o)
            h.fill(Path(ellipseIn: mouthRect), with: .color(pal.outline))
            h.fill(Path(ellipseIn: CGRect(x: mouthRect.midX - 0.45 * o, y: mouthRect.maxY - 0.9 * o,
                                          width: 0.9 * o, height: 0.6 * o)),
                   with: .color(pal.pink))
        } else {
            let s = 1 + 0.35 * f.happy
            let mouth = Path { m in
                m.move(to: CGPoint(x: noseX, y: 3.25))
                m.addQuadCurve(to: CGPoint(x: noseX - 1.4 * s, y: 3.9 + 0.2 * f.happy),
                               control: CGPoint(x: noseX - 0.1, y: 4.3 + 0.4 * f.happy))
                m.move(to: CGPoint(x: noseX, y: 3.25))
                m.addQuadCurve(to: CGPoint(x: noseX + 1.4 * s, y: 3.9 + 0.2 * f.happy),
                               control: CGPoint(x: noseX + 0.1, y: 4.3 + 0.4 * f.happy))
            }
            outlined(h, mouth, pal, width: 0.6)
        }

        // Whiskers
        let whiskers = Path { w in
            let l = noseX - 5.4, rr = noseX + 5.6
            w.move(to: CGPoint(x: l, y: 3.0)); w.addLine(to: CGPoint(x: l - 4.2, y: 2.2))
            w.move(to: CGPoint(x: l, y: 3.8)); w.addLine(to: CGPoint(x: l - 4.0, y: 4.4))
            w.move(to: CGPoint(x: rr, y: 3.0)); w.addLine(to: CGPoint(x: rr + 4.0, y: 2.2))
            w.move(to: CGPoint(x: rr, y: 3.8)); w.addLine(to: CGPoint(x: rr + 3.8, y: 4.4))
        }
        h.stroke(whiskers, with: .color(pal.outline.opacity(0.45)), style: StrokeStyle(lineWidth: 0.4, lineCap: .round))
    }

    static func paw(_ g: GraphicsContext, center c: CGPoint, pal: CatPalette, angle: CGFloat = 0, beans: Bool = false) {
        var p = g
        p.translateBy(x: c.x, y: c.y)
        p.rotate(by: .radians(Double(angle)))
        let rect = CGRect(x: -3.3, y: -2.6, width: 6.6, height: 5.2)
        let path = Path(ellipseIn: rect)
        p.fill(path, with: .color(pal.points ?? pal.cream))
        if beans {
            p.fill(Path(ellipseIn: CGRect(x: -1.5, y: -0.2, width: 3.0, height: 2.2)), with: .color(pal.pink))
            for (bx, by) in [(-2.0, -1.7), (-0.5, -2.2), (1.0, -1.7)] {
                p.fill(Path(ellipseIn: CGRect(x: bx, y: by, width: 1.1, height: 1.1)), with: .color(pal.pink))
            }
        } else {
            for dx in [-1.1, 1.1] {
                p.stroke(Path { $0.move(to: CGPoint(x: dx, y: 0.6)); $0.addLine(to: CGPoint(x: dx, y: 2.3)) },
                         with: .color(pal.outline), style: StrokeStyle(lineWidth: 0.55, lineCap: .round))
            }
        }
        outlined(p, path, pal)
    }

    // MARK: - Full body (menu bar cat)

    /// `anchor` is where the point between the cat's feet lands on the canvas.
    /// The body rotates around it (`engine.rotation`), which is how it climbs walls.
    static func draw(in ctx: inout GraphicsContext, engine e: CatEngine, palette pal: CatPalette,
                     anchor: CGPoint, k: CGFloat) {
        if e.species == .bird {
            BirdRenderer.draw(in: &ctx, engine: e, palette: pal, anchor: anchor, k: k)
            return
        }
        var p = pose(for: e)
        if e.species == .dog {
            p.tail = dogTail(p.tail, engine: e, palette: pal)
            // Up on hind legs: both front paws reach up and forward (scrabbling at the wall).
            let st = CGFloat(e.stand)
            if st > 0.01 {
                let scrab = CGFloat(sin(e.time * 13)) * 0.25
                p.legs[3].angle = mix(p.legs[3].angle, 2.05 + scrab, st)
                p.legs[1].angle = mix(p.legs[1].angle, 2.25 - scrab, st)
                p.legs[1].length = mix(p.legs[1].length, 6.6, st)
            }
        }
        var face = e.faceScale
        if abs(face) < 0.06 { face = face < 0 ? -0.06 : 0.06 }

        // Floor shadow (only while upright); it stays on the floor while the cat is in the air.
        if abs(e.rotation) < 0.35 {
            var sc = ctx
            sc.opacity = e.alpha * (1 - abs(e.rotation) / 0.35)
            sc.translateBy(x: anchor.x, y: anchor.y + e.lift)
            sc.scaleBy(x: k, y: k)
            let sh = max(0.25, 1 - e.lift / k / 30)
            let cx = (p.bodyC.x - pivotX + 1.5) * face
            sc.fill(Path(ellipseIn: CGRect(x: cx - 11 * sh, y: -1.0, width: 22 * sh, height: 2.4)),
                    with: .color(.black.opacity(0.22 * sh)))
        }

        var base = ctx
        base.opacity = e.alpha
        base.translateBy(x: anchor.x, y: anchor.y)
        base.rotate(by: .radians(e.rotation))
        base.scaleBy(x: k * CGFloat(e.scale), y: k * CGFloat(e.scale))
        base.translateBy(x: -pivotX, y: -ground)

        var g = base
        g.translateBy(x: pivotX, y: 0)
        g.scaleBy(x: face, y: 1)
        g.translateBy(x: -pivotX, y: 0)

        func drawLeg(_ l: Leg, near: Bool) {
            guard l.alpha > 0.02 else { return }
            var lg = g
            lg.opacity *= Double(l.alpha)
            let w: CGFloat = 3.8
            let t = CGAffineTransform(translationX: l.hip.x, y: l.hip.y).rotated(by: -l.angle)
            let path = Path(roundedRect: CGRect(x: -w / 2, y: -w / 2, width: w, height: l.length + w),
                            cornerRadius: w / 2).applying(t)
            let top = near ? pal.fur : pal.furDark
            if let pts = near ? pal.points : (pal.pointsDark ?? pal.points) {
                let foot = CGPoint(x: l.hip.x + sin(l.angle) * l.length, y: l.hip.y + cos(l.angle) * l.length)
                lg.fill(path, with: .linearGradient(
                    Gradient(stops: [.init(color: top, location: 0), .init(color: top, location: 0.25),
                                     .init(color: pts, location: 0.7), .init(color: pts, location: 1)]),
                    startPoint: l.hip, endPoint: foot))
            } else {
                lg.fill(path, with: .color(top))
                let pawPath = Path(ellipseIn: CGRect(x: -(w + 0.8) / 2, y: l.length - 1.9, width: w + 0.8, height: 2.8))
                    .applying(t)
                var clip = lg
                clip.clip(to: path)
                clip.fill(pawPath, with: .color(near ? pal.cream : pal.creamDark))
            }
            outlined(lg, path, pal)
        }

        func drawTail() {
            let path = Path { pp in
                pp.move(to: p.tail[0])
                pp.addCurve(to: p.tail[3], control1: p.tail[1], control2: p.tail[2])
            }
            let tw: CGFloat = 3.5 + 0.9 * pal.fluff
            g.stroke(path, with: .color(pal.outline), style: StrokeStyle(lineWidth: tw + 2.3, lineCap: .round))
            if let pts = pal.points {
                g.stroke(path, with: .linearGradient(
                    Gradient(stops: [.init(color: pal.fur, location: 0), .init(color: pts, location: 0.35),
                                     .init(color: pts, location: 1)]),
                    startPoint: p.tail[0], endPoint: p.tail[3]),
                         style: StrokeStyle(lineWidth: tw, lineCap: .round))
            } else {
                g.stroke(path, with: .color(pal.fur), style: StrokeStyle(lineWidth: tw, lineCap: .round))
                g.stroke(path.trimmedPath(from: 0.72, to: 1), with: .color(pal.furDark),
                         style: StrokeStyle(lineWidth: tw, lineCap: .round))
            }
        }

        let tailLate = e.sit > 0.5 || e.loaf > 0.5

        drawLeg(p.legs[0], near: false)
        drawLeg(p.legs[1], near: false)
        if !tailLate { drawTail() }

        // Body with chest patch, shading and (optionally) tabby stripes.
        let bt = CGAffineTransform(translationX: p.bodyC.x, y: p.bodyC.y).rotated(by: p.bodyTilt)
        let bw = p.bodyS.width, bh = p.bodyS.height
        let bodyPath = Path(ellipseIn: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)).applying(bt)
        g.fill(bodyPath, with: .color(pal.fur))
        var bc = g
        bc.clip(to: bodyPath)
        if pal.points != nil {
            var sh = bc
            sh.concatenate(bt)
            sh.fill(Path(ellipseIn: CGRect(x: -bw * 0.9, y: -bh * 0.2, width: bw * 1.1, height: bh * 1.2)),
                    with: .radialGradient(Gradient(colors: [pal.furDark, pal.furDark.opacity(0)]),
                                          center: CGPoint(x: -bw * 0.4, y: bh * 0.4), startRadius: 0, endRadius: bw * 0.55))
        }
        bc.fill(Path(ellipseIn: CGRect(x: bw * 0.12, y: -bh * 0.12, width: bw * 0.44, height: bh * 0.9)).applying(bt),
                with: .color(pal.cream))
        if pal.stripes {
            for i in 0..<3 {
                let sx = -bw * 0.26 + CGFloat(i) * bw * 0.15
                let stripe = Path { sp in
                    sp.move(to: CGPoint(x: sx, y: -bh / 2 - 1))
                    sp.addQuadCurve(to: CGPoint(x: sx - 1.0, y: -bh / 2 + bh * 0.36),
                                    control: CGPoint(x: sx + 0.8, y: -bh * 0.3))
                }.applying(bt)
                bc.stroke(stripe, with: .color(pal.furDark), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }
        }
        outlined(g, bodyPath, pal)

        // Haunch + back paw when sitting.
        if p.haunch > 0.02 {
            var hg = g
            hg.opacity *= Double(p.haunch)
            let hc = CGPoint(x: p.bodyC.x - 3.6, y: p.bodyC.y + 5.2)
            let haunch = Path(ellipseIn: CGRect(x: hc.x - 5.8, y: hc.y - 4.8, width: 11.6, height: 9.6))
            hg.fill(haunch, with: .color(pal.points != nil ? pal.furDark : pal.fur))
            outlined(hg, haunch, pal)
            let pawPath = Path(ellipseIn: CGRect(x: hc.x + 2.2, y: ground - 2.6, width: 5, height: 2.6))
            hg.fill(pawPath, with: .color(pal.points ?? pal.cream))
            outlined(hg, pawPath, pal, width: 1.0)
        }

        if tailLate { drawTail() }

        drawLeg(p.legs[2], near: true)
        let pawInFront = e.stand > 0.5 && e.species == .cat   // the waving paw goes in front of the face
        if !pawInFront { drawLeg(p.legs[3], near: true) }

        // Head
        var h = g
        h.translateBy(x: p.headC.x, y: p.headC.y)
        // On the wall the body is rotated; keep the head (mostly) upright so the cat looks back
        // at you over its shoulder. Inside the mirrored context a rotation flips sign.
        let wall = CGFloat(min(1, abs(e.rotation) / (.pi / 2)))
        let counter = -e.rotation * 0.85 * (face < 0 ? -1 : 1)
        h.rotate(by: .radians(Double(p.headTilt + 0.08 * CGFloat(e.perk)) + counter))
        let headFace = Face(
            eyesClosed: p.eyesClosed,
            perk: CGFloat(e.perk),
            mouthO: CGFloat(e.mouthO),
            happy: CGFloat(e.happy),
            lookX: e.lookX,
            earTwitch: CGFloat(e.earTwitch),
            earBack: CGFloat(e.crouch) * 0.3 + CGFloat(e.loaf) * 0.15,
            frontal: min(1, CGFloat(e.stand) * 0.6 + CGFloat(e.headBob) * 0.3 + wall * 0.75))
        if e.species == .dog {
            drawDogHead(h, r: p.headR, pal: pal, face: headFace, time: e.time,
                        swing: CGFloat(sin(e.walkPhase * 2)) * CGFloat(e.walk) + bobOffset(e))
        } else {
            drawHead(h, r: p.headR, pal: pal, face: headFace)
        }
        if pawInFront { drawLeg(p.legs[3], near: true) }

        // "woof!"
        if e.species == .dog && e.mouthO > 0.5 {
            let hx = pivotX + (p.headC.x + 3 - pivotX) * face
            drawBark(base, at: CGPoint(x: hx, y: p.headC.y - 13), pal: pal, opacity: (e.mouthO - 0.5) * 2)
        }

        // Zzz (drawn un-mirrored so the letters read correctly).
        if e.loaf > 0.3 {
            let sign: CGFloat = face < 0 ? -1 : 1
            let hx = pivotX + (p.headC.x - pivotX) * face
            for i in 0..<3 {
                let ph = (e.time * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let pos = CGPoint(x: hx + (5 + CGFloat(ph) * 7) * sign, y: p.headC.y - 9 - CGFloat(ph) * 10)
                var z = base
                z.opacity *= sin(ph * .pi) * (e.loaf - 0.3) / 0.7
                z.draw(Text("z").font(.system(size: 3.6 + CGFloat(ph) * 3, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: 0xA9BDFF)), at: pos)
            }
        }
        // Music notes while vibing.
        if e.headBob > 0.3 && e.isVisible {
            let hx = pivotX + (p.headC.x - pivotX) * face
            for i in 0..<2 {
                let ph = (e.time * 0.6 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                let side: CGFloat = i == 0 ? -1 : 1
                let pos = CGPoint(x: hx + side * (8 + CGFloat(ph) * 3), y: p.headC.y - 6 - CGFloat(ph) * 9)
                var n = base
                n.opacity *= sin(ph * .pi) * (e.headBob - 0.3) / 0.7
                n.draw(Text(i == 0 ? "♪" : "♫").font(.system(size: 5.5, weight: .bold))
                    .foregroundColor(Color(hex: 0xFFC6A8)), at: pos)
            }
        }
    }

    // MARK: - Peeking over an edge (inside the open island)

    /// Unit box 32 × 26; the ledge is at y = 21. Head peeks above, paws rest on the edge.
    static let peekUnitW: CGFloat = 32
    static let peekUnitH: CGFloat = 26
    static let peekLedge: CGFloat = 21

    static func drawPeek(in ctx: inout GraphicsContext, engine e: CatEngine, palette pal: CatPalette,
                         origin: CGPoint, k: CGFloat, lookX: CGFloat) {
        if e.species == .bird {
            BirdRenderer.drawPeek(in: &ctx, engine: e, palette: pal, origin: origin, k: k, lookX: lookX)
            return
        }
        var g = ctx
        g.translateBy(x: origin.x, y: origin.y)
        g.scaleBy(x: k, y: k)

        let bob = bobOffset(e) * 0.9 + CGFloat(sin(e.time * 1.1)) * 0.25
        let headC = CGPoint(x: 16 + lookX * 0.8, y: 11.6 + bob)

        // The head sits behind the ledge.
        var h = g
        h.clip(to: Path(CGRect(x: -30, y: -40, width: 92, height: 40 + peekLedge + 0.4)))
        h.translateBy(x: headC.x, y: headC.y)
        h.rotate(by: .radians(Double(lookX) * 0.12 + sin(e.time * 0.8) * 0.03 + Double(bob) * 0.06))
        let peekFace = Face(
            eyesClosed: CGFloat(e.blink),
            perk: CGFloat(e.perk),
            mouthO: CGFloat(e.mouthO),
            happy: max(CGFloat(e.happy), CGFloat(e.waveArm) * 0.9),
            lookX: lookX,
            earTwitch: CGFloat(e.earTwitch),
            earBack: 0,
            frontal: 1)
        if e.species == .dog {
            drawDogHead(h, r: 9.6, pal: pal, face: peekFace, time: e.time, swing: bobOffset(e))
        } else {
            drawHead(h, r: 9.6, pal: pal, face: peekFace)
        }

        // Paws over the edge; the right one waves hello when greeting.
        let w = CGFloat(e.waveArm)
        paw(g, center: CGPoint(x: 9.4, y: peekLedge), pal: pal)
        let rest = CGPoint(x: 22.6, y: peekLedge)
        let up = CGPoint(x: 27.2, y: 10.5 + CGFloat(sin(e.time * 11)) * 1.2)
        paw(g, center: mix(rest, up, w), pal: pal,
            angle: w * (-0.35 + CGFloat(sin(e.time * 11)) * 0.25), beans: w > 0.5)
    }
}

// MARK: - SwiftUI layers

/// Positions and redraws the walking cat every frame.
struct CatLayer: View {
    @ObservedObject var engine: CatEngine
    @ObservedObject var settings: AppSettings

    var body: some View {
        let _ = engine.frame
        let k = engine.catH / CatRenderer.unitH
        // Square canvas centred on the feet, big enough for any rotation + Zzz/♪ above the head.
        let side = (CatRenderer.unitW + 26) * k * 2
        let palette = settings.palette
        Canvas(rendersAsynchronously: false) { ctx, size in
            CatRenderer.draw(in: &ctx, engine: engine, palette: palette,
                             anchor: CGPoint(x: size.width / 2, y: size.height / 2), k: k)
        }
        .frame(width: side, height: side)
        .position(engine.anchor)
        .opacity(engine.isVisible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// The cat peeking over a ledge. `ledgeY` is where its paws rest, in this view's coordinates.
struct PeekCatView: View {
    @ObservedObject var engine: CatEngine
    @ObservedObject var settings: AppSettings
    var height: CGFloat
    /// The view's centre x in its panel's coordinates, and the cursor x in the same space,
    /// so the eyes can follow the cursor.
    var centerX: CGFloat
    var mouseX: () -> CGFloat

    var body: some View {
        let _ = engine.frame
        let k = height / CatRenderer.peekLedge * 0.86
        let w = CatRenderer.peekUnitW * k
        let h = CatRenderer.peekUnitH * k
        let look = max(-1, min(1, (mouseX() - centerX) / 160))
        Canvas(rendersAsynchronously: false) { ctx, _ in
            CatRenderer.drawPeek(in: &ctx, engine: engine, palette: settings.palette,
                                 origin: .zero, k: k, lookX: look)
        }
        .frame(width: w, height: h)
        .allowsHitTesting(false)
    }
}
