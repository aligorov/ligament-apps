# build_msi.ps1 — Автоматическая сборка Windows MSI-пакета и RDP Credential Provider для Ligament 2FA
# Запуск в PowerShell:
#   .\scripts\build_msi.ps1
#
# Требования на Windows:
#   1. Flutter SDK: flutter doctor
#   2. CMake & MSVC (C++ Build Tools)
#   3. WiX Toolset: winget install WiX.Toolset (или https://wixtoolset.org)

param(
    [switch]$EndpointOnly
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ClientDir = Split-Path -Parent $ScriptDir
$BuildReleaseDir = "$ClientDir\build\windows\x64\runner\Release"
$DistDir = "$ClientDir\dist"
$OutputMsi = "$DistDir\Ligament-2FA-Windows-x64.msi"
$OutputEndpointMsi = "$DistDir\Ligament-Endpoint-Windows-x64.msi"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Сборка Windows MSI пакетов: Ligament 2FA & Endpoint Agent" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 1. Сборка релизной версии Flutter для Windows (пропускается при -EndpointOnly)
Set-Location $ClientDir
if (-not $EndpointOnly) {
    $env:CL = "$env:CL /D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
    Write-Host "`n[1/5] Компиляция Flutter Windows Release (с обфускацией AOT)..." -ForegroundColor Yellow
    flutter build windows --release --no-tree-shake-icons --obfuscate --split-debug-info=build\windows_symbols

    if (-not (Test-Path "$BuildReleaseDir\ligament_authenticator.exe")) {
        Write-Error "Ошибка: Бинарный файл $BuildReleaseDir\ligament_authenticator.exe не найден!"
    }
} else {
    Write-Host "`n[1/5] Пропуск сборки Flutter GUI (режим -EndpointOnly)..." -ForegroundColor Gray
}

# 2. Сборка Windows Credential Provider (RDP 2FA C++ DLL)
$CpDir = "$ClientDir\windows\credential_provider"
if (Test-Path "$CpDir\CMakeLists.txt") {
    Write-Host "`n[2/5] Компиляция Windows Credential Provider (RDP 2FA C++ DLL)..." -ForegroundColor Yellow
    cmake -B "$CpDir\build" -S "$CpDir" -A x64
    cmake --build "$CpDir\build" --config Release
    
    if (Test-Path "$CpDir\build\Release\LigamentCredentialProvider.dll") {
        Write-Host " Успешно скомпилирована библиотека: LigamentCredentialProvider.dll" -ForegroundColor Green
    } else {
        Write-Error "Ошибка: LigamentCredentialProvider.dll не скомпилировалась!"
    }
}

# 3. Сборка службы Ligament 2FA Service (watchdog; входит в MSI)
$SvcDir = "$ClientDir\windows\service"
if (Test-Path "$SvcDir\CMakeLists.txt") {
    Write-Host "`n[2b/5] Компиляция Ligament 2FA Service (ligament_service.exe)..." -ForegroundColor Yellow
    cmake -B "$SvcDir\build" -S "$SvcDir" -A x64
    cmake --build "$SvcDir\build" --config Release
    if (Test-Path "$SvcDir\build\Release\ligament_service.exe") {
        Write-Host " Успешно скомпилирована служба: ligament_service.exe" -ForegroundColor Green
    } else {
        Write-Error "Ошибка: ligament_service.exe не скомпилировалась!"
    }
}

# 3b. Сборка Windows Ligament Link Agent (LocalSystem host service; входит в MSI).
$LinkAgentDir = "$ClientDir\windows\link_agent"
$LinkAgentBuildDir = "$LinkAgentDir\build\Release"
if (Test-Path "$LinkAgentDir\go.mod") {
    Write-Host "`n[2c/5] Сборка Ligament Link Agent (Go Windows service)..." -ForegroundColor Yellow
    $linkAgentVersion = "dev"
    $linkAgentPubspec = Get-Content "$ClientDir\pubspec.yaml" -Raw
    if ($linkAgentPubspec -match '(?m)^version:\s*(\d+\.\d+\.\d+(?:\+\d+)?)') {
        $linkAgentVersion = $Matches[1]
    }
    if (-not (Get-Command "go.exe" -ErrorAction SilentlyContinue)) {
        Write-Error "Go 1.23+ is required to build windows/link_agent."
    }
    New-Item -ItemType Directory -Force -Path $LinkAgentBuildDir | Out-Null
    Push-Location $LinkAgentDir
    try {
        go test ./...
        if ($LASTEXITCODE -ne 0) { throw 'Link agent Go tests failed' }
        go vet ./...
        if ($LASTEXITCODE -ne 0) { throw 'Link agent go vet failed' }
        go build -trimpath -ldflags "-s -w -buildid= -X main.agentVersion=$linkAgentVersion" -o "$LinkAgentBuildDir\ligament_link_agent.exe" .\cmd\link-agent
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$LinkAgentBuildDir\ligament_link_agent.exe")) {
            throw 'Link agent Windows service build failed'
        }
    } finally {
        Pop-Location
    }
}

# 4. Каталог дистрибутивов (отдельный RDP-ZIP больше не создаётся:
#    единый MSI = приложение + CP + служба)
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir | Out-Null
}


# 4. Проверка наличия WiX Toolset
$wixInstalled = $false
$heatCmd = ""
$candleCmd = ""
$lightCmd = ""

if (Get-Command "heat.exe" -ErrorAction SilentlyContinue) {
    $heatCmd = "heat.exe"
    $candleCmd = "candle.exe"
    $lightCmd = "light.exe"
    $wixInstalled = $true
} elseif (Test-Path "C:\Program Files (x86)\WiX Toolset v3.11\bin\candle.exe") {
    $wixBin = "C:\Program Files (x86)\WiX Toolset v3.11\bin"
    $heatCmd = "$wixBin\heat.exe"
    $candleCmd = "$wixBin\candle.exe"
    $lightCmd = "$wixBin\light.exe"
    $wixInstalled = $true
} elseif (Test-Path "C:\Program Files (x86)\WiX Toolset v3.14\bin\candle.exe") {
    $wixBin = "C:\Program Files (x86)\WiX Toolset v3.14\bin"
    $heatCmd = "$wixBin\heat.exe"
    $candleCmd = "$wixBin\candle.exe"
    $lightCmd = "$wixBin\light.exe"
    $wixInstalled = $true
}

if (-not $wixInstalled) {
    Write-Host "`n[!] WiX Toolset не найден в системе." -ForegroundColor Red
    Write-Host "Для автоматической сборки MSI установите WiX через winget:" -ForegroundColor Yellow
    Write-Host "  winget install WiX.Toolset" -ForegroundColor Green
    Write-Host "Или скачайте инсталлятор: https://github.com/wixtoolset/wix3/releases" -ForegroundColor Yellow
    Write-Host "`nФайлы скомпилированного приложения готовы в папке:" -ForegroundColor Cyan
    Write-Host "  $BuildReleaseDir" -ForegroundColor White
    exit 1
}

# 5. Упаковка через WiX Toolset
$TempDir = [System.IO.Path]::GetTempPath() + "LigamentWix_" + [System.Guid]::NewGuid().ToString("N")
New-Item -ItemType Directory -Path $TempDir | Out-Null

try {
    # Версия MSI = version из pubspec.yaml (1.0.10+21 -> 1.0.10.21)
    $pubspec = Get-Content "$ClientDir\pubspec.yaml" -Raw
    if ($pubspec -match '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?') {
        $build4 = if ($Matches[4]) { $Matches[4] } else { "0" }
        $msiVersion = "{0}.{1}.{2}.{3}" -f $Matches[1], $Matches[2], $Matches[3], $build4
    } else {
        Write-Error "Не удалось извлечь version из pubspec.yaml — версия MSI обязательна."
        exit 1
    }
    Write-Host " Версия MSI: $msiVersion" -ForegroundColor Cyan

    if (-not $EndpointOnly) {
        Write-Host "`n[4/5] Анализ и сборка компонентов приложения (WiX Heat)..." -ForegroundColor Yellow
        # Генерируем фрагмент с файлами релиза Flutter
        & $heatCmd dir "$BuildReleaseDir" -cg AppFiles -dr INSTALLFOLDER -gg -scom -sreg -srd -var "var.SourceDir" -out "$TempDir\Files.wxs"

        Write-Host "`n[5/5] Компиляция WiX XML (Candle) и линковка полного MSI (Light)..." -ForegroundColor Yellow
        & $candleCmd -arch x64 -ext WixUtilExtension -dSourceDir="$BuildReleaseDir" -dProductVersion="$msiVersion" "$ClientDir\windows\installer\Product.wxs" "$TempDir\Files.wxs" -out "$TempDir\"
        & $lightCmd -sval -ext WixUIExtension -ext WixUtilExtension "$TempDir\Product.wixobj" "$TempDir\Files.wixobj" -o "$OutputMsi"

        Write-Host "`n========================================================" -ForegroundColor Green
        Write-Host " УСПЕШНО СОБРАН WINDOWS MSI ДИСТРИБУТИВ (APP + RDP 2FA):" -ForegroundColor Green
        Write-Host " Файл: $OutputMsi" -ForegroundColor White
        Write-Host " Размер: $((Get-Item $OutputMsi).Length / 1MB) МБ" -ForegroundColor White
        Write-Host "========================================================" -ForegroundColor Green
    }

    # Сборка легковесного Ligament Endpoint Agent MSI
    Write-Host "`n[5b/5] Компиляция Ligament Endpoint Agent MSI (Headless / GPO)..." -ForegroundColor Yellow
    & $candleCmd -arch x64 -ext WixUtilExtension -dProductVersion="$msiVersion" "$ClientDir\windows\installer\EndpointProduct.wxs" -out "$TempDir\"
    & $lightCmd -sval -ext WixUIExtension -ext WixUtilExtension "$TempDir\EndpointProduct.wixobj" -o "$OutputEndpointMsi"

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " УСПЕШНО СОБРАН ЛЕГКОВЕСНЫЙ ENDPOINT AGENT MSI:" -ForegroundColor Green
    Write-Host " Файл: $OutputEndpointMsi" -ForegroundColor White
    Write-Host " Размер: $((Get-Item $OutputEndpointMsi).Length / 1MB) МБ" -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host "Тихая установка для Active Directory GPO / SCCM / Intune:" -ForegroundColor Cyan
    Write-Host "  msiexec /i Ligament-Endpoint-Windows-x64.msi SERVER_URL=https://2fa.corp ENROLL_TOKEN=xxx CONSOLE_2FA=1 RDP_2FA=1 /qn" -ForegroundColor White
} finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
