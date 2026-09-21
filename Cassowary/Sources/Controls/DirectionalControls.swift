// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import SwiftUI
import UIKit
import OpenEmuSystem
import OpenEmuKit

/// Anything that turns button presses into emulator input.
///
/// `GameSession` is the real one. The Settings test pad uses
/// `PreviewPressHandler`, which records presses instead of emulating.
protocol ControlPressHandler {
    func press(_ button: OESystemKey)
    func release(_ button: OESystemKey)
    func moveAnalog(_ button: OESystemKey, value: CGFloat)
}

extension GameSession: ControlPressHandler {}

/// The directional input style, picked in Settings → Controls.
enum DPadStyle: String, CaseIterable, Identifiable {
    case buttons
    case dpad
    case stick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .buttons: return "Buttons"
        case .dpad: return "D-Pad"
        case .stick: return "Thumbstick"
        }
    }

    var blurb: String {
        switch self {
        case .buttons: return "Four separate buttons in a cross."
        case .dpad: return "A classic cross. Slide to roll between directions."
        case .stick: return "A stick that follows your finger — swipe anywhere on it."
        }
    }
}

/// Settings for retriggering a held direction on the d-pad.
///
/// A held direction is normally reported once and the game keeps moving while
/// it stays down — what most games want. Games that only act on a fresh press
/// (menus, puzzle games) instead need the direction repeated, so that is
/// opt-in and its rate is the user's to pick.
enum DirectionRepeat {

    static let enabledKey = "cassowary.dpadRepeat"
    static let rateKey = "cassowary.dpadRepeatRate"

    /// Repeats per second. Kept low enough that each press still lasts several
    /// frames, which is what makes a repeat count.
    static let defaultRate = 8.0
    static let rateRange = 3.0...12.0

    /// How long a direction is held before the first repeat, so a quick tap
    /// passes through untouched.
    static let initialDelay = 0.35

    /// How long each repeat lets go before pressing again. The game has to see
    /// a released frame for the next press to be a new press.
    static let releaseGap = 0.034
}

/// Press what is newly wanted, release what is not, return the new held set.
///
/// Views keep the held set in @State for highlighting and call this on every
/// gesture update so rolls across directions report exactly.
@MainActor
@discardableResult
func syncDirections(_ want: Set<String>, held: Set<String>, buttons: [String: ControllerButton], handler: any ControlPressHandler) -> Set<String> {
    for id in held.subtracting(want) {
        if let button = buttons[id] {
            handler.release(button.systemKey)
        }
    }
    for id in want.subtracting(held) {
        if let button = buttons[id] {
            handler.press(button.systemKey)
        }
    }
    return want
}

/// Which direction buttons a stick deflection means.
///
/// `vector` is normalized (-1…1, y down). Inside the deadzone nothing is
/// pressed; beyond it each axis presses independently, so diagonals press
/// two buttons — like a real pad.
func directionIDs(for vector: CGVector, up: ControllerButton?, down: ControllerButton?, left: ControllerButton?, right: ControllerButton?) -> Set<String> {
    guard hypot(vector.dx, vector.dy) >= 0.22 else { return [] }
    var ids = Set<String>()
    if vector.dx > 0.35, let right { ids.insert(right.id) }
    else if vector.dx < -0.35, let left { ids.insert(left.id) }
    if vector.dy > 0.35, let down { ids.insert(down.id) }
    else if vector.dy < -0.35, let up { ids.insert(up.id) }
    return ids
}

/// A normalized stick vector from a touch, clamped to the unit circle.
func stickVector(at location: CGPoint, center: CGPoint, radius: CGFloat) -> CGVector {
    guard radius > 0 else { return .zero }
    var dx = (location.x - center.x) / radius
    var dy = (location.y - center.y) / radius
    let length = hypot(dx, dy)
    if length > 1 {
        dx /= length
        dy /= length
    }
    return CGVector(dx: dx, dy: dy)
}

/// A classic cross D-pad.
///
/// One touch surface: the direction follows the finger, so rolling from
/// left to up reports release-left + press-up with no lift. Everything is
/// full-throw digital — the correct feel for a cross, and what an analog
/// system reads as fully deflected.
struct ClassicDPadView: View {

    let up: ControllerButton?
    let down: ControllerButton?
    let left: ControllerButton?
    let right: ControllerButton?
    let handler: any ControlPressHandler
    let theme: ButtonTheme
    var size: CGFloat = 180

    @State private var held: Set<String> = []

    @AppStorage(DirectionRepeat.enabledKey) private var repeatEnabled = false
    @AppStorage(DirectionRepeat.rateKey) private var repeatRate = DirectionRepeat.defaultRate

    /// The retrigger run for whatever is held right now, if any.
    @State private var repeatTask: Task<Void, Never>?

    private var buttons: [String: ControllerButton] {
        [up, down, left, right].compactMap { $0 }.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    var body: some View {
        let bar = size / 3
        ZStack {
            // The cross.
            Group {
                crossBar(width: bar, height: size, corner: bar * 0.28)
                crossBar(width: size, height: bar, corner: bar * 0.28)
            }
            .shadow(color: theme.pressGlow().opacity(held.isEmpty ? 0 : 0.6), radius: 10)

            // Pressed arms light up.
            armHighlight(id: up?.id, width: bar, height: bar, x: 0, y: -bar)
            armHighlight(id: down?.id, width: bar, height: bar, x: 0, y: bar)
            armHighlight(id: left?.id, width: bar, height: bar, x: -bar, y: 0)
            armHighlight(id: right?.id, width: bar, height: bar, x: bar, y: 0)

            // Direction chevrons.
            chevron("chevron.up", id: up?.id, x: 0, y: -bar, bar: bar)
            chevron("chevron.down", id: down?.id, x: 0, y: bar, bar: bar)
            chevron("chevron.left", id: left?.id, x: -bar, y: 0, bar: bar)
            chevron("chevron.right", id: right?.id, x: bar, y: 0, bar: bar)

            // Pivot.
            Circle()
                .fill(theme.padActive())
                .overlay {
                    Circle()
                        .strokeBorder(theme.edge())
                }
                .frame(width: bar * 0.72, height: bar * 0.72)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.08), value: held)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: size / 2, y: size / 2)
                    let vector = stickVector(at: value.location, center: center, radius: size / 2)
                    let want = directionIDs(for: vector, up: up, down: down, left: left, right: right)
                    // Only a roll to a different direction changes the report;
                    // a finger that merely jitters in place must not restart
                    // the retrigger delay.
                    guard want != held else { return }
                    held = syncDirections(want, held: held, buttons: buttons, handler: handler)
                }
                .onEnded { _ in
                    stopRepeat()
                    held = syncDirections([], held: held, buttons: buttons, handler: handler)
                }
        )
        .onAppear { restartRepeat() }
        .onDisappear { stopRepeat() }
        .onChange(of: RepeatKey(held: held, enabled: repeatEnabled, rate: repeatRate)) { _, _ in
            restartRepeat()
        }
        .accessibilityLabel("D-pad")
        .accessibilityHint("Touch and slide to press directions")
    }

    // MARK: - Auto-repeat

    /// What a retrigger run depends on. A change to any of it restarts the run.
    private struct RepeatKey: Hashable {
        let held: Set<String>
        let enabled: Bool
        let rate: Double
    }

    /// Retrigger the held direction(s) at the rate the user picked.
    ///
    /// One task per held set: it lets go for a moment, presses again, then
    /// waits out the rest of the interval. Cancelling it — a lift, a roll to
    /// another direction, or a settings change — leaves the last press in
    /// place, so the gesture code above stays in charge of the final report.
    private func restartRepeat() {
        stopRepeat()
        guard repeatEnabled, !held.isEmpty else { return }

        let ids = held
        let period = 1 / max(repeatRate, 1)
        let gap = min(DirectionRepeat.releaseGap, period * 0.5)
        let pressed = max(period - gap, 0.01)

        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(DirectionRepeat.initialDelay))
            while !Task.isCancelled {
                for id in ids {
                    if let button = buttons[id] { handler.release(button.systemKey) }
                }
                try? await Task.sleep(for: .seconds(gap))
                guard !Task.isCancelled else { return }
                for id in ids {
                    if let button = buttons[id] { handler.press(button.systemKey) }
                }
                try? await Task.sleep(for: .seconds(pressed))
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private func crossBar(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(theme.padBase())
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(theme.edge(), lineWidth: 1)
            }
            .frame(width: width, height: height)
    }

    private func armHighlight(id: String?, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(width, height) * 0.28, style: .continuous)
            .fill(id.map { held.contains($0) } ?? false ? theme.padActive() : .clear)
            .frame(width: width, height: height)
            .offset(x: x, y: y)
    }

    private func chevron(_ symbol: String, id: String?, x: CGFloat, y: CGFloat, bar: CGFloat) -> some View {
        Group {
            if id != nil {
                Image(systemName: symbol)
                    .font(.system(size: bar * 0.32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(x: x, y: y)
            }
        }
    }
}

/// A virtual thumbstick.
///
/// Drag (or swipe) anywhere on it and the knob follows the finger. Digital
/// systems get 8-way press/release like the other styles. When the system's
/// directions are analog (N64 stick and friends), each axis instead reports
/// its proportional deflection through `changeAnalogEmulatorKey` — value 0
/// on release means centered, matching HID axis semantics.
struct ThumbstickView: View {

    let up: ControllerButton?
    let down: ControllerButton?
    let left: ControllerButton?
    let right: ControllerButton?
    let handler: any ControlPressHandler
    let theme: ButtonTheme
    var diameter: CGFloat = 170

    @State private var held: Set<String> = []
    @State private var knob: CGSize = .zero
    @State private var active = false

    private var buttons: [String: ControllerButton] {
        [up, down, left, right].compactMap { $0 }.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    private var hasAnalog: Bool {
        [up, down, left, right].contains { $0?.isAnalog == true }
    }

    var body: some View {
        let knobDiameter = diameter * 0.44
        let travel = diameter / 2 - knobDiameter / 2 - 4
        ZStack {
            Circle()
                .fill(theme.padBase())
                .overlay {
                    Circle().strokeBorder(theme.edge())
                }
            Circle()
                .fill(active ? theme.padActive() : theme.faceBase())
                .overlay {
                    Circle().strokeBorder(theme.edge())
                }
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(knob)
                .offset(y: active ? theme.pressOffsetY : 0)
                .shadow(color: active ? theme.pressGlow() : .clear, radius: 12)
                .shadow(color: .black.opacity(0.4), radius: 2, y: active ? 1 : theme.restShadowY)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: diameter / 2, y: diameter / 2)
                    let vector = stickVector(at: value.location, center: center, radius: diameter / 2)
                    knob = CGSize(width: vector.dx * travel, height: vector.dy * travel)
                    active = true
                    if hasAnalog {
                        driveAnalog(vector)
                    }
                    let want = directionIDs(for: vector, up: up, down: down, left: left, right: right)
                        .filter { buttons[$0]?.isAnalog != true }
                    held = syncDirections(want, held: held, buttons: buttons, handler: handler)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.18)) {
                        knob = .zero
                    }
                    active = false
                    if hasAnalog {
                        driveAnalog(.zero)
                    }
                    held = syncDirections([], held: held, buttons: buttons, handler: handler)
                }
        )
        .accessibilityLabel("Joystick")
        .accessibilityHint("Drag to push the stick")
    }

    /// Report each analog axis as its positive deflection, 0…1.
    private func driveAnalog(_ vector: CGVector) {
        if let right, right.isAnalog {
            handler.moveAnalog(right.systemKey, value: max(0, vector.dx))
        }
        if let left, left.isAnalog {
            handler.moveAnalog(left.systemKey, value: max(0, -vector.dx))
        }
        if let down, down.isAnalog {
            handler.moveAnalog(down.systemKey, value: max(0, vector.dy))
        }
        if let up, up.isAnalog {
            handler.moveAnalog(up.systemKey, value: max(0, -vector.dy))
        }
    }
}

/// A soft rounded square, used for the pad arms, buttons, and plates.
struct ControlPadShape: Shape {
    /// Corner radius as a fraction of the shorter side, so the shape stays
    /// correct whether or not the frame is square.
    var cornerFactor: CGFloat = 0.28

    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * cornerFactor, style: .continuous)
    }
}

/// A button that presses on touch down and releases on touch up.
///
/// Games read the button state every frame, so the press and release have to be
/// reported exactly, not just on tap. The drag gesture with no minimum distance
/// is what gives us the touch-down callback. The press animation (shrink for
/// Glass/Neon, travel for Retro, glow for Neon) comes from the theme.
struct HoldableButton<Label: View>: View {

    let button: ControllerButton
    let handler: any ControlPressHandler
    let theme: ButtonTheme
    @ViewBuilder let label: (Bool) -> Label

    @State private var isPressed = false

    var body: some View {
        label(isPressed)
            .scaleEffect(isPressed ? theme.pressScale : 1)
            .offset(y: isPressed ? theme.pressOffsetY : 0)
            .shadow(color: isPressed ? theme.pressGlow() : .clear, radius: 12)
            .shadow(color: .black.opacity(0.4), radius: 2, y: isPressed ? 1 : theme.restShadowY)
            .animation(.spring(response: 0.16, dampingFraction: 0.75), value: isPressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        handler.press(button.systemKey)
                    }
                    .onEnded { _ in
                        isPressed = false
                        handler.release(button.systemKey)
                    }
            )
            .accessibilityLabel(button.label)
            .accessibilityAddTraits(.isButton)
    }
}

/// Four separate chevron buttons in a cross.
///
/// Each direction is its own target, so sliding from one to the next reports a
/// release and a press rather than a roll. Glass and Neon show four caps with
/// room between them; Retro shows one solid, clicky pad — a real d-pad shape
/// with the arms still pressing on their own.
struct SplitButtonsPad: View {

    let up: ControllerButton?
    let down: ControllerButton?
    let left: ControllerButton?
    let right: ControllerButton?
    let handler: any ControlPressHandler
    let theme: ButtonTheme
    var buttonSize: CGFloat = 56

    /// Retro is drawn as one solid pad; the other themes are four loose caps.
    private var isSolid: Bool { theme == .retro }

    /// Gap between the caps, and between a cap and the pad body.
    private var gap: CGFloat {
        max(buttonSize * (isSolid ? 0.05 : 0.14), isSolid ? 2 : 6)
    }

    /// The square the whole control fills.
    private var span: CGFloat { buttonSize * 3 + gap * 2 }

    /// Distance from the middle to an arm's centre.
    private var reach: CGFloat { buttonSize + gap }

    var body: some View {
        ZStack {
            // Retro gets a body under the caps, so the group reads as a real
            // d-pad. Without it the seams would let the game show through.
            if isSolid {
                padBody
            }

            padCap(up, symbol: "chevron.up").offset(y: -reach)
            padCap(down, symbol: "chevron.down").offset(y: reach)
            padCap(left, symbol: "chevron.left").offset(x: -reach)
            padCap(right, symbol: "chevron.right").offset(x: reach)

            centerPivot
        }
        .frame(width: span, height: span)
    }

    /// The plus the Retro caps sit on: two bars, like a real d-pad's body.
    private var padBody: some View {
        Group {
            bar(width: buttonSize, height: span)
            bar(width: span, height: buttonSize)
        }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        ControlPadShape(cornerFactor: 0.22)
            .fill(theme.padBase())
            .overlay {
                ControlPadShape(cornerFactor: 0.22)
                    .stroke(theme.edge(), lineWidth: 1)
            }
            .frame(width: width, height: height)
    }

    /// The middle of the cross: a dimple, not a button.
    private var centerPivot: some View {
        Circle()
            .fill(theme.padActive())
            .frame(width: buttonSize * 0.3, height: buttonSize * 0.3)
            .opacity(isSolid ? 0.9 : 0.7)
    }

    private func padCap(_ button: ControllerButton?, symbol: String) -> some View {
        Group {
            if let button {
                HoldableButton(button: button, handler: handler, theme: theme) { pressed in
                    ControlPadShape(cornerFactor: 0.22)
                        .fill(pressed ? theme.padActive() : (isSolid ? theme.padCap() : theme.padBase()))
                        .overlay {
                            // A solid pad draws its one outline on the body;
                            // loose caps each need their own.
                            if !isSolid {
                                ControlPadShape(cornerFactor: 0.22)
                                    .stroke(theme.edge(), lineWidth: 1)
                            }
                        }
                        .frame(width: buttonSize, height: buttonSize)
                        .overlay {
                            Image(systemName: symbol)
                                .font(.system(size: buttonSize * 0.32, weight: .bold))
                                .foregroundStyle(.white.opacity(pressed ? 1 : 0.82))
                        }
                }
            } else {
                Color.clear.frame(width: buttonSize, height: buttonSize)
            }
        }
    }
}

/// One round face button (A, B, Start…) in the current theme.
struct FaceButtonView: View {

    let button: ControllerButton
    let handler: any ControlPressHandler
    let theme: ButtonTheme
    var size: CGFloat = 56

    var body: some View {
        HoldableButton(button: button, handler: handler, theme: theme) { pressed in
            Circle()
                .fill(pressed ? theme.faceActive() : theme.faceBase())
                .overlay {
                    Circle()
                        .stroke(theme.edge(), lineWidth: 1)
                }
                .frame(width: size, height: size)
                .overlay {
                    Text(button.label)
                        .font(.system(size: size * 0.28, weight: .semibold))
                        .foregroundStyle(.white.opacity(pressed ? 1 : 0.9))
                }
        }
    }
}

/// Records presses for the Settings test pad instead of emulating.
///
/// Button labels are registered up front (fake preview buttons have no core
/// behind them), and every press ticks the counter and plays a light haptic
/// so the theme can be felt as well as seen.
@MainActor
final class PreviewPressHandler: ObservableObject, ControlPressHandler {

    @Published private(set) var lastLabel = "—"
    @Published private(set) var pressCount = 0

    private var labels: [UInt: String] = [:]
    private var lastAnalogBucket = -1
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    func register(_ button: ControllerButton) {
        labels[button.keyIndex] = button.label
    }

    func press(_ button: OESystemKey) {
        lastLabel = labels[button.key] ?? "…"
        pressCount += 1
        feedback.impactOccurred()
    }

    func release(_ button: OESystemKey) { }

    func moveAnalog(_ button: OESystemKey, value: CGFloat) {
        // Analog systems report deflection continuously; show it in 10% steps
        // so the readout proves proportionality without redrawing every frame.
        let bucket = Int((value * 10).rounded())
        guard bucket != lastAnalogBucket else { return }
        lastAnalogBucket = bucket
        let label = labels[button.key] ?? "…"
        lastLabel = "\(label) \(bucket * 10)%"
    }
}

/// Fake buttons for the test pad. Real game buttons come from the system
/// plugin; these stand in so a style and theme can be tried with no game.
enum PreviewButtons {
    static let up = ControllerButton(id: "preview.up", label: "Up", keyIndex: 0, isAnalog: false)
    static let down = ControllerButton(id: "preview.down", label: "Down", keyIndex: 1, isAnalog: false)
    static let left = ControllerButton(id: "preview.left", label: "Left", keyIndex: 2, isAnalog: false)
    static let right = ControllerButton(id: "preview.right", label: "Right", keyIndex: 3, isAnalog: false)
    static let a = ControllerButton(id: "preview.a", label: "A", keyIndex: 4, isAnalog: false)
    static let b = ControllerButton(id: "preview.b", label: "B", keyIndex: 5, isAnalog: false)

    static let all = [up, down, left, right, a, b]
}

/// The Settings test pad: the selected style and theme, pressable.
///
/// Drawn on a dark stage (the row behind it is white, which would wash out
/// Glass). Feel only — presses go to the preview handler, not a game.
struct ControlPreview: View {

    let style: DPadStyle
    let theme: ButtonTheme
    @ObservedObject var handler: PreviewPressHandler

    var body: some View {
        HStack {
            switch style {
            case .buttons:
                SplitButtonsPad(up: PreviewButtons.up, down: PreviewButtons.down, left: PreviewButtons.left, right: PreviewButtons.right, handler: handler, theme: theme, buttonSize: 52)
            case .dpad:
                ClassicDPadView(up: PreviewButtons.up, down: PreviewButtons.down, left: PreviewButtons.left, right: PreviewButtons.right, handler: handler, theme: theme, size: 156)
            case .stick:
                ThumbstickView(up: PreviewButtons.up, down: PreviewButtons.down, left: PreviewButtons.left, right: PreviewButtons.right, handler: handler, theme: theme, diameter: 148)
            }

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                FaceButtonView(button: PreviewButtons.a, handler: handler, theme: theme, size: 56)
                FaceButtonView(button: PreviewButtons.b, handler: handler, theme: theme, size: 56)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            PreviewButtons.all.forEach(handler.register)
        }
    }
}
