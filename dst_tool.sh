#!/bin/bash
# DST Dedicated Server Tool
# Release: v6.9
# Single-file management script for Don't Starve Together dedicated server.

# ================= 配置区域 =================
# 最小手动配置（第一次使用只改这 4 项）
CFG_DST_DIR="$HOME/dst_server/"
CFG_KLEI_DIR="$HOME/.klei/DoNotStarveTogether"
CFG_SAVE_DIR_NAME="MyDediServer"
CFG_SERVICE_MODE="external" # screen / external

# 高级配置（通常无需手动改）
CFG_STEAMCMD_DIR="$HOME/steamcmd"
CFG_BACKUP_REPO="$HOME/dst_backups"
CFG_SCREEN_MASTER_NAME="DST_Master"
CFG_SCREEN_CAVES_NAME="DST_Caves"
CFG_INITIALIZED="0"                                     # 0: 首次运行未初始化, 1: 已初始化

DST_DIR="$CFG_DST_DIR"
STEAMCMD_DIR="$CFG_STEAMCMD_DIR"
KLEI_DIR="$CFG_KLEI_DIR"
SAVE_DIR_NAME="$CFG_SAVE_DIR_NAME"
BACKUP_REPO="$CFG_BACKUP_REPO"
SERVICE_MODE="$CFG_SERVICE_MODE" # screen / external
SCREEN_MASTER_NAME="$CFG_SCREEN_MASTER_NAME"
SCREEN_CAVES_NAME="$CFG_SCREEN_CAVES_NAME"
SCRIPT_VERSION="v6.9"

DST_BIN_DIR=""
DST_EXEC=""
LOG_MASTER=""
LOG_CAVES=""
MOD_SETUP_FILE=""
MOD_OVERRIDE_MASTER=""
MOD_OVERRIDE_CAVES=""
LEVEL_OVERRIDE_MASTER=""
LEVEL_OVERRIDE_CAVES=""
# ===========================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

EVENT_KEYS=(
    "crow_carnival" "hallowed_nights" "winters_feast" "year_of_the_beefalo"
    "year_of_the_bunnyman" "year_of_the_carrat" "year_of_the_catcoon"
    "year_of_the_dragonfly" "year_of_the_gobbler" "year_of_the_knight"
    "year_of_the_pig" "year_of_the_snake" "year_of_the_varg"
)

refresh_paths() {
    DST_BIN_DIR="${DST_DIR%/}/bin"
    DST_EXEC="$DST_BIN_DIR/dontstarve_dedicated_server_nullrenderer"
    LOG_MASTER="$KLEI_DIR/$SAVE_DIR_NAME/Master/server_log.txt"
    LOG_CAVES="$KLEI_DIR/$SAVE_DIR_NAME/Caves/server_log.txt"
    MOD_SETUP_FILE="$DST_DIR/mods/dedicated_server_mods_setup.lua"
    MOD_OVERRIDE_MASTER="$KLEI_DIR/$SAVE_DIR_NAME/Master/modoverrides.lua"
    MOD_OVERRIDE_CAVES="$KLEI_DIR/$SAVE_DIR_NAME/Caves/modoverrides.lua"
    LEVEL_OVERRIDE_MASTER="$KLEI_DIR/$SAVE_DIR_NAME/Master/leveldataoverride.lua"
    LEVEL_OVERRIDE_CAVES="$KLEI_DIR/$SAVE_DIR_NAME/Caves/leveldataoverride.lua"
}

refresh_paths
mkdir -p "$BACKUP_REPO"
trap 'echo -e "\n${YELLOW}>> 操作已取消，返回菜单...${NC}"; sleep 1' SIGINT

# ================= 辅助函数 =================

print_line() { echo -e "${CYAN}--------------------------------------------------${NC}"; }

have_screen() { command -v screen >/dev/null 2>&1; }

screen_session_exists() {
    local name="$1"
    have_screen && screen -ls 2>/dev/null | grep -q "$name"
}

screen_shards_running() {
    screen_session_exists "$SCREEN_MASTER_NAME" || screen_session_exists "$SCREEN_CAVES_NAME"
}

cluster_process_running() {
    pgrep -fa "dontstarve_dedicated_server_nullrenderer" 2>/dev/null \
        | grep -F -- "-cluster $SAVE_DIR_NAME" >/dev/null 2>&1
}

external_shard_running() {
    local shard="$1"
    pgrep -fa "dontstarve_dedicated_server_nullrenderer" 2>/dev/null \
        | grep -F -- "-cluster $SAVE_DIR_NAME" \
        | grep -F -- "-shard $shard" >/dev/null 2>&1
}

external_dst_running() {
    cluster_process_running && ! screen_shards_running
}

lifecycle_managed_by_screen() { [ "$SERVICE_MODE" = "screen" ]; }

warn_external_manager() {
    echo -e "${YELLOW}⚠️ 检测到 DST 进程不在本脚本 screen 会话中，请使用你当前的托管方式启停。${NC}"
}

warn_lifecycle_disabled() {
    echo -e "${YELLOW}⚠️ 当前 SERVICE_MODE=$SERVICE_MODE，已禁用脚本启停。${NC}"
}

choose_from_list() {
    local prompt="$1"
    shift
    local options=("$@")
    local i pick

    [ "${#options[@]}" -gt 0 ] || return 1
    if [ "${#options[@]}" -eq 1 ]; then
        echo "${options[0]}"
        return 0
    fi

    echo "$prompt" >&2
    for ((i = 0; i < ${#options[@]}; i++)); do
        printf "  [%d] %s\n" "$i" "${options[$i]}" >&2
    done

    while true; do
        read -r -p "选择序号: " pick
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 0 ] && [ "$pick" -lt "${#options[@]}" ]; then
            echo "${options[$pick]}"
            return 0
        fi
        echo "输入无效，请重试。" >&2
    done
}

collect_dst_dirs() {
    local -a found
    local d

    for d in \
        "$DST_DIR" \
        "$HOME/dst_server" \
        "/home/steam/dst_server" \
        "$HOME/dontstarvetogether_dedicated_server" \
        "/home/steam/dontstarvetogether_dedicated_server"
    do
        [ -x "$d/bin/dontstarve_dedicated_server_nullrenderer" ] && found+=("$d")
    done

    [ "${#found[@]}" -gt 0 ] || return 1
    printf '%s\n' "${found[@]}" | awk '!seen[$0]++'
}

collect_clusters() {
    local base="$1" d
    [ -d "$base" ] || return 1

    for d in "$base"/*; do
        [ -d "$d" ] || continue
        [ -d "$d/Master" ] || continue
        [ -d "$d/Caves" ] || continue
        basename "$d"
    done | awk '!seen[$0]++'
}

init_detect_steamcmd_dir() {
    local -a cands=(
        "$STEAMCMD_DIR"
        "$HOME/steamcmd"
        "/home/steam/steamcmd"
    )
    local d
    for d in "${cands[@]}"; do
        [ -x "$d/steamcmd.sh" ] && { echo "$d"; return 0; }
    done
    echo "$HOME/steamcmd"
}

init_detect_service_mode() {
    if screen_shards_running; then
        echo "screen"
        return 0
    fi
    if cluster_process_running; then
        echo "external"
        return 0
    fi
    echo "$SERVICE_MODE"
}

apply_runtime_config() {
    DST_DIR="$1"
    STEAMCMD_DIR="$2"
    KLEI_DIR="$3"
    SAVE_DIR_NAME="$4"
    BACKUP_REPO="$5"
    SERVICE_MODE="$6"
    refresh_paths
    mkdir -p "$BACKUP_REPO"
}

escape_sed_repl() {
    printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g' -e 's/"/\\"/g'
}

save_embedded_config() {
    local self_file="$1"
    local v_dst v_steam v_klei v_save v_backup v_mode v_master v_caves

    [ -w "$self_file" ] || { echo -e "${RED}❌ 无法写入脚本：$self_file${NC}"; return 1; }

    v_dst=$(escape_sed_repl "$DST_DIR")
    v_steam=$(escape_sed_repl "$STEAMCMD_DIR")
    v_klei=$(escape_sed_repl "$KLEI_DIR")
    v_save=$(escape_sed_repl "$SAVE_DIR_NAME")
    v_backup=$(escape_sed_repl "$BACKUP_REPO")
    v_mode=$(escape_sed_repl "$SERVICE_MODE")
    v_master=$(escape_sed_repl "$SCREEN_MASTER_NAME")
    v_caves=$(escape_sed_repl "$SCREEN_CAVES_NAME")

    sed -i "s|^CFG_DST_DIR=.*$|CFG_DST_DIR=\"$v_dst\"|" "$self_file"
    sed -i "s|^CFG_STEAMCMD_DIR=.*$|CFG_STEAMCMD_DIR=\"$v_steam\"|" "$self_file"
    sed -i "s|^CFG_KLEI_DIR=.*$|CFG_KLEI_DIR=\"$v_klei\"|" "$self_file"
    sed -i "s|^CFG_SAVE_DIR_NAME=.*$|CFG_SAVE_DIR_NAME=\"$v_save\"|" "$self_file"
    sed -i "s|^CFG_BACKUP_REPO=.*$|CFG_BACKUP_REPO=\"$v_backup\"|" "$self_file"
    sed -i "s|^CFG_SERVICE_MODE=.*$|CFG_SERVICE_MODE=\"$v_mode\" # screen / external|" "$self_file"
    sed -i "s|^CFG_SCREEN_MASTER_NAME=.*$|CFG_SCREEN_MASTER_NAME=\"$v_master\"|" "$self_file"
    sed -i "s|^CFG_SCREEN_CAVES_NAME=.*$|CFG_SCREEN_CAVES_NAME=\"$v_caves\"|" "$self_file"
    sed -i "s|^CFG_INITIALIZED=.*$|CFG_INITIALIZED=\"1\"                                     # 0: 首次运行未初始化, 1: 已初始化|" "$self_file"
}

run_init_wizard() {
    local script_file dst_dir klei_dir cluster steamcmd_dir backup_repo service_mode
    local -a dst_candidates cluster_candidates

    script_file="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

    mapfile -t dst_candidates < <(collect_dst_dirs || true)
    if [ "${#dst_candidates[@]}" -eq 0 ]; then
        echo -e "${RED}❌ 未探测到 DST 安装目录（缺少 bin/dontstarve_dedicated_server_nullrenderer）${NC}"
        pause
        return
    fi
    dst_dir="$(choose_from_list "检测到 DST 安装目录：" "${dst_candidates[@]}")" || return

    klei_dir="$KLEI_DIR"
    [ -d "$klei_dir" ] || klei_dir="$HOME/.klei/DoNotStarveTogether"
    [ -d "$klei_dir" ] || klei_dir="/home/steam/.klei/DoNotStarveTogether"

    mapfile -t cluster_candidates < <(collect_clusters "$klei_dir" || true)
    if [ "${#cluster_candidates[@]}" -eq 0 ]; then
        cluster="$SAVE_DIR_NAME"
        echo -e "${YELLOW}⚠️ 未探测到包含 Master/Caves 的集群，沿用当前：$cluster${NC}"
    else
        cluster="$(choose_from_list "检测到存档集群：" "${cluster_candidates[@]}")" || return
    fi

    steamcmd_dir="$(init_detect_steamcmd_dir)"
    backup_repo="$BACKUP_REPO"
    service_mode="$(init_detect_service_mode)"

    apply_runtime_config "$dst_dir" "$steamcmd_dir" "$klei_dir" "$cluster" "$backup_repo" "$service_mode"

    print_line
    echo -e "${CYAN}初始化结果：${NC}"
    echo " DST_DIR=$DST_DIR"
    echo " STEAMCMD_DIR=$STEAMCMD_DIR"
    echo " KLEI_DIR=$KLEI_DIR"
    echo " SAVE_DIR_NAME=$SAVE_DIR_NAME"
    echo " BACKUP_REPO=$BACKUP_REPO"
    echo " SERVICE_MODE=$SERVICE_MODE"
    if save_embedded_config "$script_file"; then
        CFG_INITIALIZED="1"
        echo -e "${GREEN}✅ 已写入脚本内嵌配置：$script_file${NC}"
    else
        echo -e "${RED}❌ 写入脚本失败，请检查文件权限。${NC}"
    fi
    pause
}

show_help_text() {
    cat <<EOF
DST Tool ${SCRIPT_VERSION} 内置说明
==================================================
一、快速开始
1) 首次运行会自动进入初始化向导
2) 手动执行初始化：$(basename "$0") --init
3) 或在主菜单选择：11. 脚本工具 -> 1. 初始化/重扫配置
4) 初始化会把结果写回脚本顶部 CFG_* 配置

二、最小手动配置（脚本顶部）
1) CFG_DST_DIR: DST 专用服目录（含 bin/）
2) CFG_KLEI_DIR: Klei 数据目录
3) CFG_SAVE_DIR_NAME: 集群名（存档目录名）
4) CFG_SERVICE_MODE: screen / external

三、运行模式
1) screen: 由本脚本负责启停，支持控制台指令
2) external: 本脚本不启停，只做配置/备份/活动/Mod 管理

四、扫描逻辑（初始化时）
1) 扫 DST 安装目录候选（要求存在可执行文件）
2) 扫 KLEI_DIR 下包含 Master+Caves 的集群目录
3) 自动识别 steamcmd 目录

五、常见问题
1) Mod 名称未解析：通常是该 Mod 未下载到本机
2) 外部托管状态显示异常：先确认 CFG_SAVE_DIR_NAME 与实际 -cluster 一致
3) 回档前请确保服务已停（external 模式下尤其重要）
==================================================
EOF
}

show_help_interactive() {
    clear
    show_help_text
    pause
}

show_current_config() {
    print_line
    echo -e "${CYAN}当前脚本配置:${NC}"
    echo " DST_DIR=$DST_DIR"
    echo " STEAMCMD_DIR=$STEAMCMD_DIR"
    echo " KLEI_DIR=$KLEI_DIR"
    echo " SAVE_DIR_NAME=$SAVE_DIR_NAME"
    echo " BACKUP_REPO=$BACKUP_REPO"
    echo " SERVICE_MODE=$SERVICE_MODE"
    echo " SCREEN_MASTER_NAME=$SCREEN_MASTER_NAME"
    echo " SCREEN_CAVES_NAME=$SCREEN_CAVES_NAME"
    echo " CFG_INITIALIZED=${CFG_INITIALIZED:-0}"
    pause
}

script_tools_menu() {
    local tool_choice
    while true; do
        clear
        echo "=================================================="
        echo -e "   🛠 ${CYAN}脚本工具${NC} 🛠"
        echo "=================================================="
        print_line
        echo "1. ⚙️ 初始化/重扫配置"
        echo "2. ℹ️ 使用说明"
        echo "3. 📋 查看当前配置"
        echo "0. 🔙 返回主菜单"
        echo "=================================================="
        read -r -p "请选择: " tool_choice || return
        case "$tool_choice" in
            1) run_init_wizard ;;
            2) show_help_interactive ;;
            3) show_current_config ;;
            0) return ;;
            *) echo -e "${RED}❌ 无效选项${NC}"; sleep 0.5 ;;
        esac
    done
}

auto_init_if_needed() {
    if [ "${CFG_INITIALIZED:-0}" = "1" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        echo -e "${YELLOW}⚠️ 检测到首次运行且未初始化，但当前非交互终端。请先执行: $(basename "$0") --init${NC}"
        return 0
    fi

    echo -e "${YELLOW}ℹ️ 检测到首次运行，自动进入初始化向导...${NC}"
    run_init_wizard
}

check_status() {
    local master_status="${RED}🔴 未运行${NC}"
    local caves_status="${RED}🔴 未运行${NC}"
    local extra="" ext_master=0 ext_caves=0
    if screen_session_exists "$SCREEN_MASTER_NAME"; then
        master_status="${GREEN}🟢 运行中(screen)${NC}"
    elif external_shard_running "Master"; then
        master_status="${GREEN}🟢 运行中(external)${NC}"
        ext_master=1
    fi

    if screen_session_exists "$SCREEN_CAVES_NAME"; then
        caves_status="${GREEN}🟢 运行中(screen)${NC}"
    elif external_shard_running "Caves"; then
        caves_status="${GREEN}🟢 运行中(external)${NC}"
        ext_caves=1
    fi

    if external_dst_running; then
        if [ "$ext_master" -eq 1 ] || [ "$ext_caves" -eq 1 ]; then
            extra="    进程: ${YELLOW}🟡 外部托管${NC}"
        else
            extra="    进程: ${YELLOW}🟡 检测到外部进程(非当前分片参数)${NC}"
        fi
    fi
    echo -e "   地面: $master_status    洞穴: $caves_status$extra"
}

pause() { echo -e "\n${WHITE}按回车键继续...${NC}"; read -r || true; }

send_cmd_to_master() {
    local cmd="$1"
    local desc="$2"
    if ! screen_session_exists "$SCREEN_MASTER_NAME"; then
        external_dst_running && warn_external_manager
        echo -e "${RED}❌ 地面服务器未运行，无法发送指令。${NC}"; pause; return
    fi
    echo -e "${BLUE}📡 发送指令: $desc${NC}"
    screen -S "$SCREEN_MASTER_NAME" -p 0 -X eval "stuff \"$cmd\015\""
    echo -e "${YELLOW}⏳ 等待服务器响应...${NC}"; sleep 1
    echo -e "${CYAN}📋 --- 最近 3 条日志反馈 ---${NC}"
    tail -n 3 "$LOG_MASTER"
    echo -e "${CYAN}-----------------------------${NC}"; pause
}

normalize_mod_id() {
    local raw="${1#workshop-}"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then echo "$raw"; return 0; fi
    return 1
}

trim_text() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

resolve_mod_input() {
    local raw mods_count
    local -a mods
    raw=$(trim_text "$1")
    [ -n "$raw" ] || return 1

    if [[ "$raw" =~ id=([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$raw" =~ workshop-([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; return 0; fi
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        mapfile -t mods < <(get_configured_mod_ids)
        mods_count=${#mods[@]}
        if [ "$mods_count" -gt 0 ] && [ "$raw" -ge 1 ] && [ "$raw" -le "$mods_count" ]; then
            echo "${mods[$((raw - 1))]}"; return 0
        fi
        echo "$raw"; return 0
    fi
    return 1
}

parse_mod_targets() {
    local raw raw_lower part modid start end i tmp
    local -a configured out parts
    raw=$(trim_text "$1")
    [ -n "$raw" ] || return 1
    raw_lower=$(echo "$raw" | tr '[:upper:]' '[:lower:]')

    mapfile -t configured < <(get_configured_mod_ids)
    if [ "$raw_lower" = "all" ]; then
        [ "${#configured[@]}" -gt 0 ] || return 1
        printf '%s\n' "${configured[@]}" | awk 'NF && !seen[$0]++'
        return 0
    fi

    IFS=',' read -r -a parts <<< "$raw"
    for part in "${parts[@]}"; do
        part=$(trim_text "$part")
        [ -n "$part" ] || continue

        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            [ "${#configured[@]}" -gt 0 ] || return 1
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
            if [ "$start" -gt "$end" ]; then tmp="$start"; start="$end"; end="$tmp"; fi
            if [ "$start" -lt 1 ] || [ "$end" -gt "${#configured[@]}" ]; then return 1; fi
            for ((i = start; i <= end; i++)); do out+=("${configured[$((i - 1))]}") ; done
            continue
        fi

        modid=$(resolve_mod_input "$part") || return 1
        out+=("$modid")
    done

    [ "${#out[@]}" -gt 0 ] || return 1
    printf '%s\n' "${out[@]}" | awk 'NF && !seen[$0]++'
}

ensure_override_file() {
    local file="$1"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        cat > "$file" <<'EOF'
return {
}
EOF
    fi
}

ensure_mod_files() {
    mkdir -p "$DST_DIR/mods" "$KLEI_DIR/$SAVE_DIR_NAME/Master" "$KLEI_DIR/$SAVE_DIR_NAME/Caves"
    touch "$MOD_SETUP_FILE"
    ensure_override_file "$MOD_OVERRIDE_MASTER"
    ensure_override_file "$MOD_OVERRIDE_CAVES"
}

ensure_level_override_file() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    if [ ! -f "$file" ] || [ ! -s "$file" ]; then
        cat > "$file" <<'EOF'
return {
    overrides = {
    },
}
EOF
    fi
}

# ================= 活动配置读写（纯 Shell/AWK） =================
read_level_override_value() {
    local file="$1" key="$2"
    ensure_level_override_file "$file"
    awk -v k="$key" '
        BEGIN { q = sprintf("%c", 39) }
        {
            line = $0
            if (line ~ ("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*")) {
                sub("^[[:space:]]*" k "[[:space:]]*=[[:space:]]*", "", line)
            } else if (line ~ ("^[[:space:]]*\\[\"" k "\"\\][[:space:]]*=[[:space:]]*")) {
                sub("^[[:space:]]*\\[\"" k "\"\\][[:space:]]*=[[:space:]]*", "", line)
            } else {
                next
            }

            sub(/[[:space:]]*,[[:space:]]*$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^"/) {
                sub(/^"/, "", line)
                sub(/"$/, "", line)
                print line
                exit
            }
            if (substr(line, 1, 1) == q) {
                sub("^" q, "", line)
                sub(q "$", "", line)
                print line
                exit
            }
            print line
            exit
        }
    ' "$file"
}

set_level_override_value() {
    local file="$1" key="$2" value="$3"
    local esc_value tmp
    ensure_level_override_file "$file"
    esc_value="${value//\\/\\\\}"
    esc_value="${esc_value//\"/\\\"}"

    if ! grep -qE 'overrides[[:space:]]*=[[:space:]]*\{|\\["overrides"\\][[:space:]]*=[[:space:]]*\{' "$file"; then
        if grep -qE 'return[[:space:]]*\{' "$file"; then
            sed -i -E "/return[[:space:]]*\{/a\\
    overrides = {\\
        $key = \"$esc_value\",\\
    },
" "$file"
        else
            cat > "$file" <<EOF
return {
    overrides = {
        $key = "$esc_value",
    },
}
EOF
        fi
        echo "changed"
        return 0
    fi

    tmp=$(mktemp)
    if awk -v k="$key" -v v="$esc_value" '
        function brace_delta(s,   i,c,d) {
            d = 0
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "{") d++
                else if (c == "}") d--
            }
            return d
        }
        BEGIN { in_overrides = 0; depth = 0; replaced = 0 }
        {
            line = $0
            if (!in_overrides && (line ~ /overrides[[:space:]]*=[[:space:]]*\{/ || line ~ /\["overrides"\][[:space:]]*=[[:space:]]*\{/)) {
                in_overrides = 1
                depth = brace_delta(line)
                print line
                next
            }

            if (in_overrides) {
                d = brace_delta(line)
                if (line ~ ("^[[:space:]]*" k "[[:space:]]*=") || line ~ ("^[[:space:]]*\\[\"" k "\"\\][[:space:]]*=")) {
                    match(line, /^[[:space:]]*/)
                    indent = substr(line, RSTART, RLENGTH)
                    print indent k " = \"" v "\","
                    replaced = 1
                    depth += d
                    if (depth <= 0) in_overrides = 0
                    next
                }

                if ((depth + d) <= 0 && !replaced) {
                    print "        " k " = \"" v "\","
                    replaced = 1
                }
                print line
                depth += d
                if (depth <= 0) in_overrides = 0
                next
            }

            print line
        }
        END {
            if (!replaced) exit 3
        }
    ' "$file" > "$tmp"; then
        mv "$tmp" "$file"
        echo "changed"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

apply_event_value_to_file() {
    local file="$1" key="$2" value="$3" current result
    current=$(read_level_override_value "$file" "$key")
    [ -z "$current" ] && current="default"
    if [ "$current" = "$value" ]; then return 2; fi

    [ -f "$file" ] && cp "$file" "$file.bak"
    result=$(set_level_override_value "$file" "$key" "$value") || return 1
    [ "$result" = "changed" ] || return 1
    return 0
}

event_label() {
    local key="$1"
    case "$key" in
        crow_carnival) echo "鸦年华" ;; hallowed_nights) echo "万圣夜" ;;
        winters_feast) echo "冬季盛宴" ;; year_of_the_beefalo) echo "皮弗娄牛年" ;;
        year_of_the_bunnyman) echo "兔人年" ;; year_of_the_carrat) echo "胡萝卜鼠年" ;;
        year_of_the_catcoon) echo "浣猫年" ;; year_of_the_dragonfly) echo "龙蝇年" ;;
        year_of_the_gobbler) echo "火鸡年" ;; year_of_the_knight) echo "骑士年" ;;
        year_of_the_pig) echo "猪年" ;; year_of_the_snake) echo "蛇年" ;;
        year_of_the_varg) echo "座狼年" ;; *) echo "$key" ;;
    esac
}

list_events() {
    local key i mval cval label
    print_line
    echo -e "${CYAN}活动状态（default / enabled）:${NC}"
    for ((i = 0; i < ${#EVENT_KEYS[@]}; i++)); do
        key="${EVENT_KEYS[$i]}"
        label=$(event_label "$key")
        mval=$(read_level_override_value "$LEVEL_OVERRIDE_MASTER" "$key")
        cval=$(read_level_override_value "$LEVEL_OVERRIDE_CAVES" "$key")
        [ -z "$mval" ] && mval="default"
        [ -z "$cval" ] && cval="default"
        printf "%2d. %-24s Master:%-8s Caves:%-8s %s\n" "$((i + 1))" "$key" "$mval" "$cval" "$label"
    done
}

set_event_value() {
    local idx action key value changed=0 errors=0 rc
    list_events
    echo ""
    read -r -p "选择活动序号 (q返回): " idx
    [[ "$idx" == "q" ]] && return
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#EVENT_KEYS[@]}" ]; then
        echo -e "${RED}❌ 无效序号${NC}"; pause; return
    fi
    key="${EVENT_KEYS[$((idx - 1))]}"

    echo "1) enabled  2) default"
    read -r -p "目标值: " action
    case "$action" in
        1) value="enabled" ;;
        2) value="default" ;;
        *) echo -e "${RED}❌ 无效值${NC}"; pause; return ;;
    esac

    apply_event_value_to_file "$LEVEL_OVERRIDE_MASTER" "$key" "$value"; rc=$?
    [ "$rc" -eq 0 ] && changed=$((changed + 1)); [ "$rc" -eq 1 ] && errors=$((errors + 1))
    
    apply_event_value_to_file "$LEVEL_OVERRIDE_CAVES" "$key" "$value"; rc=$?
    [ "$rc" -eq 0 ] && changed=$((changed + 1)); [ "$rc" -eq 1 ] && errors=$((errors + 1))

    if [ "$errors" -gt 0 ]; then
        echo -e "${RED}❌ 写入失败，请检查文件权限。${NC}"
    elif [ "$changed" -gt 0 ]; then
        echo -e "${GREEN}✅ 活动配置已更新(双分片): $key -> $value${NC}"
        screen -ls | grep -qE "DST_Master|DST_Caves" && echo -e "${YELLOW}ℹ️ 服务器运行中，建议重启后生效。${NC}"
    fi
    pause
}

event_menu() {
    while true; do
        clear
        echo "=================================================="
        echo -e "   🎉 ${CYAN}季节活动开关${NC} 🎉"
        echo "=================================================="
        print_line
        echo "1. 📄 查看活动状态"
        echo "2. ⚙️  设置活动（enabled/default）"
        echo "0. 🔙 返回主菜单"
        echo "=================================================="
        read -r -p "请选择: " event_choice || return
        case $event_choice in
            1) list_events; pause ;;
            2) set_event_value ;;
            0) return ;;
            *) echo -e "${RED}❌ 无效选项${NC}"; sleep 0.5 ;;
        esac
    done
}

# ================= Mod 管理函数 =================
extract_mod_ids_from_file() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -vE '^[[:space:]]*--' "$file" \
        | grep -oE 'ServerMod(Set|Collection)up[[:space:]]*\([[:space:]]*"(workshop-)?[0-9]+"[[:space:]]*\)|\["workshop-[0-9]+"\]' \
        | grep -oE '(workshop-)?[0-9]+' \
        | sed 's/^workshop-//'
}

get_configured_mod_ids() {
    { extract_mod_ids_from_file "$MOD_SETUP_FILE"
      extract_mod_ids_from_file "$MOD_OVERRIDE_MASTER"
      extract_mod_ids_from_file "$MOD_OVERRIDE_CAVES"
    } | awk 'NF && !seen[$0]++'
}

get_install_mod_ids() {
    extract_mod_ids_from_file "$MOD_SETUP_FILE" | awk 'NF && !seen[$0]++'
}

mod_has_setup_entry() {
    local modid="$1"
    [ -f "$MOD_SETUP_FILE" ] || return 1
    grep -vE '^[[:space:]]*--' "$MOD_SETUP_FILE" | grep -qE "ServerMod(Set|Collection)up[[:space:]]*\\([[:space:]]*\"(workshop-)?$modid\""
}

mod_in_override() { [ -f "$1" ] && grep -q "\\[\"workshop-$2\"\\]" "$1"; }

mod_is_downloaded() {
    local modid="$1"
    [ -d "$DST_DIR/mods/workshop-$modid" ] \
        || [ -d "$STEAMCMD_DIR/steamapps/workshop/content/322330/$modid" ] \
        || [ -d "$HOME/Steam/steamapps/workshop/content/322330/$modid" ] \
        || find "$DST_DIR/ugc_mods" -type d -path "*/content/322330/$modid" -print -quit 2>/dev/null | grep -q .
}

get_mod_name() {
    local modid="$1" file line
    local -a files roots save_variants
    local root shard sv modroot

    roots=(
        "$DST_DIR"
        "/home/steam/dontstarvetogether_dedicated_server"
    )
    save_variants=(
        "$SAVE_DIR_NAME"
        "${SAVE_DIR_NAME}$"
    )

    for root in "${roots[@]}"; do
        files+=(
            "$root/mods/workshop-$modid/modinfo_chs.lua"
            "$root/mods/workshop-$modid/modinfo.lua"
        )
        for sv in "${save_variants[@]}"; do
            for shard in Master Caves; do
                files+=(
                    "$root/ugc_mods/$sv/$shard/content/322330/$modid/modinfo_chs.lua"
                    "$root/ugc_mods/$sv/$shard/content/322330/$modid/modinfo.lua"
                )
            done
        done

        while IFS= read -r modroot; do
            files+=(
                "$modroot/modinfo_chs.lua"
                "$modroot/modinfo.lua"
            )
        done < <(find "$root/ugc_mods" -type d -path "*/content/322330/$modid" 2>/dev/null)
    done

    files+=(
        "$STEAMCMD_DIR/steamapps/workshop/content/322330/$modid/modinfo_chs.lua"
        "$STEAMCMD_DIR/steamapps/workshop/content/322330/$modid/modinfo.lua"
        "$HOME/Steam/steamapps/workshop/content/322330/$modid/modinfo_chs.lua"
        "$HOME/Steam/steamapps/workshop/content/322330/$modid/modinfo.lua"
    )

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        while IFS= read -r line; do
            line="${line%$'\r'}"
            [[ "$line" =~ ^[[:space:]]*-- ]] && continue
            [[ "$line" =~ ^[[:space:]]*name[[:space:]]*= ]] || continue
            if [[ "$line" =~ \"([^\"]+)\" ]] || [[ "$line" =~ \'([^\']+)\' ]] || [[ "$line" =~ \[\[([^]]+)\]\] ]]; then
                echo "${BASH_REMATCH[1]}"
                return 0
            fi
        done < "$file"
    done
    echo "(名称未解析)"
}

print_mod_brief() {
    local idx="$1" modid="$2"
    printf "%2d. %-12s %s\n" "$idx" "$modid" "$(get_mod_name "$modid")"
}

# 批量拉起 SteamCMD，大幅优化下载速度
download_mods_batch() {
    local mod_args="+login anonymous"
    for modid in "$@"; do
        echo -e "${BLUE}⬇️  加入下载队列: $modid${NC}"
        mod_args+=" +workshop_download_item 322330 $modid validate"
    done
    mod_args+=" +quit"
    echo -e "${YELLOW}⏳ 正在调用 SteamCMD 批量执行...${NC}"
    "$STEAMCMD_DIR/steamcmd.sh" $mod_args
}

download_mod() { download_mods_batch "$1"; }

add_setup_entry() {
    local modid="$1"
    ensure_mod_files
    mod_has_setup_entry "$modid" && return 1
    echo "ServerModSetup(\"$modid\")" >> "$MOD_SETUP_FILE"
    return 0
}

remove_setup_entry() {
    local modid="$1"
    [ -f "$MOD_SETUP_FILE" ] && sed -i -E "/ServerMod(Set|Collection)up[[:space:]]*\\([[:space:]]*\"(workshop-)?$modid\"[[:space:]]*\\)/d" "$MOD_SETUP_FILE"
}

insert_mod_override() {
    local file="$1" key="workshop-$2"
    ensure_override_file "$file"
    grep -q "\\[\"$key\"\\]" "$file" && return
    sed -i -E "/return[[:space:]]*\{/a \    [\"$key\"] = { configuration_options = {}, enabled = true }," "$file"
}

remove_mod_override() { [ -f "$1" ] && sed -i "/\\[\"workshop-$2\"\\][[:space:]]*=.*/d" "$1"; }

notify_mod_restart_hint() {
    cluster_process_running && echo -e "${YELLOW}ℹ️ Mod 变更需重启服务器后生效。${NC}"
}

snapshot_mod_files() {
    local snapshot_dir="$1"
    mkdir -p "$snapshot_dir"
    [ -f "$MOD_SETUP_FILE" ] && cp "$MOD_SETUP_FILE" "$snapshot_dir/setup.lua"
    [ -f "$MOD_OVERRIDE_MASTER" ] && cp "$MOD_OVERRIDE_MASTER" "$snapshot_dir/master.lua"
    [ -f "$MOD_OVERRIDE_CAVES" ] && cp "$MOD_OVERRIDE_CAVES" "$snapshot_dir/caves.lua"
}

restore_mod_files_if_changed() {
    local snapshot_dir="$1"
    local changed=0

    ensure_mod_files
    if [ -f "$snapshot_dir/setup.lua" ] && ! cmp -s "$snapshot_dir/setup.lua" "$MOD_SETUP_FILE"; then
        cp "$snapshot_dir/setup.lua" "$MOD_SETUP_FILE"
        changed=1
    fi
    if [ -f "$snapshot_dir/master.lua" ] && ! cmp -s "$snapshot_dir/master.lua" "$MOD_OVERRIDE_MASTER"; then
        cp "$snapshot_dir/master.lua" "$MOD_OVERRIDE_MASTER"
        changed=1
    fi
    if [ -f "$snapshot_dir/caves.lua" ] && ! cmp -s "$snapshot_dir/caves.lua" "$MOD_OVERRIDE_CAVES"; then
        cp "$snapshot_dir/caves.lua" "$MOD_OVERRIDE_CAVES"
        changed=1
    fi
    echo "$changed"
}

download_missing_install_mods() {
    local mods modid
    mods=$(get_install_mod_ids)
    [ -n "$mods" ] || return

    while read -r modid; do
        [ -n "$modid" ] || continue
        mod_is_downloaded "$modid" || download_mod "$modid"
    done <<< "$mods"
}

add_mod_core() {
    local modid="$1"
    add_setup_entry "$modid"
    insert_mod_override "$MOD_OVERRIDE_MASTER" "$modid"
    insert_mod_override "$MOD_OVERRIDE_CAVES" "$modid"
    download_mod "$modid"
    notify_mod_restart_hint
}

enable_mod_core() {
    local modid="$1"
    insert_mod_override "$MOD_OVERRIDE_MASTER" "$modid"
    insert_mod_override "$MOD_OVERRIDE_CAVES" "$modid"
    echo -e "${GREEN}✅ 已启用: workshop-$modid${NC}"
    mod_has_setup_entry "$modid" || echo -e "${YELLOW}⚠️ 该 Mod 不在 setup.lua 中，建议补齐。${NC}"
}

disable_mod_core() {
    local modid="$1"
    remove_mod_override "$MOD_OVERRIDE_MASTER" "$modid"
    remove_mod_override "$MOD_OVERRIDE_CAVES" "$modid"
    echo -e "${GREEN}✅ 已禁用: workshop-$modid${NC}"
}

remove_mod_core() {
    local modid="$1"
    remove_setup_entry "$modid"
    remove_mod_override "$MOD_OVERRIDE_MASTER" "$modid"
    remove_mod_override "$MOD_OVERRIDE_CAVES" "$modid"
    echo -e "${GREEN}✅ 已移除配置: $modid${NC}"
}

render_mod_list() {
    local mods modid i=1
    ensure_mod_files
    mods=$(get_configured_mod_ids)
    if [ -z "$mods" ]; then echo -e "${YELLOW}暂无已配置 Mod${NC}"; return 1; fi
    echo -e "${CYAN}已配置 Mod 列表:${NC}"
    while read -r modid; do
        [ -n "$modid" ] && print_mod_brief "$i" "$modid" && ((i++))
    done <<< "$mods"
    return 0
}

update_all_mods() {
    print_line
    ensure_mod_files
    mapfile -t mods_array < <(get_install_mod_ids)
    if [ ${#mods_array[@]} -eq 0 ]; then echo -e "${YELLOW}暂无可更新的 Mod${NC}"; pause; return; fi
    download_mods_batch "${mods_array[@]}"
    echo -e "${GREEN}✅ 全部 Mod 更新完成${NC}"
    pause
}

batch_mod_menu() {
    local raw op mods modid ok=0 fail=0
    print_line
    render_mod_list || { pause; return; }
    echo "支持格式: all / 1,3,8 / 2-6"
    read -r -p "输入目标 (q返回): " raw
    [[ "$raw" == "q" ]] && return
    mods=$(parse_mod_targets "$raw") || { echo -e "${RED}❌ 目标解析失败${NC}"; pause; return; }

    echo "1) 启用  2) 禁用  3) 移除配置"
    read -r -p "选择动作: " op
    while read -r modid; do
        [ -n "$modid" ] || continue
        echo -e "${BLUE}▶ 处理: $modid${NC}"
        case "$op" in
            1) enable_mod_core "$modid" ;;
            2) disable_mod_core "$modid" ;;
            3) remove_mod_core "$modid" ;;
            *) echo "无效操作"; break ;;
        esac
        [ $? -eq 0 ] && ((ok++)) || ((fail++))
    done <<< "$mods"
    echo -e "${GREEN}✅ 完成: 成功 $ok, 失败 $fail${NC}"; pause
}

mod_menu() {
    while true; do
        clear
        echo "=================================================="
        echo -e "   🧩 ${CYAN}Mod 管理中心${NC} 🧩"
        echo "=================================================="
        print_line
        echo "1. 📄 查看列表"
        echo "2. ➕ 添加/安装新 Mod (支持ID)"
        echo "3. 🧰 批量操作 (启用/禁用/删除)"
        echo "4. 🔄 批量更新全部 Mod (极速版)"
        echo "0. 🔙 返回主菜单"
        echo "=================================================="
        read -r -p "请选择: " mod_choice || return
        case $mod_choice in
            1) print_line; render_mod_list; pause ;;
            2) print_line; read -r -p "输入 Mod ID: " raw
               modid=$(resolve_mod_input "$raw") && add_mod_core "$modid" || echo "无效"; pause ;;
            3) batch_mod_menu ;;
            4) update_all_mods ;;
            0) return ;;
            *) sleep 0.5 ;;
        esac
    done
}

# ================= 核心与数据功能 =================

start_shards_direct() {
    if ! have_screen; then
        echo -e "${RED}❌ 启动失败：未检测到 screen。${NC}"
        return 1
    fi
    if [ ! -d "$DST_BIN_DIR" ]; then
        echo -e "${RED}❌ 启动失败：目录不存在 $DST_BIN_DIR${NC}"
        return 1
    fi
    if [ ! -x "$DST_EXEC" ]; then
        echo -e "${RED}❌ 启动失败：可执行文件不存在或无权限 $DST_EXEC${NC}"
        return 1
    fi

    cd "$DST_BIN_DIR" || return 1

    echo -e "${BLUE}🟢 启动 Master...${NC}"
    screen -dmS "$SCREEN_MASTER_NAME" ./dontstarve_dedicated_server_nullrenderer -console -cluster "$SAVE_DIR_NAME" -shard Master

    echo -e "${BLUE}🟢 启动 Caves...${NC}"
    screen -dmS "$SCREEN_CAVES_NAME" ./dontstarve_dedicated_server_nullrenderer -console -cluster "$SAVE_DIR_NAME" -shard Caves
    return 0
}

start_server() {
    print_line
    if ! lifecycle_managed_by_screen; then warn_lifecycle_disabled; pause; return; fi
    if external_dst_running; then warn_external_manager; pause; return; fi
    if screen_shards_running; then echo -e "${YELLOW}⚠️  已在运行中！${NC}"; pause; return; fi
    echo -e "${GREEN}🚀 启动服务器...${NC}"
    if ! start_shards_direct; then
        pause
        return
    fi
    echo -e "${GREEN}✅ 启动指令已发送。${NC}"
    pause
}

graceful_stop() {
    print_line
    if ! lifecycle_managed_by_screen; then warn_lifecycle_disabled; pause; return; fi
    echo -e "${YELLOW}🛑 正在停止服务器...${NC}"
    if external_dst_running && ! screen_shards_running; then warn_external_manager; pause; return; fi
    if ! screen_shards_running; then echo -e "${RED}⚠️  未运行。${NC}"; pause; return; fi
    for target in "$SCREEN_MASTER_NAME" "$SCREEN_CAVES_NAME"; do
        screen -list 2>/dev/null | grep -q "$target" && screen -S "$target" -p 0 -X eval 'stuff "c_shutdown(true)\015"'
    done
    echo -e "${BLUE}⏳ 监控存档保存状态...${NC}"
    for ((i=1; i<=40; i++)); do
        if ! screen_shards_running; then break; fi
        tail -n 10 "$LOG_MASTER" 2>/dev/null | grep -q "Shutting down" && break
        echo -n "."; sleep 0.5
    done
    screen -list 2>/dev/null | grep -E "$SCREEN_MASTER_NAME|$SCREEN_CAVES_NAME" | cut -d. -f1 | xargs -r -I{} screen -S {} -X quit
    echo -e "\n${GREEN}✅ 已完全停止。${NC}"; pause
}

restart_server() {
    if ! lifecycle_managed_by_screen; then warn_lifecycle_disabled; pause; return; fi
    if external_dst_running && ! screen_shards_running; then warn_external_manager; pause; return; fi
    screen_shards_running && { eval "orig_p=$(declare -f pause)"; pause(){ :; }; graceful_stop; eval "$orig_p"; }
    read -p "是否更新游戏版本? (y/n): " up_c
    [[ "$up_c" == "y" ]] && update_game
    start_server
}

update_game() {
    print_line; echo -e "${BLUE}⬇️  SteamCMD 正在拉取 DST 最新版本...${NC}"
    "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$DST_DIR" +login anonymous +app_update 343050 validate +quit
    echo -e "${GREEN}✅ 更新结束。${NC}"; pause
}

view_log() {
    [ -f "$1" ] && { echo -e "${CYAN}📺 $2日志 (Ctrl+C 退出)${NC}"; tail -f "$1"; } || { echo -e "${RED}❌ 无日志${NC}"; pause; }
}

view_log_menu() {
    local lc
    while true; do
        echo "1) 地面日志 2) 洞穴日志 0) 返回"
        read -r -p "选择: " lc
        case "$lc" in
            1) view_log "$LOG_MASTER" "地面"; return ;;
            2) view_log "$LOG_CAVES" "洞穴"; return ;;
            0) return ;;
            *) echo -e "${RED}❌ 无效输入，请输入 1/2/0${NC}" ;;
        esac
    done
}

create_backup() {
    print_line
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    if [ ! -d "$KLEI_DIR/$SAVE_DIR_NAME" ]; then echo -e "${RED}❌ 无存档数据${NC}"; pause; return; fi
    echo -e "${CYAN}💾 正在打包存档...${NC}"
    tar -zcf "$BACKUP_REPO/backup_${TIMESTAMP}.tar.gz" -C "$KLEI_DIR" "$SAVE_DIR_NAME"
    echo -e "${GREEN}✅ 备份完毕: backup_${TIMESTAMP}.tar.gz${NC}"
    
    # 自动清理机制：保留最近 10 份
    # echo -e "${CYAN}🧹 清理冗余旧备份 (保留 10 份)...${NC}"
    # ls -1t "$BACKUP_REPO"/backup_*.tar.gz 2>/dev/null | tail -n +11 | xargs -r rm -f
    pause
}

restore_backup() {
    local mod_snapshot_dir mod_changed
    print_line
    if external_dst_running && ! screen_shards_running; then
        warn_external_manager
        echo -e "${RED}❌ 请先停止外部托管服务后再回档，避免存档损坏。${NC}"
        pause
        return
    fi
    files=($(ls -1t "$BACKUP_REPO"/*.tar.gz 2>/dev/null))
    if [ ${#files[@]} -eq 0 ]; then echo -e "${RED}❌ 无可用备份${NC}"; pause; return; fi

    echo -e "${CYAN}📂 历史备份列表 (Top 10):${NC}"
    for ((i=0; i<${#files[@]} && i<10; i++)); do echo -e " [$i] $(basename "${files[$i]}")"; done

    read -p "选择恢复序号 (q退出): " c
    [[ "$c" == "q" ]] && return
    if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -ge "${#files[@]}" ]; then echo "❌ 无效"; pause; return; fi

    read -p "🔴 覆盖当前存档将导致现有数据丢失，确认继续? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    mod_snapshot_dir=$(mktemp -d)
    snapshot_mod_files "$mod_snapshot_dir"

    screen_shards_running && { eval "orig_p=$(declare -f pause)"; pause(){ :; }; graceful_stop; eval "$orig_p"; }

    echo -e "${YELLOW}🗑️  清除现有存档...${NC}"
    rm -rf "${KLEI_DIR:?}/${SAVE_DIR_NAME:?}"
    
    echo -e "${BLUE}📦 解压历史存档...${NC}"
    tar -zxf "${files[$c]}" -C "$KLEI_DIR"

    mod_changed=$(restore_mod_files_if_changed "$mod_snapshot_dir")
    rm -rf "$mod_snapshot_dir"
    if [ "$mod_changed" -eq 1 ]; then
        echo -e "${BLUE}🔄 回档覆盖了 Mod 配置，已恢复当前配置并检查缺失下载。${NC}"
        download_missing_install_mods
    fi

    echo -e "${GREEN}✅ 回档完成！${NC}"
    read -p "立即启动服务器? (y/n): " sn
    [[ "$sn" == "y" ]] && start_server || pause
}

console_menu() {
    while true; do
        clear
        echo "=================================================="
        echo -e "   🎮 ${CYAN}游戏内控制台${NC} 🎮"
        echo "=================================================="
        check_status
        print_line
        echo "1. 💾 立即保存 (c_save)"
        echo "2. ⏪ 回滚至昨天 (c_rollback(1))"
        echo "3. 📢 全服公告 (c_announce)"
        echo -e "4. ☠️  ${RED}重置世界 (c_regenerateworld)${NC}"
        echo "9. ⌨️  执行自定义 Lua 指令"
        echo "0. 🔙 返回主菜单"
        echo "=================================================="
        read -r -p "选择指令: " cmd_choice || return
        case $cmd_choice in
            1) send_cmd_to_master "c_save()" "立即保存" ;;
            2) send_cmd_to_master "c_rollback(1)" "回滚 1 天" ;;
            3) read -p "内容: " msg; send_cmd_to_master "c_announce(\"$msg\")" "发布公告";;
            4) read -p "输入 YES 确认重置: " cf; [[ "$cf" == "YES" ]] && send_cmd_to_master "c_regenerateworld()" "重置世界" ;;
            9) read -p "Lua: " user_cmd; send_cmd_to_master "$user_cmd" "自定义指令" ;;
            0) return ;;
        esac
    done
}

# ================= 主菜单循环 =================
case "${1:-}" in
    --init)
        run_init_wizard
        exit 0
        ;;
    --help|-h)
        show_help_text
        exit 0
        ;;
esac

auto_init_if_needed

while true; do
    clear
    echo "=================================================="
    echo -e "      🦁 ${CYAN}DST 服务器管理面板 ${SCRIPT_VERSION}${NC} 🦁"
    echo "=================================================="
    check_status
    print_line
    
    echo -e "${YELLOW}[ ⚡ 核心服务控制 ]${NC}"
    echo "  1. 🚀 启动    2. 🛑 停止    3. 🔄 重启    4. ⬇️ 更新"
    echo ""
    
    echo -e "${YELLOW}[ 🎮 游戏与模组管理 ]${NC}"
    echo "  5. ⌨️ 控制台/指令      7. 🧩 Mod 管理中心"
    echo "  6. 📜 查看运行日志    8. 🎉 季节活动配置"
    echo ""
    
    echo -e "${YELLOW}[ 💾 存档与数据安全 ]${NC}"
    echo "  9. 📦 备份当前存档    10. ⏪ 恢复历史存档"
    echo ""
    
    echo -e "${YELLOW}[ 🛠 脚本维护 ]${NC}"
    echo " 11. ⚙️ 脚本工具"
    print_line
    echo "  0. 🚪 退出面板"
    echo "=================================================="
    
    if ! read -r -p "请输入选项 [0-11]: " choice; then
        echo -e "\n${YELLOW}检测到输入流结束，退出脚本。${NC}"
        exit 0
    fi
    
    case $choice in
        1) start_server ;;
        2) graceful_stop ;;
        3) restart_server ;;
        4) update_game ;;
        5) console_menu ;;
        6) view_log_menu ;;
        7) mod_menu ;;
        8) event_menu ;;
        9) create_backup ;;
        10) restore_backup ;;
        11) script_tools_menu ;;
        0) echo -e "${GREEN}👋 拜拜！${NC}"; exit 0 ;;
        *) echo -e "${RED}❌ 无效选项${NC}"; sleep 0.5 ;;
    esac
done
