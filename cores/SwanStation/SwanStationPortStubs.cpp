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

// Stand-ins for the two parts of the core the iOS build leaves out, so the
// rest of the core links unchanged.
//
// 1. The OpenGL and Vulkan GPU backends. Apple platforms cannot load either
//    the way the core expects (Vulkan needs MoltenVK, and the iOS GL stack has
//    no GLES 3.1 core-profile entry points the backend uses), so the factory
//    returns an empty pointer. `System::CreateGPU` already treats that as
//    "fall back to the software renderer".
//
// 2. CHD disc images. libchdr brings its own zstd, lzma and miniz copies,
//    which is a lot of code to carry for a format most test discs do not use.
//    Dropping the implementation makes .chd files fail to open instead of
//    failing to link.
#include "core/gpu.h"
#include "common/cd_image.h"

std::unique_ptr<GPU> GPU::CreateHardwareOpenGLRenderer()
{
  return nullptr;
}

std::unique_ptr<GPU> GPU::CreateHardwareVulkanRenderer()
{
  return nullptr;
}

std::unique_ptr<CDImage> CDImage::OpenCHDImage(const char*, OpenFlags, Common::Error*)
{
  return nullptr;
}
