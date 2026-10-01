# Windows Identity: промты реализации (клиент + CP)

Серверный дизайн: `/Users/aleksey/Documents/2fa/docs/windows-identity-server-design.md`.
Промт 1 — в сессию репозитория **ligament-apps** (Flutter). Промт 2 — в сессию CP (C++).

---

## Промт 1 — приложение (ligament-apps)

Задача: Windows-identity в приложении Ligament — фаза 1 (остаток UI) и фазы 2/2b по серверному дизайну.

Контекст:
- Серверный дизайн (главный документ, прочитать перед стартом): `/Users/aleksey/Documents/2fa/docs/windows-identity-server-design.md`.
- Уже сделано в этом репо — НЕ переделывать: `lib/services/windows_identity.dart` (FFI Win32: GetUserNameW/GetUserNameExW/GetComputerNameExW; `collect()` → `{windows_user, windows_domain, computer_name, is_domain}`), поле `windows_identity` в payload `POST /api/v1/app/login`, поля identity в телеметрии (`collectPosture`), `windowsIdentityMatch` в AuthState.
- Модель: Windows-идентичность — НЕ вход без пароля, а аттестация «кто в приложении ↔ кто за машиной». Источник истины — Win32 API, не переменные окружения. Любой сбой identity-цепочки = тихая деградация, обычный вход не блокируется никогда.

Реализовать по порядку:

1. Mismatch-баннер (фаза 1, UI)
   - `AuthState.windowsIdentityMatch == false` → ненавязчивый баннер в кабинете: «⚠️ Аккаунт {username}, а за Windows-сессией {windows_user}. Администратор уведомлён.» При `true`/`null` не показывать.
   - Закрывается на сессию; локализация ru/en.

2. Чтение sso-билета и предъявление серверу (фаза 2)
   - Файл: `C:\ProgramData\Ligament\sso\<SID>\sso.bin`, где `<SID>` — SID текущего пользователя (Win32 через FFI по образцу windows_identity.dart: OpenProcessToken → GetTokenInformation(TokenUser) → ConvertSidToStringSidW). Содержимое — билет строкой UTF-8.
   - После успешного логина — один раз `POST /api/v1/app/sso-ticket` с телом `{"ticket": "<билет>"}`.
   - Ответы: 200 — запомнить `expires_at` (статус «подтверждено Windows» в профиле); 401/409 — невалиден/истёк: тихо, в лог; 404 `not_enabled` — сервер ещё не поддерживает: пропустить и не повторять до перезапуска; 429 — не чаще раза в минуту.
   - Нет файла / нет доступа (не та учётка) → нет билета, без ошибок пользователю.
   - Не-Windows: всё выключено (null-паттерн, conditional import).

3. Экран browser_sso-челленджа (фаза 2b — SSO-мост)
   - Существующий канал челленджей приносит новый тип `browser_sso`: `{id, sp_name, username, machine, auto_allowed, expires_at}`.
   - При получении: прочитать живой билет (п.2), сверить `machine` с текущей машиной (`computer_name` из windows_identity).
   - Диалог: «Вход в {sp_name} — подтвердить как {windows_domain}\{windows_user}?» [Войти] [Отмена]. Нет билета или машина не совпала → кнопка недоступна + подсказка «Требуется свежий вход в Windows (билет живёт ~5 минут)».
   - [Войти] → `POST /api/v1/app/challenges/{id}/decision` `{"action":"approve","sso_ticket":"<билет>"}`; [Отмена] → `{"action":"deny"}`.
   - `auto_allowed=true` (серверная политика) разрешает авто-approve без диалога — но на клиенте включается только тумблером в настройках приложения, по умолчанию диалог всегда.
   - Истёкший `expires_at` не показывать.

Требования:
- Все Win32-вызовы — только FFI (пакет ffi уже в зависимостях), никаких `Platform.environment`.
- i18n ru/en для всех новых строк.
- Тесты: unit — построение пути по SID-заглушке, сравнение machine, мок-ответы sso-ticket (200/401/404/409/429) и decision; виджет-тесты баннера и диалога.
- Серверные контракты считать финальными — сервер реализует их независимо; ничего в серверном репо не трогать.

Приёмка:
- Windows без файла билета: логин и работа без единой новой ошибки в UI.
- С файлом: после логина уходит sso-ticket, в профиле статус «подтверждено Windows» со временем.
- Push `browser_sso` открывает диалог; approve уходит с билетом, deny — без.
- macOS/Linux-сборка не падает (FFI за conditional import).

---

## Промт 2 — credential provider (C++)

Задача: выдача и запись sso-билета при входе в Windows.

1. В терминальном accept-ответе `POST /api/v1/auth/poll` появилось поле `sso_ticket` (строка). Если непусто — записать файл `C:\ProgramData\Ligament\sso\<SID залогиненного пользователя>\sso.bin` (каталоги создать), содержимое — билет строкой UTF-8.
2. Безопасность файла: DACL — полный доступ SYSTEM и Администраторам, текущему SID только чтение; запись атомарно (tmp + MoveFileEx с REPLACE_EXISTING); наследование выключить (PROTECTED_DACL).
3. SID брать от токена залогиненного пользователя контекста CP, не от процесса CP.
4. Ошибки записи не ломают вход в Windows — только строка в cp.log.
