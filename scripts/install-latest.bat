@echo off
setlocal EnableDelayedExpansion
title Ligament 2FA - Updater & Installer

:: Check for Administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ========================================================
    echo Запрос прав Администратора...
    echo ========================================================
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Run install-latest.ps1 if present next to bat, otherwise download on the fly
set "PS_SCRIPT=%~dp0install-latest.ps1"
if not exist "%PS_SCRIPT%" (
	echo Скачивание скрипта установки...
	powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile('https://raw.githubusercontent.com/aligorov/ligament-apps/main/scripts/install-latest.ps1', '%TEMP%\install-latest.ps1')"
	set "PS_SCRIPT=%TEMP%\install-latest.ps1"
)

:: A-5 (аудит 2026-10-12): пиннинг целостности MSI хэшем. Задайте до запуска
::   set LIGAMENT_EXPECTED_SHA256=<hex-64>
:: значение уйдёт в install-latest.ps1 параметром -ExpectedSha256 (хэш
:: скачанного артефакта сверяется ДО запуска установки).
set "PS_HASH_ARGS="
if defined LIGAMENT_EXPECTED_SHA256 (
	set "PS_HASH_ARGS=-ExpectedSha256 "%LIGAMENT_EXPECTED_SHA256%""
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %* !PS_HASH_ARGS!

if exist "%TEMP%\install-latest.ps1" (
    del /f /q "%TEMP%\install-latest.ps1" >nul 2>&1
)
