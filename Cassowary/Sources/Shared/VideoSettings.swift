// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation

/// The video settings every game launches with, whichever device it is on.
///
/// The phone's `GameView` and the TV's `TVPlayerView` used to apply these
/// independently: the filter arrived on the TV weeks after the phone, and the
/// upscaling switches never did. Both players call this now, so the next
/// video setting lands everywhere at once. The in-game menus still own the
/// pickers — this is only what a launch starts with.
///
/// Main actor, like the session and the catalogs it reads.
@MainActor
enum VideoSettings {

    /// Apply the filter and upscaling switches remembered for a system.
    ///
    /// The game starts unfiltered and the shader compiles once it is running,
    /// so a slow first compile never delays the launch.
    static func applySaved(to session: GameSession,
                           systemIdentifier: String?,
                           shaderCatalog: ShaderCatalog,
                           upscaling: UpscalingOptions) {
        let shader = shaderCatalog.shader(named: shaderCatalog.resolvedShaderName(forSystem: systemIdentifier))
        session.setShader(shader)
        session.setMetalFXUpscalingEnabled(upscaling.isEnabled(.metalFX, forSystem: systemIdentifier))
        session.setIntegerScalingEnabled(upscaling.isEnabled(.integerScaling, forSystem: systemIdentifier))
    }
}
