#!/usr/bin/env bash
# minas-docker-app-installer: 在小米 NAS 上一键装/卸 WebUI 应用进「应用中心」。
# 用法(在 NAS root 通道里跑):
#   ./ns-app.sh register <app> <ctr_port> <lan_port> <image> [icon_src]
#   ./ns-app.sh uninstall <app>
#   ./ns-app.sh list
set -euo pipefail
DOCKER="/data/docker/docker"
NGINX_CONF="/etc/nginx/conf.d"
NGINX_LUCI="/etc/nginx/conf.d/luci"
ICON_DIR="/data/plugin/www/icon"

register() {
  local app="$1" ctr="$2" lan="$3" image="$4" icon="${5:-}"
  echo "==> 1/4 起容器 $app ($ctr->$lan)"
  mkdir -p "/data/apps/$app/{config,downloads}"
  $DOCKER rm -f "$app" 2>/dev/null || true
  $DOCKER run -d --name "$app" --restart unless-stopped \
    --memory 512m --cpus 1.5 --pids-limit 128 \
    -p "127.0.0.1:$ctr:$ctr" \
    -v "/data/apps/$app/config:/config" \
    -v "/data/apps/$app/downloads:/downloads" "$image"
  echo "==> 2/4 反代 $lan"
  cat > "$NGINX_CONF/$app.conf" <<EOF
server {
  listen $lan;
  location / {
    proxy_pass http://127.0.0.1:$ctr/;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  }
}
EOF
  echo "==> 3/4 icon"
  [ -n "$icon" ] && cp "$icon" "$ICON_DIR/$app.icon" || echo "   (未提供 icon_src,跳过;可稍后放 $ICON_DIR/$app.icon)"
  echo "==> 4/4 注册 + UI 伺服"
  python3 - "$app" "$lan" "$ctr" <<'PY'
import json, os, sys, datetime
app, lan, ctr = sys.argv[1], sys.argv[2], sys.argv[3]
p = "/data/plugin/u%s.list" % os.environ.get("MINAS_UID", "98067140")
b = p + ".bak-%d" % int(datetime.datetime.now().timestamp())
os.replace(p, b) if os.path.exists(p) else None
raw = open(b).read() if os.path.exists(b) else "{}"
# 找到最后一个完整 JSON 对象
obj, _ = json.JSONDecoder().raw_decode(raw)
now = datetime.datetime.now().isoformat()
obj[app] = {
  "status": "running", "install": True, "enable": True, "progress": "0",
  "icon": "/icon/%s.icon" % app,
  "frontend": {"icon": "/%s.icon" % app, "title": app, "type": "url",
    "dev_type": [1,2,3,4], "url": [{"dev_type": [1,2,3,4], "url": "http://0.0.0.0:%s/" % lan}],
    "sortid": 1, "permission": ["admin"], "widget": []},
  "info": {"plugin": app, "name": app, "id": "90%02d" % (len(obj) % 100), "version": "1.0.0",
    "port": lan, "type": "standard", "system": False, "tags": ["tool"],
    "publisher": "", "developer": "", "desc": "installed via minas-docker-app-installer",
    "changelog": "", "timestamp": now, "size": 0, "ext": {}},
  "changetime": now, "error": {"errno": 0, "laststatus": "running"},
}
t = p + ".tmp"
json.dump(obj, open(t, "w"), indent=2, ensure_ascii=False)
os.replace(t, p); os.chmod(p, 0o644)
print("registered", len(obj), "entries ->", p)
PY
  # UI 伺服(修 404):前缀 location 代理到容器 WebUI
  local uid="${MINAS_UID:-98067140}"
  cat > "$NGINX_LUCI/$app-uc.conf" <<EOF
location /plugin/$uid/$app/ {
  proxy_pass http://127.0.0.1:$ctr/;
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF
  nginx -t && nginx -s reload
  echo "==> 完成: $app 反代:$lan / UI:/plugin/$uid/$app/"
}

uninstall() {
  local app="$1" uid="${MINAS_UID:-98067140}"
  $DOCKER rm -f "$app" 2>/dev/null || true
  rm -f "$NGINX_CONF/$app.conf" "$NGINX_LUCI/$app-uc.conf" "$ICON_DIR/$app.icon"
  nginx -t && nginx -s reload
  python3 - "$app" <<'PY'
import json, os, sys
app = sys.argv[1]
p = "/data/plugin/u%s.list" % os.environ.get("MINAS_UID", "98067140")
if not os.path.exists(p): print("no registry"); sys.exit(0)
t = p + ".tmp"; raw = open(p).read()
obj, _ = json.JSONDecoder().raw_decode(raw)
obj.pop(app, None)
json.dump(obj, open(t, "w"), indent=2, ensure_ascii=False)
os.replace(t, p); os.chmod(p, 0o644)
print("unregistered", app)
PY
  rm -rf "/data/apps/$app"   # ⚠️ 确认无个人数据
  echo "==> 已卸 $app(容器/反代/UI/icon/注册/数据)"
}

case "${1:-}" in
  register)  register "${2:?app}" "${3:?ctr_port}" "${4:?lan_port}" "${5:?image}" "${6:-}" ;;
  uninstall) uninstall "${2:?app}" ;;
  list)      grep -oE '"[a-zA-Z0-9_-]+":\t' "/data/plugin/u${MINAS_UID:-98067140}.list" 2>/dev/null | tr -d '":' | sort -u || echo "(注册表不存在)" ;;
  *) echo "用法: $0 register <app> <ctr_port> <lan_port> <image> [icon_src] | uninstall <app> | list" ;;
esac
