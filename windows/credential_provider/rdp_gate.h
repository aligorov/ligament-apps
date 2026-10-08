// rdp_gate.h — CP-гейт RDP MFA, контракт logon-bound assertion (сервер
// internal/api/rdp_cp.go, закрытие аудита P1 #2 от 2026-10-08, миграция
// 0065). Пропуск MFA возможен ровно ОДИН раз на claim гранта шлюза:
//
//   1) ядро после claim гранта выдаёт одноразовый nonce (TTL 5 мин) и
//      доставляет его endpoint-службе кадром agent_assertion;
//   2) CP забирает nonce у службы через named pipe \\.\pipe\LigamentRdpGate;
//   3) CP предъявляет ядру POST /api/v1/cp/rdp-assert с nonce, LogonId
//      СВОЕГО логон-окна (GetTokenInformation TokenStatistics) и именем
//      машины, аутентифицируясь agent_key endpoint'а (реестр RdpAgentKey —
//      тот же, что у endpoint-службы; в БД только sha256);
//   4) ядро атомарно гасит assertion → {"satisfied":true} → MFA-каскад
//      пропускается. Повторное предъявление = false (окно одно).
//
// Второе подключение того же юзера к той же машине получает НОВЫЙ грант
// (со свежей MFA-попыткой) — прежний «активный грант = satisfied» больше
// не работает.
#pragma once

#include "common.h"

namespace ligament {

struct RdpGateResult {
    // true — шлюз подтвердил второй фактор для ЭТОГО окна подключения.
    bool satisfied = false;
    // true — гейт ответил по HTTP (код распознан, тело прочитано). false —
    // транспортный отказ/отклонение запроса: CP обязан работать как обычно.
    bool responded = false;
    // Несекретный диагноз для cp.log ("network_error", "status_403",
    // "not_satisfied", "no_assertion", "no_agent_key", ...). Без кредов.
    std::string note;
};

// POST {serverUrl}/api/v1/cp/rdp-assert {nonce, logon_id, machine}
// с заголовком Authorization: Bearer <agent_key из реестра>.
//
// computerName — NetBIOS-имя цели (GetComputerNameW): сервер сверяет его
// с hostname endpoint'а (привязка к машине). nonce берётся у endpoint-
// службы (named pipe), LogonId — из контекста процесса CP.
//
// БЛОКИРУЮЩИЙ вызов (таймауты WinHTTP ~3 с + pipe ~2 с): только с
// воркер-потока, никогда с потока LogonUI (см. RunAsyncJob). Любая
// ошибка — нет службы/nonce/ключа, сеть, плохой URL/схема, не-200, битый
// JSON → satisfied=false (fail-closed: гейт недоступен → CP работает как
// обычно).
RdpGateResult CheckRdpMfaSatisfied(
    const std::wstring& serverUrl,
    const std::wstring& computerName,
    bool allowSelfSigned = false,
    bool allowHttp = false);

} // namespace ligament
