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

/// The on-screen gamepad.
///
/// The directional style (Settings → Controls) picks one of three pads, and
/// the button theme picks the look. The pad follows the controls each system
/// plugin describes; when the console has a skin (`ControllerSkin`) the face
/// buttons sit where the real controller has them, L and R move up to
/// shoulder buttons, and the Console theme paints them in the real colors.
/// A console without a skin gets plain blocks: a row for three buttons, a
/// square for four.
///
/// Every part of the pad can be dragged and resized from the game's menu
/// (Edit Controls Layout). Where it ends up is saved per system.
struct OnScreenControls: View {

    let layout: ControllerLayout
    let session: GameSession
    /// The pad is being rearranged: parts drag instead of pressing.
    @Binding var isEditing: Bool

    @AppStorage("cassowary.padStyle") private var styleRaw: String = DPadStyle.buttons.rawValue
    @AppStorage("cassowary.buttonTheme") private var themeRaw: String = ButtonTheme.console.rawValue

    @StateObject private var placements: ControlPlacementStore
    /// The part picked for resizing while editing.
    @State private var selected: ControlElement?
    /// The part being dragged, and how far, before the move is saved.
    @State private var dragging: ControlElement?
    @State private var dragTranslation: CGSize = .zero

    init(layout: ControllerLayout, session: GameSession, isEditing: Binding<Bool>) {
        self.layout = layout
        self.session = session
        self._isEditing = isEditing
        self._placements = StateObject(wrappedValue: ControlPlacementStore(systemIdentifier: layout.systemIdentifier))
    }

    /// System controls are drawn a little smaller than the face buttons, the
    /// way they are on a real controller.
    private static let systemScale: CGFloat = 0.8
    private static let systemSpacing: CGFloat = 8

    private var style: DPadStyle {
        DPadStyle(rawValue: styleRaw) ?? .buttons
    }

    private var theme: ButtonTheme {
        ButtonTheme(rawValue: themeRaw) ?? .console
    }

    private var skin: ControllerSkin? {
        ControllerSkin.forSystem(layout.systemIdentifier)
    }

    var body: some View {
        GeometryReader { geometry in
            // Controls scale with the screen so they stay reachable on a small
            // phone without covering the game on a large one.
            let portrait = geometry.size.height > geometry.size.width
            let parts = arrangement()
            let buttonSize = fittedButtonSize(parts, in: geometry.size, portrait: portrait)
            let place = Placing(size: geometry.size, portrait: portrait)

            VStack(spacing: 18) {
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        if !parts.leftShoulder.isEmpty {
                            movable(.leftShoulder, place) {
                                shoulderRow(parts.leftShoulder, buttonSize: buttonSize)
                            }
                        }
                        movable(.dpad, place) {
                            directionalPad(buttonSize: buttonSize)
                        }
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 16) {
                        // In landscape Start and Select stay at the top of the
                        // cluster, over the black bars rather than the game.
                        if !portrait, !systemButtons.isEmpty {
                            movable(.system, place) { systemBlock(buttonSize: buttonSize) }
                        }
                        if !parts.rightShoulder.isEmpty {
                            movable(.rightShoulder, place) {
                                shoulderRow(parts.rightShoulder, buttonSize: buttonSize)
                            }
                        }
                        movable(.face, place) {
                            // As tall as the d-pad, so the shoulder buttons
                            // on both sides sit level.
                            facePad(parts, buttonSize: buttonSize)
                                .frame(minHeight: padSpan(buttonSize: buttonSize))
                        }
                    }
                }

                // In portrait there is room below, so Start and Select sit in
                // the middle, where a real controller keeps them.
                if portrait, !systemButtons.isEmpty {
                    movable(.system, place) { systemBlock(buttonSize: buttonSize) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // In portrait the panel sits under the top bar, over the game
            // rather than the controls; in landscape the middle is the game.
            .overlay(alignment: portrait ? .top : .center) {
                if isEditing {
                    editPanel(portrait: portrait)
                        .padding(.top, portrait ? 70 : 0)
                }
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing { selected = nil }
        }
    }

    /// The size of one on-screen button.
    ///
    /// It follows the shorter side of the screen, so turning the device — or
    /// unfolding one — keeps the controls the same size instead of making
    /// them jump. The floor keeps them a comfortable touch target; the cap
    /// stops a row of buttons from swallowing a short landscape screen.
    private static func buttonSize(in size: CGSize) -> CGFloat {
        min(max(min(size.width, size.height) * 0.075, 46), 64)
    }

    /// The button size, shrunk if needed so the whole pad fits the screen.
    ///
    /// This is the one rule for every screen shape: measure the pad in
    /// button-widths, see how many fit across and down, and never go bigger
    /// than `buttonSize(in:)`. A wide cluster like the N64's then fits a
    /// narrow phone, and a tall stack of shoulders and buttons fits a short
    /// landscape screen, with nothing tuned per device.
    private func fittedButtonSize(_ parts: Arrangement, in size: CGSize, portrait: Bool) -> CGFloat {
        let preferred = Self.buttonSize(in: size)

        // The d-pad is three buttons and two gaps across.
        let padUnits: CGFloat = 3.3
        let shoulderHeight: CGFloat = 0.62 + 0.3
        func shoulderWidth(_ buttons: [ControllerButton]) -> CGFloat {
            CGFloat(buttons.count) * 1.6
        }
        func blockSize(_ count: Int, scale: CGFloat = 1) -> CGSize {
            let columns = count <= 3 ? count : 2
            let rows = count <= 3 ? 1 : (count + 1) / 2
            return CGSize(width: CGFloat(columns) * 1.2 * scale, height: CGFloat(rows) * 1.2 * scale)
        }

        var faceWidth: CGFloat = 0
        var faceHeight: CGFloat = 0
        if !parts.face.isEmpty {
            let spots = parts.face.map(\.spot)
            faceWidth = (spots.map { $0.x + $0.size / 2 }.max() ?? 0) - (spots.map { $0.x - $0.size / 2 }.min() ?? 0)
            faceHeight = (spots.map { $0.y + $0.size / 2 }.max() ?? 0) - (spots.map { $0.y - $0.size / 2 }.min() ?? 0)
        }
        for group in parts.rest {
            let block = blockSize(group.count)
            faceWidth = max(faceWidth, block.width)
            faceHeight += block.height + 0.2
        }

        var rightWidth = max(faceWidth, shoulderWidth(parts.rightShoulder))
        var rightHeight = faceHeight + (parts.rightShoulder.isEmpty ? 0 : shoulderHeight)
        let leftWidth = max(padUnits, shoulderWidth(parts.leftShoulder))
        let leftHeight = padUnits + (parts.leftShoulder.isEmpty ? 0 : shoulderHeight)
        var belowHeight: CGFloat = 0

        if !systemButtons.isEmpty {
            let system = blockSize(systemButtons.count, scale: Self.systemScale)
            if portrait {
                belowHeight = system.height + 0.3
            } else {
                rightWidth = max(rightWidth, system.width)
                rightHeight += system.height + 0.3
            }
        }

        // Room left after the padding, the gap between the two sides, and the
        // top bar, which the pad must not run under.
        let across = (size.width - 52) / (leftWidth + rightWidth)
        let down = (size.height - 32 - 70) / (max(leftHeight, rightHeight) + belowHeight)
        return max(min(preferred, across, down), 30)
    }

    /// The on-screen pads report through this, so every touch press buzzes the
    /// phone at the strength picked in Settings → Controls. A physical
    /// controller or keyboard goes straight to the session and stays silent.
    private var pressHandler: any ControlPressHandler {
        HapticPressHandler(target: session)
    }

    // MARK: - D-pad

    /// The directional control, in the style the user picked.
    ///
    /// A system with no d-pad shows nothing here either way; the buttons it
    /// does have show up on the right instead.
    @ViewBuilder
    private func directionalPad(buttonSize: CGFloat) -> some View {
        // The d-pad styles use the plugin's d-pad buttons; the thumbstick style
        // uses the plugin's stick buttons when the system has them, so on N64
        // it drives the analog inputs. Both sets come from the same layout a
        // physical controller uses.
        let buttons = style == .stick ? layout.leftStick : layout.dPad

        if buttons.isEmpty {
            Color.clear.frame(width: buttonSize * 3, height: buttonSize * 3)
        } else {
            switch style {
            case .buttons:
                SplitButtonsPad(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: pressHandler, theme: theme, buttonSize: buttonSize)
            case .dpad:
                ClassicDPadView(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: pressHandler, theme: theme, size: buttonSize * 3)
            case .stick:
                ThumbstickView(up: buttons.up, down: buttons.down, left: buttons.left, right: buttons.right, handler: pressHandler, theme: theme, diameter: buttonSize * 2.8)
                    .frame(width: buttonSize * 3, height: buttonSize * 3)
            }
        }
    }

    /// The height the directional control takes, whatever its style.
    private func padSpan(buttonSize: CGFloat) -> CGFloat {
        style == .buttons ? SplitButtonsPad.span(buttonSize: buttonSize, theme: theme) : buttonSize * 3
    }

    // MARK: - Which buttons are which

    /// The directions the pad already draws, which the action cluster leaves
    /// out.
    ///
    /// A real right stick is not drawn either, so its directions are left out
    /// too — but a system whose "right stick" is a set of buttons, like the
    /// N64's C buttons, keeps them: those are face buttons on that pad, and
    /// only the analog ones belong to a stick.
    private var directionalIDs: Set<String> {
        var ids = layout.dPad.ids.union(layout.leftStick.ids)
        for button in layout.rightStick.all.compactMap({ $0 }) where button.isAnalog {
            ids.insert(button.id)
        }
        return ids
    }

    /// The system controls the plugin describes, in its own order.
    private var systemButtons: [ControllerButton] {
        layout.allButtons.filter { !directionalIDs.contains($0.id) && ButtonGlyph.isSystem($0) }
    }

    /// The buttons the action cluster shows, kept in the groups the plugin put
    /// them in. System controls are left out here: they get their own block.
    private func actionGroups() -> [[ControllerButton]] {
        layout.groups
            .map { group in
                group.filter { button in
                    !directionalIDs.contains(button.id) && !ButtonGlyph.isSystem(button)
                }
            }
            .filter { !$0.isEmpty }
    }

    /// The action buttons sorted into the skin's places.
    private struct Arrangement {
        var face: [(spot: ControllerSkin.Spot, button: ControllerButton)] = []
        var leftShoulder: [ControllerButton] = []
        var rightShoulder: [ControllerButton] = []
        /// Buttons the skin does not place, in the plugin's groups.
        var rest: [[ControllerButton]] = []
    }

    /// Hand each button the skin names to its place, by label. Whatever is
    /// left keeps the plain blocks, so nothing goes missing.
    private func arrangement() -> Arrangement {
        let groups = actionGroups()
        guard let skin else { return Arrangement(rest: groups) }

        var pool = groups.flatMap { $0 }
        func take(_ label: String) -> ControllerButton? {
            let wanted = label.lowercased()
            guard let index = pool.firstIndex(where: {
                $0.label.trimmingCharacters(in: .whitespaces).lowercased() == wanted
            }) else { return nil }
            return pool.remove(at: index)
        }

        var parts = Arrangement()
        parts.leftShoulder = skin.leftShoulder.compactMap(take)
        parts.rightShoulder = skin.rightShoulder.compactMap(take)
        parts.face = skin.face.compactMap { spot in take(spot.label).map { (spot, $0) } }

        let left = Set(pool.map(\.id))
        parts.rest = groups
            .map { $0.filter { left.contains($0.id) } }
            .filter { !$0.isEmpty }
        return parts
    }

    // MARK: - Action buttons

    /// The face buttons: the skin's cluster, then any leftover blocks.
    private func facePad(_ parts: Arrangement, buttonSize: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 10) {
            if !parts.face.isEmpty {
                skinCluster(parts.face, buttonSize: buttonSize)
            }
            ForEach(Array(parts.rest.enumerated()), id: \.offset) { _, group in
                buttonBlock(group, buttonSize: buttonSize)
            }
        }
    }

    /// The skin's buttons, each at its own spot. The frame wraps the spots
    /// tightly so the cluster lines up with the rest of the pad.
    private func skinCluster(_ spots: [(spot: ControllerSkin.Spot, button: ControllerButton)], buttonSize: CGFloat) -> some View {
        let minX = spots.map { $0.spot.x - $0.spot.size / 2 }.min() ?? 0
        let maxX = spots.map { $0.spot.x + $0.spot.size / 2 }.max() ?? 0
        let minY = spots.map { $0.spot.y - $0.spot.size / 2 }.min() ?? 0
        let maxY = spots.map { $0.spot.y + $0.spot.size / 2 }.max() ?? 0
        let painted = theme == .console

        return ZStack(alignment: .topLeading) {
            ForEach(spots, id: \.button.id) { spot, button in
                FaceButtonView(
                    button: button,
                    handler: pressHandler,
                    theme: theme,
                    size: buttonSize * spot.size,
                    fill: painted ? spot.fill : nil,
                    glyph: painted ? spot.glyph : nil,
                    caption: skin?.captions[button.label]
                )
                .position(x: (spot.x - minX) * buttonSize, y: (spot.y - minY) * buttonSize)
            }
        }
        .frame(width: (maxX - minX) * buttonSize, height: (maxY - minY) * buttonSize)
    }

    private func shoulderRow(_ buttons: [ControllerButton], buttonSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            ForEach(buttons) { button in
                ShoulderButtonView(button: button, handler: pressHandler, theme: theme, size: buttonSize,
                                   caption: skin?.captions[button.label])
            }
        }
    }

    private func systemBlock(buttonSize: CGFloat) -> some View {
        buttonBlock(systemButtons, buttonSize: buttonSize * Self.systemScale, spacing: Self.systemSpacing)
    }

    /// One plugin group: a row for up to three buttons, a 2×2 grid for four
    /// or more. That keeps a three-button console (Genesis) in one row and a
    /// four-button one (SNES) in a square, the way their pads are.
    private func buttonBlock(_ buttons: [ControllerButton], buttonSize: CGFloat, spacing: CGFloat = 10) -> some View {
        let rows: [[ControllerButton]] = buttons.count <= 3
            ? [buttons]
            : stride(from: 0, to: buttons.count, by: 2).map {
                Array(buttons[$0 ..< min($0 + 2, buttons.count)])
            }

        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(row) { button in
                        FaceButtonView(button: button, handler: pressHandler, theme: theme, size: buttonSize,
                                       caption: skin?.captions[button.label])
                    }
                }
            }
        }
    }

    // MARK: - Moving the controls

    /// The screen the parts are moved across.
    private struct Placing {
        let size: CGSize
        let portrait: Bool
    }

    /// Draw one part where the player put it. While editing, the part stops
    /// pressing and becomes a handle: drag to move it, tap to pick it for
    /// resizing.
    private func movable<Content: View>(_ element: ControlElement, _ place: Placing, @ViewBuilder content: () -> Content) -> some View {
        let placement = placements.placement(for: element, portrait: place.portrait)
        let live = dragging == element ? dragTranslation : .zero

        return content()
            .allowsHitTesting(!isEditing)
            .overlay {
                if isEditing {
                    editHandle(element, place)
                }
            }
            .scaleEffect(placement.scale)
            .offset(x: placement.x * place.size.width + live.width,
                    y: placement.y * place.size.height + live.height)
            .zIndex(dragging == element ? 1 : 0)
    }

    private func editHandle(_ element: ControlElement, _ place: Placing) -> some View {
        let isSelected = selected == element
        return RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(isSelected ? 0.22 : 0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.7),
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            .padding(-6)
            .contentShape(Rectangle())
            // Measured on the whole screen, so a part drawn smaller or larger
            // still follows the finger exactly.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        selected = element
                        dragging = element
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        var placement = placements.placement(for: element, portrait: place.portrait)
                        placement.x += value.translation.width / max(place.size.width, 1)
                        placement.y += value.translation.height / max(place.size.height, 1)
                        placements.set(placement, for: element, portrait: place.portrait)
                        dragging = nil
                        dragTranslation = .zero
                    }
            )
            .accessibilityLabel("Move \(element.title)")
    }

    /// The panel shown while rearranging: size for the picked part, reset,
    /// and done.
    private func editPanel(portrait: Bool) -> some View {
        VStack(spacing: 12) {
            Text("Drag the controls to move them")
                .font(.headline)

            if let selected {
                Text("Size: \(selected.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(value: scaleBinding(selected, portrait: portrait), in: ControlPlacementStore.scaleRange) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "minus.magnifyingglass")
                } maximumValueLabel: {
                    Image(systemName: "plus.magnifyingglass")
                }
            } else {
                Text("Tap a control to change its size.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Reset", role: .destructive) {
                    placements.reset(portrait: portrait)
                }
                .buttonStyle(.bordered)

                Button("Done") {
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
            }

            Text(portrait ? "Saved for portrait." : "Saved for landscape.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .foregroundStyle(.white)
    }

    private func scaleBinding(_ element: ControlElement, portrait: Bool) -> Binding<CGFloat> {
        Binding(
            get: { placements.placement(for: element, portrait: portrait).scale },
            set: { scale in
                var placement = placements.placement(for: element, portrait: portrait)
                placement.scale = scale
                placements.set(placement, for: element, portrait: portrait)
            }
        )
    }
}
