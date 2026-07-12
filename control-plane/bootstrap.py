#!/usr/bin/env python3
"""bootstrap — доставка подписки клиенту через whitelisted-канал (EPIC 2 #16/#17).

Egress-агностично: клиент просто делает HTTPS GET по whitelisted-URL поверх ТОГО соединения,
что дало ОС (модем/роутер/wifi — без разницы; см. product/ARCHITECTURE.md §0). Подписка
зашифрована per-client (AES-256-GCM) → утечка bootstrap-URL не палит комнату/ключ туннеля.

Backend-ы подключаемые:
  - FilesystemBackend  — для локального теста.
  - YandexStorageBackend — primary в проде (storage.yandexcloud.net, тот же whitelist-класс,
    что carrier Telemost → ноль доп-зависимостей). [заглушка put через S3 API / yc CLI]

Crypto: AES-256-GCM (cryptography). client_key = 32 байта, по одному на клиента (выдаётся при
enroll/сборке клиента, хранится у клиента и в реестре CP).
"""
from __future__ import annotations
import json
import os
import secrets
import urllib.request
from abc import ABC, abstractmethod

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"OLCB1"  # формат: MAGIC | nonce(12) | ciphertext+tag


# ── crypto ────────────────────────────────────────────────────────────────────
def encrypt_subscription(sub: dict, client_key: bytes) -> bytes:
    if len(client_key) != 32:
        raise ValueError("client_key должен быть 32 байта (AES-256)")
    nonce = secrets.token_bytes(12)
    pt = json.dumps(sub, ensure_ascii=False).encode()
    ct = AESGCM(client_key).encrypt(nonce, pt, MAGIC)
    return MAGIC + nonce + ct


def decrypt_subscription(blob: bytes, client_key: bytes) -> dict:
    if blob[:5] != MAGIC:
        raise ValueError("не olc-bootstrap blob")
    nonce, ct = blob[5:17], blob[17:]
    pt = AESGCM(client_key).decrypt(nonce, ct, MAGIC)
    return json.loads(pt.decode())


def gen_client_key() -> str:
    """Новый per-client ключ (hex, 64 символа)."""
    return secrets.token_bytes(32).hex()


# ── backends ──────────────────────────────────────────────────────────────────
class Backend(ABC):
    @abstractmethod
    def put(self, client_id: str, blob: bytes) -> str:
        """Кладёт blob, возвращает URL/путь, по которому клиент его заберёт."""

    @abstractmethod
    def url_for(self, client_id: str) -> str:
        ...


class FilesystemBackend(Backend):
    """Локальный тест: пишет в каталог, url = file://."""

    def __init__(self, root: str):
        self.root = root
        os.makedirs(root, exist_ok=True)

    def _path(self, client_id: str) -> str:
        return os.path.join(self.root, f"{client_id}.olcb")

    def put(self, client_id: str, blob: bytes) -> str:
        p = self._path(client_id)
        with open(p, "wb") as f:
            f.write(blob)
        return self.url_for(client_id)

    def url_for(self, client_id: str) -> str:
        return "file://" + os.path.abspath(self._path(client_id))


class YandexStorageBackend(Backend):
    """Primary прод-backend: публичный объект в YC Object Storage (whitelisted Yandex,
    тот же класс что carrier Telemost). Клиент GET'ит https://storage.yandexcloud.net/<bucket>/<id>.olcb.
    Объект анонимно-читаемый (флаг бакета --public-read), но содержимое зашифровано per-client → безопасно.
    put() заливает SigV4-загрузчиком (stdlib yc_s3) по static access key выделенного SA."""

    BASE = "https://storage.yandexcloud.net"

    def __init__(self, bucket: str, access_key: str | None = None, secret_key: str | None = None):
        self.bucket = bucket
        self.access_key = access_key
        self.secret_key = secret_key

    def put(self, client_id: str, blob: bytes) -> str:
        if not (self.access_key and self.secret_key):
            raise NotImplementedError(
                "YandexStorageBackend.put: нужны access_key/secret_key выделенного SA "
                "(см. .secrets/olc-bootstrap-yc/s3.env)."
            )
        import yc_s3
        code = yc_s3.put_object(self.access_key, self.secret_key, self.bucket,
                                f"{client_id}.olcb", blob)
        if code != 200:
            raise RuntimeError(f"S3 PUT вернул {code}")
        return self.url_for(client_id)

    def url_for(self, client_id: str) -> str:
        return f"{self.BASE}/{self.bucket}/{client_id}.olcb"


# ── клиентская сторона (референс; Go/Swift-клиент это зеркалит) ─────────────────
def fetch_subscription(url: str, client_key_hex: str, timeout: int = 15) -> dict:
    """Egress-агностичный GET по whitelisted-URL + расшифровка. Никаких допущений про транспорт."""
    if url.startswith("file://"):
        with open(url[7:], "rb") as f:
            blob = f.read()
    else:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            blob = resp.read()
    return decrypt_subscription(blob, bytes.fromhex(client_key_hex))


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="bootstrap publish/fetch")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen-key", help="новый per-client ключ")

    p = sub.add_parser("publish", help="зашифровать подписку и положить в backend")
    p.add_argument("--subscription", required=True, help="JSON-файл подписки (из room_manager subscription)")
    p.add_argument("--client-id", required=True)
    p.add_argument("--client-key", required=True, help="hex 64 (gen-key)")
    p.add_argument("--fs-root", help="FilesystemBackend root (тест)")
    p.add_argument("--yc-bucket", help="YandexStorageBackend bucket (прод)")

    f = sub.add_parser("fetch", help="забрать и расшифровать (клиентская сторона)")
    f.add_argument("--url", required=True)
    f.add_argument("--client-key", required=True)

    args = ap.parse_args()
    if args.cmd == "gen-key":
        print(gen_client_key())
    elif args.cmd == "publish":
        with open(args.subscription, encoding="utf-8") as fh:
            sub_obj = json.load(fh)
        if args.fs_root:
            backend: Backend = FilesystemBackend(args.fs_root)
        elif args.yc_bucket:
            backend = YandexStorageBackend(
                args.yc_bucket,
                access_key=os.environ.get("AWS_ACCESS_KEY_ID"),
                secret_key=os.environ.get("AWS_SECRET_ACCESS_KEY"),
            )
        else:
            raise SystemExit("нужен --fs-root или --yc-bucket")
        blob = encrypt_subscription(sub_obj, bytes.fromhex(args.client_key))
        url = backend.put(args.client_id, blob)
        print(json.dumps({"client_id": args.client_id, "url": url, "bytes": len(blob)}, ensure_ascii=False))
    elif args.cmd == "fetch":
        print(json.dumps(fetch_subscription(args.url, args.client_key), ensure_ascii=False, indent=2))
