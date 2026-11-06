# xiaomi-nas-app-docker

在小米 NAS(MINAS,aarch64)上把一个 WebUI 应用装成 docker 容器,挂 nginx 反代,再往厂商「应用中心」注册 icon,让手机 App 里点得开。

**轻量 Plan B**:自造注册表条目 + icon(非真 mpk、非 dockhand 全家桶)。仅自有设备;写注册表 / 动 docker 前先拿授权。

## 主线四步(装任意 WebUI 应用)
1. **docker 容器** — 限资源(512M/1.5C/128PID)、loopback 暴露、数据落 `/data/apps/`
2. **WebUI 定固定密码** — 部署时把密码哈希写进配置,免读启动日志(首启即固定,重启不变)
3. **nginx 反代** — 给浏览器 / LAN 访问
4. **应用中心注册** — icon + 条目 + **UI 伺服**(修"点进去 404"的核心)

## 内容
- [`SKILL.md`](./SKILL.md) — 完整流程 + 关键坑(tab 格式、厂商重写 `.list`、404 修法、访问日志验证、icon ≥256、aarch64 校验等)

## 适用 / 不适用
- ✅ 有 WebUI 的应用(下载 / 影音 / 媒体库)
- ❌ 厂商 App 内完整装/卸按钮(真 mpk,客户端只认官方签名渠道)、dockhand 全套管理
