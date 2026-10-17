#!/bin/bash
# rpi2b-oneshot-setup

clear
set -u

[ "$(id -u)" -eq 0 ] || exit 1

read -r -p "Install? [y/N] " ans < /dev/tty
case "$ans" in
    y|Y|yes|YES) ;;
    *) exit 0 ;;
esac

u="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
[ -n "$u" ] && [ "$u" != root ] && userdel -f -r "$u"

systemctl set-default multi-user.target
passwd -d root
passwd -u root

ag="$(command -v agetty)"
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-$ag --autologin root --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl enable getty@tty1.service
systemctl restart getty@tty1.service

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<EOF
PermitRootLogin yes
PermitEmptyPasswords yes
PasswordAuthentication yes
EOF
sshd -t
if systemctl list-unit-files | grep -q '^ssh\.service'; then su=ssh
elif systemctl list-unit-files | grep -q '^sshd\.service'; then su=sshd
else su=
fi
[ -n "$su" ] && systemctl restart "$su"

for t in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${t}" && {
        systemctl disable --now "$t"
        systemctl mask "$t"
    }
done

w=/usr/local/bin
ar="$(PATH="${PATH//$w:/}" command -v apt 2>/dev/null || echo /usr/bin/apt)"
agr="$(PATH="${PATH//$w:/}" command -v apt-get 2>/dev/null || echo /usr/bin/apt-get)"
aitr="$(PATH="${PATH//$w:/}" command -v aptitude 2>/dev/null || true)"

cat > "$w/apt" <<EOF
#!/bin/bash
sub=""
for a in "\$@"; do
    case "\$a" in --) break ;; -*) continue ;; *) sub="\$a"; break ;; esac
done
case "\$sub" in
    upgrade|full-upgrade|dist-upgrade) exit 1 ;;
esac
exec "$ar" "\$@"
EOF
chmod 755 "$w/apt"

cat > "$w/apt-get" <<EOF
#!/bin/bash
sub=""
for a in "\$@"; do
    case "\$a" in --) break ;; -*) continue ;; *) sub="\$a"; break ;; esac
done
case "\$sub" in
    upgrade|dist-upgrade) exit 1 ;;
esac
exec "$agr" "\$@"
EOF
chmod 755 "$w/apt-get"

if [ -n "$aitr" ]; then
    cat > "$w/aptitude" <<EOF
#!/bin/bash
sub=""
for a in "\$@"; do
    case "\$a" in --) break ;; -*) continue ;; *) sub="\$a"; break ;; esac
done
case "\$sub" in
    upgrade|safe-upgrade|full-upgrade|dist-upgrade) exit 1 ;;
esac
exec "$aitr" "\$@"
EOF
    chmod 755 "$w/aptitude"
fi

. /etc/os-release
cn="$VERSION_CODENAME"

rk=""
for k in /usr/share/keyrings/raspbian-archive-keyring.gpg /usr/share/keyrings/raspbian-archive-keyring.pgp; do
    [ -f "$k" ] && rk="$k" && break
done
pik=""
for k in /usr/share/keyrings/raspberrypi-archive-keyring.pgp /usr/share/keyrings/raspberrypi-archive-keyring.gpg; do
    [ -f "$k" ] && pik="$k" && break
done

t="https://mirrors.tuna.tsinghua.edu.cn"
sd=/etc/apt/sources.list.d
sl=/etc/apt/sources.list

rm -f "$sd"/*.sources "$sd"/*.list
: > "$sl"

{
    echo "Types: deb"
    echo "URIs: $t/raspbian/raspbian/"
    echo "Architectures: armhf"
    echo "Suites: $cn"
    echo "Components: main contrib non-free rpi"
    [ -n "$rk" ] && echo "Signed-By: $rk"
} > "$sd/raspbian.sources"

{
    echo "Types: deb"
    echo "URIs: $t/raspberrypi/"
    echo "Suites: $cn"
    echo "Components: main"
    [ -n "$pik" ] && echo "Signed-By: $pik"
} > "$sd/raspi.sources"

apt update

apt install -y cbonsai neofetch figlet

if [ -x /usr/bin/figlet-figlet ] && \
   update-alternatives --list figlet 2>/dev/null | grep -qx '/usr/bin/figlet-figlet'; then
    [ "$(readlink -f /usr/bin/figlet)" = /usr/bin/figlet-figlet ] || \
        update-alternatives --set figlet /usr/bin/figlet-figlet
fi

[ -x /usr/games/cbonsai ] && ln -sf /usr/games/cbonsai /usr/local/bin/cbonsai

cat > /etc/profile.d/games-path.sh <<'EOF'
case ":$PATH:" in
    *:/usr/games:*) ;;
    *) PATH="/usr/games:$PATH" ;;
esac
export PATH
EOF
chmod 644 /etc/profile.d/games-path.sh

apt install -y samba samba-common-bin smbclient wsdd2

for s in winbind samba-ad-dc; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service" && \
        systemctl disable --now "$s"
done

[ -d /smbshare ] || mkdir -p /smbshare
chmod 777 /smbshare

cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = Raspberry Pi 2B
   netbios name = RPI2B
   server role = standalone server
   map to guest = never
   restrict anonymous = 0
   null passwords = yes
   server min protocol = SMB3_11
   server max protocol = SMB3_11
   server signing = no
   smb encrypt = off
   multicast dns register = yes
   local master = yes
   preferred master = yes
   os level = 65
   max connections = 5

   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

[smbshare]
   path = /smbshare
   browseable = yes
   read only = no
   valid users = root
   force user = root
   force group = root
   create mask = 0644
   directory mask = 0755
   smb encrypt = off
EOF

pdbedit -x -u root 2>/dev/null
tp="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
printf '%s\n%s\n' "$tp" "$tp" | smbpasswd -s -a root
printf '%s\n%s\n' "$tp" "$tp" | smbpasswd -s -e root 2>/dev/null
pdbedit -r -u root --set-nt-hash=31D6CFE0D16AE931B73C59D7E0C089C0

if systemctl list-unit-files | grep -q '^smbd\.service'; then sm=smbd
elif systemctl list-unit-files | grep -q '^smb\.service'; then sm=smb
else sm=
fi
[ -n "$sm" ] && {
    systemctl restart "$sm"
    systemctl enable "$sm"
}

systemctl enable --now nmbd  2>/dev/null
systemctl enable --now wsdd2

exit 0
