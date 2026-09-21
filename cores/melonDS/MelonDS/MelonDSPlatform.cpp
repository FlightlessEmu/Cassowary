/*
    Copyright 2016-2025 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

// The melonDS platform layer for this app.
//
// melonDS expects the frontend to provide file access, threads, network hooks
// and so on. This is the iOS/Catalyst answer to that: files go through stdio,
// the app's own directory answers "local" paths, and everything that only the
// app knows about (saves, rumble, stop requests, multiplayer) is forwarded to
// the MelonDSHost the core was created with.

#include "MelonDSPlatform.h"
#include "MelonDSHost.h"

#include "Platform.h"

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>

namespace melonDS::Platform
{

namespace
{
    std::string LocalDirectory;
    LogLevel MinimumLogLevel = LogLevel::Warn;

    /// When this process started, so the timers have a fixed epoch.
    const auto ProcessStart = std::chrono::steady_clock::now();

    /// The host for one core instance. The core hands it back on every call.
    MelonDSHost* Host(void* userdata)
    {
        return static_cast<MelonDSHost*>(userdata);
    }

    bool IsAbsolute(const std::string& path)
    {
        return !path.empty() && path[0] == '/';
    }

    /// fopen takes a mode string; translate melonDS's flags into one.
    std::string ModeString(FileMode mode, bool exists)
    {
        std::string result;

        const bool read = (mode & FileMode::Read) != 0;
        const bool write = (mode & FileMode::Write) != 0;
        const bool mustExist = (mode & FileMode::NoCreate) != 0 ||
                               ((mode & FileMode::Preserve) != 0 && exists);

        if (mode & FileMode::Append)
        {
            result = read ? "a+b" : "ab";
        }
        else if (!write)
        {
            result = read ? "rb" : "";
        }
        else if (mustExist)
        {
            // Keep the file's contents: open for update instead.
            result = read ? "r+b" : "r+b";
        }
        else
        {
            result = read ? "w+b" : "wb";
        }

        return result;
    }
}

void SetLocalDirectory(const std::string& path)
{
    LocalDirectory = path;
}

const std::string& GetLocalDirectory()
{
    return LocalDirectory;
}

void SetLogLevel(LogLevel level)
{
    MinimumLogLevel = level;
}

void SignalStop(StopReason reason, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->Stop(reason);
}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if ((mode & (FileMode::Read | FileMode::Write)) == FileMode::None)
    {
        Log(LogLevel::Error, "Attempted to open \"%s\" in neither read nor write mode (FileMode 0x%x)\n",
            path.c_str(), (unsigned) mode);
        return nullptr;
    }

    const std::string modeString = ModeString(mode, FileExists(path));

    if (modeString.empty())
        return nullptr;

    FILE* file = fopen(path.c_str(), modeString.c_str());
    if (file != nullptr)
        return reinterpret_cast<FileHandle*>(file);

    Log(LogLevel::Debug, "Failed to open \"%s\" (mode \"%s\")\n", path.c_str(), modeString.c_str());
    return nullptr;
}

std::string GetLocalFilePath(const std::string& filename)
{
    if (IsAbsolute(filename) || LocalDirectory.empty())
        return filename;

    return LocalDirectory + "/" + filename;
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(GetLocalFilePath(path), mode);
}

bool CloseFile(FileHandle* file)
{
    if (file == nullptr)
        return false;

    return fclose(reinterpret_cast<FILE*>(file)) == 0;
}

bool IsEndOfFile(FileHandle* file)
{
    return feof(reinterpret_cast<FILE*>(file)) != 0;
}

bool FileReadLine(char* str, int count, FileHandle* file)
{
    return fgets(str, count, reinterpret_cast<FILE*>(file)) != nullptr;
}

bool FileExists(const std::string& name)
{
    FileHandle* file = OpenFile(name, FileMode::Read);
    if (file == nullptr)
        return false;

    CloseFile(file);
    return true;
}

bool LocalFileExists(const std::string& name)
{
    return FileExists(GetLocalFilePath(name));
}

bool CheckFileWritable(const std::string& filepath)
{
    const bool existed = FileExists(filepath);

    FileHandle* file = OpenFile(filepath, FileMode::Write);
    if (file == nullptr)
        return false;

    CloseFile(file);

    // Do not leave an empty file behind just because we checked.
    if (!existed)
        unlink(filepath.c_str());

    return true;
}

bool CheckLocalFileWritable(const std::string& name)
{
    return CheckFileWritable(GetLocalFilePath(name));
}

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    int stdorigin;
    switch (origin)
    {
    case FileSeekOrigin::Start:   stdorigin = SEEK_SET; break;
    case FileSeekOrigin::Current: stdorigin = SEEK_CUR; break;
    case FileSeekOrigin::End:     stdorigin = SEEK_END; break;
    default:                      return false;
    }

    return fseeko(reinterpret_cast<FILE*>(file), (off_t) offset, stdorigin) == 0;
}

void FileRewind(FileHandle* file)
{
    rewind(reinterpret_cast<FILE*>(file));
}

u64 FilePosition(FileHandle* file)
{
    return (u64) ftello(reinterpret_cast<FILE*>(file));
}

u64 FileRead(void* data, u64 size, u64 count, FileHandle* file)
{
    return fread(data, size, count, reinterpret_cast<FILE*>(file));
}

bool FileFlush(FileHandle* file)
{
    return fflush(reinterpret_cast<FILE*>(file)) == 0;
}

u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file)
{
    return fwrite(data, size, count, reinterpret_cast<FILE*>(file));
}

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    if (fmt == nullptr)
        return 0;

    va_list args;
    va_start(args, fmt);
    const u64 result = vfprintf(reinterpret_cast<FILE*>(file), fmt, args);
    va_end(args);

    return result;
}

u64 FileLength(FileHandle* file)
{
    FILE* stream = reinterpret_cast<FILE*>(file);

    const off_t position = ftello(stream);
    if (position < 0)
        return 0;

    if (fseeko(stream, 0, SEEK_END) != 0)
        return 0;

    const off_t length = ftello(stream);
    fseeko(stream, position, SEEK_SET);

    return length < 0 ? 0 : (u64) length;
}

void Log(LogLevel level, const char* fmt, ...)
{
    if (fmt == nullptr || level < MinimumLogLevel)
        return;

    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    fputs("[melonDS] ", stderr);
    fputs(message, stderr);
}

struct Thread
{
    std::thread Handle;
    bool Finished = false;
};

Thread* Thread_Create(std::function<void()> func)
{
    Thread* thread = new Thread();
    thread->Handle = std::thread([thread, func]() {
        func();
        thread->Finished = true;
    });

    return thread;
}

void Thread_Free(Thread* thread)
{
    if (thread == nullptr)
        return;

    if (thread->Handle.joinable())
        thread->Handle.join();

    delete thread;
}

void Thread_Wait(Thread* thread)
{
    if (thread != nullptr && thread->Handle.joinable())
        thread->Handle.join();
}

struct Semaphore
{
    std::mutex Lock;
    std::condition_variable Signal;
    unsigned Count = 0;
};

Semaphore* Semaphore_Create()
{
    return new Semaphore();
}

void Semaphore_Free(Semaphore* sema)
{
    delete sema;
}

void Semaphore_Reset(Semaphore* sema)
{
    std::lock_guard<std::mutex> guard(sema->Lock);
    sema->Count = 0;
}

void Semaphore_Wait(Semaphore* sema)
{
    std::unique_lock<std::mutex> lock(sema->Lock);
    sema->Signal.wait(lock, [sema] { return sema->Count > 0; });
    sema->Count--;
}

bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    std::unique_lock<std::mutex> lock(sema->Lock);

    if (timeout_ms <= 0)
    {
        if (sema->Count == 0)
            return false;

        sema->Count--;
        return true;
    }

    const bool signalled = sema->Signal.wait_for(lock, std::chrono::milliseconds(timeout_ms),
                                                 [sema] { return sema->Count > 0; });
    if (!signalled)
        return false;

    sema->Count--;
    return true;
}

void Semaphore_Post(Semaphore* sema, int count)
{
    if (count <= 0)
        return;

    {
        std::lock_guard<std::mutex> guard(sema->Lock);
        sema->Count += (unsigned) count;
    }

    sema->Signal.notify_all();
}

struct Mutex
{
    std::mutex Lock;
};

Mutex* Mutex_Create()
{
    return new Mutex();
}

void Mutex_Free(Mutex* mutex)
{
    delete mutex;
}

void Mutex_Lock(Mutex* mutex)
{
    mutex->Lock.lock();
}

void Mutex_Unlock(Mutex* mutex)
{
    mutex->Lock.unlock();
}

bool Mutex_TryLock(Mutex* mutex)
{
    return mutex->Lock.try_lock();
}

void Sleep(u64 usecs)
{
    std::this_thread::sleep_for(std::chrono::microseconds(usecs));
}

u64 GetMSCount()
{
    const auto elapsed = std::chrono::steady_clock::now() - ProcessStart;
    return (u64) std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count();
}

u64 GetUSCount()
{
    const auto elapsed = std::chrono::steady_clock::now() - ProcessStart;
    return (u64) std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count();
}

void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->WriteNDSSave(savedata, savelen, writeoffset, writelen);
}

void WriteGBASave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->WriteGBASave(savedata, savelen, writeoffset, writelen);
}

void WriteFirmware(const Firmware& firmware, u32 writeoffset, u32 writelen, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->WriteFirmware(firmware, writeoffset, writelen);
}

void WriteDateTime(int year, int month, int day, int hour, int minute, int second, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->WriteDateTime(year, month, day, hour, minute, second);
}

void MP_Begin(void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->MPBegin();
}

void MP_End(void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->MPEnd();
}

int MP_SendPacket(u8* data, int len, u64 timestamp, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPSendPacket(data, len, timestamp) : -1;
}

int MP_RecvPacket(u8* data, u64* timestamp, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPRecvPacket(data, timestamp) : -1;
}

int MP_SendCmd(u8* data, int len, u64 timestamp, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPSendCmd(data, len, timestamp) : -1;
}

int MP_SendReply(u8* data, int len, u64 timestamp, u16 aid, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPSendReply(data, len, timestamp, aid) : -1;
}

int MP_SendAck(u8* data, int len, u64 timestamp, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPSendAck(data, len, timestamp) : -1;
}

int MP_RecvHostPacket(u8* data, u64* timestamp, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPRecvHostPacket(data, timestamp) : -1;
}

u16 MP_RecvReplies(u8* data, u64 timestamp, u16 aidmask, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MPRecvReplies(data, timestamp, aidmask) : 0;
}

int Net_SendPacket(u8* data, int len, void* userdata)
{
    return Host(userdata) ? Host(userdata)->NetSendPacket(data, len) : -1;
}

int Net_RecvPacket(u8* data, void* userdata)
{
    return Host(userdata) ? Host(userdata)->NetRecvPacket(data) : -1;
}

void Mic_Start(void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->MicStart();
}

void Mic_Stop(void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->MicStop();
}

int Mic_ReadInput(s16* data, int maxlength, void* userdata)
{
    return Host(userdata) ? Host(userdata)->MicReadInput(data, maxlength) : 0;
}

void Camera_Start(int num, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->CameraStart(num);
}

void Camera_Stop(int num, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->CameraStop(num);
}

void Camera_CaptureFrame(int num, u32* frame, int width, int height, bool yuv, void* userdata)
{
    if (frame == nullptr)
        return;

    if (MelonDSHost* host = Host(userdata))
        host->CameraCaptureFrame(num, frame, width, height, yuv);
    else
        memset(frame, 0, sizeof(u32) * (size_t) width * (size_t) height);
}

bool Addon_KeyDown(KeyType type, void* userdata)
{
    // The Guitar Grip and friends are not part of the on-screen controls.
    return false;
}

void Addon_RumbleStart(u32 len, void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->RumbleStart(len);
}

void Addon_RumbleStop(void* userdata)
{
    if (MelonDSHost* host = Host(userdata))
        host->RumbleStop();
}

float Addon_MotionQuery(MotionQueryType type, void* userdata)
{
    // No Motion Pak support yet; games that use one read zero.
    return 0.0f;
}

struct DynamicLibrary
{
    void* Handle = nullptr;
};

DynamicLibrary* DynamicLibrary_Load(const char* lib)
{
    if (lib == nullptr)
        return nullptr;

    void* handle = dlopen(lib, RTLD_LAZY);
    if (handle == nullptr)
        return nullptr;

    DynamicLibrary* result = new DynamicLibrary();
    result->Handle = handle;

    return result;
}

void DynamicLibrary_Unload(DynamicLibrary* lib)
{
    if (lib == nullptr)
        return;

    dlclose(lib->Handle);
    delete lib;
}

void* DynamicLibrary_LoadFunction(DynamicLibrary* lib, const char* name)
{
    if (lib == nullptr || name == nullptr)
        return nullptr;

    return dlsym(lib->Handle, name);
}

// MARK: - AAC decoding (DSi sound player)
//
// Not implemented: there is no AAC decoder in the app yet, and no DS game
// needs one. melonDS handles a missing decoder by logging and carrying on.

struct AACDecoder
{
};

AACDecoder* AAC_Init()
{
    return nullptr;
}

void AAC_DeInit(AACDecoder* dec)
{
}

bool AAC_Configure(AACDecoder* dec, int frequency, int channels)
{
    return false;
}

bool AAC_DecodeFrame(AACDecoder* dec, const void* input, int inputlen, void* output, int outputlen)
{
    return false;
}

} // namespace melonDS::Platform
