# Локальный LiveKit stand

Этот stand поднимает локальный `livekit-server` с dev-ключами и использует
`auth.provider: livekit` внутри `olcrtc`. Ключи `devkey` / `devsecret` лежат в
`deploy/livekit.yaml` и вшиты в локальный auth-provider. Это не секреты: они
дают доступ только к контейнеру, который слушает `127.0.0.1:7880`.

## Запуск

```bash
docker compose -f deploy/docker-compose.livekit.yaml up
```

После запуска используй одинаковый `room.id` в server/client конфигах:

- `docs/examples/server/server.livekit.datachannel.yaml`
- `docs/examples/client/client.livekit.datachannel.yaml`

Комната создаётся локальным LiveKit при первом подключении участника с
подписанным token. Для генерации room ID можно использовать:

```bash
olcrtc docs/examples/gen.livekit.yaml
```

## Что делает auth.provider: livekit

- использует engine `livekit`;
- подписывает room token локальными dev API key/secret;
- выдаёт grants `roomJoin`, `roomCreate`, `canPublish`, `canPublishData`,
  `canSubscribe`;
- не ходит во внешние сервисы;
- реализует `auth.RoomCreator`, поэтому подходит для `mode: gen`.
