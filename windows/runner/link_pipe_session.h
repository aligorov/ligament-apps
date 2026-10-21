#pragma once

#include <windows.h>

enum class LinkPipeSessionStatus { trusted, query_failed, not_session_zero };

struct LinkPipeSessionResult {
  LinkPipeSessionStatus status;
  ULONG session;
  DWORD error;
};

// Query the connected pipe, not the LocalSystem process. ProcessIdToSessionId
// requires PROCESS_QUERY_INFORMATION, which a standard desktop user may lack.
// Query failure remains a hard refusal: this is not a trust-check bypass.
template <typename Query>
LinkPipeSessionResult CheckLinkPipeSession(HANDLE pipe, Query query) {
  ULONG session = MAXDWORD;
  if (!query(pipe, &session)) {
    const DWORD error = GetLastError();
    return {LinkPipeSessionStatus::query_failed, MAXDWORD, error};
  }
  return {session == 0 ? LinkPipeSessionStatus::trusted
                       : LinkPipeSessionStatus::not_session_zero,
          session, ERROR_SUCCESS};
}

inline LinkPipeSessionResult CheckLinkPipeSession(HANDLE pipe) {
  return CheckLinkPipeSession(pipe, GetNamedPipeServerSessionId);
}
