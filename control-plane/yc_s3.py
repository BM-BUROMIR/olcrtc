#!/usr/bin/env python3
"""Минимальный S3 PUT для Yandex Object Storage через AWS SigV4 (stdlib-only).

Чтобы control-plane не тянул boto3/aws-cli в рантайме. Кладёт объект в бакет;
анонимное чтение объектов включается флагом бакета (yc storage bucket ... --public-read).
"""
from __future__ import annotations
import hashlib
import hmac
import datetime
import urllib.request

ENDPOINT_HOST = "storage.yandexcloud.net"
REGION = "ru-central1"
SERVICE = "s3"


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def _signing_key(secret: str, datestamp: str) -> bytes:
    k = _sign(("AWS4" + secret).encode(), datestamp)
    k = _sign(k, REGION)
    k = _sign(k, SERVICE)
    return _sign(k, "aws4_request")


def put_object(access_key: str, secret_key: str, bucket: str, key: str,
               body: bytes, content_type: str = "application/octet-stream",
               now: datetime.datetime | None = None) -> int:
    """PUT https://storage.yandexcloud.net/<bucket>/<key>. Возвращает HTTP-код (200 ок)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(body).hexdigest()
    canonical_uri = f"/{bucket}/{key}"

    canonical_headers = (
        f"host:{ENDPOINT_HOST}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amzdate}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join([
        "PUT", canonical_uri, "", canonical_headers, signed_headers, payload_hash,
    ])
    scope = f"{datestamp}/{REGION}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amzdate, scope,
        hashlib.sha256(canonical_request.encode()).hexdigest(),
    ])
    signature = hmac.new(_signing_key(secret_key, datestamp),
                         string_to_sign.encode(), hashlib.sha256).hexdigest()
    authz = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )

    req = urllib.request.Request(
        f"https://{ENDPOINT_HOST}{canonical_uri}", data=body, method="PUT",
        headers={
            "Host": ENDPOINT_HOST,
            "x-amz-date": amzdate,
            "x-amz-content-sha256": payload_hash,
            "Authorization": authz,
            "Content-Type": content_type,
            "Content-Length": str(len(body)),
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.status
