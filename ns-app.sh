#!/usr/bin/env bash
# minas-docker-app-installer v3: 在小米 NAS 上一键装/卸 WebUI 应用进「应用中心」。
# 端口自选(避开厂商 80/443/8001 等端口池即可)；应用中心入口走同源反代，手机远程/局域网双端可用。
# 用法(在 NAS root 通道里跑):
#   MINAS_UID=<你的米家数字UID> ./ns-app.sh register <app> <ctr_port> <lan_port> <image> [icon_src]
#   MINAS_UID=<你的米家数字UID> ./ns-app.sh uninstall <app>
#   MINAS_UID=<你的米家数字UID> ./ns-app.sh list
set -euo pipefail
DOCKER="/data/docker/docker"
NGINX_CONF="/etc/nginx/conf.d"
NGINX_LUCI="/etc/nginx/conf.d/luci"
ICON_DIR="/data/plugin/www/icon"

register() {
  local app="$1" ctr="$2" lan="$3" image="$4" icon="${5:-}"
  [[ "$app" =~ ^[a-z][a-z0-9_]{0,31}$ ]] || { echo "app 名必须是小写字母开头的 [a-z0-9_]，≤32 字符(厂商 .list key 校验，连字符会被洗)"; exit 1; }
  echo "==> 1/4 起容器 $app ($lan->$ctr)"
  mkdir -p "/data/apps/$app/{config,downloads}"
  $DOCKER rm -f "$app" 2>/dev/null || true
  # lan 可以是 8300 或 127.0.0.1:8300(仅本机)；别撞厂商端口池(80/443/8001/8080 等)
  $DOCKER run -d --name "$app" --restart unless-stopped \
    --memory 512m --cpus 1.5 --pids-limit 128 \
    -p "$lan:$ctr" \
    -v "/data/apps/$app/config:/config" \
    -v "/data/apps/$app/downloads:/downloads" "$image"
  echo "==> 2/4 出网自检(bridge 容器需 MASQUERADE)"
  iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE || \
    echo "   ⚠️ 无 MASQUERADE：bridge 容器无法出网。修法：iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o \$(ip route | awk '/default/{print \$5; exit}') -j MASQUERADE"
  echo "==> 3/4 icon"
  [ -n "$icon" ] && cp "$icon" "$ICON_DIR/$app.icon" || echo "   (未提供 icon_src,跳过;可稍后放 $ICON_DIR/$app.icon)"
  echo "==> 4/4 注册 + UI 伺服"
  python3 - "$app" "$lan" "$ctr" <<'PY'
import json, os, sys, time, shutil
app, lan, ctr = sys.argv[1], sys.argv[2], sys.argv[3]
uid = os.environ.get("MINAS_UID") or sys.exit("请设 MINAS_UID 环境变量(你的米家数字 UID)")
p = "/data/plugin/u%s.list" % uid
b = p + ".pre-register"
shutil.copy(p, b) if os.path.exists(p) else None
raw = open(p).read() if os.path.exists(p) else "{}"
# 找到最后一个完整 JSON 对象
obj, _ = json.JSONDecoder().raw_decode(raw)
now = int(time.time())
# 出卡字段组=硬门槛(缺任一→整卡不显示,2026-11-07 实证)：online/autograde/顶层 timestamp(int)/
# frontend.url 数组形(裸串静默丢卡)/sortid=info.id 数值/permission/widget 数组/info.ext.admin/id 数值
pid = 9000 + len(obj) % 100
obj[app] = {
  "status": "running", "install": True, "enable": True,
  "online": True, "autograde": False, "progress": "100",
  "icon": "/icon/%s.icon" % app,
  "frontend": {"icon": "/%s.icon" % app, "title": app, "type": "url",
    "dev_type": [1,2,3,4], "url": [{"dev_type": [1,2,3,4], "url": "/"}],
    "sortid": pid, "permission": ["admin"], "widget": []},
  "info": {"plugin": app, "name": app, "id": pid, "version": "1.0.0",
    "port": lan, "type": "standard", "system": False, "tags": ["tool"],
    "publisher": "", "developer": "", "desc": "installed via minas-docker-app-installer",
    "changelog": "", "timestamp": now, "size": 0, "ext": {"admin": True}},
  "timestamp": now, "changetime": now,
}
json.dump(obj, open(p, "w"), indent=2, ensure_ascii=False)
os.chmod(p, 0o644)
print("registered", len(obj), "entries ->", p)
PY
  # 同源反代(应用中心 WebView 正门)：=301 补尾斜杠(缺了 SPA 相对路径基准会歪)、^~ 压厂商 regex、no-store 防 WebView 缓存
  local uid="${MINAS_UID:?}"
  cat > "$NGINX_LUCI/$app-uc.conf" <<EOF
location = /plugin/$uid/$app {
    return 301 /plugin/$uid/$app/;
}
location ^~ /plugin/$uid/$app/ {
    add_header Cache-Control "no-store";
    proxy_pass http://127.0.0.1:$ctr/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
}
EOF
  nginx -t && nginx -s reload
  echo "==> 完成: $app 直连:http://NAS:$lan / 应用中心同源:/plugin/$uid/$app/"
}

uninstall() {
  local app="$1" uid="${MINAS_UID:?}"
  $DOCKER rm -f "$app" 2>/dev/null || true
  rm -f "$NGINX_CONF/$app.conf" "$NGINX_LUCI/$app-uc.conf" "$ICON_DIR/$app.icon"
  nginx -t && nginx -s reload
  python3 - "$app" <<'PY'
import json, os, sys
app = sys.argv[1]
uid = os.environ.get("MINAS_UID") or sys.exit("请设 MINAS_UID 环境变量(你的米家数字 UID)")
p = "/data/plugin/u%s.list" % uid
if not os.path.exists(p): print("no registry"); sys.exit(0)
raw = open(p).read()
obj, _ = json.JSONDecoder().raw_decode(raw)
obj.pop(app, None)
json.dump(obj, open(p, "w"), indent=2, ensure_ascii=False)
os.chmod(p, 0o644)
print("unregistered", app)
PY
  rm -rf "/data/apps/$app"   # ⚠️ 确认无个人数据
  echo "==> 已卸 $app(容器/反代/UI/icon/注册/数据)"
}

case "${1:-}" in
  register)  register "${2:?app}" "${3:?ctr_port}" "${4:?lan_port}" "${5:?image}" "${6:-}" ;;
  uninstall) uninstall "${2:?app}" ;;
  list)      grep -oE '"[a-zA-Z0-9_-]+":\t' "/data/plugin/u${MINAS_UID:?}.list" 2>/dev/null | tr -d '":' | sort -u || echo "(注册表不存在)" ;;
  *) echo "用法: $0 register <app> <ctr_port> <lan_port> <image> [icon_src] | uninstall <app> | list" ;;
esac
