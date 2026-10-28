# Qt validates compiled QML by source mtime. Clamping every same-day build to
# changelog midnight can leave an upgraded widget running stale compiled code.
%global clamp_mtime_to_source_date_epoch 0

Name:           nier-onedrive
Version:        1.3.5
Release:        1%{?dist}
Summary:        OneDrive account setup and Quickshell integration for Nier
License:        GPL-3.0-only
URL:            https://github.com/0byt3/nier-copr
BuildArch:      noarch
Source0:        manifest.json
Source1:        Panel.qml
Source2:        Service.qml
Source3:        Model.js
Source4:        onedrive.svg
Source5:        nier-onedrive-monitor
Source6:        50-nier-monitor.conf
Source7:        nier-onedrive-setup
Source8:        nier-onedrive@.service
Source9:        onedrive-offline.svg
BuildRequires:  systemd-rpm-macros
Requires:       onedrive >= 2.5.12-4
Requires:       python3 >= 3.11
Requires:       systemd
Requires:       /usr/bin/xdg-open
Requires(preun): systemd

%global nier_plugin_dir /usr/local/share/nier/quickshell/plugins/onedrive

%description
Terminal wizard for independent OneDrive accounts, per-account user services,
and account-aware Quickshell widgets for Nier Desktop. The OneDrive client
is supplied by the required onedrive package. Installing this integration
does not authenticate accounts or start synchronization.

%prep

%build

%install
install -d %{buildroot}%{nier_plugin_dir}
install -m 0644 %{SOURCE0} %{SOURCE1} %{SOURCE2} %{SOURCE3} %{SOURCE4} %{SOURCE9} %{buildroot}%{nier_plugin_dir}/
install -D -m 0755 %{SOURCE5} %{buildroot}%{_bindir}/nier-onedrive-monitor
install -D -m 0644 %{SOURCE6} %{buildroot}%{_userunitdir}/onedrive.service.d/50-nier-monitor.conf
install -D -m 0755 %{SOURCE7} %{buildroot}%{_bindir}/nier-onedrive-setup
install -D -m 0644 %{SOURCE8} %{buildroot}%{_userunitdir}/nier-onedrive@.service

%preun
%systemd_user_preun nier-onedrive@.service

%files
%{_bindir}/nier-onedrive-monitor
%{_bindir}/nier-onedrive-setup
%{nier_plugin_dir}
%{_userunitdir}/onedrive.service.d/
%{_userunitdir}/nier-onedrive@.service

%changelog
* Wed Oct 28 2026 Nier maintainers - 1.3.5-1
- Move the folder action beside Add account as a compact icon button

* Wed Oct 28 2026 Nier maintainers - 1.3.4-1
- Restore subtle account text and replace inline path with an Open folder button

* Wed Oct 28 2026 Nier maintainers - 1.3.3-1
- Match account and clickable path styling to status and remove field prefixes

* Wed Oct 28 2026 Nier maintainers - 1.3.2-1
- Open the account sync folder in the default file manager when its path is clicked

* Wed Oct 28 2026 Nier maintainers - 1.3.1-1
- Show Account and home-abbreviated sync Path in widget details

* Wed Oct 28 2026 Nier maintainers - 1.3.0-2
- Wrap detected Microsoft email addresses so the full identity remains visible

* Wed Oct 28 2026 Nier maintainers - 1.3.0-1
- Detect Microsoft account email after sign-in and refresh existing account identities

* Wed Oct 28 2026 Nier maintainers - 1.2.2-2
- Preserve distinct QML build timestamps for same-day widget upgrades

* Wed Oct 28 2026 Nier maintainers - 1.2.2-1
- Use connection-colored icon-only bar widgets and compact account panel actions

* Wed Oct 28 2026 Nier maintainers - 1.2.1-1
- Use supported --sync preview, retain authenticated setups and limit worker threads

* Wed Oct 28 2026 Nier maintainers - 1.2.0-1
- Split account setup, monitor, services and widget from the OneDrive client RPM
