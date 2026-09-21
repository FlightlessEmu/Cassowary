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

/// Press what is newly wanted, release what is not, return the new held set.
///
/// Views keep the held set in @State for highlighting and call this on every
/// gesture update so rolls across directions report exactly.
@MainActor
@discardableResult
func syncDirections(_ want: Set<String>, held: Set<String>, buttons: [String: ControllerButton], session: GameSession) -> Set<String> {
    for id in held.subtracting(want) {
        if let button = buttons[id] {
            session.release(button.systemKey)
        }
    }
    for id in want.subtracting(held) {
        if let button = buttons[id] {
            session.press(button.systemKey)
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
    let session: GameSession
    let theme: ButtonTheme
    var size: CGFloat = 180

    @State private var held: Set<String> = []

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
                    held = syncDirections(want, held: held, buttons: buttons, session: session)
                }
                .onEnded { _ in
                    held = syncDirections([], held: held, buttons: buttons, session: session)
                }
        )
        .accessibilityLabel("D-pad")
        .accessibilityHint("Touch and slide to press directions")
    }

    private func crossBar(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(theme.padBase())
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(theme.edge())
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
    let session: GameSession
    var diameter: CGFloat = 170

    @State private var held: Set<String> = []
    @State private var knob: CGSize = .zero

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
                .fill(.white.opacity(0.10))
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.18))
                }
            Circle()
                .fill(.white.opacity(0.28))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(knob)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let center = CGPoint(x: diameter / 2, y: diameter / 2)
                    let vector = stickVector(at: value.location, center: center, radius: diameter / 2)
                    knob = CGSize(width: vector.dx * travel, height: vector.dy * travel)
                    if hasAnalog {
                        driveAnalog(vector)
                    }
                    let want = directionIDs(for: vector, up: up, down: down, left: left, right: right)
                        .filter { buttons[$0]?.isAnalog != true }
                    held = syncDirections(want, held: held, buttons: buttons, session: session)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.18)) {
                        knob = .zero
                    }
                    if hasAnalog {
                        driveAnalog(.zero)
                    }
                    held = syncDirections([], held: held, buttons: buttons, session: session)
                }
        )
        .accessibilityLabel("Joystick")
        .accessibilityHint("Drag to push the stick")
    }

    /// Report each analog axis as its positive deflection, 0…1.
    private func driveAnalog(_ vector: CGVector) {
        if let right, right.isAnalog {
            session.moveAnalog(right.systemKey, value: max(0, vector.dx))
        }
        if let left, left.isAnalog {
            session.moveAnalog(left.systemKey, value: max(0, -vector.dx))
        }
        if let down, down.isAnalog {
            session.moveAnalog(down.systemKey, value: max(0, vector.dy))
        }
        if let up, up.isAnalog {
            session.moveAnalog(up.systemKey, value: max(0, -vector.dy))
        }
    }
}
