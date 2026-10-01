# Windows Identity: мониторинг и подтверждение пользователя

**Дата:** 2026-09-15
**Задача:** приложение должно автоматически подтягивать пользователя из Windows и (а) подтверждать, что аккаунт приложения принадлежит текущему пользователю Windows, (б) передавать это на сервер для мониторинга/аудита.

Это НЕ безпарольный SSO-вход: пароль/2FA остаются, а Windows-идентичность становится **сигналом аттестации** — привязкой «кто в приложении» к «кто за машиной».

---

## 1. Модель угроз, которую это закрывает

| Сценарий | Что видно сегодня | Что даёт Windows-identity |
|---|---|---|
| Сотрудник передал токен/аккаунт коллеге на той же машине | Незаметно: сессия «работает» | Сервер видит: аккаунт ivanov, а за Windows-сессией petrov → событие `identity_mismatch` |
| Учётка приложения запущена под чужой Windows-сессией (шаринг рабочих станций, RDP-прыжки) | Незаметно | Mismatch-баннер в приложении + алерт в `/admin/users` |
| Мониторинг «кто где вошёл» | Только device_name | Истинный Windows-пользователь + машина + домен в телеметрии |

Важно понимать границу: `GetUserNameW` подтверждает, **под чьей учёткой выполняется процесс**. Это честная привязка к Windows-сессии (подделать = запустить процесс под чужой учёткой, т.е. уже иметь её креды). Это не защита от самого владельца учётки.

---

## 2. Архитектура (реализовано на клиенте, контракты — для сервера)

### 2.1 Клиент

1. **Источник истины — Win32 API, не переменные окружения.** `USERNAME`/`USERDOMAIN` из env подменяются тривиально; `advapi32!GetUserNameW` и `kernel32!GetComputerNameExW` (DNS/NetBIOS-имена) через собственный FFI (по образцу `input_injector.dart`, зависимость `ffi` уже есть). Работает и под доменной учёткой (NetBIOS-домен — `GetUserNameExW` NameSamCompatible: `CORP\ivanov`).

2. **Новый сервис** `lib/services/windows_identity.dart`:
   - `collect()` → `{ windows_user, windows_domain, computer_name, is_domain }`;
   - кэш на время жизни процесса (identity сессии не меняется);
   - не-Windows платформы → `null` (поля не отправляются).

3. **Потоки данных:**
   - **Логин** (`POST /api/v1/app/login`): в payload добавляется `windows_identity: {...}` — сервер с первой сессии знает связку аккаунт↔Windows-пользователь↔машина.
   - **Телеметрия** (`collectPosture`, отправка раз в интервал GPO): те же поля едут в `security_posture` — мониторинг живёт на потоке телеметрии: расхождение видно сразу, а не только при логине.
   - **Подтверждение в рантайме** (`AuthState`): `currentUser.username` сравнивается с `windows_user` (без домена, case-insensitive). Результат — `windowsIdentityMatch: true|false|null` (null = не-Windows/неизвестно). UI может показывать индикатор; mismatch уходит с телеметрией как `identity_mismatch: true`.

### 2.2 Контракты для сервера (вне этого репозитория)

- `POST /api/v1/app/login` и `POST /api/v1/app/telemetry` — принимать/игнорировать `windows_identity` (unknown-поля не ломают клиент, можно включать постепенно).
- Аудит-событие `identity_mismatch` (username аккаунта ≠ windows_user при совпадающей машине) → журнал + опционально алерт администратору в `/admin/users`.
- Политика (на будущее): `RequireWindowsIdentityMatch` — при mismatch отклонять approve-решения с устройства (серверная проверка при `challenges/{id}/decision`).

### 2.3 Усиление на будущее (фаза 2, по требованию)

Если понадобится криптографическая гарантия (а не «честный клиент»):
- **Nonce от credential provider:** CP уже валидирует пароль+2FA при входе в Windows. В ответе `/api/v1/auth/poll` сервер может вернуть одноразовый `sso_ticket` (привязка user+machine, TTL ~5 мин), CP пишет его в `C:\ProgramData\Ligament\sso.bin` с DACL на SID залогиненного пользователя; приложение при старте читает билет и предъявляет серверу. Это закрывает сценарий «процесс под другой учёткой шлёт чужое имя» и превращает мониторинг в доказательство.
- **Kerberos/SPNEGO** (`Authorization: Negotiate`) — каноничный вариант, но требует AD-joined бэкенд с SPN и полностью меняет модель входа; сюда не включал осознанно.

---

## 3. Что вошло в этот коммит (клиент)

- `lib/services/windows_identity.dart` — FFI GetUserNameW/GetComputerNameExW + SAM-compatible домен.
- `lib/api/client.dart` — `windowsIdentity` в `login()`.
- `lib/services/telemetry_service.dart` — поля identity в `collectPosture()`.
- `lib/services/auth_state.dart` — `windowsIdentityMatch` + передача в login/telemetry.

Серверные части (аудит `identity_mismatch`, политика RequireWindowsIdentityMatch) — задачи для бэкенд-репозитория.
