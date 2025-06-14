#!/bin/bash

# ==================================================
# 系统日志与备份清理工具（增强版）
# 主要功能：
#   - 安全清理系统、服务、面板及备份日志，释放磁盘空间
#   - 结果表格化输出，状态彩色可视
#   - 支持中文宽度对齐与内容截断
#   - 需 root 权限，操作安全校验
# 适用环境：Linux 服务器日常维护
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
# 计算字符串显示宽度（支持中文）
# $1: 输入字符串
# 输出：显示宽度（数字）
# ------------------------------
display_width() {
    local str="$1"
    # 计算中文字符数量（UTF-8中文字符范围）
    local chinese_chars=$(echo -n "$str" | grep -o -P "[\x{4E00}-\x{9FA5}]" | wc -l)
    # 总宽度 = 字符数 + 中文字符数（因为每个中文字符多占1个宽度）
    echo $((${#str} + chinese_chars))
}

# ------------------------------
# 填充字符串到指定宽度
# $1: 原始字符串
# $2: 目标宽度
# $3: 填充字符（默认空格）
# 输出：填充后的字符串
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
# 输出表格行
# $1: 日志描述
# $2: 文件路径
# $3: 状态码（success/warning/error）
# 自动截断、彩色标识、宽度对齐
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
# 输出表格头部（含列标题）
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
# 输出表格底部边框
# ------------------------------
print_table_footer() {
    echo "+----------------------------------+--------------+--------------------------------------------------------------+"
}

# ------------------------------
# 清空文件内容并记录结果
# $1: 文件路径
# $2: 日志描述
# 自动校验文件存在性与操作状态
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
# 删除匹配文件并记录结果
# $1: 文件匹配模式（支持通配符）
# $2: 日志描述
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
# 权限检查（必须 root 用户）
# ------------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本需 root 权限执行！${NC}"
    echo "请使用: sudo $0"
    exit 1
fi

# ==============================================
# 主清理流程入口
# ==============================================

# 模块1：系统日志清理
echo -e "\n${BLUE}1. 宝塔日志审计清理结果${NC}"
print_table_header

clear_and_log "/var/log/alternatives.log" "更新替代信息"
clear_and_log "/var/log/auth.log" "授权日志"
clear_and_log "/var/log/btmp" "失败的登录记录"
clear_and_log "/var/log/daemon.log" "系统后台守护进程日志"
clear_and_log "/var/log/debug" "调试信息"
clear_and_log "/var/log/dpkg.log" "dpkg日志"
clear_and_log "/var/log/kern.log" "内核日志"
clear_and_log "/var/log/lastlog" "用户最后登录"
clear_and_log "/var/log/messages" "综合日志"
clear_and_log "/var/log/syslog" "系统警告/错误日志"
clear_and_log "/var/log/ufw.log" "ufw日志"
clear_and_log "/var/log/wtmp" "登录和重启记录"
clear_and_log "/var/log/apt/history.log" "history日志"
clear_and_log "/var/log/apt/term.log" "term日志"

print_table_footer

# 模块2：系统日志归档清理
echo -e "\n${BLUE}2. 宝塔日志审计归档清理结果${NC}"
print_table_header

# 清理压缩归档日志（增强版）
delete_files "/var/log/alternatives.log.*" "更新替代信息归档"
delete_files "/var/log/auth.log.*" "授权日志归档"
delete_files "/var/log/btmp.*" "失败的登录记录归档"
delete_files "/var/log/daemon.log.*" "系统后台守护进程日志"
delete_files "/var/log/debug.log.*" "调试信息归档"
delete_files "/var/log/dpkg.log.*" "dpkg日志归档"
delete_files "/var/log/kern.log.*" "内核日志归档"
delete_files "/var/log/lastlog.*" "用户最后登录归档"
delete_files "/var/log/messages.*" "综合日志归档"
delete_files "/var/log/syslog.*" "系统警告/错误日志归档"
delete_files "/var/log/ufw.log.*" "ufw日志归档"
delete_files "/var/log/wtmp.*" "登录和重启记录归档"
delete_files "/var/log/apt/history.log.*" "history日志归档"
delete_files "/var/log/apt/term.log.*" "term日志归档"

print_table_footer

# 模块3：宝塔面板日志清理
echo -e "\n${BLUE}3. 宝塔面板日志清理结果${NC}"
print_table_header

clear_and_log "/www/server/panel/logs/task.log" "宝塔任务日志"
clear_and_log "/www/server/panel/logs/error.log" "宝塔错误日志"
clear_and_log "/www/server/panel/logs/upgrade_polkit.log" "Polkit升级日志"
clear_and_log "/www/server/panel/logs/letsencrypt.log" "SSL证书日志"
clear_and_log "/www/server/panel/logs/terminal.log" "终端操作日志"

clear_and_log "/www/server/panel/data/msg_box.db" "消息盒子数据库"
clear_and_log "/www/server/panel/data/db/log.db" "面板操作日志"
clear_and_log "/www/backup/panel/db/log.db" "面板操作日志备份"
clear_and_log "/www/server/panel/data/db/backup.db" "宝塔备份日志"
clear_and_log "/www/backup/panel/db/backup.db" "宝塔备份日志备份"
clear_and_log "/www/server/panel/data/db/task.db" "软件安装任务日志"
clear_and_log "/www/backup/panel/db/task.db" "软件安装任务日志备份"

# 特殊处理目录（清空目录内所有文件）
if [ -d "/www/server/panel/logs/installed" ]; then
    rm -f /www/server/panel/logs/installed/*
    table_output "软件安装日志" "/www/server/panel/logs/installed/*" "success"
else
    table_output "软件安装日志" "/www/server/panel/logs/installed" "warning"
fi

clear_and_log "/www/server/panel/data/db/client_info.db" "客户端信息数据库"
clear_and_log "/www/backup/panel/db/client_info.db" "客户端信息数据库备份"

print_table_footer

# 模块4：常用软件日志清理
echo -e "\n${BLUE}5. 软件日志清理结果${NC}"
print_table_header

# 支持多个PHP版本
php_versions=("80" "81" "82" "83")
for version in "${php_versions[@]}"; do
    log_path="/www/server/php/${version}/var/log/php-fpm.log"
    clear_and_log "$log_path" "PHP ${version} FPM日志"
done

mysql_log_dir="/www/server/data"

# 清理Mysql错误日志
for err_file in "$mysql_log_dir"/*.err; do
    [ -f "$err_file" ] && clear_and_log "$err_file" "MySQL错误日志"
done

# 清理Mysql二进制日志（不可恢复操作）
if rm -f "$mysql_log_dir"/mysql-bin.[0-9]* 2>/dev/null; then
    table_output "MySQL二进制日志" "$mysql_log_dir/mysql-bin.[0-9]*" "success"
else
    table_output "MySQL二进制日志" "$mysql_log_dir/mysql-bin.[0-9]*" "warning"
fi

# 清理Mysql二进制日志索引文件
clear_and_log "$mysql_log_dir/mysql-bin.index" "MySQL二进制日志索引"

# 清理Redis日志
clear_and_log "/www/server/redis/redis.log" "Redis日志"

print_table_footer

# 模块5：宝塔面板文件服务器及数据库备份清理
echo -e "\n${BLUE}4. 宝塔面板文件服务器备份清理结果${NC}"
print_table_header

# 清理每日备份文件
delete_files "/www/backup/panel/*.zip" "每日备份-日期命名"

delete_files "/www/backup/site/*" "网站备份"

# 清理 /www/backup/database/ 目录 (排除 mysql 文件夹)
db_backup_base_path="/www/backup/database"
db_desc="数据库备份上传记录"
db_path_display_op="$db_backup_base_path/* (excl. mysql)"
db_path_display_dir_missing="$db_backup_base_path (dir not found)"
db_path_display_no_items="$db_backup_base_path/* (no items to delete or only mysql)"

if [ ! -d "$db_backup_base_path" ]; then
    table_output "$db_desc" "$db_path_display_dir_missing" "warning"
else
    if find "$db_backup_base_path" -mindepth 1 -maxdepth 1 ! -name "mysql" -print -quit 2>/dev/null | grep -q "."; then
        find "$db_backup_base_path" -mindepth 1 -maxdepth 1 ! -name "mysql" -exec rm -rf {} + 2>/dev/null
        if [ $? -eq 0 ]; then
            table_output "$db_desc" "$db_path_display_op" "success"
        else
            table_output "$db_desc" "$db_path_display_op" "error"
        fi
    else
        table_output "$db_desc" "$db_path_display_no_items" "warning"
    fi
fi

# 清理 /www/backup/database/mysql/ 目录 (排除 all_backup 文件夹)
mysql_backup_base_path="/www/backup/database/mysql"
mysql_desc="MySQL数据库备份"
mysql_path_display_op="$mysql_backup_base_path/* (excl. all_backup)"
mysql_path_display_dir_missing="$mysql_backup_base_path (dir not found)"
mysql_path_display_no_items="$mysql_backup_base_path/* (no items to delete or only all_backup)"

if [ ! -d "$mysql_backup_base_path" ]; then
        table_output "$mysql_desc" "$mysql_path_display_dir_missing" "warning"
else
    if find "$mysql_backup_base_path" -mindepth 1 -maxdepth 1 ! -name "all_backup" -print -quit 2>/dev/null | grep -q "."; then
        find "$mysql_backup_base_path" -mindepth 1 -maxdepth 1 ! -name "all_backup" -exec rm -rf {} + 2>/dev/null
        if [ $? -eq 0 ]; then
            table_output "$mysql_desc" "$mysql_path_display_op" "success"
        else
            table_output "$mysql_desc" "$mysql_path_display_op" "error"
        fi
    else
        table_output "$mysql_desc" "$mysql_path_display_no_items" "warning"
    fi
fi

delete_files "/www/backup/file_history/www/wwwroot/*" "文件历史备份"

print_table_footer

# 模块6：系统 journal 日志清理（保留最近 40MB）
echo -e "\n${BLUE}7. 清理系统journal日志${NC}"
echo "--------------------------------------------------------------------------------------------------------------"
journalctl_output=$(journalctl --vacuum-size=40M 2>&1)
echo "$journalctl_output"
echo "--------------------------------------------------------------------------------------------------------------"

# 检查 journal 清理结果并显示状态
if [[ "$journalctl_output" == *"Vacuuming done"* ]]; then
    echo -e "${GREEN}✓ journal日志清理成功${NC}"
else
    echo -e "${YELLOW}! journal日志清理可能未完全执行${NC}"
    echo "详细信息:"
    echo "$journalctl_output"
fi

# ==============================================
# 清理完成报告
# ==============================================
echo -e "\n${GREEN}✔ 所有日志清理完成！${NC}"
echo "=============================================================================================================="

# 显示磁盘空间信息
echo -e "\n${BLUE}当前磁盘使用情况：${NC}"
df -h / | awk 'NR==2 {print "可用空间: " $4 "/" $2 " (已用 " $5 ")"}'

# 安全注意事项
echo -e "\n${YELLOW}【重要安全提示】${NC}"
echo "1. MySQL 二进制日志删除后不可恢复！"
echo "2. 宝塔面板备份文件已永久删除"
echo "3. 部分日志需重启服务后重新生成"
echo "4. 建议定期执行本脚本维护服务器"
