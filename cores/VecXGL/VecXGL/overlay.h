// VecXGL 1.1 (SDL/Win32)
// Overlay info
// JH 2007
//
// The overlay is the coloured film that clips over the Vectrex screen. The
// pixels are parsed here and uploaded by the core's Metal renderer; there is
// no OpenGL texture anymore.

#ifndef __OVERLAY_H
#define __OVERLAY_H

#include <stdint.h>

typedef struct								// Create A Structure
{
	uint8_t	*imageData;						// Image Data (Up To 32 Bits)
	uint32_t bpp;							// Image Color Depth In Bits Per Pixel.
	uint32_t width;							// Image Width
	uint32_t height;						// Image Height
	uint32_t upsideDown;					// If 1, then image is upside down
	uint32_t texID;							// Unused; kept so existing code compiles
} TextureImage;

#endif
