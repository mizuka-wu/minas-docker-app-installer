---
name: xiaomi-nas-app-docker
description: "Xiaomi NAS: 装 WebUI 应用(docker + 反代 + 应用中心 icon)"
version: 2.0.0
author: wuyiwei
license: MIT
metadata:
  hermes:
    tags: [xiaomi, minas, nas, docker, nginx, app-center]
    related_skills: [xiaomi-nas-root-ssh]
---

# 小米 NAS 装 WebUI 应用(docker + 反代 + 应用中心 icon)

## 这是什么(What)
在小米 NAS(MINAS,aarch64)上,把一个**有 WebUI 的应用**装成三样东西,让它在手机「应用中心」里有 icon、点得开:

1. **一个 docker 容器** —— 应用本体,限资源、数据落 `/data`
2. **一个 nginx 反代** —— 给浏览器 / LAN 直接访问
3. **一条「应用中心」注册** —— 顶部 icon + 跳转条目 + UI 伺服(手机 App 点 icon 能进)

轻量 Plan B:自造注册表条目 + icon(非真 mpk、非 dockhand 全家桶);装/卸按钮是摆设,目标是 **icon 显示 + 点开能进 WebUI**。仅自有设备;写注册表 / 动 docker 前先拿授权。root 通道与完整注册表 schema(多账号 / 商店 / mTLS)→ 读 `xiaomi-nas-root-ssh`。

## 怎么做(How,`<app>` 占位,换应用只换这几处)

### 1) docker 容器 —— 把应用跑起来
```
mkdir -p /data/apps/<app>/{config,downloads}
/data/docker/docker run -d --name <app> --restart unless-stopped \
  --memory 512m --cpus 1.5 --pids-limit 128 \
  -p 127.0.0.1:<ctr>:<ctr> \
  -v /data/apps/<app>/config:/config \
  -v /data/apps/<app>/downloads:/downloads \
  <image:latest>
```
`<ctr>` = 容器内 WebUI 端口;只绑 `127.0.0.1`(交给反代,不上 LAN);想免反代直接 LAN 访问就 `--network host`。

### 2) nginx 反代 —— 浏览器 / LAN 能访问
写 `/etc/nginx/conf.d/<app>.conf`(标准树,`http{}` include 它):
```
server {
  listen <lan>;                       # ≥8200,先 ss -ltn 探空
  location / {
    proxy_pass http://127.0.0.1:<ctr>/;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```
`nginx -t && nginx -s reload`;`curl 127.0.0.1:<lan>` 回 200/302/401 都算通。

### 3) 应用中心注册 —— icon + 条目 + UI 伺服
- **先备份**:`cp /data/plugin/u<UID>.list /data/plugin/u<UID>.list.bak-$(date +%s)`(别用 vendor `.bak` 后缀)。
- **icon**:放 `/data/plugin/www/icon/<app>.icon`(内容=PNG)。来源优先级:① 从跑着的 WebUI 回环抓官方 PNG(`curl 127.0.0.1:<ctr>/<静态icon>`);② 复用 `/data/plugin/www/icon/<现成>.icon`;③ 官网 SVG 用 ImageMagick `convert -density 512 <svg> -resize 256x256 out.png`(≥256 才清晰)。源用**全路径**。
- **条目**:写进 `/data/plugin/u<UID>.list`(自装 docker 应用**无 `resource` 字段**;`id` 用 9000+ 避撞官方 1-18 与商店 1xxxx)。结构:顶层 `icon:/icon/<app>.icon` + `frontend`(title/type:url/permission/dev_type/url)+ `info`(plugin/name/id/port/tags/desc)。
- **UI 伺服(修"点进去 404"的关键)**:应用中心点 icon 后,实际是去 **`/plugin/<UID>/<app>/index.html`** 这个**相对路径**加载 UI(注意 `<UID>` **不带 `u`**),**不是**拨 `info.port`。这路径没 nginx 伺服 → 404。修法=在 **`/etc/nginx/conf.d/luci/`**(443 站点)加一个**前缀 location** 把 `/plugin/<UID>/<app>/` 代理到容器 WebUI:
```
location /plugin/<UID>/<app>/ {
  proxy_pass http://127.0.0.1:<ctr>/;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```
`nginx -t && nginx -s reload`。

## 环境事实(本机实测)
- **aarch64** → 镜像必须有 arm64 清单(linuxserver/* 基本都有;纯 amd64 别用)。验:`/data/docker/docker buildx imagetools inspect <img>` 看有没有 `linux/arm64`。
- **docker**:CLI 不在 PATH = `/data/docker/docker`;socket `/run/docker.sock`;data-root `/data/docker_data`。
- **root 通道**:瞬态 2323(`nc <NAS_IP> 2323`)或 `ssh -i <SSH_KEY> root@<NAS_IP>`;掉了重跑 xiaomi-nas-root-ssh 脚本 ~2min。
- **注册表**:`/data/plugin/u<UID>.list`(每账号一份);**App 请求路径里的 uid 不带 `u`**(如 `u<UID>.list` 的文件 ↔ `/plugin/<UID>/` 的路径)。
- **nginx**:标准树 `/etc/nginx/nginx.conf` 的 `http{}` → `include /etc/nginx/conf.d/*.conf`(反代丢这);`conf.d/luci/` 是 443 mTLS 站点(UI 伺服丢这);vendor `/etc/webdav/nginx/nginx.conf`(Samba/8081)**别碰**。
- **占用端口**:官方 9000/9100/9200、商店 18119 系、系统 80/443/8081/8083/8086;反代 ≥8200,装前 `ss -ltn` 探空。
- **落盘**:`/data` 持久(应用数据落 `/data/apps/<name>/`);`/var`=tmpfs(重启清,别放);`/`=erofs 只读;**用户数据池 `/home/<UID>/pool0/data` 绝不碰**。

## 回滚(反序)
```
/data/docker/docker rm -f <app>
rm -f /etc/nginx/conf.d/<app>.conf && nginx -t && nginx -s reload
rm -f /etc/nginx/conf.d/luci/<app>-uc.conf && nginx -t && nginx -s reload   # UI 伺服
# 注册表:恢复 .bak 备份 或 删该 key
rm -rf /data/apps/<app>     # 确认是他授权装的、无个人数据
```

## 关键坑(Pitfalls)
- ⚠️ **注册表是 tab 格式**(`\t"key":\t{`,冒号后 tab,中文原生 UTF-8);`json.dump(indent=N)` 写**空格**→**所有 icon 全没**(踩过)。改**手术式文本插入**:整文件当文本,严格 tab 拼条目,其他条目字节不动;写完校验无 `": "`。
- ⚠️ **厂商后端会主动重写 `.list`**(缩回 / 删自造条目)→ 手动注册**不持久**;被清按本流程重注册即可,不算故障。要持久得走厂商 mpk 安装机制(另题)。
- **打开机制**=应用中心按 `/plugin/<UID>/<app>/` 相对路径加载 UI(需第 3 步 UI 伺服);`info.port` 只是浏览器直连兜底;**别指望 `frontend.url` 绝对 URL**(SPA 接不住→404)。
- **回环在 80 测不到 UI 伺服**(它在 443 站点,80 必 404)→ 验证靠**访问日志**:让手机点一次,`grep /var/log/nginx/access.log` 看那条请求变 200;**真实路径以日志为准,别猜**。
- **前缀 location 可带 URI,正则 location 不行**(否则 `proxy_pass cannot have URI`)。
- **icon 太小不渲染**:WebUI 回环抓到的可能是 32px → 256×256 才清晰。
- **镜像没 arm64** → 拉下是 amd64,容器秒崩;先 `buildx imagetools inspect` 验。大陆拉 hub/ghcr 慢 → 重试,linuxserver 走 `lscr.io`。
- **端口撞** → 装前 `ss -ltn`;别拍脑袋 8080(常被占)。
- 写 `.list` 用 `os.replace` 原子替换 + chmod 644;别用 vendor `.bak` 命名(撞它每日 04:07 合并同步)。
- 用户 Mac 往 NAS 拷大文件时构建/全盘扫描会拖垮 2323 SSH → 探测保持轻量、timeout 给足。
