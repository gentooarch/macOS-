#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/sysctl.h>

// 定义一个结构体来存储我们需要的信息
typedef struct {
    pid_t pid;
    char name[256];
    uint64_t memory_bytes; // 实际物理内存 (Resident Size)
} ProcessInfo;

// 格式化文件大小的辅助函数 (KB, MB, GB)
void format_size(uint64_t bytes, char *buffer, size_t buf_len) {
    const char *suffixes[] = {"B", "KB", "MB", "GB", "TB"};
    int i = 0;
    double dblBytes = bytes;

    if (bytes > 1024) {
        for (i = 0; (bytes / 1024) > 0 && i < 4; i++, bytes /= 1024) {
            dblBytes = bytes / 1024.0;
        }
    }
    
    // 如果是 MB 或 GB，保留两位小数，否则整数
    if (i >= 2) {
        snprintf(buffer, buf_len, "%.2f %s", dblBytes, suffixes[i]);
    } else {
        snprintf(buffer, buf_len, "%llu %s", bytes, suffixes[i]);
    }
}

// qsort 的比较函数：按内存从大到小排序
int compare_processes(const void *a, const void *b) {
    const ProcessInfo *p1 = (const ProcessInfo *)a;
    const ProcessInfo *p2 = (const ProcessInfo *)b;

    if (p2->memory_bytes > p1->memory_bytes) return 1;
    if (p2->memory_bytes < p1->memory_bytes) return -1;
    return 0;
}

int main() {
    // 1. 获取系统中所有 PID 的数量
    // proc_listpids 返回的是缓冲区所需的字节数，不是 PID 个数
    int buffer_size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (buffer_size <= 0) {
        perror("Failed to get pid list size");
        return 1;
    }

    // 2. 分配内存并获取 PID 列表
    pid_t *pids = malloc(buffer_size);
    if (!pids) {
        perror("Out of memory");
        return 1;
    }
    
    // 重新调用以填充数据
    int actual_size = proc_listpids(PROC_ALL_PIDS, 0, pids, buffer_size);
    int num_pids = actual_size / sizeof(pid_t);

    // 3. 准备存储进程详情的数组
    ProcessInfo *proc_list = malloc(num_pids * sizeof(ProcessInfo));
    if (!proc_list) {
        free(pids);
        perror("Out of memory for process list");
        return 1;
    }

    int count = 0;
    struct proc_taskinfo pti;

    // 4. 遍历所有 PID 获取详细信息
    for (int i = 0; i < num_pids; i++) {
        if (pids[i] == 0) continue; // 跳过 kernel_task (通常无法获取常规 info)

        // 获取任务信息 (包含内存统计)
        // PROC_PIDTASKINFO 是获取内存使用的关键 flavor
        int ret = proc_pidinfo(pids[i], PROC_PIDTASKINFO, 0, &pti, sizeof(pti));
        
        if (ret == sizeof(pti)) {
            proc_list[count].pid = pids[i];
            
            // pti_resident_size 是实际物理内存驻留集大小 (RSS)
            proc_list[count].memory_bytes = pti.pti_resident_size;

            // 获取进程名称
            int name_len = proc_name(pids[i], proc_list[count].name, sizeof(proc_list[count].name));
            if (name_len <= 0) {
                strcpy(proc_list[count].name, "<unknown>");
            }

            count++;
        }
    }

    // 5. 排序
    qsort(proc_list, count, sizeof(ProcessInfo), compare_processes);

    // 6. 打印表头
    printf("%-8s  %-30s  %s\n", "PID", "NAME", "MEMORY (RSS)");
    printf("----------------------------------------------------------\n");

    // 打印前 20 个占用最高的进程 (或者打印全部，这里限制一下避免刷屏)
    int limit = 100; 
    if (count < limit) limit = count;

    char mem_str[32];
    for (int i = 0; i < limit; i++) {
        format_size(proc_list[i].memory_bytes, mem_str, sizeof(mem_str));
        // 限制名字长度打印，防止不对齐
        printf("%-8d  %-30.30s  %s\n", proc_list[i].pid, proc_list[i].name, mem_str);
    }

    printf("----------------------------------------------------------\n");
    printf("Showing top %d of %d processes.\n", limit, count);

    // 清理内存
    free(pids);
    free(proc_list);

    return 0;
}
