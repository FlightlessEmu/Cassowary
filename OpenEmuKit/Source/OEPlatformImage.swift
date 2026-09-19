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
import CoreAudio

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The image type the host app and the helper pass around.
///
/// `NSImage` on macOS, `UIImage` on iOS. The Objective-C side has the same
/// alias in `OpenEmuBase/OEPlatform.h`; this is the Swift spelling.
#if canImport(AppKit)
public typealias OEPlatformImage = NSImage
#elseif canImport(UIKit)
public typealias OEPlatformImage = UIImage
#endif

/// The responder root class the helper inherits from.
///
/// macOS uses `NSResponder` so the helper can sit in the responder chain. iOS
/// runs the helper in-process and has no use for that, so it inherits from
/// `NSObject` instead.
#if canImport(AppKit)
public typealias OEPlatformResponder = NSResponder
#else
public typealias OEPlatformResponder = NSObject
#endif

/// The application delegate protocol the helper conforms to.
#if canImport(AppKit)
public typealias OEPlatformApplicationDelegate = NSApplicationDelegate
#else
public typealias OEPlatformApplicationDelegate = NSObjectProtocol
#endif

/// The identifier of an audio output device.
///
/// `OEPlatformAudioDeviceID` is a macOS-only spelling. iOS has exactly one output, so the
/// type is kept for source compatibility and the value is always zero there.
#if canImport(AppKit)
public typealias OEPlatformAudioDeviceID = AudioDeviceID
#else
public typealias OEPlatformAudioDeviceID = UInt32
#endif

extension OEPlatformImage {
    /// Build an image from a `CGImage`, whichever platform this is.
    convenience init(cgImage: CGImage) {
#if canImport(AppKit)
        self.init(cgImage: cgImage, size: .zero)
#else
        self.init(cgImage: cgImage)
#endif
    }
}
