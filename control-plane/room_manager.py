#!/usr/bin/env python3
"""RoomManager — ядро control-plane (EPIC 2 #13).

Держит живую Telemost-комнату для одного deployment'а (server+client делят room+channel+key):
- ensure_current(): если текущей комнаты нет / она мертва / истекает в окне overlap → создаёт новую.
- старую комнату не убиваем сразу (overlap) — даём клиентам/серверу доплыть до новой.
- персист в rooms.json; эмит subscription (то, что клиент тянет из whitelisted-bootstrap).

Идентичность туннеля (channel, crypto.key, carrier, transport, server-list) — КОНСТАНТЫ deployment'а,
ротируется только room.uri. Они задаются в deployment.json.

Push новой комнаты серверу (#14, рестарт olcrtc-srv с новым room.id) и публикация подписки в
Telegram/Storage (#15/#16) — отдельные модули; здесь — лайфсайкл комнаты + генерация подписки.
"""
from __future__ import annotations
import json
import os
import time
from dataclasses import dataclass, asdict

from telemost_client import TelemostClient, load_cookie_header, ROOM_TTL_SEC

# за сколько до истечения создавать смену (overlap-окно)
ROTATE_BEFORE_SEC = 2 * 3600  # 2ч


@dataclass
class Deployment:
    """Константы туннеля для одного deployment'а (НЕ ротируются)."""
    name: str
    carrier: str          # telemost
    channel: str          # общий ярлык канала srv<->cnc
    crypto_key: str       # 64hex
    transport: str        # vp8channel
    servers: list         # список srv-эндпоинтов (для failover на клиенте)

    @staticmethod
    def load(path: str) -> "Deployment":
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
        return Deployment(
            name=d["name"], carrier=d.get("carrier", "telemost"),
            channel=d["channel"], crypto_key=d["crypto_key"],
            transport=d.get("transport", "vp8channel"), servers=d.get("servers", []),
        )


class RoomManager:
    def __init__(self, client: TelemostClient, deployment: Deployment, store_path: str):
        self.client = client
        self.dep = deployment
        self.store_path = store_path
        self.state = self._load()

    def _load(self) -> dict:
        if os.path.exists(self.store_path):
            with open(self.store_path, encoding="utf-8") as f:
                return json.load(f)
        return {"current_uri": None, "rooms": {}}  # rooms: uri -> room dict

    def _save(self):
        tmp = self.store_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.state, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self.store_path)

    def current(self) -> dict | None:
        uri = self.state.get("current_uri")
        return self.state["rooms"].get(uri) if uri else None

    def _needs_rotation(self) -> bool:
        cur = self.current()
        if not cur:
            return True
        if time.time() > cur["expires_at"] - ROTATE_BEFORE_SEC:
            return True
        # подтверждаем живость у Telemost (комната могла закрыться раньше TTL)
        return not self.client.is_alive(cur["uri"])

    def ensure_current(self) -> dict:
        """Гарантирует живую текущую комнату. Возвращает её. Создаёт новую при необходимости."""
        if self._needs_rotation():
            room = self.client.create_room()
            self.state["rooms"][room["uri"]] = room
            self.state["current_uri"] = room["uri"]
            self._gc()
            self._save()
        return self.current()

    def _gc(self):
        """Убирает из стора давно истёкшие комнаты (с запасом на overlap)."""
        now = time.time()
        keep = {}
        for uri, r in self.state["rooms"].items():
            if uri == self.state["current_uri"] or r["expires_at"] > now:
                keep[uri] = r
        self.state["rooms"] = keep

    def subscription(self) -> dict:
        """То, что клиент тянет из bootstrap. crypto_key здесь в открытом виде —
        на уровне публикации (#17) шифруется per-client."""
        cur = self.current()
        if not cur:
            raise RuntimeError("нет текущей комнаты — вызови ensure_current()")
        return {
            "deployment": self.dep.name,
            "carrier": self.dep.carrier,
            "room": cur["uri"],
            "channel": self.dep.channel,
            "crypto_key": self.dep.crypto_key,
            "transport": self.dep.transport,
            "servers": self.dep.servers,
            "room_expires_at": cur["expires_at"],
            "issued_at": time.time(),
        }


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="control-plane room manager")
    ap.add_argument("--cookies", required=True)
    ap.add_argument("--deployment", required=True, help="deployment.json")
    ap.add_argument("--store", default="rooms.json")
    ap.add_argument("action", choices=["ensure", "current", "subscription"])
    args = ap.parse_args()

    rm = RoomManager(
        TelemostClient(load_cookie_header(args.cookies)),
        Deployment.load(args.deployment),
        args.store,
    )
    if args.action == "ensure":
        print(json.dumps(rm.ensure_current(), ensure_ascii=False, indent=2))
    elif args.action == "current":
        print(json.dumps(rm.current(), ensure_ascii=False, indent=2))
    elif args.action == "subscription":
        rm.ensure_current()
        print(json.dumps(rm.subscription(), ensure_ascii=False, indent=2))
