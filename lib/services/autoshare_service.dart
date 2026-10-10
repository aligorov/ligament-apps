import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Ш5 Wake (план docs/console-any-state-plan.md §5): служба-сторож
/// поднимает приложение в пользовательской сессии с флагом
/// `--autoshare=<session_id>` — после восстановления сессии и
/// подключения WS приложение headless начинает owner-трансляцию этой
/// сессии (запуск — AuthState.requestAutoshare /
/// startOwnerScreenFromWake). Здесь только разбор argv и single-instance
/// лок; сам стрим живёт в AuthState/SupportService.

/// session_id из аргументов командной строки (`--autoshare=<session_id>`).
/// Берётся последний непустой флаг; пустое значение или отсутствие флага —
/// null (обычный запуск). Чистая функция — тестируется без приложения.
String? autoshareSessionFromArgs(List<String> args) {
  String? found;
  for (final arg in args) {
    if (!arg.startsWith('--autoshare=')) continue;
    final sid = arg.substring('--autoshare='.length).trim();
    if (sid.isNotEmpty) found = sid;
  }
  return found;
}

/// Эксклюзивный файл-лок autoshare-запусков (план §8, риск «двойной
/// запуск»): пока первый wake-экземпляр жив и держит лок, повторный
/// запуск с --autoshare уходит сразу (main → exit(0)).
///
/// Лок — dart:io RandomAccessFile.lock (неблокирующий: занятый другим
/// процессом лок бросает исключение сразу, а не ждёт). Файл остаётся
/// ОТКРЫТЫМ до конца процесса — ОС снимает лок сама; явно закрывать не
/// нужно (и в POSIX нельзя открывать этот файл где-то ещё: закрытие
/// любого дескриптора снимает fcntl-лок процесса).
class AutoshareSingleInstance {
  static const String lockFileName = 'ligament_autoshare.lock';

  /// Прод-экземпляр, держащий лок: статическая ссылка не даёт GC собрать
  /// объект вместе с открытым RandomAccessFile до конца процесса (лок
  /// живёт, пока открыт дескриптор файла).
  static AutoshareSingleInstance? _held;

  /// Взят ли лок этим процессом (диагностика/тесты).
  static bool get isLockHeld => _held?._handle != null;

  RandomAccessFile? _handle;

  /// true — лок взят этим процессом (или файловая система недоступна и
  /// решено продолжить без лока: будить лучше, чем молча не подняться);
  /// false — лок уже держит другой экземпляр, вызывающий должен сразу
  /// завершиться.
  ///
  /// [directoryPath] — директория лока; по умолчанию Application Support
  /// (path_provider), при его недоступности — системный temp.
  Future<bool> acquire({String? directoryPath}) async {
    assert(!kIsWeb); // вызывается только из десктопного main()
    Directory dir;
    if (directoryPath != null) {
      dir = Directory(directoryPath);
    } else {
      try {
        dir = await getApplicationSupportDirectory();
      } catch (_) {
        dir = Directory.systemTemp;
      }
    }
    final file = File('${dir.path}${Platform.pathSeparator}$lockFileName');
    try {
      final raf = await file.open(mode: FileMode.append);
      try {
        await raf.lock(FileLock.exclusive);
        _handle = raf;
        _held = this;
        return true;
      } catch (e) {
        // Лок занят: другой экземпляр уже обслуживает autoshare.
        debugPrint('autoshare: лок ${file.path} занят другим экземпляром: $e');
        await raf.close();
        return false;
      }
    } catch (e) {
      debugPrint('autoshare: файловый лок недоступен, продолжаем без него: $e');
      return true;
    }
  }

  /// Освобождение лока (тесты; прод держит хэндл до конца процесса).
  Future<void> release() async {
    final h = _handle;
    _handle = null;
    if (h != null) {
      try {
        await h.unlock();
      } catch (_) {}
      await h.close();
    }
  }
}
