/*
 Copyright (c) 2026, OpenEmu Team

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

/*!
 * @header OEHIDUsageTables_iOS.h
 * @abstract The HID usage page and usage constants OpenEmu refers to.
 *
 * @discussion IOKit does not exist on iOS, so the constants that come from
 *   <IOKit/hid/IOHIDUsageTables.h> on macOS are defined here instead. The
 *   values are the USB HID specification values and are identical to the ones
 *   in the macOS SDK. They are not platform specific — only the header that
 *   declares them is.
 *
 *   Keeping the names the same means the controller database, the binding
 *   code, and the device parsers are all unchanged between macOS and iOS.
 */

#ifndef OEHIDUsageTables_iOS_h
#define OEHIDUsageTables_iOS_h

#define kHIDPage_Undefined                           0x00
#define kHIDPage_GenericDesktop                      0x01
#define kHIDUsage_KeyboardErrorRollOver              0x01    /* ErrorRollOver */
#define kHIDPage_Simulation                          0x02
#define kHIDUsage_GD_Mouse                           0x02    /* Application Collection */
#define kHIDUsage_KeyboardPOSTFail                   0x02    /* POSTFail */
#define kHIDPage_VR                                  0x03
#define kHIDUsage_KeyboardErrorUndefined             0x03    /* ErrorUndefined */
#define kHIDPage_Sport                               0x04
#define kHIDUsage_GD_Joystick                        0x04    /* Application Collection */
#define kHIDUsage_KeyboardA                          0x04    /* a or A */
#define kHIDPage_Game                                0x05
#define kHIDUsage_GD_GamePad                         0x05    /* Application Collection */
#define kHIDUsage_KeyboardB                          0x05    /* b or B */
#define kHIDPage_GenericDeviceControls               0x06
#define kHIDUsage_GD_Keyboard                        0x06    /* Application Collection */
#define kHIDUsage_KeyboardC                          0x06    /* c or C */
#define kHIDPage_KeyboardOrKeypad                    0x07    /* USB Device Class Definition for Human Interface Devices (HID). Note: the usage type for all key codes is Selector (Sel). */
#define kHIDUsage_KeyboardD                          0x07    /* d or D */
#define kHIDPage_LEDs                                0x08
#define kHIDUsage_KeyboardE                          0x08    /* e or E */
#define kHIDPage_Button                              0x09
#define kHIDUsage_KeyboardF                          0x09    /* f or F */
#define kHIDPage_Ordinal                             0x0A
#define kHIDUsage_KeyboardG                          0x0A    /* g or G */
#define kHIDUsage_KeyboardH                          0x0B    /* h or H */
#define kHIDPage_Consumer                            0x0C
#define kHIDUsage_KeyboardI                          0x0C    /* i or I */
#define kHIDUsage_KeyboardJ                          0x0D    /* j or J */
#define kHIDPage_Haptics                             0x0E
#define kHIDUsage_KeyboardK                          0x0E    /* k or K */
#define kHIDUsage_KeyboardL                          0x0F    /* l or L */
#define kHIDPage_Unicode                             0x10    /* Reserved 0x11 - 0x13 */
#define kHIDUsage_KeyboardM                          0x10    /* m or M */
#define kHIDUsage_KeyboardN                          0x11    /* n or N */
#define kHIDUsage_KeyboardO                          0x12    /* o or O */
#define kHIDUsage_KeyboardP                          0x13    /* p or P */
#define kHIDPage_AlphanumericDisplay                 0x14    /* Reserved 0x15 - 0x1F */
#define kHIDUsage_KeyboardQ                          0x14    /* q or Q */
#define kHIDUsage_KeyboardR                          0x15    /* r or R */
#define kHIDUsage_KeyboardS                          0x16    /* s or S */
#define kHIDUsage_KeyboardT                          0x17    /* t or T */
#define kHIDUsage_KeyboardU                          0x18    /* u or U */
#define kHIDUsage_KeyboardV                          0x19    /* v or V */
#define kHIDUsage_KeyboardW                          0x1A    /* w or W */
#define kHIDUsage_KeyboardX                          0x1B    /* x or X */
#define kHIDUsage_KeyboardY                          0x1C    /* y or Y */
#define kHIDUsage_KeyboardZ                          0x1D    /* z or Z */
#define kHIDUsage_Keyboard1                          0x1E    /* 1 or ! */
#define kHIDUsage_Keyboard2                          0x1F    /* 2 or @ */
#define kHIDPage_Sensor                              0x20    /* Reserved 0x21 - 0x40 */
#define kHIDUsage_Keyboard3                          0x20    /* 3 or # */
#define kHIDUsage_Csmr_ACExit                        0x204    /* Selector */
#define kHIDUsage_Csmr_ACProperties                  0x209    /* Selector */
#define kHIDUsage_Keyboard4                          0x21    /* 4 or $ */
#define kHIDUsage_Keyboard5                          0x22    /* 5 or % */
#define kHIDUsage_Csmr_ACHome                        0x223    /* Selector */
#define kHIDUsage_Csmr_ACBack                        0x224    /* Selector */
#define kHIDUsage_Csmr_ACForward                     0x225    /* Selector */
#define kHIDUsage_Keyboard6                          0x23    /* 6 or ^ */
#define kHIDUsage_Keyboard7                          0x24    /* 7 or & */
#define kHIDUsage_Keyboard8                          0x25    /* 8 or * */
#define kHIDUsage_Keyboard9                          0x26    /* 9 or ( */
#define kHIDUsage_Keyboard0                          0x27    /* 0 or ) */
#define kHIDUsage_KeyboardReturnOrEnter              0x28    /* Return (Enter) */
#define kHIDUsage_KeyboardEscape                     0x29    /* Escape */
#define kHIDUsage_KeyboardDeleteOrBackspace          0x2A    /* Delete (Backspace) */
#define kHIDUsage_KeyboardTab                        0x2B    /* Tab */
#define kHIDUsage_KeyboardSpacebar                   0x2C    /* Spacebar */
#define kHIDUsage_KeyboardHyphen                     0x2D    /* - or _ */
#define kHIDUsage_KeyboardEqualSign                  0x2E    /* = or + */
#define kHIDUsage_KeyboardOpenBracket                0x2F    /* [ or { */
#define kHIDUsage_GD_X                               0x30    /* Dynamic Value */
#define kHIDUsage_KeyboardCloseBracket               0x30    /* ] or } */
#define kHIDUsage_GD_Y                               0x31    /* Dynamic Value */
#define kHIDUsage_KeyboardBackslash                  0x31    /* \ or | */
#define kHIDUsage_GD_Z                               0x32    /* Dynamic Value */
#define kHIDUsage_KeyboardNonUSPound                 0x32    /* Non-US # or _ */
#define kHIDUsage_GD_Rx                              0x33    /* Dynamic Value */
#define kHIDUsage_KeyboardSemicolon                  0x33    /* ; or : */
#define kHIDUsage_GD_Ry                              0x34    /* Dynamic Value */
#define kHIDUsage_KeyboardQuote                      0x34    /* ' or " */
#define kHIDUsage_GD_Rz                              0x35    /* Dynamic Value */
#define kHIDUsage_KeyboardGraveAccentAndTilde        0x35    /* Grave Accent and Tilde */
#define kHIDUsage_KeyboardComma                      0x36    /* , or < */
#define kHIDUsage_KeyboardPeriod                     0x37    /* . or > */
#define kHIDUsage_KeyboardSlash                      0x38    /* / or ? */
#define kHIDUsage_GD_Hatswitch                       0x39    /* Dynamic Value */
#define kHIDUsage_KeyboardCapsLock                   0x39    /* Caps Lock */
#define kHIDUsage_KeyboardF1                         0x3A    /* F1 */
#define kHIDUsage_KeyboardF2                         0x3B    /* F2 */
#define kHIDUsage_KeyboardF3                         0x3C    /* F3 */
#define kHIDUsage_GD_Start                           0x3D    /* On/Off Control */
#define kHIDUsage_KeyboardF4                         0x3D    /* F4 */
#define kHIDUsage_GD_Select                          0x3E    /* On/Off Control */
#define kHIDUsage_KeyboardF5                         0x3E    /* F5 */
#define kHIDUsage_KeyboardF6                         0x3F    /* F6 */
#define kHIDUsage_KeyboardF7                         0x40    /* F7 */
#define kHIDPage_BrailleDisplay                      0x41    /* Reserved 0x42 - 0x7F */
#define kHIDUsage_KeyboardF8                         0x41    /* F8 */
#define kHIDUsage_KeyboardF9                         0x42    /* F9 */
#define kHIDUsage_KeyboardF10                        0x43    /* F10 */
#define kHIDUsage_KeyboardF11                        0x44    /* F11 */
#define kHIDUsage_KeyboardF12                        0x45    /* F12 */
#define kHIDUsage_KeyboardPrintScreen                0x46    /* Print Screen */
#define kHIDUsage_KeyboardScrollLock                 0x47    /* Scroll Lock */
#define kHIDUsage_KeyboardPause                      0x48    /* Pause */
#define kHIDUsage_KeyboardInsert                     0x49    /* Insert */
#define kHIDUsage_KeyboardHome                       0x4A    /* Home */
#define kHIDUsage_KeyboardPageUp                     0x4B    /* Page Up */
#define kHIDUsage_KeyboardDeleteForward              0x4C    /* Delete Forward */
#define kHIDUsage_KeyboardEnd                        0x4D    /* End */
#define kHIDUsage_KeyboardPageDown                   0x4E    /* Page Down */
#define kHIDUsage_KeyboardRightArrow                 0x4F    /* Right Arrow */
#define kHIDUsage_KeyboardLeftArrow                  0x50    /* Left Arrow */
#define kHIDUsage_KeyboardDownArrow                  0x51    /* Down Arrow */
#define kHIDUsage_KeyboardUpArrow                    0x52    /* Up Arrow */
#define kHIDUsage_KeypadNumLock                      0x53    /* Keypad NumLock or Clear */
#define kHIDUsage_KeypadSlash                        0x54    /* Keypad / */
#define kHIDUsage_KeypadAsterisk                     0x55    /* Keypad * */
#define kHIDUsage_KeypadHyphen                       0x56    /* Keypad - */
#define kHIDUsage_KeypadPlus                         0x57    /* Keypad + */
#define kHIDUsage_KeypadEnter                        0x58    /* Keypad Enter */
#define kHIDUsage_Keypad1                            0x59    /* Keypad 1 or End */
#define kHIDUsage_Keypad2                            0x5A    /* Keypad 2 or Down Arrow */
#define kHIDUsage_Keypad3                            0x5B    /* Keypad 3 or Page Down */
#define kHIDUsage_Keypad4                            0x5C    /* Keypad 4 or Left Arrow */
#define kHIDUsage_Keypad5                            0x5D    /* Keypad 5 */
#define kHIDUsage_Keypad6                            0x5E    /* Keypad 6 or Right Arrow */
#define kHIDUsage_Keypad7                            0x5F    /* Keypad 7 or Home */
#define kHIDUsage_Keypad8                            0x60    /* Keypad 8 or Up Arrow */
#define kHIDUsage_Keypad9                            0x61    /* Keypad 9 or Page Up */
#define kHIDUsage_Keypad0                            0x62    /* Keypad 0 or Insert */
#define kHIDUsage_KeypadPeriod                       0x63    /* Keypad . or Delete */
#define kHIDUsage_KeyboardNonUSBackslash             0x64    /* Non-US \ or | */
#define kHIDUsage_KeyboardApplication                0x65    /* Application */
#define kHIDUsage_KeyboardPower                      0x66    /* Power */
#define kHIDUsage_KeypadEqualSign                    0x67    /* Keypad = */
#define kHIDUsage_KeyboardF13                        0x68    /* F13 */
#define kHIDUsage_KeyboardF14                        0x69    /* F14 */
#define kHIDUsage_KeyboardF15                        0x6A    /* F15 */
#define kHIDUsage_KeyboardF16                        0x6B    /* F16 */
#define kHIDUsage_KeyboardF17                        0x6C    /* F17 */
#define kHIDUsage_KeyboardF18                        0x6D    /* F18 */
#define kHIDUsage_KeyboardF19                        0x6E    /* F19 */
#define kHIDUsage_KeyboardF20                        0x6F    /* F20 */
#define kHIDUsage_KeyboardF21                        0x70    /* F21 */
#define kHIDUsage_KeyboardF22                        0x71    /* F22 */
#define kHIDUsage_KeyboardF23                        0x72    /* F23 */
#define kHIDUsage_KeyboardF24                        0x73    /* F24 */
#define kHIDUsage_KeyboardExecute                    0x74    /* Execute */
#define kHIDUsage_KeyboardHelp                       0x75    /* Help */
#define kHIDUsage_KeyboardMenu                       0x76    /* Menu */
#define kHIDUsage_KeyboardSelect                     0x77    /* Select */
#define kHIDUsage_KeyboardStop                       0x78    /* Stop */
#define kHIDUsage_KeyboardAgain                      0x79    /* Again */
#define kHIDUsage_KeyboardUndo                       0x7A    /* Undo */
#define kHIDUsage_KeyboardCut                        0x7B    /* Cut */
#define kHIDUsage_KeyboardCopy                       0x7C    /* Copy */
#define kHIDUsage_KeyboardPaste                      0x7D    /* Paste */
#define kHIDUsage_KeyboardFind                       0x7E    /* Find */
#define kHIDUsage_KeyboardMute                       0x7F    /* Mute */
#define kHIDPage_Monitor                             0x80
#define kHIDUsage_KeyboardVolumeUp                   0x80    /* Volume Up */
#define kHIDUsage_KeyboardVolumeDown                 0x81    /* Volume Down */
#define kHIDPage_MonitorVirtual                      0x82
#define kHIDUsage_KeyboardLockingCapsLock            0x82    /* Locking Caps Lock */
#define kHIDUsage_KeyboardLockingNumLock             0x83    /* Locking Num Lock */
#define kHIDPage_PowerDevice                         0x84    /* Power Device Page */
#define kHIDUsage_KeyboardLockingScrollLock          0x84    /* Locking Scroll Lock */
#define kHIDPage_BatterySystem                       0x85    /* Battery System Page */
#define kHIDUsage_GD_SystemMainMenu                  0x85    /* One-Shot Control */
#define kHIDUsage_KeypadComma                        0x85    /* Keypad Comma */
#define kHIDPage_PowerReserved                       0x86
#define kHIDUsage_KeypadEqualSignAS400               0x86    /* Keypad Equal Sign for AS/400 */
#define kHIDUsage_KeyboardInternational1             0x87    /* International1 */
#define kHIDUsage_KeyboardInternational2             0x88    /* International2 */
#define kHIDUsage_KeyboardInternational3             0x89    /* International3 */
#define kHIDUsage_KeyboardInternational4             0x8A    /* International4 */
#define kHIDUsage_KeyboardInternational5             0x8B    /* International5 */
#define kHIDPage_BarCodeScanner                      0x8C    /* (Point of Sale) USB Device Class Definition for Bar Code Scanner Devices */
#define kHIDUsage_KeyboardInternational6             0x8C    /* International6 */
#define kHIDPage_Scale                               0x8D    /* (Point of Sale) USB Device Class Definition for Scale Devices */
#define kHIDPage_WeighingDevice                      0x8D    /* (Point of Sale) USB Device Class Definition for Weighing Devices */
#define kHIDUsage_KeyboardInternational7             0x8D    /* International7 */
#define kHIDPage_MagneticStripeReader                0x8E    /* ReservedPointofSalepages 0x8F */
#define kHIDUsage_KeyboardInternational8             0x8E    /* International8 */
#define kHIDUsage_KeyboardInternational9             0x8F    /* International9 */
#define kHIDPage_CameraControl                       0x90    /* USB Device Class Definition for Image Class Devices */
#define kHIDUsage_GD_DPadUp                          0x90    /* On/Off Control */
#define kHIDUsage_KeyboardLANG1                      0x90    /* LANG1 */
#define kHIDPage_Arcade                              0x91    /* OAAF Definitions for arcade and coinop related Devices */
#define kHIDUsage_GD_DPadDown                        0x91    /* On/Off Control */
#define kHIDUsage_KeyboardLANG2                      0x91    /* LANG2 */
#define kHIDUsage_GD_DPadRight                       0x92    /* On/Off Control */
#define kHIDUsage_KeyboardLANG3                      0x92    /* LANG3 */
#define kHIDUsage_GD_DPadLeft                        0x93    /* On/Off Control */
#define kHIDUsage_KeyboardLANG4                      0x93    /* LANG4 */
#define kHIDUsage_KeyboardLANG5                      0x94    /* LANG5 */
#define kHIDUsage_KeyboardLANG6                      0x95    /* LANG6 */
#define kHIDUsage_KeyboardLANG7                      0x96    /* LANG7 */
#define kHIDUsage_KeyboardLANG8                      0x97    /* LANG8 */
#define kHIDUsage_KeyboardLANG9                      0x98    /* LANG9 */
#define kHIDUsage_KeyboardAlternateErase             0x99    /* AlternateErase */
#define kHIDUsage_KeyboardSysReqOrAttention          0x9A    /* SysReq/Attention */
#define kHIDUsage_KeyboardCancel                     0x9B    /* Cancel */
#define kHIDUsage_KeyboardClear                      0x9C    /* Clear */
#define kHIDUsage_KeyboardPrior                      0x9D    /* Prior */
#define kHIDUsage_KeyboardReturn                     0x9E    /* Return */
#define kHIDUsage_KeyboardSeparator                  0x9F    /* Separator */
#define kHIDUsage_KeyboardOut                        0xA0    /* Out */
#define kHIDUsage_KeyboardOper                       0xA1    /* Oper */
#define kHIDUsage_KeyboardClearOrAgain               0xA2    /* Clear/Again */
#define kHIDUsage_KeyboardCrSelOrProps               0xA3    /* CrSel/Props */
#define kHIDUsage_KeyboardExSel                      0xA4    /* ExSel */
#define kHIDUsage_Csmr_Record                        0xB2    /* On/Off Control */
#define kHIDUsage_Sim_Accelerator                    0xC4    /* Dynamic Value */
#define kHIDUsage_Sim_Brake                          0xC5    /* Dynamic Value */
#define kHIDUsage_KeyboardLeftControl                0xE0    /* Left Control */
#define kHIDUsage_KeyboardLeftShift                  0xE1    /* Left Shift */
#define kHIDUsage_KeyboardLeftAlt                    0xE2    /* Left Alt */
#define kHIDUsage_KeyboardLeftGUI                    0xE3    /* Left GUI */
#define kHIDUsage_KeyboardRightControl               0xE4    /* Right Control */
#define kHIDUsage_KeyboardRightShift                 0xE5    /* Right Shift */
#define kHIDUsage_KeyboardRightAlt                   0xE6    /* Right Alt */
#define kHIDUsage_KeyboardRightGUI                   0xE7    /* Right GUI */
#define kHIDPage_FIDO                                0xF1D0    /* Reserved 0xF1D1 - 0xFEFF */
#define kHIDPage_VendorDefinedStart                  0xFF00
#define kHIDUsage_Keyboard_Reserved                  0xFFFF

#endif /* OEHIDUsageTables_iOS_h */
