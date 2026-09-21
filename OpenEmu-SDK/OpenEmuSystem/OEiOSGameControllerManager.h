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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/*!
 * @class OEiOSGameControllerManager
 * @abstract Bridges GameController to OpenEmu's HID device model on iOS.
 *
 * @discussion iOS has no IOKit, so nothing enumerates controllers for
 *   `OEDeviceManager`. GameController reports the same elements a HID
 *   descriptor would, though, so this class builds one synthetic MFi
 *   extended gamepad per connected controller — the profile the system
 *   plugins' `Controller-Mappings.plist` files describe — and hands it to
 *   `OEHIDDeviceParser`. Input changes become the HID values that parser's
 *   device handler dispatches, which is exactly what a real device does.
 *
 *   The binding stack cannot tell the difference: `OESystemBindings` creates
 *   device bindings for the controller, the responder resolves its events to
 *   emulator keys, and the settings screen can remap it. Nothing happens on
 *   macOS or Mac Catalyst, where IOKit provides the devices.
 */
@interface OEiOSGameControllerManager : NSObject

@property (class, readonly) OEiOSGameControllerManager *sharedManager;

/// Begin watching GameController. Safe to call more than once.
- (void)start;

/// Stop watching and remove every synthetic device.
- (void)stop;

/// Hold the control with the given HID usage, for the automated test: a
/// simulator has no hardware controller, so this drives the same path a
/// controller input would. It never releases, which is what lets the test
/// screenshot show the held state.
- (void)holdControlWithUsage:(uint32_t)usage;

@end

NS_ASSUME_NONNULL_END
