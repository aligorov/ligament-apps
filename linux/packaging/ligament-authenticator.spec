Name:           ligament-authenticator
Version:        %{version}
Release:        1%{?dist}
Summary:        Ligament Authenticator — Enterprise 2FA & MFA Client
License:        Proprietary
URL:            https://ligam.org
BuildArch:      x86_64
AutoReqProv:    no

Requires:       gtk3 >= 3.22
Requires:       glib2 >= 2.58
Requires:       libsecret >= 0.18

%description
Ligament Authenticator is an enterprise cross-platform Two-Factor Authentication client.
Supports push verification, number matching, SOS remote assistance, TOTP, and
security posture telemetry.
Compatible with RED OS (РЕД ОС 7.3/8), Alt Linux (Альт Линукс), Fedora, and RHEL.

%prep
# No prep needed

%build
# Pre-built binary bundle

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/opt/ligament-authenticator
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/128x128/apps
mkdir -p %{buildroot}/usr/share/pixmaps

cp -r %{_sourcedir}/bundle/* %{buildroot}/opt/ligament-authenticator/
ln -sf /opt/ligament-authenticator/ligament_authenticator %{buildroot}/usr/bin/ligament-authenticator
install -m 644 %{_sourcedir}/packaging/ligament-authenticator.desktop %{buildroot}/usr/share/applications/ligament-authenticator.desktop
install -m 644 %{_sourcedir}/icons/app_icon.png %{buildroot}/usr/share/icons/hicolor/128x128/apps/ligament-authenticator.png
install -m 644 %{_sourcedir}/icons/app_icon.png %{buildroot}/usr/share/pixmaps/ligament-authenticator.png

%post
if [ -x /usr/bin/update-desktop-database ]; then
    /usr/bin/update-desktop-database -q /usr/share/applications || true
fi
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

%postun
if [ -x /usr/bin/update-desktop-database ]; then
    /usr/bin/update-desktop-database -q /usr/share/applications || true
fi
if [ -x /usr/bin/gtk-update-icon-cache ]; then
    /usr/bin/gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi

%files
%defattr(-,root,root,-)
/opt/ligament-authenticator
/usr/bin/ligament-authenticator
/usr/share/applications/ligament-authenticator.desktop
/usr/share/icons/hicolor/128x128/apps/ligament-authenticator.png
/usr/share/pixmaps/ligament-authenticator.png
