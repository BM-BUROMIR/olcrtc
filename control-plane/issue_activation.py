#!/usr/bin/env python3
"""Issue a private one-time OLC activation link."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
from typing import Any

from activation_grants import ActivationGrantStore


def issue_activation(
    *,
    grants_db: pathlib.Path,
    device_id: str,
    ttl_seconds: int,
    output: pathlib.Path,
) -> dict[str, Any]:
    output.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        token = ActivationGrantStore(grants_db).issue(device_id, ttl_seconds=ttl_seconds)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(f"olc://activate/{token}\n")
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        output.unlink(missing_ok=True)
        raise
    return {"device_id": device_id, "ttl_seconds": ttl_seconds, "output_created": True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grants-db", type=pathlib.Path, required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--ttl-seconds", type=int, default=900)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    summary = issue_activation(
        grants_db=args.grants_db,
        device_id=args.device_id,
        ttl_seconds=args.ttl_seconds,
        output=args.output,
    )
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
