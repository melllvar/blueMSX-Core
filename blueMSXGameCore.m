/*
 Copyright (c) 2014, OpenEmu Team
 
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

#import "blueMSXGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import <OpenGL/gl.h>
#import "OEMSXSystemResponderClient.h"

#include "ArchInput.h"
#include "ArchNotifications.h"
#include "Actions.h"
#include "JoystickPort.h"
#include "Machine.h"
#include "MidiIO.h"
#include "UartIO.h"
#include "Casette.h"
#include "Emulator.h"
#include "Board.h"
#include "Language.h"
#include "LaunchFile.h"
#include "PrinterIO.h"
#include "InputEvent.h"

#import "Emulator.h"
#include "ArchEvent.h"

#include "Properties.h"
#include "VideoRender.h"
#include "AudioMixer.h"
#include "CMCocoaBuffer.h"


#define SCREEN_BUFFER_WIDTH 320
#define SCREEN_WIDTH        272
#define SCREEN_DEPTH         32
#define SCREEN_HEIGHT       240

#define SOUND_SAMPLE_RATE     44100
#define SOUND_FRAME_SIZE      8192
#define SOUND_BYTES_PER_FRAME 2

#define virtualCodeSet(eventCode) self->virtualCodeMap[eventCode] = 1
#define virtualCodeUnset(eventCode) self->virtualCodeMap[eventCode] = 0
#define virtualCodeClear() memset(self->virtualCodeMap, 0, sizeof(self->virtualCodeMap));

@interface blueMSXGameCore () <OEMSXSystemResponderClient>
{
    int virtualCodeMap[256];
    int currentScreenIndex;
    NSString *fileToLoad;
    RomType romTypeToLoad;
    Properties *properties;
    Video *video;
    Mixer *mixer;
    CMCocoaBuffer *screens[2];
    NSLock *bufferLock;
}

- (void)initializeEmulator;
- (void)renderFrame;

@end

static blueMSXGameCore *_core;
static Int32 mixAudio(void *param, Int16 *buffer, UInt32 count);

@implementation blueMSXGameCore

- (id)init
{
    if ((self = [super init]))
    {
        currentScreenIndex = 0;
        bufferLock = [[NSLock alloc] init];
        _core = self;
        for (int i = 0; i < 2; i++)
            screens[i] = [[CMCocoaBuffer alloc] initWithWidth:SCREEN_BUFFER_WIDTH
                                                       height:SCREEN_HEIGHT
                                                        depth:SCREEN_DEPTH
                                                         zoom:1];
    }

    return self;
}

- (void)dealloc
{
    videoDestroy(video);
    propDestroy(properties);
    mixerSetWriteCallback(mixer, NULL, NULL, 0);
    mixerDestroy(mixer);
}

- (void)initializeEmulator
{
    NSString *resourcePath = [[[self owner] bundle] resourcePath];
    
    __block NSString *machinesPath = [resourcePath stringByAppendingPathComponent:@"Machines"];
    __block NSString *machineName = @"MSX2 - C-BIOS";
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *supportPath = [NSURL fileURLWithPath:[self supportDirectoryPath]];
    NSURL *customMachinesPath = [supportPath URLByAppendingPathComponent:@"Machines"];

    if ([customMachinesPath checkResourceIsReachableAndReturnError:NULL] == YES)
    {
        NSArray *customMachines = [fm contentsOfDirectoryAtURL:customMachinesPath
                                    includingPropertiesForKeys:nil
                                                       options:NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:NULL];
        
        [customMachines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop)
        {
            NSString *customMachine = [[obj lastPathComponent] stringByDeletingPathExtension];
            
            machinesPath = [customMachinesPath path];
            machineName = customMachine;
            
            NSLog(@"blueMSX: Will use custom machine \"%@\"", customMachine);

            *stop = YES;
        }];
    }
    else
    {
        [fm createDirectoryAtURL:customMachinesPath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
    }
    
    properties = propCreate(0, 0, P_KBD_EUROPEAN, 0, "");
    
    // Set machine name
    machineSetDirectory([machinesPath UTF8String]);
    strncpy(properties->emulation.machineName,
            [machineName UTF8String], PROP_MAXPATH - 1);
    
    // Set up properties
    properties->emulation.speed = 50;
    properties->emulation.syncMethod = P_EMU_SYNCTOVBLANKASYNC;
    properties->emulation.enableFdcTiming = YES;
    properties->emulation.vdpSyncMode = 0;
    
    properties->video.brightness = 100;
    properties->video.contrast = 100;
    properties->video.saturation = 100;
    properties->video.gamma = 100;
    properties->video.colorSaturationWidth = 0;
    properties->video.colorSaturationEnable = NO;
    properties->video.deInterlace = YES;
    properties->video.monitorType = 0;
    properties->video.monitorColor = 0;
    properties->video.scanlinesPct = 100;
    properties->video.scanlinesEnable = (properties->video.scanlinesPct < 100);
    
    properties->sound.mixerChannel[MIXER_CHANNEL_PSG].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_PSG].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_PSG].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_SCC].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_SCC].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_SCC].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXMUSIC].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXMUSIC].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXMUSIC].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXAUDIO].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXAUDIO].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_MSXAUDIO].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_KEYBOARD].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_KEYBOARD].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_KEYBOARD].enable = YES;
    properties->sound.mixerChannel[MIXER_CHANNEL_MOONSOUND].volume = 100;
    properties->sound.mixerChannel[MIXER_CHANNEL_MOONSOUND].pan = 50;
    properties->sound.mixerChannel[MIXER_CHANNEL_MOONSOUND].enable = YES;
    
    properties->joy1.typeId = JOYSTICK_PORT_JOYSTICK;
    properties->joy2.typeId = JOYSTICK_PORT_JOYSTICK;
    
    // Init video
    video = videoCreate();
    videoSetColors(video, properties->video.saturation, properties->video.brightness,
                   properties->video.contrast, properties->video.gamma);
    videoSetScanLines(video, properties->video.scanlinesEnable, properties->video.scanlinesPct);
    videoSetColorSaturation(video, properties->video.colorSaturationEnable, properties->video.colorSaturationWidth);
    videoSetColorMode(video, properties->video.monitorColor);
    videoSetRgbMode(video, 1);
    videoUpdateAll(video, properties);
    
    // Init translations (unused for the most part)
    langSetLanguage(properties->language);
    langInit();
    
    // Init input
    joystickPortSetType(0, properties->joy1.typeId);
    joystickPortSetType(1, properties->joy2.typeId);
    
    // Init misc. devices
    printerIoSetType(properties->ports.Lpt.type, properties->ports.Lpt.fileName);
    printerIoSetType(properties->ports.Lpt.type, properties->ports.Lpt.fileName);
    uartIoSetType(properties->ports.Com.type, properties->ports.Com.fileName);
    midiIoSetMidiOutType(properties->sound.MidiOut.type, properties->sound.MidiOut.fileName);
    midiIoSetMidiInType(properties->sound.MidiIn.type, properties->sound.MidiIn.fileName);
    ykIoSetMidiInType(properties->sound.YkIn.type, properties->sound.YkIn.fileName);
    
    // Init mixer
    mixer = mixerCreate();
    
    for (int i = 0; i < MIXER_CHANNEL_TYPE_COUNT; i++)
    {
        mixerSetChannelTypeVolume(mixer, i, properties->sound.mixerChannel[i].volume);
        mixerSetChannelTypePan(mixer, i, properties->sound.mixerChannel[i].pan);
        mixerEnableChannelType(mixer, i, properties->sound.mixerChannel[i].enable);
    }
    
    mixerSetMasterVolume(mixer, properties->sound.masterVolume);
    mixerEnableMaster(mixer, properties->sound.masterEnable);
    mixerSetStereo(mixer, YES);
    mixerSetWriteCallback(mixer, mixAudio,
                          (__bridge void *)[self ringBufferAtIndex:0],
                          SOUND_FRAME_SIZE);
    
    // Init media DB
    mediaDbLoad([[resourcePath stringByAppendingPathComponent:@"Databases"] UTF8String]);
    mediaDbSetDefaultRomType(properties->cartridge.defaultType);
    
    // Init board
    boardSetFdcTimingEnable(properties->emulation.enableFdcTiming);
    boardSetY8950Enable(properties->sound.chip.enableY8950);
    boardSetYm2413Enable(properties->sound.chip.enableYM2413);
    boardSetMoonsoundEnable(properties->sound.chip.enableMoonsound);
    boardSetVideoAutodetect(properties->video.detectActiveMonitor);
    boardEnableSnapshots(0);
    
    // Init storage
    for (int i = 0; i < PROP_MAX_CARTS; i++)
    {
        if (properties->media.carts[i].fileName[0])
            insertCartridge(properties, i, properties->media.carts[i].fileName,
                            properties->media.carts[i].fileNameInZip,
                            properties->media.carts[i].type, -1);
    }
    
    for (int i = 0; i < PROP_MAX_DISKS; i++)
    {
        if (properties->media.disks[i].fileName[0])
            insertDiskette(properties, i, properties->media.disks[i].fileName,
                           properties->media.disks[i].fileNameInZip, -1);
    }
    
    for (int i = 0; i < PROP_MAX_TAPES; i++)
    {
        if (properties->media.tapes[i].fileName[0])
            insertCassette(properties, i, properties->media.tapes[i].fileName,
                           properties->media.tapes[i].fileNameInZip, 0);
    }
    
    tapeSetReadOnly(properties->cassette.readOnly);
    
    // Misc. initialization
    emulatorInit(properties, mixer);
    actionInit(video, properties, mixer);
    emulatorRestartSound();
}

- (void)startEmulation
{
    [super startEmulation];
    
    // propertiesSetDirectory("", "");
    // tapeSetDirectory("/Cassettes", "");

    NSURL *batterySavesPath = [NSURL fileURLWithPath:[self batterySavesDirectoryPath]];
    [[NSFileManager defaultManager] createDirectoryAtURL:batterySavesPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    
    boardSetDirectory([[self batterySavesDirectoryPath] UTF8String]);

    tryLaunchUnknownFile(properties, [fileToLoad UTF8String], NO);
}

- (void)stopEmulation
{
    emulatorSuspend();
    emulatorStop();
    
    [super stopEmulation];
}

- (void)setPauseEmulation:(BOOL)pauseEmulation
{
    if (pauseEmulation)
        emulatorSetState(EMU_PAUSED);
    else
        emulatorSetState(EMU_RUNNING);
    
    [super setPauseEmulation:pauseEmulation];
}

- (void)resetEmulation
{
    actionEmuResetSoft();
}

- (void)fastForward:(BOOL)flag
{
    [super fastForward:flag];
    
    properties->emulation.speed = flag ? 100 : 50;
    emulatorSetFrequency(properties->emulation.speed, NULL);
}

- (oneway void)didPushMSXJoystickButton:(OEMSXJoystickButton)button
                             controller:(NSInteger)index
{
    int code = -1;
    
    switch (button)
    {
    case OEMSXJoystickUp:
        code = (index == 1) ? EC_JOY1_UP : EC_JOY2_UP;
        break;
    case OEMSXJoystickDown:
        code = (index == 1) ? EC_JOY1_DOWN : EC_JOY2_DOWN;
        break;
    case OEMSXJoystickLeft:
        code = (index == 1) ? EC_JOY1_LEFT : EC_JOY2_LEFT;
        break;
    case OEMSXJoystickRight:
        code = (index == 1) ? EC_JOY1_RIGHT : EC_JOY2_RIGHT;
        break;
    case OEMSXButtonA:
        code = (index == 1) ? EC_JOY1_BUTTON1 : EC_JOY2_BUTTON1;
        break;
    case OEMSXButtonB:
        code = (index == 1) ? EC_JOY1_BUTTON2 : EC_JOY2_BUTTON2;
        break;
    default:
        break;
    }
    
    if (code != -1)
        virtualCodeSet(code);
}

- (oneway void)didReleaseMSXJoystickButton:(OEMSXJoystickButton)button
                                controller:(NSInteger)index
{
    int code = -1;
    
    switch (button)
    {
    case OEMSXJoystickUp:
        code = (index == 1) ? EC_JOY1_UP : EC_JOY2_UP;
        break;
    case OEMSXJoystickDown:
        code = (index == 1) ? EC_JOY1_DOWN : EC_JOY2_DOWN;
        break;
    case OEMSXJoystickLeft:
        code = (index == 1) ? EC_JOY1_LEFT : EC_JOY2_LEFT;
        break;
    case OEMSXJoystickRight:
        code = (index == 1) ? EC_JOY1_RIGHT : EC_JOY2_RIGHT;
        break;
    case OEMSXButtonA:
        code = (index == 1) ? EC_JOY1_BUTTON1 : EC_JOY2_BUTTON1;
        break;
    case OEMSXButtonB:
        code = (index == 1) ? EC_JOY1_BUTTON2 : EC_JOY2_BUTTON2;
        break;
    default:
        break;
    }
    
    if (code != -1)
        virtualCodeUnset(code);
}

- (oneway void)didPressKey:(OEMSXKey)key
{
    virtualCodeSet(key);
}

- (oneway void)didReleaseKey:(OEMSXKey)key
{
    virtualCodeUnset(key);
}

- (void)executeFrame
{
    // Update controls
    memcpy(eventMap, _core->virtualCodeMap, sizeof(_core->virtualCodeMap));
}

- (void)renderFrame
{
    [bufferLock lock];
    
    FrameBuffer* frameBuffer = frameBufferFlipViewFrame(properties->emulation.syncMethod == P_EMU_SYNCTOVBLANKASYNC);
    CMCocoaBuffer *currentScreen = screens[currentScreenIndex];
    
    char* dpyData = currentScreen->pixels;
    int width = currentScreen->actualWidth;
    int height = currentScreen->actualHeight;
    
    if (frameBuffer == NULL)
        frameBuffer = frameBufferGetWhiteNoiseFrame();
    
    int borderWidth = (SCREEN_BUFFER_WIDTH - frameBuffer->maxWidth) * currentScreen->zoom / 2;
    
    videoRender(video, frameBuffer, currentScreen->depth, currentScreen->zoom,
                dpyData + borderWidth * currentScreen->bytesPerPixel, 0,
                currentScreen->pitch, -1);
    
    if (borderWidth > 0)
    {
        int h = height;
        while (h--)
        {
            memset(dpyData, 0, borderWidth * currentScreen->bytesPerPixel);
            memset(dpyData + (width - borderWidth) * currentScreen->bytesPerPixel,
                   0, borderWidth * currentScreen->bytesPerPixel);
            
            dpyData += currentScreen->pitch;
        }
    }
    
    currentScreenIndex ^= 1;
    
    [bufferLock unlock];
}

#pragma mark - OE I/O

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    [self initializeEmulator];
    
    fileToLoad = nil;
    romTypeToLoad = ROM_UNKNOWN;
    
    const char *cpath = [path UTF8String];
    MediaType *mediaType = mediaDbLookupRomByPath(cpath);
    if (!mediaType)
        mediaType = mediaDbGuessRomByPath(cpath);
    
    if (mediaType)
        romTypeToLoad = mediaDbGetRomType(mediaType);
    
    fileToLoad = path;
    
    return YES;
}

- (BOOL)saveStateToFileAtPath:(NSString *)fileName
{
    emulatorSuspend();
    boardSaveState([fileName UTF8String], 1);
    emulatorResume();

    return YES;
}

- (BOOL)loadStateFromFileAtPath:(NSString *)fileName
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        emulatorSuspend();
        emulatorStop();
        emulatorStart([fileName UTF8String]);
    });

    return YES;
}

#pragma mark - OE Video

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(screens[0]->actualWidth, screens[0]->actualHeight);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake((SCREEN_BUFFER_WIDTH - SCREEN_WIDTH) / 2, 0,
                         SCREEN_WIDTH, screens[0]->actualHeight);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(17, 15);
}

- (const void *)videoBuffer
{
    return screens[currentScreenIndex]->pixels;
}

- (GLenum)pixelFormat
{
    return GL_RGBA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_BYTE;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB;
}

#pragma mark - OE Audio

- (double)audioSampleRate
{
    return SOUND_SAMPLE_RATE;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Audio

static Int32 mixAudio(void *param, Int16 *buffer, UInt32 count)
{
    OERingBuffer *soundBuffer = (__bridge OERingBuffer *)param;
    [soundBuffer write:(uint8_t *)buffer maxLength:count * SOUND_BYTES_PER_FRAME];
    
    return 0;
}

#pragma mark - blueMSX callbacks

#pragma mark - Emulation callbacks

void archEmulationStartNotification()
{
}

void archEmulationStopNotification()
{
}

void archEmulationStartFailure()
{
}

#pragma mark - Debugging callbacks

void archTrap(UInt8 value)
{
}

#pragma mark - Input Callbacks

void archPollInput()
{
}

UInt8 archJoystickGetState(int joystickNo)
{
    return 0; // Coleco-specific; unused
}

void archKeyboardSetSelectedKey(int keyCode)
{
}

#pragma mark - Mouse Callbacks

void archMouseGetState(int *dx, int *dy)
{
    // FIXME
//    @autoreleasepool
//    {
//        NSPoint coordinates = theEmulator.mouse.pointerCoordinates;
//        *dx = (int)coordinates.x;
//        *dy = (int)coordinates.y;
//    }
}

int archMouseGetButtonState(int checkAlways)
{
    // FIXME
//    @autoreleasepool
//    {
//        return theEmulator.mouse.buttonState;
//    }
    return 0;
}

void archMouseEmuEnable(AmEnableMode mode)
{
    // FIXME
//    @autoreleasepool
//    {
//        theEmulator.mouse.mouseMode = mode;
//    }
}

void archMouseSetForceLock(int lock)
{
}

#pragma mark - Sound callbacks

void archSoundCreate(Mixer* mixer, UInt32 sampleRate, UInt32 bufferSize, Int16 channels)
{
}

void archSoundDestroy()
{
}

void archSoundResume()
{
}

void archSoundSuspend()
{
}

#pragma mark - Video callbacks

int archUpdateEmuDisplay(int syncMode)
{
    [_core renderFrame];
    
    return 1;
}

void archUpdateWindow()
{
}

void *archScreenCapture(ScreenCaptureType type, int *bitmapSize, int onlyBmp)
{
    return NULL;
}

@end
