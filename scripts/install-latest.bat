@echo off
setlocal
set "PS_SCRIPT=%~dp0install-latest.ps1"
if not exist "%PS_SCRIPT%" (
    echo Trusted local install-latest.ps1 is required.
    exit /b 1
)
:: Supply -ExpectedSha256 and -ExpectedPublisherThumbprint from a trusted channel.
:: PowerShell handles elevation using this same local script and validated arguments.
powershell.exe -NoProfile -File "%PS_SCRIPT%" %*
exit /b %errorlevel%
