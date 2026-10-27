%global debug_package %{nil}
%global __strip /bin/true
%global _build_id_links none
%global __brp_check_rpaths %{nil}

Name:           voxtype
Version:        1.1.1
Release:        2%{?dist}
Summary:        Push-to-talk voice-to-text for Linux. Optimized for Wayland, works on X11 too
License:        MIT
URL:            https://voxtype.io
Source0:        https://github.com/peteonrails/voxtype/releases/download/v%{version}/voxtype-%{version}-1.x86_64.rpm

ExclusiveArch:  x86_64
BuildRequires:  cpio
BuildRequires:  rpm
BuildRequires:  python3

AutoReqProv:    no
Requires:       alsa-lib
Requires:       curl
Requires:       glibc
Requires:       pipewire-alsa

%description
Push-to-talk voice-to-text for Linux. Optimized for Wayland, works on X11 too.

%prep
%setup -q -c -T
rpm2cpio %{SOURCE0} | cpio -idmv

%build

%install
rm -rf usr/lib/.build-id
mkdir -p %{buildroot}/etc %{buildroot}/usr
cp -a etc/voxtype %{buildroot}/etc/
cp -a usr/* %{buildroot}/usr/
# Upstream 1.1.1's adaptive launcher assumes AVX2 for every x86_64 CPU.
# Fedora's x86-64-v2 baseline also includes CPUs without AVX2.
python3 - <<'PYTHON'
from pathlib import Path
path = Path("%{buildroot}%{_bindir}/voxtype")
text = path.read_text()
original = 'if [ -x "$VOXTYPE_LIB/voxtype-avx2" ]; then'
marker = '# Final fallback for aarch64 or single-binary installs'
if text.count(original) != 1 or text.count(marker) != 1:
    raise SystemExit("Voxtype launcher changed; review CPU variant adapter")
text = text.replace(original, 'if grep -qw avx2 /proc/cpuinfo 2>/dev/null && [ -x "$VOXTYPE_LIB/voxtype-avx2" ]; then')
text = text.replace(marker, '\n'.join([
    '# Portable x86-64-v2 fallback, without AVX2.',
    'if [ -x "$VOXTYPE_LIB/voxtype-baseline" ]; then',
    '    exec "$VOXTYPE_LIB/voxtype-baseline" "$@"',
    'fi', '', marker,
]))
path.write_text(text)
PYTHON
test -x %{buildroot}/usr/lib/voxtype/voxtype-baseline
sh -n %{buildroot}%{_bindir}/voxtype

%post
if command -v restorecon >/dev/null 2>&1; then
    restorecon %{_bindir}/voxtype 2>/dev/null || true
fi

%files
%config(noreplace) /etc/voxtype/config.toml
%{_bindir}/voxtype
%{_bindir}/voxtype-audio-bridge
%{_bindir}/voxtype-osd
/usr/lib/systemd/user/voxtype.service
/usr/lib/voxtype
%{_datadir}/voxtype
%{_datadir}/bash-completion/completions/voxtype
%{_datadir}/fish/vendor_completions.d/voxtype.fish
%{_datadir}/zsh/site-functions/_voxtype
%{_docdir}/voxtype

%changelog
* Tue Oct 27 2026 Nier maintainers - 1.1.1-2
- Select the packaged baseline variant on CPUs without AVX2.

* Sun Oct 25 2026 neir-copr - 1.1.1-1
- Repackage upstream release 1.1.1
