// LigamentCredential.h — ICredentialProviderCredential implementation
#pragma once

#include "common.h"
#include "HttpApiClient.h"
#include "WebAuthnClient.h"

namespace ligament {

enum FIELD_ID {
    FID_LOGO = 0,
    FID_LARGE_TEXT,
    FID_USERNAME,
    FID_PASSWORD,
    FID_SUBMIT,
    FID_STATUS_TEXT,
    FID_NUMBER_MATCH,
    FID_FIDO2_BTN,
    FID_OTP_CODE,
    FID_SWITCH_FACTOR_BTN,
    FID_NUM_FIELDS
};

enum AUTH_FACTOR_MODE {
    MODE_FIDO2 = 0,
    MODE_PUSH,
    MODE_OTP
};

extern const CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR s_Fields[];

class LigamentCredential : public ICredentialProviderCredential {
public:
    LigamentCredential();
    virtual ~LigamentCredential();

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv);
    IFACEMETHODIMP_(ULONG) AddRef();
    IFACEMETHODIMP_(ULONG) Release();

    // ICredentialProviderCredential
    IFACEMETHODIMP Advise(ICredentialProviderCredentialEvents* pcpce);
    IFACEMETHODIMP UnAdvise();
    IFACEMETHODIMP SetSelected(BOOL* pbAutoLogon);
    IFACEMETHODIMP SetDeselected();
    IFACEMETHODIMP GetFieldState(DWORD dwFieldID, CREDENTIAL_PROVIDER_FIELD_STATE* pcpfs, CREDENTIAL_PROVIDER_FIELD_INTERACTIVE_STATE* pcpfis);
    IFACEMETHODIMP GetStringValue(DWORD dwFieldID, PWSTR* ppsz);
    IFACEMETHODIMP GetBitmapValue(DWORD dwFieldID, HBITMAP* phbmp);
    IFACEMETHODIMP GetCheckboxValue(DWORD dwFieldID, BOOL* pbChecked, PWSTR* ppszLabel);
    IFACEMETHODIMP GetSubmitButtonValue(DWORD dwFieldID, DWORD* pdwAdjacentTo);
    IFACEMETHODIMP GetComboBoxValueCount(DWORD dwFieldID, DWORD* pcItems, DWORD* pdwSelectedItem);
    IFACEMETHODIMP GetComboBoxValueAt(DWORD dwFieldID, DWORD dwItem, PWSTR* ppszItem);
    IFACEMETHODIMP SetStringValue(DWORD dwFieldID, PCWSTR psz);
    IFACEMETHODIMP SetCheckboxValue(DWORD dwFieldID, BOOL bChecked);
    IFACEMETHODIMP SetComboBoxSelectedValue(DWORD dwFieldID, DWORD dwSelectedItem);
    IFACEMETHODIMP CommandLinkClicked(DWORD dwFieldID);
    IFACEMETHODIMP GetSerialization(
        CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* pcpgsr,
        CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs,
        PWSTR* ppszOptionalStatusText,
        CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon
    );
    IFACEMETHODIMP ReportResult(
        NTSTATUS ntsStatus,
        NTSTATUS ntsSubstatus,
        PWSTR* ppszOptionalStatusText,
        CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon
    );

    void Initialize(const Config& cfg, bool isRemote, CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus);
    void SetProviderEvents(ICredentialProviderEvents* pcpe, UINT_PTR upAdviseContext);
    bool IsAuthenticated() const { return m_authenticated; }

private:
    LONG m_cRef = 1;
    ICredentialProviderCredentialEvents* m_pEvents = nullptr;
    DWORD m_dwEventsCookie = 0;
    ICredentialProviderEvents* m_pProviderEvents = nullptr;
    DWORD m_dwProviderEventsCookie = 0;
    UINT_PTR m_providerAdviseContext = 0;
    Config m_config;
    bool m_isRemoteSession = false;
    CREDENTIAL_PROVIDER_USAGE_SCENARIO m_cpus = CPUS_LOGON;

    AUTH_FACTOR_MODE m_currentMode = MODE_PUSH;
    std::wstring m_username;
    std::wstring m_domain;
    std::wstring m_password;
    std::wstring m_otpCode;
    std::wstring m_statusText;
    std::wstring m_numberMatch;

    // Флаг подтверждённого второго фактора. Единственное поле, которое воркер
    // опроса пишет в обход потока LogonUI (до CredentialsChanged, иначе
    // SetSelected не увидит его для авто-логона): выровненный volatile bool,
    // запись — под m_csPoll, чтение без блокировки (на Windows/x86/x64
    // атомарно для MSVC volatile). Строковые поля воркером не трогать.
    volatile bool m_authenticated = false;
    std::unique_ptr<WebAuthnClient> m_webAuthn;

    HBITMAP m_hQrBmp = nullptr;
    HBITMAP m_hDefaultLogoBmp = nullptr;
    void ClearQrBitmap();
    void NotifyQrChanged();
    static HBITMAP CreateQrBitmap(const std::string& text, int targetSize = 256);
    static HBITMAP CreateLogoBitmap(int targetSize = 256);

    // --- Асинхронный HTTP-воркер ------------------------------------------
    // ВСЕ обращения к серверу (StartPush / WebAuthnBegin / VerifyOtp и опрос
    // статуса челленджа) выполняются ТОЛЬКО на воркер-потоке со своим
    // HttpApiClient: блокирующий WinHTTP на потоке LogonUI замораживал
    // экран входа до ~30-60 с ровно при сетевых проблемах. LogonUI стартует
    // задачу (StartWorkerJob) и забирает результат/обновляет UI только под
    // m_csPoll. Воркер не трогает COM и строки UI-состояния напрямую, кроме
    // volatile bool m_authenticated (см. выше) — единственное исключение.
    HANDLE m_hPollThread = nullptr;
    CRITICAL_SECTION m_csPoll;

    enum WorkerJob { JobNone = 0, JobStartPush, JobWebAuthnBegin, JobVerifyOtp };

    struct WorkerState {
        bool stop = false;
        // Фаза 1 — стартовый вызов (StartPush / WebAuthnBegin / VerifyOtp)
        bool beginDone = false;
        bool beginOk = false;
        std::string beginError;     // код сервера/транспорта ("network_error", "rate_limited", ...)
        int retryAfterSec = 0;
        std::wstring numberMatch;   // JobStartPush: контрольное число для тайла
        std::wstring qrUrl;         // JobWebAuthnBegin: ссылка для QR-кода
        // Фаза 2 — опрос статуса челленджа (после успешной фазы 1)
        bool done = false;
        std::wstring status;        // "approved" / "denied" / "expired" / "timeout"
    } m_worker;

    WorkerJob m_job = JobNone;
    std::wstring m_jobUser;
    std::wstring m_jobPass;         // копия для воркера; затирается сразу после получения
    std::wstring m_jobOtp;
    bool m_beginApplied = false;    // LogonUI уже применил результат фазы 1 к UI

    static DWORD WINAPI WorkerThreadProc(LPVOID lpParam);
    void RunAsyncJob();
    bool StartWorkerJob(WorkerJob job, const wchar_t* statusText);
    void StopPollThread();
    void JoinPollThread();
    // CredentialsChanged из воркера: с собственной AddRef-ссылкой на
    // m_pProviderEvents под m_csPoll (защита от UnAdvise-гонки).
    void NotifyProviderChangedFromWorker();
    void ResetAuthState();

    void TriggerFIDO2Auth();
    void SwitchToNextMode();
    void UpdateFieldStates();
    void NotifyFieldChanged(DWORD dwFieldID);
    HRESULT KerbInteractiveLogonPack(
        const std::wstring& domain,
        const std::wstring& user,
        const std::wstring& password,
        CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs
    );
    HRESULT PackAndFinish(
        CREDENTIAL_PROVIDER_GET_SERIALIZATION_RESPONSE* pcpgsr,
        CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs,
        PWSTR* ppszOptionalStatusText,
        CREDENTIAL_PROVIDER_STATUS_ICON* pcpsiOptionalStatusIcon
    );
};

} // namespace ligament
