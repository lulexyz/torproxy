# 一键搭建Tor动态代理

## 部署
linux下，只需一条命令即可
```bash
sudo ./init.sh 1234 5 user pass   #在1234端口开启5个socks5代理，需要帐号密码认证，帐号密码为: user/pass
```
## 测试
假设本机ip为x.x.x.x，运行：
```
while true; do curl -x socks5://user:pass@x.x.x.x:1234 ip.sb;done
```
设置NewCircuitPeriod=30，对于每个tor端口来说，每30秒重新创建一个新链路，也就是换一个新IP
CircuitBuildTimeout=10，对于新建每个链路的过程来说，建立程序超过10秒则直接放弃，保障了连接到线路的质量

## 使用
使用方式为正常的socks5使用方法，因为使用的xray对tor进行中转，其它协议也是支持的，修改init.sh中的config.json即可
