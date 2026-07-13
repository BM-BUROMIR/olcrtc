# olc-bypass — control-plane (room-manager, EPIC 2)

Управляет жизненным циклом whitelisted-комнат и раздачей подписки. Реализует **Модель B**
(аккаунты централизованы в CP, edge-серверы аккаунтов не хранят). См. `../product/ARCHITECTURE.md` §3.

## Доказано end-to-end (2026-06-21)

```
CP создаёт Telemost-комнату (POST /conferences {}, cookie jar, БЕЗ браузера в рантайме)
   → push_room.sh на srv (room.id + рестарт olcrtc-srv)
   → cnc джойнит ту же комнату ЧЕРЕЗ МТС-модем
   → туннель: exit=France, google=200, ya=302
```

## Линчпин: Telemost-комната создаётся программно

Раньше считалось «room creation только через UI» (так и в коде olcrtc). Реверс показал:
`POST https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences` body `{}` → **201**
{uri, room_id}, авторизация = Yandex SSO-куки. Проверено и in-page, и server-side curl'ом.
Комната живёт ~24ч, владелец после создания не нужен (оба конца — гостевой join).

## Компоненты

| Файл | Назначение | Issue |
|---|---|---|
| `telemost_client.py` | `TelemostClient`: create_room() / is_alive() по cookie jar. stdlib-only. | #12 |
| `room_manager.py` | `RoomManager`: ротация комнаты 24ч с overlap, персист `rooms.json`, эмит подписки. | #13 |
| `push_room.sh` | пуш новой комнаты на srv (SSH: room.id + рестарт). | #14 |
| `bootstrap.py` | per-client шифр (AES-256-GCM) + publisher (backend) + egress-агностичный fetcher (клиент GET). | #16/#17 |
| `deployment.example.json` | константы туннеля (channel/key/transport/servers) — НЕ ротируются. | #11 |

## Bootstrap — доставка подписки клиенту (egress-агностично)

Клиент в шатдаун делает HTTPS GET по whitelisted-URL поверх ЛЮБОГО соединения (не знает про
модем/интерфейс — см. `../product/ARCHITECTURE.md §0`). Подписка зашифрована per-client (AES-GCM),
поэтому объект может быть публичным. Приоритет каналов (Telegram демотирован — может не работать
в шатдаун): **PRIMARY Yandex Object Storage** (тот же whitelist-класс что carrier Telemost → ноль
доп-зависимостей), **BACKUP MAX** (`platform-api.max.ru`, госмессенджер, независимый якорь).

```bash
KEY=$(python3 bootstrap.py gen-key)                       # per-client ключ (раз на клиента)
python3 room_manager.py ... subscription > sub.json
python3 bootstrap.py publish --subscription sub.json --client-id <id> --client-key $KEY --fs-root /tmp/boot
# клиент (референс; Go/Swift зеркалит):
python3 bootstrap.py fetch --url <url> --client-key $KEY
```

Backend-ы: `FilesystemBackend` (тест), `YandexStorageBackend` (**✅ прод, проверен e2e на реальной
инфре**) — кладёт в YC-бакет `olc-bootstrap` через `yc_s3.py` (stdlib SigV4, без boto3/aws в рантайме),
клиент GET'ит анонимно `https://storage.yandexcloud.net/olc-bootstrap/<client>.olcb`. Креды SA — в
`../.secrets/olc-bootstrap-yc/s3.env`. Бакет в облаке b1gcdjb4be0k7q9drafv / каталог olc-bypass, SA
изолирован bucket-ACL (не дотянется до UNITE-бакетов). Прогон:

```bash
set -a; source ../.secrets/olc-bootstrap-yc/s3.env; set +a   # S3-креды выделенного SA
python3 bootstrap.py publish --subscription sub.json --client-id <id> --client-key $KEY --yc-bucket olc-bootstrap
# клиент (без облачных кред): python3 bootstrap.py fetch --url <https-url> --client-key $KEY
```

## Использование

```bash
export SSL_CERT_FILE=/etc/ssl/cert.pem   # только macOS python.org (нет CA-бандла); на Linux не нужно

# 1. создать/взять текущую живую комнату
python3 room_manager.py --cookies <jar> --deployment <deployment.json> --store rooms.json ensure

# 2. подписка для клиента (то, что ляжет в whitelisted-bootstrap)
python3 room_manager.py --cookies <jar> --deployment <deployment.json> --store rooms.json subscription

# 3. пуш текущей комнаты на сервер
ROOM=$(python3 -c 'import json;print(json.load(open("rooms.json"))["current_uri"])')
./push_room.sh --srv-host <ip> --room "$ROOM" --ssh-key <key>
```

cookie jar и реальный `deployment.json` — в `../.secrets/{telemost-account,olc-stand}/` (gitignored).

## Осталось по EPIC 2

- #15 Telegram-бот публикатор подписки (primary whitelisted-bootstrap).
- #16 Yandex Object Storage fallback.
- #17 per-client шифрование подписки (сейчас crypto_key в открытом виде в subscription()).
- #18 admin CLI (add server/account/client).
- #19 **долгоживущие сессии / пул аккаунтов** — главный операционный риск: куки протухают,
  Yandex антифрод может лочить при смене IP. Нужен ВЫДЕЛЕННЫЙ аккаунт (не личный) + refresh.

## Managed production rotation

`managed_rotation.py` performs one fail-closed transaction: ensure or create a fresh
room, atomically install the complete server config while preserving file ownership,
wait for a stable service process, run HTTPS and 1 MiB SOCKS probes, publish encrypted
objects for every authorized device, and commit the generation. Server and published
objects are restored when a later phase fails.

Runtime paths and credentials belong in a private config based on
`managed-rotation.example.json`. On macOS, install the 30-minute scheduler with:

```bash
control-plane/install-managed-rotation-launchd.sh \
  <private-rotation-config.json> <private-s3.env> <private-runtime-dir>
```

The generated plist and logs remain in the private runtime directory. The user
LaunchAgents directory contains only a symlink, so the job is restored after login.

### Per-device enrollment

Issue a separate key for every device. The command writes one mode-`0600` JSON file containing
all authorized managed profiles and prints only a secret-free summary:

```bash
python3 control-plane/device_enrollment.py \
  --registry <private-devices.json> \
  --device-id <device-id> \
  --profiles telemost,wb \
  --object-base-url https://<bootstrap-host>/<private-prefix> \
  --output <private-enrollment.json>
```

Run managed rotation after enrollment so the device objects are published. Deliver the enrollment
file through a private channel and remove the delivery copy after import. Disabling a device in the
registry removes it from subsequent publications without rotating other devices' keys.

### Durable shadow mode

The optional `shadow` section in `managed-rotation.example.json` records each successful legacy
rotation in SQLite as a fenced operation, writes an immutable private generation, and atomically
advances a manifest. It does not replace the client-facing legacy object.

For an always-on Linux host use the checked-in systemd service/timer and
`run-systemd-rotation.sh`. Provider, SSH, deployment, and base-config credentials are supplied with
`LoadCredential`; SSH host identity is pinned. Deployment and restore procedures are in
`runbooks/shadow-rollout.md` and `runbooks/control-plane-restore.md`.
