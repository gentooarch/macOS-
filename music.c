//clang -o music main.m -framework AudioToolbox -framework Foundation -framework MediaPlayer -framework AppKit
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <pthread.h>
#include <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AppKit/AppKit.h>

#define NUM_BUFFERS 3
#define SEEK_STEP_SEC 5.0 // 快进快退的步长（秒）

typedef struct {
    AudioFileID                  playbackFile;
    AudioQueueRef                queue;
    SInt64                       packetIndex;
    UInt32                       numPacketsToRead;
    AudioStreamPacketDescription *packetDescs;
    bool                         isDone;
    double                       duration;
    double                       sampleRate;
    char                         filename[256];
    // 新增：保存 Buffer 引用，以便在 Seek 时重新填充
    AudioQueueBufferRef          buffers[NUM_BUFFERS];
} PlayerState;

// 前向声明 (必须与定义保持一致，不加 static)
void HandleOutputBuffer(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer);

// 更新系统“正在播放”面板的状态
void updateNowPlaying(PlayerState *pState, bool isPlaying) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    double currentTime = 0;
    if (pState->sampleRate > 0) {
        currentTime = (double)pState->packetIndex / pState->sampleRate;
    }
    
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = [NSString stringWithUTF8String:pState->filename];
    info[MPMediaItemPropertyPlaybackDuration] = @(pState->duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? @1.0 : @0.0;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        center.nowPlayingInfo = info;
    });
}

// 执行跳转逻辑的核心函数
void performSeek(PlayerState *pState, double offsetSeconds) {
    // 1. 计算新的时间点
    double currentTime = (double)pState->packetIndex / pState->sampleRate;
    double targetTime = currentTime + offsetSeconds;
    
    // 边界检查
    if (targetTime < 0) targetTime = 0;
    if (targetTime > pState->duration) targetTime = pState->duration;
    
    // 2. 暂停并重置 AudioQueue (清除现有 Buffer 中的旧数据)
    AudioQueueReset(pState->queue);
    
    // 3. 更新 Packet Index
    pState->packetIndex = (SInt64)(targetTime * pState->sampleRate);
    
    // 4. 重新填充所有 Buffer
    for (int i = 0; i < NUM_BUFFERS; i++) {
        HandleOutputBuffer(pState, pState->queue, pState->buffers[i]);
    }
    
    // 5. 重新开始播放
    AudioQueueStart(pState->queue, NULL);
    
    // 6. 更新 UI
    updateNowPlaying(pState, true);
}

// 修复：去掉了 static 关键字，与前向声明保持一致
void HandleOutputBuffer(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    PlayerState *pState = (PlayerState *)inUserData;
    if (pState->isDone) return;

    UInt32 numBytesReadFromFile = inBuffer->mAudioDataBytesCapacity;
    UInt32 numPackets = pState->numPacketsToRead;

    OSStatus status = AudioFileReadPacketData(pState->playbackFile, false, &numBytesReadFromFile,
                           pState->packetDescs, pState->packetIndex, &numPackets, inBuffer->mAudioData);

    if (numPackets > 0) {
        inBuffer->mAudioDataByteSize = numBytesReadFromFile;
        status = AudioQueueEnqueueBuffer(inAQ, inBuffer, (pState->packetDescs ? numPackets : 0), pState->packetDescs);
        pState->packetIndex += numPackets;
    } else {
        if (status == noErr) {
             AudioQueueStop(inAQ, false);
             pState->isDone = true;
        }
    }
}

void setupRemoteCommands(PlayerState *pState) {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    
    [commandCenter.playCommand setEnabled:YES];
    [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        AudioQueueStart(pState->queue, NULL);
        updateNowPlaying(pState, true);
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.pauseCommand setEnabled:YES];
    [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        AudioQueuePause(pState->queue);
        updateNowPlaying(pState, false);
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    [commandCenter.togglePlayPauseCommand setEnabled:YES];
    [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        UInt32 isRunning;
        UInt32 size = sizeof(isRunning);
        AudioQueueGetProperty(pState->queue, kAudioQueueProperty_IsRunning, &isRunning, &size);
        if (isRunning) {
            AudioQueuePause(pState->queue);
            updateNowPlaying(pState, false);
        } else {
            AudioQueueStart(pState->queue, NULL);
            updateNowPlaying(pState, true);
        }
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.seekForwardCommand setEnabled:YES];
    [commandCenter.seekForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        performSeek(pState, SEEK_STEP_SEC);
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.seekBackwardCommand setEnabled:YES];
    [commandCenter.seekBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        performSeek(pState, -SEEK_STEP_SEC);
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

void setTerminalRawMode(bool enable) {
    static struct termios oldt, newt;
    if (enable) {
        tcgetattr(STDIN_FILENO, &oldt);
        newt = oldt;
        newt.c_lflag &= ~(ICANON | ECHO);
        tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    } else {
        tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    }
}

void *inputThread(void *arg) {
    PlayerState *state = (PlayerState *)arg;
    setTerminalRawMode(true);
    
    while (!state->isDone) {
        char c;
        if (read(STDIN_FILENO, &c, 1) > 0) {
            // 解析 ANSI 转义序列
            if (c == '\033') { // ESC
                char seq[2];
                // 尝试快速读取接下来的序列
                if (read(STDIN_FILENO, &seq[0], 1) > 0) {
                    if (read(STDIN_FILENO, &seq[1], 1) > 0) {
                        if (seq[0] == '[') {
                            if (seq[1] == 'C') { // 右箭头
                                performSeek(state, SEEK_STEP_SEC);
                            } else if (seq[1] == 'D') { // 左箭头
                                performSeek(state, -SEEK_STEP_SEC);
                            }
                        }
                    }
                }
                continue;
            }

            if (c == 'q') {
                state->isDone = true;
                break;
            }
            if (c == ' ') {
                UInt32 isRunning;
                UInt32 size = sizeof(isRunning);
                AudioQueueGetProperty(state->queue, kAudioQueueProperty_IsRunning, &isRunning, &size);
                if (isRunning) {
                    AudioQueuePause(state->queue);
                    updateNowPlaying(state, false);
                } else {
                    AudioQueueStart(state->queue, NULL);
                    updateNowPlaying(state, true);
                }
            }
        }
    }
    setTerminalRawMode(false);
    AudioQueueStop(state->queue, true);
    exit(0);
    return NULL;
}

int main(int argc, const char * argv[]) {
    if (argc < 2) {
        printf("Usage: %s <audio_file>\n", argv[0]);
        return 1;
    }

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        PlayerState *state = calloc(1, sizeof(PlayerState));
        strncpy(state->filename, argv[1], 255);

        CFURLRef fileURL = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), false);
        OSStatus status = AudioFileOpenURL(fileURL, kAudioFileReadPermission, 0, &state->playbackFile);
        CFRelease(fileURL);
        
        if (status != noErr) {
            printf("Error opening file\n");
            return 1;
        }

        AudioStreamBasicDescription dataFormat;
        UInt32 propSize = sizeof(dataFormat);
        AudioFileGetProperty(state->playbackFile, kAudioFilePropertyDataFormat, &propSize, &dataFormat);
        state->sampleRate = dataFormat.mSampleRate;
        
        Float64 totalDuration;
        propSize = sizeof(totalDuration);
        AudioFileGetProperty(state->playbackFile, kAudioFilePropertyEstimatedDuration, &propSize, &totalDuration);
        state->duration = totalDuration;

        AudioQueueNewOutput(&dataFormat, HandleOutputBuffer, state, NULL, NULL, 0, &state->queue);

        setupRemoteCommands(state);
        
        UInt32 maxPacketSize;
        propSize = sizeof(maxPacketSize);
        AudioFileGetProperty(state->playbackFile, kAudioFilePropertyPacketSizeUpperBound, &propSize, &maxPacketSize);
        
        state->numPacketsToRead = (state->sampleRate / 10);
        
        if (dataFormat.mBytesPerPacket == 0) 
            state->packetDescs = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * state->numPacketsToRead);

        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueAllocateBuffer(state->queue, state->numPacketsToRead * maxPacketSize, &state->buffers[i]);
            HandleOutputBuffer(state, state->queue, state->buffers[i]);
        }

        AudioQueueStart(state->queue, NULL);
        updateNowPlaying(state, true);

        pthread_t tid;
        pthread_create(&tid, NULL, inputThread, state);

        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (state->isDone) {
                [timer invalidate];
                CFRunLoopStop(CFRunLoopGetCurrent());
            }
            double displayTime = 0;
            if (state->sampleRate > 0)
                 displayTime = (double)state->packetIndex / state->sampleRate;
            
            printf("\r\033[KPlaying: %.1f / %.1f sec [Space: Pause, Arrows: Seek, q: Quit]", displayTime, state->duration);
            fflush(stdout);
        }];

        [[NSRunLoop currentRunLoop] run];
        
        AudioQueueDispose(state->queue, true);
        AudioFileClose(state->playbackFile);
        if (state->packetDescs) free(state->packetDescs);
        free(state);
    }
    return 0;
}
