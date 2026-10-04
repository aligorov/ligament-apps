# Промт: серверная реализация Windows-identity (фазы 1, 2, 2b)

> Готовое задание для агента/сессии, работающей в репозитории сервера 2FA.
> Основано на docs/windows-identity-server-design.md и на ФАКТИЧЕСКИ
> реализованных клиентских контрактах ligament-apps v0.4.102+.

---

Задача: серверная часть Windows-identity для Ligament 2FA — фазы 1 (приём/мониторинг/аудит), 2 (sso_ticket как доказательство), 2b (SSO-мост в SAML/OIDC-сервисы).

Контекст:
- Главный документ (прочитать перед стартом): docs/windows-identity-server-design.md.
- Клиентская часть УЖЕ реализована и выпущена (ligament-apps v0.4.102+). Контракты ниже финальны и НЕ могут меняться — сервер подстраивается под них.
- Источник истины по клиентским форматам — код ligament-apps:
  - lib/api/client.dart — submitSsoTicket(), browserSsoDecision(), login() (поле windows_identity);
  - lib/services/auth_state.dart — normalizeBrowserSsoPrompt() (какие поля челленджа читаются);
  - lib/services/sso/sso_ticket_flow.dart — обработка кодов ответа;
  - windows/credential_provider/HttpApiClient.cpp PollStatus() — чтение sso_ticket из accept-ответа;
  - windows/credential_provider/common.h WriteSsoTicketFile() — куда и как CP кладёт билет.
- Модель: Windows-идентичность — НЕ вход без пароля, а аттестация «кто в приложении ↔ кто за машиной». Клиентские поля — заявление; билет CP — доказательство. Любой сбой = тихая деградация, вход/2FA не ломаются.

Реализовать по порядку:

1. Фаза 1 — приём, мониторинг, аудит
   - loginPayload (internal/api/app.go): принимать windows_identity {windows_user, windows_domain?, computer_name, is_domain}. Отсутствие/пусто = не-Windows клиент, не ошибка.
   - Телеметрия: поля уже едут в security_posture (app_devices.security_posture JSONB, internal/store/app_devices.go). Вердикт mismatch сервер считает САМ (клиентский флаг identity_mismatch — только сигнал, не истина): username аккаунта (lowercase, домен и @ отрезать) ≠ windows_user (lowercase, «ДОМЕН\» отрезать) на том же устройстве → identity_mismatch.
   - Миграция: колонка app_devices.identity_mismatch_at timestamptz (NULL = ок/нет данных). Проверять $n-нумерацию интеграционным тестом на реальном PG.
   - Аудит: identity_bound (первое появление windows_user на устройстве), identity_mismatch (троттлинг 1/час на (user, device) по образцу кулдауна wifiReject), identity_rebind (смена владельца машины; алерт только при чередованиях).
   - Карточка в /admin/users: «Windows: CORP\petrov → расхождение с аккаунтом ivanov, HH:MM» + время последнего mismatch.
   - Политика RequireWindowsIdentityMatch (глобальный тумблер + per-group по образцу groups_policy/trust-окон): гейт на POST /api/v1/app/challenges/{id}/decision при approve — незагашенный mismatch → 403 identity_mismatch. Deny всегда разрешён. Погашение: повторный вход на устройстве с совпавшей идентичностью.

2. Фаза 2 — sso_ticket: доказательство вместо заявления
   - Выдача: accept-ответ POST /api/v1/auth/poll дополняется полем sso_ticket (строка верхнего уровня, без экранирования — CP парсит наивным экстрактором, JWT base64url безопасен). Формат: HMAC/JWT, ключ — отдельная производная master_key (НЕ VAPID), claims: uid, jti, exp = +5 мин, опционально machine (клиент сравнивает с computer_name, DNS-суффикс-толерантно: 'ws-001' == 'ws-001.corp.local').
   - Приём: POST /api/v1/app/sso-ticket {"ticket": "..."} — коды контрактом зафиксированы клиентом:
     * 200 + {"expires_at": ...} — принят (expires_at: ISO-строка ИЛИ epoch-секунды — клиент парсит оба), ставит устройству identity_proof = cp_nonce с меткой времени;
     * 401 — подпись невалидна; 409 — истёк или jti уже погашен (клиент молчит и логирует);
     * 404 — фича выключена: клиент НЕ повторяет до перезапуска приложения (включение/выключение бесшовно, без клиентских апдейтов);
     * 429 — rate-limit (1/мин на устройство; у клиента свой cooldown 1/мин поверх).
   - Одноразовость jti — погашение по образцу webauthn_session через challenges.
   - Mismatch-события делятся на proof-backed (живой proof на устройстве) и declared; строгий режим политики требует живой proof для approve.
   - Билет не пишется в логи и не утекает наружу.

3. Фаза 2b — SSO-мост: вход в SAML/OIDC-сервисы по билету
   - Флоу: SP → /saml/sso?SAMLRequest → нет web-сессии → /login?next → создаётся челлендж purpose=browser_sso (привязка к сессии формы, next, имя SP из AuthnRequest) → доставка существующим механизмом челленджей (WS/push + pending-список). Клиент ждёт поля: {id, sp_name, username, machine, auto_allowed, expires_at} — плоским сообщением {"type":"browser_sso", ...} (альтернативный формат challenge_prompt+purpose тоже поддержан, но основной — browser_sso).
   - Decision-контракт ОТЛИЧАЕТСЯ от обычных челленджей: {"action":"approve","sso_ticket":"..."} / {"action":"deny"} — НЕ {"decision":...}. Approve без валидного билета не принимается.
   - По approve: проверка подписи+TTL+jti, гашение челленджа и сиблингов → web-сессия формы логина → редирект next → /saml/sso → подписанный Response на ACS SP. Слой SAML не меняется.
   - auto_allowed (per-SP/глобально, off по умолчанию): разрешает клиентское автоподтверждение без диалога; на сервере остаётся обязательная валидация билета. Rate-limit на решение; fallback на пароль+2FA всегда (нет билета/истёк/офлайн/не-Windows).
   - Windows-identity НЕ попадает в SAML-утверждения и внешние каналы без отдельного решения.

Требования:
- Go, следовать существующим паттернам репозитория (internal/api/app.go, internal/store/app_devices.go, groups_policy, кулдаун wifiReject, погашение webauthn_session).
- Миграции — с интеграционными тестами на реальном PostgreSQL ($n-плейсхолдеры фейками не ловятся).
- Обратная совместимость: неизвестные поля клиента игнорируются (json.Unmarshal), фичи за флагами, включение постепенное.
- Unit-тесты: правило mismatch (домены/@/регистр), TTL/jti билета, коды sso-ticket (200/401/404/409/429), гейт политики (approve под mismatch → 403, deny разрешён), браузерный decision-контракт.
- Клиентский репозиторий (ligament-apps) не трогать.

Приёмка:
- Логин с windows_identity и телеметрия с полями пишутся, mismatch виден в /admin/users с троттлингом.
- CP-вход (push approve) → в poll-ответе есть sso_ticket; POST /api/v1/app/sso-ticket гасит jti, повтор → 409; 404 при выключенной фиче; 429 при чаще 1/мин.
- Включение RequireWindowsIdentityMatch: approve с устройства с незагашенным mismatch → 403; deny проходит.
- /login?next для SP-запроса создаёт browser_sso-челлендж; approve с валидным билетом выпускает web-сессию и SAML Response на ACS; deny/истечение ничего не выпускают.
