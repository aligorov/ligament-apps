#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Ligament Authenticator — Установщик для Linux (Astra, РЕД ОС, Альт, Ubuntu и др.)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Ligament Authenticator"

# Проверка на удаление
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "=== Удаление ${APP_NAME} ==="
    if [[ $EUID -eq 0 ]]; then
        rm -rf /opt/ligament-authenticator
        rm -f /usr/lib/systemd/user/ligament-link-agent.service
        rm -f /usr/bin/ligament-authenticator
        rm -f /usr/share/applications/ligament-authenticator.desktop
        rm -f /usr/share/icons/hicolor/128x128/apps/ligament-authenticator.png
        rm -f /usr/share/pixmaps/ligament-authenticator.png
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
        command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
    else
        systemctl --user disable --now ligament-link-agent.service >/dev/null 2>&1 || true
        rm -f "${HOME}/.config/systemd/user/ligament-link-agent.service"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        rm -rf "${HOME}/.local/opt/ligament-authenticator"
        rm -f "${HOME}/.local/bin/ligament-authenticator"
        rm -f "${HOME}/.local/share/applications/ligament-authenticator.desktop"
        rm -f "${HOME}/.local/share/icons/hicolor/128x128/apps/ligament-authenticator.png"
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "${HOME}/.local/share/applications" || true
    fi
    echo "--> ${APP_NAME} успешно удален."
    exit 0
fi

if [[ "${1:-}" == "--enable-link-agent" ]]; then
    if [[ $EUID -eq 0 ]]; then
        echo "Run this command as the desktop user, without sudo." >&2
        exit 1
    fi
    TARGET_DIR="${HOME}/.local/opt/ligament-authenticator"
    UNIT_DIR="${HOME}/.config/systemd/user"
    UNIT_PATH="${UNIT_DIR}/ligament-link-agent.service"
    if [[ ! -x "${TARGET_DIR}/link-agent" || ! -f "${SCRIPT_DIR}/packaging/ligament-link-agent.service" ]]; then
        echo "Install the Linux package/bundle first; Link agent files are missing." >&2
        exit 1
    fi
    mkdir -p "${UNIT_DIR}"
    sed "s|/opt/ligament-authenticator/link-agent|${TARGET_DIR}/link-agent|g" \
        "${SCRIPT_DIR}/packaging/ligament-link-agent.service" > "${UNIT_PATH}"
    chmod 600 "${UNIT_PATH}"
    systemctl --user daemon-reload
    systemctl --user enable --now ligament-link-agent.service
    echo "Ligament Link agent enabled for the current user."
    exit 0
fi

echo "=================================================================="
echo " Установка ${APP_NAME} для Linux"
echo "=================================================================="

if [[ $EUID -eq 0 ]]; then
    # Системная установка (root / sudo)
    TARGET_DIR="/opt/ligament-authenticator"
    BIN_DIR="/usr/bin"
    DESKTOP_DIR="/usr/share/applications"
    ICON_DIR="/usr/share/icons/hicolor/128x128/apps"
    PIXMAP_DIR="/usr/share/pixmaps"
    EXEC_PATH="${TARGET_DIR}/ligament_authenticator"
    if [[ -f "${SCRIPT_DIR}/packaging/ligament-link-agent.service" ]]; then
        mkdir -p /usr/lib/systemd/user
        cp -f "${SCRIPT_DIR}/packaging/ligament-link-agent.service" /usr/lib/systemd/user/ligament-link-agent.service
        chmod 644 /usr/lib/systemd/user/ligament-link-agent.service
        command -v systemctl >/dev/null 2>&1 && systemctl --global daemon-reload || true
    fi
else
    # Пользовательская установка (без root)
    TARGET_DIR="${HOME}/.local/opt/ligament-authenticator"
    BIN_DIR="${HOME}/.local/bin"
    DESKTOP_DIR="${HOME}/.local/share/applications"
    ICON_DIR="${HOME}/.local/share/icons/hicolor/128x128/apps"
    PIXMAP_DIR=""
    EXEC_PATH="${TARGET_DIR}/ligament_authenticator"
fi

echo "--> Установка файлов в ${TARGET_DIR}..."
mkdir -p "${TARGET_DIR}" "${BIN_DIR}" "${DESKTOP_DIR}" "${ICON_DIR}"

# Копируем бандл
cp -rf "${SCRIPT_DIR}/bundle/"* "${TARGET_DIR}/"
chmod +x "${TARGET_DIR}/ligament_authenticator"
if [[ -f "${TARGET_DIR}/link-agent" ]]; then chmod 755 "${TARGET_DIR}/link-agent"; fi

# Создаем символическую ссылку на бинарник
ln -sf "${EXEC_PATH}" "${BIN_DIR}/ligament-authenticator"

# Устанавливаем иконку
if [[ -f "${SCRIPT_DIR}/icons/app_icon.png" ]]; then
    cp -f "${SCRIPT_DIR}/icons/app_icon.png" "${ICON_DIR}/ligament-authenticator.png"
    if [[ -n "${PIXMAP_DIR}" ]]; then
        mkdir -p "${PIXMAP_DIR}"
        cp -f "${SCRIPT_DIR}/icons/app_icon.png" "${PIXMAP_DIR}/ligament-authenticator.png"
    fi
fi

# Устанавливаем и настраиваем .desktop ярлык
if [[ -f "${SCRIPT_DIR}/packaging/ligament-authenticator.desktop" ]]; then
    sed "s|Exec=/opt/ligament-authenticator/ligament_authenticator|Exec=${EXEC_PATH}|g" \
        "${SCRIPT_DIR}/packaging/ligament-authenticator.desktop" > "${DESKTOP_DIR}/ligament-authenticator.desktop"
    chmod 644 "${DESKTOP_DIR}/ligament-authenticator.desktop"
fi

# Обновляем системные кэши
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q "${DESKTOP_DIR}" || true
fi
if [[ $EUID -eq 0 ]] && command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

echo "=================================================================="
echo "--> Установка успешно завершена!"
echo "--> Запуск: ${BIN_DIR}/ligament-authenticator"
echo "--> Или найдите 'Ligament Authenticator' в меню приложений."
if [[ $EUID -ne 0 && ":$PATH:" != *":${HOME}/.local/bin:"* ]]; then
    echo "--> Подсказка: добавьте ~/.local/bin в ваш PATH:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
echo "=================================================================="
