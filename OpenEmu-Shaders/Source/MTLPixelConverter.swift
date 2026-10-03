// Copyright (c) 2019, OpenEmu Team
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
import simd

public class MTLPixelConverter {
    enum Error: LocalizedError {
        case missingFunction(String)
    }
    
    @frozen @usableFromInline struct BufferUniforms {
        let origin: SIMD2<UInt32>
        let stride: UInt32
    }

    public class BufferConverter {
        let kernel: MTLComputePipelineState
        let bytesPerPixel: Int
        
        init(kernel: MTLComputePipelineState, bytesPerPixel: Int) {
            self.kernel = kernel
            self.bytesPerPixel = bytesPerPixel
        }
        
        public func convert(fromBuffer src: MTLBuffer, sourceOrigin: MTLOrigin, sourceBytesPerRow: Int,
                            toTexture dst: MTLTexture, commandBuffer: MTLCommandBuffer)
        {
            let ce = commandBuffer.makeComputeCommandEncoder()!
            ce.label = "pixel conversion"
            ce.setComputePipelineState(kernel)
            
            var unif = BufferUniforms(origin: SIMD2(x: UInt32(sourceOrigin.x), y: UInt32(sourceOrigin.y)),
                                      stride: UInt32(sourceBytesPerRow / bytesPerPixel))
            
            ce.setBuffer(src, offset: 0, index: 0)
            ce.setBytes(&unif, length: MemoryLayout.stride(ofValue: unif), index: 1)
            ce.setTexture(dst, index: 0)
            
            let size = MTLSizeMake(16, 16, 1)
            let count = MTLSizeMake(
                (dst.width + size.width + 1) / size.width,
                (dst.height + size.height + 1) / size.height,
                1)
            ce.dispatchThreadgroups(count, threadsPerThreadgroup: size)
            ce.endEncoding()
        }
    }
    
    let bufToTex: [BufferConverter?]
    
    static let converters: [(OEMTLPixelFormat, String)] = [
        (.bgra4Unorm, "convert_bgra4444_to_bgra8888_buf"),
        (.b5g6r5Unorm, "convert_rgb565_to_bgra8888_buf"),
        (.r5g5b5a1Unorm, "convert_bgra5551_to_bgra8888_buf"),
        (.rgba8Unorm, "convert_rgba8888_to_bgra8888_buf"),
        (.abgr8Unorm, "convert_abgr8888_to_bgra8888_buf"),
    ]
    
    public init(device: MTLDevice) throws {
        let bundle = Bundle(for: type(of: self))
        let library = try device.makeDefaultLibrary(bundle: bundle)
        
        var bufToTex = [BufferConverter?](repeating: nil, count: OEMTLPixelFormat.allCases.count)
        
        for (format, name) in MTLPixelConverter.converters {
            guard let fn = library.makeFunction(name: name) else {
                throw Error.missingFunction(name)
            }
            
            let kernel = try device.makeComputePipelineState(function: fn)
            
            bufToTex[format.rawValue] = BufferConverter(kernel: kernel, bytesPerPixel: format.bytesPerPixel)
        }
        self.bufToTex = bufToTex
    }
    
    public func bufferConverter(withFormat sourceFormat: OEMTLPixelFormat) -> BufferConverter? {
        bufToTex[sourceFormat.rawValue]
    }
}
