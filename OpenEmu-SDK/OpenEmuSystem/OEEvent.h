/*
 Copyright (c) 2012, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <OpenEmuBase/OEPlatform.h>

#import <OpenEmuBase/OpenEmuBase.h>

NS_ASSUME_NONNULL_BEGIN

@interface OEEvent : NSObject <NSSecureCoding>

/// Wraps a platform mouse event. macOS passes an `NSEvent`; iOS passes a
/// `UIGestureRecognizer`-driven touch, which the app reduces to the same two
/// facts the responder needs: where it happened and whether it went down or up.
- (instancetype)initWithMouseEvent:(OEPlatformMouseEvent *)event withLocationInGameView:(OEIntPoint)location NS_SWIFT_NAME(init(mouseEvent:locationInGameView:));

/// Builds a mouse event out of thin air, for touch screens that have no
/// `NSEvent` to wrap. The type says which part of the touch this is:
/// `OEPlatformMouseEventTypeLeftMouseDown` to press,
/// `OEPlatformMouseEventTypeMouseMoved` to drag a held touch, and
/// `OEPlatformMouseEventTypeLeftMouseUp` to lift it.
- (instancetype)initWithType:(OEPlatformMouseEventType)type withLocationInGameView:(OEIntPoint)location NS_SWIFT_NAME(init(type:locationInGameView:));

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) OEIntPoint locationInGameView;

/// The kind of mouse event. On iOS this is derived from the touch phase.
@property (nonatomic, readonly) OEPlatformMouseEventType type;

@end

NS_ASSUME_NONNULL_END
