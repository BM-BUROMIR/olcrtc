"""Structured rendering of a complete OLC server candidate configuration."""

from __future__ import annotations

import copy
import re

import yaml


_HEX_32 = re.compile(r"^[0-9a-fA-F]{64}$")


def render_server_config(base_yaml: str, subscription: dict) -> str:
    config = yaml.safe_load(base_yaml)
    if not isinstance(config, dict) or config.get("mode") != "srv":
        raise ValueError("base config must be an srv YAML object")
    required = ("carrier", "room", "channel", "crypto_key", "transport")
    if any(not isinstance(subscription.get(key), str) or not subscription[key].strip() for key in required):
        raise ValueError("candidate subscription is incomplete")
    if not _HEX_32.fullmatch(subscription["crypto_key"]):
        raise ValueError("candidate crypto_key must be hex64")

    result = copy.deepcopy(config)
    result["auth"] = {**result.get("auth", {}), "provider": subscription["carrier"]}
    result["room"] = {"id": subscription["room"], "channel": subscription["channel"]}
    result["crypto"] = {**result.get("crypto", {}), "key": subscription["crypto_key"]}
    result["net"] = {**result.get("net", {}), "transport": subscription["transport"]}
    return yaml.safe_dump(result, sort_keys=False, allow_unicode=False)
