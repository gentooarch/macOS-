#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>     // for usleep
#include <libproc.h>    // macOS 进程 API
#include <sys/time.h>   // for gettimeofday

// 定义结构体存储进程信息
typedef struct {
    pid_t pid;
    char name[256];
    uint64_t time_start;  // 第一次采样的 CPU 总时间 (user + system)
    uint64_t time_end;    // 第二次采样的 CPU 总时间
    double cpu_percent;   // 计算出的百分比
    int valid;            // 标记进程在第二次采样时是否还活着
} ProcessInfo;

// 获取单个进程的当前累计 CPU 时间 (User + System)，单位：纳秒
uint64_t get_cpu_time(pid_t pid, struct proc_taskinfo *pti_buffer) {
    int ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pti_buffer, sizeof(*pti_buffer));
    if (ret <= 0) {
        return 0; // 获取失败（可能进程退出了）
    }
    // pti_total_user 和 pti_total_system 单位通常是纳秒
    return pti_buffer->pti_total_user + pti_buffer->pti_total_system;
}

// 排序函数：按 CPU 百分比从大到小
int compare_cpu(const void *a, const void *b) {
    const ProcessInfo *p1 = (const ProcessInfo *)a;
    const ProcessInfo *p2 = (const ProcessInfo *)b;
    
    if (p2->cpu_percent > p1->cpu_percent) return 1;
    if (p2->cpu_percent < p1->cpu_percent) return -1;
    return 0;
}

int main() {
    // 1. 获取 PID 列表
    int buffer_size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (buffer_size <= 0) return 1;

    pid_t *pids = malloc(buffer_size);
    int actual_size = proc_listpids(PROC_ALL_PIDS, 0, pids, buffer_size);
    int num_pids = actual_size / sizeof(pid_t);

    // 2. 初始化进程列表
    ProcessInfo *proc_list = malloc(num_pids * sizeof(ProcessInfo));
    struct proc_taskinfo pti;
    int count = 0;

    printf("Sampling CPU usage (please wait 1 second)...\n");

    // ---------------------------------------------------------
    // 第一步：第一次采样 (Snapshot 1)
    // ---------------------------------------------------------
    for (int i = 0; i < num_pids; i++) {
        if (pids[i] == 0) continue;

        uint64_t t = get_cpu_time(pids[i], &pti);
        if (t > 0) {
            proc_list[count].pid = pids[i];
            proc_list[count].time_start = t;
            proc_list[count].valid = 1;

            // 获取名字
            proc_name(pids[i], proc_list[count].name, sizeof(proc_list[count].name));
            count++;
        }
    }

    // ---------------------------------------------------------
    // 第二步：等待 1 秒
    // ---------------------------------------------------------
    // 为了精确计算，我们记录实际 sleep 的微秒数，虽然 usleep 也可以，但计算时用 wall clock 更准
    struct timeval tv1, tv2;
    gettimeofday(&tv1, NULL);
    
    usleep(1000000); // 睡眠 1,000,000 微秒 = 1 秒

    gettimeofday(&tv2, NULL);
    
    // 计算实际经过的时间（单位：纳秒，为了和 CPU 时间单位匹配）
    // 秒 * 1e9 + 微秒 * 1e3
    double time_interval_ns = (tv2.tv_sec - tv1.tv_sec) * 1000000000.0 + 
                              (tv2.tv_usec - tv1.tv_usec) * 1000.0;

    // ---------------------------------------------------------
    // 第三步：第二次采样 (Snapshot 2) 并计算
    // ---------------------------------------------------------
    for (int i = 0; i < count; i++) {
        uint64_t t_new = get_cpu_time(proc_list[i].pid, &pti);
        
        if (t_new > 0 && t_new >= proc_list[i].time_start) {
            proc_list[i].time_end = t_new;
            
            // 核心公式：(CPU时间差 / 实际物理时间差) * 100%
            uint64_t delta = t_new - proc_list[i].time_start;
            proc_list[i].cpu_percent = (double)delta / time_interval_ns * 100.0;
        } else {
            // 进程可能在睡眠期间退出了
            proc_list[i].valid = 0;
            proc_list[i].cpu_percent = 0.0;
        }
    }

    // ---------------------------------------------------------
    // 第四步：排序和打印
    // ---------------------------------------------------------
    qsort(proc_list, count, sizeof(ProcessInfo), compare_cpu);

    printf("\n%-8s  %-30s  %s\n", "PID", "NAME", "CPU %");
    printf("--------------------------------------------------\n");

    int limit = 20;
    int printed = 0;
    for (int i = 0; i < count && printed < limit; i++) {
        if (!proc_list[i].valid) continue;

        // 如果 CPU 使用率极低（例如 < 0.1%），可以根据需要过滤
        // if (proc_list[i].cpu_percent < 0.1) break;

        printf("%-8d  %-30.30s  %.2f%%\n", 
               proc_list[i].pid, 
               proc_list[i].name, 
               proc_list[i].cpu_percent);
        printed++;
    }
    printf("--------------------------------------------------\n");
    printf("Note: >100%% means the process is using multiple cores.\n");

    free(pids);
    free(proc_list);
    return 0;
}
