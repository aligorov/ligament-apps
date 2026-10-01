// LigamentProvider.cpp — Implementation of ICredentialProvider and ICredentialProviderFilter
#include "LigamentProvider.h"
#include <wincred.h> // CREDUIWIN_*/CRED_PACK_WOW_BUFFER — флаги CPUS_CREDUI (wincred.h)

namespace ligament {

// Microsoft standard Password Credential Provider GUID: {60b78e88-ead8-445c-9cfd-0b87f74ea6cd}
static const GUID CLSID_PasswordProvider =
    { 0x60b78e88, 0xead8, 0x445c, { 0x9c, 0xfd, 0x0b, 0x87, 0xf7, 0x4e, 0xa6, 0xcd } };

// ---------------------------------------------------------- CPUS_CREDUI/UAC
// Имя исполняемого файла текущего хост-процесса без пути (сравнение дальше
// без регистра). UAC-промпт хостят consent.exe / CredentialUIBroker.exe /
// LogonUI.exe на secure desktop; произвольный app-CredUI (браузеры, runas)
// грузит DLL в процесс самого приложения — по имени хоста отличаем одно от
// другого (эмпирика флагов CREDUIWIN_* на живой элевации зависит от версии
// ОС и пути повышения, имя хоста закрывает остальное).
static std::wstring CurrentHostProcessName() {
    wchar_t path[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return std::wstring();
    const wchar_t* base = path + n;
    while (base > path && base[-1] != L'\\' && base[-1] != L'/') --base;
    return std::wstring(base);
}

// CREDUI-сценарий является UAC-элевацией («путь Duo»). Дискриминаторы:
//  - CREDUIWIN_ENUMERATE_ADMINS (0x100) — документированный маркер
//    «intended for User Account Control purposes only» (wincred.h);
//  - хост-процесс — системный UAC-хост (consent.exe и компания);
//  - CREDUIWIN_GENERIC — точно НЕ UAC-secure (несовместим с
//    CREDUIWIN_SECURE_PROMPT): произвольный app-CredUI, всегда «нет».
static bool IsUacElevationCredUI(DWORD dwFlags, const std::wstring& hostProcess) {
    if (dwFlags & CREDUIWIN_GENERIC) return false;
    if (dwFlags & CREDUIWIN_ENUMERATE_ADMINS) return true;
    return _wcsicmp(hostProcess.c_str(), L"consent.exe") == 0
        || _wcsicmp(hostProcess.c_str(), L"credentialuibroker.exe") == 0
        || _wcsicmp(hostProcess.c_str(), L"logonui.exe") == 0;
}

extern const CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR s_Fields[];

LigamentProvider::LigamentProvider() {
    InterlockedIncrement(&g_cRefDll);
    m_config = Config::LoadFromRegistry();
}

LigamentProvider::~LigamentProvider() {
    InterlockedDecrement(&g_cRefDll);
    if (m_pCredential) {
        m_pCredential->Release();
        m_pCredential = nullptr;
    }
    if (m_pEvents) {
        m_pEvents->Release();
        m_pEvents = nullptr;
    }
}

bool LigamentProvider::CheckIfRemoteSession() {
    if (GetSystemMetrics(SM_REMOTESESSION) != 0) {
        return true;
    }
    unsigned short* pProtocol = nullptr;
    DWORD bytes = 0;
    if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, WTSClientProtocolType, (LPWSTR*)&pProtocol, &bytes)) {
        bool isRdp = (pProtocol && *pProtocol != 0);
        WTSFreeMemory(pProtocol);
        if (isRdp) return true;
    }
    return false;
}

// IUnknown
HRESULT LigamentProvider::QueryInterface(REFIID riid, void** ppv) {
    static const QITAB qit[] = {
        QITABENT(LigamentProvider, ICredentialProvider),
        QITABENT(LigamentProvider, ICredentialProviderFilter),
        { 0 },
    };
    return QISearch(this, qit, riid, ppv);
}

ULONG LigamentProvider::AddRef() {
    return InterlockedIncrement(&m_cRef);
}

ULONG LigamentProvider::Release() {
    LONG c = InterlockedDecrement(&m_cRef);
    if (c == 0) delete this;
    return c;
}

// ICredentialProvider
HRESULT LigamentProvider::SetUsageScenario(CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus, DWORD dwFlags) {
    bool scenarioChanged = (m_scenario != cpus);
    m_scenario = cpus;
    m_flags = dwFlags;
    m_isRemoteSession = CheckIfRemoteSession();
    m_config = Config::LoadFromRegistry();

    // Recompute for every scenario: an enforce flag left over from a
    // previous scenario (e.g. LOGON -> CHANGE_PASSWORD) must not survive,
    // otherwise non-logon dialogs would be left without any usable tile.
    m_shouldEnforce2FA = false;

    // Check if 2FA applies to this scenario. Ненастроенный сервер
    // (ServerURL отсутствует/пуст) = 2FA не применяется ВООБЩЕ: ни RDP, ни
    // консоль. Важно согласованной логикой с Filter() — иначе наш тайл не
    // создан, а штатный парольный подавлен, и вход невозможен.
    if (cpus == CPUS_CREDUI) {
        // 2FA на повышение прав (UAC). Гейт строже, чем в LOGON: только
        // ЯВНЫЙ UAC-промпт — флаг CREDUIWIN_ENUMERATE_ADMINS или системный
        // хост (consent.exe / CredentialUIBroker.exe / LogonUI.exe) и НЕ
        // CREDUIWIN_GENERIC. Во всех прочих CredUI-диалогах (браузеры,
        // runas, app-CredUI) тайла быть не должно: E_NOTIMPL —
        // канонический способ скрыть провайдер из чужого перечисления
        // (паттерн MS-сэмпла SampleCredUICredentialProvider). Для
        // LOGON/UNLOCK поведение ниже не менялось.
        std::wstring host = CurrentHostProcessName();
        bool isUacPrompt = IsUacElevationCredUI(dwFlags, host);
        m_shouldEnforce2FA = m_config.serverUrlConfigured
            && m_config.elevation2faEnabled
            && isUacPrompt;
        // Паттерн privacyidea: cpus/flags/host/решение в лог — снимает
        // эмпирику флагов на живом стенде (секретов не пишем).
        LogDebug(L"SetUsageScenario(CREDUI): flags=0x%08lX host=%s uacPrompt=%d elev2fa=%d srvCfg=%d enforce2fa=%d",
            (unsigned long)dwFlags, host.empty() ? L"?" : host.c_str(), isUacPrompt ? 1 : 0,
            m_config.elevation2faEnabled ? 1 : 0, m_config.serverUrlConfigured ? 1 : 0,
            m_shouldEnforce2FA ? 1 : 0);
        if (!m_shouldEnforce2FA) {
            // Тайл НЕ создаём; GetCredentialCount=0 мало — S_OK заставил бы
            // хост держать нас в перечислении пустым провайдером.
            return E_NOTIMPL;
        }
    } else if (m_config.serverUrlConfigured && (cpus == CPUS_LOGON || cpus == CPUS_UNLOCK_WORKSTATION)) {
        if (m_isRemoteSession && m_config.rdp2faEnabled) {
            m_shouldEnforce2FA = true;
        } else if (!m_isRemoteSession && m_config.console2faEnabled) {
            m_shouldEnforce2FA = true;
        }
    }

    // Do not log infrastructure details (server URL) from the winlogon context
    LogDebug(L"SetUsageScenario: cpus=%d, remote=%d, srvCfg=%d, enforce2fa=%d",
        cpus, m_isRemoteSession ? 1 : 0, m_config.serverUrlConfigured ? 1 : 0, m_shouldEnforce2FA ? 1 : 0);

    if (m_shouldEnforce2FA) {
        if (!m_pCredential) {
            m_pCredential = new LigamentCredential();
            scenarioChanged = true;
        }
        // Один инстанс провайдера может пережить смену сценария
        // (LOGON → CREDUI в одном процессе): без пере-Initialize кредл
        // остался бы с m_cpus=LOGON — KERB-блоб вместо CredPack, метка
        // «Windows RDP» вместо «UAC Elevation», FIDO2 открыт на secure
        // desktop. Повторный вызов с тем же cpus — не пере-инициализируем
        // (иначе сбросится подтверждённый push→автологон-флоу).
        if (scenarioChanged) {
            m_pCredential->Initialize(m_config, m_isRemoteSession, cpus, dwFlags);
        }
        if (m_pEvents) {
            m_pCredential->SetProviderEvents(m_pEvents, m_adviseContext);
        }
    }
    return S_OK;
}

HRESULT LigamentProvider::SetSerialization(const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcs) {
    // Контракт (V2-сэмпл): S_OK означает «потребил, перечислю дефолтный тайл
    // под автологон». Мы удалённые креды не потребляем (2FA требует ручного
    // ввода) — честно возвращаем E_NOTIMPL, иначе LogonUI ждёт от нас тайл,
    // которого нет (диагноз агентов: сломанный remote-хэндофф).
    if (pcpcs && pcpcs->rgbSerialization && pcpcs->cbSerialization) {
        LogDebug(L"setser: получен удалённый блоб cb=%lu authPkg=%lu — не потреблён (E_NOTIMPL)",
            (unsigned long)pcpcs->cbSerialization, (unsigned long)pcpcs->ulAuthenticationPackage);
    }
    return E_NOTIMPL;
}

HRESULT LigamentProvider::Advise(ICredentialProviderEvents* pcpe, UINT_PTR upAdviseContext) {
    if (m_pEvents) m_pEvents->Release();
    m_pEvents = pcpe;
    m_adviseContext = upAdviseContext;
    if (m_pEvents) m_pEvents->AddRef();
    if (m_pCredential) {
        m_pCredential->SetProviderEvents(m_pEvents, m_adviseContext);
    }
    return S_OK;
}

HRESULT LigamentProvider::UnAdvise() {
    if (m_pCredential) {
        m_pCredential->SetProviderEvents(nullptr, 0);
    }
    if (m_pEvents) {
        m_pEvents->Release();
        m_pEvents = nullptr;
    }
    m_adviseContext = 0;
    return S_OK;
}

HRESULT LigamentProvider::GetFieldDescriptorCount(DWORD* pdwCount) {
    if (!pdwCount) return E_POINTER;
    *pdwCount = FID_NUM_FIELDS;
    return S_OK;
}

HRESULT LigamentProvider::GetFieldDescriptorAt(DWORD dwIndex, CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR** ppcpfd) {
    if (!ppcpfd) return E_POINTER;
    if (dwIndex >= FID_NUM_FIELDS) return E_INVALIDARG;

    CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR* pcpfd = (CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR*)CoTaskMemAlloc(sizeof(CREDENTIAL_PROVIDER_FIELD_DESCRIPTOR));
    if (!pcpfd) return E_OUTOFMEMORY;

    pcpfd->dwFieldID = s_Fields[dwIndex].dwFieldID;
    pcpfd->cpft = s_Fields[dwIndex].cpft;
    pcpfd->guidFieldType = s_Fields[dwIndex].guidFieldType;

    if (s_Fields[dwIndex].pszLabel) {
        SHStrDupW(s_Fields[dwIndex].pszLabel, &pcpfd->pszLabel);
    } else {
        pcpfd->pszLabel = nullptr;
    }

    *ppcpfd = pcpfd;
    return S_OK;
}

HRESULT LigamentProvider::GetCredentialCount(DWORD* pdwCount, DWORD* pdwDefault, BOOL* pbAutoLogonWithDefault) {
    if (!pdwCount || !pdwDefault || !pbAutoLogonWithDefault) return E_POINTER;

    if (m_shouldEnforce2FA && m_pCredential) {
        *pdwCount = 1;
        *pdwDefault = 0;
        *pbAutoLogonWithDefault = m_pCredential->IsAuthenticated() ? TRUE : FALSE;
        LogDebug(L"credcount: 1 тайл (enforce), default=0, autologon=%d", *pbAutoLogonWithDefault ? 1 : 0);
    } else {
        *pdwCount = 0;
        *pdwDefault = CREDENTIAL_PROVIDER_NO_DEFAULT;
        *pbAutoLogonWithDefault = FALSE;
        LogDebug(L"credcount: 0 тайлов (не enforce: cpus/remote/флаги)");
    }
    return S_OK;
}

HRESULT LigamentProvider::GetCredentialAt(DWORD dwIndex, ICredentialProviderCredential** ppcpc) {
    if (!ppcpc) return E_POINTER;
    if (dwIndex != 0 || !m_pCredential) return E_INVALIDARG;

    m_pCredential->AddRef();
    *ppcpc = m_pCredential;
    return S_OK;
}

// ICredentialProviderFilter: Filter out default password provider during remote RDP when 2FA is active
HRESULT LigamentProvider::Filter(
    CREDENTIAL_PROVIDER_USAGE_SCENARIO cpus,
    DWORD dwFlags,
    GUID* rgclsidProviders,
    BOOL* rgbAllow,
    DWORD cProviders)
{
    bool isRemote = CheckIfRemoteSession();
    Config cfg = Config::LoadFromRegistry();

    // Suppress the stock password tile only in interactive logon scenarios
    // where Ligament 2FA is actually enforced. Other usage scenarios
    // (CPUS_CHANGE_PASSWORD, CPUS_CRED_PICKER, ...) must keep
    // the standard providers working, otherwise password change and
    // credential dialogs become unusable.
    bool enforce = false;
    if (cpus == CPUS_LOGON || cpus == CPUS_UNLOCK_WORKSTATION) {
        // Тот же гейт, что и в SetUsageScenario: нет ServerURL — штатный
        // парольный тайл НЕ подавляем (2FA полностью выключена).
        enforce = cfg.serverUrlConfigured &&
            ((isRemote && cfg.rdp2faEnabled) || (!isRemote && cfg.console2faEnabled));
    } else if (cpus == CPUS_CREDUI) {
        // UAC-элевация: тот же гейт, что и SetUsageScenario(CREDUI).
        // Официальные правила CredUI-фильтра (паттерн multiOTP): при
        // CREDUIWIN_GENERIC НЕ фильтровать никогда — чужой app-CredUI
        // обязан работать с штатными провайдерами. Ниже подавляется
        // ТОЛЬКО CLSID_PasswordProvider; неизвестные CLSID не трогаем.
        std::wstring host = CurrentHostProcessName();
        bool isUacPrompt = IsUacElevationCredUI(dwFlags, host);
        enforce = !(dwFlags & CREDUIWIN_GENERIC)
            && cfg.serverUrlConfigured
            && cfg.elevation2faEnabled
            && isUacPrompt;
        LogDebug(L"filter(CREDUI): flags=0x%08lX host=%s uacPrompt=%d elev2fa=%d srvCfg=%d enforce=%d",
            (unsigned long)dwFlags, host.empty() ? L"?" : host.c_str(), isUacPrompt ? 1 : 0,
            cfg.elevation2faEnabled ? 1 : 0, cfg.serverUrlConfigured ? 1 : 0, enforce ? 1 : 0);
    }

    DWORD suppressed = 0;
    if (enforce) {
        for (DWORD i = 0; i < cProviders; ++i) {
            if (IsEqualGUID(rgclsidProviders[i], CLSID_PasswordProvider)) {
                // Suppress standard password-only tile in favor of Ligament 2FA
                rgbAllow[i] = FALSE;
                ++suppressed;
            }
        }
    }
    LogDebug(L"filter: cpus=%lu flags=0x%08lX remote=%d srvCfg=%d rdp2fa=%d console2fa=%d elev2fa=%d enforce=%d providers=%lu suppressedStock=%lu",
        (unsigned long)cpus, (unsigned long)dwFlags, isRemote ? 1 : 0, cfg.serverUrlConfigured ? 1 : 0, cfg.rdp2faEnabled ? 1 : 0,
        cfg.console2faEnabled ? 1 : 0, cfg.elevation2faEnabled ? 1 : 0, enforce ? 1 : 0,
        (unsigned long)cProviders, (unsigned long)suppressed);
    return S_OK;
}

HRESULT LigamentProvider::UpdateRemoteCredential(
    const CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcsIn,
    CREDENTIAL_PROVIDER_CREDENTIAL_SERIALIZATION* pcpcsOut)
{
    // NLA-креды от mstsc приходят сюда. Мы их не перехватываем (2FA требует
    // ручного ввода) — но ФИКСИРУЕМ факт прихода: важный маркер RDP-потока.
    if (pcpcsIn && pcpcsIn->rgbSerialization && pcpcsIn->cbSerialization) {
        LogDebug(L"remote-cred: получен блоб cb=%lu authPkg=%lu — не перехватываем",
            (unsigned long)pcpcsIn->cbSerialization,
            (unsigned long)pcpcsIn->ulAuthenticationPackage);
    } else {
        LogDebug(L"remote-cred: вызов с пустым входом");
    }
    UNREFERENCED_PARAMETER(pcpcsOut);
    return E_NOTIMPL;
}

} // namespace ligament
