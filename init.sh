#!/bin/bash

# 检查输入参数
# 
if [ $# -lt 2 ]; then
    echo "Usage: $0 <port> <ports_number> [username] [password]"
    exit 1
elif [ $# -eq 2 ]; then
    xray_port=$1
    ports_number=$2
    authtype="noauth"
elif [ $# -eq 4 ]; then
    xray_port=$1
    ports_number=$2
    username=$3
    password=$4
    authtype="password"
else
    echo "Usage: $0 <port> <ports_number> [username] [password]"
    exit 1
fi

# 检查配置文件是否存在
if [ ! -d "config" ]; then
    mkdir config
    echo "Config directory created."
fi

# 检查是否安装了Docker
if ! command -v docker >/dev/null; then
    echo "Docker is not installed. Do you want to install it? (yes/no)"
    read -r answer
    if [ "$answer" = "yes" ]; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        rm get-docker.sh
    else
        echo "Docker is required. Exiting."
        exit 1
    fi
fi

# 检查是否安装了Docker Compose
if ! command -v docker-compose >/dev/null; then
    echo "Docker Compose is not installed. Do you want to install it? (yes/no)"
    read -r answer
    if [ "$answer" = "yes" ]; then
        # 获取最新版本
        COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | cut -d '"' -f 4)
        sudo curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    else
        echo "Docker Compose is required. Exiting."
        exit 1
    fi
fi

## 生成 torrc 配置文件的动态部分
start_port=58001
end_port=$((start_port + ports_number - 1))

ports_config=""
for ((port = $start_port; port <= $end_port; port++)); do
    printf -v ports_config '%s%s' "$ports_config" "SOCKSPort 0.0.0.0:$port" $'\n'
done

# 将动态生成的内容与静态内容合并并写入文件
cat > config/torrc <<EOL
${ports_config}
NewCircuitPeriod 30
CircuitBuildTimeout 10
%include /etc/torrc.d/*.conf
EOL
echo "Generated torrc with ports starting from $start_port for $ports_number ports."


# 生成config.json

# 生成服务器列表，最后一个端口不添加逗号
servers_list=""
for ((port = $start_port; port <= $end_port; port++)); do
    if [[ $port -eq $end_port ]]; then
        # 最后一个端口，不添加逗号
        printf -v servers_list '%s%s' "$servers_list" "{\"address\": \"tor-privoxy\", \"port\": $port}"
    else
        # 非最后一个端口，添加逗号和换行
        printf -v servers_list '%s%s' "$servers_list" "{\"address\": \"tor-privoxy\", \"port\": $port},"
    fi
    printf -v servers_list '%s%s' "$servers_list" $'\n'
done

# 使用EOL将静态部分和动态生成的服务器列表合并到config.json中
cat > config/config.json <<EOL
{
  "api": {
    "services": ["HandlerService", "LoggerService", "StatsService"],
    "tag": "api"
  },
  "dns": null,
  "fakeDns": null,
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"},
      "tag": "api"
    },
    {
      "listen": null,
      "port": $xray_port,
      "protocol": "socks",
      "settings": {
        "accounts": [{"pass": "${password}", "user": "${username}"}],
        "auth": "${authtype}",
        "ip": "127.0.0.1",
        "udp": false
      },
      "tag": "inbound-socks"
    }
  ],
  "log": {"error": "./error.log", "loglevel": "warning"},
  "outbounds": [
    {"protocol": "freedom", "settings": {}, "tag": "direct"},
    {
      "protocol": "socks",
      "settings": {
        "servers": [
$servers_list
        ]
      },
      "tag": "socks_out"
    },
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
      {"domain": ["regexp:.*"], "outboundTag": "socks_out", "type": "field"},
      {"ip": ["0.0.0.0/0", "::/0"], "outboundTag": "socks_out", "type": "field"},
      {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"},
      {"outboundTag": "blocked", "protocol": ["bittorrent"], "type": "field"}
    ]
  }
}
EOL

echo "config.json has been generated with dynamic port mappings."



# 生成 Docker Compose 文件
cat > docker-compose.yml <<EOL
version: '3'

services:
  xray:
    image: teddysun/xray:latest
    container_name: xray
    hostname: xray
    volumes:
      - ./config/config.json:/etc/xray/config.json
    tty: true
    restart: unless-stopped
    ports:
      - "$port:$port"
EOL

# 添加tor-privoxy服务并动态生成端口映射
echo "  tor-privoxy:" >> docker-compose.yml
echo "    restart: always" >> docker-compose.yml
echo "    image: peterdavehello/tor-socks-proxy:latest" >> docker-compose.yml
echo "    volumes:" >> docker-compose.yml
echo "      - ./config/torrc:/etc/tor/torrc" >> docker-compose.yml
echo "    ports:" >> docker-compose.yml

for ((p = $start_port; p <= $end_port; p++)); do
    echo "      - \"127.0.0.1:$p:$p\" # Tor SOCKS proxy" >> docker-compose.yml
done

# 清理并启动 Docker 容器
docker-compose down
docker-compose up -d
