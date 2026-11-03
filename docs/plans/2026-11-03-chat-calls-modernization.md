# План модернизации корпоративного чата и подсистемы звонков Ligament

> **Execution:** Следовать этому плану пошагово (Task-by-Task). Перед каждым изменением писать модульный тест, проверять его провал, реализовывать минимальный код, добиваться зелёного теста и чистоты `flutter analyze`.

**Goal:** Создать отзывчивый корпоративный мессенджер с высокопроизводительным рендерингом (кэшируемые `TextSpan`), мгновенным поиском и фильтрацией, десктопными шорткатами (`Enter`/`Shift+Enter`), легковесным PiP-оверлеем звонков без сброса WebRTC-текстур и сжатыми 5-битными звуковыми волнами для голосовых сообщений.

**Architecture:**
- **Чат и список диалогов:** Инкапсулированная строка поиска с мгновенным локальным фильтром и чипами (`Все`, `Личные`, `Форумы`, `Непрочитанные`).
- **Рендеринг сообщений:** Замена потенциального тяжелого AST-парсинга на линейный O(N) токенизатор сущностей форматирования (`bold`, `italic`, `monospace/code`, `link`), кэширующий плоский `List<InlineSpan>` прямо в модели `ChatMessage` (время рендера ячейки < 0.2 мс).
- **Поле ввода (Composer):** Десктопная маршрутизация `Enter` (отправка) vs `Shift+Enter` (перенос строки) через `CallbackShortcuts`/`FocusNode`, цитирование (Reply bar) и кэширование черновиков per-chat.
- **Звонковый слой (WebRTC & PiP):** Вынос сессии звонка в долгоживущий `CallSessionManager` (Provider/Singleton). Рендеринг через глобальный `GlobalCallOverlayWidget` в `MaterialApp.builder` поверх навигационного стека (переход между полноэкранным режимом и плавающим окном 160×90 без уничтожения `RTCVideoRenderer` и потери нативного `texture_id`).
- **Голосовые сообщения:** Расчет RMS на стороне отправителя каждые 100 мс с нормализацией в 50 замеров по 5 бит ($2^5 = 32$) $\rightarrow$ упаковка в 32 байта Base64 в метаданные. Отрисовка через `CustomPainter` напрямую на GPU.

**Tech Stack:** Flutter / Dart, `flutter_webrtc`, `window_manager`, Material 3 (`Theme.of(context).colorScheme`), `audioplayers`.

---

## Task 1: Модели и кэширующий токенизатор сущностей форматирования

**Files:**
- Modify: `lib/models/chat_models.dart`
- Create: `lib/screens/chat/chat_format_tokenizer.dart`
- Test: `test/chat_format_tokenizer_test.dart`

**Step 1: Write the failing unit tests for tokenizer**
Создать файл `test/chat_format_tokenizer_test.dart` с проверкой:
- Парсинга жирного текста `**текст**`
- Парсинга курсива `*текст*`
- Парсинга инлайн-кода `` `mono` ``
- Парсинга ссылок `https://...`
- Кэширования `getSpans` в `ChatMessage`

**Step 2: Run test to verify it fails**
```bash
cd /Users/aleksey/Documents/ligament-apps && flutter test test/chat_format_tokenizer_test.dart
```
Ожидается: FAIL (класс `ChatFormatTokenizer` не найден).

**Step 3: Implement `ChatFormatTokenizer` & extend `ChatMessage`**
- Создать `lib/screens/chat/chat_format_tokenizer.dart` с линейным `RegExp` O(N).
- Добавить поле `List<InlineSpan>? _cachedSpans` и геттер `getSpans(...)` в `ChatMessage` в `lib/models/chat_models.dart`.

**Step 4: Run test to verify it passes**
```bash
cd /Users/aleksey/Documents/ligament-apps && flutter test test/chat_format_tokenizer_test.dart
```
Ожидается: PASS (все тесты зеленые).

**Step 5: Verify static analysis & commit**
```bash
flutter analyze
git commit -m "feat(chat): add cached fast inline span tokenizer"
```

---

## Task 2: Поиск по диалогам и фильтр-чипы (Search & Category Chips)

**Files:**
- Modify: `lib/services/chat_service.dart`
- Modify: `lib/screens/chat_screen.dart`
- Test: `test/chat_search_filter_test.dart`

**Step 1: Write the failing test for chat filtering**
Создать `test/chat_search_filter_test.dart` с тестами на:
- Фильтрацию чатов по ключевому слову в `title` или `peerUserId`.
- Фильтрацию по категории (`all`, `direct`, `forum`, `unread`).

**Step 2: Run test to verify it fails**
```bash
cd /Users/aleksey/Documents/ligament-apps && flutter test test/chat_search_filter_test.dart
```

**Step 3: Implement filtering logic and UI**
- В `ChatService` добавить метод `List<ChatItem> filterChats({String query, String category})`.
- В `_buildChatList` в `chat_screen.dart` внедрить поле `SearchBar` / компактный `TextField` с иконкой лупы и горизонтальную строку `FilterChip` (`Все`, `Личные`, `Форумы`, `Непрочитанные`).
- Использовать строго семантические токены `theme.colorScheme`.

**Step 4: Run test to verify it passes**
```bash
flutter test test/chat_search_filter_test.dart
flutter analyze
```

**Step 5: Commit**
```bash
git commit -m "feat(ui): add search bar and filter chips to chat list"
```

---

## Task 3: Десктопные шорткаты композера (Enter vs Shift+Enter) и цитирование

**Files:**
- Modify: `lib/screens/chat_screen.dart`
- Modify: `lib/models/chat_models.dart`
- Test: `test/chat_composer_shortcuts_test.dart`

**Step 1: Write tests for reply payload and drafts**
- Тестирование структуры сообщения с `replyToId` и `replyToAuthor/replyToSnippet`.
- Проверка сохранения и очистки черновиков `drafts[chatId]`.

**Step 2: Implement composer ergonomics in `chat_screen.dart`**
- Использовать `CallbackShortcuts` или `FocusNode(onKeyEvent)`:
  - `LogicalKeyboardKey.enter` без `shift`: вызов `_handleSend()`.
  - `LogicalKeyboardKey.enter` с `shift`: вставка `\n`.
  - `LogicalKeyboardKey.escape`: отмена цитирования (если активен reply bar).
- Добавить баннер цитируемого сообщения над полем ввода с превью автора, текста и кнопкой закрытия `✕`.
- Добавить словарь `Map<String, String> _drafts` в стейт экрана для сохранения недописанного сообщения при переходе между чатами.

**Step 3: Run tests & verify analyzer**
```bash
flutter test test/chat_composer_shortcuts_test.dart
flutter analyze
```

**Step 4: Commit**
```bash
git commit -m "feat(ui): add desktop shortcuts reply bar and drafts to composer"
```

---

## Task 4: 5-битный алгоритм Waveform для голосовых сообщений

**Files:**
- Create: `lib/services/waveform_codec.dart`
- Create: `lib/widgets/waveform_bubble.dart`
- Test: `test/waveform_codec_test.dart`

**Step 1: Write the failing unit test for 5-bit packing & unpacking**
Создать `test/waveform_codec_test.dart`:
- Генерация 50 нормализованных сэмплов `[0..31]`.
- Упаковка в Base64 (ровно 32 байта).
- Распаковка обратно и проверка сохранения значений с точностью до 5 бит.

**Step 2: Run test to verify it fails**
```bash
flutter test test/waveform_codec_test.dart
```

**Step 3: Implement `WaveformCodec` & `WaveformBubble`**
- Создать `lib/services/waveform_codec.dart` с методами `pack(List<int> samples)` и `unpack(String base64Str)`.
- Создать виджет `lib/widgets/waveform_bubble.dart` с `CustomPainter` (отрисовка столбиков волны на Canvas за < 0.05 мс, анимация прогресса воспроизведения `activeColor` / `inactiveColor`).
- Использовать цвета `theme.colorScheme.primary` и `theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4)`.

**Step 4: Run test to verify it passes**
```bash
flutter test test/waveform_codec_test.dart
flutter analyze
```

**Step 5: Commit**
```bash
git commit -m "feat(chat): implement 5-bit packed audio waveform decoder and painter"
```

---

## Task 5: Глобальный CallSessionManager и архитектура непрерывного PiP

**Files:**
- Create: `lib/services/call_session_manager.dart`
- Create: `lib/widgets/global_call_overlay.dart`
- Modify: `lib/main.dart`
- Modify: `lib/screens/chat_screen.dart`
- Test: `test/call_session_manager_test.dart`

**Step 1: Write unit tests for `CallSessionManager` state transitions**
Создать `test/call_session_manager_test.dart`:
- Проверка состояний: `idle` -> `calling` -> `connected` -> `ended`.
- Проверка переключения режима отображения: `fullscreen` <-> `pip` (160×90).
- Проверка отвязки треков без утечек при завершении вызова (`srcObject = null` перед `dispose()`).

**Step 2: Run test to verify it fails**
```bash
flutter test test/call_session_manager_test.dart
```

**Step 3: Implement `CallSessionManager` & `GlobalCallOverlayWidget`**
- Создать `lib/services/call_session_manager.dart`: хранение медиа-треков, состояния микрофона, камеры, шеринга экрана, таймера звонка.
- Создать `lib/widgets/global_call_overlay.dart`:
  - Если звонок активен и режим `fullscreen`: отображает полноэкранный интерфейс с плавающей нижней панелью контролов (Mute, Camera, ScreenShare, EndCall).
  - Если режим `pip`: отображает компактный `Positioned` виджет с `GestureDetector(onPanUpdate: ...)` для перетаскивания по углам и кнопкой разворота на полный экран.
- Внедрить `GlobalCallOverlayWidget` в `MaterialApp.builder` в `lib/main.dart` (над навигационным стеком).
- В `chat_screen.dart` обновить `_startCall`, связав его с вызовом `CallSessionManager.instance.startCall(...)` вместо старого модального `AlertDialog`.

**Step 4: Run tests & verify analyzer**
```bash
flutter test test/call_session_manager_test.dart
flutter analyze
```

**Step 5: Commit**
```bash
git commit -m "feat(calls): introduce CallSessionManager and persistent in-app PiP overlay"
```

---

## Task 6: Десктопный системный PiP (Always on Top) и автопереключение аудио

**Files:**
- Modify: `lib/services/call_session_manager.dart`
- Modify: `lib/widgets/global_call_overlay.dart`
- Test: `test/desktop_audio_devices_test.dart`

**Step 1: Implement desktop window management for PiP**
- При нажатии «Свернуть в мини-окно ОС» на десктопе:
  - Использовать `window_manager`: сохранить исходные `getBounds()`, вызвать `setAlwaysOnTop(true)`, уменьшить окно до 320×180, скрыть декорации заголовка.
  - При клике «Развернуть»: вернуть исходный размер, вызвать `setAlwaysOnTop(false)`.

**Step 2: Implement audio device hotplug listener**
- В `CallSessionManager` подписаться на `navigator.mediaDevices.ondevicechange`:
  - При подключении/отключении Bluetooth-гарнитур или USB-наушников автоматически обновлять список доступных устройств и перенаправлять аудиопоток через `Helper.selectAudioOutput(...)`.

**Step 3: Run analysis & commit**
```bash
flutter analyze
git commit -m "feat(calls): support desktop always-on-top PiP and audio device hotplug"
```

---

## Task 7: Финальная интеграция, регрессионное тестирование и документация

**Files:**
- Modify: `test/chat_screen_test.dart`
- Test: Запуск всего набора тестов `flutter test`

**Step 1: Update comprehensive test suite**
- Проверить взаимодействие всех новых компонентов (поиск + Markdown-токены + черновики + звонковый оверлей).

**Step 2: Run all tests and static analysis**
```bash
cd /Users/aleksey/Documents/ligament-apps
flutter analyze
flutter test
```
Ожидается: 0 warnings, 0 errors, All tests passed.

**Step 3: Commit and tag**
```bash
git commit -m "chore(chat): finalize chat and call UI modernization"
```
