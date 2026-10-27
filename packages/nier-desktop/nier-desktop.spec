%global commit 2332782f088c85a675f64b309a910a9cb162b135
%global shortcommit 2332782

Name:           nier-desktop
Version:        4.0.0~alpha
Release:        1.git%{shortcommit}%{?dist}
Summary:        Nier Hyprland + Quickshell desktop
License:        MIT
URL:            https://github.com/0byt3/nier-desktop
Source0:        https://github.com/0byt3/nier-desktop/archive/%{commit}/%{name}-%{commit}.tar.gz
BuildArch:      noarch
Provides:       nier = %{version}-%{release}

BuildRequires:  bash
BuildRequires:  coreutils
BuildRequires:  findutils

Requires:       bash
Requires:       dnf5
Requires:       dnf5-plugins
Requires:       fedora-workstation-repositories
Requires:       rpm
Requires:       coreutils
Requires:       findutils
Requires:       grep
Requires:       sed
Requires:       gawk
Requires:       util-linux
Requires:       util-linux-script
Requires:       procps-ng
Requires:       diffutils
Requires:       tar
Requires:       gzip
Requires:       bzip2
Requires:       xz
Requires:       unzip
Requires:       curl
Requires:       jq
Requires:       fzf
Requires:       socat
Requires:       python3
Requires:       lua
Requires:       perl-JSON-PP
Requires:       perl-Encode
Requires:       systemd
Requires:       dbus
Requires:       libnotify
Requires:       which

Requires:       hyprland
Requires:       xdg-desktop-portal-hyprland
Requires:       hyprpicker
Requires:       hyprsunset
Requires:       hypridle
Requires:       hyprlock
Requires:       hyprpaper
Requires:       uwsm
Requires:       quickshell
Requires:       ghostty
Requires:       greetd
Requires:       cage
Requires:       wlr-randr
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-gtk
Requires:       xdg-terminal-exec
Requires:       xdg-user-dirs
Requires:       xdg-utils
Requires:       desktop-file-utils
Requires:       gtk3
Requires:       gtk4
Requires:       qt6-qtwayland
Requires:       qt6-qt5compat
Requires:       qt6-qtsvg
Requires:       qt6-qtimageformats
Requires:       fontconfig
Requires:       liberation-sans-fonts
Requires:       liberation-serif-fonts
Requires:       liberation-mono-fonts
Requires:       google-noto-emoji-color-fonts
Requires:       google-noto-sans-cjk-ttc-fonts

Requires:       pipewire
Requires:       pipewire-alsa
Requires:       pipewire-pulseaudio
Requires:       wireplumber
Requires:       alsa-utils
Requires:       pamixer
Requires:       pavucontrol
Requires:       brightnessctl
Requires:       playerctl
Requires:       upower
Requires:       power-profiles-daemon
Requires:       NetworkManager
Requires:       NetworkManager-wifi
Requires:       iw
Requires:       bluez
Requires:       bluez-tools
Requires:       gnome-keyring
Requires:       libsecret
Requires:       polkit
Requires:       fcitx5
Requires:       fcitx5-gtk
Requires:       fcitx5-qt
Requires:       wl-clipboard
Requires:       wtype
Requires:       grim
Requires:       slurp
Requires:       qrencode
Requires:       zbar
Requires:       tesseract
Requires:       tesseract-langpack-eng
Requires:       v4l-utils
Requires:       ImageMagick
# Fedora ffmpeg-free and RPM Fusion ffmpeg both provide this executable.
Requires:       /usr/bin/ffmpeg
Requires:       libxkbcommon-utils
Requires:       python3-gobject
Requires:       python3-dbus
Requires:       python3-pyyaml

Requires:       git
Requires:       gh
Requires:       neovim
Requires:       tmux
Requires:       ripgrep
Requires:       fd-find
Requires:       bat
Requires:       btop
Requires:       eza
Requires:       zoxide
Requires:       tealdeer
Requires:       glow
Requires:       gum
Requires:       yq
Requires:       pandoc
Requires:       fastfetch
Requires:       inxi
Requires:       dconf
Requires:       glib2
Requires:       bash-completion
Requires:       iproute
Requires:       kmod
Requires:       less
Requires:       vim-enhanced
Requires:       plocate
Requires:       yt-dlp
Requires:       flatpak
Requires:       mise
Requires:       blesh
Requires:       snapper
Requires:       btrfs-progs
Requires:       dracut
Requires:       grubby

Requires:       chromium
Requires:       nautilus
Requires:       nautilus-python
Requires:       sushi
Requires:       evince
Requires:       xournalpp
Requires:       imv
Requires:       mpv
Requires:       mpv-mpris
Requires:       pinta
Requires:       gnome-disk-utility
Requires:       cups
Requires:       system-config-printer
Requires:       udiskie
Requires:       udisks2

%description
Nier is a Fedora Hyprland + Quickshell desktop. This package installs the
vendor tree under /usr/local/share/nier and the nier CLI at /usr/local/bin/nier.

Activate with:
  sudo nier apply --system
  sudo nier apply --system-wide
  nier apply

%prep
%setup -q -n %{name}-%{commit}

%build

%install
install -Dm0755 bin/nier %{buildroot}/usr/local/bin/nier
mkdir -p %{buildroot}/usr/local/share/nier
cp -a share/. %{buildroot}/usr/local/share/nier/
find %{buildroot}/usr/local/share/nier/bin -type f -exec chmod 0755 {} +

%post
if [ "$1" -ge 1 ] && [ -x /usr/local/bin/nier ]; then
  /usr/local/bin/nier apply --system || :
fi

%files
/usr/local/bin/nier
/usr/local/share/nier

%changelog
* Mon Oct 26 2026 neir-copr - 4.0.0~alpha-1.git2332782
- Snapshot 4.0.0.alpha (2332782)
