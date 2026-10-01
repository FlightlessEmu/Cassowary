// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import "OEMicrophoneInput.h"
#import <os/lock.h>

NSNotificationName const OEMicrophoneInputListeningDidChangeNotification = @"OEMicrophoneInputListeningDidChangeNotification";

/// A second of audio: enough to ride out the gap between the app appending
/// and the core reading, short enough that old sound is not replayed.
static const NSUInteger OEMicrophoneBufferLength = 48000;

@implementation OEMicrophoneInput
{
    os_unfair_lock _lock;
    int16_t _buffer[OEMicrophoneBufferLength];
    NSUInteger _readPosition;
    NSUInteger _count;
    BOOL _listening;
}

+ (OEMicrophoneInput *)sharedInput
{
    static OEMicrophoneInput *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[OEMicrophoneInput alloc] init]; });
    return shared;
}

+ (double)sampleRate
{
    return 48000;
}

- (instancetype)init
{
    if ((self = [super init]))
        _lock = OS_UNFAIR_LOCK_INIT;
    return self;
}

- (BOOL)isListening
{
    os_unfair_lock_lock(&_lock);
    BOOL listening = _listening;
    os_unfair_lock_unlock(&_lock);
    return listening;
}

- (void)setListening:(BOOL)listening
{
    os_unfair_lock_lock(&_lock);
    BOOL changed = _listening != listening;
    _listening = listening;
    _count = 0;
    _readPosition = 0;
    os_unfair_lock_unlock(&_lock);

    if (!changed)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:OEMicrophoneInputListeningDidChangeNotification object:self];
    });
}

- (void)startListening { [self setListening:YES]; }
- (void)stopListening  { [self setListening:NO]; }

- (void)appendSamples:(const int16_t *)samples count:(NSUInteger)count
{
    os_unfair_lock_lock(&_lock);
    for (NSUInteger i = 0; i < count; i++) {
        NSUInteger end = (_readPosition + _count) % OEMicrophoneBufferLength;
        _buffer[end] = samples[i];
        if (_count < OEMicrophoneBufferLength)
            _count++;
        else
            // Full: the oldest sample makes room, so the game hears what is
            // being said now rather than a second ago.
            _readPosition = (_readPosition + 1) % OEMicrophoneBufferLength;
    }
    os_unfair_lock_unlock(&_lock);
}

- (NSUInteger)readSamples:(int16_t *)buffer maxCount:(NSUInteger)maxCount
{
    if (self.blowing) {
        for (NSUInteger i = 0; i < maxCount; i++)
            buffer[i] = (int16_t)arc4random_uniform(40000) - 20000;
        return maxCount;
    }

    os_unfair_lock_lock(&_lock);
    NSUInteger available = MIN(_count, maxCount);
    for (NSUInteger i = 0; i < available; i++)
        buffer[i] = _buffer[(_readPosition + i) % OEMicrophoneBufferLength];
    _readPosition = (_readPosition + available) % OEMicrophoneBufferLength;
    _count -= available;
    os_unfair_lock_unlock(&_lock);

    // The game expects a steady stream: silence where nothing was heard.
    for (NSUInteger i = available; i < maxCount; i++)
        buffer[i] = 0;
    return maxCount;
}

@end
