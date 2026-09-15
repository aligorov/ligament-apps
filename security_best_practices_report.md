# Security Audit — Ligament 2FA (клиентские приложения)

**Дата:** 2026-09-15
**Объект:** `ligament-apps` v1.0.9+20 — Flutter-клиент (Windows/macOS/Linux/Android/iOS), Windows Credential Provider (C++), скрипты установки, GPO/MDM-политики.
**Метод:** статический анализ кода (Dart/C++/PowerShell/конфигурации), проверка git-истории.

---

## Резюме

Приложение — корпоративный 2FA-клиент с расширенным функционалом: push-подтверждения с number matching, удалённая поддержка (WebRTC-трансляция экрана + **удалённое управление вводом**), Windows credential provider на экране входа, телеметрия.

Общая гигиена кода хорошая: токен в secure storage, пароли затираются `SecureZeroMemory` + `CredProtect`, number matching реализован, fail-close по умолчанию, секретов в git нет. Однако найдены **2 критические** и **4 высокоуровневые** проблемы, главные из которых — передача сессионного токена и доменных учётных данных по незашифрованным каналам на филиальные relay-узлы, а также обширная поверхность удалённого управления вводом, которая при краже токена превращает аутентификатор в инструмент атакующего.

---

## CRITICAL

### C1. Bearer-токен сессии передаётся по незашифрованному WebSocket на relay-узлы

**Файлы:** `lib/services/auth_state.dart:321-325`, `lib/services/ws_service.dart:59-80`, `lib/api/client.dart:79-89`

Failover-список relay-узлов строится как `http://$ip:8082` (`auth_state.dart:324`), а `ws_service.dart:61-63` превращает `http://` в `ws://` — **без проверки схемы** (для основного сервера экран подключения требует HTTPS, для relay — исключение). Заголовок `Authorization: Bearer <token>` (`ws_service.dart:72`) уходит в открытом виде по локальной сети филиала. Список relay берётся из ответа сервера (`last_ip`) и кэшируется в SharedPreferences — клиент доверяет ему безусловно.

**Impact:** атакующий в сегменте сети (ARP-spoofing, rogue DHCP, компрометация L2) перехватывает долгоживущий токен сессии устройства. Токен даёт: `POST /api/v1/app/challenges/{id}/decision` — **программное подтверждение любого входа** (контрольное число `number_match` приходит в том же pending-списке, угадывать не нужно), чтение истории входов, инициирование/сигналинг сессий поддержки. Т.е. полный обход 2FA. Дополнительно по этому же каналу доставляются `support_signal`-сообщения (см. H3).

**Рекомендация:** relay только по `https/wss` (с валидацией сертификата); токен в WS — одноразовый ticket, а не основной session token; удалить кэширование не-TLS relay.

### C2. Credential Provider отправляет доменные логин/пароль на relay-узел (возможно по HTTP)

**Файлы:** `windows/credential_provider/common.h:44` (пример `http://192.168.10.50:8082`), `HttpApiClient.cpp:174-268` (`SendRelayRequest`), `HttpApiClient.cpp:485-508` (fallback в `VerifyCombined`)

При недоступности центрального сервера (network error / 5xx) провайдер **на экране входа Windows** отправляет `username` + `password` на филиальный relay. Схема не валидируется: конфиг с `http://` означает передачу доменных учётных данных открытым текстом. Relay-ответ `{"ok":true}` безусловно логинит пользователя (`LigamentCredential.cpp:495-497`).

**Impact:** MITM в филиальной сети перехватывает доменные учётные данные с экрана входа; подменённый ответ relay (`{"ok":true}`) позволяет войти в Windows без знания пароля.

**Рекомендация:** жёстко запретить `FallbackRelayURL` со схемой `http://` в релизной сборке (или требовать pinned сертификат); при недоступности relay — fail-close.

---

## HIGH

### H1. `AllowSelfSigned` отключает ВСЕ проверки сертификата (включая ретрай)

**Файлы:** `windows/credential_provider/HttpApiClient.cpp:112-118, 128-135`

Флаг игнорирует `UNKNOWN_CA | DATE_INVALID | CN_INVALID | WRONG_USAGE` — т.е. принимает **любой** сертификат, и повторно ретраит с отключённой валидацией при ошибке. По умолчанию выключен (хорошо), но включается одной настройкой реестра, а по канону должен был бы игнорировать только самоподписанные корни (pin доверенного отпечатка). В сочетании с C2 — кража доменных кредов.

**Рекомендация:** заменить на `CertPinThumbprint` (SHA-256 отпечаток в реестре); как минимум — игнорировать только `UNKNOWN_CA`, но не `CN_INVALID`.

### H2. Сигнальный канал сервера управляет мышью/клавиатурой жертвы (input injection по WS)

**Файлы:** `lib/services/support_service.dart:528-590, 763-901`, `lib/services/input_injector.dart` (весь)

`_handleRemoteInput` исполняет команды `mouse_move/click`, `key_down/up`, `wheel`, `hotkey` (Win-клавиши, Alt+F4, Ctrl+Alt+Del-эмуляция, `win_l`), `block_input` (ClipCursor+BlockInput — **блокировка локального пользователя**), `clipboard_get` (чтение буфера обмена — туда копируют пароли из PM), `clipboard_set`, приём файлов. Команды приходят как через DTLS-защищённый DataChannel, так и через серверный сигнальный канал (`handleRemoteSignal` при живом `_peerConnection`). Гейт `view_only` — только на клиенте.

**Impact:** кража токена (C1) или компрометация сервера/аккаунта инженера = полнофункциональный RAT на рабочих станциях сотрудников с 2FA-клиентом (при активной сессии поддержки). `block_input` позволяет заблокировать локального пользователя.

**Рекомендация:** ввод только через DataChannel (запретить `input_control` из серверного сигнала); `clipboard_get`/`block_input` — за явной политикой/подтверждением; журналирование всех команд ввода на сервер (audit trail); индикатор активной сессии, который нельзя скрыть.

### H3. Лог CP в `%ProgramData%\Ligament\cp.log`: слабые ACL + утечка имён пользователей

**Файлы:** `windows/credential_provider/common.h:190-207`, `LigamentCredential.cpp:1134-1163`

Каталог и файл создаются `CreateDirectoryW/CreateFileW` **без явного DACL**. По умолчанию Users могут создавать каталоги в ProgramData → стандартный пользователь может пре-создать `C:\ProgramData\Ligament\cp.log` (или symlink) до того, как это сделает SYSTEM, и тогда credential provider (контекст winlogon/SYSTEM) пишет в контролируемый пользователем файл — классическая атака на локальное повышение привилегий (log-forging, symlink-append). Файл читаем всеми: логируются имена пользователей (`pack: user="%s"`, `LigamentCredential.cpp:1327`), IP, NTSTATUS (пароль не логируется — это да).

**Рекомендация:** MSI/установщик создаёт каталог с ACL «SYSTEM/Administrators only»; в коде — `CreateFileW` c `SECURITY_ATTRIBUTES` (или писать в `%ProgramData%` через установленный заранее путь), `FILE_FLAG_OPEN_REPARSE_POINT` для защиты от symlink.

### H4. `install-latest.ps1`: `irm | iex` + установка DLL в logon-цепочку без проверки подписи/хэша

**Файлы:** `scripts/install-latest.ps1` (заголовок, загрузка MSI/ZIP с GitHub Releases), DLL копируется в System32 и регистрируется как credential provider.

Скрипт скачивает артефакты с `github.com/aligorov/ligament-apps/releases` и выполняет с правами администратора без проверки Authenticode-подписи или SHA-256. Репозиторий публичный.

**Impact:** компрометация GitHub-аккаунта/репозитория = массовое развёртывание вредоносного кода с админ-правами в цепочку входа в домен (supply chain).

**Рекомендация:** подписать MSI и CP-DLL Authenticode; в скрипте проверять подпись (`Get-AuthenticodeSignature`) и/или пиннинг хэша версии;убликовать на собственном сервере обновлений с GPO-управлением.

---

## MEDIUM

### M1. Политики macOS читаются из user-writable домена `defaults`
`lib/services/gpo_service.dart:220-237` — после Managed Preferences идёт fallback на `defaults read com.ligament.twofa`, а это `~/Library/Preferences/...`, доступное пользователю на запись. Без установленного MDM-профиля пользователь сам себе выключает `RequireTouchID`/`AllowExit`/меняет `ServerURL` (в т.ч. на `http://`). Рекомендация: если профиля MDM нет — политики не применять вовсе, а не читать из user-домена.

### M2. Number matching: правильное число приходит на клиент вместе с челленджем
`lib/screens/approval_modal.dart:32-51`, `lib/api/client.dart:168-178` — модалка генерирует 3 опции из полученного `number_match`, проверка `_selectedMatch != expectedMatch` — на клиенте (`approval_modal.dart:144-149`). Сервер обязан отвергать `decision` без верного `number_match` (код ошибки `number_match_mismatch` обрабатывается — признак серверной проверки есть). Защита держится только на сервере и секрете токена — ещё одна причина закрыть C1.

### M3. Android: relay-failover сломан + `allowBackup` не отключён
`android/app/src/main/AndroidManifest.xml` — нет `android:usesCleartextTraffic` (на targetSdk 28+ cleartext запрещён → HTTP-relay на Android молча не работает, при том что на десктопе работает — несогласованность, маскирующая C1). Не задан `android:allowBackup="false"` — SharedPreferences (server_url, кэш relays) попадают в adb-backup/перенос. Рекомендация: `allowBackup=false`, `dataExtractionRules`, network security config с явным `cleartextTrafficPermitted=false`.

### M4. Публичные STUN-серверы Google/Cloudflare в WebRTC
`lib/services/support_service.dart:415-422` — утечка метаданных (IP-адреса сотрудников стучатся к публичным STUN), TURN нет (доступность). Для корпоративного продукта — свой STUN/TURN за периметром.

### M5. Наивный JSON-парсинг в CP
`common.h:320-372` (`ExtractJsonString/Bool/Int`) — substring-поиск без экранирования `\uXXXX`/`\"` и без контекста вложенности. Ответы сервера содержат пользовательские строки (имена машин, сервисы) — возможен парсинг-конфуз, влияющий на решение о входе. Рекомендация: настоящий JSON-парсер (например, json.hpp) — блок критичной логики входа.

---

## LOW

- **L1.** `WebAuthnFinish` передаёт handle в query string (`HttpApiClient.cpp:571`) — попадает в логи прокси. Одноразовый handle — риск минимальный.
- **L2.** `ErrorWidget.builder` (`lib/main.dart:21-47`) показывает текст исключения пользователю в release — мелкая утечка внутренностей.
- **L3.** Токен не имеет видимого refresh/TTL-контроля на клиенте (`auth_state.dart`) — при длинном сроке жизни токена кража (C1) становится ещё опаснее. Рекомендация: короткоживущие токены + refresh.
- **L4.** Принятые от оператора файлы сохраняются в `Downloads/LigamentSupport` автоматически (`support_service.dart:314-366`) — лимит 50 МБ и санитизация имени есть, но нет антивирусной проверки/подтверждения пользователем.
- **L5.** SAM-probe в `ReportResult` (`LigamentCredential.cpp:1085-1107`) делает до 3 попыток `LogonUserW` на каждый неудачный вход — дополнительно раскручивает счётчик badPwdcount (риск преждевременного lockout).

---

## Что сделано правильно

- Токен — в `flutter_secure_storage` (Keychain/Keystore/DPAPI), с миграцией из SharedPreferences и затиранием legacy-копии (`auth_state.dart:152-166`).
- Пароль в CP: `SecureZeroMemory` в деструкторе и `ReportResult`, `CredProtectW` при сериализации (`LigamentCredential.cpp:1181-1198`).
- 2FA-статус не переживает смену пользователя/неудачный вход (`ResetAuthState`), автологон только после подтверждённого второго фактора.
- Fail-open строго для транспортных ошибок и только при `FailClose=0`; fail-close по умолчанию.
- Экран подключения валидирует схему (HTTPS-only) (`connect_screen.dart:33-57`).
- `AllowSelfSigned`/`BypassAccounts` — HKLM-only (нужен админ), закомментированы в шаблоне `.reg` с честными предупреждениями.
- В логах CP нет паролей и URL сервера из winlogon-контекста.
- Секретов в git-истории и трекинге не обнаружено; CI-секреты в workflows не светятся.

---

## Приоритет устранения

1. **C1 + C2** — relay только по TLS с валидацией сертификата; короткоживущие WS-ticket вместо основного токена. (Высокий приоритет: обход 2FA / кража доменных кредов.)
2. **H2** — запретить input-control из серверного сигнального канала; аудит-журнал команд ввода.
3. **H1 + H3 + H4** — pin сертификата вместо AllowSelfSigned; ACL на ProgramData\Ligament; Authenticode + проверка подписи инсталлятором.
4. M1–M5 по порядку.

---

## Статус исправлений (2026-09-15)

| ID | Статус | Что сделано |
|----|--------|-------------|
| C1 | ✅ Исправлено | `auth_state.dart`: relay-фолбэки строятся только из явных `https` URL от сервера (legacy IP-записи игнорируются); `ws_service.dart`: отказ подключения к non-`wss` кандидатам; `client.dart`: `probeRelay` переведён на https. ⚠️ Relay-серверы должны получить TLS + отдавать `url`/`last_url` с https — до этого failover не работает (намеренно). |
| C2 | ✅ Исправлено | `HttpApiClient.cpp: ParseRelayUrl` — не-HTTPS `FallbackRelayURL` отвергается, relay отключается. |
| H1 | ✅ Частично | `AllowSelfSigned` теперь игнорирует только `UNKNOWN_CA` (имя хоста/сроки/назначение проверяются всегда); удалён ретрай с отключённой валидацией. Полный pin отпечатка — рекомендация на будущее. |
| H2 | ✅ Исправлено | `support_service.dart: handleRemoteSignal` — серверный сигнальный канал пропускает только WebRTC SDP/ICE и чат; команды ввода/буфера/файлов исполняются исключительно из DTLS DataChannel. |
| H3 | ✅ Исправлено | `common.h: LogCPFileLine` (и `CPLog` переведён на него) — каталог/файл cp.log с явным DACL `SYSTEM+Admins full` (protected), перехват владения pre-created каталогом, отказ от записи через reparse point. |
| H4 | ✅ Исправлено | `install-latest.ps1`: `Assert-ArtifactTrusted` — валидная подпись ОК; неподписанный артефакт требует подтверждения/`-AllowUnsigned`; битая подпись — жёсткий отказ. Проверяются MSI и CP DLL до копирования в System32. ⚠️ Релизные артефакты нужно подписать Authenticode. |
| M1 | ✅ Исправлено | `gpo_service.dart`: macOS-политики читаются только из MDM Managed Preferences и `/Library/Preferences` (админ); user-домен удалён. |
| M2 | ➖ Сервер | Серверная валидация number_match обязательна (клиентскую проверку см. approval_modal.dart). |
| M3 | ✅ Исправлено | `AndroidManifest.xml`: `allowBackup=false` + `network_security_config.xml` (cleartext запрещён, только системные CA). |
| M4 | ➖ Инфра | Свои STUN/TURN за периметром — инфраструктурное решение. |
| M5 | ➖ Отложено | Замена наивного JSON-парсинга CP на полноценный — отдельная задача (риск регрессии логон-флоу, нужно тестирование на Windows). |
| L2 | ✅ Исправлено | `main.dart`: ErrorWidget в release показывает generic-текст. |
| L1, L3–L5 | ➖ Отложено | Низкий риск / серверная сторона / осознанная диагностика. |

**Проверки:** `flutter analyze` — чисто; `flutter test` — 4/4. C++ правки проверены ревью (сборка требует MSVC/Windows — прогнать `scripts/build_msi.ps1` на Windows-машине).

---

## Дополнение: ревью LigamentCredential.cpp (потоковая модель) — 2026-09-15

Глубокое ревью основного файла credential provider. Логика 2FA и KERB-сериализация корректны; найдены проблемы потоковой модели и поведенческая проблема конфигурации:

| ID | Суть | Статус |
|----|------|--------|
| F1 (высокий) | Гонка на `std::wstring m_statusText` между воркером опроса и потоком LogonUI (`GetStringValue`) — повреждение кучи в SYSTEM-процессе LogonUI. | ✅ Исправлено: воркер пишет только `m_pollState` под CS и `volatile bool m_authenticated`; тексты статуса применяет `GetSerialization` (PUSH/FIDO2 approved-ветки). |
| F2 (высокий) | Вызов `m_pProviderEvents->CredentialsChanged` из воркера по указателю, который параллельный `UnAdvise` может освободить (use-after-free) + нарушение STA-контракта. | ✅ Исправлено: `NotifyProviderChangedFromWorker()` берёт AddRef-ссылку под `m_csPoll`; `SetProviderEvents` тоже под CS. |
| F3 (средний) | SAM-проба (до 3× `LogonUserW`) после каждого неудачного входа: до 4 инкрементов badPwdCount на опечатку — ускоренный AD-lockout (DoS на чужие учётки). | ✅ Исправлено: проба за явным флагом `SamProbeEnabled` (по умолчанию ВЫКЛ). |
| F4 (средний) | Блокирующие HTTP-вызовы (`StartPush`/`WebAuthnBegin`/`VerifyCombined`) на потоке LogonUI — заморозка экрана входа до ~30-60с при сетевых проблемах. | ✅ Исправлено: все обращения к серверу переведены на асинхронный воркер (job-модель `WorkerState`/`StartWorkerJob`/`RunAsyncJob`, две фазы: стартовый вызов → опрос). `GetSerialization` больше не содержит ни одного сетевого вызова; inline `HttpApiClient` удалён из класса. Секреты задачи (пароль/OTP) затираются сразу после получения воркером. |
| F5 (низкий) | USHORT-усечка длин в KERB-блобе; `BypassAccounts` матчил короткое имя по любому домену (`administrator` отключал 2FA для `ANYDOMAIN\administrator`). | ✅ Исправлено: явный гард длин >64КБ; короткое имя bypass-списка действует только для входа без домена, доменные — только полным `ДОМЕН\user`/`user@domain`. |

### Поведенческое изменение по запросу владельца: нет ServerURL → 2FA полностью выключена

Раньше: отсутствующий `ServerURL` молча заменялся фантомным `https://twofa.corp.local`; на несконфигурированной машине при `FailClose=1` RDP-входы **блокировались**.

Теперь: `ServerURL` пуст/отсутствует (GPO/MSI/реестр) → провайдер пассивен: не создаёт свой тайл (`SetUsageScenario`) и **не подавляет штатный парольный тайл** (`Filter`) — RDP- и консольные входы идут без второго фактора. MSI без свойства `SERVERURL` пишет пустое значение — семантика согласована.

⚠️ Следствие для модели угроз: удаление значения `ServerURL` становится способом отключить 2FA на машине. Ключ HKLM-политик защищён правами администратора, но рекомендуется контроль через GPO (Central Store) и аудит изменения ключа `SOFTWARE\Policies\Ligament\2FA`.
