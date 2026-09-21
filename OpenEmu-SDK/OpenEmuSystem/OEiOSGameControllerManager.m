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

#import "OEiOSGameControllerManager.h"

// The synthetic devices belong to the iOS port: everywhere else IOKit hands
// OEDeviceManager real devices to match.
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST

#import <GameController/GameController.h>
#import <math.h>

#import "OEControllerDescription.h"
#import "OEHIDDeviceHandler.h"
#import "OEHIDDeviceParser.h"
#import "OEDeviceManager_Internal.h"

NS_ASSUME_NONNULL_BEGIN

// GameController does not expose vendor or product IDs. The controller
// database has an entry for the generic MFi extended gamepad under these IDs
// (see Controller-Database.plist), which is how the parser finds the profile
// the system plugins describe.
static const NSUInteger OEiOSGameControllerVendorID  = 0;
static const NSUInteger OEiOSGameControllerProductID = 0;

/// One control of the MFi extended gamepad profile, in the order the
/// Controller-Database describes it.
typedef NS_ENUM(NSUInteger, OEGameControllerControl) {
    OEGameControllerControlButtonA = 0,
    OEGameControllerControlButtonB,
    OEGameControllerControlButtonX,
    OEGameControllerControlButtonY,
    OEGameControllerControlButtonL1,
    OEGameControllerControlButtonR1,
    OEGameControllerControlButtonL2,
    OEGameControllerControlButtonR2,
    OEGameControllerControlButtonHome,
    OEGameControllerControlDPadUp,
    OEGameControllerControlDPadDown,
    OEGameControllerControlDPadLeft,
    OEGameControllerControlDPadRight,
    OEGameControllerControlLeftAnalogX,
    OEGameControllerControlLeftAnalogY,
    OEGameControllerControlRightAnalogX,
    OEGameControllerControlRightAnalogY,
    OEGameControllerControlCount,
};

typedef struct {
    uint32_t usagePage;
    uint32_t usage;
    IOHIDElementType type;
    CFIndex logicalMin;
    CFIndex logicalMax;
} OEGameControllerElementSpec;

/// The elements a synthetic device exposes. A real controller's HID
/// descriptor would have these; the values are the ones
/// OEControllerGCExtendedGamepadProfile maps its controls to.
static const OEGameControllerElementSpec OEGameControllerControlElements[OEGameControllerControlCount] = {
    [OEGameControllerControlButtonA]        = { kHIDPage_Button,         1,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonB]        = { kHIDPage_Button,         2,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonX]        = { kHIDPage_Button,         3,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonY]        = { kHIDPage_Button,         4,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonL1]       = { kHIDPage_Button,         5,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonR1]       = { kHIDPage_Button,         6,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonL2]       = { kHIDPage_Button,         7,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonR2]       = { kHIDPage_Button,         8,               kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlButtonHome]     = { kHIDPage_Consumer,    kHIDUsage_Csmr_ACHome, kIOHIDElementTypeInput_Button, 0, 1 },
    [OEGameControllerControlDPadUp]         = { kHIDPage_GenericDesktop, kHIDUsage_GD_DPadUp,    kIOHIDElementTypeInput_Misc, 0, 1 },
    [OEGameControllerControlDPadDown]       = { kHIDPage_GenericDesktop, kHIDUsage_GD_DPadDown,  kIOHIDElementTypeInput_Misc, 0, 1 },
    [OEGameControllerControlDPadLeft]       = { kHIDPage_GenericDesktop, kHIDUsage_GD_DPadLeft,  kIOHIDElementTypeInput_Misc, 0, 1 },
    [OEGameControllerControlDPadRight]      = { kHIDPage_GenericDesktop, kHIDUsage_GD_DPadRight, kIOHIDElementTypeInput_Misc, 0, 1 },
    [OEGameControllerControlLeftAnalogX]    = { kHIDPage_GenericDesktop, kHIDUsage_GD_X,   kIOHIDElementTypeInput_Axis, -32768, 32767 },
    [OEGameControllerControlLeftAnalogY]    = { kHIDPage_GenericDesktop, kHIDUsage_GD_Y,   kIOHIDElementTypeInput_Axis, -32768, 32767 },
    [OEGameControllerControlRightAnalogX]   = { kHIDPage_GenericDesktop, kHIDUsage_GD_Z,   kIOHIDElementTypeInput_Axis, -32768, 32767 },
    [OEGameControllerControlRightAnalogY]   = { kHIDPage_GenericDesktop, kHIDUsage_GD_Rz,  kIOHIDElementTypeInput_Axis, -32768, 32767 },
};

/// One bridged controller: the device handler the parser built for it and the
/// element to dispatch each control's values through.
@interface OEGameControllerDevice : NSObject

@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong, nullable) OEHIDDeviceHandler *handler;
@property(nonatomic, strong) NSMutableArray<NSValue *> *elements;

@end

@implementation OEGameControllerDevice

- (IOHIDElementRef)elementForControl:(OEGameControllerControl)control
{
    if(control >= self.elements.count)
        return NULL;

    return (IOHIDElementRef)self.elements[control].pointerValue;
}

@end

@implementation OEiOSGameControllerManager
{
    NSMapTable<GCController *, OEGameControllerDevice *> *_devices;
    OEGameControllerDevice *_testDevice;
    NSUInteger _nextLocationID;
    BOOL _started;
}

+ (OEiOSGameControllerManager *)sharedManager
{
    static OEiOSGameControllerManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[OEiOSGameControllerManager alloc] init];
    });

    return manager;
}

- (instancetype)init
{
    if((self = [super init]))
    {
        _devices = [NSMapTable strongToStrongObjectsMapTable];
    }

    return self;
}

#pragma mark - Watching controllers

- (void)start
{
    if(_started) return;
    _started = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(controllerDidConnect:) name:GCControllerDidConnectNotification object:nil];
    [center addObserver:self selector:@selector(controllerDidDisconnect:) name:GCControllerDidDisconnectNotification object:nil];

    for(GCController *controller in [GCController controllers])
        [self connectController:controller];
}

- (void)stop
{
    if(!_started) return;
    _started = NO;

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    for(GCController *controller in [[_devices keyEnumerator] allObjects])
        [self disconnectController:controller];

    if(_testDevice != nil) {
        [self removeDevice:_testDevice];
        _testDevice = nil;
    }
}

- (void)controllerDidConnect:(NSNotification *)notification
{
    [self connectController:notification.object];
}

- (void)controllerDidDisconnect:(NSNotification *)notification
{
    [self disconnectController:notification.object];
}

#pragma mark - Connecting

- (void)connectController:(GCController *)controller
{
    if(![controller isKindOfClass:[GCController class]] || [_devices objectForKey:controller] != nil)
        return;

    GCExtendedGamepad *pad = controller.extendedGamepad;
    if(pad == nil)
    {
        // The micro gamepad and the older GCGamepad profile are not the MFi
        // extended gamepad the plugins describe, so there is nothing to map.
        NSLog(@"[Cassowary] gamepad %@ is not an extended gamepad; ignored", controller.vendorName ? : @"unknown");
        return;
    }

    OEGameControllerDevice *device = [self newDeviceNamed:controller.vendorName ? : @"MFi Extended Gamepad"];
    [_devices setObject:device forKey:controller];

    [self bindExtendedGamepad:pad toDevice:device];

    NSLog(@"[Cassowary] gamepad bridged: %@ (%lu controls, player %@)",
          device.name,
          (unsigned long)device.handler.controllerDescription.numberOfControls,
          @(device.handler.deviceIdentifier));
}

- (void)disconnectController:(GCController *)controller
{
    if(![controller isKindOfClass:[GCController class]])
        return;

    OEGameControllerDevice *device = [_devices objectForKey:controller];
    if(device == nil) return;

    [_devices removeObjectForKey:controller];
    [self unbindController:controller];
    [self removeDevice:device];

    NSLog(@"[Cassowary] gamepad removed: %@", device.name);
}

#pragma mark - The synthetic device

- (OEGameControllerDevice *)newDeviceNamed:(NSString *)name
{
    NSDictionary *properties = @{
        @"usagePage"                     : @(kHIDPage_GenericDesktop),
        @"usage"                         : @(kHIDUsage_GD_GamePad),
        @kIOHIDVendorIDKey               : @(OEiOSGameControllerVendorID),
        @kIOHIDProductIDKey              : @(OEiOSGameControllerProductID),
        @kIOHIDProductKey                : name,
        @kIOHIDManufacturerKey           : @"GameController",
        @kIOHIDLocationIDKey             : @(++_nextLocationID),
        @kIOHIDTransportKey              : @kIOHIDTransportBluetoothValue,
    };

    IOHIDDeviceRef deviceRef = IOHIDDeviceCreate(properties);
    OEGameControllerDevice *device = [[OEGameControllerDevice alloc] init];
    device.name = name;
    device.elements = [NSMutableArray arrayWithCapacity:OEGameControllerControlCount];

    for(NSUInteger index = 0; index < OEGameControllerControlCount; index++) {
        OEGameControllerElementSpec spec = OEGameControllerControlElements[index];
        NSDictionary *elementProperties = @{
            @"usagePage"  : @(spec.usagePage),
            @"usage"      : @(spec.usage),
            @"type"       : @(spec.type),
            @"cookie"     : @(index + 1),
            @"logicalMin" : @(spec.logicalMin),
            @"logicalMax" : @(spec.logicalMax),
        };

        IOHIDElementRef element = IOHIDElementCreate(elementProperties);
        IOHIDDeviceAddElement(deviceRef, element);
        [device.elements addObject:[NSValue valueWithPointer:element]];
        CFRelease(element);
    }

    OEHIDDeviceHandler *handler = [[OEHIDDeviceHandler deviceParser] deviceHandlerForIOHIDDevice:deviceRef];
    CFRelease(deviceRef); // the handler retained the device

    if(handler == nil || [handler connect] == NO) {
        NSLog(@"[Cassowary] could not build a device handler for %@", name);
        return device;
    }

    device.handler = handler;
    [[OEDeviceManager sharedDeviceManager] OE_addDeviceHandler:handler];

    return device;
}

- (void)removeDevice:(OEGameControllerDevice *)device
{
    if(device.handler == nil) return;

    [[OEDeviceManager sharedDeviceManager] OE_removeDeviceHandler:device.handler];
    device.handler = nil;
}

#pragma mark - GameController input

- (void)bindExtendedGamepad:(GCExtendedGamepad *)pad toDevice:(OEGameControllerDevice *)device
{
    [self bindButton:pad.buttonA control:OEGameControllerControlButtonA device:device];
    [self bindButton:pad.buttonB control:OEGameControllerControlButtonB device:device];
    [self bindButton:pad.buttonX control:OEGameControllerControlButtonX device:device];
    [self bindButton:pad.buttonY control:OEGameControllerControlButtonY device:device];

    [self bindButton:pad.leftShoulder control:OEGameControllerControlButtonL1 device:device];
    [self bindButton:pad.rightShoulder control:OEGameControllerControlButtonR1 device:device];
    [self bindButton:pad.leftTrigger control:OEGameControllerControlButtonL2 device:device];
    [self bindButton:pad.rightTrigger control:OEGameControllerControlButtonR2 device:device];

    if(@available(iOS 13.0, *)) {
        if(pad.buttonHome != nil)
            [self bindButton:pad.buttonHome control:OEGameControllerControlButtonHome device:device];
    }

    [self bindButton:pad.dpad.up control:OEGameControllerControlDPadUp device:device];
    [self bindButton:pad.dpad.down control:OEGameControllerControlDPadDown device:device];
    [self bindButton:pad.dpad.left control:OEGameControllerControlDPadLeft device:device];
    [self bindButton:pad.dpad.right control:OEGameControllerControlDPadRight device:device];

    [self bindAxis:pad.leftThumbstick.xAxis control:OEGameControllerControlLeftAnalogX device:device];
    [self bindAxis:pad.leftThumbstick.yAxis control:OEGameControllerControlLeftAnalogY device:device];
    [self bindAxis:pad.rightThumbstick.xAxis control:OEGameControllerControlRightAnalogX device:device];
    [self bindAxis:pad.rightThumbstick.yAxis control:OEGameControllerControlRightAnalogY device:device];
}

- (void)unbindController:(GCController *)controller
{
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if(pad == nil) return;

    pad.buttonA.valueChangedHandler = nil;
    pad.buttonB.valueChangedHandler = nil;
    pad.buttonX.valueChangedHandler = nil;
    pad.buttonY.valueChangedHandler = nil;
    pad.leftShoulder.valueChangedHandler = nil;
    pad.rightShoulder.valueChangedHandler = nil;
    pad.leftTrigger.valueChangedHandler = nil;
    pad.rightTrigger.valueChangedHandler = nil;
    if(@available(iOS 13.0, *)) {
        pad.buttonHome.valueChangedHandler = nil;
    }
    pad.dpad.up.valueChangedHandler = nil;
    pad.dpad.down.valueChangedHandler = nil;
    pad.dpad.left.valueChangedHandler = nil;
    pad.dpad.right.valueChangedHandler = nil;
    pad.leftThumbstick.xAxis.valueChangedHandler = nil;
    pad.leftThumbstick.yAxis.valueChangedHandler = nil;
    pad.rightThumbstick.xAxis.valueChangedHandler = nil;
    pad.rightThumbstick.yAxis.valueChangedHandler = nil;
}

- (void)bindButton:(GCControllerButtonInput *)button control:(OEGameControllerControl)control device:(OEGameControllerDevice *)device
{
    button.valueChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self dispatchControl:control value:(pressed ? 1 : 0) device:device];
    };
}

- (void)bindAxis:(GCControllerAxisInput *)axis control:(OEGameControllerControl)control device:(OEGameControllerDevice *)device
{
    axis.valueChangedHandler = ^(GCControllerAxisInput *axis, float value) {
        [self dispatchControl:control value:[self integerForAxisValue:value] device:device];
    };
}

- (CFIndex)integerForAxisValue:(float)value
{
    float clamped = MAX(-1.0f, MIN(1.0f, value));
    return (CFIndex)lrintf(clamped * 32767.0f);
}

- (void)dispatchControl:(OEGameControllerControl)control value:(CFIndex)value device:(OEGameControllerDevice *)device
{
    // The binding stack is main-thread only; GameController says nothing
    // about which thread it calls its handlers on.
    if(![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dispatchControl:control value:value device:device];
        });
        return;
    }

    OEHIDDeviceHandler *handler = device.handler;
    IOHIDElementRef element = [device elementForControl:control];
    if(handler == nil || element == NULL)
        return;

    IOHIDValueRef valueRef = IOHIDValueCreate(element, mach_absolute_time(), value);
    [handler dispatchEventWithHIDValue:valueRef];
    CFRelease(valueRef);
}

#pragma mark - Test support

- (void)holdControlWithUsage:(uint32_t)usage
{
    OEGameControllerDevice *device = [[_devices objectEnumerator] allObjects].firstObject;
    if(device == nil)
    {
        // A simulator without even its virtual gamepad: build one so the test
        // can still drive the binding stack.
        device = [self newDeviceNamed:@"MFi Extended Gamepad (test)"];
        _testDevice = device;
    }

    for(NSUInteger index = 0; index < OEGameControllerControlCount; index++) {
        if(OEGameControllerControlElements[index].usage != usage)
            continue;

        [self dispatchControl:(OEGameControllerControl)index value:1 device:device];
        NSLog(@"[Cassowary] test gamepad: usage %lu held on %@", (unsigned long)usage, device.name);
        return;
    }

    NSLog(@"[Cassowary] test gamepad: no control has usage %lu", (unsigned long)usage);
}

@end

NS_ASSUME_NONNULL_END

#else

@implementation OEiOSGameControllerManager

+ (OEiOSGameControllerManager *)sharedManager
{
    static OEiOSGameControllerManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[OEiOSGameControllerManager alloc] init];
    });

    return manager;
}

- (void)start {}
- (void)stop {}
- (void)holdControlWithUsage:(uint32_t)usage {}

@end

#endif
