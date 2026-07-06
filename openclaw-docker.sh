#!/bin/bash
# ============================================================================
#  OpenClaw Docker 管理脚本 (openclaw-docker.sh)
#  - 选项1: Docker 环境管理 (安装/管理/卸载)，搬运自 kejilion.sh
#  - 选项2: OpenClaw 镜像构建向导 (本地 dockerfile / 外链 / 官方镜像)
#  - 选项3: OpenClaw 安装向导 (生成 docker-compose.yml + .env + 持久化卷)
#  - 选项4: OpenClaw 容器管理 (全量搬运 kejilion.sh moltbot_menu，适配 docker)
# ============================================================================

sh_v="1.0.0"

# ---------- 颜色 ----------
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

# ---------- 全局配置 ----------
OC_HOME="${OC_HOME:-/home/docker/openclaw}"
OC_CONFIG_DIR="${OC_CONFIG_DIR:-$OC_HOME/config}"
OC_WORKSPACE_DIR="${OC_WORKSPACE_DIR:-$OC_HOME/workspace}"
OC_AUTH_DIR="${OC_AUTH_DIR:-$OC_HOME/auth}"
OC_DATA_DIR="${OC_DATA_DIR:-$OC_HOME/data}"
OC_BACKUP_DIR="${OC_BACKUP_DIR:-$OC_HOME/backup}"
COMPOSE_FILE="$OC_HOME/docker-compose.yml"
ENV_FILE="$OC_HOME/.env"
OC_CONTAINER="openclaw-gateway"
OC_CLI_CONTAINER="openclaw-cli"
OC_IMAGE_NAME="${OC_IMAGE_NAME:-openclaw:local}"
OC_DOCKERFILE_URL="${OC_DOCKERFILE_URL:-}"          # 外链 dockerfile，留空则用本地
OC_LOCAL_DOCKERFILE="${OC_LOCAL_DOCKERFILE:-}"      # 本地 dockerfile 路径，留空则向导时询问
OC_GATEWAY_PORT="${OC_GATEWAY_PORT:-18789}"
OC_GATEWAY_BIND="${OC_GATEWAY_BIND:-lan}"           # lan | loopback
OC_HOME_VOLUME="${OC_HOME_VOLUME:-}"                # 留空=bind mount，填卷名=命名卷

ENABLE_STATS="${ENABLE_STATS:-true}"
GH_PROXY="${GH_PROXY:-https://gh.kejilion.pro/}"

# ============================================================================
#  辅助函数
# ============================================================================

# 跨发行版包安装
install() {
    for package in "$@"; do
        if ! command -v "$package" >/dev/null 2>&1; then
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "$package"
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "$package"
            elif command -v apt >/dev/null 2>&1; then
                apt update -y >/dev/null 2>&1
                apt install -y "$package"
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache "$package"
            elif command -v pacman >/dev/null 2>&1; then
                pacman -S --noconfirm "$package"
            elif command -v zypper >/dev/null 2>&1; then
                zypper install -y "$package"
            elif command -v opkg >/dev/null 2>&1; then
                opkg update
                opkg install "$package"
            elif command -v pkg >/dev/null 2>&1; then
                pkg install -y "$package"
            else
                echo "无法确定包管理器，请手动安装: $package"
            fi
        fi
    done
}

# 跨发行版卸载包
remove() {
    for package in "$@"; do
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y "$package"
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y "$package"
        elif command -v apt >/dev/null 2>&1; then
            apt remove -y "$package"
        elif command -v apk >/dev/null 2>&1; then
            apk del "$package"
        elif command -v pacman >/dev/null 2>&1; then
            pacman -R --noconfirm "$package"
        elif command -v zypper >/dev/null 2>&1; then
            zypper remove -y "$package"
        fi
    done
}

# root 权限守卫
root_use() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_huang}该功能需要 root 用户才能运行！${gl_bai}"
        break_end
        main_menu
    fi
}

# 操作完成暂停
break_end() {
    echo -e "${gl_lv}操作完成${gl_bai}"
    echo "按任意键继续..."
    read -n 1 -s -r -p ""
    echo ""
    clear
}

# 命令存在检测
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 统计上报 (可选，默认关闭以保护隐私)
send_stats() {
    if [ "$ENABLE_STATS" == "false" ]; then
        return
    fi
    local action="$1"
    (
        curl -s -X POST "https://api.kejilion.pro/api/log" \
            -H "Content-Type: application/json" \
            -d "{\"action\":\"$action\",\"timestamp\":\"$(date -u '+%Y-%m-%d %H:%M:%S')\",\"version\":\"$sh_v\"}" \
            &>/dev/null
    ) &
}

# 获取 IP 地址
ip_address() {
    public_ip=$(curl -s --max-time 5 https://ipinfo.io/ip 2>/dev/null)
    local_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [ -z "$local_ip" ] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    isp_info=$(curl -s --max-time 5 http://ipinfo.io/org 2>/dev/null)

    if echo "$isp_info" | grep -qiE "CHINANET|mobile|unicom|telecom|china"; then
        ipv4_address="$local_ip"
    else
        ipv4_address="$public_ip"
    fi
    ipv6_address=$(curl -s --max-time 3 https://v6.ipinfo.io/ip 2>/dev/null)
}

# ============================================================================
#  OpenClaw Docker 专用辅助函数
# ============================================================================

# 确保 OC_HOME 目录结构存在
ensure_oc_dirs() {
    mkdir -p "$OC_HOME" "$OC_CONFIG_DIR" "$OC_CONFIG_DIR/workspace" \
             "$OC_AUTH_DIR" "$OC_DATA_DIR" "$OC_BACKUP_DIR"
    # 官方镜像以 uid 1000 (node) 运行，需修正宿主目录属主
    if command_exists docker; then
        docker run --rm -v "$OC_CONFIG_DIR:/home/node/.openclaw" \
            -v "$OC_AUTH_DIR:/home/node/.config/openclaw" \
            -v "$OC_DATA_DIR:/home/node/.openclaw/data" \
            --entrypoint chown node:1000 -R 1000:1000 \
            /home/node/.openclaw /home/node/.config/openclaw 2>/dev/null || \
            chown -R 1000:1000 "$OC_CONFIG_DIR" "$OC_AUTH_DIR" "$OC_DATA_DIR" 2>/dev/null
    fi
}

# 在容器内执行 openclaw 命令 (非交互)
oc_exec() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}未找到 docker-compose.yml，请先运行选项3 安装向导${gl_bai}"
        return 1
    fi
    cd "$OC_HOME" || return 1
    docker compose -f "$COMPOSE_FILE" exec -T "$OC_CLI_CONTAINER" openclaw "$@"
}

# 在容器内执行 openclaw 命令 (交互式，带 TTY)
oc_exec_it() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}未找到 docker-compose.yml，请先运行选项3 安装向导${gl_bai}"
        return 1
    fi
    cd "$OC_HOME" || return 1
    docker compose -f "$COMPOSE_FILE" exec "$OC_CLI_CONTAINER" openclaw "$@"
}

# 在容器内执行任意命令 (非交互)
oc_run() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}未找到 docker-compose.yml，请先运行选项3 安装向导${gl_bai}"
        return 1
    fi
    cd "$OC_HOME" || return 1
    docker compose -f "$COMPOSE_FILE" run --rm -T "$OC_CLI_CONTAINER" "$@"
}

# 获取 openclaw 配置文件路径 (宿主机路径)
openclaw_get_config_file() {
    local user_config="$OC_CONFIG_DIR/openclaw.json"
    if [ -f "$user_config" ]; then
        echo "$user_config"
    else
        echo "$user_config"
    fi
}

# 检测容器是否运行
oc_container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${OC_CONTAINER}$"
}

# 检测 compose 服务是否已定义
oc_compose_defined() {
    [ -f "$COMPOSE_FILE" ] || return 1
    cd "$OC_HOME" || return 1
    docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null | grep -q "^${OC_CLI_CONTAINER}$"
}

# 启动网关
start_gateway() {
    cd "$OC_HOME" || return 1
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}未找到 docker-compose.yml${gl_bai}"
        return 1
    fi
    docker compose -f "$COMPOSE_FILE" up -d openclaw-gateway
    sleep 3
}

# ============================================================================
#  选项 1: Docker 环境管理  (搬运自 kejilion.sh)
# ============================================================================

install_add_docker() {
    if command_exists docker; then
        echo -e "${gl_lv}Docker 已安装${gl_bai}"
        docker -v
        return 0
    fi

    echo -e "${gl_kjlan}正在安装 Docker 环境...${gl_bai}"

    # 优先使用 linuxmirrors 一键脚本
    if curl -sSL https://linuxmirrors.cn/docker.sh -o /tmp/linuxmirrors-docker.sh 2>/dev/null; then
        bash /tmp/linuxmirrors-docker.sh
        rm -f /tmp/linuxmirrors-docker.sh
    else
        # 降级：直接安装
        install docker docker-compose
    fi

    if command_exists docker; then
        systemctl enable docker 2>/dev/null
        systemctl start docker 2>/dev/null
        echo -e "${gl_lv}Docker 安装完成${gl_bai}"
        docker -v
    else
        echo -e "${gl_hong}Docker 安装失败，请手动安装${gl_bai}"
    fi
}

install_docker() {
    if ! command_exists docker; then
        install_add_docker
    fi
}

# Docker 状态摘要
docker_tato() {
    if ! command_exists docker; then
        echo -e "${gl_hui}Docker 未安装${gl_bai}"
        return
    fi
    local container_count image_count network_count volume_count
    container_count=$(docker ps -a -q 2>/dev/null | wc -l | tr -d ' ')
    image_count=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
    network_count=$(docker network ls -q 2>/dev/null | wc -l | tr -d ' ')
    volume_count=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
    echo -e "容器: ${gl_lv}${container_count}${gl_bai}  镜像: ${gl_lv}${image_count}${gl_bai}  网络: ${gl_lv}${network_count}${gl_bai}  卷: ${gl_lv}${volume_count}${gl_bai}"
}

# Docker 容器管理菜单
docker_ps() {
    while true; do
        clear
        send_stats "Docker容器管理"
        echo "Docker容器列表"
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
        echo ""
        echo "容器操作"
        echo "------------------------"
        echo "1. 创建新的容器"
        echo "------------------------"
        echo "2. 启动指定容器             6. 启动所有容器"
        echo "3. 停止指定容器             7. 停止所有容器"
        echo "4. 删除指定容器             8. 删除所有容器"
        echo "5. 重启指定容器             9. 重启所有容器"
        echo "------------------------"
        echo "11. 进入指定容器           12. 查看容器日志"
        echo "13. 查看容器网络           14. 查看容器占用"
        echo "------------------------"
        echo "0. 返回上一级选单"
        echo "------------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -e -p "请输入创建命令: " dockername
                $dockername
                ;;
            2)
                read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername
                docker start $dockername
                ;;
            3)
                read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername
                docker stop $dockername
                ;;
            4)
                read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername
                docker rm -f $dockername
                ;;
            5)
                read -e -p "请输入容器名（多个容器名请用空格分隔）: " dockername
                docker restart $dockername
                ;;
            6) docker start $(docker ps -a -q) ;;
            7) docker stop $(docker ps -q) ;;
            8)
                read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定删除所有容器吗？(Y/N): ")" choice
                case "$choice" in
                    [Yy]) docker rm -f $(docker ps -a -q) ;;
                esac
                ;;
            9) docker restart $(docker ps -q) ;;
            11)
                read -e -p "请输入容器名: " dockername
                docker exec -it $dockername /bin/sh
                break_end
                ;;
            12)
                read -e -p "请输入容器名: " dockername
                docker logs $dockername
                break_end
                ;;
            13)
                echo ""
                container_ids=$(docker ps -q)
                echo "------------------------------------------------------------"
                printf "%-25s %-25s %-25s\n" "容器名称" "网络名称" "IP地址"
                for container_id in $container_ids; do
                    local container_info=$(docker inspect --format '{{ .Name }}{{ range $network, $config := .NetworkSettings.Networks }} {{ $network }} {{ $config.IPAddress }}{{ end }}' "$container_id")
                    local container_name=$(echo "$container_info" | awk '{print $1}')
                    local network_info=$(echo "$container_info" | cut -d' ' -f2-)
                    while IFS= read -r line; do
                        local network_name=$(echo "$line" | awk '{print $1}')
                        local ip_addr=$(echo "$line" | awk '{print $2}')
                        printf "%-20s %-20s %-15s\n" "$container_name" "$network_name" "$ip_addr"
                    done <<< "$network_info"
                done
                break_end
                ;;
            14)
                docker stats --no-stream
                break_end
                ;;
            *) break ;;
        esac
    done
}

# Docker 镜像管理菜单
docker_image() {
    while true; do
        clear
        send_stats "Docker镜像管理"
        echo "Docker镜像列表"
        docker image ls
        echo ""
        echo "镜像操作"
        echo "------------------------"
        echo "1. 获取指定镜像             3. 删除指定镜像"
        echo "2. 更新指定镜像             4. 删除所有镜像"
        echo "------------------------"
        echo "0. 返回上一级选单"
        echo "------------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -e -p "请输入镜像名（多个镜像名请用空格分隔）: " imagenames
                for name in $imagenames; do
                    echo -e "${gl_kjlan}正在获取镜像: $name${gl_bai}"
                    docker pull $name
                done
                ;;
            2)
                read -e -p "请输入镜像名（多个镜像名请用空格分隔）: " imagenames
                for name in $imagenames; do
                    echo -e "${gl_kjlan}正在更新镜像: $name${gl_bai}"
                    docker pull $name
                done
                ;;
            3)
                read -e -p "请输入镜像名（多个镜像名请用空格分隔）: " imagenames
                for name in $imagenames; do
                    docker rmi -f $name
                done
                ;;
            4)
                read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定删除所有镜像吗？(Y/N): ")" choice
                case "$choice" in
                    [Yy]) docker rmi -f $(docker images -q) ;;
                esac
                ;;
            *) break ;;
        esac
    done
}

# 开启 Docker IPv6
docker_ipv6_on() {
    root_use
    install jq
    local CONFIG_FILE="/etc/docker/daemon.json"
    local REQUIRED_IPV6_CONFIG='{"ipv6": true, "fixed-cidr-v6": "2001:db8:1::/64"}'
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$REQUIRED_IPV6_CONFIG" | jq . > "$CONFIG_FILE"
        systemctl restart docker
    else
        local ORIGINAL_CONFIG=$(<"$CONFIG_FILE")
        local CURRENT_IPV6=$(echo "$ORIGINAL_CONFIG" | jq '.ipv6 // false')
        local UPDATED_CONFIG
        if [[ "$CURRENT_IPV6" == "false" ]]; then
            UPDATED_CONFIG=$(echo "$ORIGINAL_CONFIG" | jq '. + {ipv6: true, "fixed-cidr-v6": "2001:db8:1::/64"}')
        else
            UPDATED_CONFIG=$(echo "$ORIGINAL_CONFIG" | jq '. + {"fixed-cidr-v6": "2001:db8:1::/64"}')
        fi
        if [[ "$ORIGINAL_CONFIG" == "$UPDATED_CONFIG" ]]; then
            echo -e "${gl_huang}当前已开启ipv6访问${gl_bai}"
        else
            echo "$UPDATED_CONFIG" | jq . > "$CONFIG_FILE"
            systemctl restart docker
        fi
    fi
}

# 关闭 Docker IPv6
docker_ipv6_off() {
    root_use
    install jq
    local CONFIG_FILE="/etc/docker/daemon.json"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${gl_hong}配置文件不存在${gl_bai}"
        return
    fi
    local ORIGINAL_CONFIG=$(<"$CONFIG_FILE")
    local UPDATED_CONFIG=$(echo "$ORIGINAL_CONFIG" | jq 'del(.["fixed-cidr-v6"]) | .ipv6 = false')
    local CURRENT_IPV6=$(echo "$ORIGINAL_CONFIG" | jq -r '.ipv6 // false')
    if [[ "$CURRENT_IPV6" == "false" ]]; then
        echo -e "${gl_huang}当前已关闭ipv6访问${gl_bai}"
    else
        echo "$UPDATED_CONFIG" | jq . > "$CONFIG_FILE"
        systemctl restart docker
    fi
}

# Docker 备份/迁移/还原
docker_ssh_migration() {
    while true; do
        clear
        send_stats "Docker备份迁移"
        echo "======================================="
        echo "Docker 备份 / 迁移 / 还原"
        echo "======================================="
        echo "1. 备份 Docker 环境 (容器+卷+配置)"
        echo "2. 还原 Docker 环境"
        echo "3. 迁移到远程服务器 (SSH)"
        echo "4. 查看本地备份列表"
        echo "5. 删除备份文件"
        echo "0. 返回上一级选单"
        echo "---------------------------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1)
                read -e -p "请输入备份文件名 (留空=自动时间戳): " bak_name
                [ -z "$bak_name" ] && bak_name="docker-backup-$(date +%Y%m%d_%H%M%S)"
                local bak_dir="/home/docker/backup"
                mkdir -p "$bak_dir"
                echo -e "${gl_kjlan}正在备份...${gl_bai}"
                # 备份所有容器配置
                docker ps -a --format '{{.Names}}' > "$bak_dir/containers.list"
                # 打包 docker 数据目录
                tar -czf "$bak_dir/${bak_name}.tar.gz" \
                    -C /home/docker . 2>/dev/null \
                    --exclude="backup" || true
                # 生成还原脚本
                cat > "$bak_dir/${bak_name}_restore.sh" <<'RESTORE'
#!/bin/bash
echo "还原 Docker 环境..."
cd /home/docker
tar -xzf backup/__BAK_NAME__.tar.gz -C /home/docker/
echo "还原完成，请手动重启相关容器"
RESTORE
                sed -i "s/__BAK_NAME__/${bak_name}/g" "$bak_dir/${bak_name}_restore.sh"
                chmod +x "$bak_dir/${bak_name}_restore.sh"
                echo -e "${gl_lv}备份完成: $bak_dir/${bak_name}.tar.gz${gl_bai}"
                break_end
                ;;
            2)
                local bak_dir="/home/docker/backup"
                echo "可用备份:"
                ls -lh "$bak_dir"/*.tar.gz 2>/dev/null || echo "无备份文件"
                read -e -p "请输入备份文件名 (不含路径): " bak_file
                if [ -f "$bak_dir/$bak_file" ]; then
                    echo -e "${gl_kjlan}正在还原...${gl_bai}"
                    tar -xzf "$bak_dir/$bak_file" -C /home/docker/
                    echo -e "${gl_lv}还原完成${gl_bai}"
                else
                    echo -e "${gl_hong}文件不存在${gl_bai}"
                fi
                break_end
                ;;
            3)
                read -e -p "远程服务器 IP: " remote_ip
                read -e -p "SSH 端口 (默认22): " ssh_port
                [ -z "$ssh_port" ] && ssh_port=22
                read -e -p "远程用户 (默认root): " remote_user
                [ -z "$remote_user" ] && remote_user=root
                local bak_dir="/home/docker/backup"
                local bak_name="docker-migrate-$(date +%Y%m%d_%H%M%S)"
                echo -e "${gl_kjlan}正在打包...${gl_bai}"
                tar -czf "$bak_dir/${bak_name}.tar.gz" -C /home/docker . 2>/dev/null --exclude="backup" || true
                echo -e "${gl_kjlan}正在传输到远程服务器...${gl_bai}"
                scp -P "$ssh_port" "$bak_dir/${bak_name}.tar.gz" "${remote_user}@${remote_ip}:/tmp/"
                echo -e "${gl_kjlan}请在远程服务器执行:${gl_bai}"
                echo "  mkdir -p /home/docker && tar -xzf /tmp/${bak_name}.tar.gz -C /home/docker/"
                break_end
                ;;
            4)
                local bak_dir="/home/docker/backup"
                echo "备份列表:"
                ls -lh "$bak_dir"/*.tar.gz 2>/dev/null || echo "无备份文件"
                break_end
                ;;
            5)
                local bak_dir="/home/docker/backup"
                read -e -p "请输入要删除的备份文件名 (留空=全部): " del_file
                if [ -z "$del_file" ]; then
                    read -e -p "$(echo -e "${gl_hong}确定删除所有备份？(Y/N): ${gl_bai}")" choice
                    case "$choice" in
                        [Yy]) rm -f "$bak_dir"/*.tar.gz "$bak_dir"/*.sh ;;
                    esac
                else
                    rm -f "$bak_dir/$del_file"
                fi
                ;;
            *) break ;;
        esac
    done
}

# Docker 管理主菜单
linux_docker() {
    while true; do
        clear
        echo -e "Docker管理"
        docker_tato
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}1.   ${gl_bai}安装更新Docker环境 ${gl_huang}★${gl_bai}"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}2.   ${gl_bai}查看Docker全局状态 ${gl_huang}★${gl_bai}"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}3.   ${gl_bai}Docker容器管理 ${gl_huang}★${gl_bai}"
        echo -e "${gl_kjlan}4.   ${gl_bai}Docker镜像管理"
        echo -e "${gl_kjlan}5.   ${gl_bai}Docker网络管理"
        echo -e "${gl_kjlan}6.   ${gl_bai}Docker卷管理"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}7.   ${gl_bai}清理无用的docker容器和镜像网络数据卷"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}8.   ${gl_bai}更换Docker源"
        echo -e "${gl_kjlan}9.   ${gl_bai}编辑daemon.json文件"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}11.  ${gl_bai}开启Docker-ipv6访问"
        echo -e "${gl_kjlan}12.  ${gl_bai}关闭Docker-ipv6访问"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}19.  ${gl_bai}备份/迁移/还原Docker环境"
        echo -e "${gl_kjlan}20.  ${gl_bai}卸载Docker环境"
        echo -e "${gl_kjlan}------------------------"
        echo -e "${gl_kjlan}0.   ${gl_bai}返回主菜单"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) clear; install_add_docker ;;
            2)
                clear
                local container_count=$(docker ps -a -q 2>/dev/null | wc -l | tr -d ' ')
                local image_count=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
                local network_count=$(docker network ls -q 2>/dev/null | wc -l | tr -d ' ')
                local volume_count=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
                echo "Docker版本"
                docker -v 2>/dev/null
                docker compose version 2>/dev/null
                echo ""
                echo -e "Docker镜像: ${gl_lv}$image_count${gl_bai} "
                docker image ls 2>/dev/null
                echo ""
                echo -e "Docker容器: ${gl_lv}$container_count${gl_bai}"
                docker ps -a 2>/dev/null
                echo ""
                echo -e "Docker卷: ${gl_lv}$volume_count${gl_bai}"
                docker volume ls 2>/dev/null
                echo ""
                echo -e "Docker网络: ${gl_lv}$network_count${gl_bai}"
                docker network ls 2>/dev/null
                echo ""
                ;;
            3) docker_ps ;;
            4) docker_image ;;
            5)
                while true; do
                    clear
                    echo "Docker网络列表"
                    echo "------------------------------------------------------------"
                    docker network ls 2>/dev/null
                    echo ""
                    echo "网络操作"
                    echo "------------------------"
                    echo "1. 创建网络"
                    echo "2. 加入网络"
                    echo "3. 退出网络"
                    echo "4. 删除网络"
                    echo "------------------------"
                    echo "0. 返回上一级选单"
                    echo "------------------------"
                    read -e -p "请输入你的选择: " sub_choice
                    case $sub_choice in
                        1) read -e -p "设置新网络名: " dockernetwork; docker network create $dockernetwork ;;
                        2)
                            read -e -p "加入网络名: " dockernetwork
                            read -e -p "哪些容器加入该网络（空格分隔）: " dockernames
                            for dockername in $dockernames; do
                                docker network connect $dockernetwork $dockername
                            done
                            ;;
                        3)
                            read -e -p "退出网络名: " dockernetwork
                            read -e -p "哪些容器退出该网络（空格分隔）: " dockernames
                            for dockername in $dockernames; do
                                docker network disconnect $dockernetwork $dockername
                            done
                            ;;
                        4) read -e -p "请输入要删除的网络名: " dockernetwork; docker network rm $dockernetwork ;;
                        *) break ;;
                    esac
                done
                ;;
            6)
                while true; do
                    clear
                    echo "Docker卷列表"
                    docker volume ls 2>/dev/null
                    echo ""
                    echo "卷操作"
                    echo "------------------------"
                    echo "1. 创建新卷"
                    echo "2. 删除指定卷"
                    echo "3. 删除所有卷"
                    echo "------------------------"
                    echo "0. 返回上一级选单"
                    echo "------------------------"
                    read -e -p "请输入你的选择: " sub_choice
                    case $sub_choice in
                        1) read -e -p "设置新卷名: " dockerjuan; docker volume create $dockerjuan ;;
                        2)
                            read -e -p "输入删除卷名（空格分隔）: " dockerjuans
                            for dockerjuan in $dockerjuans; do
                                docker volume rm $dockerjuan
                            done
                            ;;
                        3)
                            read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定删除所有未使用的卷吗？(Y/N): ")" choice
                            case "$choice" in
                                [Yy]) docker volume prune -f ;;
                            esac
                            ;;
                        *) break ;;
                    esac
                done
                ;;
            7)
                clear
                read -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}将清理无用的镜像容器网络，确定清理吗？(Y/N): ")" choice
                case "$choice" in
                    [Yy]) docker system prune -af --volumes ;;
                esac
                ;;
            8)
                clear
                bash <(curl -sSL https://linuxmirrors.cn/docker.sh)
                ;;
            9)
                clear
                install nano
                mkdir -p /etc/docker && nano /etc/docker/daemon.json
                systemctl restart docker
                ;;
            11) clear; docker_ipv6_on ;;
            12) clear; docker_ipv6_off ;;
            19) docker_ssh_migration ;;
            20)
                clear
                read -e -p "$(echo -e "${gl_hong}注意: ${gl_bai}确定卸载docker环境吗？(Y/N): ")" choice
                case "$choice" in
                    [Yy])
                        docker ps -a -q | xargs -r docker rm -f 2>/dev/null
                        docker images -q | xargs -r docker rmi 2>/dev/null
                        docker network prune -f 2>/dev/null
                        docker volume prune -f 2>/dev/null
                        remove docker docker-compose docker-ce docker-ce-cli containerd.io
                        rm -f /etc/docker/daemon.json
                        hash -r
                        ;;
                esac
                ;;
            0) return 0 ;;
            *) echo "无效的输入!" ;;
        esac
        break_end
    done
}

# ============================================================================
#  选项 2: OpenClaw 镜像构建向导
# ============================================================================

image_build_menu() {
    while true; do
        clear
        send_stats "OpenClaw镜像构建"
        echo "======================================="
        echo -e "🦞 OpenClaw 镜像构建向导 🦞"
        echo "======================================="
        echo "当前镜像: ${gl_kjlan}${OC_IMAGE_NAME}${gl_bai}"
        echo ""
        echo "镜像状态:"
        if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${OC_IMAGE_NAME}$"; then
            local img_info=$(docker images "$OC_IMAGE_NAME" --format '{{.ID}} {{.Size}} {{.CreatedSince}}')
            echo -e "  ${gl_lv}已构建${gl_bai}  $img_info"
        else
            echo -e "  ${gl_hui}未构建${gl_bai}"
        fi
        echo ""
        echo "------------------------"
        echo "1. 从本地 dockerfile 构建        ★"
        echo "2. 从外链 dockerfile 构建 (GitHub Raw)"
        echo "3. 拉取官方镜像 ghcr.io/openclaw/openclaw"
        echo "4. 拉取官方镜像 openclaw/openclaw (Docker Hub)"
        echo "5. 更新镜像 (重新构建/拉取)"
        echo "6. 查看本地镜像列表"
        echo "7. 删除指定镜像"
        echo "8. 设置默认镜像名"
        echo "------------------------"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) build_from_local_dockerfile ;;
            2) build_from_remote_dockerfile ;;
            3) pull_official_image "ghcr.io/openclaw/openclaw:latest" ;;
            4) pull_official_image "openclaw/openclaw:latest" ;;
            5) update_image ;;
            6) docker image ls; break_end ;;
            7)
                read -e -p "请输入镜像名: " img_name
                docker rmi -f "$img_name" 2>/dev/null
                break_end
                ;;
            8)
                read -e -p "请输入默认镜像名 (如 openclaw:local): " new_image
                [ -n "$new_image" ] && OC_IMAGE_NAME="$new_image"
                echo -e "${gl_lv}已设置为: $OC_IMAGE_NAME${gl_bai}"
                break_end
                ;;
            0) return 0 ;;
            *) echo "无效的输入!"; sleep 1 ;;
        esac
    done
}

# 从本地 dockerfile 构建
build_from_local_dockerfile() {
    install_docker
    local dockerfile_path="$OC_LOCAL_DOCKERFILE"

    if [ -z "$dockerfile_path" ]; then
        # 优先检测当前目录和脚本同目录的 dockerfile
        local script_dir
        script_dir=$(cd "$(dirname "$0")" && pwd)
        if [ -f "$script_dir/dockerfile" ]; then
            dockerfile_path="$script_dir/dockerfile"
            echo -e "${gl_kjlan}检测到同目录 dockerfile: $dockerfile_path${gl_bai}"
            read -e -p "使用此 dockerfile? (Y/n): " use_default
            [[ "$use_default" =~ ^[Nn] ]] && dockerfile_path=""
        fi
    fi

    if [ -z "$dockerfile_path" ]; then
        read -e -p "请输入 dockerfile 路径: " dockerfile_path
    fi

    if [ ! -f "$dockerfile_path" ]; then
        echo -e "${gl_hong}文件不存在: $dockerfile_path${gl_bai}"
        break_end
        return 1
    fi

    local build_context
    build_context=$(dirname "$dockerfile_path")
    local tag_name
    read -e -p "请输入镜像标签 (默认 $OC_IMAGE_NAME): " tag_name
    [ -z "$tag_name" ] && tag_name="$OC_IMAGE_NAME"

    echo -e "${gl_kjlan}开始构建镜像: $tag_name${gl_bai}"
    echo -e "${gl_kjlan}Dockerfile: $dockerfile_path${gl_bai}"
    echo -e "${gl_kjlan}构建上下文: $build_context${gl_bai}"
    echo ""

    if docker build -t "$tag_name" -f "$dockerfile_path" "$build_context"; then
        OC_IMAGE_NAME="$tag_name"
        echo -e "${gl_lv}镜像构建成功: $tag_name${gl_bai}"
    else
        echo -e "${gl_hong}镜像构建失败${gl_bai}"
    fi
    break_end
}

# 从外链 dockerfile 构建 (GitHub Raw)
build_from_remote_dockerfile() {
    install_docker
    local url="$OC_DOCKERFILE_URL"

    if [ -z "$url" ]; then
        echo "请输入 dockerfile 的 URL (如 GitHub Raw 链接):"
        echo "示例: https://raw.githubusercontent.com/<user>/<repo>/main/dockerfile"
        read -e -p "URL: " url
    fi

    if [ -z "$url" ]; then
        echo -e "${gl_hong}URL 不能为空${gl_bai}"
        break_end
        return 1
    fi

    echo -e "${gl_kjlan}正在下载 dockerfile...${gl_bai}"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if curl -fsSL "$url" -o "$tmp_dir/dockerfile"; then
        echo -e "${gl_lv}下载成功${gl_bai}"
        local tag_name
        read -e -p "请输入镜像标签 (默认 $OC_IMAGE_NAME): " tag_name
        [ -z "$tag_name" ] && tag_name="$OC_IMAGE_NAME"

        echo -e "${gl_kjlan}开始构建镜像: $tag_name${gl_bai}"
        if docker build -t "$tag_name" "$tmp_dir"; then
            OC_IMAGE_NAME="$tag_name"
            OC_DOCKERFILE_URL="$url"
            echo -e "${gl_lv}镜像构建成功: $tag_name${gl_bai}"
            echo -e "${gl_kjlan}外链已记录，下次可直接使用${gl_bai}"
        else
            echo -e "${gl_hong}镜像构建失败${gl_bai}"
        fi
    else
        echo -e "${gl_hong}下载失败，请检查 URL${gl_bai}"
    fi
    rm -rf "$tmp_dir"
    break_end
}

# 拉取官方镜像
pull_official_image() {
    install_docker
    local official_image="$1"
    local tag_name

    echo -e "${gl_kjlan}正在拉取官方镜像: $official_image${gl_bai}"
    if docker pull "$official_image"; then
        echo -e "${gl_lv}拉取成功${gl_bai}"
        read -e -p "是否将其标记为 $OC_IMAGE_NAME? (Y/n): " retag
        if [[ ! "$retag" =~ ^[Nn] ]]; then
            docker tag "$official_image" "$OC_IMAGE_NAME"
            echo -e "${gl_lv}已标记为: $OC_IMAGE_NAME${gl_bai}"
        fi
    else
        echo -e "${gl_hong}拉取失败${gl_bai}"
    fi
    break_end
}

# 更新镜像
update_image() {
    install_docker
    echo -e "${gl_kjlan}更新镜像: $OC_IMAGE_NAME${gl_bai}"
    echo "请选择更新方式:"
    echo "1. 重新构建 (本地 dockerfile)"
    echo "2. 重新构建 (外链 dockerfile)"
    echo "3. 重新拉取 (官方镜像)"
    read -e -p "请选择: " update_choice
    case $update_choice in
        1) build_from_local_dockerfile ;;
        2) build_from_remote_dockerfile ;;
        3)
            if [[ "$OC_IMAGE_NAME" == *"ghcr.io"* ]] || [[ "$OC_IMAGE_NAME" == *"openclaw/openclaw"* ]]; then
                pull_official_image "$OC_IMAGE_NAME"
            else
                read -e -p "请输入官方镜像地址: " official
                pull_official_image "$official"
            fi
            ;;
        *) echo "无效选择" ;;
    esac

    # 如果容器正在运行，提示重启
    if oc_container_running; then
        read -e -p "镜像已更新，是否重启 OpenClaw 容器以应用新镜像? (Y/n): " restart_choice
        if [[ ! "$restart_choice" =~ ^[Nn] ]]; then
            cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" up -d --force-recreate openclaw-gateway
            echo -e "${gl_lv}容器已重启${gl_bai}"
        fi
    fi
    break_end
}

# ============================================================================
#  选项 3: OpenClaw 安装向导 (生成 docker-compose.yml + .env)
#  参考: https://docs.openclaw.ai/install/docker
# ============================================================================

install_wizard_menu() {
    while true; do
        clear
        send_stats "OpenClaw安装向导"
        echo "======================================="
        echo -e "🦞 OpenClaw 安装向导 🦞"
        echo "======================================="
        echo "安装目录: ${gl_kjlan}$OC_HOME${gl_bai}"
        echo "配置目录: ${gl_kjlan}$OC_CONFIG_DIR${gl_bai}"
        echo "镜像名:   ${gl_kjlan}$OC_IMAGE_NAME${gl_bai}"
        echo "端口:     ${gl_kjlan}$OC_GATEWAY_PORT${gl_bai}"
        echo ""
        echo "Compose 状态:"
        if [ -f "$COMPOSE_FILE" ]; then
            echo -e "  ${gl_lv}已生成${gl_bai}  $COMPOSE_FILE"
        else
            echo -e "  ${gl_hui}未生成${gl_bai}"
        fi
        echo "容器状态:"
        if oc_container_running; then
            echo -e "  ${gl_lv}运行中${gl_bai}"
        else
            echo -e "  ${gl_hui}未运行${gl_bai}"
        fi
        echo ""
        echo "------------------------"
        echo "1. 完整安装向导 (推荐)      ★"
        echo "2. 仅生成 docker-compose.yml"
        echo "3. 仅生成 .env 配置"
        echo "4. 启动 OpenClaw 容器"
        echo "5. 停止 OpenClaw 容器"
        echo "6. 重启 OpenClaw 容器"
        echo "7. 查看容器日志"
        echo "8. 进入容器终端"
        echo "9. 重新生成配置 (覆盖)"
        echo "10. 配置向导 (onboard)"
        echo "11. 查看访问地址和 Token"
        echo "------------------------"
        echo "0. 返回主菜单"
        echo "------------------------"
        read -e -p "请输入你的选择: " sub_choice
        case $sub_choice in
            1) full_install_wizard ;;
            2) generate_compose_file ;;
            3) generate_env_file ;;
            4) start_gateway; break_end ;;
            5) cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" stop openclaw-gateway; break_end ;;
            6) cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" restart openclaw-gateway; break_end ;;
            7) cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" logs -f --tail=100 openclaw-gateway; break_end ;;
            8) cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" exec openclaw-gateway /bin/bash; break_end ;;
            9) generate_compose_file; generate_env_file; echo -e "${gl_lv}配置已重新生成${gl_bai}"; break_end ;;
            10) run_onboarding ;;
            11) show_access_info; break_end ;;
            0) return 0 ;;
            *) echo "无效的输入!"; sleep 1 ;;
        esac
    done
}

# 前置检查
check_prerequisites() {
    echo -e "${gl_kjlan}=== 前置检查 ===${gl_bai}"

    # Docker
    if ! command_exists docker; then
        echo -e "${gl_hong}✗ Docker 未安装${gl_bai}"
        read -e -p "是否现在安装 Docker? (Y/n): " install_docker_choice
        if [[ ! "$install_docker_choice" =~ ^[Nn] ]]; then
            install_add_docker
        else
            return 1
        fi
    else
        echo -e "${gl_lv}✓ Docker 已安装: $(docker -v)${gl_bai}"
    fi

    # Docker Compose
    if docker compose version >/dev/null 2>&1; then
        echo -e "${gl_lv}✓ Docker Compose v2 可用${gl_bai}"
    else
        echo -e "${gl_hong}✗ Docker Compose v2 不可用，请安装 docker-compose-plugin${gl_bai}"
        return 1
    fi

    # 内存检查
    local mem_total
    mem_total=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    if [ -n "$mem_total" ] && [ "$mem_total" -lt 1800 ]; then
        echo -e "${gl_huang}⚠ 内存仅 ${mem_total}MB，构建镜像可能 OOM (建议 ≥2GB)${gl_bai}"
        read -e -p "继续? (y/N): " continue_choice
        [[ ! "$continue_choice" =~ ^[Yy] ]] && return 1
    else
        echo -e "${gl_lv}✓ 内存充足: ${mem_total}MB${gl_bai}"
    fi

    # 磁盘空间
    local disk_free
    disk_free=$(df -m "$OC_HOME" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$disk_free" ] && [ "$disk_free" -lt 2048 ]; then
        echo -e "${gl_huang}⚠ 磁盘空间不足 ${disk_free}MB (建议 ≥2GB)${gl_bai}"
    else
        echo -e "${gl_lv}✓ 磁盘空间充足: ${disk_free}MB${gl_bai}"
    fi

    # 镜像检查
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${OC_IMAGE_NAME}$"; then
        echo -e "${gl_lv}✓ 镜像已存在: $OC_IMAGE_NAME${gl_bai}"
    else
        echo -e "${gl_huang}⚠ 镜像不存在: $OC_IMAGE_NAME${gl_bai}"
        read -e -p "是否现在构建/拉取镜像? (Y/n): " build_choice
        if [[ ! "$build_choice" =~ ^[Nn] ]]; then
            echo "请选择构建方式:"
            echo "1. 本地 dockerfile 构建"
            echo "2. 外链 dockerfile 构建"
            echo "3. 拉取官方镜像"
            read -e -p "请选择: " build_method
            case $build_method in
                1) build_from_local_dockerfile ;;
                2) build_from_remote_dockerfile ;;
                3) pull_official_image "ghcr.io/openclaw/openclaw:latest" ;;
            esac
        else
            return 1
        fi
    fi

    echo -e "${gl_lv}=== 前置检查通过 ===${gl_bai}"
    return 0
}

# 生成 .env 文件
generate_env_file() {
    echo -e "${gl_kjlan}=== 生成 .env 配置 ===${gl_bai}"

    # 生成随机 token
    local gateway_token
    gateway_token=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p | head -c 64)

    read -e -p "网关端口 (默认 $OC_GATEWAY_PORT): " input_port
    [ -n "$input_port" ] && OC_GATEWAY_PORT="$input_port"

    read -e -p "绑定模式 (lan/loopback, 默认 $OC_GATEWAY_BIND): " input_bind
    [ -n "$input_bind" ] && OC_GATEWAY_BIND="$input_bind"

    read -e -p "是否使用命名卷持久化 /home/node? (留空=bind mount, 输入卷名=openclaw_home): " home_vol
    OC_HOME_VOLUME="$home_vol"

    cat > "$ENV_FILE" <<EOF
# OpenClaw Docker 环境配置
# 由 openclaw-docker.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')

# 镜像配置
OPENCLAW_IMAGE=${OC_IMAGE_NAME}

# 网关配置
OPENCLAW_GATEWAY_PORT=${OC_GATEWAY_PORT}
OPENCLAW_GATEWAY_BIND=${OC_GATEWAY_BIND}
OPENCLAW_GATEWAY_TOKEN=${gateway_token}

# 绑定目录 (宿主机路径)
OPENCLAW_CONFIG_DIR=${OC_CONFIG_DIR}
OPENCLAW_WORKSPACE_DIR=${OC_WORKSPACE_DIR}
OPENCLAW_AUTH_PROFILE_SECRET_DIR=${OC_AUTH_DIR}

# 命名卷 (留空则使用上方 bind mount)
OPENCLAW_HOME_VOLUME=${OC_HOME_VOLUME}

# 沙箱 (默认关闭)
OPENCLAW_SANDBOX=0

# 跳过 onboarding (首次安装设为 0)
OPENCLAW_SKIP_ONBOARDING=0

# 禁用 Bonjour/mDNS (容器环境默认禁用)
OPENCLAW_DISABLE_BONJOUR=1
EOF

    echo -e "${gl_lv}已生成: $ENV_FILE${gl_bai}"
    echo -e "${gl_kjlan}网关 Token: $gateway_token${gl_bai}"
    echo -e "${gl_huang}请妥善保存 Token，访问 WebUI 时需要${gl_bai}"
}

# 生成 docker-compose.yml
generate_compose_file() {
    echo -e "${gl_kjlan}=== 生成 docker-compose.yml ===${gl_bai}"

    mkdir -p "$OC_HOME" "$OC_CONFIG_DIR" "$OC_WORKSPACE_DIR" "$OC_AUTH_DIR" "$OC_DATA_DIR"

    # 确保目录权限 (uid 1000 = node 用户)
    chown -R 1000:1000 "$OC_CONFIG_DIR" "$OC_WORKSPACE_DIR" "$OC_AUTH_DIR" "$OC_DATA_DIR" 2>/dev/null || true

    local home_volume_block=""
    if [ -n "$OC_HOME_VOLUME" ]; then
        home_volume_block="  ${OC_HOME_VOLUME}:
    external: true
"
    fi

    cat > "$COMPOSE_FILE" <<EOF
# OpenClaw Docker Compose
# 由 openclaw-docker.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')
# 参考: https://docs.openclaw.ai/install/docker

services:
  openclaw-gateway:
    image: \${OPENCLAW_IMAGE:-${OC_IMAGE_NAME}}
    container_name: ${OC_CONTAINER}
    restart: unless-stopped
    ports:
      - "\${OPENCLAW_GATEWAY_PORT:-${OC_GATEWAY_PORT}}:18789"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - NODE_ENV=production
      - OPENCLAW_GATEWAY_TOKEN=\${OPENCLAW_GATEWAY_TOKEN}
      - OPENCLAW_GATEWAY_BIND=\${OPENCLAW_GATEWAY_BIND:-${OC_GATEWAY_BIND}}
      - OPENCLAW_DISABLE_BONJOUR=\${OPENCLAW_DISABLE_BONJOUR:-1}
$(if [ -n "$OC_HOME_VOLUME" ]; then
    echo "    volumes:"
    echo "      - \${OPENCLAW_CONFIG_DIR:-${OC_CONFIG_DIR}}:/home/node/.openclaw"
    echo "      - \${OPENCLAW_WORKSPACE_DIR:-${OC_WORKSPACE_DIR}}:/home/node/.openclaw/workspace"
    echo "      - \${OPENCLAW_AUTH_PROFILE_SECRET_DIR:-${OC_AUTH_DIR}}:/home/node/.config/openclaw"
    echo "      - ${OC_HOME_VOLUME}:/home/node"
else
    echo "    volumes:"
    echo "      - \${OPENCLAW_CONFIG_DIR:-${OC_CONFIG_DIR}}:/home/node/.openclaw"
    echo "      - \${OPENCLAW_WORKSPACE_DIR:-${OC_WORKSPACE_DIR}}:/home/node/.openclaw/workspace"
    echo "      - \${OPENCLAW_AUTH_PROFILE_SECRET_DIR:-${OC_AUTH_DIR}}:/home/node/.config/openclaw"
    echo "      - ${OC_DATA_DIR}:/home/node/.openclaw/data"
fi)
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:18789/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - NET_RAW
      - NET_ADMIN

  openclaw-cli:
    image: \${OPENCLAW_IMAGE:-${OC_IMAGE_NAME}}
    container_name: ${OC_CLI_CONTAINER}
    network_mode: "service:${OC_CONTAINER}"
    profiles: ["cli"]
    volumes:
      - \${OPENCLAW_CONFIG_DIR:-${OC_CONFIG_DIR}}:/home/node/.openclaw
      - \${OPENCLAW_WORKSPACE_DIR:-${OC_WORKSPACE_DIR}}:/home/node/.openclaw/workspace
      - \${OPENCLAW_AUTH_PROFILE_SECRET_DIR:-${OC_AUTH_DIR}}:/home/node/.config/openclaw
$(if [ -n "$OC_HOME_VOLUME" ]; then
    echo "      - ${OC_HOME_VOLUME}:/home/node"
fi)
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - NET_RAW
      - NET_ADMIN

${home_volume_block}
EOF

    echo -e "${gl_lv}已生成: $COMPOSE_FILE${gl_bai}"
}

# 运行 onboarding
run_onboarding() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}请先生成 compose 配置${gl_bai}"
        break_end
        return 1
    fi

    cd "$OC_HOME" || return 1
    echo -e "${gl_kjlan}启动 onboarding (将提示输入 API Key 等)...${gl_bai}"
    echo -e "${gl_huang}注意: onboarding 需要交互式终端${gl_bai}"
    echo ""

    # 先确保网关容器存在
    docker compose -f "$COMPOSE_FILE" up -d openclaw-gateway
    sleep 3

    # 运行 onboard (交互式)
    docker compose -f "$COMPOSE_FILE" exec openclaw-gateway \
        node /usr/local/lib/node_modules/openclaw/openclaw.mjs onboard --mode local --no-install-daemon
    break_end
}

# 显示访问信息
show_access_info() {
    echo "======================================="
    echo "OpenClaw 访问信息"
    echo "======================================="

    ip_address

    local port="${OC_GATEWAY_PORT:-18789}"
    local token=""
    if [ -f "$ENV_FILE" ]; then
        token=$(grep '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" | cut -d'=' -f2-)
    fi

    echo ""
    echo -e "${gl_kjlan}本地访问:${gl_bai}"
    echo "  http://127.0.0.1:${port}/"
    [ -n "$token" ] && echo "  http://127.0.0.1:${port}/#token=${token}"

    echo ""
    echo -e "${gl_kjlan}局域网访问:${gl_bai}"
    echo "  http://${ipv4_address:-<your-ip>}:${port}/"
    [ -n "$token" ] && echo "  http://${ipv4_address:-<your-ip>}:${port}/#token=${token}"

    echo ""
    echo -e "${gl_kjlan}网关 Token:${gl_bai}"
    echo "  ${token}"
    echo ""
    echo -e "${gl_huang}请将 Token 粘贴到 WebUI Settings 中完成认证${gl_bai}"

    echo ""
    echo -e "${gl_kjlan}健康检查:${gl_bai}"
    if command_exists curl; then
        local healthz http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" 2>/dev/null)
        if [ "$http_code" = "200" ]; then
            echo -e "  ${gl_lv}✓ /healthz 正常 (HTTP 200)${gl_bai}"
        else
            echo -e "  ${gl_hong}✗ /healthz 异常 (HTTP ${http_code:-000})${gl_bai}"
        fi
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/readyz" 2>/dev/null)
        if [ "$http_code" = "200" ]; then
            echo -e "  ${gl_lv}✓ /readyz 正常 (HTTP 200)${gl_bai}"
        else
            echo -e "  ${gl_huang}⚠ /readyz 异常 (HTTP ${http_code:-000})${gl_bai}"
        fi
    fi
}

# 完整安装向导
full_install_wizard() {
    echo "======================================="
    echo -e "🦞 OpenClaw 完整安装向导 🦞"
    echo "======================================="
    echo ""

    # 1. 前置检查
    if ! check_prerequisites; then
        echo -e "${gl_hong}前置检查未通过，安装中止${gl_bai}"
        break_end
        return 1
    fi

    echo ""

    # 2. 生成配置
    generate_env_file
    echo ""
    generate_compose_file
    echo ""

    # 3. 启动容器
    echo -e "${gl_kjlan}=== 启动 OpenClaw 容器 ===${gl_bai}"
    cd "$OC_HOME" || return 1
    if docker compose -f "$COMPOSE_FILE" up -d openclaw-gateway; then
        echo -e "${gl_lv}容器已启动${gl_bai}"
        sleep 5
    else
        echo -e "${gl_hong}容器启动失败${gl_bai}"
        break_end
        return 1
    fi

    echo ""

    # 4. 健康检查
    echo -e "${gl_kjlan}=== 健康检查 ===${gl_bai}"
    local port="${OC_GATEWAY_PORT:-18789}"
    local retry=0
    while [ $retry -lt 10 ]; do
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" 2>/dev/null)
        if [ "$http_code" = "200" ]; then
            echo -e "${gl_lv}✓ 网关健康检查通过${gl_bai}"
            break
        fi
        retry=$((retry + 1))
        echo -e "${gl_huang}等待网关就绪... (${retry}/10)${gl_bai}"
        sleep 3
    done

    echo ""

    # 5. 显示访问信息
    show_access_info

    echo ""

    # 6. 询问是否运行 onboarding
    echo ""
    read -e -p "是否现在运行配置向导 (onboarding)? 将提示输入 API Key (Y/n): " onboard_choice
    if [[ ! "$onboard_choice" =~ ^[Nn] ]]; then
        run_onboarding
    fi

    echo ""
    echo -e "${gl_lv}=======================================${gl_bai}"
    echo -e "${gl_lv}  OpenClaw 安装完成！${gl_bai}"
    echo -e "${gl_lv}=======================================${gl_bai}"
    echo ""
    echo -e "下一步:"
    echo -e "  1. 访问 ${gl_kjlan}http://<your-ip>:${port}/${gl_bai}"
    echo -e "  2. 在 Settings 中粘贴 Token"
    echo -e "  3. 运行选项4 进入 OpenClaw 容器管理"
    echo ""
    break_end
}

# ============================================================================
#  选项 4: OpenClaw 容器管理 (全量搬运 kejilion.sh moltbot_menu)
#  适配: openclaw xxx → docker compose exec openclaw-cli openclaw xxx
#        ${HOME}/.openclaw/openclaw.json → $OC_CONFIG_DIR/openclaw.json (宿主机直接读写)
# ============================================================================

# 检查容器是否已部署
oc_check_deployed() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}未找到 docker-compose.yml${gl_bai}"
        echo -e "请先运行 ${gl_kjlan}选项3 安装向导${gl_bai} 完成部署"
        break_end
        return 1
    fi
    return 0
}

# 检测 openclaw 安装状态 (容器内是否有 openclaw 命令)
get_install_status() {
    if oc_container_running && oc_exec status >/dev/null 2>&1; then
        echo -e "${gl_lv}已安装${gl_bai}"
    elif [ -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_huang}已部署未运行${gl_bai}"
    else
        echo -e "${gl_hui}未部署${gl_bai}"
    fi
}

# 检测运行状态
get_running_status() {
    if oc_container_running; then
        echo -e "${gl_lv}运行中${gl_bai}"
    else
        echo -e "${gl_hui}未运行${gl_bai}"
    fi
}

# 检测 openclaw 版本更新
check_openclaw_update() {
    if ! oc_container_running; then
        return 1
    fi
    local local_version remote_version
    local_version=$(oc_exec --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -z "$local_version" ] && return 1
    remote_version=$(curl -s --max-time 5 https://registry.npmjs.org/openclaw/latest 2>/dev/null | jq -r '.version' 2>/dev/null)
    [ -z "$remote_version" ] && return 1
    if [ "$local_version" != "$remote_version" ]; then
        echo -e "${gl_huang}检测到新版本: $remote_version (当前 $local_version)${gl_bai}"
    else
        echo -e "${gl_lv}当前版本已是最新: $local_version${gl_bai}"
    fi
}

# 启动 OpenClaw 容器
start_bot() {
    echo -e "${gl_kjlan}启动 OpenClaw 容器...${gl_bai}"
    send_stats "启动 OpenClaw"
    start_gateway
    break_end
}

# 停止 OpenClaw 容器
stop_bot() {
    echo -e "${gl_kjlan}停止 OpenClaw 容器...${gl_bai}"
    send_stats "停止 OpenClaw"
    cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" stop openclaw-gateway
    break_end
}

# 重启 OpenClaw 容器
restart_bot() {
    echo -e "${gl_kjlan}重启 OpenClaw 容器...${gl_bai}"
    send_stats "重启 OpenClaw"
    cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" restart openclaw-gateway
    sleep 3
    break_end
}

# 查看日志
view_logs() {
    echo -e "${gl_kjlan}OpenClaw 状态与日志${gl_bai}"
    send_stats "查看 OpenClaw 日志"
    cd "$OC_HOME" || return 1
    echo ""
    echo -e "${gl_kjlan}=== 容器状态 ===${gl_bai}"
    docker compose -f "$COMPOSE_FILE" ps
    echo ""
    echo -e "${gl_kjlan}=== openclaw status ===${gl_bai}"
    oc_exec status 2>&1 | head -50
    echo ""
    echo -e "${gl_kjlan}=== gateway status ===${gl_bai}"
    oc_exec gateway status 2>&1 | head -30
    echo ""
    echo -e "${gl_kjlan}=== 最近日志 (Ctrl+C 退出) ===${gl_bai}"
    docker compose -f "$COMPOSE_FILE" logs --tail=100 -f openclaw-gateway
    break_end
}

# 更新 OpenClaw (重新拉取/构建镜像并重启)
update_moltbot() {
    echo -e "${gl_kjlan}更新 OpenClaw...${gl_bai}"
    send_stats "更新 OpenClaw"
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_hong}未找到 compose 配置${gl_bai}"
        break_end
        return 1
    fi
    cd "$OC_HOME" || return 1
    echo -e "${gl_kjlan}1. 拉取最新镜像...${gl_bai}"
    docker compose -f "$COMPOSE_FILE" pull openclaw-gateway 2>/dev/null || \
        echo -e "${gl_huang}本地构建镜像请用选项2 更新镜像${gl_bai}"
    echo -e "${gl_kjlan}2. 重建容器...${gl_bai}"
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate openclaw-gateway
    sleep 3
    echo -e "${gl_lv}更新完成${gl_bai}"
    break_end
}

# 卸载 OpenClaw 容器
uninstall_moltbot() {
    echo -e "${gl_hong}卸载 OpenClaw...${gl_bai}"
    send_stats "卸载 OpenClaw"
    if [ ! -f "$COMPOSE_FILE" ]; then
        echo -e "${gl_huang}未找到 compose 配置，无需卸载${gl_bai}"
        break_end
        return 0
    fi
    read -e -p "$(echo -e "${gl_hong}确认卸载? 将停止并删除容器 (Y/N): ${gl_bai}")" choice
    case "$choice" in
        [Yy])
            cd "$OC_HOME" || return 1
            docker compose -f "$COMPOSE_FILE" down -v 2>/dev/null
            echo -e "${gl_kjlan}是否删除配置和数据目录? $OC_HOME${gl_bai}"
            read -e -p "(y/N): " del_data
            if [[ "$del_data" =~ ^[Yy] ]]; then
                rm -rf "$OC_HOME"
                echo -e "${gl_lv}已删除: $OC_HOME${gl_bai}"
            else
                echo -e "${gl_huang}已保留配置: $OC_HOME${gl_bai}"
            fi
            echo -e "${gl_lv}卸载完成${gl_bai}"
            ;;
    esac
    break_end
}

# ----------------------------------------------------------------------------
#  OpenClaw API Provider 管理 (适配 docker)
# ----------------------------------------------------------------------------

# 构造 provider 的 models JSON 数组
build-openclaw-provider-models-json() {
    local provider_name="$1"
    local model_ids="$2"
    local models_array="["
    local first=true
    while read -r model_id; do
        [ -z "$model_id" ] && continue
        [[ $first == false ]] && models_array+=","
        first=false
        local context_window=1048576
        local max_tokens=128000
        local input_cost=0.15
        local output_cost=0.60
        case "$model_id" in
            *opus*|*pro*|*preview*|*thinking*|*sonnet*)
                input_cost=2.00
                output_cost=12.00
                ;;
            *gpt-5*|*codex*)
                input_cost=1.25
                output_cost=10.00
                ;;
            *flash*|*lite*|*haiku*|*mini*|*nano*)
                input_cost=0.10
                output_cost=0.40
                ;;
        esac
        models_array+=$(cat <<EOF
{
    "id": "$model_id",
    "name": "$provider_name / $model_id",
    "input": ["text", "image"],
    "contextWindow": $context_window,
    "maxTokens": $max_tokens,
    "cost": {
        "input": $input_cost,
        "output": $output_cost,
        "cacheRead": 0,
        "cacheWrite": 0
    }
}
EOF
)
    done <<< "$model_ids"
    models_array+="]"
    echo "$models_array"
}

# 写入 provider 配置到 openclaw.json (宿主机直接操作)
write-openclaw-provider-models() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local models_array="$4"
    local config_file
    config_file=$(openclaw_get_config_file)
    [ ! -f "$config_file" ] && {
        echo "未找到配置文件: $config_file"
        return 1
    }
    install jq
    cp "$config_file" "${config_file}.bak.$(date +%s)"
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg prov "$provider_name" \
       --arg baseUrl "$base_url" \
       --arg apiKey "$api_key" \
       --argjson models "$models_array" \
       '.models.providers[$prov] = {
           "baseUrl": $baseUrl,
           "apiKey": $apiKey,
           "api": "openai-completions",
           "models": $models
       }
       | .agents.defaults.models[$prov] = (.agents.defaults.models[$prov] // {})' \
       "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    echo -e "${gl_lv}已写入 provider: $provider_name${gl_bai}"
}

# 添加全量模型
add-all-models-from-provider() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local model_ids="$4"
    local models_array
    models_array=$(build-openclaw-provider-models-json "$provider_name" "$model_ids")
    write-openclaw-provider-models "$provider_name" "$base_url" "$api_key" "$models_array"
}

# 仅添加默认模型
add-default-model-only-to-provider() {
    local provider_name="$1"
    local base_url="$2"
    local api_key="$3"
    local default_model="$4"
    local models_array
    models_array=$(build-openclaw-provider-models-json "$provider_name" "$default_model")
    write-openclaw-provider-models "$provider_name" "$base_url" "$api_key" "$models_array"
}

# 同步会话模型
openclaw_sync_sessions_model() {
    local model_ref="$1"
    oc_exec models set "$model_ref" >/dev/null 2>&1 || true
}

# 交互式添加 provider
add-openclaw-provider-interactive() {
    send_stats "OpenClaw API添加"
    echo "=== 交互式添加 OpenClaw Provider (全量模型) ==="
    echo ""
    read -e -p "Provider 名称 (如 deepseek/openrouter): " provider_name
    [ -z "$provider_name" ] && return 1
    read -e -p "Base URL (如 https://api.deepseek.com/v1): " base_url
    [ -z "$base_url" ] && return 1
    read -s -p "API Key: " api_key
    echo ""
    [ -z "$api_key" ] && return 1

    echo -e "${gl_kjlan}正在获取可用模型列表...${gl_bai}"
    local models_response
    models_response=$(curl -s -m 10 -H "Authorization: Bearer $api_key" "${base_url}/models" 2>/dev/null)
    local model_list
    model_list=$(echo "$models_response" | jq -r '.data[].id // empty' 2>/dev/null)

    if [ -z "$model_list" ]; then
        echo -e "${gl_hong}无法获取模型列表，请检查 Base URL 和 API Key${gl_bai}"
        echo "响应: $models_response"
        return 1
    fi

    echo -e "${gl_kjlan}可用模型:${gl_bai}"
    local i=1
    local model_array=()
    while read -r m; do
        echo "  $i. $m"
        model_array+=("$m")
        i=$((i+1))
    done <<< "$model_list"

    echo ""
    read -e -p "选择默认模型编号: " model_choice
    local default_model="${model_array[$((model_choice-1))]}"
    [ -z "$default_model" ] && default_model="${model_array[0]}"

    echo ""
    echo "1) 添加全部模型 + 设为默认"
    echo "2) 仅添加默认模型 ($default_model)"
    read -e -p "请选择 (1/2): " add_choice
    case "$add_choice" in
        1)
            add-all-models-from-provider "$provider_name" "$base_url" "$api_key" "$model_list"
            ;;
        2)
            add-default-model-only-to-provider "$provider_name" "$base_url" "$api_key" "$default_model"
            ;;
        *)
            add-default-model-only-to-provider "$provider_name" "$base_url" "$api_key" "$default_model"
            ;;
    esac

    oc_exec models set "$provider_name/$default_model" 2>/dev/null
    openclaw_sync_sessions_model "$provider_name/$default_model"
    start_gateway
    echo -e "${gl_lv}Provider 添加完成: $provider_name (默认模型: $default_model)${gl_bai}"
}

# 列出已配置的 provider
openclaw_api_manage_list() {
    local config_file
    config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API列表"
    [ ! -f "$config_file" ] && {
        echo "ℹ️ 未找到 openclaw.json: $config_file"
        return 1
    }
    install jq
    local providers
    providers=$(jq -r '.models.providers | keys[]' "$config_file" 2>/dev/null)
    [ -z "$providers" ] && {
        echo "ℹ️ 未配置任何 provider"
        return 0
    }
    echo "======================================="
    echo "已配置的 API Provider"
    echo "======================================="
    printf "%-4s %-20s %-40s %-15s %-10s\n" "#" "名称" "Base URL" "协议" "模型数"
    echo "-------------------------------------------------------------------------------"
    local i=1
    while read -r name; do
        local base_url api models_count
        base_url=$(jq -r --arg p "$name" '.models.providers[$p].baseUrl // "-"' "$config_file")
        api=$(jq -r --arg p "$name" '.models.providers[$p].api // "openai-completions"' "$config_file")
        models_count=$(jq -r --arg p "$name" '.models.providers[$p].models | length' "$config_file" 2>/dev/null)
        [ -z "$models_count" ] && models_count=0
        printf "%-4s %-20s %-40s %-15s %-10s\n" "$i" "$name" "$base_url" "$api" "$models_count"
        i=$((i+1))
    done <<< "$providers"
    echo ""
}

# 同步 provider 模型 (调用容器内 openclaw 命令)
sync-openclaw-provider-interactive() {
    send_stats "OpenClaw API同步"
    local config_file
    config_file=$(openclaw_get_config_file)
    [ ! -f "$config_file" ] && {
        echo "ℹ️ 未找到配置文件"
        return 1
    }
    openclaw_api_manage_list
    echo ""
    read -e -p "请输入要同步的 Provider 名称 (留空=全部): " provider_name
    echo -e "${gl_kjlan}正在同步...${gl_bai}"
    if [ -n "$provider_name" ]; then
        # 单个 provider: 通过 python 在宿主机操作 config
        local base_url api_key
        base_url=$(jq -r --arg p "$provider_name" '.models.providers[$p].baseUrl // empty' "$config_file")
        api_key=$(jq -r --arg p "$provider_name" '.models.providers[$p].apiKey // empty' "$config_file")
        if [ -z "$base_url" ] || [ -z "$api_key" ]; then
            echo -e "${gl_hong}未找到 provider: $provider_name${gl_bai}"
            return 1
        fi
        local remote_models
        remote_models=$(curl -s -m 15 -H "Authorization: Bearer $api_key" "${base_url}/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null)
        if [ -z "$remote_models" ]; then
            echo -e "${gl_hong}无法获取远程模型列表${gl_bai}"
            return 1
        fi
        add-all-models-from-provider "$provider_name" "$base_url" "$api_key" "$remote_models"
        echo -e "${gl_lv}同步完成: $provider_name${gl_bai}"
    else
        # 全部同步
        for p in $(jq -r '.models.providers | keys[]' "$config_file" 2>/dev/null); do
            local base_url api_key
            base_url=$(jq -r --arg p "$p" '.models.providers[$p].baseUrl // empty' "$config_file")
            api_key=$(jq -r --arg p "$p" '.models.providers[$p].apiKey // empty' "$config_file")
            [ -z "$base_url" ] && continue
            local remote_models
            remote_models=$(curl -s -m 15 -H "Authorization: Bearer $api_key" "${base_url}/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null)
            [ -z "$remote_models" ] && continue
            add-all-models-from-provider "$p" "$base_url" "$api_key" "$remote_models"
            echo -e "${gl_lv}同步完成: $p${gl_bai}"
        done
    fi
    start_gateway
}

# 切换 provider 协议
fix-openclaw-provider-protocol-interactive() {
    local config_file
    config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API协议切换"
    [ ! -f "$config_file" ] && return 1
    openclaw_api_manage_list
    read -e -p "请输入 Provider 名称: " provider_name
    jq -e --arg p "$provider_name" '.models.providers[$p]' "$config_file" >/dev/null 2>&1 || {
        echo "未找到 provider: $provider_name"
        return 1
    }
    echo "选择协议:"
    echo "1. openai-completions (默认, /chat/completions)"
    echo "2. openai-responses (/responses)"
    read -e -p "请选择 (1/2): " proto_choice
    local new_api="openai-completions"
    [ "$proto_choice" = "2" ] && new_api="openai-responses"
    install jq
    local tmp_file
    tmp_file=$(mktemp)
    jq --arg p "$provider_name" --arg api "$new_api" \
       '.models.providers[$p].api = $api' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    echo -e "${gl_lv}已切换 $provider_name 协议为 $new_api${gl_bai}"
    start_gateway
}

# 删除 provider
delete-openclaw-provider-interactive() {
    local config_file
    config_file=$(openclaw_get_config_file)
    send_stats "OpenClaw API删除入口"
    [ ! -f "$config_file" ] && return 1
    openclaw_api_manage_list
    read -e -p "请输入要删除的 Provider 名称: " provider_name
    jq -e --arg p "$provider_name" '.models.providers[$p]' "$config_file" >/dev/null 2>&1 || {
        echo "未找到 provider: $provider_name"
        return 1
    }
    read -e -p "确认删除 $provider_name? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && return 0
    install jq
    local tmp_file
    tmp_file=$(mktemp)
    # 删除 provider 及其 defaults.models 引用
    jq --arg p "$provider_name" \
       'del(.models.providers[$p]) | del(.agents.defaults.models[$p])' "$config_file" > "$tmp_file" && mv "$tmp_file" "$config_file"
    echo -e "${gl_lv}已删除 provider: $provider_name${gl_bai}"
    start_gateway
}

# API 厂商推荐
openclaw_api_providers_showcase() {
    send_stats "OpenClaw API厂商推荐"
    echo "======================================="
    echo "API 厂商推荐"
    echo "======================================="
    echo -e "${gl_kjlan}DeepSeek${gl_bai}    https://api.deepseek.com/v1"
    echo -e "${gl_kjlan}OpenRouter${gl_bai}  https://openrouter.ai/api/v1"
    echo -e "${gl_kjlan}Kimi${gl_bai}        https://api.moonshot.cn/v1"
    echo -e "${gl_kjlan}硅基流动${gl_bai}    https://api.siliconflow.cn/v1"
    echo -e "${gl_kjlan}智谱GLM${gl_bai}     https://open.bigmodel.cn/api/paas/v4"
    echo -e "${gl_kjlan}MiniMax${gl_bai}     https://api.minimax.chat/v1"
    echo -e "${gl_kjlan}NVIDIA${gl_bai}      https://integrate.api.nvidia.com/v1"
    echo -e "${gl_kjlan}Ollama${gl_bai}      http://host.docker.internal:11434/v1"
    echo -e "${gl_kjlan}LM Studio${gl_bai}   http://host.docker.internal:1234/v1"
    echo ""
    echo -e "${gl_huang}提示: 容器内访问宿主机服务请用 host.docker.internal${gl_bai}"
    echo "======================================="
}

# API 管理菜单
openclaw_api_manage_menu() {
    while true; do
        clear
        echo "======================================="
        echo "OpenClaw API 管理"
        echo "======================================="
        openclaw_api_manage_list
        echo "1. 添加 API Provider"
        echo "2. 同步 API 模型列表"
        echo "3. 切换 API 协议 (completions/responses)"
        echo "4. 删除 API Provider"
        echo "5. API 厂商推荐"
        echo "0. 返回上一级"
        echo "---------------------------------------"
        read -e -p "请输入选择: " sub_choice
        case $sub_choice in
            1) add-openclaw-provider-interactive; break_end ;;
            2) sync-openclaw-provider-interactive; break_end ;;
            3) fix-openclaw-provider-protocol-interactive; break_end ;;
            4) delete-openclaw-provider-interactive; break_end ;;
            5) openclaw_api_providers_showcase; break_end ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ----------------------------------------------------------------------------
#  换模型
# ----------------------------------------------------------------------------

change_model() {
    send_stats "换模型"
    local config_file
    config_file=$(openclaw_get_config_file)
    [ ! -f "$config_file" ] && {
        echo "未找到配置文件"
        break_end
        return 1
    }
    install jq

    local current_model
    current_model=$(jq -r '.agents.defaults.model.primary // .agents.defaults.model // "-"' "$config_file" 2>/dev/null)
    echo "当前默认模型: ${gl_kjlan}${current_model}${gl_bai}"
    echo ""

    local providers
    providers=$(jq -r '.models.providers | keys[]' "$config_file" 2>/dev/null)
    [ -z "$providers" ] && {
        echo "未配置任何 provider，请先用 API 管理添加"
        break_end
        return 1
    }

    echo "可用模型:"
    local i=1
    local model_refs=()
    while read -r p; do
        local models
        models=$(jq -r --arg p "$p" '.models.providers[$p].models[]?.id // empty' "$config_file" 2>/dev/null)
        while read -r m; do
            [ -z "$m" ] && continue
            local ref="$p/$m"
            local mark=""
            [ "$ref" = "$current_model" ] && mark="${gl_lv}*${gl_bai} "
            echo "  $i. ${mark}${ref}"
            model_refs+=("$ref")
            i=$((i+1))
        done <<< "$models"
    done <<< "$providers"

    echo ""
    [ ${#model_refs[@]} -eq 0 ] && {
        echo "未找到可用模型"
        break_end
        return 1
    }
    read -e -p "选择模型编号 (0=取消): " model_choice
    [ "$model_choice" = "0" ] && return 0
    [ -z "$model_choice" ] && return 0
    local selected="${model_refs[$((model_choice-1))]}"
    [ -z "$selected" ] && {
        echo "无效选择"
        break_end
        return 1
    }

    # 探测模型可用性
    echo -e "${gl_kjlan}正在探测模型可用性...${gl_bai}"
    local provider_name="${selected%%/*}"
    local request_model="${selected#*/}"
    local base_url api_key
    base_url=$(jq -r --arg p "$provider_name" '.models.providers[$p].baseUrl // empty' "$config_file")
    api_key=$(jq -r --arg p "$provider_name" '.models.providers[$p].apiKey // empty' "$config_file")

    local probe_ok=false
    if [ -n "$base_url" ] && [ -n "$api_key" ]; then
        local tmp_payload tmp_response
        tmp_payload=$(mktemp)
        tmp_response=$(mktemp)
        printf '{"model":"%s","messages":[{"role":"user","content":"hi"}],"temperature":0,"max_tokens":16}' "$request_model" > "$tmp_payload"
        local http_code
        http_code=$(curl -s -o "$tmp_response" -w '%{http_code}' -m 25 \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $api_key" \
            "${base_url%/}/chat/completions" \
            -d @"$tmp_payload" 2>/dev/null)
        rm -f "$tmp_payload" "$tmp_response"
        if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
            echo -e "${gl_lv}✓ 模型探测成功 (HTTP $http_code)${gl_bai}"
            probe_ok=true
        else
            echo -e "${gl_huang}⚠ 模型探测异常 (HTTP $http_code)${gl_bai}"
            read -e -p "仍要设为默认? (y/N): " force_set
            [[ "$force_set" =~ ^[Yy] ]] && probe_ok=true
        fi
    fi

    if [ "$probe_ok" = true ]; then
        oc_exec models set "$selected" 2>/dev/null
        # 同时更新 config 文件
        local tmp_file
        tmp_file=$(mktemp)
        jq --arg ref "$selected" \
           '.agents.defaults.model = (if .agents.defaults.model | type == "object" then .primary = $ref else $ref end)' \
           "$config_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$config_file"
        echo -e "${gl_lv}已设为默认模型: $selected${gl_bai}"
        start_gateway
    fi
    break_end
}

# ----------------------------------------------------------------------------
#  插件 / 技能 / 配置文件 / 配置向导 / 健康检测 / WebUI / TUI / 记忆 / 权限 / 多智能体 / 备份还原
# ----------------------------------------------------------------------------

install_plugin() {
    send_stats "插件管理"
    while true; do
        clear
        echo "========================================"
        echo "         插件管理 (安装/删除)"
        echo "========================================"
        echo "当前插件列表:"
        oc_exec plugins list 2>/dev/null
        echo "--------------------------------------------------------"
        echo "推荐插件 ID:"
        echo "  [feishu] [telegram] [slack] [msteams] [discord] [whatsapp]"
        echo "  [memory-core] [memory-lancedb] [copilot-proxy]"
        echo "  [lobster] [voice-call] [nostr]"
        echo "--------------------------------------------------------"
        echo "1) 安装/启用插件"
        echo "2) 删除/禁用插件"
        echo "0) 返回"
        read -e -p "请选择操作: " plugin_action
        [ "$plugin_action" = "0" ] && break
        [ -z "$plugin_action" ] && continue
        read -e -p "请输入插件 ID (空格分隔, 0 退出): " raw_input
        [ "$raw_input" = "0" ] && break
        [ -z "$raw_input" ] && continue

        local changed=false
        for token in $raw_input; do
            if [ "$plugin_action" = "1" ]; then
                echo -e "${gl_kjlan}安装/启用: $token${gl_bai}"
                if oc_exec plugins install "$token" 2>/dev/null; then
                    oc_exec plugins enable "$token" 2>/dev/null
                    echo -e "${gl_lv}✓ $token${gl_bai}"
                    changed=true
                else
                    echo -e "${gl_hong}✗ $token 安装失败${gl_bai}"
                fi
            else
                echo -e "${gl_kjlan}禁用/卸载: $token${gl_bai}"
                oc_exec plugins disable "$token" 2>/dev/null
                oc_exec plugins uninstall "$token" 2>/dev/null
                echo -e "${gl_lv}✓ $token${gl_bai}"
                changed=true
            fi
        done
        [ "$changed" = true ] && start_gateway
        break_end
    done
}

install_skill() {
    send_stats "技能管理"
    while true; do
        clear
        echo "========================================"
        echo "         技能管理 (安装/删除)"
        echo "========================================"
        echo "当前已安装技能:"
        oc_exec skills list 2>/dev/null
        echo "----------------------------------------"
        echo "推荐技能:"
        echo "  github notion apple-notes apple-reminders 1password gog"
        echo "  things-mac bluebubbles himalaya summarize openhue video-frames"
        echo "  openai-whisper coding-agent"
        echo "----------------------------------------"
        echo "1) 安装技能"
        echo "2) 删除技能"
        echo "0) 返回"
        read -e -p "请选择操作: " skill_action
        [ "$skill_action" = "0" ] && break
        [ -z "$skill_action" ] && continue
        read -e -p "请输入技能名称 (空格分隔, 0 退出): " skill_input
        [ "$skill_input" = "0" ] && break
        [ -z "$skill_input" ] && continue

        local changed=false
        for token in $skill_input; do
            if [ "$skill_action" = "1" ]; then
                echo -e "${gl_kjlan}安装技能: $token${gl_bai}"
                if oc_exec skills install "$token" 2>/dev/null; then
                    echo -e "${gl_lv}✓ $token${gl_bai}"
                    changed=true
                else
                    echo -e "${gl_hong}✗ $token 安装失败${gl_bai}"
                fi
            else
                echo -e "${gl_kjlan}删除技能: $token${gl_bai}"
                oc_exec skills uninstall "$token" 2>/dev/null
                echo -e "${gl_lv}✓ $token${gl_bai}"
                changed=true
            fi
        done
        [ "$changed" = true ] && start_gateway
        break_end
    done
}

nano_openclaw_json() {
    send_stats "编辑 OpenClaw 配置文件"
    install nano
    local config_file
    config_file=$(openclaw_get_config_file)
    [ ! -f "$config_file" ] && {
        echo "未找到配置文件: $config_file"
        break_end
        return 1
    }
    nano "$config_file"
    start_gateway
}

openclaw_webui_menu() {
    while true; do
        clear
        send_stats "OpenClaw WebUI"
        echo "======================================="
        echo "OpenClaw WebUI 访问与设置"
        echo "======================================="
        show_access_info
        echo "---------------------------------------"
        echo "1. 重新显示访问地址和 Token"
        echo "2. 获取新的 dashboard 链接"
        echo "3. 查看设备列表"
        echo "4. 审批设备 (approve)"
        echo "0. 返回上一级"
        echo "---------------------------------------"
        read -e -p "请输入选择: " sub_choice
        case $sub_choice in
            1) show_access_info ;;
            2) oc_exec dashboard --no-open 2>&1 | head -20 ;;
            3) oc_exec devices list 2>&1 | head -30 ;;
            4)
                read -e -p "请输入 Request ID: " req_id
                [ -n "$req_id" ] && oc_exec devices approve "$req_id"
                ;;
            0) return 0 ;;
        esac
        break_end
    done
}

openclaw_memory_menu() {
    while true; do
        clear
        send_stats "OpenClaw 记忆管理"
        echo "======================================="
        echo "OpenClaw 记忆 / Memory"
        echo "======================================="
        echo "1. 查看记忆列表"
        echo "2. 查看记忆详情"
        echo "3. 添加记忆"
        echo "4. 删除记忆"
        echo "5. 清空所有记忆"
        echo "6. 记忆统计"
        echo "0. 返回上一级"
        echo "---------------------------------------"
        read -e -p "请输入选择: " sub_choice
        case $sub_choice in
            1) oc_exec memory list 2>&1 | head -50 ;;
            2)
                read -e -p "请输入记忆 ID: " mem_id
                [ -n "$mem_id" ] && oc_exec memory get "$mem_id"
                ;;
            3)
                read -e -p "请输入记忆内容: " mem_content
                [ -n "$mem_content" ] && oc_exec memory add "$mem_content"
                ;;
            4)
                read -e -p "请输入记忆 ID: " mem_id
                [ -n "$mem_id" ] && oc_exec memory delete "$mem_id"
                ;;
            5)
                read -e -p "$(echo -e "${gl_hong}确认清空所有记忆? (y/N): ${gl_bai}")" confirm
                [[ "$confirm" =~ ^[Yy] ]] && oc_exec memory clear
                ;;
            6) oc_exec memory stats 2>&1 ;;
            0) return 0 ;;
        esac
        break_end
    done
}

openclaw_permission_menu() {
    while true; do
        clear
        send_stats "OpenClaw 权限管理"
        echo "======================================="
        echo "OpenClaw 权限管理"
        echo "======================================="
        echo "1. 查看权限列表"
        echo "2. 授予权限"
        echo "3. 撤销权限"
        echo "4. 查看角色列表"
        echo "5. 创建角色"
        echo "6. 删除角色"
        echo "0. 返回上一级"
        echo "---------------------------------------"
        read -e -p "请输入选择: " sub_choice
        case $sub_choice in
            1) oc_exec permissions list 2>&1 ;;
            2)
                read -e -p "权限名称: " perm
                [ -n "$perm" ] && oc_exec permissions grant "$perm"
                ;;
            3)
                read -e -p "权限名称: " perm
                [ -n "$perm" ] && oc_exec permissions revoke "$perm"
                ;;
            4) oc_exec roles list 2>&1 ;;
            5)
                read -e -p "角色名称: " role
                [ -n "$role" ] && oc_exec roles create "$role"
                ;;
            6)
                read -e -p "角色名称: " role
                [ -n "$role" ] && oc_exec roles delete "$role"
                ;;
            0) return 0 ;;
        esac
        break_end
    done
}

openclaw_multiagent_menu() {
    while true; do
        clear
        send_stats "OpenClaw 多智能体"
        echo "======================================="
        echo "OpenClaw 多智能体管理"
        echo "======================================="
        echo "1. 查看智能体列表"
        echo "2. 创建智能体"
        echo "3. 删除智能体"
        echo "4. 查看智能体详情"
        echo "5. 设置默认智能体"
        echo "6. 查看会话列表"
        echo "0. 返回上一级"
        echo "---------------------------------------"
        read -e -p "请输入选择: " sub_choice
        case $sub_choice in
            1) oc_exec agents list 2>&1 ;;
            2)
                read -e -p "智能体名称: " agent_name
                [ -n "$agent_name" ] && oc_exec agents create "$agent_name"
                ;;
            3)
                read -e -p "智能体名称: " agent_name
                [ -n "$agent_name" ] && oc_exec agents delete "$agent_name"
                ;;
            4)
                read -e -p "智能体名称: " agent_name
                [ -n "$agent_name" ] && oc_exec agents show "$agent_name"
                ;;
            5)
                read -e -p "智能体名称: " agent_name
                [ -n "$agent_name" ] && oc_exec agents set-default "$agent_name"
                ;;
            6) oc_exec sessions list 2>&1 ;;
            0) return 0 ;;
        esac
        break_end
    done
}

# 备份/还原
openclaw_backup_render_file_list() {
    [ -d "$OC_BACKUP_DIR" ] || return 0
    local files
    files=$(ls -1 "$OC_BACKUP_DIR"/*.tar.gz 2>/dev/null)
    [ -z "$files" ] && return 0
    echo "备份文件列表:"
    ls -lh "$OC_BACKUP_DIR"/*.tar.gz 2>/dev/null
    echo ""
}

openclaw_memory_backup_export() {
    send_stats "备份记忆"
    local bak_name="memory-$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$OC_BACKUP_DIR"
    echo -e "${gl_kjlan}备份记忆到 $OC_BACKUP_DIR/$bak_name${gl_bai}"
    tar -czf "$OC_BACKUP_DIR/$bak_name" \
        -C "$OC_CONFIG_DIR" . 2>/dev/null
    echo -e "${gl_lv}备份完成: $OC_BACKUP_DIR/$bak_name${gl_bai}"
}

openclaw_memory_backup_import() {
    send_stats "还原记忆"
    openclaw_backup_render_file_list
    read -e -p "请输入备份文件名 (不含路径): " bak_file
    if [ -f "$OC_BACKUP_DIR/$bak_file" ]; then
        cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" stop openclaw-gateway
        tar -xzf "$OC_BACKUP_DIR/$bak_file" -C "$OC_CONFIG_DIR"
        chown -R 1000:1000 "$OC_CONFIG_DIR" 2>/dev/null
        start_gateway
        echo -e "${gl_lv}还原完成${gl_bai}"
    else
        echo -e "${gl_hong}文件不存在${gl_bai}"
    fi
}

openclaw_project_backup_export() {
    send_stats "备份项目"
    local bak_name="project-$(date +%Y%m%d_%H%M%S).tar.gz"
    mkdir -p "$OC_BACKUP_DIR"
    echo -e "${gl_kjlan}备份整个 OpenClaw 项目到 $OC_BACKUP_DIR/$bak_name${gl_bai}"
    tar -czf "$OC_BACKUP_DIR/$bak_name" \
        -C "$OC_HOME" . 2>/dev/null \
        --exclude="backup" || true
    echo -e "${gl_lv}备份完成: $OC_BACKUP_DIR/$bak_name${gl_bai}"
}

openclaw_project_backup_import() {
    send_stats "还原项目"
    openclaw_backup_render_file_list
    read -e -p "$(echo -e "${gl_hong}高级操作: 还原将覆盖当前项目, 确认? (y/N): ${gl_bai}")" confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && return 0
    read -e -p "请输入备份文件名 (不含路径): " bak_file
    if [ -f "$OC_BACKUP_DIR/$bak_file" ]; then
        cd "$OC_HOME" && docker compose -f "$COMPOSE_FILE" down 2>/dev/null
        tar -xzf "$OC_BACKUP_DIR/$bak_file" -C "$OC_HOME"
        chown -R 1000:1000 "$OC_CONFIG_DIR" "$OC_AUTH_DIR" "$OC_DATA_DIR" 2>/dev/null
        start_gateway
        echo -e "${gl_lv}还原完成${gl_bai}"
    else
        echo -e "${gl_hong}文件不存在${gl_bai}"
    fi
}

openclaw_backup_delete_file() {
    read -e -p "请输入要删除的备份文件名 (留空=全部): " del_file
    if [ -z "$del_file" ]; then
        read -e -p "$(echo -e "${gl_hong}确定删除所有备份? (Y/N): ${gl_bai}")" choice
        case "$choice" in
            [Yy]) rm -f "$OC_BACKUP_DIR"/*.tar.gz ;;
        esac
    else
        rm -f "$OC_BACKUP_DIR/$del_file"
    fi
}

openclaw_backup_restore_menu() {
    send_stats "OpenClaw备份与还原"
    while true; do
        clear
        echo "======================================="
        echo "OpenClaw 备份与还原"
        echo "======================================="
        openclaw_backup_render_file_list
        echo "---------------------------------------"
        echo "1. 备份记忆全量"
        echo "2. 还原记忆全量"
        echo "3. 备份 OpenClaw 项目 (安全模式)"
        echo "4. 还原 OpenClaw 项目 (高级/高风险)"
        echo "5. 删除备份文件"
        echo "0. 返回上一级"
        echo "---------------------------------------"
        read -e -p "请输入你的选择: " backup_choice
        case "$backup_choice" in
            1) openclaw_memory_backup_export; break_end ;;
            2) openclaw_memory_backup_import; break_end ;;
            3) openclaw_project_backup_export; break_end ;;
            4) openclaw_project_backup_import; break_end ;;
            5) openclaw_backup_delete_file; break_end ;;
            0) return 0 ;;
            *) echo "无效的选择"; sleep 1 ;;
        esac
    done
}

# 机器人连接对接
change_tg_bot_code() {
    send_stats "机器人连接对接"
    echo "======================================="
    echo "机器人连接对接"
    echo "======================================="
    echo "选择渠道:"
    echo "1. Telegram"
    echo "2. Discord"
    echo "3. WhatsApp (QR)"
    echo "4. 飞书 (Feishu/Lark)"
    echo "0. 返回"
    read -e -p "请选择: " channel_choice
    case $channel_choice in
        1)
            read -e -p "Telegram Bot Token: " tg_token
            [ -n "$tg_token" ] && oc_exec channels add --channel telegram --token "$tg_token"
            ;;
        2)
            read -e -p "Discord Bot Token: " dc_token
            [ -n "$dc_token" ] && oc_exec channels add --channel discord --token "$dc_token"
            ;;
        3) oc_exec_it channels login ;;
        4)
            echo "飞书插件请先在插件管理中安装 feishu 插件"
            echo "然后参考 https://docs.openclaw.ai/channels/feishu 配置"
            ;;
        0) return 0 ;;
    esac
    break_end
}

# ----------------------------------------------------------------------------
#  OpenClaw 容器管理主菜单
# ----------------------------------------------------------------------------

openclaw_container_menu() {
    oc_check_deployed || return 0
    while true; do
        clear
        local install_status running_status update_message
        install_status=$(get_install_status)
        running_status=$(get_running_status)
        update_message=$(check_openclaw_update 2>/dev/null)

        echo "======================================="
        echo -e "🦞 OPENCLAW 容器管理 (Docker) 🦞"
        echo "======================================="
        echo -e "$install_status $running_status $update_message"
        echo "======================================="
        echo "1.  启动容器              2.  停止容器"
        echo "3.  重启容器              4.  状态日志查看"
        echo "--------------------"
        echo "5.  换模型"
        echo "6.  API管理"
        echo "7.  机器人连接对接"
        echo "8.  插件管理（安装/删除）"
        echo "9.  技能管理（安装/删除）"
        echo "10. 编辑主配置文件"
        echo "11. 配置向导 (onboard)"
        echo "12. 健康检测与修复 (doctor)"
        echo "13. WebUI访问与设置"
        echo "14. TUI命令行对话窗口"
        echo "15. 记忆/Memory"
        echo "16. 权限管理"
        echo "17. 多智能体管理"
        echo "--------------------"
        echo "18. 备份与还原"
        echo "19. 更新 (拉取最新镜像)"
        echo "20. 卸载 (停止并删除容器)"
        echo "--------------------"
        echo "0.  返回主菜单"
        echo "--------------------"
        read -e -p "请输入选项并回车: " choice
        case $choice in
            1) start_bot ;;
            2) stop_bot ;;
            3) restart_bot ;;
            4) view_logs ;;
            5) change_model ;;
            6) openclaw_api_manage_menu ;;
            7) change_tg_bot_code ;;
            8) install_plugin ;;
            9) install_skill ;;
            10) nano_openclaw_json ;;
            11)
                send_stats "初始化配置向导"
                oc_exec_it onboard --mode local --no-install-daemon
                break_end
                ;;
            12)
                send_stats "健康检测与修复"
                oc_exec doctor --fix
                break_end
                ;;
            13) openclaw_webui_menu ;;
            14)
                send_stats "TUI命令行对话"
                oc_exec_it tui
                break_end
                ;;
            15) openclaw_memory_menu ;;
            16) openclaw_permission_menu ;;
            17) openclaw_multiagent_menu ;;
            18) openclaw_backup_restore_menu ;;
            19) update_moltbot ;;
            20) uninstall_moltbot ;;
            0) break ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================================================================
#  主菜单
# ============================================================================

main_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}"
        cat <<'LOGO'
  ___                    ____ ___   ____    _    ____  _____ 
 / _ \ _ __   ___ _ __ / ___/ _ \ / ___|  / \  |  _ \| ____|
| | | | '_ \ / _ \ '__| |  | | | | |  _  / _ \ | |_) |  _|  
| |_| | |_) |  __/ |  | |__| |_| | |_| |/ ___ \|  _ <| |___ 
 \___/| .__/ \___|_|   \____\___/ \____/_/   \_\_| \_\_____|
      |_|
LOGO
        echo -e "${gl_bai}"
        echo "======================================="
        echo -e "  OpenClaw Docker 管理脚本 v${sh_v}"
        echo "======================================="
        echo ""
        echo -e "${gl_kjlan}脚本向导选项:${gl_bai}"
        echo "------------------------"
        echo -e "${gl_kjlan}1.${gl_bai} Docker 环境管理 (安装/管理/卸载)"
        echo -e "${gl_kjlan}2.${gl_bai} OpenClaw 镜像构建向导"
        echo -e "${gl_kjlan}3.${gl_bai} OpenClaw 安装向导 (Compose+持久化)"
        echo -e "${gl_kjlan}4.${gl_bai} OpenClaw 容器管理 (全量功能)"
        echo "------------------------"
        echo -e "${gl_kjlan}0.${gl_bai} 退出"
        echo "------------------------"
        read -e -p "请输入你的选择: " choice
        case $choice in
            1) linux_docker ;;
            2) image_build_menu ;;
            3) install_wizard_menu ;;
            4) openclaw_container_menu ;;
            0) echo "再见!"; exit 0 ;;
            *) echo "无效的输入!"; sleep 1 ;;
        esac
    done
}

# ============================================================================
#  入口
# ============================================================================

# 当通过 `curl ... | bash` 执行时, stdin 是管道(脚本源码), 会导致脚本里的 read
# 误从管道读取. 这里检测 stdin 是否为 TTY, 若不是则重定向到 /dev/tty, 让交互式
# read 能正确读取用户键盘输入.
if [ ! -t 0 ] && [ -t 1 ]; then
    exec 0</dev/tty
fi

# 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${gl_huang}提示: 建议 root 用户运行此脚本${gl_bai}"
    echo -e "${gl_huang}部分功能 (如 Docker 安装、端口管理) 需要 root 权限${gl_bai}"
    read -e -p "是否继续? (y/N): " continue_run
    [[ ! "$continue_run" =~ ^[Yy] ]] && exit 1
fi

# 命令行参数支持
if [ "$#" -gt 0 ]; then
    case "$1" in
        docker|d)     linux_docker ;;
        image|img|i)  image_build_menu ;;
        install|wiz)  install_wizard_menu ;;
        oc|claw|openclaw) openclaw_container_menu ;;
        *) main_menu ;;
    esac
else
    main_menu
fi
