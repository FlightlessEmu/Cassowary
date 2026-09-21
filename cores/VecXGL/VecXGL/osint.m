// VecXGL 1.2 (SDL/Win32 and SDL/Linux)
//
// This is a port of the vectrex emulator "vecx", by Valavan Manohararajah.
// Portions of this code copyright James Higgs 2005/2007.
// These portions are:
// 1. Ay38910 PSG (audio) emulation wave-buffering code.
// 2. Drawing of vectors using OpenGL.
//
// Comand-line parsing code gratefully borrowed from vecxsdl (Thomas Mathys).
// Key mapping and command-line options were also changed
// to be compatible with Thomas Mathys' vecxsdl.
//
// Other vecx ports by JH:
// - VecXPS2 (Playsyation 2)
// - VecXWin32 (Windows/DirectX) (unreleased)

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "vecx.h"
#include "bios.h"						// bios rom data
#include "wnoise.h"						// White noise waveform
#include "overlay.h"					// overlay texture info
#import "osint.h"
#import "VectrexGameCore.h"
#import "e8910.h"

//typedefs for integers
typedef uint8_t Uint8;
typedef uint16_t Uint16;

// AY38910 emulation stuff
extern unsigned snd_regs[16];
Uint8 AY_vol[3];
Uint16 AY_spufreq[3];
Uint16 AY_noisefreq;
Uint8 AY_tone_enable[3];
Uint8 AY_noise_enable[3];

//Audio buffer
Uint8 *pWave;

static const char* cartname = NULL;

static long screen_x = DEFAULT_WIDTH;
static long screen_y = DEFAULT_HEIGHT;
static long scl_factor;

//static long bytes_per_pixel;
float VX_color_set[VECTREX_COLORS];

// Global texture image info
TextureImage g_overlay;							// Storage For One Texture
extern int LoadTGA (char *filename);			// Loads A TGA File Into Memory

static void osint_updatescale (void)
{
	long sclx, scly;

	sclx = ALG_MAX_X / screen_x;
	scly = ALG_MAX_Y / screen_y;

	if (sclx > scly) {
		scl_factor = sclx;
	} else {
		scl_factor = scly;
	}
}

void openCart(const char *romName)
{
	FILE *cartfile;
	cartname = romName;
	cartfile = fopen (cartname, "rb");
    
	if (cartfile != NULL) {
        fread (cart, 1, sizeof (cart), cartfile);
        fclose (cartfile);
	}	
}


int osint_defaults (void)
{
	unsigned b;

	screen_x = DEFAULT_WIDTH;
	screen_y = DEFAULT_HEIGHT;

	osint_updatescale ();

	// JH - built-in bios
	memcpy(rom, bios_data, bios_data_size);

	/* the cart is empty by default */
	for (b = 0; b < sizeof (cart); b++) {
		cart[b] = 0;
	}
    
    e8910_init_sound();
    
    //initialize and zero audio buffer
    pWave = malloc(882);
    memset(pWave, 0, 882);
    
    g_overlay.width = 0;

	return 0;
}

// Load a custom vectrex bios rom
static void osint_load_bios(const char *filename) {

	FILE *f;

	f = fopen(filename, "rb");
	if (!f) {
		fprintf(stderr, "Can't open bios image (%s).\n", filename);
		exit(1);
	}

	if (sizeof(rom) != fread(rom, 1, sizeof(rom), f)) {
		fprintf(
			stderr,
			"%s is not a valid Vectrex BIOS.\n"
			"It's smaller than %lu bytes.\n",
			filename, sizeof(rom)
		);
		fclose(f);
		exit(1);
	}

	fclose(f);
}

static void osint_maskinfo (int mask, int *shift, int *precision)
{
	*shift = 0;

	while ((mask & 1L) == 0) {
		mask >>= 1;
		(*shift)++;
	}

	*precision = 0;

	while ((mask & 1L) != 0) {
		mask >>= 1;
		(*precision)++;
	}
}

void osint_gencolors (void)
{
	int c;
	int rcomp, gcomp, bcomp;

	for (c = 0; c < VECTREX_COLORS; c++) {
		rcomp = c * 256 / VECTREX_COLORS;
		gcomp = c * 256 / VECTREX_COLORS;
		bcomp = c * 256 / VECTREX_COLORS;

		VX_color_set[c] = (float)c/128;
		if(VX_color_set[c] > 1.0f) VX_color_set[c] = 1.0f;
	}
}

/*
    JH - there some were nice low-level line drawing routines here,
         which have been replaced by Metal line drawing in the core
*/

void osint_render (void)
{
	// The vector list is handed to the core, which draws it with Metal
	// (see vx_metal_present() in VectrexGameCore.m). This used to be the
	// OpenGL line drawing code, which does not exist on iOS.
	vx_metal_present();
}

void osint_btnDown(OEVectrexButton btn) {
    switch(btn) {
        case OEVectrexButton1:
            snd_regs[14] &= ~0x01;
            break;
        case OEVectrexButton2:
            snd_regs[14] &= ~0x02;
            break;
        case OEVectrexButton3:
            snd_regs[14] &= ~0x04;
            break;
        case OEVectrexButton4:
            snd_regs[14] &= ~0x08;
            break;
        case OEVectrexAnalogUp:
            alg_jch1 = 0xFF;
            break;
        case OEVectrexAnalogDown:
            alg_jch1 = 0x00;
            break;
        case OEVectrexAnalogLeft:
            alg_jch0 = 0x00;
            break;
        case OEVectrexAnalogRight:
            alg_jch0 = 0xFF;
            break;
        default:
            break;
    }
}

void osint_btnUp(OEVectrexButton btn) {
    switch(btn) {
        case OEVectrexButton1:
            snd_regs[14] |= 0x01;
            break;
        case OEVectrexButton2:
            snd_regs[14] |= 0x02;
            break;
        case OEVectrexButton3:
            snd_regs[14] |= 0x04;
            break;
        case OEVectrexButton4:
            snd_regs[14] |= 0x08;
            break;
        case OEVectrexAnalogUp:
            alg_jch1 = 0x80;
            break;
        case OEVectrexAnalogDown:
            alg_jch1 = 0x80;
            break;
        case OEVectrexAnalogLeft:
            alg_jch0 = 0x80;
            break;
        case OEVectrexAnalogRight:
            alg_jch0 = 0x80;
            break;
        default:
            break;
    }
}

// load overlay and set it as current texture
void load_overlay(char *filename)
{
    if (!LoadTGA(filename))				// Load The Font Texture
    {
        return;										// If Loading Failed, Return False
    }
    /*
    //BuildFont();											// Build The Font

    glShadeModel(GL_SMOOTH);								// Enable Smooth Shading
    glClearColor(0.0f, 0.0f, 0.0f, 0.5f);					// Black Background
    glClearDepth(1.0f);										// Depth Buffer Setup
    glBindTexture(GL_TEXTURE_2D, g_overlay.texID);		// Select Our Font Texture
    
    //glScissor(1	,64,637,288);								// Define Scissor Region
    
    //return TRUE;
    */
}
