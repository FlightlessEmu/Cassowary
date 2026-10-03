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

import Foundation

import UIKit

/// The image type the host app and the helper pass around.
///
/// The Objective-C side has the same alias in `OpenEmuBase/OEPlatform.h`;
/// this is the Swift spelling.
public typealias OEPlatformImage = UIImage

/// The bitmap type the screenshot APIs return.
///
/// Separate from `OEPlatformImage` because the screenshot code needs
/// bitmap-specific behaviour — resizing and encoding.
public typealias OEPlatformBitmapImage = UIImage

/// The responder root class the helper inherits from.
///
/// The helper runs in-process and the app feeds it events directly, so it
/// inherits from `NSObject`.
public typealias OEPlatformResponder = NSObject

/// The application delegate protocol the helper conforms to.
public typealias OEPlatformApplicationDelegate = NSObjectProtocol

extension OEPlatformBitmapImage {
    /// Build a bitmap from a `CGImage`.
    convenience init(platformCGImage: CGImage) {
        self.init(cgImage: platformCGImage)
    }
}
