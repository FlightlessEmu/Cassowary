#pragma once

#include "Platform.h"
#include "types.h"

namespace melonDS
{

/// The callbacks our app answers for a running DS.
///
/// melonDS reaches the outside world through these hooks, which are handed to
/// `NDS` as its user data. Everything the core might need from the host lives
/// here, so the glue only has to implement this one interface.
///
/// The defaults do nothing, which is the right answer for the parts we have
/// not wired up yet (microphone, camera, multiplayer).
struct MelonDSHost
{
    virtual ~MelonDSHost() = default;

    // MARK: Saves

    /// The cartridge's save memory changed. `writeoffset` and `writelen` say
    /// which part of the full buffer was touched.
    virtual void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen) {}

    /// A slot-2 (GBA) save changed, same idea.
    virtual void WriteGBASave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen) {}

    /// The emulated DS changed its firmware (settings, wifi config).
    virtual void WriteFirmware(const Firmware& firmware, u32 writeoffset, u32 writelen) {}

    /// The DS clock was set. Nothing to do on iOS; the system clock wins.
    virtual void WriteDateTime(int year, int month, int day, int hour, int minute, int second) {}

    /// The console shut itself down by itself (power off, bad exception).
    virtual void Stop(Platform::StopReason reason) {}

    // MARK: Rumble Pak

    /// Start the rumble motor for `millis`.
    virtual void RumbleStart(u32 millis) {}

    /// Stop the rumble motor.
    virtual void RumbleStop() {}

    // MARK: Microphone

    virtual void MicStart() {}

    virtual void MicStop() {}

    /// Fill `data` with up to `maxlength` samples of signed 16-bit mono audio
    /// at 47.6 kHz. Return how many samples were written.
    virtual int MicReadInput(s16* data, int maxlength) { return 0; }

    // MARK: DSi camera

    virtual void CameraStart(int num) {}

    virtual void CameraStop(int num) {}

    /// Write one frame of `width` x `height` pixels into `frame`.
    virtual void CameraCaptureFrame(int num, u32* frame, int width, int height, bool yuv) {}

    // MARK: Local multiplayer

    /// A local wireless session started. `Wifi` calls these when no
    /// `MPInterface` is installed, so the host can drive the older path.
    virtual void MPBegin() {}

    virtual void MPEnd() {}

    virtual int MPSendPacket(u8* data, int len, u64 timestamp) { return -1; }

    virtual int MPRecvPacket(u8* data, u64* timestamp) { return -1; }

    virtual int MPSendCmd(u8* data, int len, u64 timestamp) { return -1; }

    virtual int MPSendReply(u8* data, int len, u64 timestamp, u16 aid) { return -1; }

    virtual int MPSendAck(u8* data, int len, u64 timestamp) { return -1; }

    virtual int MPRecvHostPacket(u8* data, u64* timestamp) { return -1; }

    virtual u16 MPRecvReplies(u8* data, u64 timestamp, u16 aidmask) { return 0; }

    // MARK: Wi-Fi (Nintendo WFC / online)

    /// Send one 802.3 frame out to the internet.
    virtual int NetSendPacket(u8* data, int len) { return -1; }

    /// Receive one 802.3 frame from the internet.
    virtual int NetRecvPacket(u8* data) { return -1; }
};

} // namespace melonDS
