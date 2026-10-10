#!/bin/bash
# rpi2b-oneshot-setup
clear
set -u
exec >/dev/null 2>&1

[ "$(id -u)" -eq 0 ] || exit 1

ask() {
    [ "${AUTO_YES:-0}" = 1 ] && return 0
    [ "${AUTO_NO:-0}" = 1 ] && return 1
    printf "run %s? [y/N] " "$1" > /dev/tty
    read -r r < /dev/tty || r=""
    case "$r" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

u="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"

systemctl set-default multi-user.target || exit 1
passwd -d root || exit 1
passwd -u root || exit 1
[ "$(passwd -S root | awk '{print $2}')" = NP ] || exit 1

ag="$(command -v agetty)" || exit 1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-$ag --autologin root --noclear %I \$TERM
EOF
systemctl daemon-reload
systemctl enable getty@tty1.service || exit 1
systemctl restart getty@tty1.service || exit 1
systemctl cat getty@tty1.service | grep -q -- '--autologin root' || exit 1

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-root-login.conf <<EOF
PermitRootLogin yes
PermitEmptyPasswords yes
PasswordAuthentication yes
EOF
sshd -t || exit 1
if systemctl list-unit-files | grep -q '^ssh\.service'; then su=ssh
elif systemctl list-unit-files | grep -q '^sshd\.service'; then su=sshd
else exit 1; fi
systemctl restart "$su" || exit 1
sshd -T | grep -q '^permitrootlogin yes' || exit 1
sshd -T | grep -q '^permitemptypasswords yes' || exit 1

[ -n "$u" ] && [ "$u" != root ] && userdel -f -r "$u"

if ask "apt lockdown"; then
    for t in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
        systemctl list-unit-files 2>/dev/null | grep -q "^${t}" && {
            systemctl disable --now "$t"
            systemctl mask "$t"
        }
    done

    w=/usr/local/bin
    case ":$PATH:" in *:"$w":*) : ;; *) exit 1 ;; esac
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

    [ "$(command -v apt)" = "$w/apt" ] || exit 1
    [ "$(command -v apt-get)" = "$w/apt-get" ] || exit 1
    apt upgrade >/dev/null 2>&1 && exit 1
    apt-get upgrade >/dev/null 2>&1 && exit 1
fi

if ask "tuna mirror"; then
    . /etc/os-release
    [ -n "${VERSION_CODENAME:-}" ] || exit 1
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

    { echo "Types: deb"
      echo "URIs: $t/raspbian/raspbian/"
      echo "Architectures: armhf"
      echo "Suites: $cn"
      echo "Components: main contrib non-free rpi"
      [ -n "$rk" ] && echo "Signed-By: $rk"; } > "$sd/raspbian.sources"

    { echo "Types: deb"
      echo "URIs: $t/raspberrypi/"
      echo "Suites: $cn"
      echo "Components: main"
      [ -n "$pik" ] && echo "Signed-By: $pik"; } > "$sd/raspi.sources"

    grep -rqs 'raspbian.raspberrypi.com' "$sd" "$sl" 2>/dev/null && exit 1
    grep -rqs 'archive.raspberrypi.com'  "$sd" "$sl" 2>/dev/null && exit 1
    grep -rqs 'mirrors.tuna.tsinghua.edu.cn' "$sd" "$sl" 2>/dev/null || exit 1
    apt update
fi

if ask "fun tools"; then
    apt install -y cbonsai neofetch figlet
    [ -x /usr/games/cbonsai ] || exit 1
    [ -x /usr/bin/neofetch ]  || exit 1
    [ -x /usr/bin/figlet ]    || exit 1

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
fi

if ask "smb share"; then
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
   server signing = required
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
   smb encrypt = required
EOF

    testparm -s >/dev/null 2>&1 || exit 1

    pdbedit -x -u root 2>/dev/null || true
    tp="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
    printf '%s\n%s\n' "$tp" "$tp" | smbpasswd -s -a root
    printf '%s\n%s\n' "$tp" "$tp" | smbpasswd -s -e root 2>/dev/null || true
    pdbedit -r -u root --set-nt-hash=31D6CFE0D16AE931B73C59D7E0C089C0
    pdbedit -L -w root | cut -d: -f4 | grep -qix 31D6CFE0D16AE931B73C59D7E0C089C0 || exit 1

    if systemctl list-unit-files | grep -q '^smbd\.service'; then sm=smbd
    elif systemctl list-unit-files | grep -q '^smb\.service'; then sm=smb
    else exit 1; fi
    systemctl restart "$sm"
    systemctl enable "$sm"

    systemctl enable --now nmbd  2>/dev/null || true
    systemctl enable --now wsdd2

    testparm -sv 2>/dev/null | grep -qiE 'server min protocol = SMB3(_11)?'  || exit 1
    testparm -sv 2>/dev/null | grep -qE  'max connections = 5'                || exit 1
    testparm -sv 2>/dev/null | grep -qE  'server signing = required'          || exit 1
    testparm -sv 2>/dev/null | grep -qiE 'server smb encrypt = required|smb encrypt = required' || exit 1

    smbclient //localhost/smbshare -U root% -c 'ls' >/dev/null 2>&1 || exit 1
    systemctl is-active wsdd2 >/dev/null || exit 1
    systemctl is-active nmbd  >/dev/null || exit 1
fi
