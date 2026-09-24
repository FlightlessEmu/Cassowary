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

// The OpenEmu side of SwanStation.
//
// SwanStation is a libretro core (a GPL-3 fork of DuckStation), so the work
// splits in two: SwanStationLibretroBridge plays frontend to the core, and
// this class presents the result as an OEGameCore. The video path is the same
// one Mednafen uses: the core renders into a plain BGRA buffer, the engine
// copies it into a Metal texture. The GPU-heavy Metal work happens in the
// engine, not here.
#import "SwanStationGameCore.h"

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEGameCoreDisplayModes.h>

#include "SwanStationLibretroBridge.h"
#include <libretro.h>

#include <cstring>

// Input state. The app pushes button and stick changes in as they happen; the
// core pulls them from the libretro input callback while it runs, on the same
// thread, so plain statics are enough.
static uint32_t s_joypad[2];
// Each stick direction separately, as a 0..1 magnitude: OpenEmu sends the four
// directions as their own "buttons" rather than one signed axis. Converted to a
// single signed axis when the core asks. Order: left, right, up, down.
static float s_stick[2][2][4];

// Audio has to reach the ring buffer through a C callback, so the buffer is
// parked here for it.
static __strong id<OEAudioBuffer> s_audioBuffer = nil;

static void SwanStationAudioCallback(const int16_t *frames, size_t frameCount, void *userdata)
{
    if (s_audioBuffer == nil || frameCount == 0)
        return;

    // Interleaved stereo S16.
    [s_audioBuffer write:frames maxLength:frameCount * 2 * sizeof(int16_t)];
}

static uint32_t JoypadBitForID(unsigned id)
{
    // The ids the core advertises in its input descriptors, mapped back onto
    // OpenEmu's PlayStation buttons.
    switch (id)
    {
        case RETRO_DEVICE_ID_JOYPAD_UP:     return 1 << OEPSXButtonUp;
        case RETRO_DEVICE_ID_JOYPAD_DOWN:   return 1 << OEPSXButtonDown;
        case RETRO_DEVICE_ID_JOYPAD_LEFT:   return 1 << OEPSXButtonLeft;
        case RETRO_DEVICE_ID_JOYPAD_RIGHT:  return 1 << OEPSXButtonRight;
        case RETRO_DEVICE_ID_JOYPAD_B:      return 1 << OEPSXButtonCross;
        case RETRO_DEVICE_ID_JOYPAD_A:      return 1 << OEPSXButtonCircle;
        case RETRO_DEVICE_ID_JOYPAD_X:      return 1 << OEPSXButtonTriangle;
        case RETRO_DEVICE_ID_JOYPAD_Y:      return 1 << OEPSXButtonSquare;
        case RETRO_DEVICE_ID_JOYPAD_L:      return 1 << OEPSXButtonL1;
        case RETRO_DEVICE_ID_JOYPAD_L2:     return 1 << OEPSXButtonL2;
        case RETRO_DEVICE_ID_JOYPAD_L3:     return 1 << OEPSXButtonL3;
        case RETRO_DEVICE_ID_JOYPAD_R:      return 1 << OEPSXButtonR1;
        case RETRO_DEVICE_ID_JOYPAD_R2:     return 1 << OEPSXButtonR2;
        case RETRO_DEVICE_ID_JOYPAD_R3:     return 1 << OEPSXButtonR3;
        case RETRO_DEVICE_ID_JOYPAD_START:  return 1 << OEPSXButtonStart;
        case RETRO_DEVICE_ID_JOYPAD_SELECT: return 1 << OEPSXButtonSelect;
        default:                            return 0;
    }
}

static int16_t SwanStationInputState(unsigned port, unsigned device, unsigned index, unsigned id, void *userdata)
{
    if (port >= 2)
        return 0;

    // The core asks with its own subclass values (RETRO_DEVICE_PS_DUALSHOCK and
    // friends), but every subclass keeps its base device in the low byte.
    switch (device & 0xff)
    {
        case RETRO_DEVICE_JOYPAD:
            return (s_joypad[port] & JoypadBitForID(id)) ? 1 : 0;

        case RETRO_DEVICE_ANALOG:
        {
            if (index != RETRO_DEVICE_INDEX_ANALOG_LEFT && index != RETRO_DEVICE_INDEX_ANALOG_RIGHT)
                return 0;

            // libretro's Y axis grows downwards, and OpenEmu reports up and
            // down separately, so the axis is (down - up).
            const float *stick = s_stick[port][index - RETRO_DEVICE_INDEX_ANALOG_LEFT];
            float axis;
            if (id == RETRO_DEVICE_ID_ANALOG_X)
                axis = stick[1] - stick[0];
            else if (id == RETRO_DEVICE_ID_ANALOG_Y)
                axis = stick[3] - stick[2];
            else
                return 0;

            if (axis > 1.0f) axis = 1.0f;
            if (axis < -1.0f) axis = -1.0f;
            return (int16_t)(axis * 32767.0f);
        }

        default:
            return 0;
    }
}

@implementation SwanStationGameCore
{
    // The frame the engine reads. The core hands us a pointer to its own
    // buffer, which may be replaced or resized at any time, so the pixels are
    // copied out here once per frame.
    uint8_t *_frameBuffer;
    NSUInteger _frameBufferSize;
    // The buffer the engine handed over for this frame, and how big it is. The
    // engine uploads from the pointer it gave us and checks that it got the
    // same one back, so when it offers a buffer the frame is copied into that
    // instead of into one of ours.
    void *_videoBufferHint;
    NSUInteger _videoBufferHintSize;
    OEIntSize _frameSize;
    __strong id<MTLDevice> _metalDevice;
}

- (id)init
{
    if ((self = [super init]))
    {
        memset(s_joypad, 0, sizeof(s_joypad));
        memset(s_stick, 0, sizeof(s_stick));
        for (NSUInteger player = 0; player < 2; player++)
            for (NSUInteger stick = 0; stick < 2; stick++)
                for (NSUInteger axis = 0; axis < 4; axis++)
                    s_stick[player][stick][axis] = 0.0f;
    }

    return self;
}

- (void)dealloc
{
    s_audioBuffer = nil;
    free(_frameBuffer);
}

#pragma mark - Renderer

// Whether the game runs on the GPU. This is the core's reason to exist, so it
// is on unless it is turned off: set the `SwanStationMetalRenderer` user
// default to NO to fall back to software rendering.
- (BOOL)usesMetalRenderer
{
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:@"SwanStationMetalRenderer"];
    return (value == nil) ? YES : [value boolValue];
}

- (OEGameCoreRendering)gameCoreRendering
{
    return [self usesMetalRenderer] ? OEGameCoreRenderingMetal2 : [super gameCoreRendering];
}

- (void)createMetalTextureWithDevice:(id<MTLDevice>)device
{
    _metalDevice = device;
    SwanStationBridge::SetMetalDevice((__bridge void *)device);
}

- (id<MTLTexture>)metalTexture
{
    void *handle = SwanStationBridge::DisplayTextureHandle();
    return handle ? (__bridge id<MTLTexture>)handle : nil;
}

#pragma mark - Emulation

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    SwanStationBridge::SetMetalRendererEnabled([self usesMetalRenderer]);

    NSString *systemDirectory = self.biosDirectoryPath;
    NSString *saveDirectory = self.batterySavesDirectoryPath;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *directory in @[systemDirectory, saveDirectory])
    {
        if (![fileManager fileExistsAtPath:directory])
        {
            [fileManager createDirectoryAtPath:directory
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:NULL];
        }
    }

    SwanStationBridge::SetDirectories(systemDirectory.fileSystemRepresentation,
                                      saveDirectory.fileSystemRepresentation);

    if (!SwanStationBridge::Initialize())
    {
        if (error)
        {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{ NSLocalizedDescriptionKey : @"The PlayStation core would not start." }];
        }
        return NO;
    }

    if (!SwanStationBridge::LoadGame(path.fileSystemRepresentation))
    {
        if (error)
        {
            *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                         code:OEGameCoreCouldNotLoadROMError
                                     userInfo:@{ NSLocalizedDescriptionKey :
                                                     @"SwanStation could not load this disc image. A PlayStation BIOS "
                                                     @"(scph5500.bin, scph5501.bin or scph5502.bin) is needed in the "
                                                     @"BIOS folder." }];
        }
        return NO;
    }

    SwanStationBridge::SetAudioCallback(&SwanStationAudioCallback, NULL);
    SwanStationBridge::SetInputStateCallback(&SwanStationInputState, NULL);

    _frameSize = OEIntSizeMake(SwanStationBridge::DisplayWidth(), SwanStationBridge::DisplayHeight());

    return YES;
}

- (void)executeFrame
{
    SwanStationBridge::RunFrame();

    // Copy the core's frame into a buffer of our own. The bridge keeps the
    // pointer, width, height and pitch from the frame the core just finished.
    const void *pixels = SwanStationBridge::LastFramePixels();
    const NSUInteger width = SwanStationBridge::LastFrameWidth();
    const NSUInteger height = SwanStationBridge::LastFrameHeight();
    const NSUInteger pitch = SwanStationBridge::LastFramePitch();

    if (pixels == NULL || width == 0 || height == 0)
        return;

    const NSUInteger rowBytes = width * 2;  // RGB565, see the pixel format below
    const NSUInteger required = rowBytes * height;

    // Into the engine's buffer when it offered one, into ours otherwise.
    uint8_t *base = (_videoBufferHint != NULL) ? (uint8_t *)_videoBufferHint : _frameBuffer;
    NSUInteger capacity = (_videoBufferHint != NULL) ? _videoBufferHintSize : _frameBufferSize;

    if (_videoBufferHint == NULL && required > capacity)
    {
        uint8_t *resized = (uint8_t *)realloc(_frameBuffer, required);
        if (resized == NULL)
            return;

        _frameBuffer = resized;
        _frameBufferSize = required;
        base = _frameBuffer;
        capacity = _frameBufferSize;
    }

    // A PlayStation game can change resolution mid-frame, and the engine sizes
    // its buffer from the frame before this one. It resizes for the next
    // frame; this one is clipped rather than written past the end.
    const NSUInteger rowsThatFit = (rowBytes > 0) ? (capacity / rowBytes) : 0;
    const NSUInteger rowsToCopy = MIN(height, rowsThatFit);

    const uint8_t *source = (const uint8_t *)pixels;
    uint8_t *destination = base;
    for (NSUInteger row = 0; row < rowsToCopy; row++)
    {
        memcpy(destination, source, rowBytes);
        source += pitch;
        destination += rowBytes;
    }

    _frameSize = OEIntSizeMake((NSUInteger)width, (NSUInteger)height);
}

- (void)resetEmulation
{
    SwanStationBridge::Reset();
}

- (void)stopEmulation
{
    SwanStationBridge::SetAudioCallback(NULL, NULL);
    SwanStationBridge::SetInputStateCallback(NULL, NULL);
    SwanStationBridge::UnloadGame();

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return SwanStationBridge::FrameRate();
}

#pragma mark - Video

- (const void *)getVideoBufferWithHint:(void *)hint
{
    // The engine uploads from the buffer it hands over and expects the same
    // pointer back (see MTLGameRenderer's assertion), so the frame is copied
    // into it. It is sized from -bufferSize, which follows the core's own
    // frame size.
    if (hint != NULL)
    {
        _videoBufferHint = hint;
        _videoBufferHintSize = (NSUInteger)self.bufferSize.width * (NSUInteger)self.bufferSize.height * 2;
        return hint;
    }

    _videoBufferHint = NULL;
    _videoBufferHintSize = 0;
    return _frameBuffer;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, _frameSize.width, _frameSize.height);
}

- (OEIntSize)bufferSize
{
    if ([self usesMetalRenderer])
    {
        unsigned width = 0, height = 0;
        if (SwanStationBridge::DisplaySize(&width, &height))
            return OEIntSizeMake(width, height);
    }

    return _frameSize;
}

- (OEIntSize)aspectSize
{
    const OEIntSize size = self.bufferSize;
    const double aspect = SwanStationBridge::AspectRatio();
    if (aspect <= 0.0 || size.height == 0)
        return OEIntSizeMake(4, 3);

    return OEIntSizeMake((NSUInteger)(size.height * aspect), size.height);
}

- (uint32_t)pixelFormat
{
    // The software path hands over RGB565 (see SwanStationLibretroBridge.cpp
    // for why that is the only format it is allowed to use). The Metal path
    // renders RGBA8 into its own texture, which the engine samples directly.
    return [self usesMetalRenderer] ? OEPixelFormat_RGBA : OEPixelFormat_RGB;
}

- (uint32_t)pixelType
{
    return [self usesMetalRenderer] ? OEPixelType_UNSIGNED_INT_8_8_8_8 : OEPixelType_UNSIGNED_SHORT_5_6_5;
}

- (NSUInteger)bytesPerRow
{
    return [self usesMetalRenderer] ? (self.bufferSize.width * 4) : [super bytesPerRow];
}

#pragma mark - Audio

- (double)audioSampleRate
{
    return SwanStationBridge::SampleRate();
}

- (NSUInteger)channelCount
{
    return 2;
}

- (id<OEAudioBuffer>)audioBufferAtIndex:(NSUInteger)index
{
    id<OEAudioBuffer> buffer = [super audioBufferAtIndex:index];
    s_audioBuffer = buffer;
    return buffer;
}

#pragma mark - Save states

- (NSData *)serializeStateWithError:(NSError **)outError
{
    const size_t size = SwanStationBridge::SerializeSize();
    if (size == 0)
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreCouldNotSaveStateError
                                        userInfo:@{ NSLocalizedDescriptionKey : @"No game is running." }];
        }
        return nil;
    }

    NSMutableData *state = [NSMutableData dataWithLength:size];
    if (!SwanStationBridge::Serialize(state.mutableBytes, size))
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreCouldNotSaveStateError
                                        userInfo:@{ NSLocalizedDescriptionKey : @"The core refused to save state." }];
        }
        return nil;
    }

    return state;
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    if (!SwanStationBridge::Deserialize(state.bytes, state.length))
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain:OEGameCoreErrorDomain
                                            code:OEGameCoreStateHasWrongSizeError
                                        userInfo:@{ NSLocalizedDescriptionKey : @"This save state does not fit the "
                                                                                  @"running game." }];
        }
        return NO;
    }

    return YES;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    NSError *error = nil;
    NSData *state = [self serializeStateWithError:&error];
    if (state != nil)
        [state writeToFile:fileName options:NSDataWritingAtomic error:&error];

    block(state != nil, error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    NSError *error = nil;
    NSData *state = [NSData dataWithContentsOfFile:fileName options:0 error:&error];
    BOOL success = state != nil && [self deserializeState:state withError:&error];

    block(success, error);
}

#pragma mark - Input

- (oneway void)didPushPSXButton:(OEPSXButton)button forPlayer:(NSUInteger)player
{
    // Players are 1-based all the way down; the pad state is 0-based.
    if (player == 0 || player > 2 || button >= OEPSXButtonCount)
        return;

    s_joypad[player - 1] |= (1u << button);
}

- (oneway void)didReleasePSXButton:(OEPSXButton)button forPlayer:(NSUInteger)player
{
    if (player == 0 || player > 2 || button >= OEPSXButtonCount)
        return;

    s_joypad[player - 1] &= ~(1u << button);
}

- (oneway void)didMovePSXJoystickDirection:(OEPSXButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    if (player == 0 || player > 2)
        return;
    player -= 1;

    NSUInteger stick;
    NSUInteger axis;
    switch (button)
    {
        case OEPSXLeftAnalogLeft:   stick = 0; axis = 0; break;
        case OEPSXLeftAnalogRight:  stick = 0; axis = 1; break;
        case OEPSXLeftAnalogUp:     stick = 0; axis = 2; break;
        case OEPSXLeftAnalogDown:   stick = 0; axis = 3; break;
        case OEPSXRightAnalogLeft:  stick = 1; axis = 0; break;
        case OEPSXRightAnalogRight: stick = 1; axis = 1; break;
        case OEPSXRightAnalogUp:    stick = 1; axis = 2; break;
        case OEPSXRightAnalogDown:  stick = 1; axis = 3; break;
        default:                    return;
    }

    if (value < 0.0f) value = 0.0f;
    if (value > 1.0f) value = 1.0f;
    s_stick[player][stick][axis] = (float)value;
}

- (oneway void)mouseMovedAtPoint:(OEIntPoint)point {}
- (oneway void)leftMouseDownAtPoint:(OEIntPoint)point {}
- (oneway void)leftMouseUp {}
- (oneway void)rightMouseDownAtPoint:(OEIntPoint)point {}
- (oneway void)rightMouseUp {}

@end
