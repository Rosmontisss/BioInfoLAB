#!/bin/bash

# 系统性能监控脚本
# 用途：每30秒记录系统性能指标，按 Ctrl+C 停止，瞬时值与最大值同行列示
# 格式：指标名称 [瞬时值/最大值]

# 配置参数
OUTPUT_FILE="system_stats.csv"
MAX_FILE="system_stats_max.csv"  # 最大值记录文件
INTERVAL=30     # 采样间隔（秒）
DISPLAY_WIDTH=180 # 显示宽度（加宽以容纳同行列示）

# 颜色定义
COLOR_RESET="\033[0m"
COLOR_WHITE="\033[37m"
COLOR_RED="\033[31m"

# 警告阈值
THRESHOLD=80    # 超过此阈值显示为红色

# 清除旧文件（可选）
read -p "是否清除旧的统计文件? (y/n): " answer
if [ "$answer" == "y" ]; then
    rm -f "$OUTPUT_FILE" "$MAX_FILE"
fi

# 创建表头（使用制表符分隔）
echo -e "时间戳(秒)\tCPU负载(1m)\tCPU负载(5m)\tCPU负载(15m)\t运行队列长度\t总进程数\t运行中进程数\t睡眠中进程数\t总线程数\t总内存(MB)\t已用内存(MB)\t空闲内存(MB)\t内存使用率(%)\t总SWAP(MB)\t已用SWAP(MB)\t空闲SWAP(MB)\tSWAP使用率(%)" > "$OUTPUT_FILE"

# 初始化最大值（如果不存在）
if [ ! -f "$MAX_FILE" ]; then
    echo -e "CPU负载(1m)\tCPU负载(5m)\tCPU负载(15m)\t运行队列长度\t总进程数\t运行中进程数\t睡眠中进程数\t总线程数\t内存使用率(%)\tSWAP使用率(%)" > "$MAX_FILE"
    echo -e "0\t0\t0\t0\t0\t0\t0\t0\t0\t0" >> "$MAX_FILE"
fi

# 读取当前最大值
read -r max_values < <(tail -n 1 "$MAX_FILE")
IFS=$'\t' read -ra max_array <<< "$max_values"

# 显示合并表头
echo
echo -e "${COLOR_WHITE}="*$DISPLAY_WIDTH"${COLOR_RESET}"
echo -e "${COLOR_WHITE}系统性能监控 - 每${INTERVAL}秒记录一次，按 Ctrl+C 停止 | 格式：[瞬时值/最大值] | 超过${THRESHOLD}%的值显示为红色${COLOR_RESET}"
echo -e "${COLOR_WHITE}数据将保存到 $OUTPUT_FILE${COLOR_RESET}"
echo -e "${COLOR_WHITE}%-15s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s${COLOR_RESET}" \
       "时间" "CPU(1m)" "CPU(5m)" "CPU(15m)" "运行队列" "总进程数" "运行中进程" "睡眠中进程" "总线程数" "内存使用率(%)" "SWAP使用率(%)"
echo -e "${COLOR_WHITE}="*$DISPLAY_WIDTH"${COLOR_RESET}"

# 捕获 Ctrl+C 信号，优雅退出
trap 'echo; echo -e "${COLOR_WHITE}="*$DISPLAY_WIDTH"${COLOR_RESET}"; echo -e "${COLOR_WHITE}监控已停止，数据已保存到 $OUTPUT_FILE${COLOR_RESET}"; exit 0' INT

# 开始循环收集数据
while true; do
    # 获取当前时间戳（秒）
    timestamp=$(date +%s)
    human_time=$(date "+%H:%M:%S")
    
    # 获取CPU负载信息
    load_info=$(cat /proc/loadavg)
    load_1m=$(echo "$load_info" | awk '{print $1}')
    load_5m=$(echo "$load_info" | awk '{print $2}')
    load_15m=$(echo "$load_info" | awk '{print $3}')
    run_queue=$(echo "$load_info" | awk '{print $4}' | cut -d/ -f1)
    
    # 获取进程和线程数
    total_processes=$(ps -eLf | wc -l)
    running_processes=$(ps -eo stat | grep -c "^R")
    sleeping_processes=$(ps -eo stat | grep -c "^S")
    total_threads=$(ps -eLf | wc -l)
    
    # 获取内存和SWAP信息（单位：MB）
    mem_info=$(free -m | awk '
        NR==2 {mem_total=$2; mem_used=$3; mem_free=$4}
        NR==3 {swap_total=$2; swap_used=$3; swap_free=$4}
        END {
            mem_percent = (mem_used / mem_total) * 100;
            swap_percent = (swap_used / swap_total) * 100;
            printf "%d\t%d\t%d\t%.2f\t%d\t%d\t%d\t%.2f", 
                   mem_total, mem_used, mem_free, mem_percent,
                   swap_total, swap_used, swap_free, swap_percent
        }
    ')
    
    # 提取内存和SWAP使用率
    mem_percent=$(echo "$mem_info" | awk -F'\t' '{print $4}')
    swap_percent=$(echo "$mem_info" | awk -F'\t' '{print $8}')
    
    # 组合所有数据并写入CSV（使用制表符分隔）
    echo -e "$timestamp\t$load_1m\t$load_5m\t$load_15m\t$run_queue\t$total_processes\t$running_processes\t$sleeping_processes\t$total_threads\t$mem_info" >> "$OUTPUT_FILE"
    
    # 更新最大值数组
    if (( $(echo "$load_1m > ${max_array[0]}" | bc -l) )); then max_array[0]=$load_1m; fi
    if (( $(echo "$load_5m > ${max_array[1]}" | bc -l) )); then max_array[1]=$load_5m; fi
    if (( $(echo "$load_15m > ${max_array[2]}" | bc -l) )); then max_array[2]=$load_15m; fi
    if (( $run_queue > ${max_array[3]} )); then max_array[3]=$run_queue; fi
    if (( $total_processes > ${max_array[4]} )); then max_array[4]=$total_processes; fi
    if (( $running_processes > ${max_array[5]} )); then max_array[5]=$running_processes; fi
    if (( $sleeping_processes > ${max_array[6]} )); then max_array[6]=$sleeping_processes; fi
    if (( $total_threads > ${max_array[7]} )); then max_array[7]=$total_threads; fi
    if (( $(echo "$mem_percent > ${max_array[8]}" | bc -l) )); then max_array[8]=$mem_percent; fi
    if (( $(echo "$swap_percent > ${max_array[9]}" | bc -l) )); then max_array[9]=$swap_percent; fi
    
    # 更新最大值文件
    printf "%s\n" "$(IFS=$'\t'; echo "${max_array[*]}")" > "$MAX_FILE"
    
    # 应用颜色格式（仅超过阈值的指标显示为红色）
    colorize() {
        local value=$1
        local threshold=$2
        if (( $(echo "$value > $threshold" | bc -l) )); then
            echo -e "${COLOR_RED}${value}${COLOR_RESET}"
        else
            echo -e "${COLOR_WHITE}${value}${COLOR_RESET}"
        fi
    }
    
    # 为每个指标的瞬时值和最大值生成带颜色的字符串
    # CPU负载
    load_1m_color=$(colorize "$load_1m" "$THRESHOLD")
    max_load_1m_color=$(colorize "${max_array[0]}" "$THRESHOLD")
    load1_str="${load_1m_color}/${max_load_1m_color}"
    
    load_5m_color=$(colorize "$load_5m" "$THRESHOLD")
    max_load_5m_color=$(colorize "${max_array[1]}" "$THRESHOLD")
    load5_str="${load_5m_color}/${max_load_5m_color}"
    
    load_15m_color=$(colorize "$load_15m" "$THRESHOLD")
    max_load_15m_color=$(colorize "${max_array[2]}" "$THRESHOLD")
    load15_str="${load_15m_color}/${max_load_15m_color}"
    
    # 运行队列（超过CPU核心数标红）
    cpu_cores=$(nproc)
    if (( $run_queue > $cpu_cores )); then
        run_queue_color="${COLOR_RED}${run_queue}${COLOR_RESET}"
    else
        run_queue_color="${COLOR_WHITE}${run_queue}${COLOR_RESET}"
    fi
    if (( ${max_array[3]} > $cpu_cores )); then
        max_run_queue_color="${COLOR_RED}${max_array[3]}${COLOR_RESET}"
    else
        max_run_queue_color="${COLOR_WHITE}${max_array[3]}${COLOR_RESET}"
    fi
    runq_str="${run_queue_color}/${max_run_queue_color}"
    
    # 进程数
    total_proc_str="${COLOR_WHITE}${total_processes}/${max_array[4]}${COLOR_RESET}"
    running_proc_str="${COLOR_WHITE}${running_processes}/${max_array[5]}${COLOR_RESET}"
    sleeping_proc_str="${COLOR_WHITE}${sleeping_processes}/${max_array[6]}${COLOR_RESET}"
    total_thread_str="${COLOR_WHITE}${total_threads}/${max_array[7]}${COLOR_RESET}"
    
    # 内存和SWAP使用率
    mem_str="${mem_color}/${max_mem_color}"
    mem_color=$(colorize "$mem_percent" "$THRESHOLD")
    max_mem_color=$(colorize "${max_array[8]}" "$THRESHOLD")
    
    swap_str="${swap_color}/${max_swap_color}"
    swap_color=$(colorize "$swap_percent" "$THRESHOLD")
    max_swap_color=$(colorize "${max_array[9]}" "$THRESHOLD")
    
    # 在终端显示合并后的一行数据（瞬时值/最大值）
    printf "${COLOR_WHITE}%-15s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s | %-20s${COLOR_RESET}\n" \
           "$human_time" \
           "$load1_str" \
           "$load5_str" \
           "$load15_str" \
           "$runq_str" \
           "$total_proc_str" \
           "$running_proc_str" \
           "$sleeping_proc_str" \
           "$total_thread_str" \
           "$mem_str" \
           "$swap_str"
    
    # 等待下一个采样周期
    sleep $INTERVAL
done
