#!/usr/bin/env python3
"""HTTP exchange service for single-use OLC activation grants."""

from __future__ import annotations

import argparse
import datetime as dt
import hmac
import json
import pathlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable

from activation_grants import (
    ActivationConflict,
    ActivationExpired,
    ActivationGrantStore,
    ActivationInvalid,
)
from device_registry import DeviceRegistry, RegistryError


MAX_REQUEST_BYTES = 4096


class ActivationService:
    def __init__(
        self,
        *,
        grants: ActivationGrantStore,
        registry: DeviceRegistry,
        object_base_url: str,
        admin_token: str,
        clock: Callable[[], dt.datetime] | None = None,
    ):
        if len(admin_token) < 32 or any(character.isspace() for character in admin_token):
            raise ValueError("admin token must contain at least 32 non-whitespace characters")
        self.grants = grants
        self.registry = registry
        self.object_base_url = object_base_url
        self.admin_token = admin_token
        self.clock = clock or (lambda: dt.datetime.now(dt.timezone.utc))

    def exchange(self, body: bytes) -> tuple[int, dict[str, Any]]:
        if len(body) > MAX_REQUEST_BYTES:
            return HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "request_too_large"}
        try:
            request = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        if not isinstance(request, dict) or set(request) != {
            "schema_version",
            "grant",
            "installation_id",
        }:
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        if request["schema_version"] != 1 or not isinstance(request["grant"], str) or not isinstance(
            request["installation_id"], str
        ):
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        try:
            result = self.grants.consume(
                request["grant"],
                request["installation_id"],
                now=self.clock(),
            )
            profiles = self.registry.enrollment(result.device_id, self.object_base_url)
        except ActivationExpired:
            return HTTPStatus.GONE, {"error": "grant_expired"}
        except ActivationConflict:
            return HTTPStatus.CONFLICT, {"error": "grant_already_bound"}
        except (ActivationInvalid, RegistryError):
            return HTTPStatus.UNAUTHORIZED, {"error": "invalid_grant"}
        return HTTPStatus.OK, {"schema_version": 1, "profiles": profiles}

    def issue(self, body: bytes) -> tuple[int, dict[str, Any]]:
        if len(body) > MAX_REQUEST_BYTES:
            return HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "request_too_large"}
        try:
            request = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        if not isinstance(request, dict) or set(request) != {"device_id", "ttl_seconds"}:
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        if not isinstance(request["device_id"], str) or not isinstance(request["ttl_seconds"], int):
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        try:
            self.registry.enrollment(request["device_id"], self.object_base_url)
            token = self.grants.issue(
                request["device_id"],
                ttl_seconds=request["ttl_seconds"],
                now=self.clock(),
            )
        except (RegistryError, ValueError):
            return HTTPStatus.BAD_REQUEST, {"error": "invalid_request"}
        return HTTPStatus.CREATED, {
            "schema_version": 1,
            "activation_url": f"olc://activate/{token}",
            "expires_in": request["ttl_seconds"],
        }


def handler(service: ActivationService) -> type[BaseHTTPRequestHandler]:
    class RequestHandler(BaseHTTPRequestHandler):
        server_version = "OLCActivation/1"

        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/healthz":
                self._reply(HTTPStatus.OK, {"status": "ok"})
                return
            self._reply(HTTPStatus.NOT_FOUND, {"error": "not_found"})

        def do_POST(self) -> None:  # noqa: N802
            if self.path not in {"/v1/activate", "/v1/admin/grants"}:
                self._reply(HTTPStatus.NOT_FOUND, {"error": "not_found"})
                return
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                self._reply(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
                return
            if length < 0 or length > MAX_REQUEST_BYTES:
                self._reply(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "request_too_large"})
                return
            body = self.rfile.read(length)
            if self.path == "/v1/admin/grants":
                expected = f"Bearer {service.admin_token}"
                if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
                    self._reply(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
                    return
                status, payload = service.issue(body)
            else:
                status, payload = service.exchange(body)
            self._reply(status, payload)

        def _reply(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            # The URL is fixed and request bodies may contain grants, so emit no access details.
            return

    return RequestHandler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grants-db", type=pathlib.Path, required=True)
    parser.add_argument("--device-registry", type=pathlib.Path, required=True)
    parser.add_argument("--object-base-url", required=True)
    parser.add_argument("--admin-token-file", type=pathlib.Path, required=True)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    service = ActivationService(
        grants=ActivationGrantStore(args.grants_db),
        registry=DeviceRegistry(args.device_registry),
        object_base_url=args.object_base_url,
        admin_token=args.admin_token_file.read_text(encoding="utf-8").strip(),
    )
    ThreadingHTTPServer((args.bind, args.port), handler(service)).serve_forever()


if __name__ == "__main__":
    main()
