# Локальный стенд LiveKit для macOS + Docker Desktop

Этот стенд проверяет не только запуск контейнера, а реальный tunnel path:

```text
curl с macOS -> SOCKS5 cnc container -> vp8channel -> LiveKit container -> srv container -> HTTP container
```

Запуск:

```bash
bash deploy/local-livekit/smoke.sh
```

Успешный прогон обязан увидеть в логах `cnc` строку `SOCKS5 server listening`, у `srv` и `cnc`
строку `peer latched`, а запрос через SOCKS должен вернуть `HTTP 200`.

Стенд намеренно использует `transport: vp8channel`. `srv`, `cnc` и LiveKit работают в одной
Docker-сети, а на macOS публикуется только SOCKS-порт. Это обходит недостижимые для host
Docker-кандидаты вида `172.x` в media path, но curl всё равно идёт с macOS через SOCKS.

Локальный LiveKit поднят с `rtc.tcp_port`, узким UDP range `50000-50020`; внешний STUN отключен
через `stun_servers: []` и `use_external_ip: false`. UDP range не публикуется на macOS host:
для этого стенда media path живёт внутри Docker-сети, поэтому host-port conflicts не влияют на тест.

Порты можно сузить или перенести переменными:

```bash
LIVEKIT_HTTP_PORT=7880 \
LIVEKIT_TCP_PORT=7881 \
bash deploy/local-livekit/smoke.sh
```
