# Builds melonDS's emulator core as a static library for iOS and Mac Catalyst.
#
# The plugin glue in this directory is compiled by the app's own Xcode project
# (MelonDS.xcodeproj), which Scripts/cassowary/build-melonds-ios.sh uses to
# produce the library. This project only builds the emulator, and it does so by
# including upstream's own src/CMakeLists.txt, so the source list stays where
# melonDS keeps it.
#
# The resulting archives are linked into the plugin bundle by
# Scripts/cassowary/build-core-ios.sh.

cmake_minimum_required(VERSION 3.16)

project(melonDS-ios C CXX)

# Mac Catalyst is a macOS build with the iOS ABI, so the JIT is only safe where
# the app carries the JIT entitlement: Catalyst and the Simulator. A device
# build falls back to the interpreter.
option(MELONDS_JIT "Build the ARM64 JIT recompiler" OFF)

# The settings melonDS's src/CMakeLists.txt expects its parent to provide.
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../cmake" ${CMAKE_MODULE_PATH})

# Upstream detects this from a compiler check against the root project; we know
# what we are building for.
if (CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
    set(ARCHITECTURE ARM64)
endif()

set(ENABLE_OGLRENDERER OFF CACHE BOOL "The app draws through Metal, not OpenGL" FORCE)
set(ENABLE_GDBSTUB OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT ${MELONDS_JIT} CACHE BOOL "" FORCE)
set(ENABLE_JIT_PROFILING OFF CACHE BOOL "" FORCE)
set(MELONDS_EMBED_BUILD_INFO OFF CACHE BOOL "" FORCE)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" melonds-src)
