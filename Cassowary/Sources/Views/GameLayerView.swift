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

/// Hosts the core's Metal layer inside SwiftUI.
///
/// The core renders into a `CAMetalLayer` it owns. This view puts that layer on
/// screen and tells the session how big the display area is, which is what the
/// renderer needs to size its drawable.
///
/// The layer itself is set to `contentsGravity = .resizeAspect`, so it centres
/// and fits the game inside whatever frame it is given. That keeps the aspect
/// ratio handling in one place, shared with the macOS app.
struct GameLayerView: UIViewRepresentable {

    let layer: CAMetalLayer
    let onResize: (CGRect) -> Void

    func makeUIView(context: Context) -> GameLayerHostView {
        let view = GameLayerHostView()
        view.backgroundColor = .black
        view.attach(layer: layer)
        view.onResize = onResize
        return view
    }

    func updateUIView(_ view: GameLayerHostView, context: Context) {
        view.onResize = onResize
    }
}

/// A view that shows a game layer at its full size.
final class GameLayerHostView: UIView {

    private weak var gameLayer: CAMetalLayer?

    /// Called when the view's size changes, so the renderer can be told.
    var onResize: ((CGRect) -> Void)?

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
