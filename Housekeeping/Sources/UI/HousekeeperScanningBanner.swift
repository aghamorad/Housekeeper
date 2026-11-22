// Housekeeping — Animated Scanning & Progress Banner + Cartoon Cleaning Stage
//
// Displays the animated Housekeeper Octopus mascot with articulated sweeping arms,
// tool choreography (duster, broom, spray bottle, magnifier, wrench), animated
// folders being swept in real time, and zero idle CPU drain when paused/hidden.

import SwiftUI
import AppKit

/// Tailors the Housekeeper mascot's tools, props, and cartoon choreography to what
/// she is currently doing on your Mac.
enum CleaningActivityMode: Equatable {
    case scanningFolders
    case cleaningItems
    case emptyingTrash
    case checkingUpdates
    case updatingApps
    case maintenance

    var propBadgeTitle: String {
        switch self {
        case .scanningFolders: return "Inspecting folders"
        case .cleaningItems: return "Sweeping into Quarantine"
        case .emptyingTrash: return "Clearing Trash"
        case .checkingUpdates: return "Checking versions"
        case .updatingApps: return "Updating apps"
        case .maintenance: return "Checking system health"
        }
    }
}

/// Interactive cartoon stage showing the Housekeeper octopus moving her arms and
/// sweeping across animated folders according to the active operation.
struct AnimatedCleaningMascotStage: View {
    var mode: CleaningActivityMode = .scanningFolders
    var isActive: Bool = true
    var size: CGFloat = 104
    var showFolderTrack: Bool = true
    var accent: Color = HousekeepingPalette.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var budget = MotionBudget.shared
    @State private var appActive = NSApp.isActive
    @State private var onScreen = false

    private var shouldAnimate: Bool {
        isActive && !reduceMotion && appActive && scenePhase == .active && onScreen && budget.isTicking
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !shouldAnimate)) { timeline in
            let t = shouldAnimate ? timeline.date.timeIntervalSinceReferenceDate : 0
            CartoonHousekeeperCanvas(
                time: t,
                mode: mode,
                isActive: isActive,
                showFolderTrack: showFolderTrack,
                accent: accent
            )
        }
        .frame(width: showFolderTrack ? size * 1.48 : size, height: size)
        .tracksOnScreen($onScreen)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
        }
        .accessibilityLabel(mode.propBadgeTitle)
    }
}

private struct CartoonHousekeeperCanvas: View {
    let time: Double
    let mode: CleaningActivityMode
    let isActive: Bool
    let showFolderTrack: Bool
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let s = min(w / (showFolderTrack ? 1.48 : 1.0), h)

            // Subtle floor/desk shadow beneath the mascot and folders
            let shadowRect = CGRect(x: w * 0.14, y: h * 0.87, width: w * 0.72, height: h * 0.08)
            context.fill(
                Path(ellipseIn: shadowRect),
                with: .color(Color.black.opacity(0.11))
            )

            // Moving folder track in front/beside the housekeeper
            if showFolderTrack {
                drawFolderTrack(context: &context, size: size, scale: s)
            }

            // Scurrying horizontal glide + energetic cartoon bounce
            let speed: Double = {
                switch mode {
                case .cleaningItems, .emptyingTrash: return 3.6
                case .updatingApps: return 2.8
                case .scanningFolders, .checkingUpdates, .maintenance: return 2.5
                }
            }()
            let patrolX = isActive ? sin(time * speed * 0.55) * (w * 0.09) : 0
            let bounceY = isActive ? -abs(sin(time * speed)) * (s * 0.055) : 0
            let tiltAngle = isActive ? sin(time * speed * 0.55) * 0.065 : 0

            let center = CGPoint(x: w * 0.5 + patrolX, y: h * 0.48 + bounceY)

            var mascotCtx = context
            mascotCtx.translateBy(x: center.x, y: center.y)
            mascotCtx.rotate(by: Angle(radians: tiltAngle))

            drawOctopus(context: &mascotCtx, unit: s * 0.36, time: time)
            drawSparkles(context: &context, size: size, unit: s, time: time)
        }
    }

    private func drawFolderTrack(context: inout GraphicsContext, size: CGSize, scale: CGFloat) {
        let folderCount = 4
        let trackWidth = size.width * 0.86
        let startX = size.width * 0.07
        let baseY = size.height * 0.79

        for i in 0..<folderCount {
            let phaseOffset = Double(i) * (1.0 / Double(folderCount))
            let progress = isActive
                ? (time * 0.24 + phaseOffset).truncatingRemainder(dividingBy: 1.0)
                : phaseOffset * 0.75 + 0.12
            let x = startX + CGFloat(progress) * trackWidth
            let edgeFade = sin(progress * .pi)
            let pop = isActive ? max(0, sin(time * 5.0 + Double(i) * 1.7)) : 0
            let y = baseY - CGFloat(pop) * scale * 0.03

            let fw = scale * 0.21
            let fh = scale * 0.155
            var fCtx = context
            fCtx.opacity = Double(max(0.15, min(1.0, edgeFade * 1.35)))
            fCtx.translateBy(x: x, y: y)
            fCtx.rotate(by: Angle(radians: sin(time * 4.0 + Double(i)) * (isActive ? 0.08 : 0)))

            let tabRect = CGRect(x: -fw * 0.46, y: -fh * 0.62, width: fw * 0.42, height: fh * 0.28)
            let bodyRect = CGRect(x: -fw * 0.5, y: -fh * 0.46, width: fw, height: fh * 0.86)
            let folderColor: Color = {
                switch mode {
                case .cleaningItems, .emptyingTrash:
                    return i.isMultiple(of: 2) ? Color(red: 0.90, green: 0.54, blue: 0.26) : accent.opacity(0.85)
                case .updatingApps, .checkingUpdates:
                    return i.isMultiple(of: 2) ? Color(red: 0.28, green: 0.58, blue: 0.92) : Color(red: 0.52, green: 0.42, blue: 0.88)
                case .scanningFolders, .maintenance:
                    return i.isMultiple(of: 2) ? Color(red: 0.30, green: 0.62, blue: 0.94) : Color(red: 0.85, green: 0.44, blue: 0.36)
                }
            }()

            fCtx.fill(Path(roundedRect: tabRect, cornerRadius: fw * 0.10), with: .color(folderColor.opacity(0.85)))
            fCtx.fill(Path(roundedRect: bodyRect, cornerRadius: fw * 0.14), with: .color(folderColor))
            fCtx.stroke(
                Path(roundedRect: bodyRect, cornerRadius: fw * 0.14),
                with: .color(Color.white.opacity(0.45)),
                lineWidth: 0.9
            )
        }
    }

    private func drawOctopus(context: inout GraphicsContext, unit u: CGFloat, time: Double) {
        let bodyDark = Color(red: 0.64, green: 0.10, blue: 0.13)
        let bodyMid = Color(red: 0.84, green: 0.18, blue: 0.20)
        let bodyBright = Color(red: 0.94, green: 0.30, blue: 0.28)
        let cream = Color(red: 0.98, green: 0.92, blue: 0.82)
        let creamShadow = Color(red: 0.88, green: 0.78, blue: 0.65)

        // 1. Back/lower waving tentacles (4 walking/scuttling tentacles)
        let legOffsets: [(x: CGFloat, phase: Double, reach: CGFloat)] = [
            (-0.72, 0.0, 0.96),
            (-0.28, 1.3, 1.04),
            (0.28, 2.6, 1.04),
            (0.72, 3.9, 0.96)
        ]
        for leg in legOffsets {
            let swing = isActive ? sin(time * 5.2 + leg.phase) * 0.24 : 0
            let curl = isActive ? cos(time * 5.2 + leg.phase) * 0.14 : 0
            var path = Path()
            let root = CGPoint(x: leg.x * u * 0.55, y: u * 0.32)
            let ctrl1 = CGPoint(x: leg.x * u * 0.85 + CGFloat(swing) * u * 0.45, y: u * 0.72)
            let tip = CGPoint(
                x: leg.x * u * leg.reach + CGFloat(swing) * u * 0.65,
                y: u * 0.98 - CGFloat(abs(curl)) * u * 0.18
            )
            path.move(to: root)
            path.addQuadCurve(to: tip, control: ctrl1)
            context.stroke(
                path,
                with: .color(bodyDark),
                style: StrokeStyle(lineWidth: u * 0.26, lineCap: .round)
            )
            context.stroke(
                path,
                with: .color(bodyMid),
                style: StrokeStyle(lineWidth: u * 0.18, lineCap: .round)
            )
        }

        // 2. Round octopus mantle/head
        let headRect = CGRect(x: -u * 0.82, y: -u * 0.88, width: u * 1.64, height: u * 1.46)
        context.fill(
            Path(ellipseIn: headRect),
            with: .radialGradient(
                Gradient(colors: [bodyBright, bodyMid, bodyDark]),
                center: CGPoint(x: -u * 0.22, y: -u * 0.36),
                startRadius: u * 0.1,
                endRadius: u * 1.15
            )
        )

        // 3. Ruffled maid bonnet
        let puffCount = 5
        for i in 0..<puffCount {
            let t = Double(i) / Double(puffCount - 1) - 0.5
            let px = CGFloat(t) * u * 1.05
            let py = -u * 0.88 + abs(CGFloat(t)) * u * 0.25
            let r = u * (0.26 - abs(CGFloat(t)) * 0.06)
            context.fill(
                Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                with: .color(cream)
            )
        }
        var band = Path()
        band.move(to: CGPoint(x: -u * 0.72, y: -u * 0.66))
        band.addQuadCurve(
            to: CGPoint(x: u * 0.72, y: -u * 0.66),
            control: CGPoint(x: 0, y: -u * 0.95)
        )
        context.stroke(band, with: .color(creamShadow), style: StrokeStyle(lineWidth: u * 0.14, lineCap: .round))

        // 4. Scalloped maid apron
        var apron = Path()
        apron.move(to: CGPoint(x: -u * 0.44, y: u * 0.26))
        apron.addLine(to: CGPoint(x: u * 0.44, y: u * 0.26))
        apron.addLine(to: CGPoint(x: u * 0.58, y: u * 0.74))
        apron.addQuadCurve(to: CGPoint(x: 0, y: u * 0.84), control: CGPoint(x: u * 0.28, y: u * 0.90))
        apron.addQuadCurve(to: CGPoint(x: -u * 0.58, y: u * 0.74), control: CGPoint(x: -u * 0.28, y: u * 0.90))
        apron.closeSubpath()
        context.fill(apron, with: .color(cream))
        context.stroke(apron, with: .color(creamShadow), lineWidth: 1.0)

        // Apron pocket
        var pocket = Path()
        pocket.move(to: CGPoint(x: -u * 0.22, y: u * 0.44))
        pocket.addLine(to: CGPoint(x: u * 0.22, y: u * 0.44))
        pocket.addQuadCurve(to: CGPoint(x: -u * 0.22, y: u * 0.44), control: CGPoint(x: 0, y: u * 0.70))
        context.stroke(pocket, with: .color(creamShadow), lineWidth: 1.1)

        // 5. Expressive blinking cartoon eyes & rosy cheeks
        let blinkCycle = time.truncatingRemainder(dividingBy: 3.4)
        let isBlinking = isActive && blinkCycle > 3.22
        for side in [-1.0, 1.0] {
            let ex = CGFloat(side) * u * 0.30
            let ey = -u * 0.16
            // Rosy cheek
            context.fill(
                Path(ellipseIn: CGRect(x: ex + CGFloat(side) * u * 0.10 - u * 0.11, y: ey + u * 0.18, width: u * 0.22, height: u * 0.12)),
                with: .color(Color(red: 1.0, green: 0.58, blue: 0.58).opacity(0.70))
            )

            if isBlinking {
                var wink = Path()
                wink.move(to: CGPoint(x: ex - u * 0.12, y: ey))
                wink.addQuadCurve(to: CGPoint(x: ex + u * 0.12, y: ey), control: CGPoint(x: ex, y: ey + u * 0.08))
                context.stroke(wink, with: .color(Color(red: 0.12, green: 0.06, blue: 0.07)), style: StrokeStyle(lineWidth: u * 0.07, lineCap: .round))
            } else {
                let ew = u * 0.22
                let eh = u * 0.27
                context.fill(
                    Path(ellipseIn: CGRect(x: ex - ew * 0.5, y: ey - eh * 0.5, width: ew, height: eh)),
                    with: .color(Color(red: 0.10, green: 0.05, blue: 0.06))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: ex - ew * 0.22, y: ey - eh * 0.30, width: ew * 0.36, height: ew * 0.36)),
                    with: .color(.white)
                )
            }
        }

        // 6. Articulated Sweeping Arms + Props according to active mode
        let leftSweep = isActive ? sin(time * 5.8) : 0.0
        let rightSweep = isActive ? cos(time * 4.6) : 0.0

        // Left arm
        let leftShoulder = CGPoint(x: -u * 0.66, y: u * 0.10)
        let leftHand = CGPoint(
            x: -u * 1.18 + CGFloat(leftSweep) * u * 0.24,
            y: -u * 0.02 + CGFloat(abs(leftSweep)) * u * 0.22
        )
        var leftArm = Path()
        leftArm.move(to: leftShoulder)
        leftArm.addQuadCurve(to: leftHand, control: CGPoint(x: -u * 1.02, y: u * 0.36))
        context.stroke(leftArm, with: .color(bodyMid), style: StrokeStyle(lineWidth: u * 0.22, lineCap: .round))

        drawLeftProp(context: &context, at: leftHand, angle: -0.55 + leftSweep * 0.45, unit: u)

        // Right arm
        let rightShoulder = CGPoint(x: u * 0.66, y: u * 0.10)
        let rightHand = CGPoint(
            x: u * 1.16 + CGFloat(rightSweep) * u * 0.18,
            y: -u * 0.08 + CGFloat(sin(time * 5.2)) * u * 0.18
        )
        var rightArm = Path()
        rightArm.move(to: rightShoulder)
        rightArm.addQuadCurve(to: rightHand, control: CGPoint(x: u * 1.02, y: u * 0.34))
        context.stroke(rightArm, with: .color(bodyMid), style: StrokeStyle(lineWidth: u * 0.22, lineCap: .round))

        drawRightProp(context: &context, at: rightHand, angle: 0.28 + rightSweep * 0.32, unit: u, time: time)
    }

    private func drawLeftProp(context: inout GraphicsContext, at hand: CGPoint, angle: Double, unit u: CGFloat) {
        var ctx = context
        ctx.translateBy(x: hand.x, y: hand.y)
        ctx.rotate(by: Angle(radians: angle))

        switch mode {
        case .scanningFolders, .maintenance, .checkingUpdates:
            // Golden feather duster
            var stick = Path()
            stick.move(to: CGPoint(x: 0, y: u * 0.18))
            stick.addLine(to: CGPoint(x: 0, y: -u * 0.48))
            ctx.stroke(stick, with: .color(Color(red: 0.72, green: 0.48, blue: 0.22)), style: StrokeStyle(lineWidth: u * 0.08, lineCap: .round))
            let plume = CGRect(x: -u * 0.28, y: -u * 0.88, width: u * 0.56, height: u * 0.48)
            ctx.fill(Path(ellipseIn: plume), with: .color(Color(red: 0.98, green: 0.82, blue: 0.48)))
            ctx.stroke(Path(ellipseIn: plume), with: .color(Color(red: 0.88, green: 0.66, blue: 0.32)), lineWidth: 1)

        case .cleaningItems, .emptyingTrash:
            // Cartoon sweeping broom
            var handle = Path()
            handle.move(to: CGPoint(x: 0, y: -u * 0.42))
            handle.addLine(to: CGPoint(x: 0, y: u * 0.42))
            ctx.stroke(handle, with: .color(Color(red: 0.72, green: 0.48, blue: 0.22)), style: StrokeStyle(lineWidth: u * 0.08, lineCap: .round))
            let bristles = CGRect(x: -u * 0.24, y: u * 0.36, width: u * 0.48, height: u * 0.32)
            ctx.fill(Path(roundedRect: bristles, cornerRadius: u * 0.08), with: .color(Color(red: 0.96, green: 0.78, blue: 0.36)))
            ctx.stroke(Path(roundedRect: bristles, cornerRadius: u * 0.08), with: .color(Color(red: 0.76, green: 0.54, blue: 0.18)), lineWidth: 1)

        case .updatingApps:
            // Polishing cloth / buffing pad
            let pad = CGRect(x: -u * 0.22, y: -u * 0.22, width: u * 0.44, height: u * 0.34)
            ctx.fill(Path(roundedRect: pad, cornerRadius: u * 0.12), with: .color(Color(red: 0.98, green: 0.86, blue: 0.52)))
            ctx.stroke(Path(roundedRect: pad, cornerRadius: u * 0.12), with: .color(Color.white.opacity(0.6)), lineWidth: 1)
        }
    }

    private func drawRightProp(context: inout GraphicsContext, at hand: CGPoint, angle: Double, unit u: CGFloat, time: Double) {
        var ctx = context
        ctx.translateBy(x: hand.x, y: hand.y)
        ctx.rotate(by: Angle(radians: angle))

        switch mode {
        case .scanningFolders, .checkingUpdates:
            // Magnifying glass
            var handle = Path()
            handle.move(to: CGPoint(x: 0, y: u * 0.16))
            handle.addLine(to: CGPoint(x: 0, y: -u * 0.16))
            ctx.stroke(handle, with: .color(Color(red: 0.45, green: 0.30, blue: 0.20)), style: StrokeStyle(lineWidth: u * 0.09, lineCap: .round))
            let lens = CGRect(x: -u * 0.24, y: -u * 0.62, width: u * 0.48, height: u * 0.48)
            ctx.fill(Path(ellipseIn: lens), with: .color(Color.cyan.opacity(0.24)))
            ctx.stroke(Path(ellipseIn: lens), with: .color(Color(red: 0.86, green: 0.70, blue: 0.28)), lineWidth: u * 0.09)

        case .cleaningItems, .emptyingTrash:
            // Iconic yellow spray bottle + animated mist puffs
            let bottle = CGRect(x: -u * 0.18, y: -u * 0.24, width: u * 0.36, height: u * 0.48)
            ctx.fill(Path(roundedRect: bottle, cornerRadius: u * 0.12), with: .color(Color(red: 0.98, green: 0.76, blue: 0.22)))
            let nozzle = CGRect(x: -u * 0.12, y: -u * 0.40, width: u * 0.34, height: u * 0.14)
            ctx.fill(Path(roundedRect: nozzle, cornerRadius: u * 0.05), with: .color(.white))
            if isActive {
                let spray = (time * 2.2).truncatingRemainder(dividingBy: 1.0)
                let mistR = u * 0.07
                for d in 0..<3 {
                    let dx = u * (0.28 + CGFloat(spray) * 0.35 + CGFloat(d) * 0.08)
                    let dy = -u * (0.36 + CGFloat(d - 1) * 0.08)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: dx, y: dy, width: mistR, height: mistR)),
                        with: .color(Color.white.opacity(0.85 * (1.0 - spray)))
                    )
                }
            }

        case .updatingApps, .maintenance:
            // Maintenance wrench
            var shaft = Path()
            shaft.move(to: CGPoint(x: 0, y: u * 0.22))
            shaft.addLine(to: CGPoint(x: 0, y: -u * 0.44))
            ctx.stroke(shaft, with: .color(Color(red: 0.76, green: 0.80, blue: 0.86)), style: StrokeStyle(lineWidth: u * 0.10, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: -u * 0.18, y: -u * 0.62, width: u * 0.36, height: u * 0.28)), with: .color(Color(red: 0.76, green: 0.80, blue: 0.86)))
        }
    }

    private func drawSparkles(context: inout GraphicsContext, size: CGSize, unit s: CGFloat, time: Double) {
        guard isActive else { return }
        let spots: [(CGFloat, CGFloat, Double)] = [
            (0.18, 0.22, 0.0),
            (0.84, 0.20, 1.4),
            (0.26, 0.64, 2.7),
            (0.76, 0.62, 4.1)
        ]
        for (nx, ny, offset) in spots {
            let pulse = (sin(time * 4.2 + offset) + 1.0) * 0.5
            guard pulse > 0.2 else { continue }
            let r = s * 0.045 * CGFloat(pulse)
            let cx = size.width * nx
            let cy = size.height * ny
            var star = Path()
            star.move(to: CGPoint(x: cx, y: cy - r))
            star.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx, y: cy))
            star.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx, y: cy))
            star.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx, y: cy))
            star.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx, y: cy))
            context.fill(star, with: .color(Color(red: 1.0, green: 0.86, blue: 0.38).opacity(pulse * 0.9)))
        }
    }
}

/// A warm, reassuring, animated scanning banner featuring the Housekeeper Octopus mascot.
/// Displays articulated cartoon arm & folder-sweeping motion, live path discovery, step counters, and clear safety guarantees.
struct HousekeeperScanningBanner: View {
    let title: String
    let subtitle: String
    var currentItem: String? = nil
    var stepCount: String? = nil
    var progressFraction: Double? = nil
    var mode: CleaningActivityMode = .scanningFolders
    var onStop: (() -> Void)? = nil

    @Environment(\.uiStyle) private var style

    var body: some View {
        HStack(spacing: 18) {
            AnimatedCleaningMascotStage(
                mode: mode,
                isActive: true,
                size: 74,
                showFolderTrack: true,
                accent: style.accent
            )
            .padding(4)
            .background(style.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(style.isRetro ? style.titleFont : .system(size: 16, weight: .bold))
                        .foregroundStyle(style.text)

                    Spacer()

                    if let stepCount {
                        Text(stepCount)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(style.accent.opacity(0.12), in: Capsule())
                            .foregroundStyle(style.accent)
                    }
                }

                if let currentItem, !currentItem.isEmpty {
                    Text(currentItem)
                        .font(style.pathFont)
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(subtitle)
                        .font(style.smallFont)
                        .foregroundStyle(style.secondaryText)
                        .lineLimit(1)
                }

                if let fraction = progressFraction {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [style.accentShaded, style.accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(fraction))))
                        }
                    }
                    .frame(height: 5)
                }

                HStack(spacing: 8) {
                    Label("100% Safe · Nothing is deleted without your approval", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.accent)

                    Spacer()

                    if let onStop {
                        Button(action: onStop) {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.circle.fill")
                                Text("Stop")
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop reading; results found so far remain visible.")
                    }
                }
            }
        }
        .padding(16)
        .background(style.rowBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(style.accent.opacity(0.35), lineWidth: 1)
        )
    }
}
