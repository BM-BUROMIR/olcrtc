#!/usr/bin/env bash
# push_room.sh — control-plane → server (EPIC 2 #14).
# Пушит комнату на srv: правит room.id в конфиге + рестарт systemd-сервиса. Идемпотентен.
# Транспорт — SSH (у сервера обычный интернет, он не за whitelist).
#
#   ./push_room.sh --srv-host 84.252.140.183 --room "https://telemost.yandex.ru/j/<id>" \
#                  --ssh-key ~/unite/whitelist-bypass/.secrets/ssh/olc_access \
#                  [--config /etc/olc-bypass/tm-srv.yaml] [--service olc-telemost-srv.service]
#
# Ротация (cron на машине с cookie, НЕ на RU-VM — антифрод):
#   ROOM=$(python3 room_manager.py --cookies <hdr> --deployment <dep.json> --store rooms.json subscription | jq -r .room)
#   ./push_room.sh --srv-host 84.252.140.183 --room "$ROOM" --ssh-key <key>
#   # затем republish подписки: bootstrap.py publish --yc-bucket olc-bootstrap ...
set -euo pipefail
SRV_HOST=""; ROOM=""; SSH_KEY=""; SSH_USER=ubuntu
CONFIG=/etc/olc-bypass/tm-srv.yaml      # дефолт — telemost-стенд
SERVICE=olc-telemost-srv.service
while [[ $# -gt 0 ]]; do case "$1" in
  --srv-host) SRV_HOST="$2"; shift 2;;
  --room)     ROOM="$2"; shift 2;;
  --ssh-key)  SSH_KEY="$2"; shift 2;;
  --ssh-user) SSH_USER="$2"; shift 2;;
  --config)   CONFIG="$2"; shift 2;;
  --service)  SERVICE="$2"; shift 2;;
  *) echo "неизвестный аргумент: $1" >&2; exit 1;;
esac; done
[[ -n "$SRV_HOST" && -n "$ROOM" ]] || { echo "нужны --srv-host и --room" >&2; exit 1; }

SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20)
[[ -n "$SSH_KEY" ]] && SSH_OPTS=(-i "$SSH_KEY" "${SSH_OPTS[@]}")

ssh "${SSH_OPTS[@]}" "$SSH_USER@$SRV_HOST" \
  "sudo sed -i 's|id: \".*\"|id: \"$ROOM\"|' '$CONFIG' \
   && sudo systemctl restart '$SERVICE' \
   && echo \"srv $SRV_HOST → room $ROOM ($SERVICE restarted)\""
