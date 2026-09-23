// Copyright (c) 2022, OpenEmu Team
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

import Foundation
import Metal

public class PixelBuffer {
    let device: MTLDevice
    public let format: OEMTLPixelFormat
    let bpp: Int // bytes per pixel
    
    let sourceBytesPerRow: Int
    let sourceBuffer: MTLBuffer
    public let sourceSize: CGSize
    public var outputRect: CGRect = .zero {
        didSet {
            // short copy if the buffer > 1MB and were copying < 50% of the buffer.
            shortCopy = bufferLenBytes > 1000000 && Int(outputRect.width) * bpp * Int(outputRect.height) <= bufferLenBytes / 2
        }
    }

    public let contents: UnsafeMutableRawPointer
    
    // for unaligned buffers
    let buffer: UnsafeMutableRawPointer
    let bufferLenBytes: Int
    let bufferFree: Bool
    var shortCopy: Bool = false
    
    // swiftformat:disable consecutiveSpaces redundantSelf
    private init(withDevice device: MTLDevice, format: OEMTLPixelFormat, height: Int, bytesPerRow: Int, pointer: UnsafeMutableRawPointer?) {
        let length = height * bytesPerRow
        
        self.device             = device
        self.format             = format
        self.bpp                = format.bytesPerPixel
        self.sourceBytesPerRow  = bytesPerRow
        self.sourceSize         = .init(width: bytesPerRow / bpp, height: height)
        self.bufferLenBytes     = length
        self.sourceBuffer       = device.makeBuffer(length: length, options: .storageModeShared)!
        
        if let pointer {
            buffer      = pointer
            bufferFree  = false
        } else {
            buffer      = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 256)
            bufferFree  = true
        }
        
        contents = buffer
    }
    
    // swiftformat:enable all
    
    deinit {
        if bufferFree {
            buffer.deallocate()
        }
    }
    
    func copyBuffer() {
        if shortCopy {
            var src = buffer
            var dst = sourceBuffer.contents()
            let rowLen = Int(outputRect.width) * bpp

            if outputRect.origin != .zero {
                let offset = (Int(outputRect.origin.y) * sourceBytesPerRow) + (Int(outputRect.origin.x) * bpp)
                src += offset
                dst += offset
            }

            for _ in 0..<Int(outputRect.height) {
                dst.copyMemory(from: src, byteCount: rowLen)
                src += sourceBytesPerRow
                dst += sourceBytesPerRow
            }
        } else {
            sourceBuffer.contents().copyMemory(from: buffer, byteCount: bufferLenBytes)
        }
    }
    
    // MARK: - Internal APIs

    public func prepare(withCommandBuffer commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
        fatalError("not implemented")
    }
    
    // MARK: - Static initializers
    
    public static func makeBuffer(withDevice device: MTLDevice, converter: MTLPixelConverter, format: OEMTLPixelFormat, height: Int, bytesPerRow: Int) -> PixelBuffer {
        makeBuffer(withDevice: device, converter: converter,
                   format: format, height: height, bytesPerRow: bytesPerRow,
                   bytes: nil)
    }
    
    public static func makeBuffer(withDevice device: MTLDevice, converter: MTLPixelConverter, format: OEMTLPixelFormat, height: Int, bytesPerRow: Int, bytes: UnsafeMutableRawPointer?) -> PixelBuffer {
        if format.isNative {
            return NativePixelBuffer(withDevice: device, format: format,
                                     height: height, bytesPerRow: bytesPerRow,
                                     pointer: bytes)
        }

#if os(tvOS)
        // The compute conversion kernels come back empty on the Apple TV's
        // GPU: the input holds the game's pixels but the texture stays zeros.
        // Convert on the CPU and upload with a plain blit instead — the same
        // blit native formats already use, which this box does fine. The
        // phone keeps the compute path: this branch does not exist for it.
        return CPUConvertingPixelBuffer(withDevice: device, format: format,
                                        height: height, bytesPerRow: bytesPerRow,
                                        pointer: bytes)
#else
        guard let conv = converter.bufferConverter(withFormat: format) else { fatalError("Unable to create converter") }

        return IntermediatePixelBuffer(withDevice: device, converter: conv, format: format,
                                       height: height, bytesPerRow: bytesPerRow,
                                       pointer: bytes)
#endif
    }
    
    // MARK: - Class cluster
    
    class NativePixelBuffer: PixelBuffer {
        override init(withDevice device: MTLDevice, format: OEMTLPixelFormat, height: Int, bytesPerRow: Int, pointer: UnsafeMutableRawPointer?) {
            super.init(withDevice: device, format: format, height: height, bytesPerRow: bytesPerRow, pointer: pointer)
        }
        
        override func prepare(withCommandBuffer commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
            if texture.storageMode != .private {
                texture.replace(region: MTLRegionMake2D(Int(outputRect.origin.x),
                                                        Int(outputRect.origin.y),
                                                        Int(outputRect.width),
                                                        Int(outputRect.height)),
                                mipmapLevel: 0,
                                withBytes: buffer,
                                bytesPerRow: sourceBytesPerRow)
                return
            }
            
            copyBuffer()
            
            let size = MTLSize(width: Int(outputRect.width), height: Int(outputRect.height), depth: 1)
            if let bce = commandBuffer.makeBlitCommandEncoder() {
                let offset = (Int(outputRect.origin.y) * sourceBytesPerRow) + Int(outputRect.origin.x) * 4 // 4 bpp
                let len = sourceBuffer.length - (Int(outputRect.origin.y) * sourceBytesPerRow)
                bce.copy(from: sourceBuffer, sourceOffset: offset, sourceBytesPerRow: sourceBytesPerRow, sourceBytesPerImage: len, sourceSize: size,
                         to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
                bce.endEncoding()
            }
        }
    }
    
    class IntermediatePixelBuffer: PixelBuffer {
        let converter: MTLPixelConverter.BufferConverter
        
        init(withDevice device: MTLDevice, converter: MTLPixelConverter.BufferConverter, format: OEMTLPixelFormat, height: Int, bytesPerRow: Int, pointer: UnsafeMutableRawPointer?) {
            self.converter = converter
            super.init(withDevice: device, format: format, height: height, bytesPerRow: bytesPerRow, pointer: pointer)
        }
        
        override func prepare(withCommandBuffer commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
            copyBuffer()
            
            let orig = MTLOrigin(x: Int(outputRect.origin.x), y: Int(outputRect.origin.y), z: 0)
            converter.convert(fromBuffer: sourceBuffer, sourceOrigin: orig, sourceBytesPerRow: sourceBytesPerRow,
                              toTexture: texture, commandBuffer: commandBuffer)
        }
    }

#if os(tvOS)
    /// Converts the core's pixels on the CPU and uploads with a plain blit.
    ///
    /// tvOS-only: the compute kernels above produce empty textures on the
    /// Apple TV (A12) while the same kernels work on the phone and the
    /// Simulator. Logged proof: the converter's input held real game pixels
    /// while its output stayed zeros, every frame, with no Metal error.
    /// The texture format itself is fine — Apple's tables list bgra8Unorm as
    /// writable on every GPU family — and the copy engine reads the same
    /// memory correctly (native 3D cores render on this box), so the prime
    /// suspect is the A12's compute unit seeing stale shared memory. The
    /// API that would answer that (`didModifyRange`) does not exist on tvOS.
    ///
    /// The conversion below repeats each kernel's byte math one pixel at a
    /// time, so the picture matches the other devices exactly, and shaders
    /// run after it exactly as before — this changes nothing about filters.
    /// The upload is the same blit `NativePixelBuffer` uses, which this box
    /// does fine. If the kernel ever behaves, delete this class and the
    /// branch in `makeBuffer` that reaches it.
    final class CPUConvertingPixelBuffer: PixelBuffer {
        /// Converted BGRA bytes, one row per core row.
        let scratch: MTLBuffer
        let scratchBytesPerRow: Int

        override init(withDevice device: MTLDevice, format: OEMTLPixelFormat, height: Int, bytesPerRow: Int, pointer: UnsafeMutableRawPointer?) {
            let pixelsPerRow = bytesPerRow / format.bytesPerPixel
            scratchBytesPerRow = pixelsPerRow * 4
            scratch = device.makeBuffer(length: height * scratchBytesPerRow, options: .storageModeShared)!
            super.init(withDevice: device, format: format, height: height, bytesPerRow: bytesPerRow, pointer: pointer)
        }

        override func prepare(withCommandBuffer commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
            convert()
            blit(to: texture, commandBuffer: commandBuffer)
        }

        private func convert() {
            let srcFormat = format
            let srcBpp = srcFormat.bytesPerPixel
            let ox = Int(outputRect.origin.x)
            let oy = Int(outputRect.origin.y)
            let w = Int(outputRect.width)
            let h = Int(outputRect.height)
            guard w > 0, h > 0 else { return }

            let dst = scratch.contents().bindMemory(to: UInt8.self, capacity: scratch.length)
            let src = buffer.bindMemory(to: UInt8.self, capacity: bufferLenBytes)

            for row in 0..<h {
                let srcRow = (oy + row) * sourceBytesPerRow + ox * srcBpp
                let dstRow = row * scratchBytesPerRow
                for x in 0..<w {
                    let s = srcRow + x * srcBpp
                    let d = dstRow + x * 4
                    switch srcFormat {
                    case .abgr8Unorm:
                        // The kernel writes the input straight through, which
                        // lands byte-swapped in BGRA storage.
                        dst[d] = src[s + 2]; dst[d + 1] = src[s + 1]
                        dst[d + 2] = src[s]; dst[d + 3] = src[s + 3]
                    case .rgba8Unorm:
                        // The kernel's .abgr swizzle rotates the channels.
                        dst[d] = src[s + 1]; dst[d + 1] = src[s + 2]
                        dst[d + 2] = src[s + 3]; dst[d + 3] = src[s]
                    case .b5g6r5Unorm:
                        let pix = UInt16(src[s]) | UInt16(src[s + 1]) << 8
                        dst[d] = Self.expand5(UInt8(pix & 0x1f))
                        dst[d + 1] = Self.expand6(UInt8((pix >> 5) & 0x3f))
                        dst[d + 2] = Self.expand5(UInt8((pix >> 11) & 0x1f))
                        dst[d + 3] = 255
                    case .r5g5b5a1Unorm:
                        let pix = UInt16(src[s]) | UInt16(src[s + 1]) << 8
                        dst[d] = Self.expand5(UInt8((pix >> 10) & 0x1f))
                        dst[d + 1] = Self.expand5(UInt8((pix >> 5) & 0x1f))
                        dst[d + 2] = Self.expand5(UInt8(pix & 0x1f))
                        dst[d + 3] = (pix >> 15) == 1 ? 255 : 0
                    case .bgra4Unorm:
                        let pix = UInt16(src[s]) | UInt16(src[s + 1]) << 8
                        dst[d] = Self.expand4(UInt8((pix >> 12) & 0xf))
                        dst[d + 1] = Self.expand4(UInt8((pix >> 8) & 0xf))
                        dst[d + 2] = Self.expand4(UInt8((pix >> 4) & 0xf))
                        dst[d + 3] = Self.expand4(UInt8(pix & 0xf))
                    case .bgra8Unorm, .bgrx8Unorm:
                        // Native formats never reach this class.
                        dst[d] = src[s]; dst[d + 1] = src[s + 1]
                        dst[d + 2] = src[s + 2]; dst[d + 3] = src[s + 3]
                    }
                }
            }
        }

        private func blit(to texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
            let size = MTLSize(width: Int(outputRect.width), height: Int(outputRect.height), depth: 1)
            if let bce = commandBuffer.makeBlitCommandEncoder() {
                let offset = (Int(outputRect.origin.y) * scratchBytesPerRow) + Int(outputRect.origin.x) * 4
                let len = scratch.length - (Int(outputRect.origin.y) * scratchBytesPerRow)
                bce.copy(from: scratch, sourceOffset: offset, sourceBytesPerRow: scratchBytesPerRow, sourceBytesPerImage: len, sourceSize: size,
                         to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
                bce.endEncoding()
            }
        }

        // MARK: - Bit expansion

        private static func expand4(_ v: UInt8) -> UInt8 { (v << 4) | v }
        private static func expand5(_ v: UInt8) -> UInt8 { (v << 3) | (v >> 2) }
        private static func expand6(_ v: UInt8) -> UInt8 { (v << 2) | (v >> 4) }
    }
#endif
}

public enum OEMTLPixelFormat: Int, CaseIterable {
    // 16-bit formats
    case bgra4Unorm
    case b5g6r5Unorm
    case r5g5b5a1Unorm
    
    // 32-bit formats, 8 bits per pixel
    case rgba8Unorm
    case abgr8Unorm
    
    // native, no conversion
    case bgra8Unorm
    case bgrx8Unorm // no alpha
    
    var isNative: Bool {
        switch self {
        case .abgr8Unorm, .rgba8Unorm, .r5g5b5a1Unorm, .b5g6r5Unorm, .bgra4Unorm:
            return false
            
        case .bgra8Unorm, .bgrx8Unorm:
            return true
        }
    }
    
    // Returns the number of bytes per pixel for the given format; otherwise, 0 if the format is not supported
    var bytesPerPixel: Int {
        switch self {
        case .abgr8Unorm, .rgba8Unorm, .bgra8Unorm, .bgrx8Unorm:
            return 4
            
        case .b5g6r5Unorm, .r5g5b5a1Unorm, .bgra4Unorm:
            return 2
        }
    }
}
