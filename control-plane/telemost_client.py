#!/usr/bin/env python3
"""Telemost API-клиент для control-plane: создание комнат по cookie jar (без браузера в рантайме).

Реверс подтверждён 2026-06-21:
  POST https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences  body {}  -> 201 {uri, room_id, ...}
  GET  .../conferences/{url-enc uri}/connection                                       -> 200 если комната жива (гостевой)

Авторизация create = Yandex SSO-куки (Session_id/sessionid2/sessar/sessguard/L/yandex_login).
Зависимостей нет (stdlib urllib).
"""
from __future__ import annotations
import json
import time
import uuid
import urllib.request
import urllib.parse
import urllib.error

API_BASE = "https://cloud-api.yandex.ru/telemost_front/v2/telemost"
CLIENT_VERSION = "187.1.0"
ROOM_TTL_SEC = 24 * 3600  # Telemost-комната живёт ~24ч
HEALTH_CHECK_ATTEMPTS = 3


class TelemostError(RuntimeError):
    pass


class TelemostClient:
    """Создаёт/проверяет Telemost-комнаты по cookie jar одного аккаунта."""

    def __init__(self, cookie_header: str):
        self.cookie_header = cookie_header.strip()
        if not self.cookie_header:
            raise ValueError("пустой cookie_header")

    def _headers(self) -> dict:
        return {
            "Content-Type": "application/json",
            "Accept": "*/*",
            "Origin": "https://telemost.yandex.ru",
            "Referer": "https://telemost.yandex.ru/",
            "X-Telemost-Client-Version": CLIENT_VERSION,
            "Client-Instance-Id": str(uuid.uuid4()),
            "Idempotency-Key": str(uuid.uuid4()),
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:149.0) Gecko/20100101 Firefox/149.0",
            "Cookie": self.cookie_header,
        }

    def create_room(self) -> dict:
        """POST /conferences {} -> новая комната. Возвращает нормализованный dict."""
        req = urllib.request.Request(
            f"{API_BASE}/conferences",
            data=b"{}",
            headers=self._headers(),
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                body = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            if e.code in (401, 403):
                raise TelemostError(
                    f"create_room {e.code}: куки протухли/невалидны — обнови jar аккаунта. {detail}"
                ) from e
            raise TelemostError(f"create_room HTTP {e.code}: {detail}") from e
        now = time.time()
        return {
            "uri": body["uri"],
            "room_id": body["room_id"],
            "peer_id": body.get("peer_id"),
            "created_at": now,
            "expires_at": now + ROOM_TTL_SEC,
        }

    def is_alive(self, uri: str, display_name: str = "olc") -> bool:
        """Гостевой GET connection — 200 если комната ещё джойнится."""
        u = f"{API_BASE}/conferences/{urllib.parse.quote(uri, safe='')}/connection"
        q = urllib.parse.urlencode({
            "next_gen_media_platform_allowed": "true",
            "display_name": display_name,
            "waiting_room_supported": "true",
        })
        req = urllib.request.Request(
            f"{u}?{q}",
            headers={
                "Accept": "*/*",
                "Content-Type": "application/json",
                "Client-Instance-Id": str(uuid.uuid4()),
                "X-Telemost-Client-Version": CLIENT_VERSION,
                "Idempotency-Key": str(uuid.uuid4()),
                "Origin": "https://telemost.yandex.ru",
                "Referer": "https://telemost.yandex.ru/",
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:149.0) Gecko/20100101 Firefox/149.0",
            },
            method="GET",
        )
        for attempt in range(1, HEALTH_CHECK_ATTEMPTS + 1):
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    return resp.status == 200
            except urllib.error.HTTPError:
                return False
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                if attempt == HEALTH_CHECK_ATTEMPTS:
                    raise TelemostError(f"room health check failed: {exc}") from exc
                time.sleep(attempt)
        raise AssertionError("unreachable")


def load_cookie_header(path: str) -> str:
    """Читает cookie-header.txt (строка name=value; …) либо cookies.json (CDP-дамп)."""
    with open(path, encoding="utf-8") as f:
        raw = f.read().strip()
    if raw.startswith("["):
        cookies = json.loads(raw)
        pairs = [f"{c['name']}={c['value']}" for c in cookies if "yandex.ru" in c.get("domain", "")]
        return "; ".join(pairs)
    return raw


if __name__ == "__main__":
    import argparse, sys
    ap = argparse.ArgumentParser(description="Telemost room CLI")
    ap.add_argument("--cookies", required=True, help="путь к cookie-header.txt или cookies.json")
    ap.add_argument("action", choices=["create", "check"], help="create: новая комната; check: жива ли --uri")
    ap.add_argument("--uri", help="для check")
    args = ap.parse_args()

    client = TelemostClient(load_cookie_header(args.cookies))
    if args.action == "create":
        room = client.create_room()
        print(json.dumps(room, ensure_ascii=False, indent=2))
    elif args.action == "check":
        if not args.uri:
            sys.exit("--uri обязателен для check")
        print("alive" if client.is_alive(args.uri) else "dead")
