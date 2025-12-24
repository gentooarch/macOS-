//clang -framework AudioToolbox -framework Foundation -framework MediaPlayer -framework AppKit main.m -o player

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AppKit/AppKit.h>

#define NUM_BUFFERS 3
#define SEEK_STEP_SEC 5.0

typedef struct {
    ExtAudioFileRef              playbackFile;
    AudioQueueRef                queue;
    AudioStreamBasicDescription  clientFormat;
    SInt64                       totalFrames;
    double                       sampleRate;
    double                       duration;
    char                         filename[256];
    bool                         isDone;
    bool                         isPaused;
    AudioQueueBufferRef          buffers[NUM_BUFFERS];
    dispatch_source_t            uiTimer;
} PlayerState;

void HandleOutputBuffer(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);

void updateNowPlaying(PlayerState *pState, bool isPlaying) {
    pState->isPaused = !isPlaying;
    SInt64 currentFrame = 0;
    ExtAudioFileTell(pState->playbackFile, &currentFrame);
    double elapsed = (double)currentFrame / pState->sampleRate;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = [NSString stringWithUTF8String:pState->filename];
    info[MPMediaItemPropertyPlaybackDuration] = @(pState->duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? @1.0 : @0.0;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
    });
}

void resumePlayback(PlayerState *pState) {
    AudioQueuePrime(pState->queue, 0, NULL);
    AudioQueueStart(pState->queue, NULL);
    updateNowPlaying(pState, true);
}

void pausePlayback(PlayerState *pState) {
    AudioQueuePause(pState->queue);
    updateNowPlaying(pState, false);
}

void performSeek(PlayerState *pState, double offsetSeconds) {
    SInt64 currentFrame = 0;
    ExtAudioFileTell(pState->playbackFile, &currentFrame);
    SInt64 targetFrame = currentFrame + (SInt64)(offsetSeconds * pState->sampleRate);
    if (targetFrame < 0) targetFrame = 0;
    if (targetFrame > pState->totalFrames) targetFrame = pState->totalFrames;
    
    AudioQueueStop(pState->queue, true); 
    ExtAudioFileSeek(pState->playbackFile, targetFrame);
    for (int i = 0; i < NUM_BUFFERS; i++) HandleOutputBuffer(pState, pState->queue, pState->buffers[i]);
    resumePlayback(pState);
}

void HandleOutputBuffer(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    PlayerState *pState = (PlayerState *)inUserData;
    if (pState->isDone) return;
    UInt32 frameCount = inBuffer->mAudioDataBytesCapacity / pState->clientFormat.mBytesPerFrame;
    AudioBufferList bufferList = { .mNumberBuffers = 1, .mBuffers[0] = { 
        .mNumberChannels = pState->clientFormat.mChannelsPerFrame,
        .mDataByteSize = inBuffer->mAudioDataBytesCapacity, .mData = inBuffer->mAudioData } 
    };
    if (ExtAudioFileRead(pState->playbackFile, &frameCount, &bufferList) == noErr && frameCount > 0) {
        inBuffer->mAudioDataByteSize = bufferList.mBuffers[0].mDataByteSize;
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    } else {
        AudioQueueStop(inAQ, false);
        pState->isDone = true;
    }
}

void setupRemoteCommands(PlayerState *pState) {
    MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
    [cc.playCommand setEnabled:YES];
    [cc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { resumePlayback(pState); return 0; }];
    [cc.pauseCommand setEnabled:YES];
    [cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) { pausePlayback(pState); return 0; }];
    [cc.togglePlayPauseCommand setEnabled:YES];
    [cc.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        pState->isPaused ? resumePlayback(pState) : pausePlayback(pState); return 0;
    }];
    [cc.seekForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e){ performSeek(pState, SEEK_STEP_SEC); return 0; }];
    [cc.seekBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e){ performSeek(pState, -SEEK_STEP_SEC); return 0; }];
}

void setTerminalRawMode(bool enable) {
    static struct termios oldt, newt;
    if (enable) {
        tcgetattr(STDIN_FILENO, &oldt);
        newt = oldt; newt.c_lflag &= ~(ICANON | ECHO);
        tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    } else tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
}

int main(int argc, const char * argv[]) {
    if (argc < 2) { printf("Usage: %s <file>\n", argv[0]); return 1; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        PlayerState *state = calloc(1, sizeof(PlayerState));
        strncpy(state->filename, argv[1], 255);
        CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (__bridge CFStringRef)[NSString stringWithUTF8String:argv[1]], kCFURLPOSIXPathStyle, false);
        if (ExtAudioFileOpenURL(url, &state->playbackFile) != noErr) { printf("File error\n"); return 1; }
        CFRelease(url);

        AudioStreamBasicDescription fFmt; UInt32 ps = sizeof(fFmt);
        ExtAudioFileGetProperty(state->playbackFile, kExtAudioFileProperty_FileDataFormat, &ps, &fFmt);
        state->sampleRate = (fFmt.mSampleRate > 0) ? fFmt.mSampleRate : 44100;
        state->clientFormat = (AudioStreamBasicDescription){ .mSampleRate = state->sampleRate, .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBitsPerChannel = 32, .mChannelsPerFrame = fFmt.mChannelsPerFrame, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * fFmt.mChannelsPerFrame, .mBytesPerPacket = 4 * fFmt.mChannelsPerFrame };
        ExtAudioFileSetProperty(state->playbackFile, kExtAudioFileProperty_ClientDataFormat, sizeof(state->clientFormat), &state->clientFormat);
        ps = sizeof(state->totalFrames);
        ExtAudioFileGetProperty(state->playbackFile, kExtAudioFileProperty_FileLengthFrames, &ps, &state->totalFrames);
        state->duration = (double)state->totalFrames / state->sampleRate;

        AudioQueueNewOutput(&state->clientFormat, HandleOutputBuffer, state, NULL, NULL, 0, &state->queue);
        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueAllocateBuffer(state->queue, 128*1024, &state->buffers[i]);
            HandleOutputBuffer(state, state->queue, state->buffers[i]);
        }
        setupRemoteCommands(state);
        resumePlayback(state);

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            setTerminalRawMode(true);
            while (!state->isDone) {
                char c;
                if (read(STDIN_FILENO, &c, 1) > 0) {
                    if (c == 'q') { state->isDone = true; break; }
                    if (c == ' ') { state->isPaused ? resumePlayback(state) : pausePlayback(state); }
                    if (c == '\033') {
                        char seq[2]; if (read(STDIN_FILENO, &seq[0], 1) > 0 && read(STDIN_FILENO, &seq[1], 1) > 0) {
                            if (seq[1] == 'C') performSeek(state, SEEK_STEP_SEC);
                            if (seq[1] == 'D') performSeek(state, -SEEK_STEP_SEC);
                        }
                    }
                }
            }
            setTerminalRawMode(false);
            printf("\nFinished: %s\n", state->filename);
            exit(0);
        });

        state->uiTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(state->uiTimer, DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC, 0.05 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(state->uiTimer, ^{
            SInt64 cf = 0; ExtAudioFileTell(state->playbackFile, &cf);
            double cur = (double)cf/state->sampleRate;
            int curM = (int)cur/60, curS = (int)cur%60;
            int durM = (int)state->duration/60, durS = (int)state->duration%60;
            
            // 使用纯文本状态显示，去除了 Emoji 图标
            printf("\r\033[2K%s [%02d:%02d / %02d:%02d] (Space: Pause, Arrows: Seek, Q: Quit)", 
                   state->isPaused ? "PAUSED " : "PLAYING", 
                   curM, curS, durM, durS);
            fflush(stdout);
        });
        dispatch_resume(state->uiTimer);
        CFRunLoopRun();
    }
    return 0;
}
