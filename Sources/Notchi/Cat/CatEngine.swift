import SwiftUI

/// The cat's brain + body physics. Ticked at 60 fps by the IslandController.
///
/// Two worlds:
/// - `.menuBar`: walks along the bottom of the menu bar beside the notch.
/// - `.leftEdge`: lives in the bottom-left corner, climbs the left screen edge, slips, falls.
///
/// Every pose is a continuous blend, and the whole body can rotate (for wall-climbing),
/// so transitions never pop.
final class CatEngine: ObservableObject {
    enum Mode: Equatable {
        case walk, stand, sit, sleep, stretch, wave, vibe
        case hop, inside, popOut
        case mount, climb, hang, fall
        case spin      // dog: chasing its own tail
        case flight    // bird: a short flight to a new spot
    }

    /// Which pet is wearing this brain. Changes how it moves, not what it wants.
    var species: Pet = .cat
    enum World { case menuBar, leftEdge }

    /// Bumped whenever the cat needs a redraw.
    @Published private(set) var frame: Int = 0

    // MARK: Layout (cat-panel points, y grows downward)
    private(set) var world: World = .menuBar
    private(set) var centerX: CGFloat = 340
    private(set) var notchHalf: CGFloat = 95
    private(set) var minX: CGFloat = 100
    private(set) var maxX: CGFloat = 580
    private(set) var groundY: CGFloat = 32
    private(set) var catH: CGFloat = 26
    /// Left-edge world: where the island handle sits (the cat leaps into it).
    private(set) var handle: CGPoint = .zero
    private let wallX: CGFloat = 1
    var catW: CGFloat { catH * CatRenderer.unitW / CatRenderer.unitH }
    /// Menu-bar world: horizontal band covered by the (closed) island — the cat is hidden there.
    var hiddenBand: ClosedRange<CGFloat> = -10_000 ... -9_999
    var enabled = true
    var musicPlaying = false
    private var configured = false

    // MARK: Pose state (read by the renderers)
    private(set) var mode: Mode = .walk
    /// Anchor = the point between the cat's feet.
    private(set) var x: CGFloat = 200
    private(set) var y: CGFloat = 32
    /// Whole-body rotation (π/2 = clinging to the left wall, head up).
    private(set) var rotation: Double = 0
    private(set) var facing: CGFloat = 1
    private(set) var faceScale: CGFloat = 1
    private(set) var walkPhase: Double = 0
    private(set) var walk: Double = 0
    private(set) var sit: Double = 0
    private(set) var loaf: Double = 0
    private(set) var bow: Double = 0
    private(set) var stand: Double = 0
    private(set) var crouch: Double = 0
    private(set) var air: Double = 0
    private(set) var swat: Double = 0
    private(set) var blink: Double = 0
    private(set) var perk: Double = 0
    private(set) var mouthO: Double = 0
    private(set) var happy: Double = 0
    private(set) var headBob: Double = 0
    private(set) var waveArm: Double = 0
    private(set) var lookX: CGFloat = 0
    private(set) var earTwitch: Double = 0
    private(set) var time: Double = 0
    private(set) var alpha: Double = 1
    private(set) var scale: Double = 1
    private(set) var mouse: CGPoint = .zero

    var anchor: CGPoint { CGPoint(x: x, y: y) }
    /// Height above the floor (for the shadow).
    var lift: CGFloat { max(0, groundY - y) }

    // MARK: Brain
    private var speed: CGFloat = 0
    private var targetX: CGFloat = 200
    private var trot = false
    private var goingToClimb = false
    private var modeTime: Double = 0
    private var modeDuration: Double = 2
    private var sitTarget = 0.0, loafTarget = 0.0, bowTarget = 0.0, standTarget = 0.0, crouchTarget = 0.0
    private var perkTarget = 0.0, swatTarget = 0.0, mouthOTarget = 0.0, happyTarget = 0.0, bobTarget = 0.0
    private var lookTarget: CGFloat = 0
    private var nextBlink = 2.5, blinkClock = -1.0
    private var nextTwitch = 4.0, twitchClock = -1.0
    private var hopFrom: CGPoint = .zero, hopTo: CGPoint = .zero, hopT = 0.0, hopDur = 0.42
    private var hopFromRotation = 0.0, hopCrouch = 0.16
    private var hopDone: (() -> Void)?
    private var mountFrom: CGPoint = .zero, mountT = 0.0
    private var climbTarget: CGFloat = 0, slipT = 0.0
    private var vx: CGFloat = 0, vy: CGFloat = 0
    private var flightFrom: CGPoint = .zero, flightToX: CGFloat = 0, flightT = 0.0, flightDur = 0.8
    private var spinFlip = 0.0
    private var wasNear = false
    private var greetUntil = 0.0
    private var surpriseUntil = 0.0
    private var sinceDraw = 0.0

    private static let floorModes: Set<Mode> = [.walk, .stand, .sit, .sleep, .stretch, .wave, .vibe, .popOut, .spin]

    var isVisible: Bool { enabled && mode != .inside }
    var isInside: Bool { mode == .inside }
    var isHoverable: Bool {
        guard isVisible, ![.hop, .popOut, .mount, .fall, .flight].contains(mode) else { return false }
        return world == .leftEdge || !bandContains(x, margin: -catW * 0.2)
    }
    var hitRect: CGRect {
        if rotation > 0.8 {   // on the wall: body sticks out to the right of the anchor
            return CGRect(x: x, y: y - catW * 0.55, width: catH * 0.95, height: catW * 0.95)
        }
        return CGRect(x: x - catW * 0.45, y: y - catH, width: catW * 0.9, height: catH)
    }

    // MARK: - Worlds

    func configureMenuBar(centerX: CGFloat, notchHalf: CGFloat, range: CGFloat, groundY: CGFloat, catHeight: CGFloat) {
        let switched = world != .menuBar
        world = .menuBar
        self.centerX = centerX
        self.notchHalf = notchHalf
        self.groundY = groundY
        catH = catHeight
        minX = centerX - notchHalf - range
        maxX = centerX + notchHalf + range
        if !configured || switched || x < minX || x > maxX {
            configured = true
            x = centerX - notchHalf - range * 0.55
            targetX = x
            y = groundY
            rotation = 0; vx = 0; vy = 0; air = 0; alpha = 1; scale = 1
            facing = 1; faceScale = 1
            setMode(.wave, duration: 2.2)   // say hi
            stand = 1
        } else if Self.floorModes.contains(mode) {
            y = groundY
        }
    }

    func configureLeftEdge(width: CGFloat, floorY: CGFloat, handle: CGPoint, catHeight: CGFloat) {
        let switched = world != .leftEdge
        world = .leftEdge
        groundY = floorY
        catH = catHeight
        self.handle = handle
        minX = wallX + catW * 0.55
        maxX = width - catW * 0.6
        hiddenBand = -10_000 ... -9_999
        if !configured || switched {
            // Arrive by tumbling out of the island handle.
            configured = true
            dropFromHandle()
        } else if Self.floorModes.contains(mode) {
            y = groundY
            x = min(max(x, minX), maxX)
        }
    }

    // MARK: - Tick

    func update(dt: Double, mouse m: CGPoint) {
        guard enabled else { return }
        time += dt
        modeTime += dt
        mouse = m
        updateBlink(dt)
        updateTwitch(dt)

        // Curiosity: notice the cursor, look at it, sometimes wave or swat.
        let onFloor = Self.floorModes.contains(mode) && mode != .popOut
        let near = abs(m.x - x) < 90 && m.y > y - catH - 30 && m.y < y + 50
        swatTarget = 0
        if near && onFloor && mode != .sleep && mode != .stretch && mode != .spin {
            if !wasNear {
                wasNear = true
                if mode != .wave && Double.random(in: 0..<1) < 0.4 {
                    setMode(.wave, duration: 1.8)
                } else if mode == .walk || mode == .vibe {
                    goingToClimb = false
                    setMode(.stand, duration: 2)
                }
            }
            facing = m.x >= x ? 1 : -1
            perkTarget = 1
            if mode != .wave { modeTime = min(modeTime, max(0, modeDuration - 1.2)) }
            let ahead = (m.x - x) * facing
            if mode == .stand && ahead > catW * 0.35 && ahead < catW * 1.3 && m.y > y - catH * 0.8 && m.y < y + 26 {
                swatTarget = 1
            }
        } else {
            wasNear = false
            if ![.hop, .hang, .fall].contains(mode) { perkTarget = 0 }
        }
        lookTarget = near && onFloor ? max(-1, min(1, (m.x - x) / 110)) * (faceScale < 0 ? -1 : 1) : 0
        if mode == .sleep && near && abs(m.x - x) < 45 {
            setMode(.sit, duration: 2.5)
            twitchClock = 0
        }

        // Menu bar: don't idle where the island hides us.
        if world == .menuBar && [.sit, .stand, .sleep, .stretch, .wave, .vibe].contains(mode)
            && bandContains(x, margin: catW * 0.3) {
            pickWalk()
        }

        happyTarget = 0
        bobTarget = 0
        standTarget = 0
        mouthOTarget = time < surpriseUntil ? 1 : 0

        switch mode {
        case .walk, .popOut:
            y = groundY
            sitTarget = 0; loafTarget = 0; bowTarget = 0; crouchTarget = 0
            let dx = targetX - x
            let dir: CGFloat = dx >= 0 ? 1 : -1
            facing = dir
            let k = catH / 26
            let (walkSpeed, trotSpeed): (CGFloat, CGFloat) = switch species {
            case .cat: (25, 48)
            case .dog: (30, 56)
            case .bird: (16, 26)   // little hops
            }
            let top: CGFloat = (trot || mode == .popOut ? trotSpeed : walkSpeed) * k
            let desired = abs(dx) < 14 * k ? max(5 * k, abs(dx) * 2.4) : top
            speed += (desired - speed) * CGFloat(1 - exp(-dt * 5))
            // Finish turning around and standing up before moving.
            let ready = max(0, faceScale * dir) * CGFloat(1 - sit) * CGFloat(1 - loaf) * CGFloat(1 - stand)
            let step = min(speed * CGFloat(dt) * ready, abs(dx))
            x += dir * step
            walkPhase += Double(step) / Double(catH * 0.62) * .pi * 2
            walk += (1 - walk) * (1 - exp(-dt * 8))
            if abs(targetX - x) < 0.5 {
                if mode == .popOut { setMode(.sit, duration: .random(in: 2.5...4)) }
                else if goingToClimb { goingToClimb = false; startMount() }
                else { decide(from: .walk) }
            }
        case .stand:
            y = groundY
            sitTarget = 0; loafTarget = 0; bowTarget = 0
            if modeTime > modeDuration { decide(from: .stand) }
        case .sit:
            y = groundY
            sitTarget = 1; loafTarget = 0; bowTarget = 0
            if modeTime > modeDuration { decide(from: .sit) }
        case .sleep:
            y = groundY
            sitTarget = 1; loafTarget = 1
            if modeTime > modeDuration { setMode(.sit, duration: 2) }
        case .stretch:
            y = groundY
            sitTarget = 0
            bowTarget = modeTime < modeDuration * 0.7 ? 1 : 0
            happyTarget = 0.6
            if modeTime > modeDuration { pickWalk() }
        case .wave:
            sitTarget = 0; loafTarget = 0; bowTarget = 0
            standTarget = modeTime < modeDuration - 0.35 ? 1 : 0
            happyTarget = 1
            if species == .dog && world == .leftEdge && x < minX + 2 {
                // Jumping up at the wall, paws scrabbling, woofing.
                y = groundY - CGFloat(abs(sin(time * 9))) * catH * 0.18
                facing = -1
                mouthOTarget = sin(time * 7) > 0.55 ? 1 : 0
            } else {
                y = groundY
            }
            if modeTime > modeDuration { y = groundY; setMode(.stand, duration: 1.2) }
        case .spin:
            // Chasing its tail: whirl round and round in a tiny circle.
            y = groundY
            sitTarget = 0; loafTarget = 0
            happyTarget = 1
            spinFlip += dt
            if spinFlip > 0.2 { spinFlip = 0; facing = -facing }
            walk += (1 - walk) * (1 - exp(-dt * 8))
            walkPhase += dt * 16
            x = min(max(x + facing * catH * 0.4 * CGFloat(dt), minX), maxX)
            if modeTime > modeDuration { setMode(.sit, duration: .random(in: 2...4)) }
        case .flight:
            updateFlight(dt)
        case .vibe:
            y = groundY
            sitTarget = 1; loafTarget = 0
            bobTarget = 1
            happyTarget = 0.8
            if modeTime > modeDuration || !musicPlaying { decide(from: .sit) }
        case .hop:
            updateHop(dt)
        case .inside:
            happyTarget = musicPlaying ? 0.6 : 0
            bobTarget = musicPlaying ? 1 : 0
        case .mount:
            updateMount(dt)
        case .climb:
            updateClimb(dt)
        case .hang:
            sitTarget = 0; loafTarget = 0; bowTarget = 0
            perkTarget = 1
            walk *= exp(-dt * 10)
            // Wiggle the legs a bit while hanging on.
            walkPhase += dt * 3
            if species == .bird {
                // Hover in place, wings beating.
                air = 1
                y += CGFloat(sin(time * 5)) * 0.3
                happyTarget = 0.8
                if modeTime > modeDuration { startFall(vx: .random(in: 30...80)) }
                break
            }
            if modeTime > modeDuration - 0.4 { mouthOTarget = 1 }   // "uh-oh"
            if modeTime > modeDuration { startFall(vx: .random(in: 50...110)) }
        case .fall:
            updateFall(dt)
        }

        if ![.walk, .popOut, .mount, .climb, .hang, .spin].contains(mode) {
            walk *= exp(-dt * 7)
            speed = 0
        }
        if ![.hop, .fall, .climb, .mount, .hang, .flight].contains(mode) {
            air *= exp(-dt * 10)
        }

        func ease(_ v: inout Double, _ target: Double, _ rate: Double) { v += (target - v) * (1 - exp(-dt * rate)) }
        ease(&sit, sitTarget, 7)
        ease(&loaf, loafTarget, 3)
        ease(&bow, bowTarget, 5)
        ease(&stand, standTarget, 7)
        ease(&crouch, crouchTarget, 12)
        ease(&perk, perkTarget, 6)
        ease(&swat, swatTarget, 12)
        ease(&mouthO, mouthOTarget, 16)
        ease(&happy, happyTarget, 6)
        ease(&headBob, bobTarget, 4)
        ease(&waveArm, time < greetUntil ? 1 : 0, 9)
        lookX += (lookTarget - lookX) * CGFloat(1 - exp(-dt * 8))
        faceScale += (facing - faceScale) * CGFloat(1 - exp(-dt * 14))

        // Redraw only as often as the motion needs — keeps an always-on pet cheap.
        let fps: Double
        switch mode {
        case .walk, .popOut, .hop, .wave, .stretch, .mount, .climb, .hang, .fall, .spin, .flight: fps = 60
        case .sleep: fps = loaf > 0.95 && perk < 0.05 ? 15 : 30
        case .inside: fps = 30
        default: fps = (swat > 0.05 || abs(faceScale - facing) > 0.02 || blink > 0 || crouch > 0.05) ? 60 : 30
        }
        sinceDraw += dt
        if sinceDraw >= 1 / fps - 0.001 {
            sinceDraw = 0
            frame &+= 1
        }
    }

    // MARK: - Decisions

    private func decide(from: Mode) {
        let r = Double.random(in: 0..<1)
        let wall = world == .leftEdge
        // Species quirks first.
        let q = Double.random(in: 0..<1)
        if species == .dog && from != .sit && q < 0.12 { setMode(.spin, duration: .random(in: 1.4...2.4)); return }
        if species == .bird && from != .sit && q < 0.28 { flyToNewSpot(); return }

        switch from {
        case .walk:
            if wall && r < 0.32 { goClimb() }
            else if musicPlaying && r < 0.45 { setMode(.vibe, duration: .random(in: 5...9)) }
            else if r < 0.6 { setMode(.sit, duration: .random(in: 3...7)) }
            else if r < 0.72 { setMode(.stand, duration: .random(in: 1.2...2.8)) }
            else if r < 0.8 { setMode(.stretch, duration: 1.9) }
            else { pickWalk() }
        case .sit:
            if wall && r < 0.3 { goClimb() }
            else if musicPlaying && r < 0.6 { setMode(.vibe, duration: .random(in: 5...9)) }
            else if !musicPlaying && r < 0.55 { setMode(.sleep, duration: .random(in: 9...18)) }
            else { pickWalk() }
        case .stand:
            if wall && r < 0.25 { goClimb() }
            else if r < 0.45 { setMode(.sit, duration: .random(in: 3...6)) }
            else { pickWalk() }
        default:
            pickWalk()
        }
    }

    private func pickWalk() {
        var t = x
        for _ in 0..<16 {
            let c = CGFloat.random(in: minX...max(minX + 1, maxX))
            if abs(c - x) > 30 && !(world == .menuBar && bandContains(c, margin: catW * 0.7)) { t = c; break }
        }
        targetX = t
        trot = Double.random(in: 0..<1) < 0.2
        goingToClimb = false
        setMode(.walk)
    }

    private func goClimb() {
        targetX = minX
        trot = Double.random(in: 0..<1) < 0.4
        goingToClimb = true
        if abs(x - minX) < 1 { goingToClimb = false; startMount() } else { setMode(.walk) }
    }

    private func setMode(_ m: Mode, duration: Double = 0) {
        mode = m
        modeTime = 0
        modeDuration = duration
    }

    private func bandContains(_ v: CGFloat, margin: CGFloat) -> Bool {
        v > hiddenBand.lowerBound - margin && v < hiddenBand.upperBound + margin
    }

    // MARK: - Climbing the left edge

    private func startMount() {
        mountFrom = anchor
        mountT = 0
        facing = -1
        sitTarget = 0; loafTarget = 0; bowTarget = 0
        if species == .dog {
            // Dogs can't climb — jump up at the wall instead, then give up.
            setMode(.wave, duration: .random(in: 1.6...2.6))
            return
        }
        setMode(.mount)
    }

    /// Birds hover just off the wall instead of clinging to it.
    private var birdWallX: CGFloat { wallX + catW * 0.55 }

    private func updateMount(_ dt: Double) {
        mountT = min(1, mountT + dt / 0.42)
        let e = mountT * mountT * (3 - 2 * mountT)
        if species == .bird {
            rotation = 0
            air = 1
            x = mountFrom.x + (birdWallX - mountFrom.x) * CGFloat(e)
            y = groundY - catH * 0.5 * CGFloat(e)
        } else {
            rotation = e * .pi / 2
            x = mountFrom.x + (wallX - mountFrom.x) * CGFloat(e)
            y = groundY - catH * 0.62 * CGFloat(e)
        }
        walkPhase += dt * 9
        walk += (1 - walk) * (1 - exp(-dt * 8))
        if mountT >= 1 {
            let start = y
            let top = handle.y + catW * 0.9
            let span = max(0, start - top)
            climbTarget = start - span * CGFloat.random(in: 0.25...1.0)
            slipT = 0
            setMode(.climb)
        }
    }

    private func updateClimb(_ dt: Double) {
        if species == .bird {
            // Flap up the wall, bobbing a little.
            rotation = 0
            air = 1
            facing = 1
            x = birdWallX + CGFloat(sin(time * 3)) * 3
            y -= catH * 1.1 * CGFloat(dt) * CGFloat(0.7 + 0.3 * sin(time * 9))
            if y <= climbTarget { setMode(.hang, duration: .random(in: 1.2...2.4)) }
            return
        }
        rotation = .pi / 2
        facing = -1
        walk += (1 - walk) * (1 - exp(-dt * 8))
        if slipT > 0 {
            // Lost grip! Slide down a bit, paws scrabbling.
            slipT -= dt
            y = min(groundY - catH * 0.62, y + catH * 2.2 * CGFloat(dt))
            walkPhase += dt * 30
            air = 0.5
            mouthOTarget = 1
        } else {
            air *= exp(-dt * 10)
            // Inch-worm rhythm: little bursts, little pauses.
            let surge = max(0.12, 0.55 + 0.45 * sin(time * 6.5))
            let step = catH * 0.6 * CGFloat(dt) * CGFloat(surge)
            y -= step
            walkPhase += Double(step) / Double(catH * 0.42) * .pi * 2
            if Double.random(in: 0..<1) < dt * 0.2 { slipT = 0.3 }
        }
        if y <= climbTarget { setMode(.hang, duration: .random(in: 0.9...1.8)) }
    }

    private func startFall(vx: CGFloat) {
        self.vx = vx
        vy = species == .bird ? 0 : -catH * 1.5   // a tiny push off the wall
        air = 1
        if species != .bird { surpriseUntil = time + 0.7 }
        setMode(.fall)
    }

    private func updateFall(_ dt: Double) {
        if species == .bird {
            // Glide down gently instead of dropping.
            vy = min(vy + 260 * CGFloat(dt), catH * 2.4)
            y += vy * CGFloat(dt)
            x = min(max(x + vx * CGFloat(dt), birdWallX), max(maxX, wallX + 1))
            vx *= CGFloat(exp(-dt * 0.8))
            rotation = 0
            air = 1
            facing = vx >= 0 ? 1 : -1
            if y >= groundY { land() }
            return
        }
        vy += 1500 * CGFloat(dt)
        y += vy * CGFloat(dt)
        x = min(max(x + vx * CGFloat(dt), wallX), max(maxX, wallX + 1))
        vx *= CGFloat(exp(-dt * 1.5))
        rotation += (0 - rotation) * (1 - exp(-dt * 6))   // flip upright mid-air
        air = 1
        perkTarget = 1
        mouthOTarget = 1
        if y >= groundY { land() }
    }

    private func land() {
        y = groundY
        vx = 0; vy = 0
        rotation = 0
        air = 0
        crouch = 1                      // squash on impact
        crouchTarget = 0
        facing = 1                      // turn away from the wall
        x = min(max(x, minX), maxX)
        setMode(.stand, duration: 0.9)
    }

    private func dropFromHandle() {
        alpha = 1; scale = 1; sit = 0; loaf = 0; stand = 0; bow = 0
        y = handle.y + catW * 0.4
        if species == .cat {
            x = wallX + 2
            rotation = .pi / 2
            facing = -1
            faceScale = -1
        } else {
            x = wallX + catW * 0.6
            rotation = 0
            facing = 1
            faceScale = 1
        }
        startFall(vx: .random(in: 70...120))
    }

    // MARK: - Bird flights

    private func flyToNewSpot() {
        var t = x
        for _ in 0..<16 {
            let c = CGFloat.random(in: minX...max(minX + 1, maxX))
            if abs(c - x) > 60 && !(world == .menuBar && bandContains(c, margin: catW * 0.7)) { t = c; break }
        }
        guard abs(t - x) > 1 else { pickWalk(); return }
        flightFrom = anchor
        flightToX = t
        flightT = 0
        flightDur = 0.6 + Double(abs(t - x)) / 260
        facing = t > x ? 1 : -1
        sitTarget = 0; loafTarget = 0; bowTarget = 0
        setMode(.flight)
    }

    private func updateFlight(_ dt: Double) {
        flightT = min(1, flightT + dt / flightDur)
        let e = flightT < 0.5 ? 2 * flightT * flightT : 1 - pow(-2 * flightT + 2, 2) / 2
        x = flightFrom.x + (flightToX - flightFrom.x) * CGFloat(e)
        let height = min(catH * 1.4, abs(flightToX - flightFrom.x) * 0.3)
        y = groundY - CGFloat(sin(flightT * .pi)) * height
        air = flightT < 0.92 ? 1 : 0
        happyTarget = 0.6
        if flightT >= 1 {
            y = groundY
            crouch = 0.6
            setMode(.stand, duration: .random(in: 0.6...1.4))
        }
    }

    // MARK: - Into and out of the island

    func hopIntoNotch(completion: @escaping () -> Void) {
        guard isHoverable else { completion(); return }
        hopDone = completion
        hopFrom = anchor
        hopFromRotation = rotation
        switch world {
        case .menuBar:
            let side: CGFloat = x < centerX ? -1 : 1
            hopTo = CGPoint(x: centerX + side * max(4, notchHalf - catW * 0.55), y: groundY - catH * 0.2)
            facing = -side
        case .leftEdge:
            hopTo = CGPoint(x: wallX + 4, y: handle.y + catW * 0.3)
            facing = -1
        }
        if species == .bird { air = 1 }
        let dist = hypot(hopTo.x - hopFrom.x, hopTo.y - hopFrom.y)
        hopDur = 0.42 + min(0.45, Double(dist) / 1600)
        hopCrouch = rotation < 0.3 ? 0.16 : 0.05
        hopT = 0
        sitTarget = 0; loafTarget = 0; bowTarget = 0
        perkTarget = 1
        surpriseUntil = time + 0.45   // "o!"
        setMode(.hop)
    }

    /// The island opened some other way — the cat slips inside out of sight.
    func slipInside() {
        guard enabled, mode != .inside, mode != .hop else { return }
        setMode(.inside)
        alpha = 0
    }

    /// Wave hello from inside the island.
    func greet() { greetUntil = time + 1.8 }

    /// Show a little surprised face (e.g. a new track started).
    func surprise() { surpriseUntil = time + 0.6 }

    private func updateHop(_ dt: Double) {
        hopT += dt
        if hopT < hopCrouch { crouchTarget = 1; return }
        crouchTarget = 0
        let v = min(1, (hopT - hopCrouch) / hopDur)
        let ev = v < 0.5 ? 2 * v * v : 1 - pow(-2 * v + 2, 2) / 2
        let bx = hopFrom.x + (hopTo.x - hopFrom.x) * CGFloat(ev)
        let by = hopFrom.y + (hopTo.y - hopFrom.y) * CGFloat(ev)
        let arc = CGFloat(sin(v * .pi))
        switch world {
        case .menuBar:
            x = bx
            y = by - arc * catH * 0.6
            rotation = 0
        case .leftEdge:
            let dist = hypot(hopTo.x - hopFrom.x, hopTo.y - hopFrom.y)
            x = bx + arc * min(90, dist * 0.22)
            y = by - arc * catH * 0.4
            let endRotation = species == .cat ? Double.pi / 2 : 0
            rotation = hopFromRotation + (endRotation - hopFromRotation) * ev
        }
        air = sin(v * .pi)
        scale = 1 - 0.25 * v
        alpha = v > 0.82 ? max(0, 1 - (v - 0.82) / 0.18) : 1
        if v >= 1 {
            setMode(.inside)
            alpha = 0; scale = 1; air = 0
            let done = hopDone
            hopDone = nil
            done?()
        }
    }

    /// Called when the island closes: the cat comes back out.
    func popOut() {
        guard mode == .inside else { return }
        switch world {
        case .menuBar:
            let side: CGFloat = Bool.random() ? -1 : 1
            x = centerX + side * max(4, notchHalf - catW * 0.5)
            y = groundY
            rotation = 0
            alpha = 1; scale = 1; air = 0
            facing = side
            faceScale = side
            let half = (hiddenBand.upperBound - hiddenBand.lowerBound) / 2
            let out = centerX + side * (max(half, notchHalf) + catW + .random(in: 20...70))
            targetX = min(max(out, minX), maxX)
            speed = 30
            sit = 0; loaf = 0; stand = 0
            setMode(.popOut)
        case .leftEdge:
            dropFromHandle()
        }
    }

    // MARK: - Previews

    /// Freeze the cat in an exact pose (Settings preview, render scripts).
    func setPose(walk: Double = 0, phase: Double = 0, sit: Double = 0, loaf: Double = 0, bow: Double = 0,
                 stand: Double = 0, crouch: Double = 0, air: Double = 0, swat: Double = 0, blink: Double = 0,
                 perk: Double = 0, mouthO: Double = 0, happy: Double = 0, headBob: Double = 0, waveArm: Double = 0,
                 lookX: CGFloat = 0, facing: CGFloat = 1, lift: CGFloat = 0, rotation: Double = 0,
                 scale: Double = 1, time: Double = 0) {
        self.walk = walk; walkPhase = phase; self.sit = sit; self.loaf = loaf; self.bow = bow; self.stand = stand
        self.crouch = crouch; self.air = air; self.swat = swat; self.blink = blink; self.perk = perk
        self.mouthO = mouthO; self.happy = happy; self.headBob = headBob; self.waveArm = waveArm; self.lookX = lookX
        self.facing = facing; faceScale = facing; y = groundY - lift; self.rotation = rotation
        self.scale = scale; self.time = time
        alpha = 1
        frame &+= 1
    }

    // MARK: - Little life signs

    private func updateBlink(_ dt: Double) {
        nextBlink -= dt
        if nextBlink <= 0 {
            blinkClock = 0
            nextBlink = Double.random(in: 0..<1) < 0.2 ? 0.28 : .random(in: 2.2...6)
        }
        if blinkClock >= 0 {
            blinkClock += dt
            let p = blinkClock / 0.16
            blink = p < 0.5 ? p * 2 : max(0, 2 - p * 2)
            if p >= 1 { blinkClock = -1; blink = 0 }
        }
    }

    private func updateTwitch(_ dt: Double) {
        nextTwitch -= dt
        if nextTwitch <= 0 { twitchClock = 0; nextTwitch = .random(in: 3...9) }
        if twitchClock >= 0 {
            twitchClock += dt
            earTwitch = sin(min(1, twitchClock / 0.26) * .pi)
            if twitchClock > 0.26 { twitchClock = -1; earTwitch = 0 }
        }
    }
}
