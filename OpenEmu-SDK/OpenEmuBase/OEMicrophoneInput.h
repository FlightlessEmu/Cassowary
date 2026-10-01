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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the main queue when a core starts or stops listening.
extern NSNotificationName const OEMicrophoneInputListeningDidChangeNotification;

/// The microphone, between the app and a core.
///
/// A core that emulates a microphone (the Nintendo DS) says when the game is
/// listening and reads samples from here. The app does the capturing, because
/// it owns the audio session: when a core starts listening it asks for the
/// microphone and appends what it hears, or sets `blowing` for a button that
/// stands in for blowing into it. Samples are signed 16-bit mono at
/// `sampleRate`.
@interface OEMicrophoneInput : NSObject

@property(class, readonly) OEMicrophoneInput *sharedInput;

/// The rate samples are appended and read at.
@property(class, readonly) double sampleRate;

/// Whether the running game is listening. Set by the core.
@property(atomic, readonly, getter=isListening) BOOL listening;

/// While true, reads return loud noise, which is what blowing into a
/// microphone sounds like to a game. Set by the app.
@property(atomic) BOOL blowing;

/// Called by the core when the game opens and closes its microphone.
- (void)startListening;
- (void)stopListening;

/// Called by the app with captured audio.
- (void)appendSamples:(const int16_t *)samples count:(NSUInteger)count;

/// Called by the core. Fills `buffer` with `maxCount` samples: noise while
/// blowing, what was captured otherwise, and silence where there is none.
/// Returns `maxCount`.
- (NSUInteger)readSamples:(int16_t *)buffer maxCount:(NSUInteger)maxCount;

@end

NS_ASSUME_NONNULL_END
