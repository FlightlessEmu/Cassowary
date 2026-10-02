// Presentation stub for the paraLLEl-RDP mupen64plus plugin.
//
// The upstream RMG/Highscore glue presents frames with desktop OpenGL, which
// does not exist on iOS. This replaces that presentation: the scanout buffer
// is already in host memory, so the frame is copied to a small buffer and the
// OpenEmu core picks it up through parallel_video_get_frame().

#include "glguts.hpp"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

int32_t window_width = 640;
int32_t window_height = 480;
int32_t window_fullscreen = 0;
int32_t window_widescreen = 0;

static struct video_pixel *frame_pixels = NULL;
static uint32_t frame_width = 0;
static uint32_t frame_height = 0;
static uint32_t frame_pitch = 0;

void screen_init(void)
{
}

void screen_update(void)
{
}

void screen_toggle_fullscreen(void)
{
}

void screen_close(void)
{
	free(frame_pixels);
	frame_pixels = NULL;
	frame_width = 0;
	frame_height = 0;
	frame_pitch = 0;
}

void screen_write(struct frame_buffer *fb)
{
	if (!fb || !fb->valid || !fb->pixels || fb->width == 0 || fb->height == 0)
		return;

	if (frame_width != fb->width || frame_height != fb->height)
	{
		free(frame_pixels);
		frame_pixels = (struct video_pixel *)malloc(fb->width * fb->height * sizeof(struct video_pixel));
		if (!frame_pixels)
		{
			frame_width = frame_height = frame_pitch = 0;
			return;
		}
		frame_width = fb->width;
		frame_height = fb->height;
		frame_pitch = fb->width;
	}

	memcpy(frame_pixels, fb->pixels, fb->width * fb->height * sizeof(struct video_pixel));
}

void screen_read(struct frame_buffer *fb, bool alpha)
{
	(void)alpha;

	if (!fb || !fb->pixels || !frame_pixels)
		return;

	uint32_t width = fb->width ? fb->width : frame_width;
	uint32_t height = fb->height ? fb->height : frame_height;
	if (width > frame_width) width = frame_width;
	if (height > frame_height) height = frame_height;

	memcpy(fb->pixels, frame_pixels, width * height * sizeof(struct video_pixel));
	fb->width = width;
	fb->height = height;
	fb->valid = true;
}

void screen_swap(bool blank)
{
	(void)blank;
}

// The OpenEmu core pulls the latest frame through this.
extern "C" void parallel_video_get_frame(const uint8_t **pixels, int *width, int *height, int *pitch)
{
	if (pixels) *pixels = reinterpret_cast<const uint8_t *>(frame_pixels);
	if (width) *width = int(frame_width);
	if (height) *height = int(frame_height);
	if (pitch) *pitch = int(frame_pitch * sizeof(struct video_pixel));
}
