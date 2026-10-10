import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ligament_authenticator/api/client.dart';
import 'package:ligament_authenticator/services/auth_state.dart';
import 'package:ligament_authenticator/services/autoshare_service.dart';
import 'package:ligament_authenticator/services/support_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// no-op wakelock: stopScreenSharing вызывает WakelockPlus.disable() — в
/// тестах платформенного канала нет, асинхронный PlatformException ронял
/// бы тест ПОСЛЕ его завершения.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
}

/// Состояние мок-сервера (паттерн login_crash_test.dart: настоящий
/// HttpServer на loopback, ApiClient ходит по реальному сокету).
class _MockState {
  int machineRegisterCalls = 0;

  /// Ответы POST /rdp/machines/register по очереди (Д8: первые попытки
  /// неудачны); пустая очередь — успех `{"ok": true, machine_id}`.
  final List<Map<String, dynamic>> machineQueue = [];
  final Map<String, int> activateCalls = {};
  final Map<String, Map<String, dynamic>> activateBodies = {};
}

/// Этап 2.4 «Экран» (план §5.2) + Ш2/Ш5 плана docs/console-any-state-plan.md:
/// owner-флаг сессии, fail-closed гейт адресации промпта, ретрай регистрации
/// машины (Д8) и headless-запуск owner-трансляции (--autoshare, Ш5).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test подменяет HttpOverrides пустыми ответами — как в
  // login_crash_test.dart, возвращаем настоящий IO-клиент: мок — это
  // реальный HttpServer на loopback, ApiClient ходит по живому сокету.
  HttpOverrides.global = null;
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  group('SupportService ownerSession (этап 2.4)', () {
    test('по умолчанию false — обычный SOS не задевает owner-ветки UI', () {
      final s = SupportService();
      addTearDown(s.dispose);
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
    });

    test('setAuthorizing(owner: true) выставляет флаг и инициатора', () {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(
        sessionId: 'sess-1',
        accessMode: 'full_control',
        owner: true,
        initiatorDevice: 'iPhone А.И.',
      );
      expect(s.ownerSession, isTrue);
      expect(s.ownerInitiatorDevice, 'iPhone А.И.');
      expect(s.state, SupportSessionState.authorizing);
      expect(s.activeSessionId, 'sess-1');
    });

    test('setAuthorizing без owner (SOS-путь) не включает owner-режим', () {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(
        sessionId: 'sos-1',
        accessMode: 'view_only',
      );
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
    });

    test('setRequested сбрасывает owner-флаг (новое SOS-обращение)', () {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(sessionId: 'a', owner: true, initiatorDevice: 'Phone');
      s.setRequested(
        sessionId: 'b',
        category: 'it',
        problemSummary: 'help',
      );
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
    });

    test('stopScreenSharing сбрасывает owner-флаг (конец трансляции)', () async {
      final s = SupportService();
      addTearDown(s.dispose);
      s.setAuthorizing(sessionId: 'a', owner: true, initiatorDevice: 'Phone');
      await s.stopScreenSharing();
      expect(s.ownerSession, isFalse);
      expect(s.ownerInitiatorDevice, isNull);
      expect(s.state, SupportSessionState.idle);
    });
  });

  group('ownerScreenPromptTargetsThisDevice — fail-closed адресация (Ш2, Д3)', () {
    test('device-совпадение: target_device_id == наш device_id — транслируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_device_id': 'dev-pc',
          },
          'dev-pc',
        ),
        isTrue,
      );
    });

    test('machine-совпадение: target_machine_id == зарегистрированная — транслируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_machine_id': 'machine-123',
          },
          'dev-pc',
          'machine-123',
        ),
        isTrue,
      );
    });

    test('machine-совпадение перевешивает чужой device_id (ротация device_id, Д7)', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_device_id': 'old-dev-id',
            'target_machine_id': 'machine-123',
          },
          'new-dev-id',
          'machine-123',
        ),
        isTrue,
      );
    });

    test('Д3 (ключевой кейс бага): machine задан, машина НЕ зарегистрирована — НЕ транслируем', () {
      // Раньше при registeredMachineId == null проверка machine была no-op
      // и проваливалась к `return true` — незарегистрированная машина
      // начинала чужую трансляцию.
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_machine_id': 'machine-123',
          },
          'dev-pc',
          null,
        ),
        isFalse,
      );
    });

    test('machine задан, registeredMachineId пустой — НЕ транслируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_machine_id': 'machine-123'},
          'dev-pc',
          '',
        ),
        isFalse,
      );
    });

    test('machine задан, но другой — игнорируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-viewer',
            'target_machine_id': 'other-machine-456',
          },
          'my-dev-id',
          'machine-123',
        ),
        isFalse,
      );
    });

    test('target-поля пусты (нет адресации) — НЕ транслируем (broadcast-пропуск убран)', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'initiator_device_id': 'dev-viewer'},
          'dev-pc',
        ),
        isFalse,
      );
    });

    test('пустые строки target-полей — это отсутствие адресации, НЕ транслируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': '', 'target_machine_id': ''},
          'dev-pc',
        ),
        isFalse,
      );
    });

    test('target_device_id чужой — НЕ моя машина, игнорируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': 'dev-agent-other'},
          'dev-pc',
        ),
        isFalse,
      );
    });

    test('наш device_id неизвестен при device-адресации — НЕ транслируем', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'target_device_id': 'dev-agent'},
          null,
        ),
        isFalse,
      );
    });

    test('инициатор — мы сами: viewer, экран не транслирует (и при адресации в нас)', () {
      expect(
        ownerScreenPromptTargetsThisDevice(
          {'session_id': 's1', 'initiator_device_id': 'dev-me'},
          'dev-me',
        ),
        isFalse,
      );
      expect(
        ownerScreenPromptTargetsThisDevice(
          {
            'session_id': 's1',
            'initiator_device_id': 'dev-me',
            'target_device_id': 'dev-me',
          },
          'dev-me',
        ),
        isFalse,
      );
    });
  });

  // --- Ш2/Ш5 на живом AuthState: мок-сервер на loopback (паттерн
  // login_crash_test.dart — там же причина моков каналов в setUpAll).
  group('AuthState: ретрай регистрации машины (Д8) и autoshare (Ш5)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // AudioPlayer()/FlutterSecureStorage в конструкторе AuthState и login().
      for (final channel in const [
        MethodChannel('xyz.luan/audioplayers'),
        MethodChannel('xyz.luan/audioplayers.global'),
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => null);
      }
    });

    tearDown(() {
      for (final channel in const [
        MethodChannel('xyz.luan/audioplayers'),
        MethodChannel('xyz.luan/audioplayers.global'),
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    });

    Future<(AuthState, _MockState, HttpServer)> startApp() async {
      final st = _MockState();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final rawBody = await utf8.decoder.bind(req).join();
        Future<void> jsonResp(Object obj) async {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode(obj));
          await req.response.close();
        }

        if (req.method == 'POST' && req.uri.path == '/api/v1/app/login') {
          // device_id НЕ возвращаем: он заставил бы login поднять слушатель
          // LocalDetectService на 127.0.0.1:8757 — а этот порт в полном
          // прогоне занимает local_detect_test (параллельные изоляты).
          await jsonResp({
            'token': 'tok-1',
            'user': {'username': 'ivanov', 'display_name': 'Иван'},
          });
          return;
        }
        const emptyLists = <String, String>{
          'GET /api/v1/app/challenges/pending': '[]',
          'GET /api/v1/app/me/apps': '[]',
          'GET /api/v1/app/me/history': '[]',
          'GET /api/v1/app/me/notifications?limit=50': '{"notifications":[]}',
        };
        final key =
            '${req.method} ${req.uri.path}${req.uri.query.isEmpty ? '' : '?${req.uri.query}'}';
        if (req.method == 'GET' && emptyLists.containsKey(key)) {
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType.json;
          req.response.write(emptyLists[key]);
          await req.response.close();
          return;
        }
        if (req.method == 'POST' && req.uri.path == '/api/v1/app/telemetry') {
          await jsonResp({'is_compliant': true});
          return;
        }
        if (req.method == 'GET' && req.uri.path == '/api/v1/app/support/current') {
          await jsonResp({'active': false});
          return;
        }
        if (req.method == 'GET' && req.uri.path == '/api/v1/app/config') {
          await jsonResp({});
          return;
        }
        if (req.method == 'GET' && req.uri.path == '/api/v1/app/rdp/targets') {
          await jsonResp({'targets': []});
          return;
        }
        if (req.method == 'POST' && req.uri.path == '/api/v1/app/rdp/machines/register') {
          st.machineRegisterCalls++;
          final resp = st.machineQueue.isNotEmpty
              ? st.machineQueue.removeAt(0)
              : {'ok': true, 'machine_id': 'm-1'};
          await jsonResp(resp);
          return;
        }
        if (req.method == 'POST' && req.uri.path == '/api/v1/app/rdp/instances/register') {
          await jsonResp({'ok': true});
          return;
        }
        final activate = RegExp(r'^/api/v1/app/support/(.+)/activate-screen$')
            .firstMatch(req.uri.path);
        if (req.method == 'POST' && activate != null) {
          final sid = activate.group(1)!;
          st.activateCalls[sid] = (st.activateCalls[sid] ?? 0) + 1;
          st.activateBodies[sid] =
              rawBody.isEmpty ? <String, dynamic>{} : jsonDecode(rawBody) as Map<String, dynamic>;
          await jsonResp({'ok': true});
          return;
        }
        req.response.statusCode = 404;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"error":"unmocked $key"}');
        await req.response.close();
      });

      final auth = AuthState();
      auth.serverUrl = 'http://127.0.0.1:${server.port}';
      auth.api = ApiClient(baseUrl: auth.serverUrl!);
      addTearDown(() async {
        await auth.logout(); // снимает таймеры ретрая/heartbeat/опроса
        await server.close();
      });
      return (auth, st, server);
    }

    /// Поллинг условия с таймаутом (реальные таймеры, без fakeAsync:
    /// HTTP ходит по настоящему сокету).
    Future<void> until(bool Function() cond,
        {Duration timeout = const Duration(seconds: 5)}) async {
      final sw = Stopwatch()..start();
      while (!cond()) {
        if (sw.elapsed > timeout) fail('условие не наступило за $timeout');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('Д8: неудачная регистрация машины перепробуется до успеха и потом молчит', () async {
      final (auth, st, _) = await startApp();
      // Первые две регистрации «отказ» сервера (ok:false), третья — успех.
      st.machineQueue.addAll(const [
        {'ok': false},
        {'ok': false},
      ]);
      auth.machineRetryFirstDelay = const Duration(milliseconds: 20);
      auth.machineRetryNextDelay = const Duration(milliseconds: 20);

      await auth.login('ivanov', 'secret');
      expect(auth.isLoggedIn, isTrue);
      expect(st.machineRegisterCalls, 1); // первая попытка из refreshAll

      await until(() => st.machineRegisterCalls >= 3);
      expect(st.machineRegisterCalls, 3); // + два ретрая с бэкоффом

      // Успех достигнут — ретрай остановлен, спама запросов нет.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(st.machineRegisterCalls, 3);
    });

    test('Д8: успешная регистрация с первого раза не запускает ретраев', () async {
      final (auth, st, _) = await startApp();
      auth.machineRetryFirstDelay = const Duration(milliseconds: 20);

      await auth.login('ivanov', 'secret');
      expect(st.machineRegisterCalls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(st.machineRegisterCalls, 1); // не спамим при успехе
    });

    test('Ш5: autoshare ждёт WS и срабатывает один раз (реконнект не перезапускает)', () async {
      final (auth, st, _) = await startApp();
      await auth.login('ivanov', 'secret');
      expect(auth.isOnline, isFalse); // WS к мок-серверу не подключается

      // Флаг зарегистрирован, но WS ещё не готов — активации нет.
      auth.requestAutoshare('sess-auto');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(st.activateCalls['sess-auto'], isNull);

      // Первый onConnected: головной запуск owner-сессии — активация
      // уходит на сервер (затем захват экрана в тесте падает без
      // нативного WebRTC — ошибка глушится debugPrint, без UI).
      auth.isOnline = true;
      auth.wsConnectedAutoshareCheck();
      await until(() => (st.activateCalls['sess-auto'] ?? 0) >= 1);
      expect(st.activateBodies['sess-auto']?['instance_id'], auth.instanceId);

      // Реконнект WS (onConnected повторно) — повторного запуска НЕТ.
      auth.isOnline = false;
      auth.wsConnectedAutoshareCheck();
      auth.isOnline = true;
      auth.wsConnectedAutoshareCheck();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(st.activateCalls['sess-auto'], 1);
    });

    test('Ш5: восстановление сессии не удалось — autoshare молча не срабатывает', () async {
      final auth = AuthState();
      addTearDown(auth.dispose);
      auth.requestAutoshare('sess-x');
      auth.isOnline = true;
      auth.wsConnectedAutoshareCheck();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(auth.isLoggedIn, isFalse);
      expect(auth.support.state, SupportSessionState.idle);
    });

    test('startOwnerScreenFromWake идемпотентен: сессия уже запускается / ждёт диалога', () async {
      final (auth, st, _) = await startApp();
      await auth.login('ivanov', 'secret');

      // Эта сессия уже авторизуется (WS-промпт успел раньше --autoshare).
      auth.support.setAuthorizing(sessionId: 'sess-busy', owner: true);
      await auth.startOwnerScreenFromWake('sess-busy');
      expect(st.activateCalls['sess-busy'], isNull);

      // По этой сессии открыт accept-диалог (activeSupportPrompt) —
      // ждём явного решения пользователя.
      auth.activeSupportPrompt = {'session_id': 'sess-dlg'};
      await auth.startOwnerScreenFromWake('sess-dlg');
      expect(st.activateCalls['sess-dlg'], isNull);
    });
  });

  // Тесты autoshare-сервиса живут здесь (а не отдельным файлом): файл,
  // сортирующийся раньше local_detect_test, сдвигает его во вторую волну
  // изолятов flutter test — и login_crash_test выигрывает гонку за
  // 127.0.0.1:8757 (обе стороны биндят реальный сокет).
  group('autoshareSessionFromArgs (--autoshare, Ш5)', () {
    test('нет флага — null (обычный запуск)', () {
      expect(autoshareSessionFromArgs([]), isNull);
      expect(autoshareSessionFromArgs(['--minimized']), isNull);
      expect(autoshareSessionFromArgs(['ligament://rdp/abc']), isNull);
    });

    test('--autoshare=<session_id> — извлекает id', () {
      expect(
        autoshareSessionFromArgs(['--minimized', '--autoshare=sess-42']),
        'sess-42',
      );
    });

    test('пустое значение и флаг без «=» игнорируются', () {
      expect(autoshareSessionFromArgs(['--autoshare=']), isNull);
      expect(autoshareSessionFromArgs(['--autoshare=  ']), isNull);
      expect(autoshareSessionFromArgs(['--autoshare']), isNull);
      expect(autoshareSessionFromArgs(['--autoshare=sess-1', '--autoshare=']), 'sess-1');
    });

    test('берётся последний непустой флаг; значение триммится', () {
      expect(
        autoshareSessionFromArgs(['--autoshare=a', '--autoshare=b']),
        'b',
      );
      expect(autoshareSessionFromArgs(['--autoshare= sess-x ']), 'sess-x');
    });
  });

  group('AutoshareSingleInstance (single-instance лок)', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ligament_autoshare_test');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    // Лок dart:io на POSIX — fcntl (на процесс), поэтому конфликт «второй
    // acquire в том же процессе» проверять нельзя (fcntl разрешает
    // повторный лок процессу); кросс-процессный конфликт неблокирующий
    // (errno EWOULDBLOCK — проверено вручную) и в тесте не воспроизводим
    // без дочернего процесса. Здесь — жизненный цикл лока.
    test('acquire берёт лок и создаёт файл; release освобождает', () async {
      final a = AutoshareSingleInstance();
      expect(AutoshareSingleInstance.isLockHeld, isFalse);
      expect(await a.acquire(directoryPath: dir.path), isTrue);
      expect(AutoshareSingleInstance.isLockHeld, isTrue);
      expect(
          File('${dir.path}${Platform.pathSeparator}'
                  '${AutoshareSingleInstance.lockFileName}')
              .existsSync(),
          isTrue);

      // После release новый экземпляр берёт лок свободно.
      await a.release();
      expect(AutoshareSingleInstance.isLockHeld, isFalse);
      final b = AutoshareSingleInstance();
      expect(await b.acquire(directoryPath: dir.path), isTrue);
      await b.release();
    });

    test('release без acquire — no-op', () async {
      final a = AutoshareSingleInstance();
      await a.release(); // не бросает
    });
  });
}
