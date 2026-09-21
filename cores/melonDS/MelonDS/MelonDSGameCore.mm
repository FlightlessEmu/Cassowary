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

// The OpenEmu side of melonDS.
//
// melonDS is built as a static library (see build-melonds-ios.sh) and driven
// here one frame at a time. The emulator hands the app a stacked picture of
// both screens and stereo samples from the SPU, and asks the app for the
// things only it knows: where saves go, whether the Rumble Pak should buzz,
// and when the console has shut down.

#import "MelonDSGameCore.h"

#import <OpenEmuBase/OEAudioBuffer.h>

#include "MelonDSHost.h"
#include "MelonDSPlatform.h"

#include "Args.h"
#include "GPU.h"
#include "NDS.h"
#include "NDSCart.h"
#include "Savestate.h"
#include "SPI_Firmware.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace
{

constexpr NSUInteger kScreenWidth = 256;
constexpr NSUInteger kScreenHeight = 192;
constexpr NSUInteger kBufferWidth = kScreenWidth;
constexpr NSUInteger kBufferHeight = kScreenHeight * 2;
constexpr double kSampleRate = 48000.0;

/// The DS refreshes its screens 59.8261 times a second.
constexpr double kFrameRate = 59.8260982880808;

/// One sample of the key mask per button; -1 means the button is not a keypad
/// key (the microphone and the lid are handled on their own).
int KeyBitForButton(OENDSButton button)
{
    switch (button)
    {
    case OENDSButtonA:      return 0;
    case OENDSButtonB:      return 1;
    case OENDSButtonSelect: return 2;
    case OENDSButtonStart:  return 3;
    case OENDSButtonRight:  return 4;
    case OENDSButtonLeft:   return 5;
    case OENDSButtonUp:     return 6;
    case OENDSButtonDown:   return 7;
    case OENDSButtonR:      return 8;
    case OENDSButtonL:      return 9;
    case OENDSButtonX:      return 10;
    case OENDSButtonY:      return 11;
    default:                return -1;
    }
}

} // namespace

@class MelonDSGameCore;

@interface MelonDSGameCore ()
- (void)saveMemoryChanged:(const melonDS::u8 *)data length:(melonDS::u32)length;
- (void)emulatorRequestedStop;
- (void)setRumble:(BOOL)on;
@end

namespace
{

/// Answers melonDS's platform callbacks and forwards the interesting ones to
/// the core object. The core owns this and hands it to `NDS` as its user data.
class Host final : public melonDS::MelonDSHost
{
public:
    explicit Host(MelonDSGameCore *core) : _core(core) {}

    void WriteNDSSave(const melonDS::u8 *savedata, melonDS::u32 savelen,
                      melonDS::u32 writeoffset, melonDS::u32 writelen) override
    {
        [_core saveMemoryChanged:savedata length:savelen];
    }

    void Stop(melonDS::Platform::StopReason reason) override
    {
        [_core emulatorRequestedStop];
    }

    void RumbleStart(melonDS::u32 millis) override
    {
        [_core setRumble:YES];
    }

    void RumbleStop() override
    {
        [_core setRumble:NO];
    }

private:
    __unsafe_unretained MelonDSGameCore *_core;
};

} // namespace

@implementation MelonDSGameCore
{
    std::unique_ptr<melonDS::NDS> _nds;
    std::unique_ptr<Host> _host;

    /// The picture the app asked us to fill, or our own buffer when the app
    /// has not offered one.
    void *_videoPointer;
    std::vector<melonDS::u32> _videoBuffer;

    /// The cartridge's save memory, which melonDS owns and writes in place.
    /// The pointer stays valid for as long as the cartridge is loaded, so
    /// flushing can read it directly instead of copying on every write.
    const melonDS::u8 *_savePointer;
    melonDS::u32 _saveLength;
    BOOL _saveDirty;
    NSUInteger _framesSinceSaveFlush;

    /// Input queued up on the app's thread, applied on the emulator's.
    std::mutex _inputLock;
    melonDS::u32 _keyMask;
    BOOL _lidClosed;
    BOOL _touchPressed;
    melonDS::u16 _touchX;
    melonDS::u16 _touchY;

    BOOL _stopRequested;
    NSString *_romName;

    /// Where samples are pulled for a frame.
    std::vector<melonDS::s16> _audioBuffer;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        _keyMask = 0xFFF; // every key up; the DS reports releases as ones
        _videoBuffer.resize(kBufferWidth * kBufferHeight);
        _audioBuffer.resize(8192 * 2);
    }
    return self;
}

- (void)dealloc
{
    // The emulator must not outlive the host that answers its callbacks.
    _nds.reset();
    _host.reset();
}

#pragma mark - Loading

- (BOOL)loadFileAtPath:(NSString *)path
{
    return [self loadFileAtPath:path error:NULL];
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    NSError *readError = nil;
    NSData *rom = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:&readError];
    if (rom == nil)
    {
        if (error != NULL)
            *error = readError;
        return NO;
    }

    _romName = path.lastPathComponent;

    melonDS::Platform::SetLocalDirectory([[self supportDirectoryPath] fileSystemRepresentation]);
    melonDS::Platform::SetLogLevel(melonDS::Platform::LogLevel::Warn);

    // Break down the previous game before standing up its replacement, so the
    // old emulator never points at a host that is already gone.
    _nds.reset();
    _host.reset();
    _host = std::make_unique<Host>(self);

    melonDS::NDSArgs args;
    args.OutputSampleRate = kSampleRate;
    [self loadBIOSInto:args];

    _nds = std::make_unique<melonDS::NDS>(std::move(args), (void *)_host.get());

    melonDS::NDSCart::NDSCartArgs cartArgs;
    NSData *save = [NSData dataWithContentsOfFile:[self batterySavePath]];
    if (save.length > 0)
    {
        cartArgs.SRAMLength = (melonDS::u32)save.length;
        cartArgs.SRAM = std::make_unique<melonDS::u8[]>(save.length);
        memcpy(cartArgs.SRAM.get(), save.bytes, save.length);
    }

    auto cart = melonDS::NDSCart::ParseROM((const melonDS::u8 *)rom.bytes, (melonDS::u32)rom.length,
                                           _host.get(), std::move(cartArgs));
    if (cart == nullptr)
    {
        if (error != NULL)
        {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{ NSLocalizedDescriptionKey: @"The DS ROM could not be read." }];
        }
        return NO;
    }

    _nds->SetNDSCart(std::move(cart));
    _nds->Reset();

    // Sound is resampled to what the app runs at, instead of the DS's own rate.
    _nds->SPU.SetOutputSampleRate(kSampleRate);

    if (_nds->NeedsDirectBoot())
        _nds->SetupDirectBoot(std::string(_romName.fileSystemRepresentation));

    _nds->Start();

    _savePointer = _nds->GetNDSSave();
    _saveLength = _nds->GetNDSSaveLength();
    _saveDirty = NO;
    _framesSinceSaveFlush = 0;

    return YES;
}

- (void)loadBIOSInto:(melonDS::NDSArgs &)args
{
    // A real BIOS and firmware image is optional: melonDS brings its own.
    // When the user has supplied dumps they live in the app's BIOS folder.
    NSData *arm9 = [self readBIOSFile:@"bios9.bin" length:0x1000];
    if (arm9 != nil)
    {
        auto image = std::make_unique<melonDS::ARM9BIOSImage>();
        memcpy(image->data(), arm9.bytes, arm9.length);
        args.ARM9BIOS = std::move(image);
    }

    NSData *arm7 = [self readBIOSFile:@"bios7.bin" length:0x4000];
    if (arm7 != nil)
    {
        auto image = std::make_unique<melonDS::ARM7BIOSImage>();
        memcpy(image->data(), arm7.bytes, arm7.length);
        args.ARM7BIOS = std::move(image);
    }

    NSData *firmware = [self readBIOSFile:@"firmware.bin" length:0];
    if (firmware != nil)
        args.Firmware = melonDS::Firmware((const melonDS::u8 *)firmware.bytes, (melonDS::u32)firmware.length);
}

- (nullable NSData *)readBIOSFile:(NSString *)name length:(NSUInteger)length
{
    NSFileManager *manager = NSFileManager.defaultManager;

    for (NSString *directory in @[ self.biosDirectoryPath ?: @"", self.supportDirectoryPath ?: @"" ])
    {
        if (directory.length == 0)
            continue;

        NSString *path = [directory stringByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data == nil)
            continue;

        if (length != 0 && data.length != length)
        {
            NSLog(@"[melonDS] ignoring %@: expected %lu bytes, found %lu",
                  path, (unsigned long)length, (unsigned long)data.length);
            continue;
        }

        return data;
    }

    return nil;
}

#pragma mark - Running

- (void)resetEmulation
{
    if (_nds != nullptr)
        _nds->Reset();
}

- (void)executeFrame
{
    if (_nds == nullptr)
        return;

    if (_stopRequested)
    {
        _stopRequested = NO;
        [self stopEmulation];
        return;
    }

    if (!_nds->IsRunning())
        return;

    [self applyInput];

    _nds->RunFrame();

    [self copyVideo];
    [self copyAudio];

    if (_saveDirty && ++_framesSinceSaveFlush >= 300)
        [self flushSave];
}

- (void)stopEmulation
{
    [self flushSave];
    [super stopEmulation];
}

- (void)applyInput
{
    std::lock_guard<std::mutex> guard(_inputLock);

    _nds->SetKeyMask(_keyMask);
    _nds->SetLidClosed(_lidClosed);

    if (_touchPressed)
        _nds->TouchScreen(_touchX, _touchY);
    else
        _nds->ReleaseScreen();
}

- (void)copyVideo
{
    melonDS::u32 *destination = _videoPointer != NULL ? (melonDS::u32 *)_videoPointer : _videoBuffer.data();

    const int frontBuffer = _nds->GPU.FrontBuffer;
    const melonDS::u32 *top = _nds->GPU.Framebuffer[frontBuffer][0].get();
    const melonDS::u32 *bottom = _nds->GPU.Framebuffer[frontBuffer][1].get();

    if (top == nullptr || bottom == nullptr)
        return;

    memcpy(destination, top, kScreenWidth * kScreenHeight * sizeof(melonDS::u32));
    memcpy(destination + kScreenWidth * kScreenHeight, bottom, kScreenWidth * kScreenHeight * sizeof(melonDS::u32));
}

- (void)copyAudio
{
    if (_nds->SPU.GetOutputSize() <= 0)
        return;

    const int frames = _nds->SPU.ReadOutput(_audioBuffer.data(), (int)(_audioBuffer.size() / 2));
    if (frames <= 0)
        return;

    [[self audioBufferAtIndex:0] write:_audioBuffer.data() maxLength:frames * 2 * sizeof(melonDS::s16)];
}

#pragma mark - Video

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(kBufferWidth, kBufferHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(kBufferWidth, kBufferHeight);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, kBufferWidth, kBufferHeight);
}

- (NSInteger)bytesPerRow
{
    return kBufferWidth * 4;
}

- (uint32_t)pixelFormat
{
    return OEPixelFormat_BGRA;
}

- (uint32_t)pixelType
{
    return OEPixelType_UNSIGNED_INT_8_8_8_8_REV;
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if (hint != NULL)
        _videoPointer = hint;

    return _videoPointer != NULL ? _videoPointer : _videoBuffer.data();
}

- (const void *)videoBuffer
{
    return _videoPointer != NULL ? _videoPointer : _videoBuffer.data();
}

#pragma mark - Sound

- (NSUInteger)channelCount
{
    return 2;
}

- (double)audioSampleRate
{
    return kSampleRate;
}

- (NSTimeInterval)frameInterval
{
    return kFrameRate;
}

#pragma mark - Saves

- (NSString *)batterySavePath
{
    NSString *name = _romName.stringByDeletingPathExtension ?: @"game";
    return [[[self batterySavesDirectoryPath] stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"sav"];
}

- (void)saveMemoryChanged:(const melonDS::u8 *)data length:(melonDS::u32)length
{
    _savePointer = data;
    _saveLength = length;
    _saveDirty = YES;
}

- (void)flushSave
{
    if (!_saveDirty || _savePointer == nullptr || _saveLength == 0)
        return;

    NSString *path = [self batterySavePath];
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];

    NSData *data = [NSData dataWithBytes:_savePointer length:_saveLength];
    if ([data writeToFile:path atomically:YES])
        _saveDirty = NO;
    else
        NSLog(@"[melonDS] could not write the save file at %@", path);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *_Nullable))block
{
    if (_nds == nullptr)
    {
        block(NO, nil);
        return;
    }

    melonDS::Savestate state;
    if (!state.Error)
        _nds->DoSavestate(&state);

    BOOL success = !state.Error;
    if (success)
    {
        NSData *data = [NSData dataWithBytes:state.Buffer() length:state.Length()];
        success = [data writeToFile:fileName atomically:YES];
    }

    block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain
                                                       code:OEGameCoreCouldNotSaveStateError
                                                   userInfo:nil]);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *_Nullable))block
{
    if (_nds == nullptr)
    {
        block(NO, nil);
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:fileName];
    if (data.length == 0)
    {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
                                      code:OEGameCoreCouldNotLoadStateError
                                  userInfo:nil]);
        return;
    }

    melonDS::Savestate state((void *)data.bytes, (melonDS::u32)data.length, false);
    const BOOL success = _nds->DoSavestate(&state) && !state.Error;

    if (success)
    {
        _savePointer = _nds->GetNDSSave();
        _saveLength = _nds->GetNDSSaveLength();
        _saveDirty = YES;
    }

    block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain
                                                       code:OEGameCoreCouldNotLoadStateError
                                                   userInfo:nil]);
}

#pragma mark - Input

- (oneway void)didPushNDSButton:(OENDSButton)button forPlayer:(NSUInteger)player
{
    if (button == OENDSButtonLid)
    {
        std::lock_guard<std::mutex> guard(_inputLock);
        _lidClosed = YES;
        return;
    }

    const int bit = KeyBitForButton(button);
    if (bit < 0)
        return;

    std::lock_guard<std::mutex> guard(_inputLock);
    _keyMask &= ~(1u << bit);
}

- (oneway void)didReleaseNDSButton:(OENDSButton)button forPlayer:(NSUInteger)player
{
    if (button == OENDSButtonLid)
    {
        std::lock_guard<std::mutex> guard(_inputLock);
        _lidClosed = NO;
        return;
    }

    const int bit = KeyBitForButton(button);
    if (bit < 0)
        return;

    std::lock_guard<std::mutex> guard(_inputLock);
    _keyMask |= (1u << bit);
}

- (oneway void)didTouchScreenPoint:(OEIntPoint)point
{
    std::lock_guard<std::mutex> guard(_inputLock);

    // The buffer stacks the top screen over the bottom one, and only the
    // bottom screen takes touches. A touch on the top screen is ignored.
    if (point.y < (NSInteger)kScreenHeight)
    {
        _touchPressed = NO;
        return;
    }

    NSInteger x = point.x;
    NSInteger y = point.y - (NSInteger)kScreenHeight;

    if (x < 0) x = 0;
    if (x > (NSInteger)kScreenWidth - 1) x = (NSInteger)kScreenWidth - 1;
    if (y < 0) y = 0;
    if (y > (NSInteger)kScreenHeight - 1) y = (NSInteger)kScreenHeight - 1;

    _touchPressed = YES;
    _touchX = (melonDS::u16)x;
    _touchY = (melonDS::u16)y;
}

- (oneway void)didReleaseTouch
{
    std::lock_guard<std::mutex> guard(_inputLock);
    _touchPressed = NO;
}

#pragma mark - Rumble

- (void)setRumble:(BOOL)on
{
    id<OEGameCoreDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(gameCore:didChangeRumble:forPlayer:)])
        [delegate gameCore:self didChangeRumble:on forPlayer:1];
}

- (void)emulatorRequestedStop
{
    _stopRequested = YES;
}

@end
