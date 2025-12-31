//gcc main.c -o swift_editor
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_INPUT_SIZE 1024

int main(int argc, char *argv[]) {
    // 1. 检查命令行参数
    if (argc < 2) {
        printf("用法: %s <swift文件路径>\n", argv[0]);
        return 1;
    }

    char *filename = argv[1];
    char input[MAX_INPUT_SIZE];

    printf("已进入交互模式 (文件: %s)\n", filename);
    printf("输入任何内容将追加到文件，输入 'run' 执行 Swift 代码，输入 'exit' 退出。\n");

    while (1) {
        printf("> ");
        if (fgets(input, sizeof(input), stdin) == NULL) {
            break;
        }

        // 移除换行符用于比较
        // 注意：我们只在比较 "run" 和 "exit" 时去除换行符
        if (strcmp(input, "run\n") == 0) {
            printf("--- 运行结果 ---\n");
            
            // 构建命令: swift <文件名>
            char command[1024];
            snprintf(command, sizeof(command), "swift %s", filename);
            
            // 执行系统命令
            int ret = system(command);
            if (ret == -1) {
                perror("执行失败");
            }
            
            printf("--------------\n");
        } 
        else if (strcmp(input, "exit\n") == 0) {
            printf("程序退出。\n");
            break;
        }
        else {
            // 追加内容到文件
            FILE *file = fopen(filename, "a"); // "a" 表示追加模式
            if (file == NULL) {
                perror("无法打开文件");
                continue;
            }
            fputs(input, file);
            fclose(file);
        }
    }

    return 0;
}
