#!/usr/bin/env python3
"""Issue a private multi-profile enrollment artifact for one field device."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
from typing import Any

from device_registry import DeviceRegistry


def issue_enrollment(
    *,
    registry_path: pathlib.Path,
    device_id: str,
    profiles: list[str],
    object_base_url: str,
    output: pathlib.Path,
) -> dict[str, Any]:
    if output.exists():
        raise FileExistsError(output)

    registry = DeviceRegistry(registry_path)
    registry.enroll(device_id, profiles)
    enrollment = registry.enrollment(device_id, object_base_url)

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.{os.getpid()}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(enrollment, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, output)
        os.chmod(output, 0o600)
    finally:
        temporary.unlink(missing_ok=True)

    return {"device_id": device_id, "profiles": [item["id"] for item in enrollment]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=pathlib.Path, required=True)
    parser.add_argument("--device-id", required=True)
    parser.add_argument("--profiles", default="telemost,wb")
    parser.add_argument("--object-base-url", required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    profiles = [value.strip() for value in args.profiles.split(",") if value.strip()]
    summary = issue_enrollment(
        registry_path=args.registry,
        device_id=args.device_id,
        profiles=profiles,
        object_base_url=args.object_base_url,
        output=args.output,
    )
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
