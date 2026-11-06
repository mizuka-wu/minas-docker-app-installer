---
name: xiaomi-nas-app-docker
description: "Xiaomi NAS: 装 docker 应用 + nginx 反代 + 应用中心 icon 三步"
version: 1.1.0
author: wuyiwei
license: MIT
metadata:
  hermes:
    tags: [xiaomi, minas, nas, docker, nginx, app-center]
    related_skills: [xiaomi-nas-root-ssh]
---

# 小米 NAS 装 docker 应用(反代 + 应用中心 icon)

在用户小米 NAS(MINAS,aarch64)把一个 WebUI 应用装成 docker 容器,挂 nginx 反代,再往厂商「应用中心」注册 icon 让手机 App 里点得开。**轻量 Plan B**:自造注册表条目 + icon(非真 mpk、非 dockhand 全家桶)。仅自有设备;写注册表/动 docker 前先拿授权。root 通道、完整注册表 schema(多账号 / nijez 商店 / mTLS)→ 读 `xiaomi-nas-root-ssh`。

## When to Use
在小米 NAS 上加一个**有 WebUI 的应用**(下载/影音/媒体库那类),想让它出现在「应用中心」有 icon 点开能用,或要装 docker 容器 / 配 nginx 反代。不适合:要厂商 App 内完整装/卸按钮(真 mpk,客户端只认官方签名渠道,死路)、或要 dockhand 全套管理(功能过多,已明确不走)。

## 环境事实(本机 192.168.3.125 实测)
- **aarch64** → 镜像必须有 arm64 清单(linuxserver/* 基本都有;纯 amd64 别用)。验:`/data/docker/docker buildx imagetools inspect <img>` 看有没有 `linux/arm64`。
- **docker**:CLI 不在 PATH = `/data/docker/docker`;socket `/run/docker.sock`;data-root `/data/docker_data`。
- **root 通道**:瞬态 2323(`nc <IP> 2323`)或 `ssh -i ~/.ssh/id_ed25519_minas root@<IP>`;掉了重跑 xiaomi-nas-root-ssh 脚本 ~2min。
- **注册表**:`/data/plugin/u<uid>.list`(本用户 `u98067140.list`);icon `/data/plugin/www/icon/<name>.icon`(内容=PNG,扩展名随意);**注意 App 请求路径里的 uid 不带 `u`**(如 `98067140`)。
- **nginx**:标准树 `/etc/nginx/nginx.conf` 的 `http{}` → `include /etc/nginx/conf.d/*.conf` → **反代丢 `/etc/nginx/conf.d/<app>.conf`**。vendor `/etc/webdav/nginx/nginx.conf`(Samba/8081)**别碰**;`conf.d/luci/` 是 443 mTLS 那套(应用中心 UI 伺服也在这)。
- **端口**:官方 9000/9100/9200、商店 18119 系、系统 80/443/8081/8083/8086 占着。反代端口 ≥8200;装前 `ss -ltn` 探空。
- **落盘**:`/data` 持久(应用数据落 `/data/apps/<name>/`);`/var`=tmpfs(重启清);`/`=erofs 只读;**用户数据池 `/home/u98067140/pool0/data` 绝不碰**。

## 主线四步(装一个 WebUI 应用,`<app>` 占位)

### 1) docker 容器
```
mkdir -p /data/apps/<app>/{config,downloads}
/data/docker/docker run -d --name <app> --restart unless-stopped \
  --memory 512m --cpus 1.5 --pids-limit 128 \
  -p 127.0.0.1:<ctr>:<ctr> \
  -v /data/apps/<app>/config:/config \
  -v /data/apps/<app>/downloads:/downloads \
  <image:latest>
```
换应用换 镜像/端口/挂载;`downloads` 指用户要的位置(要进他的池先问);资源上限仿 nijez(512M/1.5C/128PID)别裸奔;容器名用可读的(卸载按名)。`-p 127.0.0.1:<ctr>` 只暴露给反代;想直接 LAN 访问改 `--network host` 免反代。

### 2) WebUI 定固定密码(免读启动日志,关键)
很多 linuxserver/应用镜像首启**不预设密码、打一个临时密码到日志**——手机上看不到容器日志就等于拿不到。正解=**部署时把密码哈希写进配置**,首启即固定。以 PBKDF2 类 WebUI 为例:停容器 → 往配置 `[WebUI]` 段写 `Username=<u>` + `Password_PBKDF2=@ByteArray(<16B盐b64>:<64B键b64>)`(PBKDF2-HMAC-SHA512/100000 轮)→ 起容器 → curl 登录验证。Mac 端 `hashlib.pbkdf2_hmac('sha512',b'pw',os.urandom(16),100000)` 算,再 `base64`。写完**停→改→起**顺序,别在运行态改(退出会重写覆盖)。验证登进去能拿到会话(问个只读接口)即成。

### 3) nginx 反代(给浏览器/LAN 用)
写 `/etc/nginx/conf.d/<app>.conf`:`server{ listen <lan>; location /{ proxy_pass http://127.0.0.1:<ctr>; ... } }` → `nginx -t && nginx -s reload` → `curl 127.0.0.1:<lan>` 200/302/401 都算通。8200 起挑空端口。

### 4) 应用中心注册(icon + 条目 + **UI 伺服**)
**先备份**:`cp /data/plugin/u98067140.list /data/plugin/u98067140.list.bak-$(date +%s)`(别用 vendor 的 `.bak` 后缀)。
**icon**:首选从跑着的应用 WebUI 回环抓官方 PNG(`curl 127.0.0.1:<ctr>/<静态icon>`);或复用 `/data/plugin/www/icon/<现成>.icon`;或官网 SVG 用 ImageMagick `convert -density 512 <svg> -resize 256x256 out.png` 生成(≥256 才清晰,32px 在网格里糊成点)。源用**全路径**(相对路径 `cp "$(ls|head -1)"` 会 CWD 不对 `cannot stat`)。放到 `/data/plugin/www/icon/<app>.icon`。
**条目**:自装 docker 应用 = **无 `resource` 字段**;`id` 用 9000+ 避撞官方 1-18 与 nijez 1xxxx。顶层 `icon:/icon/<app>.icon` + `frontend`(title/type:url/permission/dev_type/url) + `info`(plugin/name/id/port/tags/desc)。走 2323 单行通道先把 python 写 `/tmp/reg.py` 再跑,别直接喂 heredoc。
**UI 伺服(关键,修 404)**:应用中心点 icon 后是去 `/plugin/<uid>/<app>/index.html` 这个**相对路径**加载 UI(uid **不带 `u`**),**不是**拨 `info.port`。若这路径没 nginx 伺服 → **404**。修法=在 **`/etc/nginx/conf.d/luci/`**(443 站点)加一个**前缀 location** 把 `/plugin/<uid>/<app>/` 代理到容器 WebUI:
```
location /plugin/98067140/<app>/ {
  proxy_pass http://127.0.0.1:<ctr>/;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```
`nginx -t && nginx -s reload`。注意:① 前缀 location 可带 URI,正则 location 不行(会 `proxy_pass cannot have URI`);② **回环在 80 测不到这个 location**(它在 443 站点,80 必 404)——验证要靠**访问日志**:让手机点一次,grep `/var/log/nginx/access.log` 看那条请求变 200。真实请求路径以日志为准,别猜(曾猜 `u98067140` 错、实为 `98067140`)。

## 回滚(反序)
```
/data/docker/docker rm -f <app>
rm /etc/nginx/conf.d/<app>.conf && nginx -t && nginx -s reload
rm /etc/nginx/conf.d/luci/<app>-uc.conf && nginx -t && nginx -s reload   # UI 伺服
# 注册表:恢复备份 或 删该 key
rm -rf /data/apps/<app>    # 确认是他授权装的、无个人数据
```

## 预期与 Pitfalls
- ⚠️ **注册表是 tab 格式**(`\t"key":\t{`,冒号后 tab,中文原生 UTF-8);`json.dump(indent=N)` 写**空格**→**所有 icon 全没**(踩过,已回滚)。改**手术式文本插入**:整文件当文本,严格 tab 拼条目,其他条目字节不动;写完校验无 `": "`。
- ⚠️ **厂商后端会主动重写 `.list`**(缩回/删自造条目)→ 手动注册**不持久**;被清按本流程重注册,不算故障。要持久得走厂商 mpk 安装机制(另题)。
- **打开机制**=应用中心按 `/plugin/<uid>/<app>/` 相对路径加载 UI(需第 4 步 UI 伺服);`info.port` 是浏览器直连兜底;**别指望 `frontend.url` 绝对 URL**(SPA 接不住→404)。
- icon 太小不渲染:WebUI 回环抓到的可能是 32px 小图 → 256×256 才清晰(官网 SVG + ImageMagick 转换最稳)。
- 镜像没 arm64 → 拉下是 amd64,容器秒崩;先 `buildx imagetools inspect` 验。大陆拉 hub/ghcr 慢 → 重试,linuxserver 走 `lscr.io`。
- 端口撞 → 装前 `ss -ltn`;别拍脑袋 8080(常被占)。
- 写 `.list` 用 `os.replace` 原子替换 + chmod 644;别用 vendor `.bak` 命名(撞它每日 04:07 合并同步)。
- 反代写 `/etc/nginx/conf.d/*.conf`(http 顶层 include 只匹配文件不匹配子目录);UI 伺服写 `conf.d/luci/`(443)。vendor webdav 那套**别碰**。
- 用户 Mac 往 NAS 拷大文件时构建/全盘扫描会拖垮 2323 SSH → 探测保持轻量、timeout 给足。
