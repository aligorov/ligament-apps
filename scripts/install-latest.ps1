# ==============================================================================
# Ligament 2FA — Автоматическая загрузка и установка последней версии
# Поддерживает:
#   1. Полную установку через MSI: десктоп-клиент + RDP Credential Provider
#      одним пакетом (MSI запускается с INSTALLRDP=1 — включает опциональную
#      feature RdpCredentialProviderFeature; ZIP-развёртывание не используется)
#   2. Установку только десктоп-приложения через MSI (RDP-провайдер по
#      умолчанию НЕ ставится; ключ -InstallRDP включает его тем же MSI)
#   3. Установку только Credential Provider для RDP-серверов терминалов
#      (без GUI) через ZIP Ligament-2FA-RDP-CredentialProvider-x64.zip
#
# Запуск в PowerShell (от Администратора):
#   .\install-latest.ps1
#
# Однострочный запуск напрямую из сети:
#   irm https://raw.githubusercontent.com/aligorov/ligament-apps/main/scripts/install-latest.ps1 | iex
# ==============================================================================

[CmdletBinding()]
param (
    [ValidateSet("All", "App", "CP", "Interactive")]
    [string]$Component = "Interactive",

    [string]$ServerURL = "",

    [string]$Version = "latest",

    [switch]$Silent,

    # Разрешить установку компонентов БЕЗ цифровой подписи (CI/тест).
    # Битая/отозванная подпись блокируется всегда.
    [switch]$AllowUnsigned,

    # Включить RDP Credential Provider в составе MSI (в msiexec передаётся
    # INSTALLRDP=1). Имеет смысл в режиме App; в режиме All провайдер
    # включается всегда. По умолчанию RDP-провайдер НЕ ставится.
    [switch]$InstallRDP
)

# 1. Проверка прав Администратора и авто-элевация
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Требуются права Администратора. Запуск от имени Администратора..." -ForegroundColor Yellow
    if ($PSCommandPath) {
        $argsList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Component -ne "Interactive") { $argsList += " -Component $Component" }
        if ($ServerURL) { $argsList += " -ServerURL `"$ServerURL`"" }
        if ($Version -ne "latest") { $argsList += " -Version `"$Version`"" }
        if ($Silent) { $argsList += " -Silent" }
        if ($AllowUnsigned) { $argsList += " -AllowUnsigned" }
        if ($InstallRDP) { $argsList += " -InstallRDP" }
    } else {
        $cmd = "irm 'https://raw.githubusercontent.com/aligorov/ligament-apps/main/scripts/install-latest.ps1?v=$(Get-Random)' | iex"
        $argsList = "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
    }
    Start-Process powershell -Verb RunAs -ArgumentList $argsList
    exit
}

# Включаем TLS 1.2 / TLS 1.3 и отключаем медленный GUI-прогресс PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Проверка Authenticode-подписи скачанного артефакта перед установкой.
# Компонент попадает в цепочку входа Windows (credential provider), поэтому
# неподписанный/битый бинарник — это прямой путь к supply-chain компрометации
# домена. Валидная подпись → ОК; нет подписи → подтверждение или -AllowUnsigned;
# битая/отозванная → жёсткий отказ.
function Assert-ArtifactTrusted {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path $Path)) { throw "Файл не найден: $Path" }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    switch ($sig.Status) {
        'Valid' {
            Write-Host " [OK] Подпись $Label действительна ($($sig.SignerCertificate.Subject))" -ForegroundColor Green
            return
        }
        'NotSigned' {
            if ($AllowUnsigned) {
                Write-Host " [!] $Label НЕ ПОДПИСАН — продолжаю по ключу -AllowUnsigned" -ForegroundColor Yellow
                return
            }
            if (-not $Silent) {
                Write-Host " [!] $Label не имеет цифровой подписи." -ForegroundColor Yellow
                $answer = (Read-Host "Ставить неподписанный компонент? Введите YES для подтверждения").Trim()
                if ($answer -eq 'YES') { return }
            }
            throw "Отказ: $Label без Authenticode-подписи. Подпишите артефакты или используйте -AllowUnsigned (не для продакшена)."
        }
        default {
            throw "Отказ: подпись $Label НЕ ПРОШЛА проверку (статус: $($sig.Status)) — вероятна подмена файла."
        }
    }
}

$RepoOwner = "aligorov"
$RepoName  = "ligament-apps"
$RepoBase  = "https://github.com/$RepoOwner/$RepoName"
$ApiBase   = "https://api.github.com/repos/$RepoOwner/$RepoName"

Clear-Host
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "         Ligament 2FA — Установщик и Обновление для Windows       " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

# 2. Определение последней версии через GitHub API или fallback
Write-Host "[1/4] Поиск последнего релиза $RepoOwner/$RepoName..." -ForegroundColor Yellow
$tag = $Version
$downloadBaseUrl = ""

try {
    $headers = @{ "User-Agent" = "Ligament-Installer" }
    if ($Version -eq "latest") {
        $releaseInfo = Invoke-RestMethod -Uri "$ApiBase/releases/latest" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
        $tag = $releaseInfo.tag_name
        Write-Host " [OK] Найдена последняя версия: $tag ($($releaseInfo.name))" -ForegroundColor Green
    } else {
        $tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
        Write-Host " [OK] Выбрана указанная версия: $tag" -ForegroundColor Green
    }
    $downloadBaseUrl = "https://github.com/$RepoOwner/$RepoName/releases/download/$tag"
} catch {
    Write-Host " [!] Не удалось связаться с GitHub API (лимит запросов или офлайн). Используется direct release fallback." -ForegroundColor Yellow
    $tag = if ($Version -eq "latest") { "latest" } else { if ($Version.StartsWith("v")) { $Version } else { "v$Version" } }
    $downloadBaseUrl = if ($tag -eq "latest") { "$RepoBase/releases/latest/download" } else { "$RepoBase/releases/download/$tag" }
}

# 3. Интерактивное меню (если не передан аргумент -Component)
if ($Component -eq "Interactive" -and -not $Silent) {
    Write-Host ""
    Write-Host "Выберите тип установки:" -ForegroundColor Cyan
    Write-Host "  [1] Всё вместе: Десктоп-приложение + RDP Credential Provider (один MSI, INSTALLRDP=1)" -ForegroundColor White
    Write-Host "  [2] Только десктоп-приложение (MSI, RDP-провайдер не ставится — по умолчанию выключен)" -ForegroundColor White
    Write-Host "  [3] Только RDP Credential Provider для серверов терминалов (ZIP DLL в System32, без GUI)" -ForegroundColor White
    Write-Host "  [4] Выход" -ForegroundColor Gray
    Write-Host ""
    $choice = (Read-Host "Введите номер (1-4) [по умолчанию 1]").Trim()
    if ($choice -eq "2") {
        $Component = "App"
    } elseif ($choice -eq "3") {
        $Component = "CP"
    } elseif ($choice -eq "4") {
        Write-Host "Отменено пользователем." -ForegroundColor Yellow
        exit 0
    } else {
        $Component = "All"
    }
} elseif ($Component -eq "Interactive") {
    $Component = "All"
}

# 4. Проверка и настройка ServerURL
$RegPolicyPath = "HKLM:\SOFTWARE\Policies\Ligament\2FA"
$currentServerUrl = ""
if (Test-Path $RegPolicyPath) {
    $currentServerUrl = (Get-ItemProperty -Path $RegPolicyPath -Name "ServerURL" -ErrorAction SilentlyContinue).ServerURL
}

if (-not $ServerURL) {
    if ($currentServerUrl) {
        $ServerURL = $currentServerUrl
        Write-Host "Текущий адрес сервера 2FA: $ServerURL" -ForegroundColor Gray
    } elseif (-not $Silent) {
        Write-Host ""
        $inputUrl = (Read-Host "Введите адрес сервера 2FA (например: https://2fa.corp.ru) [Enter чтобы настроить позже]").Trim()
        if ($inputUrl) {
            $ServerURL = $inputUrl.TrimEnd('/')
        }
    }
}

$TempDir = Join-Path $env:TEMP ("LigamentSetup_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    # -------------------------------------------------------------------------
    # КОМПОНЕНТ 1: УСТАНОВКА ЧЕРЕЗ MSI (Десктоп приложение)
    # -------------------------------------------------------------------------
    if ($Component -in @("All", "App")) {
        $MsiFileName = "Ligament-2FA-Windows-x64.msi"
        $MsiUrl = "$downloadBaseUrl/$MsiFileName"
        $LocalMsi = Join-Path $TempDir $MsiFileName

        Write-Host "`nЗагрузка инсталлятора $MsiFileName..." -ForegroundColor Yellow
        Write-Host "URL: $MsiUrl" -ForegroundColor Gray
        Invoke-WebRequest -Uri $MsiUrl -OutFile $LocalMsi -UseBasicParsing
        Write-Host " [OK] Загружено: $LocalMsi ($([math]::Round((Get-Item $LocalMsi).Length / 1MB, 2)) МБ)" -ForegroundColor Green

        Write-Host "`nПроверка цифровой подписи MSI..." -ForegroundColor Yellow
        Assert-ArtifactTrusted -Path $LocalMsi -Label $MsiFileName

        Write-Host "`nОстановка активных процессов..." -ForegroundColor Yellow
        Stop-Process -Name "ligament_authenticator" -Force -ErrorAction SilentlyContinue
        taskkill /f /im logonui.exe 2>$null | Out-Null

        Write-Host "`nУстановка пакета MSI..." -ForegroundColor Yellow
        $msiArgs = "/i `"$LocalMsi`" /qn /norestart"
        if ($ServerURL) {
            $msiArgs += " SERVERURL=`"$ServerURL`""
        }

        # RDP Credential Provider включается свойством INSTALLRDP=1
        # (feature RdpCredentialProviderFeature, Level=2 — по умолчанию не ставится).
        # Режим «All»: ставим приложение + RDP-провайдер одним MSI —
        # DLL кладётся в System32 и регистрируется самим установщиком,
        # ZIP-развёртывание в System32 больше не выполняется.
        # Режим «App»: только приложение; ключ -InstallRDP опционально
        # добавляет RDP-провайдер тем же пакетом.
        if ($Component -eq "All" -or $InstallRDP) {
            $msiArgs += " INSTALLRDP=1"
            Write-Host " Включена MSI-feature RdpCredentialProviderFeature (INSTALLRDP=1)" -ForegroundColor Gray
        }

        $process = Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
            Write-Error "Ошибка установки MSI. Код выхода msiexec: $($process.ExitCode)"
        }
        Write-Host " [OK] Пакет MSI успешно установлен!" -ForegroundColor Green

        # Убедимся, что дефолтный фактор = 0 (Push Number Matching)
        if (-not (Test-Path $RegPolicyPath)) {
            New-Item -Path $RegPolicyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $RegPolicyPath -Name "DefaultFactor" -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $RegPolicyPath -Name "FIDO2Enabled" -Value 1 -Type DWord -Force
        if ($ServerURL) {
            Set-ItemProperty -Path $RegPolicyPath -Name "ServerURL" -Value $ServerURL -Type String -Force
        }

        # 2FA для RDP и консоли ПО УМОЛЧАНИЮ ВЫКЛЮЧЕНА (RDP2FAEnabled=0 и
        # Console2FAEnabled=0 — локальные дефолты MSI и дефолт кода CP).
        # Установка провайдера и включение 2FA — независимые действия:
        # включается только явной политикой (команды — в итоговой сводке).
    }

    # -------------------------------------------------------------------------
    # КОМПОНЕНТ 2: РАЗВЕРТЫВАНИЕ RDP CREDENTIAL PROVIDER ЧЕРЕЗ ZIP (System32 + COM DLL)
    # Только для режима "CP" — установка на серверы терминалов (RDS) без GUI.
    # Для рабочих станций провайдер ставится MSI с INSTALLRDP=1 (режим выше).
    # -------------------------------------------------------------------------
    if ($Component -eq "CP") {
        $ZipFileName = "Ligament-2FA-RDP-CredentialProvider-x64.zip"
        $ZipUrl = "$downloadBaseUrl/$ZipFileName"
        $LocalZip = Join-Path $TempDir $ZipFileName

        Write-Host "`nЗагрузка RDP Credential Provider $ZipFileName..." -ForegroundColor Yellow
        Write-Host "URL: $ZipUrl" -ForegroundColor Gray
        Invoke-WebRequest -Uri $ZipUrl -OutFile $LocalZip -UseBasicParsing
        Write-Host " [OK] Загружено: $LocalZip ($([math]::Round((Get-Item $LocalZip).Length / 1MB, 2)) МБ)" -ForegroundColor Green

        Write-Host "`n[3/4] Распаковка компонентов..." -ForegroundColor Yellow
        $ExtractDir = Join-Path $TempDir "ExtractedCP"
        Expand-Archive -Path $LocalZip -DestinationPath $ExtractDir -Force

        $DllSource = Join-Path $ExtractDir "LigamentCredentialProvider.dll"
        if (-not (Test-Path $DllSource)) {
            $found = Get-ChildItem -Path $ExtractDir -Filter "LigamentCredentialProvider.dll" -Recurse | Select-Object -First 1
            if ($found) { $DllSource = $found.FullName }
        }

        if (-not (Test-Path $DllSource)) {
            Write-Error "В архиве не найдена библиотека LigamentCredentialProvider.dll!"
        }

        # DLL грузится в logonui.exe (SYSTEM) — неподписанный бинарник здесь
        # недопустим: проверяем подпись ДО копирования в System32.
        Write-Host "`nПроверка цифровой подписи Credential Provider DLL..." -ForegroundColor Yellow
        Assert-ArtifactTrusted -Path $DllSource -Label "LigamentCredentialProvider.dll"

        Write-Host "`n[4/4] Развертывание Credential Provider в System32..." -ForegroundColor Yellow
        taskkill /f /im logonui.exe 2>$null | Out-Null

        $Sys32 = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        $TargetDll = Join-Path $Sys32 "LigamentCredentialProvider.dll"
        $OldDll = Join-Path $Sys32 "LigamentCredentialProvider.dll.old"

        # Если DLL занята процессом LogonUI — удаляем старый .old и переименовываем активную
        if (Test-Path $OldDll) { Remove-Item -Path $OldDll -Force -ErrorAction SilentlyContinue }
        if (Test-Path $TargetDll) {
            try {
                Move-Item -Path $TargetDll -Destination $OldDll -Force -ErrorAction Stop
            } catch {
                Write-Host " [!] Файл занят, принудительное завершение logonui..." -ForegroundColor Yellow
                taskkill /f /im logonui.exe 2>$null | Out-Null
                Start-Sleep -Milliseconds 500
                Move-Item -Path $TargetDll -Destination $OldDll -Force
            }
        }

        Copy-Item -Path $DllSource -Destination $TargetDll -Force
        Write-Host " [OK] Скопировано в $TargetDll" -ForegroundColor Green

        # Регистрация COM DLL
        $regSvr = Start-Process "regsvr32.exe" -ArgumentList "/s `"$TargetDll`"" -Wait -PassThru
        Write-Host " [OK] Регистрация DLL выполнена (regsvr32 exit code: $($regSvr.ExitCode))" -ForegroundColor Green

        # Политики реестра
        $tsPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
        if (-not (Test-Path $tsPolicy)) { New-Item -Path $tsPolicy -Force | Out-Null }
        Set-ItemProperty -Path $tsPolicy -Name "fEnableWebAuthn" -Value 1 -Type DWord -Force

        if (-not (Test-Path $RegPolicyPath)) { New-Item -Path $RegPolicyPath -Force | Out-Null }
        # RDP2FAEnabled НЕ включаем: 2FA для RDP и консоли по умолчанию
        # выключена, активация — только явной политикой (сводка в конце).
        Set-ItemProperty -Path $RegPolicyPath -Name "FIDO2Enabled" -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $RegPolicyPath -Name "DefaultFactor" -Value 0 -Type DWord -Force
        if ($ServerURL) {
            Set-ItemProperty -Path $RegPolicyPath -Name "ServerURL" -Value $ServerURL -Type String -Force
        }

        # Перезапуск экрана входа LogonUI
        taskkill /f /im logonui.exe 2>$null | Out-Null
        Write-Host " [OK] LogonUI обновлен" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "                УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                      " -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host " Версия:             $tag" -ForegroundColor White
    Write-Host " Режим по умолчанию: Push Number Matching (число в приложении Ligament)" -ForegroundColor White
    $rdpInstalled = ($Component -in @("All", "CP") -or $InstallRDP)
    if ($rdpInstalled) {
        Write-Host " RDP Credential Provider: установлен; 2FA для RDP/консоли ВЫКЛЮЧЕНА (по умолчанию)" -ForegroundColor White
        Write-Host "   Включить 2FA для RDP:    reg add `"$RegPolicyPath`" /v RDP2FAEnabled /t REG_DWORD /d 1 /f" -ForegroundColor Gray
        Write-Host "   Включить 2FA для консоли: reg add `"$RegPolicyPath`" /v Console2FAEnabled /t REG_DWORD /d 1 /f" -ForegroundColor Gray
    } else {
        Write-Host " RDP Credential Provider: НЕ установлен (по умолчанию выключен)" -ForegroundColor White
        Write-Host "   Включить позже: msiexec /i Ligament-2FA-Windows-x64.msi ADDLOCAL=RdpCredentialProviderFeature" -ForegroundColor Gray
    }
    $srv = (Get-ItemProperty -Path $RegPolicyPath -Name "ServerURL" -ErrorAction SilentlyContinue).ServerURL
    Write-Host " Сервер 2FA:         $srv" -ForegroundColor White
    Write-Host ""
    if (-not $srv) {
        Write-Host "[!] ВНИМАНИЕ: Адрес сервера 2FA еще не настроен!" -ForegroundColor Yellow
        Write-Host "Задайте его командой:" -ForegroundColor Cyan
        Write-Host "  reg add `"$RegPolicyPath`" /v ServerURL /t REG_SZ /d `"https://2fa.your-company.ru`" /f" -ForegroundColor White
        Write-Host ""
    }

} finally {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $Silent) {
    Write-Host "`nНажмите Enter для завершения..."
    try {
        $null = Read-Host
    } catch {}
}
