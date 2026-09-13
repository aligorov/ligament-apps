#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# build_linux.sh — Сборка Ligament Authenticator под Linux (.deb, .rpm, .tar.gz)
# Совместимо с Astra Linux SE/CE, РЕД ОС 7.3/8, Альт Линукс, Debian, Ubuntu, RHEL
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_BUNDLE_DIR="${ROOT_DIR}/build/linux/x64/release/bundle"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGING_DIR="${ROOT_DIR}/linux/packaging"
APP_ICON="${ROOT_DIR}/assets/icons/app_icon.png"

echo "=================================================================="
echo " 🐧 Сборка дистрибутивов Linux: Ligament Authenticator"
echo "=================================================================="

# 1. Извлечение версии приложения из pubspec.yaml
VERSION_RAW=$(grep '^version:' "${ROOT_DIR}/pubspec.yaml" | awk '{print $2}')
APP_VERSION=$(echo "${VERSION_RAW}" | cut -d'+' -f1)
BUILD_NUMBER=$(echo "${VERSION_RAW}" | cut -d'+' -f2)

if [[ -z "${APP_VERSION}" ]]; then
    APP_VERSION="1.0.9"
fi

echo "--> Версия приложения: ${APP_VERSION} (билд: ${BUILD_NUMBER})"

# 2. Проверка и запуск сборки Flutter Linux Release
mkdir -p "${DIST_DIR}"

if [[ ! -f "${BUILD_BUNDLE_DIR}/ligament_authenticator" ]]; then
    echo "--> Бандл не найден. Запуск сборки flutter build linux --release..."
    if command -v flutter >/dev/null 2>&1; then
        (cd "${ROOT_DIR}" && flutter build linux --release)
    else
        echo "ОШИБКА: Flutter SDK не найден в PATH."
        exit 1
    fi
fi

if [[ ! -f "${BUILD_BUNDLE_DIR}/ligament_authenticator" ]]; then
    echo "ОШИБКА: Исполняемый файл ${BUILD_BUNDLE_DIR}/ligament_authenticator не найден после сборки."
    exit 1
fi

echo "--> Скомпилированный Linux бандл найден: ${BUILD_BUNDLE_DIR}"

# 3. Сборка переносимого архива .tar.gz
echo "------------------------------------------------------------------"
echo "📦 1/3. Создание переносимого архива .tar.gz (Universal Linux)"
echo "------------------------------------------------------------------"

TARBALL_STAGING="$(mktemp -d -t ligament_tarball_XXXXXX)"
trap 'rm -rf "${TARBALL_STAGING}"' EXIT

mkdir -p "${TARBALL_STAGING}/ligament-authenticator/bundle"
mkdir -p "${TARBALL_STAGING}/ligament-authenticator/packaging"
mkdir -p "${TARBALL_STAGING}/ligament-authenticator/icons"

cp -rf "${BUILD_BUNDLE_DIR}/"* "${TARBALL_STAGING}/ligament-authenticator/bundle/"
cp -f "${PACKAGING_DIR}/ligament-authenticator.desktop" "${TARBALL_STAGING}/ligament-authenticator/packaging/"
cp -f "${APP_ICON}" "${TARBALL_STAGING}/ligament-authenticator/icons/"
cp -f "${PACKAGING_DIR}/install.sh" "${TARBALL_STAGING}/ligament-authenticator/install.sh"
chmod +x "${TARBALL_STAGING}/ligament-authenticator/install.sh"

cat << 'EOF' > "${TARBALL_STAGING}/ligament-authenticator/README.txt"
Ligament Authenticator for Linux
================================

Установка:
  1. Для установки в систему (/opt и меню приложений):
     sudo ./install.sh

  2. Для установки только для текущего пользователя (~/.local):
     ./install.sh

  3. Запуск без установки:
     ./bundle/ligament_authenticator

Удаление:
  sudo ./install.sh --uninstall
  (или ./install.sh --uninstall при пользовательской установке)
EOF

TARBALL_FILE="${DIST_DIR}/Ligament-2FA-Linux-x86_64.tar.gz"
(cd "${TARBALL_STAGING}" && tar -czf "${TARBALL_FILE}" ligament-authenticator)
echo "✅ Создан архив: ${TARBALL_FILE}"

# 4. Сборка пакета .deb (Astra Linux SE/CE, Debian, Ubuntu, Linux Mint)
echo "------------------------------------------------------------------"
echo "📦 2/3. Создание пакета .deb (Astra Linux, Debian, Ubuntu)"
echo "------------------------------------------------------------------"

if command -v dpkg-deb >/dev/null 2>&1; then
    DEB_STAGING="$(mktemp -d -t ligament_deb_XXXXXX)"
    
    mkdir -p "${DEB_STAGING}/DEBIAN"
    mkdir -p "${DEB_STAGING}/opt/ligament-authenticator"
    mkdir -p "${DEB_STAGING}/usr/bin"
    mkdir -p "${DEB_STAGING}/usr/share/applications"
    mkdir -p "${DEB_STAGING}/usr/share/icons/hicolor/128x128/apps"
    mkdir -p "${DEB_STAGING}/usr/share/pixmaps"

    # Подготовка DEBIAN/control
    sed "s/@VERSION@/${APP_VERSION}/g" "${PACKAGING_DIR}/control" > "${DEB_STAGING}/DEBIAN/control"
    
    # Скрипты postinst и postrm
    cp -f "${PACKAGING_DIR}/postinst" "${DEB_STAGING}/DEBIAN/postinst"
    cp -f "${PACKAGING_DIR}/postrm" "${DEB_STAGING}/DEBIAN/postrm"
    chmod 755 "${DEB_STAGING}/DEBIAN/postinst" "${DEB_STAGING}/DEBIAN/postrm"

    # Копирование бандла
    cp -rf "${BUILD_BUNDLE_DIR}/"* "${DEB_STAGING}/opt/ligament-authenticator/"
    chmod 755 "${DEB_STAGING}/opt/ligament-authenticator/ligament_authenticator"

    # Симлинк в /usr/bin
    ln -sf /opt/ligament-authenticator/ligament_authenticator "${DEB_STAGING}/usr/bin/ligament-authenticator"

    # Ярлык и иконки
    cp -f "${PACKAGING_DIR}/ligament-authenticator.desktop" "${DEB_STAGING}/usr/share/applications/"
    chmod 644 "${DEB_STAGING}/usr/share/applications/ligament-authenticator.desktop"

    cp -f "${APP_ICON}" "${DEB_STAGING}/usr/share/icons/hicolor/128x128/apps/ligament-authenticator.png"
    cp -f "${APP_ICON}" "${DEB_STAGING}/usr/share/pixmaps/ligament-authenticator.png"
    chmod 644 "${DEB_STAGING}/usr/share/icons/hicolor/128x128/apps/ligament-authenticator.png"
    chmod 644 "${DEB_STAGING}/usr/share/pixmaps/ligament-authenticator.png"

    DEB_OUT_NAME="ligament-authenticator_${APP_VERSION}_amd64.deb"
    DEB_FINAL_PATH="${DIST_DIR}/${DEB_OUT_NAME}"
    DEB_ALIAS_PATH="${DIST_DIR}/Ligament-2FA-Linux-amd64.deb"

    dpkg-deb --build --root-owner-group "${DEB_STAGING}" "${DEB_FINAL_PATH}"
    cp -f "${DEB_FINAL_PATH}" "${DEB_ALIAS_PATH}"

    rm -rf "${DEB_STAGING}"
    echo "✅ Создан DEB пакет: ${DEB_FINAL_PATH}"
    echo "✅ Создан DEB алиас:  ${DEB_ALIAS_PATH}"
else
    echo "⚠️ Внимание: утилита dpkg-deb не найдена, сборка .deb пропущена."
fi

# 5. Сборка пакета .rpm (РЕД ОС 7.3/8, Альт Линукс, Fedora, RHEL)
echo "------------------------------------------------------------------"
echo "📦 3/3. Создание пакета .rpm (РЕД ОС, Альт Линукс, Fedora, RHEL)"
echo "------------------------------------------------------------------"

if command -v rpmbuild >/dev/null 2>&1; then
    RPM_TOPDIR="$(mktemp -d -t ligament_rpm_XXXXXX)"

    mkdir -p "${RPM_TOPDIR}/BUILD"
    mkdir -p "${RPM_TOPDIR}/RPMS"
    mkdir -p "${RPM_TOPDIR}/SOURCES/bundle"
    mkdir -p "${RPM_TOPDIR}/SOURCES/packaging"
    mkdir -p "${RPM_TOPDIR}/SOURCES/icons"
    mkdir -p "${RPM_TOPDIR}/SPECS"
    mkdir -p "${RPM_TOPDIR}/SRPMS"

    # Копирование исходных файлов для rpmbuild
    cp -rf "${BUILD_BUNDLE_DIR}/"* "${RPM_TOPDIR}/SOURCES/bundle/"
    cp -f "${PACKAGING_DIR}/ligament-authenticator.desktop" "${RPM_TOPDIR}/SOURCES/packaging/"
    cp -f "${APP_ICON}" "${RPM_TOPDIR}/SOURCES/icons/app_icon.png"
    cp -f "${PACKAGING_DIR}/ligament-authenticator.spec" "${RPM_TOPDIR}/SPECS/"

    rpmbuild --define "_topdir ${RPM_TOPDIR}" \
             --define "version ${APP_VERSION}" \
             -bb "${RPM_TOPDIR}/SPECS/ligament-authenticator.spec"

    RPM_RESULT=$(find "${RPM_TOPDIR}/RPMS" -name "*.rpm" | head -n 1)
    if [[ -n "${RPM_RESULT}" && -f "${RPM_RESULT}" ]]; then
        RPM_BASENAME="$(basename "${RPM_RESULT}")"
        cp -f "${RPM_RESULT}" "${DIST_DIR}/${RPM_BASENAME}"
        cp -f "${RPM_RESULT}" "${DIST_DIR}/Ligament-2FA-Linux-x86_64.rpm"
        echo "✅ Создан RPM пакет: ${DIST_DIR}/${RPM_BASENAME}"
        echo "✅ Создан RPM алиас:  ${DIST_DIR}/Ligament-2FA-Linux-x86_64.rpm"
    else
        echo "ОШИБКА: RPM файл не найден после работы rpmbuild."
    fi

    rm -rf "${RPM_TOPDIR}"
else
    echo "⚠️ Внимание: утилита rpmbuild не найдена, сборка .rpm пропущена."
fi

# 6. Контрольные суммы SHA256
echo "------------------------------------------------------------------"
echo "🔒 Вычисление контрольных сумм SHA256"
echo "------------------------------------------------------------------"
(
    cd "${DIST_DIR}"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum Ligament-2FA-Linux* *.deb *.rpm > SHA256SUMS-linux.txt 2>/dev/null || true
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 Ligament-2FA-Linux* *.deb *.rpm > SHA256SUMS-linux.txt 2>/dev/null || true
    fi
)

echo "=================================================================="
echo "🎉 Сборка пакетов Linux успешно завершена!"
echo "Содержимое каталога dist/:"
ls -la "${DIST_DIR}"
echo "=================================================================="
