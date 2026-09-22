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
 * @header OEHID_iOS.h
 * @abstract The small slice of IOKit's HID API that OpenEmu's shared code uses,
 *   re-declared so it can compile where IOKit is not available.
 *
 * @discussion OpenEmu's binding model is built around HID *elements*: the
 *   controller database describes a controller by the HID usage of each button
 *   and axis, and every event carries the usage it came from. iOS has no IOKit
 *   at all, and Mac Catalyst's sandbox blocks the HID user client, but
 *   GameController exposes exactly the same thing — `GCControllerElement` has
 *   `usage` and `usagePage` properties that report the same values the HID
 *   descriptor does.
 *
 *   So rather than rewrite the binding layer, this header plus `OEHID_iOS.m`
 *   implement just enough of the IOKit HID types and functions for the shared
 *   code to run unchanged. The types are opaque handles; the functions read
 *   properties out of a dictionary the GameController bridge fills in.
 *
 *   Nothing here is a general purpose IOKit replacement. It covers the calls
 *   the OpenEmu-SDK actually makes and no more.
 */

#ifndef OEHID_iOS_h
#define OEHID_iOS_h

#import <TargetConditionals.h>

// The real IOKit headers are used on macOS, where `OEDeviceManager`
// enumerates devices through IOKit itself, and on Mac Catalyst, where the
// system headers pull IOKit in anyway and the shim below has to be declared
// against the real types. Catalyst cannot *use* IOKit, though: the app runs
// sandboxed and the sandbox blocks the HID user client, so `OEDeviceManager`
// sees no devices. iOS has no IOKit at all. Those two platforms take the
// GameController bridge (`OEiOSGameControllerManager`) instead, which builds
// the devices from what GameController reports.
#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/usb/USBSpec.h>
#endif /* TARGET_OS_OSX || TARGET_OS_MACCATALYST */

#if !TARGET_OS_OSX

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#if !TARGET_OS_MACCATALYST
#import <OpenEmuSystem/OEHIDUsageTables_iOS.h>
#endif

NS_ASSUME_NONNULL_BEGIN

#if !TARGET_OS_MACCATALYST

// iOS has no IOKit at all: the stand-in types and declarations the shared code
// compiles against. Mac Catalyst gets the real ones from the IOKit headers
// above, because the system exposes them there.

#pragma mark - Types

/// Opaque handles. On iOS these are Objective-C objects underneath, but the
/// shared code only ever passes them around, so the opaque names are kept.
typedef struct __IOHIDDevice * IOHIDDeviceRef;
typedef struct __IOHIDElement * IOHIDElementRef;
typedef struct __IOHIDValue * IOHIDValueRef;
typedef struct __IOHIDManager * IOHIDManagerRef;
typedef struct __IOHIDQueue * IOHIDQueueRef;

typedef CFTypeRef IOHIDDeviceTypeRef;

/// Element cookies identify an element inside one device.
typedef uint32_t IOHIDElementCookie;
/// Element types, matching the IOKit values.
typedef uint32_t IOHIDElementType;
/// Report types, matching the IOKit values.
typedef uint32_t IOHIDReportType;
/// IOKit return codes.
typedef int32_t IOReturn;
typedef uint32_t io_service_t;
typedef uint32_t IOOptionBits;

enum {
    kIOReturnSuccess = 0,
};

enum {
    kIOHIDElementTypeInput_Misc      = 1,
    kIOHIDElementTypeInput_Button    = 2,
    kIOHIDElementTypeInput_Axis      = 3,
    kIOHIDElementTypeInput_ScanCodes = 4,
    kIOHIDElementTypeOutput          = 129,
    kIOHIDElementTypeFeature         = 257,
    kIOHIDElementTypeCollection      = 513,
};

enum {
    kIOHIDReportTypeInput  = 0,
    kIOHIDReportTypeOutput = 1,
    kIOHIDReportTypeFeature = 2,
};

/// Options passed to the open calls. iOS does not need them, but the shared
/// code passes them, so the names have to exist.
enum {
    kIOHIDOptionsTypeNone    = 0,
    kIOHIDOptionsTypeSeizeDevice = 0x01,
};

/// The callout types the registration functions take. They match IOKit's, so
/// the shared code's callbacks are the same on every platform.
typedef void (*IOHIDCallback)(void * _Nullable context, IOReturn result, void * _Nullable sender);
typedef void (*IOHIDReportCallback)(void * _Nullable context, IOReturn result, void * _Nullable sender, IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex reportLength);
typedef void (*IOHIDValueCallback)(void * _Nullable context, IOReturn result, void * _Nullable sender, IOHIDValueRef value);
typedef void (*IOHIDDeviceCallback)(void * _Nullable context, IOReturn result, void * _Nullable sender, IOHIDDeviceRef device);

#pragma mark - HID property keys

// A subset of IOKit's key constants. The string values match IOKit exactly so
// a dictionary that came from IOKit and one built by the iOS bridge are
// interchangeable.
//
// They are plain C strings, exactly as IOKit defines them, so that callers can
// wrap them in CFSTR() themselves.
#define kIOHIDDeviceUsagePageKey          "DeviceUsagePage"
#define kIOHIDDeviceUsageKey              "DeviceUsage"
#define kIOHIDVendorIDKey                 "VendorID"
#define kIOHIDProductIDKey                "ProductID"
#define kIOHIDProductKey                  "Product"
#define kIOHIDManufacturerKey             "Manufacturer"
#define kIOHIDSerialNumberKey             "SerialNumber"
#define kIOHIDLocationIDKey               "LocationID"
#define kIOHIDTransportKey                "Transport"
#define kIOHIDTransportUSBValue           "USB"
#define kIOHIDTransportBluetoothValue     "Bluetooth"
#define kIOHIDElementCookieKey            "ElementCookie"
#define kIOHIDElementUsageKey             "ElementUsage"
#define kIOHIDElementUsagePageKey         "ElementUsagePage"
#define kIOHIDElementTypeKey              "ElementType"

#pragma mark - USB property keys

#define kUSBInterfaceClass                "bInterfaceClass"
#define kUSBInterfaceNumber               "bInterfaceNumber"
#define kUSBHIDClass                      (3)

#pragma mark - Access

typedef enum {
    kIOHIDAccessTypeUnknown = 0,
    kIOHIDAccessTypeGranted = 1,
    kIOHIDAccessTypeDenied  = 2,
} IOHIDAccessType;

typedef enum {
    kIOHIDRequestTypeListenEvent = 0,
    kIOHIDRequestTypePostEvent   = 1,
} IOHIDRequestType;

/// On iOS controller input never needs a permission prompt, so this always
/// reports granted.
IOHIDAccessType IOHIDCheckAccess(IOHIDRequestType requestType);
bool IOHIDRequestAccess(IOHIDRequestType requestType);

#pragma mark - Element

uint32_t IOHIDElementGetUsage(IOHIDElementRef element);
uint32_t IOHIDElementGetUsagePage(IOHIDElementRef element);
IOHIDElementType IOHIDElementGetType(IOHIDElementRef element);
IOHIDElementCookie IOHIDElementGetCookie(IOHIDElementRef element);
IOHIDElementRef _Nullable IOHIDElementGetParent(IOHIDElementRef element);
CFIndex IOHIDElementGetLogicalMin(IOHIDElementRef element);
CFIndex IOHIDElementGetLogicalMax(IOHIDElementRef element);
CFTypeRef _Nullable IOHIDElementGetProperty(IOHIDElementRef element, CFStringRef key);
Boolean IOHIDElementSetProperty(IOHIDElementRef element, CFStringRef key, CFTypeRef value);

#pragma mark - Value

IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value);
CFIndex IOHIDValueGetIntegerValue(IOHIDValueRef value);
CFIndex IOHIDValueGetLength(IOHIDValueRef value);
uint64_t IOHIDValueGetTimeStamp(IOHIDValueRef value);

#pragma mark - Device

CFTypeRef _Nullable IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key);
CFArrayRef _Nullable IOHIDDeviceCopyMatchingElements(IOHIDDeviceRef device, CFDictionaryRef _Nullable matching, IOOptionBits options);
Boolean IOHIDDeviceConformsTo(IOHIDDeviceRef device, uint32_t usagePage, uint32_t usage);
io_service_t IOHIDDeviceGetService(IOHIDDeviceRef device);
IOReturn IOHIDDeviceOpen(IOHIDDeviceRef device, IOOptionBits options);
IOReturn IOHIDDeviceClose(IOHIDDeviceRef device, IOOptionBits options);
IOReturn IOHIDDeviceSetReport(IOHIDDeviceRef device, IOHIDReportType reportType, CFIndex reportID, const uint8_t *report, CFIndex reportLength);
void IOHIDDeviceScheduleWithRunLoop(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode);
void IOHIDDeviceUnscheduleFromRunLoop(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode);
void IOHIDDeviceSetInputValueMatchingMultiple(IOHIDDeviceRef device, CFArrayRef _Nullable multiple);
void IOHIDDeviceRegisterInputValueCallback(IOHIDDeviceRef device, IOHIDValueCallback _Nullable callback, void * _Nullable context);
void IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report, CFIndex reportLength, IOHIDReportCallback _Nullable callback, void * _Nullable context);
void IOHIDDeviceRegisterRemovalCallback(IOHIDDeviceRef device, IOHIDCallback _Nullable callback, void * _Nullable context);

#pragma mark - Manager

IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef _Nullable allocator, IOOptionBits options);
void IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef manager, CFArrayRef _Nullable multiple);
void IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef manager, IOHIDDeviceCallback _Nullable callback, void * _Nullable context);
void IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef manager, IOHIDDeviceCallback _Nullable callback, void * _Nullable context);
void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode);
void IOHIDManagerUnscheduleFromRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode);

#endif /* !TARGET_OS_MACCATALYST */

#pragma mark - The GameController bridge's constructors

// IOKit has no public way to build a device from a dictionary, which is what
// the GameController bridge needs. `OEHID_iOS.m` implements these on iOS and
// Mac Catalyst; macOS never builds them.
IOHIDDeviceRef OEHIDDeviceCreate(NSDictionary *properties);
IOHIDElementRef _Nullable OEHIDElementCreate(NSDictionary *properties);

/// Attach one element to a device. The device takes ownership.
void OEHIDDeviceAddElement(IOHIDDeviceRef device, IOHIDElementRef element);

IOHIDValueRef _Nullable IOHIDValueCreate(IOHIDElementRef element, uint64_t timestamp, CFIndex value);

NS_ASSUME_NONNULL_END

#endif /* !TARGET_OS_OSX */

#endif /* OEHID_iOS_h */
