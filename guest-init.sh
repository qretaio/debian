#!/bin/sh
# Guest init for the piebox dev box. libkrun's /init.krun execs this instead
# of systemd (systemd exits under the init-blob). Starts sshd + the vsock
# bridge, then sleeps forever to keep the VM alive.

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true

# Mount virtiofs shares passed as KRUN_MOUNT_<i>="tag:guest_path".
for envvar in $(env | grep '^KRUN_MOUNT_' | cut -d= -f1); do
    spec=$(eval echo \$$envvar)
    tag=${spec%%:*}
    path=${spec#*:}
    mkdir -p "$path" 2>/dev/null || true
    mount -t virtiofs "$tag" "$path" 2>/dev/null || true
done

# Hostname (also baked into /etc/hostname by the image; set it at boot so
# libkrun's init, which may not read /etc/hostname, still reports it).
hostname piebox 2>/dev/null || true
grep -q '[[:space:]]piebox\([[:space:]]\|$\)' /etc/hosts 2>/dev/null || \
    printf '127.0.0.1\tlocalhost piebox\n' >> /etc/hosts 2>/dev/null || true

mkdir -p /run/sshd /etc/ssh/sshd_config.d /var/cache/man
mount -t tmpfs tmpfs /var/cache/man 2>/dev/null || true

# DNS: use TCP so TSI proxies the resolver through vsock like any other
# socket. Cloud-init's /etc/resolv.conf is not usable here.
rm -f /etc/resolv.conf 2>/dev/null || true
printf 'options use-vc\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null || true

# sudo setuid + a tmpfs sudoers (virtiofs-backed /etc cannot be chowned).
install -m 4755 -o root /usr/lib/cargo/bin/sudo /usr/local/bin/sudo 2>/dev/null || true
mkdir -p /run/sudoers.d
mount -t tmpfs tmpfs /run/sudoers.d 2>/dev/null || true
printf 'root ALL=(ALL:ALL) ALL\n%%sudo ALL=(ALL:ALL) ALL\nqreta ALL=(ALL) NOPASSWD:ALL\n' > /run/sudoers.d/sudoers
chmod 0440 /run/sudoers.d/sudoers 2>/dev/null || true
mount --bind /run/sudoers.d/sudoers /etc/sudoers 2>/dev/null || true
mount --bind /run/sudoers.d /etc/sudoers.d 2>/dev/null || true

# sshd on 2222 (the vsock bridge forwards guest 2222 -> host unix socket).
printf '%s\n' 'Port 2222' 'PermitRootLogin no' 'PubkeyAuthentication yes' \
    'PasswordAuthentication no' 'AllowUsers qreta' \
    'ClientAliveInterval 5' 'ClientAliveCountMax 6' \
    > /etc/ssh/sshd_config.d/99-qreta.conf
ssh-keygen -A >/dev/null 2>&1 || true

# apt 3.2 drops gpgv verification into the _apt uid, which under libkrun's
# cap-stripped virtiofs guest exits 111. Pin sandbox user to root. Bootstrap
# gnupg once if the minimal rootfs lacks gpgv.
mkdir -p /etc/apt/apt.conf.d
printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99-piebox-nosandbox
if ! test -x /usr/bin/gpgv; then
    ( apt-get -o Acquire::AllowInsecureRepositories=true --allow-unauthenticated \
        update >/piebox-gnupg.log 2>&1 && \
      DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::AllowInsecureRepositories=true \
        --allow-unauthenticated install -y -qq gnupg >>/piebox-gnupg.log 2>&1 ) &
fi

/usr/sbin/sshd -D -e >/piebox-sshd.log 2>&1 &
python3 /piebox-vsock-bridge.py >/piebox-vsock-bridge.log 2>&1 &
echo 'piebox dev box ready'
exec sleep infinity
