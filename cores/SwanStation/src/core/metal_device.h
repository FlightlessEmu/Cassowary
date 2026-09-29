// SPDX-FileCopyrightText: 2026 OpenEmu Team
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include <memory>

class HostDisplay;

/// The app's Metal device, and the display built on top of it.
///
/// The device is handed to the core by the app before the emulation thread
/// starts. It is parked here - in a plain C++ interface, with the Objective-C++
/// parts behind it - so the host interface can build the Metal display without
/// itself becoming an Objective-C++ file.
namespace MetalDevice {

/// Called from the app, with an `id<MTLDevice>`.
void SetDevice(void* device);

/// The device as an `id<MTLDevice>`, or nullptr if the app has not set one.
void* GetDevice();

bool HasDevice();

/// Creates the Metal host display. Defined in gpu_hw_metal.mm.
std::unique_ptr<HostDisplay> CreateHostDisplay();

} // namespace MetalDevice
