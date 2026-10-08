# build_msi.ps1 — Автоматическая сборка Windows MSI-пакета и RDP Credential Provider для Ligament 2FA
# Запуск в PowerShell:
#   .\scripts\build_msi.ps1
#
# Требования на Windows:
#   1. Flutter SDK: flutter doctor
#   2. CMake & MSVC (C++ Build Tools)
#   3. WiX Toolset: winget install WiX.Toolset (или https://wixtoolset.org)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ClientDir = Split-Path -Parent $ScriptDir
$BuildReleaseDir = "$ClientDir\build\windows\x64\runner\Release"
$DistDir = "$ClientDir\dist"
$OutputMsi = "$DistDir\Ligament-2FA-Windows-x64.msi"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Сборка Windows MSI пакета и RDP 2FA: Ligament 2FA" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 1. Сборка релизной версии Flutter для Windows
Set-Location $ClientDir
$env:CL = "$env:CL /D_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
Write-Host "`n[1/5] Компиляция Flutter Windows Release..." -ForegroundColor Yellow
flutter build windows --release

if (-not (Test-Path "$BuildReleaseDir\ligament_authenticator.exe")) {
    Write-Error "Ошибка: Бинарный файл $BuildReleaseDir\ligament_authenticator.exe не найден!"
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

# 3b. Сборка Ligament Endpoint Service (RDP Access Gateway; входит в MSI
#     как endpoint_service.exe — компонент EndpointServiceComponent)
$EpDir = "$ClientDir\windows\endpoint_service"
if (Test-Path "$EpDir\CMakeLists.txt") {
    Write-Host "`n[2c/5] Компиляция Ligament Endpoint Service (ligament_endpoint.exe)..." -ForegroundColor Yellow
    cmake -B "$EpDir\build" -S "$EpDir" -A x64
    cmake --build "$EpDir\build" --config Release
    if (Test-Path "$EpDir\build\Release\ligament_endpoint.exe") {
        Write-Host " Успешно скомпилирована служба: ligament_endpoint.exe" -ForegroundColor Green
    } else {
        Write-Error "Ошибка: ligament_endpoint.exe не скомпилировалась!"
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
Write-Host "`n[4/5] Анализ и сборка компонентов приложения (WiX Heat)..." -ForegroundColor Yellow
$TempDir = [System.IO.Path]::GetTempPath() + "LigamentWix_" + [System.Guid]::NewGuid().ToString("N")
New-Item -ItemType Directory -Path $TempDir | Out-Null

try {
    # Генерируем фрагмент с файлами релиза Flutter
    & $heatCmd dir "$BuildReleaseDir" -cg AppFiles -dr INSTALLFOLDER -gg -scom -sreg -srd -var "var.SourceDir" -out "$TempDir\Files.wxs"

    # Версия MSI = version из pubspec.yaml (1.0.10+21 -> 1.0.10.21; 4-е поле
    # MSI информационное, в сравнениях апгрейдов участвуют первые три).
    # Растущая версия + AllowSameVersionUpgrades гарантируют REPLACE старой
    # установки вместо параллельной записи.
    $pubspec = Get-Content "$ClientDir\pubspec.yaml" -Raw
    if ($pubspec -match '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?') {
        $build4 = if ($Matches[4]) { $Matches[4] } else { "0" }
        $msiVersion = "{0}.{1}.{2}.{3}" -f $Matches[1], $Matches[2], $Matches[3], $build4
    } else {
        Write-Error "Не удалось извлечь version из pubspec.yaml — версия MSI обязательна."
        exit 1
    }
    Write-Host " Версия MSI: $msiVersion" -ForegroundColor Cyan

    Write-Host "`n[5/5] Компиляция WiX XML (Candle) и линковка MSI (Light)..." -ForegroundColor Yellow
    & $candleCmd -arch x64 -dSourceDir="$BuildReleaseDir" -dProductVersion="$msiVersion" "$ClientDir\windows\installer\Product.wxs" "$TempDir\Files.wxs" -out "$TempDir\"
    & $lightCmd -sval -ext WixUIExtension "$TempDir\Product.wixobj" "$TempDir\Files.wixobj" -o "$OutputMsi"

    Write-Host "`n========================================================" -ForegroundColor Green
    Write-Host " УСПЕШНО СОБРАН WINDOWS MSI ДИСТРИБУТИВ (APP + RDP 2FA):" -ForegroundColor Green
    Write-Host " Файл: $OutputMsi" -ForegroundColor White
    Write-Host " Размер: $((Get-Item $OutputMsi).Length / 1MB) МБ" -ForegroundColor White
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host "Тихая установка для Active Directory GPO / SCCM / Intune:" -ForegroundColor Cyan
    Write-Host "  msiexec /i Ligament-2FA-Windows-x64.msi /qn              (только приложение; RDP-провайдер выключен)" -ForegroundColor White
    Write-Host "  msiexec /i Ligament-2FA-Windows-x64.msi /qn INSTALLRDP=1  (приложение + RDP Credential Provider)" -ForegroundColor White
} finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
