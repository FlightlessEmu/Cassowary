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

#if os(tvOS)

import GameController
import Foundation

/// Keeps tvOS from taking a game controller's buttons for itself.
///
/// On a TV the system uses a controller to move focus and to go back: B comes
/// out as "Back" and the d-pad walks the interface. The platform's answer is a
/// `GCEventViewController` at the root of the window, and it is all or
/// nothing — the same input cannot go to the interface and to the game at
/// once. So the controller is handed to the game while it is being played,
/// and back to tvOS the moment a menu comes up, or nothing on screen could be
/// selected.
///
/// The root has to be made by the scene delegate, not swapped in later: UIKit
/// will not adopt a view controller that is already the window's root.
@MainActor
enum ControllerCapture {

    /// The window's root, once the scene delegate has made it.
    static weak var root: GCEventViewController?

    /// True when the controller should drive the interface: no game running,
    /// or a game running with its controls on screen.
    static func setInterfaceActive(_ active: Bool) {
        guard let root, root.controllerUserInteractionEnabled != active else { return }
        root.controllerUserInteractionEnabled = active
        NSLog("[Cassowary] controller %@", active ? "back with tvOS" : "handed to the game")
    }
}

#endif
