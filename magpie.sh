#!/usr/bin/env bash
# ==============================================================================
# magpie.sh — magpie 网关蓝绿自动升级 / 运维一体脚本
#
# 单文件、零配置起步、混合模式：
#   compose 模式：检测到 magpie 容器属于某个 compose 项目时，一切管理动作走
#                 docker compose（你现有的编排零改动）
#   docker 模式  ：容器是裸 docker run 起的（无 compose label），脚本自行
#                 docker run 管理，可完全脱离 compose
#   模式全自动判定，无需告知；也能用 MODE=compose|docker 强制指定。
#
# 蓝绿原理（绿 = 验证通过才前进；红 = 失败即回滚，线上由已验证版本服务）：
#   拉最新镜像 → 起临时容器（旁路端口）→ 健康 + 真实业务探测 → 切流量 →
#   旧容器按连接数退役 → 原位重建 → 状态合并 → 切回 → 清理 → 删旧镜像
#
# 依赖：bash 4+、curl、rsync、flock、docker CLI（compose v2 插件可选）；
#       jq 推荐（无则退化为 grep 提取密钥、跳过 JSON 校验）。
# ==============================================================================
set -u

# TODO-none: 本文件为最终交付，不含占位实现。
VERSION="1.0.0"
CONFIG_FILE="${MAGPIE_CONFIG:-/etc/magpie-upgrade.env}"

# ============================== 配置 ==============================
# 三级优先级：环境变量 > 配置文件 > 内置默认值。
# 必须在「内置默认值赋值之前」先抓环境变量，否则同名环境变量会被默认值掩盖
# （典型症状：VHOST=x magpie.sh --status 里 VHOST 仍是空，走了 direct 模式）。
_VARS="IMAGE DATA_DIR CONTAINER SERVICE WEB_PORT GATEWAY_PORT TEMP_PORT LIVE_PORT
BIND_IP VHOST PUBLIC_HOST NGINX_LOCAL_PORT NGINX_CONTAINER DRAIN RUNTIME_DIR KEEP_DAYS
STATE_DIR TMP_ROOT LOG_FILE TZ_VALUE MODE GATEWAY_KEY SKIP_DISK_CHECK SKIP_PULL FORCE TEMP_NAME"

declare -A _ENV=()
for _v in $_VARS; do
    eval "_c=\${$_v+set}"
    [ "${_c:-}" = "set" ] && eval "_ENV[\$_v]=\$$_v"
done
unset _c _v

# —— 内置默认值（仅在没有环境变量/配置文件时生效） ——
IMAGE="${IMAGE-ghcr.io/yetone/magpie:latest}"
DATA_DIR="${DATA_DIR-}"        # 必填；compose 模式可从容器 /config 挂载反推
CONTAINER="${CONTAINER-}"      # 空 = 自动探测
SERVICE="${SERVICE-magpie}"    # compose 服务名
WEB_PORT="${WEB_PORT-3430}"    # 容器内 web 端口（控制台 + 网关同端口）
GATEWAY_PORT="${GATEWAY_PORT-3425}"  # 容器内网关端口（仅连接数统计用）
TEMP_PORT="${TEMP_PORT-13430}" # 临时容器发布端口（不能与 LIVE_PORT 冲突）
LIVE_PORT="${LIVE_PORT-}"      # 空 = 自动探测
BIND_IP="${BIND_IP-}"          # 空 = 自动探测
VHOST="${VHOST-}"              # 空 = direct 模式（不做流量切换）
PUBLIC_HOST="${PUBLIC_HOST-}"  # 反代探活的 Host 头
NGINX_LOCAL_PORT="${NGINX_LOCAL_PORT-80}"
NGINX_CONTAINER="${NGINX_CONTAINER-}"  # 空 = 宿主机直接 nginx
DRAIN="${DRAIN-700}"           # 退役最长等待秒数
RUNTIME_DIR="${RUNTIME_DIR-}"  # 空 = 跳过 MCP 运行时检查与挂载
KEEP_DAYS="${KEEP_DAYS-30}"    # 对话保留天数
STATE_DIR="${STATE_DIR-/var/lib/magpie-upgrade}"
TMP_ROOT="${TMP_ROOT-/var/tmp}"
LOG_FILE="${LOG_FILE-}"
TZ_VALUE="${TZ_VALUE-}"
MODE="${MODE-}"                # 空 = 自动；compose | docker
GATEWAY_KEY="${GATEWAY_KEY-}"  # 空 = 从 caller-keys.json 提取
SKIP_DISK_CHECK="${SKIP_DISK_CHECK-0}"
SKIP_PULL="${SKIP_PULL-0}"     # 1 = 不 pull，直接用本地镜像（私有源 / 固定镜像 ID）
FORCE="${FORCE-0}"
TEMP_NAME="${TEMP_NAME-magpie-next}"

# compose 相关变量由 resolve_mode 填充；先声明空值，避免 set -u 下 docker 模式崩溃
COMPOSE_SERVICE=""; COMPOSE_FILE=""; COMPOSE_DIR=""
GW_KEYS=""; MOUNT_ARGS=()

# ============================== 工具 ==============================
now() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s %s\n' "$(date '+%H:%M:%S')" "magpie" "$*" >>"$LOG_FILE"; }
say() { log "$*"; printf '%s\n' "$*"; }
die() { say "FAIL $*"; exit 1; }
short() { printf '%s' "$1" | cut -c1-12; }
img_id() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }

# 日志在配置加载后才能落盘；之前的信息用 stderr
early() { printf '[magpie] %s\n' "$*" >&2; }

# ============================== 配置加载 ==============================
# 读配置文件，然后把「启动时的环境变量」重新盖回去（环境变量最高优先级）
load_config() {
    local v
    # shellcheck disable=SC1090
    if [ -r "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE" 2>/dev/null || true
    fi
    if [ "${#_ENV[@]}" -gt 0 ]; then
        for v in "${!_ENV[@]}"; do printf -v "$v" '%s' "${_ENV[$v]}"; done
    fi
    [ -n "$LOG_FILE" ] || LOG_FILE="$STATE_DIR/upgrade.log"
}

need_env() {
    # 两种模式都要 DATA_DIR：配置备份、状态合并、共享挂载都依赖 /config 的宿主机路径。
    # compose 模式能反推就自动填（resolve_data_dir），反推不到才要求显式指定。
    [ -n "$DATA_DIR" ] && return 0
    early "DATA_DIR 未配置，且无法从容器挂载反推 /config 的宿主机目录。"
    early "请在 $CONFIG_FILE 里设置 DATA_DIR=/path/to/magpie-data"
    exit 2
}

init_state() {
    mkdir -p "$STATE_DIR" || exit 2
    touch "$LOG_FILE" 2>/dev/null || exit 2
    STATE="$STATE_DIR/upgrade.state"; FAIL_FILE="$STATE_DIR/upgrade.fail"
    TRY_FILE="$STATE_DIR/upgrade.try"; LOCK_FILE="$STATE_DIR/upgrade.lock"
    TMP_DIR="$TMP_ROOT/magpie-next"; TMP_ENV="$TMP_ROOT/magpie-next.env"
    CFG_BAK="$TMP_ROOT/magpie-cfg.bak"; VHOST_BAK="$TMP_ROOT/magpie-vhost.bak"
    GW_KEYS_FILE="$DATA_DIR/magpie/caller-keys.json"
}

# ============================== 容器与模式识别 ==============================
# 自动识别容器名：
#   1. 显式配置 CONTAINER
#   2. compose 模式下通过 label 或 service 匹配
#   3. docker ps 找名字带 magpie 且健康/运行中的容器
detect_container() {
    [ -n "$CONTAINER" ] && { printf '%s' "$CONTAINER"; return 0; }
    local id c
    # 尝试按 compose label
    id=$(docker ps --filter "label=com.docker.compose.service=$SERVICE" --format '{{.ID}}' 2>/dev/null | head -1)
    if [ -n "$id" ]; then
        docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##'
        return 0
    fi
    # 尝试按容器名字包含 magpie
    c=$(docker ps --filter "name=magpie" --format '{{.Names}}' 2>/dev/null \
        | grep -v "next\|temp\|tmp" | head -1)
    [ -n "$c" ] && { printf '%s' "$c"; return 0; }
    return 1
}

# 识别管理模式：compose 还是 docker
resolve_mode() {
    [ -n "$MODE" ] && return 0
    if [ -z "$CONTAINER" ]; then
        MODE="docker"; return 0
    fi
    local p s cf
    p=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$CONTAINER" 2>/dev/null)
    s=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$CONTAINER" 2>/dev/null)
    cf=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$CONTAINER" 2>/dev/null)
    if [ -n "$p" ] && [ -n "$s" ] && [ -f "${cf%%,*}" ]; then
        MODE="compose"
        COMPOSE_SERVICE="$s"
        COMPOSE_FILE="${cf%%,*}"
        COMPOSE_DIR=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER" 2>/dev/null)
    else
        MODE="docker"
    fi
}

# 从运行容器反推 DATA_DIR（挂到 /config 的宿主机目录）
resolve_data_dir() {
    [ -n "$DATA_DIR" ] && return 0
    [ -n "$CONTAINER" ] || return 1
    local src
    src=$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)
    if [ -n "$src" ] && [ -d "$src" ]; then
        DATA_DIR="$src"
        GW_KEYS_FILE="$DATA_DIR/magpie/caller-keys.json"
        return 0
    fi
    return 1
}

detect_port_map() {
    local map
    map=$(docker port "$CONTAINER" "${WEB_PORT}/tcp" 2>/dev/null | head -1)
    if [ -n "$map" ]; then
        case "$map" in
            *:*:*) : ;;
            *:*)
                [ -n "$BIND_IP" ] || BIND_IP="${map%:*}"
                [ -n "$LIVE_PORT" ] || LIVE_PORT="${map##*:}"
                ;;
        esac
    fi
    if [ -z "$BIND_IP" ]; then
        local net
        net=$(docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$CONTAINER" 2>/dev/null | head -1)
        [ -n "$net" ] && BIND_IP=$(docker network inspect "$net" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null)
    fi
    [ -n "$BIND_IP" ] || BIND_IP="127.0.0.1"
    [ -n "$LIVE_PORT" ] || LIVE_PORT="$WEB_PORT"
}

detect_network() {
    docker inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$CONTAINER" 2>/dev/null | head -1
}

# ============================== 容器动作统一抽象 ==============================
# 两种模式在「起临时容器」「重建正式容器」上的差异封装于此，上层蓝绿逻辑只调
#   container_recreate   原位重建正式容器
#   container_run_temp   用新镜像起临时容器
# docker 模式的参数不靠猜：全部从运行中的容器 inspect 反推（entrypoint/cmd/env/
# 挂载/端口/网络/重启策略），重建结果与原容器等价，与 compose 无关。

declare -a SPEC_MOUNTS=() SPEC_ENTRYPOINT=() SPEC_CMD=() SPEC_NETWORKS=() SPEC_PORTS=()
SPEC_RESTART="always"

capture_spec() { # 从运行中的正式容器抓取启动规格
    local line
    SPEC_MOUNTS=(); SPEC_ENTRYPOINT=(); SPEC_CMD=(); SPEC_NETWORKS=(); SPEC_PORTS=()
    while IFS= read -r line; do
        [ -n "$line" ] && SPEC_MOUNTS+=("$line")
    done < <(docker inspect "$CONTAINER" --format \
        '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}|{{if .RW}}rw{{else}}ro{{end}}{{println}}{{end}}' 2>/dev/null)
    while IFS= read -r line; do
        [ -n "$line" ] && SPEC_ENTRYPOINT+=("$line")
    done < <(docker inspect "$CONTAINER" --format '{{range .Config.Entrypoint}}{{println .}}{{end}}' 2>/dev/null)
    while IFS= read -r line; do
        [ -n "$line" ] && SPEC_CMD+=("$line")
    done < <(docker inspect "$CONTAINER" --format '{{range .Config.Cmd}}{{println .}}{{end}}' 2>/dev/null)
    while IFS= read -r line; do
        [ -n "$line" ] && SPEC_NETWORKS+=("$line")
    done < <(docker inspect "$CONTAINER" --format \
        '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{println}}{{end}}' 2>/dev/null)
    # 端口绑定：每行 "容器端口|HostIp|HostPort"；无绑定时输出空
    while IFS= read -r line; do
        [ -n "$line" ] && SPEC_PORTS+=("$line")
    done < <(docker inspect "$CONTAINER" --format \
        '{{range $k, $v := .HostConfig.PortBindings}}{{range $v}}{{$k}}|{{.HostIp}}|{{.HostPort}}{{println}}{{end}}{{end}}' 2>/dev/null)
    SPEC_RESTART=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER" 2>/dev/null)
    [ -n "$SPEC_RESTART" ] || SPEC_RESTART="always"
    # 容器的 entrypoint 若与镜像默认值一致，就是镜像自带的——此时 docker run 会
    # 自动套用，不能再显式传一遍（否则 argv 变成 /magpie /magpie web ...，
    # 进程直接报 unknown agent 并无限重启）。只有被显式覆盖过才传 --entrypoint。
    local img_ep cur_ep
    img_ep=$(docker image inspect --format '{{range .Config.Entrypoint}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null)
    cur_ep=$(printf '%s\n' ${SPEC_ENTRYPOINT[@]+"${SPEC_ENTRYPOINT[@]}"})
    if [ "$img_ep" = "$cur_ep" ]; then
        SPEC_ENTRYPOINT=()
    fi
}

# docker 模式重建需要 --env-file。正常升级流程会生成 TMP_ENV，但恢复路径
# （上次升级被中断）可能没有它，这里按线上容器的实际环境补一份，避免重建必失败。
ensure_env_file() {
    [ -f "$TMP_ENV" ] && return 0
    umask 077
    docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null >"$TMP_ENV" || return 1
    [ -s "$TMP_ENV" ] || { rm -f "$TMP_ENV"; return 1; }
    umask 022
    return 0
}

# 把 SPEC_MOUNTS 转成 -v 参数；$1=要替换的 /config 源目录（空=原样）
mount_args_for() { # 结果放进全局 MOUNT_ARGS
    local replace_config="${1:-}" line src dst mode
    MOUNT_ARGS=()
    for line in ${SPEC_MOUNTS[@]+"${SPEC_MOUNTS[@]}"}; do
        IFS='|' read -r _ src dst mode <<<"$line"
        [ -n "$dst" ] || continue
        if [ -n "$replace_config" ] && [ "$dst" = "/config" ]; then
            src="$replace_config"
        fi
        MOUNT_ARGS+=(-v "${src}:${dst}:${mode:-rw}")
    done
}

# 兼容 docker compose (v2) 与 docker-compose (v1)
run_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        say "未找到 docker compose 或 docker-compose 命令行工具"
        return 127
    fi
}

container_recreate() { # $1=镜像（默认 $IMAGE；direct 回滚时传旧镜像 ID）
    local img="${1:-$IMAGE}"
    if [ "$MODE" = "compose" ]; then
        ( cd "${COMPOSE_DIR:-.}" && run_compose ${COMPOSE_FILE:+-f "$COMPOSE_FILE"} \
            up -d --no-deps --force-recreate "$COMPOSE_SERVICE" >/dev/null 2>&1 )
        return $?
    fi
    # docker 自管：抓规格 → 改名保留 → 用目标镜像起同等容器 → 成功则删旧。
    # 端口映射与环境变量必须一并复刻，否则重建后对外服务直接消失。
    capture_spec
    ensure_env_file || { say "无法生成重建所需的环境文件 $TMP_ENV"; return 1; }
    mount_args_for ""
    local net_args=() port_args=() n line key ip host
    for n in ${SPEC_NETWORKS[@]+"${SPEC_NETWORKS[@]}"}; do net_args+=(--network "$n"); done
    for line in ${SPEC_PORTS[@]+"${SPEC_PORTS[@]}"}; do
        IFS='|' read -r key ip host <<<"$line"
        [ -n "$key" ] && [ -n "$host" ] || continue
        port_args+=(-p "${ip:-0.0.0.0}:${host}:${key%/*}")
    done
    docker stop "$CONTAINER" >/dev/null 2>&1
    docker rename "$CONTAINER" "${CONTAINER}-old" >/dev/null 2>&1 || true
    if ! docker run -d --name "$CONTAINER" \
            --restart="$SPEC_RESTART" \
            ${net_args[@]+"${net_args[@]}"} \
            ${port_args[@]+"${port_args[@]}"} \
            "${MOUNT_ARGS[@]}" \
            --env-file "$TMP_ENV" \
            "$img" \
            ${SPEC_ENTRYPOINT[@]+"${SPEC_ENTRYPOINT[@]}"} \
            ${SPEC_CMD[@]+"${SPEC_CMD[@]}"} >/dev/null 2>&1; then
        docker rename "${CONTAINER}-old" "$CONTAINER" >/dev/null 2>&1 || true
        docker start "$CONTAINER" >/dev/null 2>&1 || true
        return 1
    fi
    docker rm -f "${CONTAINER}-old" >/dev/null 2>&1
    return 0
}

# 临时容器：共用正式容器的挂载与网络，只把 /config 换成副本、端口换成旁路端口
container_run_temp() { # $1=临时容器名 $2=镜像 $3=宿主机端口
    local tname="$1" img="$2" tport="$3" net_args=() n shared
    mount_args_for "$TMP_DIR"
    # /config 下的共享子路径：临时容器与正式容器看到同一份数据（O_APPEND 追加安全）
    for shared in cache magpie/usage.jsonl magpie/routing magpie/gateway-conversations \
                  magpie/gemini-signatures magpie/masking magpie/mcp-npm; do
        [ -e "$DATA_DIR/$shared" ] || continue
        MOUNT_ARGS+=(-v "$DATA_DIR/$shared:/config/$shared")
    done
    for n in ${SPEC_NETWORKS[@]+"${SPEC_NETWORKS[@]}"}; do net_args+=(--network "$n"); done
    docker run -d --name "$tname" \
        --restart=unless-stopped \
        ${net_args[@]+"${net_args[@]}"} \
        -p "${BIND_IP}:${tport}:${WEB_PORT}" \
        "${MOUNT_ARGS[@]}" \
        --env-file "$TMP_ENV" \
        "$img" \
        ${SPEC_ENTRYPOINT[@]+"${SPEC_ENTRYPOINT[@]}"} \
        ${SPEC_CMD[@]+"${SPEC_CMD[@]}"} >/dev/null 2>&1
}

# ============================== 探测 ==============================
state_of() {
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null
}

load_gateway_keys() {
    [ -n "$GATEWAY_KEY" ] && { printf '%s' "$GATEWAY_KEY"; return 0; }
    [ -f "$GW_KEYS_FILE" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[].secret // empty' "$GW_KEYS_FILE" 2>/dev/null
    else
        sed -n 's/.*"secret": *"\([^"]*\)".*/\1/p' "$GW_KEYS_FILE" 2>/dev/null | sort -u
    fi
}

probe() { # $1=宿主机端口：进程存活（200/401 都算活着）
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${BIND_IP}:$1/api/health" 2>/dev/null)
    [ "$code" = "200" ] || [ "$code" = "401" ]
}

probe_v1() { # $1=宿主机端口：真实业务路径必须 200（多把 key 逐个试）
    [ -n "$GW_KEYS" ] || return 0
    local k code
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -H "Authorization: Bearer $k" "http://${BIND_IP}:$1/v1/models" 2>/dev/null)
        [ "$code" = "200" ] && return 0
    done <<<"$GW_KEYS"
    return 1
}

probe_vhost() { # 经反代的完整链路
    [ -n "$VHOST" ] || return 0
    [ -n "$GW_KEYS" ] || return 0
    local k code
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            ${PUBLIC_HOST:+-H "Host: $PUBLIC_HOST"} \
            -H "Authorization: Bearer $k" \
            "http://127.0.0.1:${NGINX_LOCAL_PORT}/v1/models" 2>/dev/null)
        [ "$code" = "200" ] && return 0
    done <<<"$GW_KEYS"
    return 1
}

# 容器内指定端口的 ESTABLISHED 连接数 ≈ 此刻还在跑的请求数
conn_count() {
    local c=$1 pat n4 n6
    pat="$(printf '%04X' "$WEB_PORT")|$(printf '%04X' "$GATEWAY_PORT")"
    n4=$(docker exec "$c" cat /proc/net/tcp 2>/dev/null \
        | awk -v p=":($pat)\$" 'NR>1 && $2 ~ p && $4=="01"' | wc -l)
    n6=$(docker exec "$c" cat /proc/net/tcp6 2>/dev/null \
        | awk -v p=":($pat)\$" 'NR>1 && $2 ~ p && $4=="01"' | wc -l)
    echo $(( ${n4:-0} + ${n6:-0} ))
}

# 退役容器最长等待：清空立即收尾，否则等满 DRAIN
# 不能固定短时间：实测 p99.9=303s、最长 598s，被掐断的请求连用量都不写（静默失败）
drain_wait() { # $1=容器 $2=说明
    local c=$1 why=$2 i=0 n
    while [ "$i" -lt "$DRAIN" ]; do
        n=$(conn_count "$c")
        if [ "$n" -eq 0 ]; then
            say "$why：连接已清空（等待 ${i}s）"
            return 0
        fi
        sleep 5
        i=$((i + 5))
    done
    say "$why：已等满 ${DRAIN}s，仍有 $(conn_count "$c") 条连接（多为常驻 SSE），照常收尾"
}

wait_ready() { # $1=容器 $2=宿主机端口 $3=超时
    local c=$1 p=$2 t=${3:-120} i=0
    while [ "$i" -lt "$t" ]; do
        if [ "$(state_of "$c")" = "healthy" ] && probe "$p" && probe_v1 "$p"; then
            return 0
        fi
        sleep 3
        i=$((i + 3))
    done
    return 1
}

version_of() { docker exec "$1" magpie --version 2>/dev/null | awk '{print $2}'; }

# ============================== 反代 ==============================
set_vhost() { # $1=端口：改 proxy_pass 并确认生效（sed 不匹配会静默无变化）
    [ -n "$VHOST" ] || return 0
    sed -i "s#proxy_pass http://[0-9.]*:[0-9]*;#proxy_pass http://${BIND_IP}:$1;#" "$VHOST"
    grep -q "proxy_pass http://${BIND_IP}:$1;" "$VHOST"
}

reload_nginx() {
    if [ -n "$NGINX_CONTAINER" ]; then
        docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1 \
            && docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1
    elif command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1
    fi
}

# ============================== 临时容器与服务 ==============================
cleanup_temp() { # $1=merge 时先把副本里刷新的登录态并回
    [ "${1:-}" = "merge" ] && [ -d "$TMP_DIR/magpie" ] && merge_back
    docker rm -f "$TEMP_NAME" >/dev/null 2>&1
    rm -rf "$TMP_DIR" "$TMP_ENV"
}

# 把临时容器在退场窗口内写过的状态并回真实配置。
# 不做白名单：凡副本比线上新的文件都并回（跳过锁/备份/版本标记），避免上游新增
# 状态文件时清单没跟上，导致对话记录、掩码表等被整段丢弃。
merge_back() {
    local src dst stage f
    stage=$(mktemp "$TMP_ROOT/magpie-merge.stage.XXXXXX") || { say "创建合并暂存文件失败，跳过合并"; return; }
    trap 'rm -f "$stage"' RETURN
    for src in "$TMP_DIR"/magpie/*; do
        [ -f "$src" ] || continue
        f=${src##*/}
        case "$f" in *.lock|*.bak|*.tmp|last-version|usage.jsonl) continue ;; esac
        dst="$DATA_DIR/magpie/$f"
        [ ! -f "$dst" ] || [ "$src" -nt "$dst" ] || continue
        # 先复制再校验、最后原子替换：源文件随时可能被临时容器写入，直接 cp 会拷到半截
        cp -a "$src" "$stage" 2>/dev/null || { rm -f "$stage"; say "跳过合并 $f：复制失败"; continue; }
        case "$f" in
            *.json)
                if ! jq empty "$stage" >/dev/null 2>&1; then
                    rm -f "$stage"; say "跳过合并 $f：不是合法 JSON"; continue
                fi
                if [ "$f" = "providers.json" ] && ! jq -e '.providers | length > 0' "$stage" >/dev/null 2>&1; then
                    rm -f "$stage"; say "跳过合并 providers.json：副本无任何供应商，疑似损坏"; continue
                fi
                ;;
        esac
        mv -f "$stage" "$dst" 2>/dev/null || { rm -f "$stage"; say "合并 $f 失败"; }
    done
    rm -f "$stage"
    trap - RETURN
}

# ============================== 中断恢复 ==============================
recover() {
    [ -f "$STATE" ] || return 0
    say "检测到上次未完成的升级（state=$(cat "$STATE" 2>/dev/null)），开始恢复"

    if [ "$(state_of "$CONTAINER")" != "healthy" ] || ! probe "$LIVE_PORT"; then
        # 同一镜像重建失败要退避，但不能永久放弃：上游出新镜像必须能继续
        local cur try_img="" try_ts=0 try_cnt=0 try_ok=1 new_cnt
        cur=$(img_id "$IMAGE")
        if [ -f "$TRY_FILE" ]; then
            read -r try_img try_ts try_cnt <"$TRY_FILE" 2>/dev/null || true
            if [ "${try_img:-}" = "$cur" ]; then
                { [ $(( $(date +%s) - ${try_ts:-0} )) -lt 1800 ] || [ "${try_cnt:-0}" -ge 12 ]; } && try_ok=0
            fi
        fi
        if [ "$try_ok" = "0" ]; then
            say "镜像 $(short "$cur") 重建退避中（失败 ${try_cnt:-0} 次），流量继续由临时容器承载"
        else
            container_recreate
            if wait_ready "$CONTAINER" "$LIVE_PORT" 180; then
                rm -f "$TRY_FILE" "$FAIL_FILE"
            else
                new_cnt=1
                [ "${try_img:-}" = "$cur" ] && new_cnt=$(( ${try_cnt:-0} + 1 ))
                [ -n "$cur" ] && { echo "$cur $(date +%s) $new_cnt" >"$TRY_FILE"; echo "$cur" >"$FAIL_FILE"; }
                # 配置还原前校验：备份里若无供应商，宁可不还原
                if [ -f "$CFG_BAK/providers.json" ] && jq -e '.providers | length > 0' "$CFG_BAK/providers.json" >/dev/null 2>&1; then
                    cp -a "$CFG_BAK"/* "$DATA_DIR/magpie/" 2>/dev/null || true
                else
                    say "配置备份缺失或不可信，跳过还原"
                fi
            fi
        fi
    fi

    if [ "$(state_of "$CONTAINER")" = "healthy" ] && probe "$LIVE_PORT" && probe_v1 "$LIVE_PORT"; then
        local switched=0
        [ -n "$VHOST" ] && grep -q "proxy_pass http://${BIND_IP}:${TEMP_PORT};" "$VHOST" 2>/dev/null && switched=1
        # 已切回但第二次退场窗口被中断：副本确实服务过流量，也要并回；30 分钟时效挡陈旧副本
        if [ "$switched" = "0" ] && [ "$(cat "$STATE" 2>/dev/null)" = "done" ] \
            && [ "$(state_of "$TEMP_NAME")" = "healthy" ] && [ -n "$(find "$STATE" -mmin -30 2>/dev/null)" ]; then
            switched=1
        fi
        if [ -n "$VHOST" ]; then
            set_vhost "$LIVE_PORT" || { say "恢复时反代改写失败，保留临时容器与状态，下次重试"; return 1; }
            reload_nginx || { say "恢复时 nginx reload 失败，保留临时容器待下次重试"; return 1; }
        fi
        if [ "$switched" = "1" ]; then drain_wait "$TEMP_NAME" "恢复时临时容器退役前"; fi
        if [ "$switched" = "1" ]; then cleanup_temp merge; else cleanup_temp; fi
        rm -f "$STATE" "$VHOST_BAK" "$FAIL_FILE" "$TRY_FILE"
        rm -rf "$CFG_BAK"
        say "已恢复到正式容器"
        return 0
    fi

    if [ "$(state_of "$TEMP_NAME")" = "healthy" ] && probe "$TEMP_PORT" && probe_v1 "$TEMP_PORT"; then
        [ -n "$VHOST" ] && { set_vhost "$TEMP_PORT"; reload_nginx || true; }
        say "正式容器仍不可用，流量保持由临时容器承载"
        return 1
    fi

    [ -n "$VHOST" ] && { set_vhost "$LIVE_PORT" || true; reload_nginx || true; }
    rm -f "$STATE"
    say "正式容器与临时容器均不可用，需人工介入"
    return 1
}

# ============================== 状态快照（只读） ==============================
do_status() {
    local img_cur img_run ver
    img_cur=$(img_id "$IMAGE")
    img_run=$(docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null)
    ver=$(version_of "$CONTAINER")
    printf '%-16s %s\n' mode "$MODE"
    printf '%-16s %s\n' config "$CONFIG_FILE"
    printf '%-16s %s\n' container "$CONTAINER"
    printf '%-16s %s\n' image "$IMAGE"
    printf '%-16s %s\n' image_local "$(short "$img_cur")"
    printf '%-16s %s\n' image_running "$(short "$img_run")"
    printf '%-16s %s\n' version "${ver:-unknown}"
    printf '%-16s %s\n' health "$(state_of "$CONTAINER")"
    printf '%-16s %s\n' bind "${BIND_IP}:${LIVE_PORT}"
    printf '%-16s %s\n' temp_port "$TEMP_PORT"
    printf '%-16s %s\n' data_dir "$DATA_DIR"
    printf '%-16s %s\n' runtime "${RUNTIME_DIR:-<none>}"
    if [ -n "$VHOST" ]; then
        printf '%-16s %s\n' vhost "$(grep -o 'proxy_pass http://[^;]*' "$VHOST" 2>/dev/null | head -1)"
    else
        printf '%-16s %s\n' vhost "<direct 模式>"
    fi
    printf '%-16s %s\n' pending "$([ -f "$STATE" ] && cat "$STATE" || echo no)"
    printf '%-16s %s\n' failed "$([ -f "$FAIL_FILE" ] && short "$(cat "$FAIL_FILE")" || echo no)"
    if [ -n "$img_cur" ] && [ "$img_cur" != "$img_run" ]; then
        printf '%-16s %s\n' upgrade_ready "yes（有新版本，未部署）"
    else
        printf '%-16s %s\n' upgrade_ready "no（已是最新）"
    fi
}

# ============================== 升级主流程 ==============================
do_upgrade() {
    exec 9>"$LOCK_FILE"
    flock -w 60 9 || { say "等待锁超时（前一轮仍在升级），本轮退出"; exit 0; }
    # 两次退役各最长 DRAIN 秒，整轮最长约 2×DRAIN；期间 cron 触发的下一轮
    # flock -w 60 拿不到锁会写日志退出，不会叠加实例。
    trap 'say "收到中断信号，状态已保留，下次运行自动恢复"; exit 1' INT TERM

    GW_KEYS=$(load_gateway_keys || true)
    [ -n "$GW_KEYS" ] || say "未取到网关密钥，业务路径探测将跳过（只剩进程存活探测）"

    # 先把本地镜像标签刷到最新：recover 判断「同一镜像是否已失败」依赖它。
    # 若 pull 放在 recover 之后，上游修好版本后本地标签仍是旧的，恢复流程会
    # 一直认为镜像没变而永久卡死。
    local pulled=1
    if [ "$SKIP_PULL" = "1" ]; then
        say "SKIP_PULL=1，跳过拉取，使用本地镜像 $(short "$(img_id "$IMAGE")")"
    else
        timeout 600 docker pull "$IMAGE" >/dev/null 2>&1 || pulled=0
    fi

    recover || exit 1
    [ "$pulled" = "1" ] || die "拉取镜像失败"

    local old_id old_ver new_id
    old_id=$(docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null)
    old_ver=$(version_of "$CONTAINER")
    new_id=$(img_id "$IMAGE")
    [ -n "$new_id" ] || die "镜像信息异常：$IMAGE"

    if [ "$old_id" = "$new_id" ] && [ "$(state_of "$CONTAINER")" = "healthy" ] && [ "$FORCE" != "1" ]; then
        say "已是最新（$(short "$new_id")，${old_ver:-unknown}），无需升级"
        return 0
    fi

    # 同一坏镜像不重复尝试：否则每轮白备几百 MB；上游出新镜像自动解除
    if [ -f "$FAIL_FILE" ] && [ "$(cat "$FAIL_FILE" 2>/dev/null)" = "$new_id" ] && [ "$FORCE" != "1" ]; then
        say "镜像 $(short "$new_id") 此前失败，跳过（等上游新镜像或 FORCE=1）"
        return 0
    fi

    if [ "$SKIP_DISK_CHECK" != "1" ]; then
        local avail
        avail=$(df -Pm "$TMP_ROOT" | awk 'NR==2{print $4}')
        [ "${avail:-0}" -gt 2048 ] || die "磁盘余量不足（${avail}MB），放弃升级"
    fi

    if [ -n "$RUNTIME_DIR" ]; then
        local r
        for r in node/bin/npx node/bin/node uv/uvx git/bin/git pw/chrome/chrome; do
            [ -e "$RUNTIME_DIR/$r" ] || die "运行时缺失：$RUNTIME_DIR/$r（见 README）"
        done
    fi

    echo "start" >"$STATE"

    # 配置备份：只备核心 JSON/YAML（约百 KB），不备对话记录与图标
    rm -rf "$CFG_BAK"
    mkdir -p "$CFG_BAK" || die "创建配置备份目录失败"
    cp -a "$DATA_DIR/magpie"/*.json "$DATA_DIR/magpie"/*.yml "$CFG_BAK/" 2>/dev/null || true

    cleanup_temp
    mkdir -p "$TMP_DIR" || die "创建临时目录失败"
    rsync -a \
        --exclude 'cache/' --exclude 'magpie/usage.jsonl' --exclude 'magpie/routing/' \
        --exclude 'magpie/gateway-conversations/' --exclude 'magpie/gemini-signatures/' \
        --exclude 'magpie/masking/' --exclude 'magpie/mcp-npm/' \
        "$DATA_DIR/" "$TMP_DIR/" \
        || { cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"; die "复制配置失败"; }
    chmod 777 "$TMP_DIR" 2>/dev/null

    # 临时容器的环境变量直接从线上容器继承（比维护一份 MAGPIE_* 白名单更准）
    umask 077
    if ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" 2>/dev/null >"$TMP_ENV"; then
        umask 022
        cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
        die "生成临时环境变量失败"
    fi
    if [ -n "$TZ_VALUE" ]; then echo "TZ=$TZ_VALUE" >>"$TMP_ENV"; fi
    umask 022

    # 共享挂载点必须存在且属主正确，否则非 root 进程跨天创建日志/会话时 Permission denied
    local owner d
    owner=$(stat -c '%u:%g' "$DATA_DIR/magpie" 2>/dev/null || echo "65532:65532")
    for d in magpie/routing magpie/gateway-conversations magpie/gemini-signatures magpie/masking magpie/mcp-npm; do
        if [ ! -d "$DATA_DIR/$d" ]; then
            install -d -o "${owner%%:*}" -g "${owner##*:}" -m 755 "$DATA_DIR/$d"
        else
            chown -R "$owner" "$DATA_DIR/$d" 2>/dev/null
            chmod 755 "$DATA_DIR/$d" 2>/dev/null
        fi
    done
    if [ ! -f "$DATA_DIR/magpie/usage.jsonl" ]; then
        install -o "${owner%%:*}" -g "${owner##*:}" -m 600 /dev/null "$DATA_DIR/magpie/usage.jsonl"
    else
        chown "$owner" "$DATA_DIR/magpie/usage.jsonl" 2>/dev/null
        chmod 600 "$DATA_DIR/magpie/usage.jsonl" 2>/dev/null
    fi

    capture_spec
    if ! container_run_temp "$TEMP_NAME" "$new_id" "$TEMP_PORT"; then
        echo "$new_id" >"$FAIL_FILE"
        cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
        die "临时容器启动失败，已放弃升级（线上未受影响）"
    fi
    if ! wait_ready "$TEMP_NAME" "$TEMP_PORT" 120; then
        echo "$new_id" >"$FAIL_FILE"
        cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
        die "新版本健康检查失败，已放弃升级（线上未受影响）"
    fi
    local new_ver
    new_ver=$(version_of "$TEMP_NAME")

    # ---- direct 模式：无反代 ----
    if [ -z "$VHOST" ]; then
        say "新版本 ${new_ver:-unknown}（$(short "$new_id")）已验证通过，原位重建（direct 模式）"
        if ! container_recreate; then
            echo "$new_id" >"$FAIL_FILE"
            cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
            die "正式容器重建失败，线上仍由旧版本服务（下次运行重试）"
        fi
        merge_back
        if ! wait_ready "$CONTAINER" "$LIVE_PORT" 180; then
            echo "$new_id" >"$FAIL_FILE"
            say "新版本未通过健康检查，回滚到 $(short "$old_id")"
            container_recreate "$old_id" >/dev/null 2>&1
            wait_ready "$CONTAINER" "$LIVE_PORT" 180 && {
                cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
                die "新版本不可用，已回滚到 ${old_ver:-unknown}，等上游新镜像"
            }
            cleanup_temp; rm -f "$STATE"
            die "新版本不可用且回滚失败，需人工介入"
        fi
        echo "done" >"$STATE"
        drain_wait "$TEMP_NAME" "临时容器退役前"
        cleanup_temp merge
        rm -f "$STATE" "$FAIL_FILE" "$TRY_FILE"; rm -rf "$CFG_BAK"
        [ -n "$old_id" ] && [ "$old_id" != "$new_id" ] && docker image rm "$old_id" >/dev/null 2>&1
        say "${old_ver:-unknown}（$(short "$old_id")）> ${new_ver:-unknown}（$(short "$new_id")）升级成功（direct）"
        return 0
    fi

    # ---- proxy 模式：真正的零停机 ----
    cp -a "$VHOST" "$VHOST_BAK" || { cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"; die "备份反代配置失败"; }
    if ! set_vhost "$TEMP_PORT"; then
        cp -a "$VHOST_BAK" "$VHOST"
        cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
        die "反代改写未生效（proxy_pass 格式不匹配），已放弃升级"
    fi
    if ! reload_nginx || ! probe_vhost; then
        cp -a "$VHOST_BAK" "$VHOST"; reload_nginx || true
        cleanup_temp; rm -f "$STATE"; rm -rf "$CFG_BAK"
        die "反代切换失败，已回滚（线上未受影响）"
    fi
    say "新版本 ${new_ver:-unknown}（$(short "$new_id")）已接管流量，进入退役等待（最长 ${DRAIN}s）"

    drain_wait "$CONTAINER" "正式容器退役前"

    if ! container_recreate; then
        echo "$new_id" >"$FAIL_FILE"
        say "正式容器重建失败，流量继续由临时容器承载，下次运行自动修复"
        return 1
    fi

    # 合并点：重建之后、就绪之前。此刻旧进程已停止（不会出现旧版本读到新版本
    # 迁移过的配置），新容器仍在启动，来得及拿到临时容器刷新过的 token。
    merge_back

    if ! wait_ready "$CONTAINER" "$LIVE_PORT" 180; then
        echo "$new_id" >"$FAIL_FILE"
        say "正式容器未通过健康检查，流量继续由临时容器承载，下次运行自动修复"
        return 1
    fi

    if ! set_vhost "$LIVE_PORT" || ! reload_nginx || ! probe_vhost; then
        # 此刻唯一已验证可用的是临时容器，所以兜底切回它，而不是恢复原始备份
        # （备份指向的正式容器正是刚失败的那个）
        if set_vhost "$TEMP_PORT" && reload_nginx && probe_vhost; then
            say "切回正式容器失败，流量已退回临时容器（${new_ver:-unknown}），下次运行自动重试"
        else
            cp -a "$VHOST_BAK" "$VHOST" 2>/dev/null; reload_nginx || true
            say "切回正式容器失败且临时容器也不可达，已恢复反代原文，需人工介入"
        fi
        return 1
    fi

    echo "done" >"$STATE"
    drain_wait "$TEMP_NAME" "临时容器退役前"
    cleanup_temp merge
    rm -f "$STATE" "$VHOST_BAK" "$FAIL_FILE" "$TRY_FILE"
    rm -rf "$CFG_BAK"
    [ -n "$old_id" ] && [ "$old_id" != "$new_id" ] && docker image rm "$old_id" >/dev/null 2>&1
    say "${old_ver:-unknown}（$(short "$old_id")）> ${new_ver:-unknown}（$(short "$new_id")）蓝绿升级成功"
    return 0
}

# ============================== 日志 ==============================
do_logs() {
    local n="${1:-40}"
    [ -f "$LOG_FILE" ] || { echo "暂无日志：$LOG_FILE"; return 1; }
    tail -n "$n" "$LOG_FILE"
}

# ============================== 保留清理 ==============================
do_retention() {
    local days="${1:-$KEEP_DAYS}"
    local conv="$DATA_DIR/magpie/gateway-conversations"
    [ -d "$conv" ] || { say "无对话目录：$conv"; return 0; }
    local before after removed=0 old sz
    before=$(du -sm "$conv" 2>/dev/null | cut -f1)
    while IFS= read -r old; do
        [ -n "$old" ] || continue
        sz=$(du -sm "$old" 2>/dev/null | cut -f1)
        rm -rf "$old" && removed=$((removed + 1))
        log "删除过期对话 $(basename "$old")（${sz}MB）"
    done < <(find "$conv" -mindepth 1 -maxdepth 1 -type d -mtime +"$days" 2>/dev/null)
    after=$(du -sm "$conv" 2>/dev/null | cut -f1)
    say "保留 ${days} 天，删除 ${removed} 个，体积 ${before:-0}MB -> ${after:-0}MB"
}

# ============================== 导出样例 ==============================
do_export() { # $1=目标目录
    local out="${1:-./magpie-examples}"
    mkdir -p "$out" || return 1
    cat >"$out/docker-compose.yml" <<'COMPOSE'
name: magpie

services:
  magpie:
    image: ghcr.io/yetone/magpie:latest
    container_name: magpie
    restart: always
    command: ["web", "--addr", "0.0.0.0:3430", "--no-open"]
    ports:
      - "127.0.0.1:3430:3430"
      - "127.0.0.1:3425:3425"
    volumes:
      - ./data:/config
    environment:
      MAGPIE_ADDR: 0.0.0.0:3425
      MAGPIE_PUBLIC_URL: ${MAGPIE_PUBLIC_URL:-}
      MAGPIE_WEB_KEY: ${MAGPIE_WEB_KEY:-}
      TZ: ${TZ:-Asia/Shanghai}
      HOME: /config/home
      XDG_CONFIG_HOME: /config
      XDG_CACHE_HOME: /config/cache
      XDG_DATA_HOME: /config/data
      XDG_STATE_HOME: /config/state
    healthcheck:
      test: ["CMD", "/magpie", "healthcheck"]
      interval: 30s
      timeout: 5s
      start_period: 10s
      retries: 3
COMPOSE
    cat >"$out/env.example" <<'ENVEX'
# 控制台密钥（至少 16 字符）：openssl rand -hex 16
MAGPIE_WEB_KEY=
MAGPIE_PUBLIC_URL=https://gw.example.com
TZ=Asia/Shanghai
ENVEX
    cat >"$out/nginx.conf" <<'NGINX'
# magpie 反代（Cloudflare 橙云场景）
# 要点：1) 只代理 3430（控制台 / 与网关 /v1 同端口）
#      2) proxy_buffering off（不关的话 SSE 会卡住不动）
#      3) 反代指向宿主机上的容器发布地址；容器内反代请写 docker 网桥网关 IP
server {
    listen 80;
    server_name gw.example.com;
    client_max_body_size 32m;

    location / {
        proxy_pass http://127.0.0.1:3430;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $http_x_forwarded_proto;

        proxy_buffering off;
        proxy_cache     off;
        gzip            off;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        send_timeout       3600s;
    }
}
NGINX
    cat >"$out/client-omp.yml" <<'OMP'
# 合并进 ~/.omp/agent/models.yml 的 providers 段
providers:
  magpie:
    api: openai-completions
    apiKey: <MAGPIE_GATEWAY_KEY>
    baseUrl: https://gw.example.com/v1
    models:
    - id: group/coding
      name: Coding (auto)
OMP
    cat >"$out/client-opencode.json" <<'OC'
{
  "provider": {
    "magpie": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "https://gw.example.com/v1", "apiKey": "<MAGPIE_GATEWAY_KEY>" },
      "models": { "group/coding": { "name": "Coding (auto)" } }
    }
  }
}
OC
    say "样例已导出到 $out（nginx.conf / client-omp.yml / client-opencode.json）"
}

# ============================== 菜单 ==============================
menu() {
    local choice
    while :; do
        cat <<EOF

  magpie.sh v$VERSION  ·  mode=$MODE  container=$CONTAINER
  ─────────────────────────────────────────────────────────
   1) 状态            当前版本 / 是否有待部署更新
   2) 检查并升级      一次完整蓝绿流程（无新版则秒退）
   3) 强制演练        FORCE=1，镜像未变也走一遍
   4) 查看日志        最近 40 行
   5) 清理对话        保留 $KEEP_DAYS 天
   6) 导出样例        nginx / 客户端接入片段
   7) 编辑配置        $CONFIG_FILE
   8) 安装定时任务    每 10 分钟升级 + 每天 04:35 清理
   9) 卸载定时任务
   0) 退出
EOF
        printf '请选择 [0-9]: '
        read -r choice || exit 0
        case "$choice" in
            1) do_status ;;
            2) do_upgrade ;;
            3) FORCE=1 do_upgrade ;;
            4) do_logs 40 ;;
            5) do_retention "$KEEP_DAYS" ;;
            6) printf '导出目录 [./magpie-examples]: '; read -r d; do_export "${d:-./magpie-examples}" ;;
            7) ${EDITOR:-vi} "$CONFIG_FILE" ;;
            8) install_cron ;;
            9) uninstall_cron ;;
            0) exit 0 ;;
            *) printf '无效选项\n' ;;
        esac
    done
}

CRON_MARK="magpie.sh"
install_cron() {
    command -v crontab >/dev/null 2>&1 || die "系统无 crontab"
    local tmp
    tmp=$(mktemp) || die "创建临时文件失败"
    crontab -l 2>/dev/null | grep -v "$CRON_MARK" >"$tmp" || true
    {
        echo "# magpie.sh: 自动升级（flock 幂等，重复触发安全）"
        echo "*/10 * * * * MAGPIE_CONFIG=$CONFIG_FILE $(readlink -f "$0") --upgrade >>$LOG_FILE 2>&1"
        echo "# magpie.sh: 对话保留 $KEEP_DAYS 天"
        echo "35 4 * * * MAGPIE_CONFIG=$CONFIG_FILE $(readlink -f "$0") --retention >>$LOG_FILE 2>&1"
    } >>"$tmp"
    crontab "$tmp" && say "已写入 crontab（每 10 分钟升级 / 每天 04:35 清理）"
    rm -f "$tmp"
}

uninstall_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    local tmp
    tmp=$(mktemp) || return 1
    crontab -l 2>/dev/null | grep -v "$CRON_MARK" >"$tmp" || true
    crontab "$tmp" && say "已移除 magpie.sh 的定时任务"
    rm -f "$tmp"
}

# ============================== 入口 ==============================
main() {
    load_config
    init_state

    CONTAINER=$(detect_container 2>/dev/null) || CONTAINER=""
    resolve_mode
    if [ -z "$CONTAINER" ]; then
        early "找不到运行中的 magpie 容器。用 CONTAINER=xxx 显式指定，或先手动起一个容器。"
        exit 1
    fi
    resolve_data_dir || true
    detect_port_map
    need_env

    case "${1:-}" in
        --status)    do_status ;;
        --upgrade)   do_upgrade ;;
        --retention) do_retention "${2:-$KEEP_DAYS}" ;;
        --logs)      do_logs "${2:-40}" ;;
        --export)    do_export "${2:-./magpie-examples}" ;;
        --check)     do_status ;;   # 别名：--status 本身就是只读快照
        "")          if [ -t 0 ]; then menu; else menu_usage; fi ;;
        -h|--help)   menu_usage ;;
        *)           early "未知参数：$1（--help 查看用法）"; exit 2 ;;
    esac
}

menu_usage() {
    cat <<EOF
magpie.sh v$VERSION — magpie 蓝绿升级 / 运维

用法：
  magpie.sh                交互菜单（无 TTY 时打印本帮助）
  magpie.sh --status       状态快照
  magpie.sh --upgrade      检查并升级（无新版秒退）
  magpie.sh --retention N  清理 N 天前的对话
  magpie.sh --logs [N]     最近 N 行日志
  magpie.sh --export [DIR] 导出 nginx / 客户端样例

环境变量：
  IMAGE DATA_DIR CONTAINER SERVICE VHOST PUBLIC_HOST BIND_IP LIVE_PORT TEMP_PORT
  DRAIN RUNTIME_DIR KEEP_DAYS MODE=compose|docker GATEWAY_KEY SKIP_PULL=1 FORCE=1
  MAGPIE_CONFIG（默认 $CONFIG_FILE）
EOF
}

main "$@"