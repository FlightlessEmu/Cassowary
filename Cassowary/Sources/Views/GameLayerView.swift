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
import QuartzCore

/// One step of a touch on the game picture.
enum GameTouch {
    case down(CGPoint)
    case moved(CGPoint)
    case up
}

/// Hosts the core's Metal layer inside SwiftUI.
///
/// The core renders into a `CAMetalLayer` it owns. This view puts that layer on
/// screen, tells the session how big the display area is, and passes touches on
/// to the emulated touch screen.
///
/// The layer itself is set to `contentsGravity = .resizeAspect`, so it centres
/// and fits the game inside whatever frame it is given. That keeps the aspect
/// ratio handling in one place, shared with the macOS app.
struct GameLayerView: UIViewRepresentable {

    let layer: CAMetalLayer

    /// The core's buffer size in pixels, which is the space touch points use.
    ///
    /// Read when a touch arrives rather than carried as a value: the core only
    /// reports its size once it is running, and the session is not observable,
    /// so a value captured here would still be zero.
    let bufferSize: () -> CGSize

    /// The shape the picture is shown in. The core's aspect size is not always
    /// the buffer size — a Game Boy outputs 160×144 but shows at 10:9.
    let aspectRatio: () -> CGFloat

    /// Steps of a touch, with each point in buffer pixels.
    let onTouch: (GameTouch) -> Void

    let onResize: (CGRect) -> Void

    func makeUIView(context: Context) -> GameLayerHostView {
        let view = GameLayerHostView()
        view.backgroundColor = .black
        view.attach(layer: layer)
        configure(view)
        return view
    }

    func updateUIView(_ view: GameLayerHostView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GameLayerHostView) {
        view.bufferSize = bufferSize
        view.aspectRatio = aspectRatio
        view.onTouch = onTouch
        view.onResize = onResize
    }
}

/// A view that shows a game layer at its full size.
///
/// Touches on it are mapped into the picture and reported. On the Mac, AppKit
/// turns mouse clicks and drags into touches, so a mouse or trackpad drives the
/// same code as a finger does on iOS.
final class GameLayerHostView: UIView {

    private weak var gameLayer: CAMetalLayer?

    /// Called when the view's size changes, so the renderer can be told.
    var onResize: ((CGRect) -> Void)?

    /// The core's buffer size in pixels, read as a touch arrives.
    var bufferSize: () -> CGSize = { .zero }

    /// The shape the picture is shown in, read as a touch arrives.
    var aspectRatio: () -> CGFloat = { 1 }

    /// Steps of a touch, in buffer pixels.
    var onTouch: ((GameTouch) -> Void)?

    // MARK: - Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let point = bufferPoint(for: touch) else { return }
        onTouch?(.down(point))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let point = bufferPoint(for: touch) else { return }
        onTouch?(.moved(point))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?(.up)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onTouch?(.up)
    }

    private func bufferPoint(for touch: UITouch) -> CGPoint? {
        let size = bufferSize()
        let ratio = aspectRatio()

        guard size.width > 0, size.height > 0,
              ratio > 0, bounds.width > 0, bounds.height > 0
        else { return nil }

        // The layer fits the picture into this view with `.resizeAspect`, which
        // leaves bars on one axis. Map from the picture's rect, not the view's.
        let scale = min(bounds.width / (size.height * ratio), bounds.height / size.height)
        let picture = CGSize(width: size.height * ratio * scale, height: size.height * scale)
        let origin = CGPoint(x: bounds.midX - picture.width / 2, y: bounds.midY - picture.height / 2)

        let location = touch.location(in: self)
        let x = (location.x - origin.x) / picture.width * size.width
        let y = (location.y - origin.y) / picture.height * size.height

        guard x >= 0, y >= 0, x < size.width, y < size.height else { return nil }
        return CGPoint(x: x, y: y)
    }

    // MARK: - The layer

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.masksToBounds = true
    }

    func attach(layer gameLayer: CAMetalLayer) {
        self.gameLayer = gameLayer
        gameLayer.removeFromSuperlayer()
        self.layer.addSublayer(gameLayer)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let gameLayer, bounds.width > 0, bounds.height > 0 else { return }

        // The scale has to be set before the size: the layer recomputes its
        // drawable size from it.
        //
        // The layer's `bounds` is deliberately not set here. The helper owns
        // that — it sets `bounds` and then syncs the filter chain's drawable
        // size, and it skips both if the bounds already match. The layer has
        // `anchorPoint = .zero`, so the helper's bounds fills this view.
        gameLayer.contentsScale = window?.screen.scale ?? traitCollection.displayScale

        // Tell the renderer the new display size. This is what the macOS game
        // view does when it lays out.
        onResize?(bounds)
    }
}
