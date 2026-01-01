#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <ctype.h>

#define MAX_LINE_LEN 1024
#define MAX_PROCESSES 1024

// 定义进程统计结构体
typedef struct {
    char name[64];
    unsigned long long total_bytes;
    int active;
} ProcessStat;

ProcessStat stats[MAX_PROCESSES];
int process_count = 0;

// 查找或创建进程统计条目
void add_bytes(char *proc_name, unsigned long long bytes) {
    for (int i = 0; i < process_count; i++) {
        if (strcmp(stats[i].name, proc_name) == 0) {
            stats[i].total_bytes += bytes;
            return;
        }
    }
    
    // 如果是新进程
    if (process_count < MAX_PROCESSES) {
        strncpy(stats[process_count].name, proc_name, 63);
        stats[process_count].name[63] = '\0'; // 确保结尾
        stats[process_count].total_bytes = bytes;
        process_count++;
    }
}

// 排序比较函数 (降序)
int compare_stats(const void *a, const void *b) {
    ProcessStat *statA = (ProcessStat *)a;
    ProcessStat *statB = (ProcessStat *)b;
    if (statB->total_bytes > statA->total_bytes) return 1;
    if (statB->total_bytes < statA->total_bytes) return -1;
    return 0;
}

// 格式化字节大小
void format_size(unsigned long long bytes, char *buffer) {
    if (bytes > 1024 * 1024 * 1024) {
        sprintf(buffer, "%.2f GB", (double)bytes / (1024.0 * 1024 * 1024));
    } else if (bytes > 1024 * 1024) {
        sprintf(buffer, "%.2f MB", (double)bytes / (1024.0 * 1024));
    } else if (bytes > 1024) {
        sprintf(buffer, "%.1f KB", (double)bytes / 1024.0);
    } else {
        sprintf(buffer, "%llu B", bytes);
    }
}

int main() {
    // 检查 root 权限
    if (geteuid() != 0) {
        printf("Error: Please run as root (sudo).\n");
        return 1;
    }

    FILE *fp;
    char line[MAX_LINE_LEN];
    
    // 打开管道执行 fs_usage
    // -w: 宽输出, -f filesys: 仅文件系统
    fp = popen("fs_usage -w -f filesys", "r");
    if (fp == NULL) {
        perror("Failed to run fs_usage");
        return 1;
    }

    printf("Starting C-based IO Monitor...\n");

    time_t last_print = time(NULL);

    while (fgets(line, sizeof(line), fp) != NULL) {
        // 1. 过滤非写入操作
        // 简单判断字符串中是否有 write 或 WrData
        if (strstr(line, "write") == NULL && strstr(line, "WrData") == NULL) {
            continue;
        }

        // 2. 解析 B=xxx (字节数)
        char *b_ptr = strstr(line, "B=");
        if (!b_ptr) continue;
        
        b_ptr += 2; // 跳过 "B="
        
        // strtoul 强大的地方：如果是 0x 开头，自动按16进制，否则按10进制
        unsigned long long bytes = strtoul(b_ptr, NULL, 0);

        // 3. 过滤 F=1 (stdout) 和 F=2 (stderr)
        char *f_ptr = strstr(line, "F=");
        if (f_ptr) {
            int fd = atoi(f_ptr + 2);
            if (fd == 1 || fd == 2) continue;
        }

        // 4. 解析进程名
        // 逻辑：将行按空格分割，取最后一部分。如果最后一部分以 '/' 开头(路径)，则取倒数第二部分。
        // 为了避免破坏原始 line (strtok 会破坏)，我们拷贝一份需要处理的尾部
        
        // 去除换行符
        line[strcspn(line, "\n")] = 0;
        
        char *last_token = NULL;
        char *second_last_token = NULL;
        char *token = strtok(line, " ");
        
        while (token != NULL) {
            second_last_token = last_token;
            last_token = token;
            token = strtok(NULL, " ");
        }

        char *proc_name = "Unknown";
        if (last_token) {
            if (last_token[0] == '/') {
                // 如果最后是路径，取倒数第二个做进程名
                if (second_last_token) proc_name = second_last_token;
            } else {
                // 否则最后那个就是进程名
                proc_name = last_token;
            }
        }

        // 过滤自身或 python
        if (strstr(proc_name, "fs_usage") || strstr(proc_name, "grep")) continue;

        // 5. 累加数据
        add_bytes(proc_name, bytes);

        // 6. 定时刷新 (每2秒)
        time_t now = time(NULL);
        if (difftime(now, last_print) >= 2.0) {
            // 清屏 (ANSI Escape Code)
            printf("\033[H\033[J");
            printf("%-40s | %-15s\n", "PROCESS (PID)", "TOTAL WRITTEN");
            printf("------------------------------------------------------------\n");
            
            // 排序
            qsort(stats, process_count, sizeof(ProcessStat), compare_stats);
            
            // 显示前 20 个
            int limit = process_count < 20 ? process_count : 20;
            for (int i = 0; i < limit; i++) {
                char size_str[32];
                format_size(stats[i].total_bytes, size_str);
                printf("%-40s | %-15s\n", stats[i].name, size_str);
            }
            
            printf("\n[Ctrl+C to Exit] Monitoring via C implementation.\n");
            last_print = now;
        }
    }

    pclose(fp);
    return 0;
}
