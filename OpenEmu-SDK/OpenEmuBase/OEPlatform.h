/*
 Copyright (c) 2026, OpenEmu Team

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

/*!
 * @header OEPlatform.h
 * @abstract Small platform differences shared by the host app, the SDK, and the
 *   cores.
 * @discussion OpenEmu was written for macOS. The iOS port keeps the same public
 *   interfaces but needs a handful of types that have a different name on each
 *   platform. Everything lives here so there is exactly one place to look.
 */

#ifndef OEPlatform_h
#define OEPlatform_h

#import <TargetConditionals.h>
#import <Foundation/Foundation.h>

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#elif TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#error "OpenEmu supports macOS and iOS"
#endif

/// The image type used for system icons and controller artwork.
/// `NSImage` on macOS, `UIImage` on iOS.
#if TARGET_OS_OSX
typedef NSImage OEPlatformImage;
#else
typedef UIImage OEPlatformImage;
#endif

/// macOS Foundation provides `NSSize`; iOS Foundation does not. Shared code
/// that talks about buffer sizes in platform terms (including MAME's headless
/// OSD header) uses it, so on iOS it is just another name for `CGSize`.
#if !TARGET_OS_OSX
typedef CGSize NSSize;
#endif

/// The event responder root class. macOS has `NSResponder`; iOS has
/// `UIResponder`. Shared code that needs to hang a category off the responder
/// chain — or that subclasses it — uses this name.
///
/// Note this is deliberately a macro rather than a `typedef`: the name is used
/// in `@interface Foo : OEResponder` and in `@implementation OEResponder (...)`,
/// and a typedef is not valid in either position.
#if TARGET_OS_OSX
#define OEResponder NSResponder
#else
#define OEResponder UIResponder
#endif

/// The keyboard event class. macOS delivers key events as `NSEvent`; iOS uses
/// `UIPress`. Shared code that only needs the type name uses this.
#if TARGET_OS_OSX
#define OEPlatformKeyEvent NSEvent
#else
#define OEPlatformKeyEvent UIPress
#endif

/// Keyboard modifier flags. Both platforms model these the same way, they just
/// use different type names.
#if TARGET_OS_OSX
typedef NSEventModifierFlags OEPlatformModifierFlags;
#else
typedef UIKeyModifierFlags OEPlatformModifierFlags;
#endif

/// A virtual key code. macOS uses `CGCharCode` from CoreGraphics; iOS has no
/// equivalent, so the type is just an unsigned 16-bit value there.
#if TARGET_OS_OSX
typedef CGCharCode OEPlatformVirtualKeyCode;
#else
typedef uint16_t OEPlatformVirtualKeyCode;
#endif

#pragma mark - Application lifecycle

/// Posted when the application is about to terminate. macOS spells this
/// `NSApplicationWillTerminateNotification`; iOS spells it
/// `UIApplicationWillTerminateNotification`. Shared code uses this name.
#if TARGET_OS_OSX
#define OEApplicationWillTerminateNotification NSApplicationWillTerminateNotification
#define OEApplicationWillResignActiveNotification NSApplicationWillResignActiveNotification
#define OEApplicationDidBecomeActiveNotification NSApplicationDidBecomeActiveNotification
#else
#define OEApplicationWillTerminateNotification UIApplicationWillTerminateNotification
#define OEApplicationWillResignActiveNotification UIApplicationWillResignActiveNotification
#define OEApplicationDidBecomeActiveNotification UIApplicationDidBecomeActiveNotification
#endif

/// The shared application object.
///
/// A function rather than a macro: a macro named after `NSApp` leaks into the
/// Swift-generated header for any ObjC interface that mentions it, and there it
/// collides with AppKit's own declaration.
static inline id _Nonnull OEPlatformApplication(void)
{
#if TARGET_OS_OSX
    return NSApp;
#else
    return UIApplication.sharedApplication;
#endif
}

#pragma mark - Mouse events

/// Mouse event types, matching AppKit's `NSEventType` for the cases OpenEmu
/// cares about. Defined here so iOS code can use the same names.
typedef NS_ENUM(NSInteger, OEPlatformMouseEventType) {
    OEPlatformMouseEventTypeLeftMouseDown  = 1,
    OEPlatformMouseEventTypeLeftMouseUp    = 2,
    OEPlatformMouseEventTypeRightMouseDown = 3,
    OEPlatformMouseEventTypeRightMouseUp   = 4,
    OEPlatformMouseEventTypeMouseMoved     = 5,
};

#if TARGET_OS_OSX
typedef NSEvent OEPlatformMouseEvent;
#else
typedef UIEvent OEPlatformMouseEvent;
#endif

/// Translate a platform event into the shared mouse event type.
static inline OEPlatformMouseEventType OEPlatformMouseEventTypeForEvent(OEPlatformMouseEvent * _Nonnull event)
{
#if TARGET_OS_OSX
    return (OEPlatformMouseEventType)event.type;
#else
    // iOS has no mouse, so the touch is treated as a left button. The app only
    // needs to know whether the touch began or ended.
    return event.type == UIEventTypeTouches
        ? OEPlatformMouseEventTypeLeftMouseDown
        : OEPlatformMouseEventTypeMouseMoved;
#endif
}

/// Convenience: build an image from data in a way that works on both platforms.
static inline OEPlatformImage * _Nullable OEPlatformImageWithData(NSData * _Nonnull data)
{
#if TARGET_OS_OSX
    return [[NSImage alloc] initWithData:data];
#else
    return [UIImage imageWithData:data];
#endif
}

/// Convenience: load a named image out of a bundle. `-[NSBundle imageForResource:]`
/// only exists on macOS, so on iOS the file is looked up by name and extension
/// and decoded from disk.
static inline OEPlatformImage * _Nullable OEPlatformImageNamedInBundle(NSBundle * _Nonnull bundle, NSString * _Nullable name)
{
    if(name.length == 0)
        return nil;

#if TARGET_OS_OSX
    return [bundle imageForResource:name];
#else
    // Plugins ship their artwork as an asset catalog, which is compiled into
    // Assets.car and looked up by name.
    UIImage *image = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
    if(image != nil)
        return image;

    // Fall back to a loose file, in case a plugin ships plain PNGs.
    NSString *base = [name stringByDeletingPathExtension];
    NSString *ext  = [name pathExtension];

    NSURL *url = ext.length > 0
        ? [bundle URLForResource:base withExtension:ext]
        : [bundle URLForResource:base withExtension:nil];

    if(url == nil) {
        for(NSString *candidateExt in @[@"png", @"jpg", @"jpeg"]) {
            url = [bundle URLForResource:base withExtension:candidateExt];
            if(url != nil) break;
        }
    }

    if(url == nil)
        return nil;

    NSData *data = [NSData dataWithContentsOfURL:url];
    return data != nil ? [UIImage imageWithData:data] : nil;
#endif
}

#endif /* OEPlatform_h */
