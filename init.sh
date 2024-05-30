#!/bin/bash

# 检查输入参数,如何输入参数如果不是4，就打印提示。如果输入为4，就是设置的socks端口，socks代理的ip数量，访问的用户名和密码
if [ $# -ne 4 ]; then
    echo "Usage: $0 <port:6666> <ports_number:20> <user> <password>"
    exit 1
fi

myport=$1
ports_number=$2
user=$3
password=$4
authtype="password"

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
for (( i=0; i<$ports_number; i++ ))
do
    port=$((start_port + i))
    ports_config+="SOCKSPort 0.0.0.0:$port\n"
done
# Remove the trailing newline character from ports_config
ports_config=$(echo -e "$ports_config" | sed -e '$a\')


# 将动态生成的内容与静态内容合并并写入文件
cat > config/torrc <<EOL
${ports_config}
NewCircuitPeriod 30 #对于每个端口来说，每30秒重新创建一个新链路，也就是换一个新IP
CircuitBuildTimeout 10 #对于新建每个链路的过程来说，建立程序超过10秒则直接放弃，保障了连接到线路的质量
Log notice file /var/log/tor/notices.log
DataDirectory /var/lib/tor
ControlPort 9052
%include /etc/torrc.d/*.conf
EOL
echo "Generated torrc with ports starting from $start_port for $ports_number ports."

## 生成 config.json 配置文件的动态部分
for (( i=0; i<$ports_number; i++ ))
do
    port=$((start_port + i))
    if [ $i -eq $((ports_number - 1)) ]; then
        ports_config_json+="{\n    \"address\": \"tor-privoxy\",\n    \"port\": $port\n  }\n"
    else
        ports_config_json+="{\n    \"address\": \"tor-privoxy\",\n    \"port\": $port\n  },\n"
    fi
done
# Remove the trailing comma and newline
ports_config_json=$(echo -e "$ports_config_json" | sed '$s/,$//')

cat > config/config.json <<EOL
{
  "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ],
    "tag": "api"
  },
  "dns": null,
  "fakeDns": null,
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "sniffing": null,
      "streamSettings": null,
      "tag": "api"
    },
    {
      "listen": null,
      "port": $myport,
      "protocol": "socks",
      "settings": {
        "accounts": [
          {
            "pass": "$password",
            "user": "$user"
          }
        ],
        "auth": "$authtype",
        "ip": "127.0.0.1",
        "udp": false
      },
      "sniffing": null,
      "streamSettings": null,
      "tag": "inbound-31445"
    }
  ],
  "log": {
    "error": "./error.log",
    "loglevel": "warning"
  },
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "socks",
      "settings": {
        "servers": [
          $ports_config_json
        ]
      },
      "tag": "socks_out"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true
    }
  },
  "reverse": null,
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "domain": [
          "regexp:.*"
        ],
        "outboundTag": "socks_out",
        "type": "field"
      },
      {
        "ip": [
          "0.0.0.0/0",
          "::/0"
        ],
        "outboundTag": "socks_out",
        "type": "field"
      },
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked",
        "type": "field"
      },
      {
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ],
        "type": "field"
      }
    ]
  },
  "stats": {},
  "transport": null
}
EOL

for (( i=0; i<$ports_number; i++ ))
do
    port=$((start_port + i))
    tor_ports+="      - \"127.0.0.1:$port:$port\" \n"
done

# Remove the trailing newline character from ports_config
tor_ports=$(echo -e "$tor_ports" | sed -e '$a\')

# Generate the docker-compose.yml file
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
      - $myport:$myport

  tor-privoxy:
    restart: always
    image: peterdavehello/tor-socks-proxy:latest
    volumes:
      - ./config/torrc:/etc/tor/torrc
    ports:
$tor_ports
EOL
