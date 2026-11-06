# minas-docker-app-installer

在小米 NAS 上把任意 **WebUI 应用**装成「docker 容器 + nginx 反代 + 应用中心 icon」,让手机「应用中心」里有图标、点得开。

## 这是什么
一个 Hermes Agent 技能([`SKILL.md`](./SKILL.md))+ 配套脚本([`ns-app.sh`](./ns-app.sh)),把"装一个有 WebUI 的应用到小米 NAS 应用中心"的完整流程沉淀成可复用步骤。轻量方案(自造注册表条目 + icon,非厂商真 mpk、非 dockhand 全家桶)。

## 做什么 —— 3 件事
| 产出 | 作用 |
|---|---|
| ① docker 容器 | 应用本体,限资源(512M/1.5C/128PID)、数据落 `/data/apps/<app>/` |
| ② nginx 反代 | 浏览器 / LAN 直接访问 WebUI |
| ③ 应用中心注册 | 顶置 icon + 跳转条目 + UI 伺服,手机 App 点 icon 能进 |

## 怎么做 —— 4 步
1. **`docker run`** 起容器(loopback 暴露、限资源、落盘)
2. **放 icon** 到 `/data/plugin/www/icon/<app>.icon`(WebUI 回环抓 / 复用 vendor / SVG 转 256)
3. **写反代** `/etc/nginx/conf.d/<app>.conf`(≥8200 端口)
4. **写应用中心注册** 条目(`/data/plugin/u<UID>.list`)+ **UI 伺服** location(`conf.d/luci/`,修"点进去 404")

全程走 root 通道(瞬态 2323),仅自有设备;详细命令、关键坑(tab 格式、厂商重写 `.list`、访问日志验证)、回滚步骤 → 见 [`SKILL.md`](./SKILL.md)。


## 卸载(uninstall)
装的反序,5 步(或用 `ns-app.sh uninstall <app>` 一键):
1. 删应用中心注册条目(还原装前备份)
2. 删 UI 伺服 `conf.d/luci/<app>-uc.conf` → `nginx -s reload`
3. 删反代 `conf.d/<app>.conf` → `nginx -s reload`
4. 删容器 `docker rm -f <app>`
5. 删数据 `rm -rf /data/apps/<app>`(⚠️ 先确认无个人数据)

## 要求 / 不适用
- ✅ 有 WebUI 的应用(下载 / 影音 / 媒体库),aarch64 架构
- ✅ 想要:应用中心里出现图标、点开能进 WebUI
- ❌ 厂商 App 内完整装/卸按钮(真 mpk,客户端只认官方签名渠道)
- ❌ dockhand 全套 Docker 管理(功能过多)
