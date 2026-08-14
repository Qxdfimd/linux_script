# Qxdfimd的快速维护脚本
**支持多发行版**

## 主脚本
自动安装依赖，显示系统信息，功能如下
01. 初始化（设置hostname，更新系统），只需运行一次
02. 设置ZRAM & SWAP为RAM:ZRAM:SWAP = 1:1:1
03. 申请IP证书（HTTP-01）
04. 申请域名证书（HTTP-01，DNS-01）
05. 安装mdserver-web
06. 安装nezha-dashboard
07. 安装3X-UI
08. 安装S-UI
09. 安装AList
```
bash <(curl -Ls https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/run.sh)
```

## 初始化
设置hostname，更新系统
```
bash <(curl -Ls https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/init.sh)
```

## 设置ZRAM & SWAP
设置ZRAM & SWAP为RAM:ZRAM:SWAP = 1:1:1
ZRAM算法顺序 zstd>lz4hc>lzo-rle>lz4>lzo
```
bash <(curl -Ls https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/zram_swap.sh)
```

## 申请IP证书
支持 HTTP-01
HTTP-01   - standalone   (自动监听80端口)
          - webroot     (使用网站根目录)
支持 IPv4单栈 / IPv6单栈 / 双栈
```
bash <(curl -Ls https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/ip_cert.sh)
```

## 申请域名证书
支持 HTTP-01 / DNS-01
HTTP-01   - standalone   (自动监听80端口)
          - webroot     (使用网站根目录)
DNS-01    - Cloudflare   (自动添加TXT记录)
          - 手动模式     (手动添加TXT记录)
支持 IPv4单栈 / IPv6单栈 / 双栈
```
bash <(curl -Ls https://raw.githubusercontent.com/Qxdfimd/linux_script/refs/heads/main/domain_cert.sh)
```
