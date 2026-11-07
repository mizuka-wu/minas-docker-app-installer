---
name: xiaomi-nas-app-docker
description: "Xiaomi NAS: 装 WebUI 应用(docker + 反代 + 应用中心 icon)"
version: 3.0.0
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
- **条目**:写进 `/data/plugin/u<UID>.list`(自装 docker 应用**无 `resource` 字段**;`id` 用 9000+ 避撞官方 1-18 与商店 1xxxx)。结构**顶层就 8 个字段**、严格对齐能用的 docker 条目(如 qB):`status=running` `install=true` `enable=true` `icon` `frontend` `info` `timestamp` `changetime`。**别加 `progress`/`error` 这些下载态字段**(那是带 `resource` 安装包的条目才有的;塞给 docker 应用会被应用中心读成"下载中 0%"、显示下载角标——实测踩坑)。`frontend.url` 用 `[{"dev_type":[1,2,3,4],"url":"/"}]`——厂商端拼接成 `/plugin/<UID>/<app>/`(带尾斜杠)。**空串会缺尾斜杠**(SPA 相对路径基准歪)、**`/index.html` 会让 SPA 把 index.html 当目录**(assets 全 404 位)——都实测踩过;绝对 URL 更不行。卡片不出时补 `online:true` `autograde:false`。
- **UI 伺服(修"点进去 404/超时"的关键)= 同源反代三件套**：在 **`/etc/nginx/conf.d/luci/`**(443 站点)写 `<app>-uc.conf`：
```
location = /plugin/<UID>/<app> { return 301 /plugin/<UID>/<app>/; }   # 补尾斜杠，否则落 vendor fcgi 301 风暴
location ^~ /plugin/<UID>/<app>/ {                                      # ^~ 才压得住厂商 regex location
    add_header Cache-Control "no-store";                                # 防 WebView 缓存旧壳
    proxy_pass http://127.0.0.1:<ctr>/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```
`nginx -t && nginx -s reload`。手机远程(厂商中继)和局域网双端同一条路可用(qB/AniRSS 双端实证)。前提：应用资源/API 是相对路径(`./`，主流 SPA 都如此；动手前 curl 首页确认)。`conf.d/luci` 规则有被 vendor 同步回收的先例，回收后卡片变超时——重跑 register 即恢复。

### 3b) 直连模式(备选：仅当应用资源走绝对路径、同源反代接不住时才用；此时**不要**写 `<app>-uc.conf`，否则请求被自家反代截走、cgi 摸不到)
不依赖 `conf.d/luci` 规则，四件套:
1. 容器端口**绑 LAN**:`-p <lan>:<ctr_port>`(手机 WebView 从手机侧发起,回环绑法手机打不开;仅限可信内网);
2. 容器 `pluginsrc/<app>/ui/` 放 `index.html`(内容=`<meta http-equiv="refresh" content="0;url=http://<NAS_IP>:<lan>/">` 自跳 SPA 老家,绕开资源相对路径坑)+ `<app>.cgi`(FILEURI 空/index.html→吐 index.html,其余按 `$FILEREQ` 静态伺服,`chmod +x`);
3. 条目 `frontend.url` 用 `[{"dev_type":[1,2,3,4],"url":"/index.html"}]`(**对齐厂商原生条目的写法**;只填 `/` 会让 plugin.cgi 找不到入口→400);
4. `resource.mpk` 可直接填 `http://<NAS_IP>:<lan>/`(应用中心接受 URL,健康检查用)。
调试 400 的顺序:先 `tail /var/log/nginx/access.log` 看手机那条请求的真实路径与 body 大小,再分清是 cgi 甩的 400 还是别的 server 块拒的——**本机 curl 443 的 400 ≠ 手机上那个 400**(走的不是同一个 server 块)。

### 4) 持久化守护 —— 防「点添加应用被清」(cron 自动补回)
厂商后端在你**点「添加应用」**时从**远端目录**重写 registry、把非目录条目(自装 docker 应用)清掉;本地改 `server.list` 目录没用(被远端冲)。解法=**守护清单 + cron**(不碰原厂服务):
- **清单** `/data/plugin/community-apps.json`:列要保的应用,每条 `{app, title, icon, url, port, id}`;**新增应用 = 加一条**,守护自动认。
- **守护脚本** `/data/plugin/keep-apps.py`:读清单,发现 registry 缺谁就**就地补回**(8 字段 docker 格式、整数时间戳;就地写、不 rename,不触发重写)。
- **cron**:`crontab` 加 `*/2 * * * * /usr/bin/python3 /data/plugin/keep-apps.py >/dev/null 2>&1`(每 2 分钟;点「添加应用」清掉后 2 分钟内复活,平时静默)。
> **清单 = 唯一事实源**:加/删应用只改清单,不用手动动注册表(守护会同步)。脚本+清单模板见本仓 `keep/`。

## 环境事实(本机实测)
- **aarch64** → 镜像必须有 arm64 清单(linuxserver/* 基本都有;纯 amd64 别用)。验:`/data/docker/docker buildx imagetools inspect <img>` 看有没有 `linux/arm64`。
- **docker**:CLI 不在 PATH = `/data/docker/docker`;socket `/run/docker.sock`;data-root `/data/docker_data`。
- **root 通道**:瞬态 2323(`nc <NAS_IP> 2323`)或 `ssh -i <SSH_KEY> root@<NAS_IP>`;掉了重跑 xiaomi-nas-root-ssh 脚本 ~2min。
- **注册表**:`/data/plugin/u<UID>.list`(每账号一份);**App 请求路径里的 uid 不带 `u`**(如 `u<UID>.list` 的文件 ↔ `/plugin/<UID>/` 的路径)。
- **nginx**:标准树 `/etc/nginx/nginx.conf` 的 `http{}` → `include /etc/nginx/conf.d/*.conf`(反代丢这);`conf.d/luci/` 是 443 mTLS 站点(UI 伺服丢这);vendor `/etc/webdav/nginx/nginx.conf`(Samba/8081)**别碰**。
- **占用端口**:官方 9000/9100/9200、商店 18119 系、系统 80/443/8081/8083/8086;反代 ≥8200,装前 `ss -ltn` 探空。
- **落盘**:`/data` 持久(应用**配置**落 `/data/apps/<name>/`);`/var`=tmpfs(重启清,别放);`/`=erofs 只读。**下载产出必须落用户库树 `/home/u<UID>/pool0/data`**(实体 `/nas/pool0/u<UID>/data`,fuse cfs)才进影音库/账号体系——`/data/apps` 在体系外,只能放配置。多应用共享下载目录:把该 data 目录挂进各容器的**相同容器内路径**(如都 `-v .../pool0/data:/media`),路径互传、同盘 mv 秒成;容器内 root 可写 fuse(touch 互通实测)。

## 卸载(uninstall,装的反序 5 步)
```
# 0) 先从守护清单删该应用(⚠️ 不删的话 cron 会把它补回来!)
#    编辑 /data/plugin/community-apps.json → 删掉该 app 那条
# 1) 删应用中心注册条目(恢复备份 或 删该 key)
cp /data/plugin/u<UID>.list.bak-<ts> /data/plugin/u<UID>.list     # 用装前那份备份还原
# 2) 删 UI 伺服(443 那个前缀 location)
rm -f /etc/nginx/conf.d/luci/<app>-uc.conf && nginx -t && nginx -s reload
# 3) 删反代
rm -f /etc/nginx/conf.d/<app>.conf && nginx -t && nginx -s reload
# 4) 删容器
/data/docker/docker rm -f <app>
# 5) 删数据(⚠️ 确认是他授权装的、且无个人数据)
rm -rf /data/apps/<app>
```
> `ns-app.sh uninstall <app>` 会按 1→5 自动跑(第 5 步删数据前脚本会提示确认)。


## 关键坑(Pitfalls)
- ⚠️ **应用中心 key 绝不能带连字符**(2026-11-07 实测):`.list` key = 目录名 = `INFO.plugin` 三处一致且**无 `-`**——`ani-rss` 打不开(400),改名 `anirss` 即好。
- ⚠️ **注册表格式**:早期实测"tab 格式手术式插入";2026-11-07 复测 `json.dump(o, f, indent=2, ensure_ascii=False)` 整体重写**也完全正常**(icon/条目都在,厂商同步兼容)——两种写法都有实证,关键是写完 `plugincenter -u u<UID> list` 回读 + 手机看 icon 验证。改前必备份(备份别用 vendor `.bak` 后缀)。
- ⚠️ **厂商后端会主动重写 `.list`**——**触发点 = 你点「添加应用」**(它从远端目录重写 registry、删自造条目;本地改 `server.list` 目录没用,会被远端冲)。手动注册**不持久**。**解法 = 第 4 步守护 cron**(清单 + 脚本,每 2 分钟自动补回);真·官方级持久需走厂商 mpk 机制(另题)。
- **打开机制**=应用中心按 `/plugin/<UID>/<app>/index.html` 相对路径加载 UI(走 UI 伺服或上面的直连模式);`frontend.url` 别填绝对 URL(会被拼进 `/plugin/` 前缀变成畸形路径),直连跳转在 index.html 里做。
- **Java/大应用冷启动 30-60s**:`docker run` 后立刻 curl 得 000 别急着判失败,等半分钟再验。
- **lscr qbittorrent 首启把临时 WebUI 密码打进容器日志**(grep `temporary password`),每次重启会变;WebAPI 可脚本化设置:`/api/v2/auth/login`(cookie jar)→ `setPreferences`(中文路径用 `--data-urlencode 'json={"save_path":"..."}'`)→ `defaultSavePath` 回读验证。
- **应用自带端口未必是 EXPOSE 的**(如 ani-rss EXPOSE 8300 但真实监听 7789)→ 起容器后看应用日志确认监听口再定映射。
- **换 icon 必须递增 `.list` 里 `?v=N` 缓存号**(icon 与 frontend.icon 两处),否则米家 App 永远显示旧图;Mac 侧出 300×300 PNG:`.ico` 用 `sips -s format png -z 300 300 in.ico --out out.png`,`.svg` 用 `qlmanage -t -s 300 -o . in.svg`;渲染完整性别只信 vision 模型,解 PNG 看主色簇+透明占比更靠谱。
- **回环在 80 测不到 UI 伺服**(它在 443 站点,80 必 404)→ 验证靠**访问日志**:让手机点一次,`grep /var/log/nginx/access.log` 看那条请求变 200;**真实路径以日志为准,别猜**。
- **前缀 location 可带 URI,正则 location 不行**(否则 `proxy_pass cannot have URI`)。
- **icon 太小不渲染**:WebUI 回环抓到的可能是 32px → 256×256 才清晰。
- **镜像没 arm64** → 拉下是 amd64,容器秒崩;先 `buildx imagetools inspect` 验。大陆拉 hub/ghcr 慢 → 重试,linuxserver 走 `lscr.io`。
- **端口撞** → 装前 `ss -ltn`;别拍脑袋 8080(常被占)。
- 写 `.list` 优先**就地覆盖**(改完直写原文件,或 `cp .tmp .list`),**别用 `os.replace` rename**(删了重建)——实测 rename 会触发厂商后端重写、把刚加的第三方条目清掉(qb/ani-rss 就是这样没的);chmod 644;备份别用 vendor `.bak` 命名(撞它每日 04:07 合并同步)。
- 用户 Mac 往 NAS 拷大文件时构建/全盘扫描会拖垮 2323 SSH → 探测保持轻量、timeout 给足。
