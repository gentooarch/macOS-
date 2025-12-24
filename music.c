#include <stdio.h>
#include <stdlib.h>
#include <termios.h>
#include <unistd.h>
#include <AudioToolbox/AudioToolbox.h>

#define NUM_BUFFERS 3
#define SEEK_STEP 5 // 秒

typedef struct {
    AudioFileID                  playbackFile;
    SInt64                       packetIndex;
    UInt32                       numPacketsToRead;
    AudioStreamPacketDescription *packetDescs;
    bool                         isDone;
    double                       duration;
    double                       sampleRate;
} PlayerState;

// 格式化时间显示
void formatTime(double seconds, char* buf) {
    int h = (int)seconds / 3600;
    int m = ((int)seconds % 3600) / 60;
    int s = (int)seconds % 60;
    sprintf(buf, "%02d:%02d:%02d", h, m, s);
}

// 音频回调函数：当缓冲区空闲时，系统会自动调用此函数填充数据
static void HandleOutputBuffer(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    PlayerState *pState = (PlayerState *)inUserData;
    if (pState->isDone) return;

    UInt32 numBytesReadFromFile = inBuffer->mAudioDataBytesCapacity;
    UInt32 numPackets = pState->numPacketsToRead;

    OSStatus status = AudioFileReadPacketData(pState->playbackFile, false, &numBytesReadFromFile, 
                                              pState->packetDescs, pState->packetIndex, &numPackets, inBuffer->mAudioData);

    if (numPackets > 0) {
        inBuffer->mAudioDataByteSize = numBytesReadFromFile;
        AudioQueueEnqueueBuffer(inAQ, inBuffer, (pState->packetDescs ? numPackets : 0), pState->packetDescs);
        pState->packetIndex += numPackets;
    } else {
        AudioQueueStop(inAQ, false);
        pState->isDone = true;
    }
}

// 终端原始模式切换（用于即时捕获按键）
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

int main(int argc, const char * argv[]) {
    if (argc < 2) {
        printf("Usage: %s <audio_file>\n", argv[0]);
        return 1;
    }

    PlayerState state = {0};
    CFURLRef fileURL = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), false);

    // 1. 打开音频文件
    AudioFileOpenURL(fileURL, kAudioFileReadPermission, 0, &state.playbackFile);
    CFRelease(fileURL);

    // 2. 获取数据格式
    AudioStreamBasicDescription dataFormat;
    UInt32 propSize = sizeof(dataFormat);
    AudioFileGetProperty(state.playbackFile, kAudioFilePropertyDataFormat, &propSize, &dataFormat);
    state.sampleRate = dataFormat.mSampleRate;

    // 获取总时长
    Float64 totalDuration;
    propSize = sizeof(totalDuration);
    AudioFileGetProperty(state.playbackFile, kAudioFilePropertyEstimatedDuration, &propSize, &totalDuration);
    state.duration = totalDuration;

    // 3. 创建播放队列
    AudioQueueRef queue;
    AudioQueueNewOutput(&dataFormat, HandleOutputBuffer, &state, NULL, NULL, 0, &queue);

    // 4. 计算并分配缓冲区
    UInt32 maxPacketSize;
    propSize = sizeof(maxPacketSize);
    AudioFileGetProperty(state.playbackFile, kAudioFilePropertyPacketSizeUpperBound, &propSize, &maxPacketSize);

    // 设定每秒读取的包数量
    state.numPacketsToRead = (state.sampleRate / 10); // 100ms per buffer
    if (state.numPacketsToRead == 0) state.numPacketsToRead = 1;
    UInt32 bufferByteSize = state.numPacketsToRead * maxPacketSize;

    if (dataFormat.mBytesPerPacket == 0 || dataFormat.mFramesPerPacket == 0) {
        state.packetDescs = (AudioStreamPacketDescription *)malloc(sizeof(AudioStreamPacketDescription) * state.numPacketsToRead);
    }

    AudioQueueBufferRef buffers[NUM_BUFFERS];
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueAllocateBuffer(queue, bufferByteSize, &buffers[i]);
        HandleOutputBuffer(&state, queue, buffers[i]);
    }

    // 5. 开始播放
    AudioQueueStart(queue, NULL);
    printf("Playing: %s\n", argv[1]);
    printf("Controls: [Space] Pause/Play, [Left/Right] Seek, [Q] Quit\n");

    setTerminalRawMode(true);
    
    char curTimeStr[16], totalTimeStr[16];
    formatTime(state.duration, totalTimeStr);

    bool running = true;
    while (running && !state.isDone) {
        // 获取当前播放时间
        AudioTimeStamp outTimeStamp;
        AudioQueueGetCurrentTime(queue, NULL, &outTimeStamp, NULL);
        double currentTime = outTimeStamp.mSampleTime / state.sampleRate;
        
        // 由于 Seek 可能会让时间轴产生偏移，简单处理一下
        static double seekOffset = 0;
        formatTime(currentTime + seekOffset, curTimeStr);

        printf("\rA: %s / %s (%.0f%%)   ", curTimeStr, totalTimeStr, (currentTime+seekOffset)/state.duration*100);
        fflush(stdout);

        // 处理键盘输入
        struct timeval tv = {0L, 100000L}; // 100ms timeout
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(STDIN_FILENO, &fds);
        if (select(STDIN_FILENO + 1, &fds, NULL, NULL, &tv) > 0) {
            char c;
            read(STDIN_FILENO, &c, 1);
            if (c == 'q' || c == 'Q') running = false;
            if (c == ' ') {
                UInt32 isRunning;
                UInt32 size = sizeof(isRunning);
                AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &isRunning, &size);
                if (isRunning) AudioQueuePause(queue); else AudioQueueStart(queue, NULL);
            }
            if (c == '\033') { // 处理方向键 (Esc [ ...)
                read(STDIN_FILENO, &c, 1); 
                read(STDIN_FILENO, &c, 1);
                double jump = 0;
                if (c == 'C') jump = SEEK_STEP;  // Right
                if (c == 'D') jump = -SEEK_STEP; // Left
                
                if (jump != 0) {
                    AudioQueueStop(queue, true);
                    double target = (currentTime + seekOffset) + jump;
                    if (target < 0) target = 0;
                    seekOffset = target;
                    state.packetIndex = (SInt64)(target * state.sampleRate / dataFormat.mFramesPerPacket);
                    for (int i = 0; i < NUM_BUFFERS; i++) HandleOutputBuffer(&state, queue, buffers[i]);
                    AudioQueueStart(queue, NULL);
                }
            }
        }
    }

    printf("\nDone.\n");
    setTerminalRawMode(false);
    AudioQueueDispose(queue, true);
    AudioFileClose(state.playbackFile);
    if (state.packetDescs) free(state.packetDescs);

    return 0;
}
