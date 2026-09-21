/*
 Copyright (c) 2010 OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// We need to mess with core internals

#import "VectrexGameCore.h"

#import <Metal/Metal.h>
#import <OpenEmuBase/OERingBuffer.h>
#import "vecx.h"
#import "osint.h"
#import "overlay.h"

extern TextureImage g_overlay;

// The Vectrex draws a beam across a phosphor screen: every frame is a list of
// line segments with an intensity. The original core drew them with OpenGL,
// which iOS does not have, so the drawing is done with Metal here.
//
// The core renders into its own BGRA texture and hands it to OpenEmuKit
// through -metalTexture (OEGameCoreRenderingMetal2). OpenEmuKit composites
// that texture with its shader chain.

typedef struct {
	float x, y;
	float r, g, b, a;
} VXVectorVertex;

typedef struct {
	float x, y;
	float u, v;
} VXOverlayVertex;

typedef struct {
	float scaleX, scaleY;
	float offsetX, offsetY;
} VXUniforms;

#if TARGET_OS_MACCATALYST
static const MTLResourceOptions kVXBufferStorage = MTLResourceStorageModeManaged;
static const MTLStorageMode     kVXOverlayStorage = MTLStorageModeManaged;
#else
static const MTLResourceOptions kVXBufferStorage = MTLResourceStorageModeShared;
static const MTLStorageMode     kVXOverlayStorage = MTLStorageModeShared;
#endif

static const NSUInteger kVXMaxVectors = 16384;

static NSString *const kVXShaderSource =
	@"#include <metal_stdlib>\n"
	 "using namespace metal;\n"
	 "\n"
	 "struct VXUniforms { float2 ndcScale; float2 ndcOffset; };\n"
	 "\n"
	 "struct VXVertexIn { float2 position [[attribute(0)]]; float4 color [[attribute(1)]]; };\n"
	 "struct VXVertexOut { float4 position [[position]]; float4 color; float pointSize [[point_size]]; };\n"
	 "\n"
	 "vertex VXVertexOut vx_vector_vertex(VXVertexIn in [[stage_in]],\n"
	 "                                    constant VXUniforms &uniforms [[buffer(1)]])\n"
	 "{\n"
	 "    VXVertexOut out;\n"
	 "    out.position = float4(in.position * uniforms.ndcScale + uniforms.ndcOffset, 0.0, 1.0);\n"
	 "    out.color = in.color;\n"
	 "    out.pointSize = 3.0;\n"
	 "    return out;\n"
	 "}\n"
	 "\n"
	 "fragment float4 vx_vector_fragment(VXVertexOut in [[stage_in]])\n"
	 "{\n"
	 "    return in.color;\n"
	 "}\n"
	 "\n"
	 "struct VXOverlayIn { float2 position [[attribute(0)]]; float2 texCoord [[attribute(1)]]; };\n"
	 "struct VXOverlayOut { float4 position [[position]]; float2 texCoord; };\n"
	 "\n"
	 "vertex VXOverlayOut vx_overlay_vertex(VXOverlayIn in [[stage_in]],\n"
	 "                                      constant VXUniforms &uniforms [[buffer(1)]])\n"
	 "{\n"
	 "    VXOverlayOut out;\n"
	 "    out.position = float4(in.position * uniforms.ndcScale + uniforms.ndcOffset, 0.0, 1.0);\n"
	 "    out.texCoord = in.texCoord;\n"
	 "    return out;\n"
	 "}\n"
	 "\n"
	 "fragment float4 vx_overlay_fragment(VXOverlayOut in [[stage_in]],\n"
	 "                                    texture2d<float> overlay [[texture(0)]],\n"
	 "                                    sampler overlaySampler [[sampler(0)]])\n"
	 "{\n"
	 "    return float4(overlay.sample(overlaySampler, in.texCoord).rgb, 0.5);\n"
	 "}\n";

@interface VXMetalRenderer : NSObject

@property (nonatomic, readonly, nullable) id<MTLTexture> texture;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                         width:(NSUInteger)width
                        height:(NSUInteger)height;
- (void)drawVectors:(const vector_t *)vectors
              count:(NSUInteger)count
             colors:(const float *)colors;

@end

@implementation VXMetalRenderer
{
	id<MTLDevice> _device;
	id<MTLCommandQueue> _queue;
	id<MTLRenderPipelineState> _vectorPipeline;
	id<MTLRenderPipelineState> _overlayPipeline;
	id<MTLSamplerState> _sampler;
	id<MTLBuffer> _vertexBuffer;
	id<MTLTexture> _texture;
	id<MTLTexture> _overlayTexture;
	VXUniforms _uniforms;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device
                         width:(NSUInteger)width
                        height:(NSUInteger)height
{
	self = [super init];
	if (self == nil) {
		return nil;
	}

	_device = device;
	_queue  = [device newCommandQueue];

	NSError *error = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:kVXShaderSource options:nil error:&error];
	if (library == nil) {
		NSLog(@"[VecXGL] could not compile the Metal shaders: %@", error);
		return nil;
	}

	// Vector pipeline. The beam adds light to the phosphor, so the blend is
	// additive; the 0.75 alpha keeps a single line from reaching full white.
	MTLVertexDescriptor *vectorVertices = [MTLVertexDescriptor vertexDescriptor];
	vectorVertices.attributes[0].format      = MTLVertexFormatFloat2;
	vectorVertices.attributes[0].offset      = 0;
	vectorVertices.attributes[0].bufferIndex = 0;
	vectorVertices.attributes[1].format      = MTLVertexFormatFloat4;
	vectorVertices.attributes[1].offset      = sizeof(float) * 2;
	vectorVertices.attributes[1].bufferIndex = 0;
	vectorVertices.layouts[0].stride        = sizeof(VXVectorVertex);
	vectorVertices.layouts[0].stepFunction  = MTLVertexStepFunctionPerVertex;

	MTLRenderPipelineDescriptor *vectorDescriptor = [MTLRenderPipelineDescriptor new];
	vectorDescriptor.label            = @"VecXGL vectors";
	vectorDescriptor.vertexFunction   = [library newFunctionWithName:@"vx_vector_vertex"];
	vectorDescriptor.fragmentFunction = [library newFunctionWithName:@"vx_vector_fragment"];
	vectorDescriptor.vertexDescriptor = vectorVertices;
	vectorDescriptor.colorAttachments[0].pixelFormat              = MTLPixelFormatBGRA8Unorm;
	vectorDescriptor.colorAttachments[0].blendingEnabled          = YES;
	vectorDescriptor.colorAttachments[0].rgbBlendOperation        = MTLBlendOperationAdd;
	vectorDescriptor.colorAttachments[0].alphaBlendOperation      = MTLBlendOperationAdd;
	vectorDescriptor.colorAttachments[0].sourceRGBBlendFactor     = MTLBlendFactorSourceAlpha;
	vectorDescriptor.colorAttachments[0].sourceAlphaBlendFactor   = MTLBlendFactorSourceAlpha;
	vectorDescriptor.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOne;
	vectorDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;

	_vectorPipeline = [device newRenderPipelineStateWithDescriptor:vectorDescriptor error:&error];
	if (_vectorPipeline == nil) {
		NSLog(@"[VecXGL] could not create the vector pipeline: %@", error);
		return nil;
	}

	// Overlay pipeline: the printed film that clips over the screen, drawn
	// as one alpha-blended quad before the vectors.
	MTLVertexDescriptor *overlayVertices = [MTLVertexDescriptor vertexDescriptor];
	overlayVertices.attributes[0].format      = MTLVertexFormatFloat2;
	overlayVertices.attributes[0].offset      = 0;
	overlayVertices.attributes[0].bufferIndex = 0;
	overlayVertices.attributes[1].format      = MTLVertexFormatFloat2;
	overlayVertices.attributes[1].offset      = sizeof(float) * 2;
	overlayVertices.attributes[1].bufferIndex = 0;
	overlayVertices.layouts[0].stride       = sizeof(VXOverlayVertex);
	overlayVertices.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

	MTLRenderPipelineDescriptor *overlayDescriptor = [MTLRenderPipelineDescriptor new];
	overlayDescriptor.label            = @"VecXGL overlay";
	overlayDescriptor.vertexFunction   = [library newFunctionWithName:@"vx_overlay_vertex"];
	overlayDescriptor.fragmentFunction = [library newFunctionWithName:@"vx_overlay_fragment"];
	overlayDescriptor.vertexDescriptor = overlayVertices;
	overlayDescriptor.colorAttachments[0].pixelFormat              = MTLPixelFormatBGRA8Unorm;
	overlayDescriptor.colorAttachments[0].blendingEnabled          = YES;
	overlayDescriptor.colorAttachments[0].rgbBlendOperation        = MTLBlendOperationAdd;
	overlayDescriptor.colorAttachments[0].alphaBlendOperation      = MTLBlendOperationAdd;
	overlayDescriptor.colorAttachments[0].sourceRGBBlendFactor     = MTLBlendFactorSourceAlpha;
	overlayDescriptor.colorAttachments[0].sourceAlphaBlendFactor   = MTLBlendFactorSourceAlpha;
	overlayDescriptor.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
	overlayDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	_overlayPipeline = [device newRenderPipelineStateWithDescriptor:overlayDescriptor error:&error];
	if (_overlayPipeline == nil) {
		NSLog(@"[VecXGL] could not create the overlay pipeline: %@", error);
		return nil;
	}

	MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
	samplerDescriptor.minFilter    = MTLSamplerMinMagFilterLinear;
	samplerDescriptor.magFilter    = MTLSamplerMinMagFilterLinear;
	samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
	samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
	_sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];

	// The texture OpenEmuKit composites.
	MTLTextureDescriptor *textureDescriptor =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                   width:width
		                                                  height:height
		                                               mipmapped:NO];
	textureDescriptor.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	textureDescriptor.storageMode = MTLStorageModePrivate;
	_texture = [device newTextureWithDescriptor:textureDescriptor];

	// One buffer holds both endpoints of every line. Each frame is drawn
	// synchronously, so a single buffer can be reused every time.
	_vertexBuffer = [device newBufferWithLength:kVXMaxVectors * 2 * sizeof(VXVectorVertex)
	                                    options:kVXBufferStorage];

	// Beam coordinates are x: 0..33000 (left to right) and y: 0..41000
	// (top to bottom). This maps them onto Metal's normalised device
	// coordinates, x: -1..1 and y: 1..-1 (the old glOrtho did the same).
	_uniforms.scaleX  =  2.0f / (float)ALG_MAX_X;
	_uniforms.scaleY  = -2.0f / (float)ALG_MAX_Y;
	_uniforms.offsetX = -1.0f;
	_uniforms.offsetY =  1.0f;

	return self;
}

- (void)uploadOverlayIfNeeded
{
	if (_overlayTexture != nil || g_overlay.imageData == NULL ||
	    g_overlay.width == 0 || g_overlay.height == 0) {
		return;
	}

	NSUInteger width  = g_overlay.width;
	NSUInteger height = g_overlay.height;
	NSUInteger sourceBytesPerPixel = g_overlay.bpp / 8;
	if (sourceBytesPerPixel != 3 && sourceBytesPerPixel != 4) {
		return;
	}

	// Metal has no 24-bit pixel format, so RGB overlays are widened to RGBA.
	uint8_t *pixels = malloc(width * height * 4);
	if (pixels == NULL) {
		return;
	}
	for (NSUInteger i = 0; i < width * height; i++) {
		pixels[i * 4 + 0] = g_overlay.imageData[i * sourceBytesPerPixel + 0];
		pixels[i * 4 + 1] = g_overlay.imageData[i * sourceBytesPerPixel + 1];
		pixels[i * 4 + 2] = g_overlay.imageData[i * sourceBytesPerPixel + 2];
		pixels[i * 4 + 3] = (sourceBytesPerPixel == 4) ? g_overlay.imageData[i * 4 + 3] : 0xFF;
	}

	MTLTextureDescriptor *descriptor =
		[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
		                                                   width:width
		                                                  height:height
		                                               mipmapped:NO];
	descriptor.storageMode = kVXOverlayStorage;
	_overlayTexture = [_device newTextureWithDescriptor:descriptor];
	[_overlayTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
	                   mipmapLevel:0
	                     withBytes:pixels
	                   bytesPerRow:width * 4];
	free(pixels);
}

- (void)drawVectors:(const vector_t *)vectors
              count:(NSUInteger)count
             colors:(const float *)colors
{
	if (count > kVXMaxVectors) {
		count = kVXMaxVectors;
	}

	[self uploadOverlayIfNeeded];

	if (count > 0) {
		VXVectorVertex *vertices = _vertexBuffer.contents;
		for (NSUInteger i = 0; i < count; i++) {
			const vector_t *vector = &vectors[i];
			float intensity = colors[vector->color];
			vertices[i * 2]     = (VXVectorVertex){ (float)vector->x0, (float)vector->y0, intensity, intensity, intensity, 0.75f };
			vertices[i * 2 + 1] = (VXVectorVertex){ (float)vector->x1, (float)vector->y1, intensity, intensity, intensity, 0.75f };
		}
#if TARGET_OS_MACCATALYST
		[_vertexBuffer didModifyRange:NSMakeRange(0, count * 2 * sizeof(VXVectorVertex))];
#endif
	}

	id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
	MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
	pass.colorAttachments[0].texture     = _texture;
	pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
	pass.colorAttachments[0].storeAction = MTLStoreActionStore;
	pass.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

	id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];

	if (_overlayTexture != nil) {
		float farX = (float)ALG_MAX_X;
		float farY = (float)ALG_MAX_Y;
		// A bottom-left origin TGA reads upside down once uploaded, so the
		// texture coordinates are flipped for it (the old GL code did the
		// same with g_overlay.upsideDown).
		float nearV = g_overlay.upsideDown ? 1.0f : 0.0f;
		float farV  = g_overlay.upsideDown ? 0.0f : 1.0f;
		VXOverlayVertex quad[6] = {
			{ 0.0f, 0.0f, 0.0f, nearV },
			{ farX, 0.0f, 1.0f, nearV },
			{ farX, farY, 1.0f, farV  },
			{ 0.0f, 0.0f, 0.0f, nearV },
			{ farX, farY, 1.0f, farV  },
			{ 0.0f, farY, 0.0f, farV  },
		};
		[encoder setRenderPipelineState:_overlayPipeline];
		[encoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
		[encoder setVertexBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
		[encoder setFragmentTexture:_overlayTexture atIndex:0];
		[encoder setFragmentSamplerState:_sampler atIndex:0];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	}

	if (count > 0) {
		[encoder setRenderPipelineState:_vectorPipeline];
		[encoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
		[encoder setVertexBytes:&_uniforms length:sizeof(_uniforms) atIndex:1];
		[encoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:count * 2];
		// A zero-length line draws nothing, so the endpoints are drawn as
		// points too (the OpenGL core did the same).
		[encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:count * 2];
	}

	[encoder endEncoding];
	[commandBuffer commit];
	// The layer that composites this texture belongs to the app, so the
	// frame has to be finished before the emulation thread moves on.
	[commandBuffer waitUntilCompleted];
}

@end

@interface VectrexGameCore () <OEVectrexSystemResponderClient>
{
    int videoWidth, videoHeight;
    NSString *romPath;
    NSString *overlayFile;
    BOOL overlayIsLoaded;
    VXMetalRenderer *_renderer;
}
- (void)presentVectors;
@end

// OpenEmu's responders have historically passed players 1-based, while the
// app builds its keys with player 0. The Vectrex has a single controller, so
// both spellings mean slot 0; anything else is clamped rather than indexing
// off the end of the small per-player arrays.
static inline NSUInteger VXPlayerIndex(NSUInteger player)
{
    NSUInteger index = (player > 0) ? (player - 1) : 0;
    return (index < 2) ? index : 0;
}

VectrexGameCore *g_core;

@implementation VectrexGameCore

- (id)init
{
    if (self = [super init])
    {
        videoWidth = 330 * 2;
        videoHeight = 410 * 2;
    }
    overlayIsLoaded = NO;

    g_core = self;
    return self;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    romPath = path;
    osint_defaults();           //setup defaults including sound buffer
    openCart(path.fileSystemRepresentation);
    osint_gencolors();          //setup colors
    return YES;
}

- (void)executeFrame
{
    // late init of the overlay

    // check fix, has to be REloaded at each frame, i mean really ?
    if (overlayFile != nil && ![overlayFile isEqualToString:@""] && !overlayIsLoaded)
    //if (![overlayFile isEqualToString:@""] && !overlayIsLoaded)
    {
        load_overlay((char *)overlayFile.fileSystemRepresentation);
        overlayIsLoaded = YES;
    }

    vecx_emu ((VECTREX_MHZ / 1000) * EMU_TIMER, 0);
}

- (void)presentVectors
{
    if (_renderer == nil) {
        return;
    }

    [_renderer drawVectors:vectors_draw
                     count:(NSUInteger)vector_draw_cnt
                    colors:VX_color_set];
}

- (void)startEmulation
{
    if(self.rate != 0) return;

    [super startEmulation];
    vecx_reset();

    // The Vectrex draws on the emulation thread itself, so there is no
    // separate rendering thread for MTL3DGameRenderer to synchronize with.
    // Its -didExecuteFrame waits for a handshake that only an alternate
    // rendering thread can send, so FPS limiting stays off (Dolphin does
    // the same for the same reason).
    [self.renderDelegate suspendFPSLimiting];

    NSFileManager *defaultFileManager = [NSFileManager defaultManager];
    if ([defaultFileManager fileExistsAtPath:[[romPath stringByDeletingPathExtension] stringByAppendingString:@".tga"]])
    {
        // Too early to load overlay, the context is not ready
        //load_overlay((char *)[[[romPath stringByDeletingPathExtension] stringByAppendingString:@".tga"] fileSystemRepresentation]);
        overlayFile = [[romPath stringByDeletingPathExtension] stringByAppendingString:@".tga"];
    }
}

- (void)updateSound:(uint8_t *)buff len:(int)len
{
    [[g_core ringBufferAtIndex:0] write:buff maxLength:len];
}

- (void)resetEmulation
{
    vecx_reset();
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    VECXState *state = saveVecxState();
    NSData *data = [NSData dataWithBytesNoCopy:state length:sizeof(VECXState) freeWhenDone:YES];

    NSError *error;
    BOOL succeeded = [data writeToFile:fileName options:0 error:&error];
    block(succeeded, error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    NSError *error;
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:fileName options:0 error:&error];

    if (!data) {
        block(NO, error);
        return;
    }

    if (sizeof(VECXState) != data.length) {
        block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedFailureReasonErrorKey: @"THe size of the saved file is different from the size of the state.",
        }]);
        return;
    }

    VECXState *state = (void *)data.bytes;
    loadVecxState(state);
}

- (OEIntSize)aspectSize
{
    return (OEIntSize){videoWidth, videoHeight};
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, videoWidth, videoHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(videoWidth, videoHeight);
}

- (OEGameCoreRendering)gameCoreRendering
{
    return OEGameCoreRenderingMetal2;
}

- (void)createMetalTextureWithDevice:(id<MTLDevice>)device
{
    _renderer = [[VXMetalRenderer alloc] initWithDevice:device
                                                  width:(NSUInteger)videoWidth
                                                 height:(NSUInteger)videoHeight];
}

- (id<MTLTexture>)metalTexture
{
    return _renderer.texture;
}

- (const void *)videoBuffer
{
    return NULL;
}

- (uint32_t)pixelFormat
{
    return OEPixelFormat_BGRA;
}

- (uint32_t)pixelType
{
    return OEPixelType_UNSIGNED_INT_8_8_8_8_REV;
}

- (double)audioSampleRate
{
    return 44100;
}

- (NSUInteger)audioBitDepth
{
    return 8;
}

- (NSTimeInterval)frameInterval
{
    return 50;
}

- (NSUInteger)channelCount
{
    return 1;
}

- (oneway void)didMoveVectrexJoystickDirection:(OEVectrexButton)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
    player = VXPlayerIndex(player);

    CGFloat clamped = MAX(0.0, MIN(1.0, value));
    switch (button)
    {
        case OEVectrexAnalogUp:
            yAxis[player][0] = (uint8_t)(clamped * 255.0);
            break;
        case OEVectrexAnalogDown:
            yAxis[player][1] = (uint8_t)(clamped * 255.0);
            break;
        case OEVectrexAnalogLeft:
            xAxis[player][0] = (uint8_t)(clamped * 255.0);
            break;
        case OEVectrexAnalogRight:
            xAxis[player][1] = (uint8_t)(clamped * 255.0);
            break;
        default:
            return;
    }

    // The Vectrex stick is analog. vecx reads the stick position from
    // alg_jch0 (x) and alg_jch1 (y), centred at 0x80, so the per-direction
    // values are folded into those two registers. Without this the stick
    // moved nothing at all: the old code only wrote xAxis/yAxis, which
    // nothing else reads.
    int x = (int)xAxis[player][1] - (int)xAxis[player][0]; // right - left
    int y = (int)yAxis[player][0] - (int)yAxis[player][1]; // up - down
    alg_jch0 = (unsigned)(0x80 + x / 2);
    alg_jch1 = (unsigned)(0x80 + y / 2);
}


- (oneway void)didPushVectrexButton:(OEVectrexButton)button forPlayer:(NSUInteger)player
{
    player = VXPlayerIndex(player);
    padData[player][button] = 1;
    
    osint_btnDown(button);
}

- (oneway void)didReleaseVectrexButton:(OEVectrexButton)button forPlayer:(NSUInteger)player
{
    player = VXPlayerIndex(player);
    padData[player][button] = 0;
    
    osint_btnUp(button);
}


@end

void vx_metal_present (void)
{
	[g_core presentVectors];
}
