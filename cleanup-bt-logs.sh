#!/bin/bash

# ==================================================
# 系统日志清理工具（增强版）
# 功能：安全清理各类系统/服务日志和备份文件，释放磁盘空间
# 特点：
#   1. 表格化输出清理结果，状态可视化
#   2. 支持中文显示宽度计算（自动截断超长内容）
#   3. 彩色状态标识（成功/警告/错误）
# 安全机制：
#   - 需 root 权限执行
#   - 文件存在性校验
#   - 操作错误捕获
# 适用场景：Linux服务器日常维护
# ==================================================

echo "开始执行系统日志清理..."
echo "=============================================================================================================="

# ------------------------------
# 颜色定义（终端输出着色）
# ------------------------------
RED=$'\033[0;31m'    # 错误状态
GREEN=$'\033[0;32m'  # 成功状态
YELLOW=$'\033[1;33m' # 警告状态
BLUE=$'\033[0;34m'   # 信息标题
NC=$'\033[0m'        # 颜色重置

# ------------------------------
# 函数：display_width
# 功能：计算字符串的显示宽度（考虑中文字符）
# 参数：$1 - 待计算的字符串
# 返回值：输出字符串的显示宽度（数字）
# ------------------------------
display_width() {
    local str="$1"
    # 计算中文字符数量（UTF-8中文字符范围）
    local chinese_chars=$(echo -n "$str" | grep -o -P "[\x{4E00}-\x{9FA5}]" | wc -l)
    # 总宽度 = 字符数 + 中文字符数（因为每个中文字符多占1个宽度）
    echo $((${#str} + chinese_chars))
}

# ------------------------------
# 函数：pad_string
# 功能：填充字符串到指定显示宽度
# 参数：
#   $1 - 原始字符串
#   $2 - 目标宽度
#   $3 - 填充字符（默认空格）
# 返回值：输出填充后的字符串
# ------------------------------
pad_string() {
    local str="$1"
    local width="$2"
    local pad_char="${3:- }"
    
    local current_width=$(display_width "$str")
    local padding=$((width - current_width))
    
    if [ $padding -gt 0 ]; then
        printf "%s%s" "$str" "$(printf "%${padding}s" "" | tr ' ' "$pad_char")"
    else
        printf "%s" "$str"
    fi
}

# ------------------------------
# 函数：table_output
# 功能：生成表格行输出
# 参数：
#   $1 - 日志描述
#   $2 - 文件路径
#   $3 - 状态码（success/warning/error）
# 处理逻辑：
#   1. 自动截断超长文本并添加".."后缀
#   2. 根据状态码添加彩色标识
#   3. 动态计算列宽对齐
# ------------------------------
table_output() {
    local description="$1"
    local path="$2"
    local status="$3"

    # 定义目标列宽（与表头匹配）
    local target_desc_width=32
    local target_status_text_width=12
    local target_path_width=60

    # 截断过长的描述文本
    local short_desc="$description"
    if [ $(display_width "$short_desc") -gt $target_desc_width ]; then
        while [ $(display_width "$short_desc") -gt $((target_desc_width - 2)) ] && [ ${#short_desc} -gt 1 ]; do
            short_desc="${short_desc:0:$((${#short_desc}-1))}"
        done
        short_desc="${short_desc}.."
    fi

    # 截断过长的路径文本
    local short_path="$path"
    if [ $(display_width "$short_path") -gt $target_path_width ]; then
        while [ $(display_width "$short_path") -gt $((target_path_width - 2)) ] && [ ${#short_path} -gt 1 ]; do
            short_path="${short_path:0:$((${#short_path}-1))}"
        done
        short_path="${short_path}.."
    fi
    
    # 填充文本到目标宽度
    local desc_display_padded=$(pad_string "$short_desc" $target_desc_width)
    local path_display_padded=$(pad_string "$short_path" $target_path_width)
    
    # 构建彩色状态标识
    local status_colored_str
    case "$status" in
        success) status_colored_str="${GREEN}✓ 成功${NC}" ;;
        warning) status_colored_str="${YELLOW}! 不存在${NC}" ;;
        error) status_colored_str="${RED}✗ 失败${NC}" ;;
        *) status_colored_str="$status" ;;
    esac
    
    # 计算状态文本的可见宽度（去除颜色代码）
    local status_visible_text_only=$(echo -e "$status_colored_str" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g")
    local status_visible_width=$(display_width "$status_visible_text_only")
    
    # 计算状态列需要的填充空格
    local status_padding_size=$((target_status_text_width - status_visible_width))
    local status_padding_spaces=""
    if [ $status_padding_size -gt 0 ]; then
        status_padding_spaces=$(printf "%${status_padding_size}s" "")
    fi
    
    # 输出表格行
    printf "| %s | %s%s | %s |\n" "$desc_display_padded" "$status_colored_str" "$status_padding_spaces" "$path_display_padded"
}

# ------------------------------
# 函数：print_table_header
# 功能：输出表格头部（带列标题）
# ------------------------------
print_table_header() {
    local target_desc_width=32
    local target_status_text_width=12
    local target_path_width=60

    # 填充列标题到目标宽度
    local header_desc_padded=$(pad_string "日志描述" $target_desc_width)
    local header_status_padded=$(pad_string "状态" $target_status_text_width)
    local header_path_padded=$(pad_string "路径" $target_path_width)

    echo "+----------------------------------+--------------+--------------------------------------------------------------+"
    printf "| %s | %s | %s |\n" "$header_desc_padded" "$header_status_padded" "$header_path_padded"
    echo "+----------------------------------+--------------+--------------------------------------------------------------+"
}

# ------------------------------
# 函数：print_table_footer
# 功能：输出表格底部边框
# ------------------------------
print_table_footer() {
    echo "+----------------------------------+--------------+--------------------------------------------------------------+"
}

# ------------------------------
# 函数：clear_and_log
# 功能：安全清空文件并记录结果
# 参数：
#   $1 - 文件路径
#   $2 - 日志描述
# 安全机制：
#   - 文件存在性检查
#   - 操作错误捕获
#   - 状态反馈（成功/文件不存在/操作失败）
# ------------------------------
clear_and_log() {
    local file="$1"
    local desc="$2"
    
    if [ -f "$file" ]; then
        # 清空文件内容（不删除文件）
        > "$file" 2>/dev/null
        if [ $? -eq 0 ]; then
            table_output "$desc" "$file" "success"
        else
            table_output "$desc" "$file" "error"
        fi
    else
        table_output "$desc" "$file" "warning"
    fi
}

# ------------------------------
# 函数：delete_files
# 功能：删除匹配的文件并记录结果
# 参数：
#   $1 - 文件匹配模式（支持通配符）
#   $2 - 日志描述
# ------------------------------
delete_files() {
    local pattern="$1"
    local desc="$2"
    
    # 查找匹配的文件
    local files_found=$(ls $pattern 2>/dev/null | wc -l)
    
    if [ $files_found -gt 0 ]; then
        # 删除文件
        rm -f $pattern 2>/dev/null
        if [ $? -eq 0 ]; then
            table_output "$desc" "$pattern" "success"
        else
            table_output "$desc" "$pattern" "error"
        fi
    else
        table_output "$desc" "$pattern" "warning"
    fi
}

# ------------------------------
# 权限检查（必须root用户）
# ------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本需 root 权限执行！${NC}"
    echo "请使用: sudo $0"
    exit 1
fi

# ==============================================
# 主清理流程
# ==============================================

# 模块1：系统日志清理
echo -e "\n${BLUE}1. 系统日志清理结果${NC}"
print_table_header

clear_and_log "/var/log/alternatives.log" "系统管理员日志"
clear_and_log "/var/log/auth.log" "用户认证日志"
clear_and_log "/var/log/btmp" "失败登录记录"
clear_and_log "/var/log/daemon.log" "守护进程日志"
clear_and_log "/var/log/debug" "调试日志"
clear_and_log "/var/log/dpkg.log" "dpkg管理日志"
clear_and_log "/var/log/apt/history.log" "APT安装历史"
clear_and_log "/var/log/kern.log" "内核日志"
clear_and_log "/var/log/lastlog" "用户是否登录时间"
clear_and_log "/var/log/messages" "系统客户端日志"
clear_and_log "/var/log/syslog" "系统主日志"
clear_and_log "/var/log/apt/term.log" "APT终端日志"
clear_and_log "/var/log/ufw.log" "防火墙日志"
clear_and_log "/var/log/wtmp" "登录重启记录"

print_table_footer

# 模块2：日志归档清理
echo -e "\n${BLUE}2. 日志归档清理结果${NC}"
print_table_header

# 清理压缩归档日志（增强版）
delete_files "/var/log/syslog.*" "系统归档日志"
delete_files "/var/log/auth.log.*" "认证归档日志"
delete_files "/var/log/kern.log.*" "内核归档日志"
delete_files "/var/log/messages.*" "客户端归档日志"
delete_files "/var/log/alternatives.log.*" "管理员归档日志"
delete_files "/var/log/btmp.*" "失败登录归档"
delete_files "/var/log/dpkg.log.*" "dpkg归档日志"

print_table_footer

# 模块3：宝塔面板日志清理
echo -e "\n${BLUE}3. 宝塔面板日志清理结果${NC}"
print_table_header

clear_and_log "/www/server/panel/data/db/task.db" "宝塔任务数据库"
clear_and_log "/www/backup/panel/db/task.db" "宝塔任务数据库"
clear_and_log "/www/server/redis/redis.log" "Redis日志"
clear_and_log "/www/server/panel/logs/task.log" "宝塔任务日志"
clear_and_log "/www/server/panel/logs/upgrade_polkit.log" "Polkit升级日志"
clear_and_log "/www/server/panel/data/db/log.db" "宝塔日志数据库"
clear_and_log "/www/backup/panel/db/log.db" "宝塔日志数据库"
clear_and_log "/www/server/panel/logs/error.log" "宝塔错误日志"
clear_and_log "/www/server/panel/logs/letsencrypt.log" "SSL证书日志"
clear_and_log "/www/server/panel/logs/terminal.log" "终端操作日志"

# 特殊处理目录（清空目录内所有文件）
if [ -d "/www/server/panel/logs/installed" ]; then
    rm -f /www/server/panel/logs/installed/*
    table_output "软件安装日志" "/www/server/panel/logs/installed/*" "success"
else
    table_output "软件安装日志" "/www/server/panel/logs/installed" "warning"
fi

print_table_footer

# 模块4：宝塔面板备份清理
echo -e "\n${BLUE}4. 宝塔面板备份清理结果${NC}"
print_table_header

# 清理每日备份文件
delete_files "/www/backup/panel/*.zip" "宝塔每日备份"

print_table_footer

# 模块5：PHP-FPM日志清理（多版本支持）
echo -e "\n${BLUE}5. PHP-FPM日志清理结果${NC}"
print_table_header

# 支持多个PHP版本
php_versions=("80" "81" "82" "83")
for version in "${php_versions[@]}"; do
    log_path="/www/server/php/${version}/var/log/php-fpm.log"
    clear_and_log "$log_path" "PHP ${version} FPM日志"
done

print_table_footer

# 模块6：MySQL日志清理
echo -e "\n${BLUE}6. MySQL日志清理结果${NC}"
print_table_header

mysql_log_dir="/www/server/data"

# 清理错误日志
for err_file in "$mysql_log_dir"/*.err; do
    [ -f "$err_file" ] && clear_and_log "$err_file" "MySQL错误日志"
done

# 清理二进制日志（不可恢复操作）
if rm -f "$mysql_log_dir"/mysql-bin.[0-9]* 2>/dev/null; then
    table_output "MySQL二进制日志" "$mysql_log_dir/mysql-bin.[0-9]*" "success"
else
    table_output "MySQL二进制日志" "$mysql_log_dir/mysql-bin.[0-9]*" "warning"
fi

# 清理索引文件
clear_and_log "$mysql_log_dir/mysql-bin.index" "MySQL二进制日志索引"

print_table_footer

# ==============================================
# 清理完成报告
# ==============================================
echo -e "\n${GREEN}✔ 所有日志清理完成！${NC}"
echo "=============================================================================================================="

# 磁盘空间信息
echo -e "\n${BLUE}当前磁盘使用情况：${NC}"
df -h / | awk 'NR==2 {print "可用空间: " $4 "/" $2 " (已用 " $5 ")"}'

# 安全注意事项
echo -e "\n${YELLOW}【重要安全提示】${NC}"
echo "1. MySQL 二进制日志删除后不可恢复！"
echo "2. 宝塔面板备份文件已永久删除"
echo "3. 部分日志需重启服务后重新生成"
echo "4. 建议定期执行本脚本维护服务器"
