#!/bin/bash
set -e

echo "正在安装 TCP-preconnection-relay v1.3..."

apt update
apt install -y nano curl build-essential

curl -L -o /root/tcp_pool.c \
https://raw.githubusercontent.com/Xeloan/TCP-preconnection-relay/main/tcp_pool.c

gcc -O2 -pthread -march=native -o /root/tcp_pool /root/tcp_pool.c

mkdir -p /etc/tcp_pool

cleanup_old_tcp_pool() {
    echo "正在清空旧版配置和服务..."

    mapfile -t units < <(
        {
            systemctl list-units --full --all --no-legend 'tcp-pool@*.service' 2>/dev/null | awk '{print $1}'
            systemctl list-unit-files --full --no-legend 'tcp-pool@*.service' 2>/dev/null | awk '{print $1}'
        } | sort -u
    )

    for unit in "${units[@]}"; do
        [ -n "$unit" ] || continue
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
    done

    rm -f /etc/tcp_pool/*.conf
    rm -f /etc/systemd/system/tcp-pool@.service

    systemctl daemon-reload || true
}

read -r -p "你是否要清空旧版配置？前一版本的用户必须清空，因为配置大改了。 [y/N]: " CLEAR_OLD
case "$CLEAR_OLD" in
    y|Y)
        cleanup_old_tcp_pool
        ;;
    *)
        true
        ;;
esac

cat > /etc/tcp_pool/relays.conf <<'EOF'
#REQUIRED
#转发标识，中括号内填写标签，比如US,HK1,HK2
[US]
#本地ip，如果监听v4网卡就填写0.0.0.0。如果是v6则为俩英文冒号::。只监听本机某个特定网卡ip就填那个ip就行，比如127.0.0.0，38.175.100.122。
LOCAL_IP=
#本地端口，记得ufw或者服务商的防火墙打开
LOCAL_PORT=
#远端ip，你转发的目标服务器，现在支持v6和域名
REMOTE_IP=
#远端的接收TCP的端口
REMOTE_TCP_PORT=
#远端的接收UDP的端口（如果你的服务端UDP和TCP跑在一个端口的，填写一样就行）
REMOTE_UDP_PORT=

#样例，看懂了删掉就行(ctrl k 快速一行行清除，小小白白可能不知道)。现在支持单文件多配置，格式就是标签加上后面一坨东西。
[JP]
LOCAL_IP=0.0.0.0
LOCAL_PORT=11451
REMOTE_IP=38.125.91.68
REMOTE_TCP_PORT=8888
REMOTE_UDP_PORT=9999

[HK]
LOCAL_IP=::
LOCAL_PORT=11451
REMOTE_IP=域名.com
REMOTE_TCP_PORT=8888
REMOTE_UDP_PORT=9999
EOF

cat > /usr/local/bin/tcp-pool-parse <<'EOF'
#!/bin/bash
set -euo pipefail

SRC="/etc/tcp_pool/relays.conf"
DST="/etc/tcp_pool"

[ -f "$SRC" ] || { echo "缺少 $SRC"; exit 1; }

mkdir -p "$DST"

current=""
declare -A section_seen
declare -A kv

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

reset_kv() {
    kv=(
        [LOCAL_IP]=""
        [LOCAL_PORT]=""
        [REMOTE_IP]=""
        [REMOTE_TCP_PORT]=""
        [REMOTE_UDP_PORT]=""
    )
}

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    (( p >= 1 && p <= 65535 )) || return 1
    return 0
}

validate_and_write_section() {
    [[ -n "$current" ]] || return 0

    local key
    for key in LOCAL_IP LOCAL_PORT REMOTE_IP REMOTE_TCP_PORT REMOTE_UDP_PORT; do
        if [[ -z "${kv[$key]}" ]]; then
            echo "[$current] 缺少: $key" >&2
            exit 1
        fi
    done

    is_valid_port "${kv[LOCAL_PORT]}" || {
        echo "[$current] 不合法 LOCAL_PORT: ${kv[LOCAL_PORT]}" >&2
        exit 1
    }
    is_valid_port "${kv[REMOTE_TCP_PORT]}" || {
        echo "[$current] 不合法 REMOTE_TCP_PORT: ${kv[REMOTE_TCP_PORT]}" >&2
        exit 1
    }
    is_valid_port "${kv[REMOTE_UDP_PORT]}" || {
        echo "[$current] 不合法 REMOTE_UDP_PORT: ${kv[REMOTE_UDP_PORT]}" >&2
        exit 1
    }

    local outfile="$DST/$current.conf"
    : > "$outfile"
    chmod 600 "$outfile"

    {
        printf 'LOCAL_IP=%s\n' "${kv[LOCAL_IP]}"
        printf 'LOCAL_PORT=%s\n' "${kv[LOCAL_PORT]}"
        printf 'REMOTE_IP=%s\n' "${kv[REMOTE_IP]}"
        printf 'REMOTE_TCP_PORT=%s\n' "${kv[REMOTE_TCP_PORT]}"
        printf 'REMOTE_UDP_PORT=%s\n' "${kv[REMOTE_UDP_PORT]}"
    } > "$outfile"
}

reset_kv

while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw%$'\r'}"
    line="$(trim "$line")"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == \;* ]] && continue

    if [[ "$line" =~ ^\[([A-Za-z0-9_-]+)\]$ ]]; then
        validate_and_write_section

        current="${BASH_REMATCH[1]}"
        if [[ -n "${section_seen[$current]:-}" ]]; then
            echo "你标签写重复了: [$current]" >&2
            exit 1
        fi
        section_seen["$current"]=1
        reset_kv
        continue
    fi

    if [[ -z "$current" ]]; then
        echo "你漏写标签了: $line" >&2
        exit 1
    fi

    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        echo "标签不合法，参考python变量名 [$current]: $line" >&2
        exit 1
    fi

    key="${BASH_REMATCH[1]}"
    val="$(trim "${BASH_REMATCH[2]}")"

    case "$key" in
        LOCAL_IP|LOCAL_PORT|REMOTE_IP|REMOTE_TCP_PORT|REMOTE_UDP_PORT)
            kv["$key"]="$val"
            ;;
        *)
            echo "[$current] 你写了个莫名奇妙的配置进来: $key" >&2
            exit 1
            ;;
    esac
done < "$SRC"

validate_and_write_section

echo "配置解析完成"
EOF

chmod +x /usr/local/bin/tcp-pool-parse

cat > /etc/systemd/system/tcp-pool@.service <<'EOF'
[Unit]
Description=High Performance TCP Connection Pool (C Version)
Wants=network-online.target
After=network-online.target xray.service

[Service]
ExecStart=/root/tcp_pool
EnvironmentFile=/etc/tcp_pool/%i.conf

Nice=-10
LimitNOFILE=65535

Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

true

echo ""
echo "========================================"
echo " Install completed!"
echo "========================================"
