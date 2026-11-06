#!/usr/bin/env python3
# 社区应用守护:后端(点"添加应用"时)按远端目录重写 registry、清掉非目录条目;
# 本脚本读清单 community-apps.json,发现条目被清就就地补回(8 字段 docker 格式,整数时间戳)。
# cron 每 2 分钟跑一次。新增应用 = 往清单里加一条。
import json, os, time, sys

MANIFEST = "/data/plugin/community-apps.json"
REGISTRY = "/data/plugin/u98067140.list"  # 清单里可用 registry 字段覆盖

def load(p):
    with open(p) as f:
        o, _ = json.JSONDecoder().raw_decode(f.read())
    return o

def save(p, o):
    # 就地覆盖(不 rename):rename 会触发厂商后端重写
    with open(p, "w") as f:
        json.dump(o, f, indent=2, ensure_ascii=False)
    os.chmod(p, 0o644)

def main():
    m = load(MANIFEST)
    reg_path = m.get("registry", REGISTRY)
    reg = load(reg_path)
    now = int(time.time())
    added = []
    for a in m.get("apps", []):
        if a["app"] in reg:
            continue  # 还在,不动
        reg[a["app"]] = {
            "status": "running", "install": True, "enable": True,
            "icon": a.get("icon", "/icon/" + a["app"] + ".icon"),
            "frontend": {
                "title": a.get("title", a["app"]), "type": "url",
                "permission": ["admin"], "dev_type": [1, 2, 3, 4],
                "url": [{"dev_type": [1, 2, 3, 4], "url": a.get("url", "/plugin/98067140/" + a["app"] + "/")}],
                "sortid": a.get("id", 9000), "widget": [],
            },
            "info": {
                "plugin": a["app"], "name": a.get("title", a["app"]),
                "id": a.get("id", 9000), "version": "1.0.0",
                "port": str(a.get("port", "")), "type": "standard",
                "system": False, "tags": ["tool"],
                "ext": {"admin": True}, "timestamp": now,
            },
            "timestamp": now, "changetime": now,
        }
        added.append(a["app"])
    if added:
        save(reg_path, reg)
        sys.stderr.write("keep-apps: re-added %s\n" % ",".join(added))
    # 静默:没东西补就不输出(避免日志噪音)

if __name__ == "__main__":
    main()
