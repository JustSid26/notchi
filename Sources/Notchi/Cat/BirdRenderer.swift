import SwiftUI

/// A chubby little round bird, drawn in the same 46×34 unit box as the cat (facing right,
/// feet at y = 32.5) so it shares the cat's brain, anchor and transforms.
///
/// How the shared pose parameters read on a bird:
/// walk → hopping · air → wings flapping · sit/loaf → fluffed into a ball · bow → pecking
/// stand → waving a wing · headBob → bobbing to music · mouthO → beak open (chirp!)
enum BirdRenderer {
    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func draw(in ctx: inout GraphicsContext, engine e: CatEngine, palette pal: CatPalette,
                     anchor: CGPoint, k: CGFloat) {
        let pivotX = CatRenderer.pivotX, ground = CatRenderer.ground
        var face = e.faceScale
        if abs(face) < 0.06 { face = face < 0 ? -0.06 : 0.06 }

        let walk = CGFloat(e.walk)
        let hop = CGFloat(abs(sin(e.walkPhase))) * 3.4 * walk
        let fluff = CGFloat(max(e.sit, e.loaf))
        let flap = CGFloat(e.air)
        let peck = CGFloat(e.bow) * CGFloat(max(0, sin(e.time * 9)))
        let crouch = CGFloat(e.crouch)
        let bob = CatRenderer.bobOffset(e)
        let waveAmt = CGFloat(e.stand)
        let closed = max(CGFloat(e.blink), e.loaf > 0.5 ? 1 : 0)

        // Shadow on the floor.
        do {
            var sc = ctx
            sc.opacity = e.alpha
            sc.translateBy(x: anchor.x, y: anchor.y + e.lift)
            sc.scaleBy(x: k, y: k)
            let sh = max(0.2, 1 - (e.lift / k + hop) / 30)
            sc.fill(Path(ellipseIn: CGRect(x: -9 * sh, y: -1.0, width: 18 * sh, height: 2.2)),
                    with: .color(.black.opacity(0.2 * sh)))
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

        let bodyY: CGFloat = 21 + 3.2 * fluff + 1.6 * crouch - hop - flap * 1.5
        let bodyC = CGPoint(x: 21.5, y: bodyY)
        let bodyS = CGSize(width: 20 + 4 * fluff, height: 18.5 - 1.5 * fluff)
        let headR: CGFloat = 8
        let headC = CGPoint(x: 26.5 + peck * 4.5 + bob * 0.3,
                            y: bodyY - 8.8 + peck * 9 + 2.2 * fluff + bob * 0.9)

        func outline(_ c: GraphicsContext, _ p: Path, _ w: CGFloat = 1.15) {
            c.stroke(p, with: .color(pal.outline), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
        let footColor = pal.nose ?? Color(hex: 0xF4B860)

        // Legs (hidden when fluffed down, tucked up while flying).
        let legAlpha = max(0, 1 - fluff * 1.6)
        if legAlpha > 0.02 {
            var lg = g
            lg.opacity *= Double(legAlpha)
            for lx in [CGFloat(19.5), 23.5] {
                let top = CGPoint(x: lx, y: bodyY + bodyS.height * 0.36)
                let foot = CGPoint(x: lx + 0.4, y: mix(ground, top.y + 3, flap))
                let leg = Path { p in p.move(to: top); p.addLine(to: foot) }
                let toes = Path { p in
                    p.move(to: foot); p.addLine(to: CGPoint(x: foot.x + 2.4, y: foot.y))
                    p.move(to: foot); p.addLine(to: CGPoint(x: foot.x + 1.5, y: foot.y + 0.6))
                    p.move(to: foot); p.addLine(to: CGPoint(x: foot.x - 1.4, y: foot.y))
                }
                lg.stroke(leg, with: .color(pal.outline), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                lg.stroke(leg, with: .color(footColor), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                lg.stroke(toes, with: .color(pal.outline), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                lg.stroke(toes, with: .color(footColor), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
            }
        }

        // Tail feathers.
        let tailBase = CGPoint(x: bodyC.x - bodyS.width * 0.36, y: bodyY + 2.2)
        let flick = CGFloat(sin(e.time * 3)) * 0.06 + CGFloat(e.happy) * CGFloat(sin(e.time * 12)) * 0.1
        for a in [CGFloat(0.42), 0.78] {
            let t = CGAffineTransform(translationX: tailBase.x, y: tailBase.y).rotated(by: .pi - a - flick)
            let feather = Path(roundedRect: CGRect(x: 0, y: -1.7, width: 9, height: 3.4), cornerRadius: 1.7).applying(t)
            g.fill(feather, with: .color(pal.furDark))
            outline(g, feather)
        }

        // Wing shape: a soft teardrop pointing back (−x) from the shoulder.
        let wingShape = Path { p in
            p.move(to: CGPoint(x: 1.5, y: -3.4))
            p.addCurve(to: CGPoint(x: -12, y: 0.8), control1: CGPoint(x: -4, y: -4.8), control2: CGPoint(x: -10, y: -2.6))
            p.addCurve(to: CGPoint(x: 1.5, y: 3.6), control1: CGPoint(x: -9, y: 4.2), control2: CGPoint(x: -3, y: 4.6))
            p.addQuadCurve(to: CGPoint(x: 1.5, y: -3.4), control: CGPoint(x: 3.6, y: 0))
        }
        let shoulder = CGPoint(x: bodyC.x + 1.5, y: bodyY - 3.2)
        let beat = CGFloat(abs(sin(e.time * 26)))
        var wingAngle: CGFloat = -0.35                                   // resting, tip down-back
        wingAngle = mix(wingAngle, 0.25 + 0.95 * beat, flap)              // flapping (up-back, never over the face)
        wingAngle = mix(wingAngle, 1.1 + CGFloat(sin(e.time * 11)) * 0.3, waveAmt)    // waving hello

        // Far wing peeks out above the body while flapping.
        if flap > 0.05 {
            var fw = g
            fw.opacity *= Double(flap)
            let t = CGAffineTransform(translationX: shoulder.x - 2.5, y: shoulder.y - 1)
                .rotated(by: 0.7 + 1.2 * beat)
            let far = wingShape.applying(t)
            fw.fill(far, with: .color(pal.furDark.opacity(0.85)))
            outline(fw, far)
        }

        // Body + head as one round blob.
        let bodyPath = Path(ellipseIn: CGRect(x: bodyC.x - bodyS.width / 2, y: bodyC.y - bodyS.height / 2,
                                              width: bodyS.width, height: bodyS.height))
        let headPath = Path(ellipseIn: CGRect(x: headC.x - headR, y: headC.y - headR * 0.95,
                                              width: 2 * headR, height: 1.9 * headR))
        let blob = bodyPath.union(headPath)
        g.fill(blob, with: .color(pal.fur))
        var bc = g
        bc.clip(to: blob)
        bc.fill(Path(ellipseIn: CGRect(x: bodyC.x + 3.5 - 7, y: bodyY + 4 - 6, width: 14, height: 12)),
                with: .color(pal.cream))
        bc.fill(Path(ellipseIn: CGRect(x: headC.x + 2.4 - 5.2, y: headC.y + 1.6 - 4.6, width: 10.4, height: 9.2)),
                with: .color(pal.cream))
        outline(g, blob)

        // Crest (cockatiel).
        if pal.crest {
            let sway = CGFloat(sin(e.time * 2.4)) * 0.6 + CGFloat(e.perk) * 1.2
            for (i, dx) in [CGFloat(-2.2), -0.4, 1.4].enumerated() {
                let root = CGPoint(x: headC.x + dx, y: headC.y - headR * 0.8)
                let tip = CGPoint(x: root.x - 3.5 - CGFloat(i) * 1.2 + sway, y: root.y - 6 + CGFloat(i) * 0.8)
                let f = Path { p in p.move(to: root); p.addQuadCurve(to: tip, control: CGPoint(x: root.x + 0.5, y: tip.y + 1)) }
                g.stroke(f, with: .color(pal.outline), style: StrokeStyle(lineWidth: 3.0, lineCap: .round))
                g.stroke(f, with: .color(pal.points ?? pal.cream), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }

        // Near wing.
        let wing = wingShape.applying(CGAffineTransform(translationX: shoulder.x, y: shoulder.y).rotated(by: wingAngle))
        g.fill(wing, with: .color(pal.furDark))
        var wc = g
        wc.clip(to: wing)
        for dy in [CGFloat(-0.6), 1.4] {
            let line = Path { p in p.move(to: CGPoint(x: -2, y: dy)); p.addLine(to: CGPoint(x: -8.5, y: dy + 1.2)) }
                .applying(CGAffineTransform(translationX: shoulder.x, y: shoulder.y).rotated(by: wingAngle))
            wc.stroke(line, with: .color(pal.outline.opacity(0.35)), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
        }
        outline(g, wing)

        // Cheek patch, eye, beak.
        let bs = 1 + 0.35 * CGFloat(e.happy)
        g.fill(Path(ellipseIn: CGRect(x: headC.x + 3.4 - 1.9 * bs, y: headC.y + 3.0 - 1.6 * bs,
                                      width: 3.8 * bs, height: 3.2 * bs)),
               with: .color(pal.blush.opacity(0.85)))
        let eye = CGPoint(x: headC.x + 2.6 + e.lookX * 0.3, y: headC.y - 0.8)
        drawEye(g, at: eye, closed: closed, happy: CGFloat(e.happy), perk: CGFloat(e.perk), pal: pal)

        let bb = CGPoint(x: headC.x + headR * 0.86, y: headC.y + 0.9)
        let o = CGFloat(e.mouthO)
        let upper = Path { p in
            p.move(to: CGPoint(x: bb.x - 0.5, y: bb.y - 2.0 - o * 0.6))
            p.addQuadCurve(to: CGPoint(x: bb.x + 3.8, y: bb.y + 0.5 - o * 0.9), control: CGPoint(x: bb.x + 2.6, y: bb.y - 1.8))
            p.addLine(to: CGPoint(x: bb.x - 0.5, y: bb.y + 0.3 - o * 0.5))
            p.closeSubpath()
        }
        let lower = Path { p in
            p.move(to: CGPoint(x: bb.x - 0.5, y: bb.y + 0.3 + o * 0.4))
            p.addLine(to: CGPoint(x: bb.x + 2.6, y: bb.y + 0.8 + o * 0.9))
            p.addQuadCurve(to: CGPoint(x: bb.x - 0.5, y: bb.y + 2.2 + o * 0.5), control: CGPoint(x: bb.x + 1.4, y: bb.y + 2.2 + o))
            p.closeSubpath()
        }
        for beak in [lower, upper] {
            g.fill(beak, with: .color(pal.nose ?? Color(hex: 0xF4B860)))
            outline(g, beak, 0.8)
        }

        // Zzz / music notes / chirp.
        let hx = pivotX + (headC.x - pivotX) * face
        let sign: CGFloat = face < 0 ? -1 : 1
        if e.loaf > 0.3 {
            for i in 0..<3 {
                let ph = (e.time * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                var z = base
                z.opacity *= sin(ph * .pi) * (e.loaf - 0.3) / 0.7
                z.draw(Text("z").font(.system(size: 3.4 + CGFloat(ph) * 3, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(hex: 0xA9BDFF)),
                       at: CGPoint(x: hx + (4 + CGFloat(ph) * 6) * sign, y: headC.y - 8 - CGFloat(ph) * 9))
            }
        }
        if e.headBob > 0.3 || (o > 0.5 && e.loaf < 0.3) {
            let amount = max(e.headBob, Double(o)) - 0.3
            for i in 0..<2 {
                let ph = (e.time * 0.7 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                var n = base
                n.opacity *= sin(ph * .pi) * amount / 0.7
                n.draw(Text(i == 0 ? "♪" : "♫").font(.system(size: 5, weight: .bold))
                    .foregroundColor(pal.fur),
                       at: CGPoint(x: hx + sign * (9 + CGFloat(ph) * 3) - CGFloat(i) * 4 * sign,
                                   y: headC.y - 5 - CGFloat(ph) * 9))
            }
        }
    }

    static func drawEye(_ g: GraphicsContext, at c: CGPoint, closed: CGFloat, happy: CGFloat, perk: CGFloat, pal: CatPalette) {
        let es = 1 + 0.15 * perk
        if closed > 0.55 {
            let up = happy > 0.5
            let arc = Path { p in
                p.move(to: CGPoint(x: c.x - 1.2, y: c.y + (up ? 0.5 : -0.2)))
                p.addQuadCurve(to: CGPoint(x: c.x + 1.2, y: c.y + (up ? 0.5 : -0.2)),
                               control: CGPoint(x: c.x, y: c.y + (up ? -1.0 : 1.2)))
            }
            g.stroke(arc, with: .color(pal.eye), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        } else {
            let eh = 2.6 * es * (1 - closed)
            g.fill(Path(ellipseIn: CGRect(x: c.x - 1.05 * es, y: c.y - eh / 2, width: 2.1 * es, height: eh)),
                   with: .color(pal.eye))
            if eh > 1.2 {
                g.fill(Path(ellipseIn: CGRect(x: c.x + 0.35 - 0.55, y: c.y - eh * 0.25 - 0.55, width: 1.1, height: 1.1)),
                       with: .color(.white))
            }
        }
    }

    // MARK: - Peeking over the edge inside the island

    static func drawPeek(in ctx: inout GraphicsContext, engine e: CatEngine, palette pal: CatPalette,
                         origin: CGPoint, k: CGFloat, lookX: CGFloat) {
        let ledge = CatRenderer.peekLedge
        var g = ctx
        g.translateBy(x: origin.x, y: origin.y)
        g.scaleBy(x: k, y: k)
        func outline(_ c: GraphicsContext, _ p: Path, _ w: CGFloat = 1.15) {
            c.stroke(p, with: .color(pal.outline), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }

        let bob = CatRenderer.bobOffset(e) * 0.9 + CGFloat(sin(e.time * 1.4)) * 0.3
        let headC = CGPoint(x: 16 + lookX * 0.8, y: 12.6 + bob)
        let r: CGFloat = 9.4

        var h = g
        h.clip(to: Path(CGRect(x: -30, y: -40, width: 92, height: 40 + ledge + 0.4)))
        h.translateBy(x: headC.x, y: headC.y)
        h.rotate(by: .radians(Double(lookX) * 0.14 + sin(e.time * 0.9) * 0.05))

        if pal.crest {
            let sway = CGFloat(sin(e.time * 2.4)) * 0.6 + CGFloat(e.perk) * 1.2
            for (i, dx) in [CGFloat(-1.6), 0, 1.6].enumerated() {
                let root = CGPoint(x: dx, y: -r * 0.8)
                let tip = CGPoint(x: dx * 1.6 - 1.5 + sway, y: -r - 5.5 + CGFloat(abs(i - 1)) * 1.2)
                let f = Path { p in p.move(to: root); p.addQuadCurve(to: tip, control: CGPoint(x: root.x + 0.6, y: tip.y + 1.2)) }
                h.stroke(f, with: .color(pal.outline), style: StrokeStyle(lineWidth: 3.0, lineCap: .round))
                h.stroke(f, with: .color(pal.points ?? pal.cream), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
        let head = Path(ellipseIn: CGRect(x: -r, y: -r * 0.95, width: 2 * r, height: 1.95 * r))
        h.fill(head, with: .color(pal.fur))
        var hc = h
        hc.clip(to: head)
        hc.fill(Path(ellipseIn: CGRect(x: -6.4, y: 2.2 - 5.4, width: 12.8, height: 11)), with: .color(pal.cream))
        outline(h, head)

        let happy = max(CGFloat(e.happy), CGFloat(e.waveArm) * 0.9)
        let bs = 1 + 0.35 * happy
        for x in [CGFloat(-5.4), 5.4] {
            h.fill(Path(ellipseIn: CGRect(x: x - 1.9 * bs, y: 2.6 - 1.6 * bs, width: 3.8 * bs, height: 3.2 * bs)),
                   with: .color(pal.blush.opacity(0.85)))
        }
        for x in [CGFloat(-3.2), 3.2] {
            drawEye(h, at: CGPoint(x: x + lookX * 0.4, y: -0.6), closed: CGFloat(e.blink), happy: happy,
                    perk: CGFloat(e.perk), pal: pal)
        }
        // Beak, seen from the front.
        let o = CGFloat(e.mouthO)
        let upper = Path { p in
            p.move(to: CGPoint(x: -1.7, y: 1.4)); p.addLine(to: CGPoint(x: 1.7, y: 1.4))
            p.addQuadCurve(to: CGPoint(x: 0, y: 4.4 - o), control: CGPoint(x: 1.2, y: 3.6 - o))
            p.addQuadCurve(to: CGPoint(x: -1.7, y: 1.4), control: CGPoint(x: -1.2, y: 3.6 - o))
        }
        if o > 0.2 {
            let lower = Path(ellipseIn: CGRect(x: -1.1, y: 4.1, width: 2.2, height: 1.4 * o))
            h.fill(lower, with: .color(pal.nose ?? Color(hex: 0xF4B860)))
            outline(h, lower, 0.7)
        }
        h.fill(upper, with: .color(pal.nose ?? Color(hex: 0xF4B860)))
        outline(h, upper, 0.8)

        // Little feet gripping the edge.
        let footColor = pal.nose ?? Color(hex: 0xF4B860)
        for fx in [CGFloat(12.6), 19.4] {
            let toes = Path { p in
                for dx in [CGFloat(-1.3), 0, 1.3] {
                    p.move(to: CGPoint(x: fx + dx, y: ledge - 0.4))
                    p.addQuadCurve(to: CGPoint(x: fx + dx * 1.2, y: ledge + 2.0), control: CGPoint(x: fx + dx * 1.3, y: ledge + 0.4))
                }
            }
            g.stroke(toes, with: .color(pal.outline), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))
            g.stroke(toes, with: .color(footColor), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))
        }

        // Wings resting on the ledge; the right one waves hello.
        let w = CGFloat(e.waveArm)
        func wingTip(_ c: CGPoint, _ angle: CGFloat) {
            let p = Path(ellipseIn: CGRect(x: -3.6, y: -2.2, width: 7.2, height: 4.4))
                .applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle))
            g.fill(p, with: .color(pal.furDark))
            outline(g, p)
        }
        wingTip(CGPoint(x: 7.4, y: ledge - 1.2), 0.35)
        let rest = CGPoint(x: 24.6, y: ledge - 1.2)
        let up = CGPoint(x: 27.4, y: 10.5 + CGFloat(sin(e.time * 11)) * 1.4)
        wingTip(CGPoint(x: mix(rest.x, up.x, w), y: mix(rest.y, up.y, w)),
                mix(-0.35, -1.2 + CGFloat(sin(e.time * 11)) * 0.3, w))
    }
}
