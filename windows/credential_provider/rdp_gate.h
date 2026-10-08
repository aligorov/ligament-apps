// rdp_gate.h — CP-гейт RDP MFA (сервер internal/api/rdp_cp.go, аудит #2,
// план §4.4/§6): перед MFA-каскадом спрашиваем ядро, есть ли у юзера
// активная RDP-сессия шлюза Ligament, ЦЕЛЬ которой — ЭТА машина.
// satisfied=true → второй фактор уже засчитан шлюзом, каскад пропускаем.
#pragma once

#include "common.h"

namespace ligament {

struct RdpGateResult {
    // true — шлюз подтвердил второй фактор для этого юзера на этой машине.
    bool satisfied = false;
    // true — гейт ответил по HTTP (код распознан, тело прочитано). false —
    // транспортный отказ/отклонение запроса: CP обязан работать как обычно.
    bool responded = false;
    // Несекретный диагноз для cp.log ("network_error", "status_403",
    // "not_satisfied", "not_configured", ...). Никаких кредов/URL.
    std::string note;
};

// GET {serverUrl}/api/v1/cp/rdp-mfa-satisfied?username=..&machine=..
// с заголовком X-CP-Secret = hex(SHA256("ligament-cp:" + serverUrl)).
//
// serverUrl — значение ServerURL из реестра; нормализуется как на сервере
// (settings.go: TrimSpace + TrimRight "/")). ХЕШИРУЕТСЯ НОРМАЛИЗИРОВАННЫЙ
// ДОМЕН, поэтому хвостовой слэш в реестре не ломает секрет.
// computerName — NetBIOS-имя цели (GetComputerNameW): сервер сравнивает
// его с hostname эндпоинта активного гранта (привязка к машине).
//
// БЛОКИРУЮЩИЙ вызов (таймауты WinHTTP ~3 c): только с воркер-потока,
// никогда с потока LogonUI (см. RunAsyncJob). Любая ошибка — сеть, плохой
// URL/схема, не-200, битый JSON, сбой SHA256 → satisfied=false
// (fail-closed: гейт недоступен → CP работает как обычно).
RdpGateResult CheckRdpMfaSatisfied(
    const std::wstring& serverUrl,
    const std::wstring& username,
    const std::wstring& computerName,
    bool allowSelfSigned = false,
    bool allowHttp = false);

} // namespace ligament
