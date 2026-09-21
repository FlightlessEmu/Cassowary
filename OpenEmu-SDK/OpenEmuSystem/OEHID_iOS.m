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
 * @file OEHID_iOS.m
 * @abstract The side of the IOKit HID shim that stands in where IOKit cannot
 *   be used.
 *
 * @discussion This implements the handful of IOKit HID calls the shared
 *   OpenEmu code makes, backed by plain Foundation objects. The GameController
 *   bridge (`OEiOSGameControllerManager`) builds these objects from a
 *   `GCController` and hands them to the shared binding code, which then
 *   behaves exactly as it does on macOS.
 *
 *   Compiled on iOS and Mac Catalyst. On macOS the real IOKit framework
 *   provides all of this and nothing here is built.
 */

#import <TargetConditionals.h>

// The stand-in implementations are needed wherever IOKit cannot enumerate
// controllers. iOS has no IOKit; Mac Catalyst links it, but the sandbox blocks
// the HID user client, so a Catalyst app never sees a device through it. Both
// platforms take the GameController path instead — see
// `OEiOSGameControllerManager`. macOS proper keeps the real thing, and tvOS
// has no IOKit either, so it needs the same stand-ins as iOS.
#if TARGET_OS_IOS || TARGET_OS_TV

#import "OEHID_iOS.h"

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Property keys

#pragma mark - Backing objects

/// One HID element: a button, an axis, a hat switch, or a collection.
@interface _OEHIDElement : NSObject
@property(nonatomic) uint32_t usage;
@property(nonatomic) uint32_t usagePage;
@property(nonatomic) IOHIDElementType type;
@property(nonatomic) IOHIDElementCookie cookie;
@property(nonatomic, weak) _OEHIDElement *parent;
@property(nonatomic) CFIndex logicalMin;
@property(nonatomic) CFIndex logicalMax;
/// Extra properties set by the device parser (trigger flag, hat switch type).
@property(nonatomic, strong) NSMutableDictionary *properties;
@end

@implementation _OEHIDElement
- (instancetype)init
{
    if((self = [super init])) {
        _properties = [NSMutableDictionary dictionary];
        _logicalMin = 0;
        _logicalMax = 1;
    }
    return self;
}
@end

/// One value read from an element at a point in time.
@interface _OEHIDValue : NSObject
@property(nonatomic, strong) _OEHIDElement *element;
@property(nonatomic) uint64_t timestamp;
@property(nonatomic) CFIndex value;
@property(nonatomic) CFIndex length;
@end

@implementation _OEHIDValue
@end

/// One physical device, as the shared code sees it.
@interface _OEHIDDevice : NSObject
@property(nonatomic) uint32_t usage;
@property(nonatomic) uint32_t usagePage;
@property(nonatomic, strong) NSMutableDictionary *properties;
@property(nonatomic, strong) NSMutableArray<_OEHIDElement *> *elements;
@property(nonatomic) io_service_t service;
@end

@implementation _OEHIDDevice
- (instancetype)init
{
    if((self = [super init])) {
        _properties = [NSMutableDictionary dictionary];
        _elements = [NSMutableArray array];
    }
    return self;
}
@end

/// The IOHIDManager stand-in. It does not enumerate anything itself — the
/// GameController bridge does that and calls the registered callbacks.
@interface _OEHIDManager : NSObject
@property(nonatomic, strong) NSMutableArray *matching;
@property(nonatomic) void *matchingCallback;
@property(nonatomic) void *removalCallback;
@property(nonatomic) void *matchingContext;
@property(nonatomic) void *removalContext;
@end

@implementation _OEHIDManager
@end

#pragma mark - Small helpers

static inline _OEHIDElement *_element(IOHIDElementRef ref)
{
    return (__bridge _OEHIDElement *)ref;
}

static inline _OEHIDDevice *_device(IOHIDDeviceRef ref)
{
    return (__bridge _OEHIDDevice *)ref;
}

/// Convert an IOKit property key to an NSString.
///
/// Every caller passes a `CFStringRef`: either `CFSTR(kIOHID...)` or a
/// bridged `NSString` from the parser. The IOKit key constants are plain C
/// strings, so `@(kIOHID...)` is a key too — that spelling is only used
/// inside this file.
static inline NSString *_stringForKey(CFStringRef key)
{
    return key ? (__bridge NSString *)key : nil;
}

#pragma mark - Access

IOHIDAccessType IOHIDCheckAccess(IOHIDRequestType requestType)
{
    // iOS never asks the user for permission to read controller input. The
    // GameController framework only hands over controllers the user has
    // already paired or connected.
    return kIOHIDAccessTypeGranted;
}

bool IOHIDRequestAccess(IOHIDRequestType requestType)
{
    return YES;
}

#pragma mark - Element

IOHIDElementRef _Nullable OEHIDElementCreate(NSDictionary *properties)
{
    _OEHIDElement *e = [[_OEHIDElement alloc] init];
    e.usage     = [properties[@"usage"] unsignedIntValue];
    e.usagePage = [properties[@"usagePage"] unsignedIntValue];
    e.type      = [properties[@"type"] unsignedIntValue];
    e.cookie    = [properties[@"cookie"] unsignedIntValue];
    e.logicalMin = [properties[@"logicalMin"] integerValue];
    e.logicalMax = [properties[@"logicalMax"] integerValue];
    [e.properties addEntriesFromDictionary:properties];
    return (__bridge_retained IOHIDElementRef)e;
}

uint32_t IOHIDElementGetUsage(IOHIDElementRef element)        { return _element(element).usage; }
uint32_t IOHIDElementGetUsagePage(IOHIDElementRef element)    { return _element(element).usagePage; }
IOHIDElementType IOHIDElementGetType(IOHIDElementRef element) { return _element(element).type; }
IOHIDElementCookie IOHIDElementGetCookie(IOHIDElementRef element) { return _element(element).cookie; }
IOHIDElementRef _Nullable IOHIDElementGetParent(IOHIDElementRef element)
{
    _OEHIDElement *parent = _element(element).parent;
    return parent ? (__bridge IOHIDElementRef)parent : NULL;
}
CFIndex IOHIDElementGetLogicalMin(IOHIDElementRef element) { return _element(element).logicalMin; }
CFIndex IOHIDElementGetLogicalMax(IOHIDElementRef element) { return _element(element).logicalMax; }

CFTypeRef _Nullable IOHIDElementGetProperty(IOHIDElementRef element, CFStringRef key)
{
    return (__bridge CFTypeRef)_element(element).properties[_stringForKey(key)];
}

Boolean IOHIDElementSetProperty(IOHIDElementRef element, CFStringRef key, CFTypeRef value)
{
    NSMutableDictionary *props = _element(element).properties;
    NSString *k = _stringForKey(key);
    if(value == NULL)
        [props removeObjectForKey:k];
    else
        props[k] = (__bridge id)value;

    return YES;
}

#pragma mark - Value

IOHIDValueRef _Nullable IOHIDValueCreate(IOHIDElementRef element, uint64_t timestamp, CFIndex value)
{
    _OEHIDValue *v = [[_OEHIDValue alloc] init];
    v.element   = _element(element);
    v.timestamp = timestamp;
    v.value     = value;
    v.length    = 4;
    return (__bridge_retained IOHIDValueRef)v;
}

IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value)
{
    return (__bridge IOHIDElementRef)((_OEHIDValue *)(__bridge id)value).element;
}
CFIndex IOHIDValueGetIntegerValue(IOHIDValueRef value) { return ((_OEHIDValue *)(__bridge id)value).value; }
CFIndex IOHIDValueGetLength(IOHIDValueRef value)       { return ((_OEHIDValue *)(__bridge id)value).length; }
uint64_t IOHIDValueGetTimeStamp(IOHIDValueRef value)   { return ((_OEHIDValue *)(__bridge id)value).timestamp; }

#pragma mark - Device

IOHIDDeviceRef OEHIDDeviceCreate(NSDictionary *properties)
{
    _OEHIDDevice *d = [[_OEHIDDevice alloc] init];
    d.usage     = [properties[@"usage"] unsignedIntValue];
    d.usagePage = [properties[@"usagePage"] unsignedIntValue];
    [d.properties addEntriesFromDictionary:properties];
    return (__bridge_retained IOHIDDeviceRef)d;
}

void OEHIDDeviceAddElement(IOHIDDeviceRef device, IOHIDElementRef element)
{
    _OEHIDElement *e = _element(element);
    e.parent = nil;
    [_device(device).elements addObject:e];
}

CFTypeRef _Nullable IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key)
{
    return (__bridge CFTypeRef)_device(device).properties[_stringForKey(key)];
}

CFArrayRef _Nullable IOHIDDeviceCopyMatchingElements(IOHIDDeviceRef device, CFDictionaryRef _Nullable matching, IOOptionBits options)
{
    NSArray *all = _device(device).elements;
    if(matching == NULL)
        return (__bridge_retained CFArrayRef)[all copy];

    // OpenEmu matches on the element cookie and, when it partitions a device's
    // elements, on the usage page. Both have to be honoured or the parser sees
    // every element in every partition.
    NSDictionary *criteria = (__bridge NSDictionary *)matching;
    NSNumber *cookie = criteria[@(kIOHIDElementCookieKey)];
    NSNumber *usagePage = criteria[@(kIOHIDElementUsagePageKey)];

    if(cookie == nil && usagePage == nil)
        return (__bridge_retained CFArrayRef)[all copy];

    NSMutableArray *filtered = [NSMutableArray array];
    for(_OEHIDElement *e in all) {
        if(cookie != nil && e.cookie != cookie.unsignedIntValue)
            continue;
        if(usagePage != nil && e.usagePage != usagePage.unsignedIntValue)
            continue;
        [filtered addObject:e];
    }
    return (__bridge_retained CFArrayRef)filtered;
}

Boolean IOHIDDeviceConformsTo(IOHIDDeviceRef device, uint32_t usagePage, uint32_t usage)
{
    _OEHIDDevice *d = _device(device);
    if(d.usagePage == usagePage && d.usage == usage)
        return YES;

    // A device also "conforms to" the generic desktop pages of the elements it
    // exposes. The keyboard check in OEDeviceManager relies on this.
    for(_OEHIDElement *e in d.elements) {
        if(e.usagePage == usagePage && e.usage == usage)
            return YES;
    }
    return NO;
}

io_service_t IOHIDDeviceGetService(IOHIDDeviceRef device) { return _device(device).service; }
IOReturn IOHIDDeviceOpen(IOHIDDeviceRef device, IOOptionBits options)  { return kIOReturnSuccess; }
IOReturn IOHIDDeviceClose(IOHIDDeviceRef device, IOOptionBits options) { return kIOReturnSuccess; }

IOReturn IOHIDDeviceSetReport(IOHIDDeviceRef device, IOHIDReportType reportType, CFIndex reportID, const uint8_t *report, CFIndex reportLength)
{
    // Output reports are how force feedback and controller LEDs are driven.
    // The GameController framework does not expose those, so this is a no-op
    // that reports success so the shared code keeps running.
    return kIOReturnSuccess;
}

void IOHIDDeviceScheduleWithRunLoop(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode) {}
void IOHIDDeviceUnscheduleFromRunLoop(IOHIDDeviceRef device, CFRunLoopRef runLoop, CFStringRef runLoopMode) {}
void IOHIDDeviceSetInputValueMatchingMultiple(IOHIDDeviceRef device, CFArrayRef _Nullable multiple) {}
void IOHIDDeviceRegisterInputValueCallback(IOHIDDeviceRef device, IOHIDValueCallback _Nullable callback, void * _Nullable context) {}
void IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report, CFIndex reportLength, IOHIDReportCallback _Nullable callback, void * _Nullable context) {}
void IOHIDDeviceRegisterRemovalCallback(IOHIDDeviceRef device, IOHIDCallback _Nullable callback, void * _Nullable context) {}

#pragma mark - Manager

IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef _Nullable allocator, IOOptionBits options)
{
    return (__bridge_retained IOHIDManagerRef)[[_OEHIDManager alloc] init];
}

void IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef manager, CFArrayRef _Nullable multiple)
{
    _OEHIDManager *m = (__bridge _OEHIDManager *)manager;
    m.matching = multiple ? [(__bridge NSArray *)multiple mutableCopy] : [NSMutableArray array];
}

void IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef manager, IOHIDDeviceCallback _Nullable callback, void * _Nullable context)
{
    _OEHIDManager *m = (__bridge _OEHIDManager *)manager;
    m.matchingCallback = (void *)callback;
    m.matchingContext  = context;
}

void IOHIDManagerRegisterDeviceRemovalCallback(IOHIDManagerRef manager, IOHIDDeviceCallback _Nullable callback, void * _Nullable context)
{
    _OEHIDManager *m = (__bridge _OEHIDManager *)manager;
    m.removalCallback = (void *)callback;
    m.removalContext  = context;
}

void IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode) {}
void IOHIDManagerUnscheduleFromRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef runLoopMode) {}

NS_ASSUME_NONNULL_END

#endif /* TARGET_OS_IOS */
