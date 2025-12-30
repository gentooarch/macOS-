//clang energy.c -o energy
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

// 处理 Ctrl+C 退出
void handle_sigint(int sig) {
    printf("\n[!] 停止监控...\n");
    exit(0);
}

int main() {
    // 捕获中断信号
    signal(SIGINT, handle_sigint);

    // -l 0: 持续运行（无限采样）
    // -s 2: 每 2 秒更新一次（Energy Impact 需要时间窗口计算，建议 2s+）
    // -n 30: 排名前 10
    // -o power: 按能效排序
    // -stats: 输出字段
    const char *cmd = "/usr/bin/top -l 0 -s 2 -n 10 -o power -stats pid,command,power";

    FILE *fp = popen(cmd, "r");
    if (fp == NULL) {
        perror("无法启动 top 命令");
        return 1;
    }

    char buffer[512];
    int is_first_sample = 1;

    // 清屏指令
    printf("\033[H\033[J"); 

    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        // 当 top 输出包含 "PID" 时，说明新的一帧数据开始了
        if (strstr(buffer, "PID") != NULL && strstr(buffer, "POWER") != NULL) {
            
            // 为了防止屏幕闪烁，我们只有在得到真实数据后才重置光标到左上角
            if (!is_first_sample) {
                printf("\033[H"); // 将光标移回顶部，覆盖旧内容
            }

            printf("macOS 能效实时监控 (Top 10) - 每 2 秒刷新\n");
            printf("按 Ctrl+C 退出程序\n");
            printf("==============================================================\n");
            printf("%-10s %-25s %-15s\n", "PID", "COMMAND", "ENERGY IMPACT");
            printf("--------------------------------------------------------------\n");
            
            is_first_sample = 0;
            continue;
        }

        // 只有非第一波采样（第一波通常是 0）且已经在数据区时才打印
        if (!is_first_sample && strlen(buffer) > 5) {
            // 打印每一行进程信息
            printf("%s", buffer);
        }
    }

    pclose(fp);
    return 0;
}
