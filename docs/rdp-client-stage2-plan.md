# RDP Access Gateway — план этапа 2 клиента (ligament-apps)

Дата: 2026-10-07
Статус: план реализации (не код). Основан на ФАКТИЧЕСКИ реализованных
контрактах сервера twofa v0.8.124 (commit d923811, `internal/api/rdp_gateway.go`,
`internal/api/rdp_cp.go`, `internal/store/rdp_gateway.go`, `api/openapi.yaml`)
и на фактической архитектуре клиента ligament-apps.

Ссылки:
- серверный дизайн: `docs/rdp-access-gateway-design.md` (rev 13) в репо 2fa;
- клиент: `lib/api/client.dart`, `lib/services/auth_state.dart`,
  `lib/services/ws_service.dart`, `lib/services/support_service.dart`,
  `windows/service/service.cpp`, `windows/installer/Product.wxs`.

---

## 0. Контекст и границы этапа 2

Этап 1 (ядро) на сервере реализован: цели/гранты/закрытие/.rdp/WS-труба,
kill-switch, CP-гейт `/api/v1/cp/rdp-mfa-satisfied`. Этап 2 — клиентская
эксплуатация этого ядра плюс два новых серверных примитива, которых пока
НЕТ (см. §1.2 — оба помечены как предусловия, придуманных эндпоинтов в
плане нет: контракты ниже либо прочитаны из кода сервера, либо явно
помечены «ТРЕБУЕТСЯ СЕРВЕРУ» с точным местом, куда их предполагается
добавить).

Состав этапа 2 клиента:

1. Плитка «Мой ПК» на главном экране (`/api/v1/app/rdp/targets` + online).
2. RDP-режим Windows: grant → локальный слушатель → WS-мост → `mstsc`.
3. Self-служба (Endpoint Service) в MSI рядом с CP: WSS-агент до ядра,
   проброс на `127.0.0.1:3389`.
4. Режим «Экран»: переиспользование SOS-механики с флагом owner.
5. PWA-контракт `/rdp/session/:id` (только контракт, серверный фронт).

---

## 1. Фактические серверные контракты (источник — код, не догадки)

### 1.1 Реализовано в v0.8.124

Все юзерские маршруты — за app-аутентификацией (`Authorization: Bearer
<app_token>`), смонтированы `RdpAPI.RegisterApp` (`internal/api/rdp_gateway.go:55`).

#### GET /api/v1/app/rdp/targets
Ответ `200`:
```json
{"targets": [{
  "id": "<uuid>",
  "name": "ws-001",
  "kind": "pc",                  // pc | terminal_server
  "max_sessions": 1,
  "online": true,
  "endpoint": "ws-001.corp.local", // hostname первого включённого endpoint
  "route": "agent"                // kind endpoint: relay | direct | agent
}]}
```
Семантика `online` (важно для UI): для `route=agent` — true только когда
endpoint `status='online'` (агент живой, `last_seen_at` обновляется
`RdpEndpointTouch`); для `relay`/`direct` — считаются доступными всегда
(в коде: `e.Kind != "agent" && e.LastSeenAt == nil → online`). Скриншота
сервер НЕ отдаёт — поле отсутствует в контракте (см. §2.3).

#### POST /api/v1/app/rdp/grant
Запрос: `{"target_id": "<uuid>", "mode": "rdp"}` — mode: `rdp | screen |
bridge` (по умолчанию `rdp`).
Ответ `201`:
```json
{"grant_id": "<uuid>", "token": "<64 hex-символа = 32 байта>",
 "route": "relay|direct|agent|bridge", "expires_in": 60}
```
Ошибки (обрабатывать в UI явно):
- `403 target_not_assigned` — цель не назначена юзеру;
- `428 mfa_required` — нет «свежей» завершённой MFA-попытки:
  `LoginAttemptLatestCompleted` = последняя запись `login_attempts` со
  `status='completed'` и непустым `second_factor_type` за последние
  **10 минут** (`internal/store/rdp_gateway.go:555`);
- `409 target_busy` — исчерпан `max_sessions` цели;
- `500 db_error`.

#### POST /api/v1/app/rdp/close
Запрос `{"grant_id": "<uuid>"}` → `200 {"status":"ok"}`; чужой грант →
`404 not_found`. Закрывает грант И активную сессию (reason=`closed`).

#### GET /api/v1/app/rdp/connect (WebSocket)
`?grant=<uuid>&token=<hex>` — единственный реализованный способ
предъявления токена (в query; расхождение с дизайн-доком §5 «токен не в
query» зафиксировано, клиент следует реализованному коду). Валидация:
sha256(token) == token_hash, state=`issued`, не истёк, юзер совпадает.
Далее сервер:
- `route=relay` — `RelayHub.DialStream(relay_id, hostname, 3389)`
  (слепая TCP-труба через релей, `internal/api/relay_stream.go`);
- `route=direct` — `net.DialTimeout(hostname:3389, 5s)`;
- `route=agent` — **пока `400 unsupported_route`** (ветка не написана);
- атомарный claim `issued→active` + создание `rdp_sessions` (гонку
  двойного claim закрывает условный UPDATE, `RdpGrantClaim`);
- далее `bridgeRDP(ws, dst, ...)` — **заглушка**: комментарий в коде
  прямо называет «полноценный WS-мост (кадры↔байты) — общая реализация
  этапа 2». Контракт кадра очевиден из задачи моста: WS **бинарные кадры
  = сырые байты RDP-потока** в обе стороны (без base64 — дизайн §6),
  разрыв любой стороны закрывает грант (`state='closed'`).

#### GET /api/v1/app/rdp/bridge.rdp
`?grant=&token=` (только `route=bridge`) — отдаёт `.rdp` с `full
address:s:<host>:<port>` на одноразовый TCP-порт ядра (idle-close 3 мин).
Для плитки этапа 2 НЕ используется (сценарий «чужой ПК», дизайн §15.1).

#### GET|POST /api/v1/cp/rdp-mfa-satisfied (реализовано, этап 3 CP)
`?username=&machine=` → `{"satisfied":bool, "grant_id", "session"}` —
CP на ЦЕЛИ видит активную сессию шлюза и не требует второй MFA. Уже
работает с этапом-1 сессиями — синергия для self-службы (§4.7).

Kill-switch (`KillUserAccess`): отзыв грантов, кик WS-стримов, сессии →
`killed`. Клиент обязан переживать обрыв WS-трубы как «сессия завершена».

### 1.2 Чего на сервере НЕТ — предусловия этапа 2 (работа в репо 2fa)

| # | Отсутствует | Где добавлять | Контракт в этом плане |
|---|---|---|---|
| S1 | WS-мост `bridgeRDP` — реализация (заглушка) | `internal/api/rdp_gateway.go:333` | §3.4 |
| S2 | Маршрут `agent` в `handleConnectWS` + WS-эндпоинт агента `/api/v1/rdp/agent/connect` + выдача/хранение agent_key + админ-CRUD целей/endpoints/назначений (store-методы `RdpTargetCreate/RdpEndpointUpsert/RdpAssignmentSet*` УЖЕ есть, HTTP-хендлеров нет) | новый `internal/api/rdp_agent.go` по образцу `relay_hub.go`+`relay_stream.go` | §4 |
| S3 | Склейка `mode=screen` с support-сессиями (создание сессии из гранта, пуш владельцу с флагом owner) | support-слой | §5 |
| S4 | PWA-страница `/rdp/session/:id` | `internal/api/pages.go` | §6 |

Клиентские этапы 2.1 (плитка) и 2.2 (коннектор по route=relay/direct)
можно начинать немедленно; после S1 коннектор работает end-to-end.
Этап 2.3 (self-служба) блокируется на S2, «Экран» — на S3.

---

## 2. Плитка «Мой ПК» на главной

### 2.1 API-интеграция

Новые методы в существующем `lib/api/client.dart` (рядом с
`getAllowedApps`, тот же стиль `ApiException`):

```dart
Future<List<Map<String, dynamic>>> getRdpTargets()            // GET  /api/v1/app/rdp/targets
Future<Map<String, dynamic>> rdpGrant({required String targetId, String mode = 'rdp'}) // POST /rdp/grant
Future<void> rdpClose(String grantId)                          // POST /rdp/close
```

Ошибка `428 mfa_required` — не исключение общего вида: `rdpGrant`
пробрасывает `ApiException(428, 'mfa_required')`, UI по нему показывает
диалог «Требуется свежее подтверждение входа» (§2.5).

### 2.2 Состояние и обновление

- Новое поле `List<Map<String,dynamic>> rdpTargets` + `loadRdpTargets()`
  в `lib/services/auth_state.dart`; вызов добавить в `refreshAll()`
  (поферхность уже дергается pull-to-refresh на главной и `onConnected`
  WS-реконнекта).
- Отдельный `Timer.periodic(60s)` на главном экране, пока вкладка видима
  и `rdpTargets` непуста — online-статус агента тухнет без обновления
  (сервер переводит в offline только по факту disconnect/timeout).
- 404/`ApiException` при `loadRdpTargets` трактуем как «фича выключена»:
  секция скрыта (сервер free-лицензии может не монтировать маршруты —
  та же деградация, что у `apps_rdp_url`).

### 2.3 Превью плитки

Сервер скриншот НЕ отдаёт (в контракте §1.1 поля нет; `capabilities`
в `rdp_endpoints` существует в БД, но в `/rdp/targets` не возвращается).
Решение этапа 2 — без нового серверного контракта:

- плитка = тёмная карточка в стиле `AppsScreen` (фон `0xFF1E293B`,
  радиус 16): крупная иконка ПК (`Icons.desktop_windows_outlined`),
  имя цели, чип типа (`pc` / `terminal_server`), строка `endpoint`;
- онлайн-индикатор: зелёная (`0xFF10B981`) / серая точка + подпись
  route (`agent`/`relay`/`direct`) — визуальный язык уже используется в
  `home_screen.dart` (статус-чип в AppBar);
- точка подключения под будущий скрин: `capabilities` агента (S2)
  может позже отдавать preview — плитка оставляет место под
  `Image.network` без изменения layout.
- offline-плитка: кнопка «Подключиться» заменяется на «Служба Ligament
  offline» (дизайн-док §10.1) — кликабельна только для «Экрана»? Нет:
  offline = обе кнопки неактивны, подсказка «включите ПК / службу».

### 2.4 Расположение и действия

Секция «Мои рабочие места» в `_buildRequestsTab` (`home_screen.dart`,
сразу под identity-баннерами, над блоком «2FA Login Requests»), данные
те же, что в `AppsScreen`, но на главной — по дизайн-доку §10.1 профиль
и приложение показывают раздел в главном окне.

Кнопки на плитке:
- **«Подключиться»** (только `Platform.isWindows` и `!kIsWeb`) → §3;
- **«Экран»** (все платформы) → §5;
- терминальный сервер (`kind=terminal_server`): подпись
  «N параллельных сессий» из `max_sessions`.

### 2.5 Обработка 428 mfa_required

Свежесть = завершённая MFA-попытка за 10 минут (`login_attempts`,
`second_factor_type <> ''`). Приложение при обычной работе сидит с
долгоживущим device-токеном и попыток НЕ создаёт. Диалог по 428:
«Подтвердите вход заново» → варианты: (а) повторный вход в приложение
(logout → login с кодом второго фактора), (б) любое событие входа в
веб-кабинет. Отдельную «тихую» MFA-попытку из приложения в этап 2 НЕ
придумываем (нет эндпоинта) — ОТКРЫТЫЙ ВОПРОС Q1 (§9).

---

## 3. RDP-режим Windows (коннектор внутри приложения)

### 3.1 Последовательность

```text
Плитка «Подключиться»
  → POST /api/v1/app/rdp/grant {target_id, mode:"rdp"}
     201 {grant_id, token, route, expires_in:60}
  → ServerSocket.bind(InternetAddress("127.0.0.2"), 0)   // случайный порт
  → IOWebSocketChannel.connect(wss://<base>/api/v1/app/rdp/connect
        ?grant=<id>&token=<hex>)                          // бинарные кадры
  → WebSocket ready (claim на сервере: grant→active, session создана)
  → Process.run('mstsc', ['/v:127.0.0.2:<port>'])
  → пользователь работает; байты: mstsc ↔ listener ↔ WS ↔ ядро ↔ цель
  → mstsc закрыт (exitCode) ИЛИ WS closed ИЛИ приложение закрывается
  → закрыть listener и WS → POST /api/v1/app/rdp/close {grant_id}
```

Диалог статуса (`RdpConnectDialog`): шаги «Грант… → Слушатель… →
Туннель… → Запуск mstsc», каждая ошибка — человеческим текстом
(`target_busy` → «Все сессии цели заняты», `grant_expired`/410 на WS →
«Истёк грант, повторите», WS 502 `target_unreachable` → «Цель
недоступна», `relay_unavailable` → «Релей офлайн»).

### 3.2 Новый сервис `lib/services/rdp_service.dart`

`RdpConnectorService extends ChangeNotifier` (одиночка, владелец —
`AuthState`, рядом с `support`):

```dart
class RdpTunnelSession {
  final String grantId;
  ServerSocket? listener;          // dart:io
  IOWebSocketChannel? ws;          // web_socket_channel (уже в pubspec)
  Process? mstsc;
  int port;
  StreamSubscription? ...
}
```

Методы: `Future<void> connect(target)` / `Future<void> close()` /
`Stream<RdpTunnelState> get states`. TTL-гранта 60 c — таймер
`expires_in` подстраховывает UI («истекает, переподключаемся»).

### 3.3 Мост слушатель ↔ WS (многопоточность)

Ключевое решение — перекачка без ручного `listen`/`add` и без потерь
backpressure: у `IOWebSocketChannel.sink` (StreamSink) и у `Socket`
(StreamSink через `socket.addStream` нет — но `Stream.pipe`/`addStream`
на стороне сокета есть через обёртку) используем пару:

```dart
// TCP → WS (backpressure: addStream не читает дальше, пока WS не примет)
unawaited(ws.sink.addStream(socket.map(Uint8List.fromList)));
// WS → TCP (то же в обратную сторону)
unawaited(socket.addStream(ws.stream.cast<List<int>>()));
```

Обе операции возвращают Future; `RdpTunnelSession.close()` отменяет
через shutdown сокета и `ws.sink.close()`. Это канонический паттерн
«pipe» для web_socket_channel (используется вместо ручного listen из-за
запрета смешивать `add` и `addStream`).

**Изолят или UI-event-loop?** Этап 2.1 — один main-isolate: RDP
интерактивный поток — это единицы Мбит/с кадрами по ~4–16 КБ;
`addStream` даёт честное backpressure, jank маловероятен. Контрольный
замер обязателен (§8, риск R1): если профилирование покажет пропуски
кадров UI — этап 2.2-опция: вынести `listener+ws` целиком в отдельный
`Isolate` (оба — чистый `dart:io`, сериализация через `SendPort`/`ReceivePort`
только для управления старт/стоп/статус). Заранее изолят НЕ заводим:
усложнение lifecycle (рестарт изолятов при suspend/resume Windows).

`pingInterval: 20s` на WS (как в `ws_service.dart`) — держит NAT и
даёт быстрый детект обрыва.

### 3.4 Контракт WS-кадр (для сервера S1, для клиента — приёмник)

- только **бинарные** кадры; payload = сырые байты TCP-потока RDP;
- текстовые кадры не используются (расширение протокола — JSON
  `{"type":"rdp_close","reason":...}` перед закрытием — опционально, не
  блокирует);
- закрытие любой стороны = конец сессии (клиент после `onDone`/`onError`
  шлёт `/rdp/close` идемпотентно, сервер уже закрыл грант).

### 3.5 mstsc

- `Process.start('mstsc', ['/v:127.0.0.2:$port'])` (Path-резолв
  `C:\Windows\System32\mstsc.exe` — fallback при пустом PATH);
- НЕ ждём `Process.run` — слушаем `exitCode.then(...)` → это сигнал
  «пользователь закрыл окно» → `close()` всей сессии;
- mstsc может самопереподключаться после сетевого сбоя НОВЫМ
  TCP-соединением к тому же `127.0.0.2:port` — поведение слушателя:
  принимаем ОДНО соединение на грант (серверный claim одноразовый);
  после разрыва слушатель закрывается, повторное подключение — новая
  плитка (новый грант). Документируем в UI-тексте.
- NLA/CredSSP/Kerberos идут внутри туннеля как обычные байты — пароль
  Windows через Ligament НЕ проходит (дизайн §2.2); для доменных машин
  работает SSO текущей сессии.

### 3.6 Windows-разрешения (win-часть)

- **исходящий localhost**: `IOWebSocketChannel` → `wss://<core>:443` —
  обычный исходящий HTTPS, разрешён по умолчанию; ничего в фаерволе не
  нужно. ВАЖНО: соединение идёт НЕ на localhost, а на ядро — локальный
  слушатель только принимает mstsc;
- **входящий loopback**: `ServerSocket` на `127.0.0.2` — Windows
  Firewall loopback-трафик не фильтрует, inbound-правило НЕ нужно,
  прав администратора НЕ нужно (bind на 127/8 без привилегий);
- выбор **127.0.0.2** (а не 127.0.0.1): (а) не конфликтует с занятыми
  портами других localhost-сервисов клиента (у нас уже слушатель
  local-detect на 127.0.0.1:8757 — коллизия портов исключена выбором
  адреса + ephemeral port), (б) `mstsc /v:127.0.0.2` не даёт Windows
  «оптимизаций» loopback-RDP, весь 127/8 маршрутизируется на loopback;
- служба Windows для коннектора НЕ нужна: всё живёт в пользовательской
  сессии приложения; существующий watchdog `Ligament2FAService`
  (`windows/service/service.cpp`) трогать не нужно (его задача — держать
  живым клиент, живёт и коннектор);
- закрытие приложения = обрыв туннеля = конец RDP-сессии: приложение
  уже умеет сворачиваться в трей (`windowManager.hide()`), в§8 R6
  предусмотреть подтверждение при выходе с активным туннелем.

### 3.7 Файлы

Новые: `lib/services/rdp_service.dart`, `lib/screens/rdp_connect_dialog.dart`,
виджет плитки `lib/widgets/my_pc_tile.dart` (или секция внутри
`home_screen.dart` — выбрать по размеру, см. §7).
Правки: `lib/api/client.dart` (+3 метода), `lib/services/auth_state.dart`
(targets+connector wiring, рестарт при logout), `lib/i18n/app_strings.dart`
(RU/EN строки), `test/rdp_tunnel_test.dart` (машина состояний, разбор
ошибок — по образцу `ws_backoff_test.dart`).

---

## 4. Self-служба: Ligament Endpoint Service (Windows-сервис в MSI)

### 4.1 Назначение и сценарий

Служба на ЦЕЛЕВОМ ПК (куда подключаются): сама инициирует исходящий
WSS к ядру, регистрируется по agent_key, поддерживает online-статус
цели и по команде ядра (`agent_dial`) открывает TCP к `127.0.0.1:3389`
и перекачивает байты. Входящих портов нет вообще (дизайн §1: «Входящий
TCP 3389 на Relay, Core и Windows-компьютере не публикуется»).

### 4.2 Контракт `/api/v1/rdp/agent/connect` (ТРЕБУЕТСЯ СЕРВЕРУ, S2)

Монтируется рядом с `/api/v1/relay/connect` (`router.go:626`) по
образцу `RelayHub.HandleConnect` (`relay_hub.go`):

- `GET wss://<core>/api/v1/rdp/agent/connect`, авторизация —
  `Authorization: Bearer <agent_key>` (только заголовок; relay
  допускает ещё query — для агента НЕ копировать, ключ длинный);
- `agent_key` — строка `<agent_key_uuid>:<hex-secret>`; сервер хранит
  только sha256(secret) (паттерн `HashRelayToken`), uuid — это
  существующая колонка `rdp_endpoints.agent_key_id`, по которой уже
  написан `RdpEndpointTouch(agent_key_id, version)` — секрет НЕ нужен
  в БД;
- невалидный ключ → `401 invalid_agent_key`; endpoint `enabled=false`
  → `403 endpoint_disabled` (fail-closed).

Кадры после upgrade (текстовые = JSON-управление, бинарные = данные):

```text
агент → ядро:  {"type":"agent_hello","version":"<semver>","capabilities":{"rdp":true,"max_streams":8}}
ядро  → агент: {"type":"agent_dial","stream_id":N,"grant_id":"...","session_id":"..."}   // host/port НЕ передаются
агент → ядро:  {"type":"agent_opened","stream_id":N} | {"type":"agent_error","stream_id":N,"error":"..."}
обе стороны:   бинарный кадр = сырые байты ↔ TCP 127.0.0.1:3389
агент → ядро:  {"type":"agent_close","stream_id":N,"reason":"..."}
ядро  → агент: {"type":"agent_close","stream_id":N,"reason":"revoked|closed|..."}
```

Правила: агент набирает **только** `127.0.0.1:3389` (host из кадра
игнорируется — allowlist зашит, дизайн §4 «Endpoint Service открывает
только локальный RDP»); несколько параллельных stream_id (терминальный
сервер) — map stream→SOCKET; разрыв WSS закрывает все стримы; heartbeat
— WS ping/pong 20с + на каждый pong сервер делает `RdpEndpointTouch`
(online, last_seen_at, agent_version); при disconnect ядро ставит
endpoint offline (по образцу relay-клиентов хаба).

Серверная ветка в `handleConnectWS`: `case "agent": dst =
agentHub.DialByEndpoint(g.EndpointID, g.ID, sessID)` — коннект до
живого агента этого endpoint, далее тот же `bridgeRDP` (S1).

### 4.3 Доставка agent_key (админка показывает ОДИН раз)

1. Админ в админке создаёт цель → endpoint `kind=agent`;
2. Сервер генерирует `agent_key = "<uuid>:<32B hex>"`, сохраняет
   `agent_key_id` (уже есть) + `sha256(secret)` (новая колонка
   `agent_key_hash` в `rdp_endpoints`, миграция — S2), показывает ключ
   **один раз** с явным предупреждением (паттерн relay-токенов в
   админке);
3. Админ кладёт ключ в конфиг службы на ПК (см. §4.5) — вручную или
   GPO-скриптом;
4. Перевыпуск ключа — тем же путём (старый мгновенно невалиден).

### 4.4 Реализация: отдельный C++ exe `ligament_endpoint.exe`

Выбор: **нативный C++17 (WinHTTP + WinHTTP-WebSocket), статический
CRT**, новый таргет `windows/endpoint_service/` — по образцу
`windows/service/` (SCM-скелет service.cpp копируется), HTTP/TLS-паттерны
— из `windows/credential_provider/HttpApiClient.cpp` (там уже есть
разбор ServerURL, TLS-верификация, AllowSelfSigned, лог в ProgramData с
DACL `D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)`).

Альтернативы (отклонены/отложены):
- `dart compile exe` — быстрый старт (переиспользование Dart-логики), но
  ~10–15 МБ, свой рантайм GC в службе, лишняя точка поставки Flutter
  SDK в CI; вернуть к этому решению, если C++-WebSocket окажется
  дороже оценки;
- Go (как сервер) — отличный websocket-стек, но второй тулчейн в
  Windows-сборке ligament-apps; допустимо, только если служба будет
  собираться в репо 2fa (решение за владельцем релизного конвейера).

Структура: `windows/endpoint_service/endpoint_service.cpp` +
`agent_ws.cpp/h` (коннект/бэкофф/протокол) + `CMakeLists.txt`
(`MultiThreaded` статический рантайм, как у `ligament_service`).

Функциональность:
- чтение конфига: `HKLM\SOFTWARE\Policies\Ligament\2FA\` →
  `HKLM\SOFTWARE\Ligament\2FA\` (приоритет Policies — как CP и
  `GpoService`): `ServerURL` (уже пишется MSI-компонентом
  `AppServerUrlRegistry`!), `RdpAgentKey` (новый DWORD-строковый),
  `RdpAgentEnabled` (DWORD, 0 = пассивна);
- WSS-коннект с backoff: экспонента 1с→2с→…→капа 60с, джиттер ±20%,
  сброс после 60с стабильности — это дословно `ReconnectBackoff` из
  `lib/services/ws_service.dart` (порт 1:1, юнит-тесты логики уже
  есть — `test/ws_backoff_test.dart` — перенести в C++-тест);
- стримы: `std::map<uint64_t, SOCKET>`, перекачка `WSARecv/WSASend` ↔
  WinHTTP-WebSocket-фреймы в 2 потока на стрим (или IOCP — v1 достаточно
  потоков: терминальный сервер ≤ 8 стримов);
- сервис: `SERVICE_WIN32_OWN_PROCESS`, `Start=auto` (стартует до
  логона), `LocalSystem` (сетевые права есть, UI нет — session 0, для
  чистой перекачки не нужно);
- лог: `C:\ProgramData\Ligament\endpoint.log` с тем же DACL.

### 4.5 MSI-компоненты

Правки `windows/installer/Product.wxs` (+ `scripts/build_msi.ps1` —
шаг сборки по образцу `[2b/5] ligament_service`):

```xml
<Property Id="AGENTKEY" Secure="yes" />   <!-- msiexec ... AGENTKEY=uuid:hex -->
<Component Id="EndpointServiceComponent" ...>
  <File Source="windows/endpoint_service/build/Release/ligament_endpoint.exe" />
  <ServiceInstall Name="LigamentEndpointService" Start="auto" Type="ownProcess" .../>
  <ServiceControl ... Start="install" Stop="both" Remove="uninstall" />
  <RegistryValue Root="HKLM" Key="SOFTWARE\Ligament\2FA"
                 Name="RdpAgentKey" Type="string" Value="[AGENTKEY]" />
</Component>
```

Ключ в реестре HKLM читают только SYSTEM/Admins — ветка наследует DACL
HKLM; `RdpAgentEnabled=0` по умолчанию (opt-in, как
RDP2FAEnabled у CP): служба стоит у всех, активируется ключом+тумблером.

### 4.6 Взаимодействие с CP на цели (уже готово)

Когда подключение приходит через шлюз, на цели CP спрашивает
`/api/v1/cp/rdp-mfa-satisfied` и получает `satisfied:true` (активная
сессия гранта) → второй фактор не запрашивается повторно. Ничего
делать не нужно — проверить интеграционно (§8, AC-6).

### 4.7 Служба vs self: что нужно от остальных win-компонент

- CP — без изменений (гейт уже в этапе 3);
- watchdog `Ligament2FAService` — без изменений;
- приложение — без изменений на цели (если стоит): служба самостоятельна.

---

## 5. Режим «Экран» (переиспользование SOS с флагом owner)

### 5.1 Что переиспользуется 1:1 (код не дублируется)

Сторона ЦЕЛИ (приложение на своём ПК, свёрнуто в трей):
- `lib/services/support_service.dart` → `startScreenSharing()` целиком:
  desktopCapturer → getDisplayMedia → RTCPeerConnection → DataChannel
  `'input'` → offer/ICE через сигналинг, resilience (ICE-restart,
  establishment timeouts), tuning 2.5 Мбит, wakelock;
- state-машина SupportSessionState, баннер активной сессии на главной.

Сторона ЗАПРАШИВАЮЩЕГО (телефон/другой ПК того же юзера):
- `lib/screens/support_operator_screen.dart` как viewer: рендер,
  масштабирование координат ввода к видео, хоткеи, clipboard, чат —
  вход в экран уже написан;
- `lib/services/input_injector.dart` — инъекция ввода на цели (Win32
  SendInput, macOS Accessibility).

Транспорт сигналинга: существующие
`POST /api/v1/app/support/{id}/signal` и WS-пуши `support_signal` /
`support_ended` (`ws_service.dart`).

### 5.2 Инверсия сценария и флаг owner

Сегодня: сотрудник просит помощь (`requestSupport`) → инженер жмёт
«Подключиться» (`connectToSupportSession` → `number_match`) → на цели
приходит `support_prompt` → accept-диалог → sharing.
Owner-режим: инициатор — ВЛАДЕЛЕЦ с плитки (grant `mode:"screen"`):

```text
Плитка «Экран» → POST /rdp/grant {target_id, mode:"screen"}
  → сервер (S3): создаёт support-сессию c owner=grant.user_id,
    пушит на устройство ЦЕЛИ (app-WS): {"type":"support_prompt",
    "session_id":..., "owner":true, "initiator_device_id":...}
  → приложение ЦЕЛИ: owner && session.user == локальный app-user
      → БЕЗ accept-диалога и без number-match: startScreenSharing()
  → запрашивающее устройство: открывает SupportOperatorScreen
    (viewer) — тем же connect-эндпоинтом, но connect разрешён
    владельцу сессии, а не только роли инженера
```

Правки клиента:
- `AuthState`/`HomeScreen`: ветка `ws.onSupportPrompt` с
  `prompt['owner'] == true` → вызов `support.startScreenSharing()`
  напрямую (минуя `SupportApprovalModal`); проверка «свой юзер» — по
  данным локальной сессии приложения (device-токен уже свой; сервер
  шлёт только устройству владельца — двойная проверка);
- `SupportOperatorScreen`: параметр `mode: owner` — скрыть
  инженерные элементы очереди, доступ без `isEngineer`; сессия в
  списке «Активная сессия» с кнопкой «Завершить» (уже есть в
  `endSupportSession`);
- access mode всегда `full_control` (свой ПК).

### 5.3 Гвозди (permission-модель)

1. **Токен приложения ≠ согласие человека.** У кого угодно с украденным
   device-токеном юзера появится «Экран моего ПК». Защиты: grant требует
   свежую MFA-попытку (428-гейт уже в коде сервера) + аудит
   `rdp_grant_issued mode=screen` + на цели НЕЗАкрываемый баннер «Ваш
   экран открыт вам с устройства X» + настройка пользователя
   «Разрешить экран моего ПК» (default ON, выключается в Settings);
   тот же юзер = модель «сам себе» по дизайн-доку §15.2 не требует
   отдельного consent-контракта, но аудит-трейл обязателен.
2. **Инициация от плитки ≠ наличие цели.** «Экран» должен работать,
   когда цель offline для RDP-маршрута, но приложение цели живо (оно и
   есть агент экрана). Для owner-экрана серверу достаточно знать
   device-пуш цели — предложение: `rdp_endpoints` при `kind=agent`
   связывать с `app_devices` (S3 решает; клиенту без разницы).
3. **Кто может подключиться к сессии**: v1 — только инициатор (grant
   user) и только с одного устройства; инженерские роли НЕ получают
   доступ к owner-сессии (это не SOS-обращение).
4. **Сессия цель-приложения**: приложение цели должно быть запущено и
   залогинено тем же юзером; иначе плитка получает понятный
   «Цель offline» (тот же онлайн-индикатор §2.3).

### 5.4 Оценка переиспользуемости

~85% кода готово: меняются только входные точки (инициация, обход
диалога, роли). Новый клиентский код: флаг-обработка в
`auth_state.dart`, режим `owner` в `support_operator_screen.dart`,
кнопка плитки, строки i18n.

---

## 6. PWA `/rdp/session/:id` (только контракт; серверный фронт — S4)

Клиент в этапе 2 ограничивается запуском внешнего окна браузера
(`url_launcher`, уже используется в `apps_screen.dart`; standalone —
`display: standalone` в manifest сервера). Контракт:

- URL: `https://<core>/rdp/session/<session_id>`; идентификатор
  сессии — НЕ секрет;
- авторизация страницы — существующей web-сессией кабинета (cookie);
  ЛИБО одноразовый короткоживущий page-ticket: клиент после гранта
  делает `POST /api/v1/app/rdp/pwa-ticket {grant_id}` →
  `{"url":"/rdp/session/<id>?t=<одноразовый-короткоживущий-ticket>"}` — выбор за
  сервером; **grant-токен в URL запрещён** (дизайн §5: не в query,
  Referer, логи; §15.1 — уже отвергнутый мост с токеном в `.rdp`);
- страница: показывает целевой ПК, статус туннеля, кнопки «Подключить
  (HTML5-RDP)» / «Завершить»; закрытие сессии — через существующий
  `POST /api/v1/app/rdp/close` от имени юзера;
- клиент НЕ встраивает страницу в WebView (плагина нет), только
  `launchUrl(externalApplication)`; кнопка на плитке появляется, когда
  сервер объявит возможность (например, поле `capabilities.pwa` в
  `/rdp/targets` после S4 — до этого плитка PWA-кнопку не рисует).

Это этап 7 серверного плана (bridge/browser) — НЕ блокирует этапы
2.1–2.4 клиента.

---

## 7. Порядок работ, оценки, приемка

| Этап | Содержание | Зависимости | Оценка | Приемка |
|---|---|---|---|---|
| 2.1 | Плитка: `client.dart` + `auth_state` + секция главной + i18n + тесты | сервер этапа 1 (готов) | 2–3 д | плитка с online-индикатором; 428/403/409 обрабатываются текстами; empty- и offline-состояния |
| 2.2 | Коннектор Windows: `rdp_service.dart` + `RdpConnectDialog` + mstsc + close | **S1** (WS-мост на сервере) | 4–5 д (кл) + 2–3 д (S1, сервер) | RDP через relay И direct проходит mstsc↔плитка; закрытие mstsc = close; kill-switch рвёт туннель; байты в `rdp_sessions` растут |
| 2.3 | Endpoint Service: C++ exe + WS-агент + MSI + выдача agent_key | **S2** | 6–8 д (кл+MSI) + 4–5 д (S2, сервер) | цель за NAT без 3389 доступна через плитку; offline→online по ключу; автозапуск до логона; backoff при обрыве ядра; CP не спрашивает вторую MFA |
| 2.4 | «Экран»: owner-флаг + viewer-режим | **S3** | 3–4 д (кл) + 3–4 д (S3, сервер) | с телефона виден экран своего ПК; без accept-диалога; баннер на цели; «Завершить» с обеих сторон |
| 2.5 | PWA-контракт (кнопка-заглушка) | S4 (можно позже) | 0,5 д | кнопка появляется только при `capabilities.pwa` |

Суммарно клиент: ~16–20 рабочих дней; серверные предусловия S1–S3: ~10–12
дней (другая команда/репо, частично параллельно).

## 8. Риски и открытые технические решения

- **R1 — Dart-слушатель в UI-изоляте.** Решение §3.3 (addStream,
  main isolate) — контрольный замер на этапе 2.2: прогон тяжёлого
  RDP-сеанса (графический контент, ~5–10 Мбит/с) с открытым
  PerformanceOverlay; при jank > 16мс кадров — вынос в `Isolate`
  (архитектура уже предусмотрена: все зависимости pure dart:io).
- **R2 — одноразовость гранта vs автопереподключение mstsc.** Повторное
  TCP-соединение mstsc к слушателю после микроразрыва отвергается
  (грант погашен). Слушатель принимает ровно одно соединение и умирает
  вместе с ним; UI предлагает «Подключиться снова» (новый грант).
  Осознанное ограничение MVP (trust window = 0 по дизайн-доку §11).
- **R3 — agent_key в реестре.** Читается только SYSTEM/Admins, но
  админ машины — всегда может вытащить; это соответствует модели
  «админ цели = доверенное лицо» (как relay-токены). Перевыпуск —
  одной кнопкой в админке.
- **R4 — C++ WebSocket.** WinHTTP-WebSocket — с Windows 8+, в т.ч.
  Server; риск низкий, но если сборка/стабильность подведут — план Б
  `dart compile exe` (§4.4), контра́кт не меняется.
- **R5 — MSI-объём.** +1 компонент-служба; обновление на живых
  инсталляциях — MajorUpgrade уже настроен, служба остановится по
  `ServiceControl Stop="both"`.
- **R6 — выход из приложения с живым туннелем.** `HomeScreen`/трей:
  при активном `RdpTunnelSession` показывать подтверждение выхода
  («Завершится RDP-сессия»); свернуть в трей — привычный путь.
- **R7 — многопользовательский терминальный сервер.** Агент держит N
  стримов; `max_sessions` уже гейтится сервером (409 target_busy);
  протестировать 3+ параллельных mstsc.
- **R8 — 127.0.0.2 на не-Windows десктопах.** macOS/Linux loopback
  алиас 127.0.0.2 работает, но mstsc-режим ограничен `Platform.isWindows`
  — для остальных платформ этапа 2 остаётся «Экран»/PWA.

## 9. Открытые вопросы (к владельцу сервера)

- **Q1 (блокер UX 428):** создаёт ли `POST /api/v1/app/login` с кодом
  второго фактора запись `login_attempts status='completed'`? Если нет —
  владелец ПК не сможет получить грант, не сходив в веб-кабинет; нужен
  либо явный «rdp-mfa»-вход, либо документированный сценарий. Проверить
  до этапа 2.2 на реальном стенде.
- **Q2:** включение `route=agent` в `/rdp/targets.online` для плитки —
  сейчас online считается по `rdp_endpoints.status`, кто переводит в
  offline при тихой смерти агента (deadline по last_seen) — S2.
- **Q3:** выбор языка Endpoint Service (C++ vs Go vs dart-native) —
  финально за релиз-инженерией (§4.4 рекомендует C++).

## 10. Инвентарь файлов

Переиспользуются без изменений: `lib/services/ws_service.dart`
(ReconnectBackoff — эталон для C++-порта), `lib/services/input_injector.dart`,
`lib/services/local_detect_service.dart` (паттерн loopback-слушателя),
`lib/screens/support_operator_screen.dart` (viewer), `windows/service/service.cpp`
(SCM-скелет), `windows/credential_provider/HttpApiClient.cpp` (WinHTTP/TLS-паттерны),
`windows/installer/Product.wxs`, `scripts/build_msi.ps1`.

Правятся: `lib/api/client.dart`, `lib/services/auth_state.dart`,
`lib/screens/home_screen.dart`, `lib/i18n/app_strings.dart`,
`pubspec.yaml` (без новых зависимостей — web_socket_channel/http уже есть),
`windows/installer/Product.wxs`, `scripts/build_msi.ps1`.

Новые: `lib/services/rdp_service.dart`, `lib/screens/rdp_connect_dialog.dart`,
`lib/widgets/my_pc_tile.dart`, `windows/endpoint_service/{endpoint_service.cpp,agent_ws.cpp,agent_ws.h,CMakeLists.txt}`,
`test/rdp_tunnel_test.dart`, `test/rdp_targets_test.dart`.
