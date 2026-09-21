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

// This file is the glue between OpenEmu's OEGameCore and VirtualC64's
// embeddable emulator library (VCCore). The emulator runs on its own thread
// inside the core; OpenEmu drives it one frame at a time:
//
//   -executeFrame calls -wakeUp, waits for the texture's frame number to
//   advance, copies the pixels into the buffer OpenEmu handed us, and drains
//   one frame of audio into OpenEmu's ring buffer.
//
// That is the same model VirtualC64's own Mac app uses: the host pokes the
// emulator on each VSYNC and it computes whatever frames are due.

#import "VirtualC64GameCore.h"

#import <OpenEmuBase/OERingBuffer.h>
#import "OEC64SystemResponderClient.h"

#include "VirtualC64.h"
#include "C64.h"
#include "C64Key.h"
#include "Datasette.h"
#include "Emulator.h"
#include "JoystickTypes.h"
#include "utl/abilities/Compressible.h"

#include <cmath>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

using namespace vc64;

@interface VirtualC64GameCore () <OEC64SystemResponderClient>
- (void)handleMessage:(Message)msg;
@end

namespace {

// The emulator's texture is a fixed 520x312 texel frame buffer. The visible
// picture sits inside it with a border, exactly as the Mac app shows it.
constexpr NSUInteger kVCTextureWidth  = 520;
constexpr NSUInteger kVCTextureHeight = 312;

constexpr double kVCVoiceSampleRate = 44100.0;
constexpr double kVCPalFrameRate    = 50.125;

// How long -executeFrame waits for the emulator thread to finish a frame.
// 400 half-millisecond sleeps is 200 ms, far longer than a PAL frame.
constexpr NSUInteger kVCWaitTries = 400;
constexpr useconds_t kVCWaitStep   = 500;

// After power-on the KERNAL needs about three seconds to reach the READY
// prompt. Typing before that loses the keystrokes, so autostart typing is
// scheduled on the emulator's frame counter (150 frames at 50 Hz).
constexpr i64 kVCAutostartBootDelay = 150;

// After LOAD has been typed for a disk, RUN follows once the KERNAL has had
// time to load the first file: 5 seconds at 50 Hz.
constexpr NSInteger kVCAutostartRunDelay = 250;

// Maps a USB HID usage code to a key on the C64 keyboard. Cassowary sends HID
// usage codes from UIKey; on the Mac they arrive as NSEvent key codes, which
// the host converts before handing them to the core.
BOOL VCC64KeyForHIDUsage(NSUInteger usage, C64Key &key)
{
    switch (usage) {

        // Letters
        case 0x04: key = C64Key::A; return YES;
        case 0x05: key = C64Key::B; return YES;
        case 0x06: key = C64Key::C; return YES;
        case 0x07: key = C64Key::D; return YES;
        case 0x08: key = C64Key::E; return YES;
        case 0x09: key = C64Key::F; return YES;
        case 0x0A: key = C64Key::G; return YES;
        case 0x0B: key = C64Key::H; return YES;
        case 0x0C: key = C64Key::I; return YES;
        case 0x0D: key = C64Key::J; return YES;
        case 0x0E: key = C64Key::K; return YES;
        case 0x0F: key = C64Key::L; return YES;
        case 0x10: key = C64Key::M; return YES;
        case 0x11: key = C64Key::N; return YES;
        case 0x12: key = C64Key::O; return YES;
        case 0x13: key = C64Key::P; return YES;
        case 0x14: key = C64Key::Q; return YES;
        case 0x15: key = C64Key::R; return YES;
        case 0x16: key = C64Key::S; return YES;
        case 0x17: key = C64Key::T; return YES;
        case 0x18: key = C64Key::U; return YES;
        case 0x19: key = C64Key::V; return YES;
        case 0x1A: key = C64Key::W; return YES;
        case 0x1B: key = C64Key::X; return YES;
        case 0x1C: key = C64Key::Y; return YES;
        case 0x1D: key = C64Key::Z; return YES;

        // Digits
        case 0x1E: key = C64Key::digit1; return YES;
        case 0x1F: key = C64Key::digit2; return YES;
        case 0x20: key = C64Key::digit3; return YES;
        case 0x21: key = C64Key::digit4; return YES;
        case 0x22: key = C64Key::digit5; return YES;
        case 0x23: key = C64Key::digit6; return YES;
        case 0x24: key = C64Key::digit7; return YES;
        case 0x25: key = C64Key::digit8; return YES;
        case 0x26: key = C64Key::digit9; return YES;
        case 0x27: key = C64Key::digit0; return YES;

        // Editing and control
        case 0x28: key = C64Key::ret; return YES;
        case 0x29: key = C64Key::runStop; return YES;
        case 0x2A: key = C64Key::del; return YES;
        case 0x2B: key = C64Key::commodore; return YES;   // TAB has no C64 key
        case 0x2C: key = C64Key::space; return YES;
        case 0x39: key = C64Key::shiftLock; return YES;

        // Punctuation
        case 0x2D: key = C64Key::minus; return YES;
        case 0x2E: key = C64Key::equal; return YES;
        case 0x2F: key = C64Key::at; return YES;
        case 0x30: key = C64Key::asterisk; return YES;
        case 0x31: key = C64Key::pound; return YES;
        case 0x32: key = C64Key::pound; return YES;
        case 0x33: key = C64Key::semicolon; return YES;
        case 0x34: key = C64Key::colon; return YES;
        case 0x35: key = C64Key::leftArrow; return YES;
        case 0x36: key = C64Key::comma; return YES;
        case 0x37: key = C64Key::period; return YES;
        case 0x38: key = C64Key::slash; return YES;

        // Function keys. Each C64 key carries two functions (F1/F2, ...), so
        // both halves of a pair map onto the same physical key.
        case 0x3A: case 0x3B: key = C64Key::F1F2; return YES;
        case 0x3C: case 0x3D: key = C64Key::F3F4; return YES;
        case 0x3E: case 0x3F: key = C64Key::F5F6; return YES;
        case 0x40: case 0x41: key = C64Key::F7F8; return YES;

        // Navigation
        case 0x49: case 0x4A: key = C64Key::home; return YES;
        case 0x4C: key = C64Key::del; return YES;
        case 0x4F: case 0x50: key = C64Key::curLeftRight; return YES;
        case 0x51: case 0x52: key = C64Key::curUpDown; return YES;

        // Modifiers
        case 0xE0: key = C64Key::control; return YES;
        case 0xE1: key = C64Key::leftShift; return YES;
        case 0xE3: key = C64Key::commodore; return YES;
        case 0xE5: key = C64Key::rightShift; return YES;
        case 0xE7: key = C64Key::commodore; return YES;

        default: return NO;
    }
}

// The emulator reports state changes through this callback. Nothing here is
// required for normal play; it exists so shutdown and errors are visible.
void VirtualC64MessageCallback(const void *listener, Message msg)
{
    VirtualC64GameCore *core = (__bridge VirtualC64GameCore *)listener;
    [core handleMessage:msg];
}

} // namespace

@implementation VirtualC64GameCore
{
    // The emulator. Owned by this class, created in -loadFileAtPath:.
    VirtualC64 *_emu;

    // Where the video frame is copied to. OpenEmu hands us the pointer in
    // -getVideoBufferWithHint:.
    void *_videoBufferHint;

    // Scratch space for one frame of interleaved stereo float samples.
    std::vector<float> _audioScratch;

    // Frame timing, read from the emulator's VIC-II model.
    double _frameRate;
    NSUInteger _samplesPerFrame;

    // The emulator texture's frame number, so -executeFrame can wait for a
    // new one instead of racing the emulator thread.
    isize _lastFrameNumber;

    BOOL _running;
    BOOL _joysticksSwapped;
    BOOL _tapeWantsPlay;

    // Joystick state per physical control port, in VirtualC64's order:
    // up, down, left, right, fire.
    bool _pad[2][5];

    // Typing that has to wait until the emulator is powered on and booted.
    NSString *_pendingAutoType;
    NSString *_pendingFlashPath;
    NSInteger _pendingRunDelay;
    i64 _autoTypeFrame;
    i64 _runFrame;

    // C64 key numbers currently held down, so releases find the same key.
    NSMutableIndexSet *_pressedKeys;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _frameRate = kVCPalFrameRate;
        _samplesPerFrame = (NSUInteger)llround(kVCVoiceSampleRate / _frameRate);
        _lastFrameNumber = -1;
        _pendingRunDelay = -1;
        _pressedKeys = [NSMutableIndexSet indexSet];
    }
    return self;
}

- (void)dealloc
{
    [self tearDownEmulator];
}

- (void)handleMessage:(Message)msg
{
    switch (msg.type) {

        case Msg::ABORT:
            NSLog(@"[VirtualC64] the emulator requested shutdown");
            break;

        default:
            break;
    }
}

#pragma mark - Loading

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    [self tearDownEmulator];

    try {

        _emu = new VirtualC64();
        [self installRoms];

        // The emulator picks the frame rate from its VIC-II model, so ask it
        // once the machine is set up.
        double rate = _emu->c64.c64->refreshRate();
        _frameRate = (rate > 1.0) ? rate : kVCPalFrameRate;
        _samplesPerFrame = (NSUInteger)llround(kVCVoiceSampleRate / _frameRate);

        [self insertMediaAtPath:path];

    } catch (std::exception &exception) {

        NSString *reason = @(exception.what());
        NSLog(@"[VirtualC64] could not load %@: %@", path.lastPathComponent, reason);
        [self tearDownEmulator];

        if (error != NULL) {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{ NSLocalizedFailureReasonErrorKey: reason }];
        }
        return NO;
    }

    return YES;
}

/// Installs the C64 system ROMs.
///
/// User-supplied ROMs in the BIOS folder win, because the open ROMs are not a
/// 100% match for the originals and some software notices. Anything missing
/// falls back to the MEGA65 Open ROMs, which are compiled into the emulator.
- (void)installRoms
{
    NSURL *bios = self.biosDirectory;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    struct { RomType type; NSArray<NSString *> *names; } roms[] = {
        { RomType::KERNAL, @[ @"kernal", @"kernal.bin", @"kernal.rom" ] },
        { RomType::BASIC,  @[ @"basic", @"basic.bin", @"basic.rom" ] },
        { RomType::CHAR,   @[ @"chargen", @"chargen.bin", @"chargen.rom",
                              @"character", @"character.bin" ] },
        { RomType::VC1541, @[ @"1541", @"1541.bin", @"dos1541.bin",
                              @"1541-ii.bin", @"1541-II.bin" ] },
    };

    for (auto &rom : roms) {

        NSURL *found = nil;
        for (NSString *name in rom.names) {
            NSURL *candidate = [bios URLByAppendingPathComponent:name];
            if ([fileManager fileExistsAtPath:candidate.path]) {
                found = candidate;
                break;
            }
        }

        if (found != nil) {
            _emu->c64.loadRom(found.path.fileSystemRepresentation, rom.type);
        } else if (rom.type != RomType::VC1541) {
            // The 1541 drive ROM is copyrighted and has no open replacement,
            // so it is the one ROM that has to come from the user.
            _emu->c64.installOpenRom(rom.type);
        }
    }
}

- (void)insertMediaAtPath:(NSString *)path
{
    NSString *extension = path.pathExtension.lowercaseString;
    const char *file = path.fileSystemRepresentation;

    NSLog(@"[VirtualC64] inserting media: %@ (extension '%@')", path.lastPathComponent, extension);

    if ([@[ @"d64", @"d71", @"d81", @"g64", @"x64", @"t64", @"p00" ] containsObject:extension]) {

        _emu->drive8.insert(file, false);
        // Lowercase: the C64 boots in uppercase mode, where unshifted
        // letters print as capitals and Shift would give lowercase.
        _pendingAutoType = @"load\"*\",8,1\n";
        _pendingRunDelay = kVCAutostartRunDelay;

    } else if ([extension isEqualToString:@"tap"]) {

        _emu->datasette.insertTape(file);
        _pendingAutoType = @"load\n";
        _tapeWantsPlay = YES;

    } else if ([extension isEqualToString:@"crt"]) {

        _emu->expansionPort.attachCartridge(file, true);

    } else if ([extension isEqualToString:@"prg"]) {

        // Flashing copies the program into RAM at its load address. That has
        // to happen after power-on (power-on clears RAM), so it is deferred
        // to -startEmulation. RUN then gets it going. This mirrors what
        // VirtualC64's own app does with a .prg.
        _pendingFlashPath = [path copy];
        _pendingAutoType = @"run\n";

    } else {

        // Unknown extension: let the drive try, it accepts more formats than
        // the list above.
        _emu->drive8.insert(file, false);
        _pendingAutoType = @"LOAD\"*\",8,1\n";
        _pendingRunDelay = kVCAutostartRunDelay;
    }
}

#pragma mark - Lifecycle

- (void)setupEmulation
{
    // Nothing to prepare beyond what -loadFileAtPath: did.
}

- (void)startEmulation
{
    [super startEmulation];

    if (_emu == nullptr || _running) {
        return;
    }

    try {
        _emu->launch((__bridge const void *)self, VirtualC64MessageCallback);
        _emu->powerOn();
        _emu->run();
        _running = YES;

        if (_tapeWantsPlay) {
            _emu->datasette.datasette->pressPlay();
            _tapeWantsPlay = NO;
        }

        if (_pendingFlashPath != nil || _pendingAutoType != nil) {
            _autoTypeFrame = (i64)_emu->c64.c64->frame + kVCAutostartBootDelay;
        }

    } catch (std::exception &exception) {
        NSLog(@"[VirtualC64] could not start the emulator: %s", exception.what());
    }
}

- (void)stopEmulation
{
    [self tearDownEmulator];
    [super stopEmulation];
}

- (void)tearDownEmulator
{
    if (_emu != nullptr) {
        try {
            _emu->halt();
            _emu->emu->join();
        } catch (...) {
            // Halting is best effort; the thread also checks its state every
            // 50 ms, so a failure here does not leave it running.
        }
        delete _emu;
        _emu = nullptr;
    }

    _running = NO;
    _lastFrameNumber = -1;
}

- (void)resetEmulation
{
    if (_emu != nullptr) {
        _emu->hardReset();
    }
}

#pragma mark - Execution

- (void)executeFrame
{
    if (_emu == nullptr || !_running) {
        return;
    }

    try {
        // Let the emulator compute the frames it owes since the last wakeup.
        _emu->wakeUp();

        // Wait for the next finished frame. The texture's frame number only
        // moves when the emulator thread has swapped in a new stable buffer.
        [self waitForNewFrame];

        [self copyVideoFrame];
        [self copyAudioSamples];
        [self handlePendingTyping];

    } catch (std::exception &exception) {
        NSLog(@"[VirtualC64] frame failed: %s", exception.what());
    }
}

- (void)waitForNewFrame
{
    isize number = _lastFrameNumber;
    isize width = 0, height = 0;

    for (NSUInteger tries = 0; tries < kVCWaitTries; tries++) {

        _emu->videoPort.lockTexture();
        const u32 *texture = _emu->videoPort.getTexture(&number, &width, &height);
        _emu->videoPort.unlockTexture();

        if (texture != nullptr && number != _lastFrameNumber) {
            _lastFrameNumber = number;
            return;
        }

        usleep(kVCWaitStep);
    }
}

- (void)copyVideoFrame
{
    if (_videoBufferHint == nullptr) {
        return;
    }

    _emu->videoPort.lockTexture();
    const u32 *texture = _emu->videoPort.getTexture();
    if (texture != nullptr) {
        memcpy(_videoBufferHint, texture, kVCTextureWidth * kVCTextureHeight * sizeof(u32));
    }
    _emu->videoPort.unlockTexture();
}

- (void)copyAudioSamples
{
    if (_samplesPerFrame == 0) {
        return;
    }

    _audioScratch.resize(_samplesPerFrame * 2);
    isize copied = _emu->audioPort.copyInterleaved(_audioScratch.data(), (isize)_samplesPerFrame);

    if (copied > 0) {
        [[self audioBufferAtIndex:0] write:_audioScratch.data()
                                 maxLength:(NSUInteger)copied * 2 * sizeof(float)];
    }
}

/// Types the queued autostart text once the emulator has booted.
- (void)handlePendingTyping
{
    i64 frame = (i64)_emu->c64.c64->frame;

    if (_pendingAutoType != nil && frame >= _autoTypeFrame) {

        // The flash has to wait for the KERNAL: power-on clears RAM, and the
        // boot code sets up the BASIC pointers. Doing this earlier leaves a
        // corrupt program behind.
        if (_pendingFlashPath != nil) {
            NSLog(@"[VirtualC64] flashing %@", _pendingFlashPath.lastPathComponent);
            _emu->c64.flash(_pendingFlashPath.fileSystemRepresentation);
            _pendingFlashPath = nil;

            // flash() only sets VARTAB. A real KERNAL LOAD also points
            // ARYTAB and STREND at the end of the program; without that,
            // RUN fails on the stale pointers.
            u8 *ram = _emu->c64.c64->mem.ram;
            ram[0x2F] = ram[0x2D];
            ram[0x30] = ram[0x2E];
            ram[0x31] = ram[0x2D];
            ram[0x32] = ram[0x2E];
        }

        NSLog(@"[VirtualC64] typing %@", _pendingAutoType);
        _emu->keyboard.autoType(std::string(_pendingAutoType.UTF8String));
        _pendingAutoType = nil;

        if (_pendingRunDelay > 0) {
            _runFrame = frame + _pendingRunDelay;
            _pendingRunDelay = 0;
        }
    }

    if (_runFrame > 0 && frame >= _runFrame) {
        _emu->keyboard.autoType(std::string("run\n"));
        _runFrame = 0;
    }
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    _videoBufferHint = hint;
    return hint;
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(kVCTextureWidth, kVCTextureHeight);
}

- (OEIntRect)screenRect
{
    // VirtualC64 currently reports the whole texture as the visible area, so
    // the border is part of the picture for now.
    return OEIntRectMake(0, 0, kVCTextureWidth, kVCTextureHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(kVCTextureWidth, kVCTextureHeight);
}

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingBitmap;
}

- (uint32_t)pixelFormat
{
    // The emulator's texels are 0xRRGGBBAA in memory, which is what
    // OEPixelFormat_RGBA + OEPixelType_UNSIGNED_INT_8_8_8_8 describes.
    return OEPixelFormat_RGBA;
}

- (uint32_t)pixelType
{
    return OEPixelType_UNSIGNED_INT_8_8_8_8;
}

- (NSInteger)bytesPerRow
{
    return (NSInteger)kVCTextureWidth * sizeof(uint32_t);
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return kVCVoiceSampleRate;
}

- (NSUInteger)audioBitDepth
{
    // VirtualC64 hands out 32-bit float samples.
    return 32;
}

- (NSUInteger)channelCount
{
    return 2;
}

- (NSTimeInterval)frameInterval
{
    return _frameRate;
}

#pragma mark - Save states

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (_emu == nullptr) {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
                                      code:OEGameCoreCouldNotSaveStateError
                                  userInfo:nil]);
        return;
    }

    try {
        _emu->c64.saveSnapshot(fileName.fileSystemRepresentation, Compressor::LZ4);
        block(YES, nil);

    } catch (std::exception &exception) {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
                                      code:OEGameCoreCouldNotSaveStateError
                                  userInfo:@{ NSLocalizedFailureReasonErrorKey: @(exception.what()) }]);
    }
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    if (_emu == nullptr) {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
                                      code:OEGameCoreCouldNotLoadStateError
                                  userInfo:nil]);
        return;
    }

    try {
        _emu->c64.loadSnapshot(fileName.fileSystemRepresentation);
        block(YES, nil);

    } catch (std::exception &exception) {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain
                                      code:OEGameCoreCouldNotLoadStateError
                                  userInfo:@{ NSLocalizedFailureReasonErrorKey: @(exception.what()) }]);
    }
}

#pragma mark - Input

- (void)setJoystickState:(BOOL)state forButton:(OEC64Button)button player:(NSUInteger)player
{
    // The HID path passes 1-based players; the app's on-screen controls pass
    // 0 for player one. Fold both spellings onto 0 and 1.
    NSUInteger index = (player > 0) ? (player - 1) : 0;
    if (index > 1) {
        return;
    }

    // Which physical C64 control port this player talks to. The C64's two
    // ports are not interchangeable: older games read port 1, newer ones
    // port 2, which is why the system offers a swap.
    NSUInteger port = index;
    if (_joysticksSwapped) {
        port = 1 - port;
    }

    switch (button) {
        case OEC64JoystickUp:    _pad[port][0] = state; break;
        case OEC64JoystickDown:  _pad[port][1] = state; break;
        case OEC64JoystickLeft:  _pad[port][2] = state; break;
        case OEC64JoystickRight: _pad[port][3] = state; break;
        case OEC64ButtonFire:    _pad[port][4] = state; break;
        // The C64 has no second joystick button in its standard ports. Some
        // games read one from the paddle lines, which VirtualC64 does not
        // expose, so JUMP does nothing.
        case OEC64ButtonJump:    return;
        case OEC64SwapJoysticks: return;
        default: return;
    }

    [self applyJoystickStateForPort:port];
}

- (void)applyJoystickStateForPort:(NSUInteger)port
{
    JoystickAPI &joystick = (port == 0) ? _emu->controlPort1.joystick : _emu->controlPort2.joystick;

    bool state[5];
    for (NSUInteger i = 0; i < 5; i++) {
        state[i] = _pad[port][i];
    }
    joystick.trigger(state);
}

- (oneway void)didPushC64Button:(OEC64Button)button forPlayer:(NSUInteger)player
{
    [self setJoystickState:YES forButton:button player:player];
}

- (oneway void)didReleaseC64Button:(OEC64Button)button forPlayer:(NSUInteger)player
{
    [self setJoystickState:NO forButton:button player:player];
}

- (oneway void)swapJoysticks
{
    if (_emu == nullptr) {
        return;
    }

    _joysticksSwapped = !_joysticksSwapped;

    // Re-apply both ports so held directions follow their player.
    [self applyJoystickStateForPort:0];
    [self applyJoystickStateForPort:1];
}

- (oneway void)keyDown:(NSUInteger)keyCode
{
    if (_emu == nullptr) {
        return;
    }

    C64Key key;
    if (!VCC64KeyForHIDUsage(keyCode, key)) {
        return;
    }

    _emu->keyboard.press(key);
    [_pressedKeys addIndex:(NSUInteger)key.nr];
}

- (oneway void)keyUp:(NSUInteger)keyCode
{
    if (_emu == nullptr) {
        return;
    }

    C64Key key;
    if (!VCC64KeyForHIDUsage(keyCode, key)) {
        return;
    }

    _emu->keyboard.release(key);
    [_pressedKeys removeIndex:(NSUInteger)key.nr];
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)point
{
    // The C64 mouse (1350/1351) is not wired up yet.
}

- (oneway void)leftMouseDownAtPoint:(OEIntPoint)point
{
}

- (oneway void)leftMouseUp
{
}

- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point
{
}

- (oneway void)rightMouseUp
{
}

@end
