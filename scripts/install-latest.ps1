# ==============================================================================
# Ligament 2FA — Установка последней версии (единый полный MSI)
# Пакет содержит: десктоп-приложение + RDP Credential Provider + службу
# Ligament2FAService. 2FA входа (RDP/консоль) ВЫКЛЮЧЕНА по умолчанию —
# включается политикой (см. итоговую сводку скрипта).
#
# Запуск в PowerShell (от Администратора):
#   .\scripts\install-latest.ps1
#
# С проверкой целостности артефакта по хэшу из примечаний к релизу:
#   .\scripts\install-latest.ps1 -ExpectedSha256 <hex-64>
#   (или через переменную окружения LIGAMENT_EXPECTED_SHA256 — то же самое)
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

    # Ожидаемый SHA256 MSI-артефакта (64 hex-символа, из примечаний к
    # релизу). Если задан — хэш скачанного файла сверяется ДО запуска
    # установки; несовпадение = жёсткий отказ (A-5, аудит 2026-10-12).
    [string]$ExpectedSha256 = "",

    [switch]$Silent,

    # Разрешить установку компонентов БЕЗ цифровой подписи (CI/тест).
    # Битая/отозванная подпись блокируется всегда.
    [switch]$AllowUnsigned,

    # Включить RDP Credential Provider в составе MSI (в msiexec передаётся
    # включается всегда. По умолчанию RDP-провайдер НЕ ставится.
)

# 1. Проверка прав Администратора и авто-элевация
# A-5: -ExpectedSha256 можно задать и переменной окружения
# LIGAMENT_EXPECTED_SHA256 (проброс из install-latest.bat / CI).
if (-not $ExpectedSha256 -and $env:LIGAMENT_EXPECTED_SHA256) {
    $ExpectedSha256 = $env:LIGAMENT_EXPECTED_SHA256
}
if ($ExpectedSha256) {
    $ExpectedSha256 = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "Некорректный -ExpectedSha256 / LIGAMENT_EXPECTED_SHA256: ожидается 64 hex-символа, получено: '$ExpectedSha256'"
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[!] Требуются права Администратора. Запуск от имени Администратора..." -ForegroundColor Yellow
    if ($PSCommandPath) {
        $argsList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($Component -ne "Interactive") { $argsList += " -Component $Component" }
        if ($ServerURL) { $argsList += " -ServerURL `"$ServerURL`"" }
        if ($Version -ne "latest") { $argsList += " -Version `"$Version`"" }
        if ($ExpectedSha256) { $argsList += " -ExpectedSha256 `"$ExpectedSha256`"" }
        if ($Silent) { $argsList += " -Silent" }
        if ($AllowUnsigned) { $argsList += " -AllowUnsigned" }
    } else {
        $cmd = "irm 'https://raw.githubusercontent.com/aligorov/ligament-apps/main/scripts/install-latest.ps1?v=$(Get-Random)' | iex"
        if ($ExpectedSha256) {
            $cmd = "`$env:LIGAMENT_EXPECTED_SHA256 = '$ExpectedSha256'; $cmd"
        }
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
    Write-Host "  [1] Полная установка: приложение + RDP Credential Provider + служба (один MSI; 2FA входа по умолчанию выключена)" -ForegroundColor White
    Write-Host "  [2] Выход" -ForegroundColor Gray
    Write-Host ""
    $choice = (Read-Host "Введите номер (1-2) [по умолчанию 1]").Trim()
    if ($choice -eq "2") {
        Write-Host "Отменено пользователем." -ForegroundColor Yellow
        exit 0
    }
    $Component = "All"
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
    # ЕДИНЫЙ ПОЛНЫЙ MSI: приложение + RDP Credential Provider + служба
    # -------------------------------------------------------------------------
    $MsiFileName = "Ligament-2FA-Windows-x64.msi"
        $MsiUrl = "$downloadBaseUrl/$MsiFileName"
        $LocalMsi = Join-Path $TempDir $MsiFileName

        Write-Host "`nЗагрузка инсталлятора $MsiFileName..." -ForegroundColor Yellow
        Write-Host "URL: $MsiUrl" -ForegroundColor Gray
        Invoke-WebRequest -Uri $MsiUrl -OutFile $LocalMsi -UseBasicParsing
        Write-Host " [OK] Загружено: $LocalMsi ($([math]::Round((Get-Item $LocalMsi).Length / 1MB, 2)) МБ)" -ForegroundColor Green

        # A-5 (аудит 2026-10-12): пиннинг целостности артефакта хэшем.
        # Сверяем ДО любых действий с системой (подпись, msiexec) —
        # несовпадение означает подмену/другую сборку: жёсткий отказ.
        if ($ExpectedSha256) {
            Write-Host "`nПроверка SHA256 артефакта..." -ForegroundColor Yellow
            $actual = (Get-FileHash -FilePath $LocalMsi -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne $ExpectedSha256) {
                throw "Отказ: SHA256 артефакта НЕ СОВПАДАЕТ.`n  ожидался: $ExpectedSha256`n  получен:  $actual`nФайл подменён либо это другая сборка. Уточните хэш в примечаниях к релизу $tag."
            }
            Write-Host " [OK] SHA256 совпадает: $actual" -ForegroundColor Green
        }

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

        # ЕДИНЫЙ полный пакет: приложение + CP + служба Ligament2FAService
        # ставятся одним MSI без свойств выбора. 2FA входа (RDP/консоль)
        # остаётся ВЫКЛЮЧЕНОЙ — включение только явной политикой.

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


    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host "                УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                      " -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host " Версия:             $tag" -ForegroundColor White
    Write-Host " Режим по умолчанию: Push Number Matching (число в приложении Ligament)" -ForegroundColor White
    Write-Host " Служба: Ligament2FAService (сторож, активна при AllowExit=0) — установлена и запущена" -ForegroundColor White
    Write-Host " RDP Credential Provider: установлен; 2FA для RDP/консоли ВЫКЛЮЧЕНА (по умолчанию)" -ForegroundColor White
    Write-Host "   Включить 2FA для RDP:     reg add `"$RegPolicyPath`" /v RDP2FAEnabled /t REG_DWORD /d 1 /f" -ForegroundColor Gray
    Write-Host "   Включить 2FA для консоли: reg add `"$RegPolicyPath`" /v Console2FAEnabled /t REG_DWORD /d 1 /f" -ForegroundColor Gray
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
