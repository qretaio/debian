# syntax=docker/dockerfile:1
#
# qretaio/debian — the piebox dev-box ZYGOTE base image.
#
# A single-layer Debian 13 (trixie) aarch64 rootfs that boots SYSTEMD AS PID 1
# under libkrun. systemd gives the dev box real services, timers, sockets,
# restart-on-crash and cgroup v2. `piebox init` pulls this image, exports its
# filesystem into the zygote directory, and clones that tree per box; per-box
# SSH keys are injected on clone.
#
# Two-stage so the FINAL image is one layer: the builder assembles the whole
# root, then `FROM scratch; COPY` flattens it into a single layer.

# ---------------------------------------------------------------- builder --
FROM debian:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# systemd-sysv provides /sbin/init -> ../lib/systemd/systemd (PID 1).
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv dbus apt gnupg ca-certificates openssh-server \
        sudo python3-minimal iproute2 procps coreutils bash passwd && \
    apt-get clean

# Hostname: piebox. /etc/hosts and /etc/resolv.conf are bind-mounted read-only
# during docker build, so stage our versions under /opt/piebox-image and COPY
# them into the final scratch stage below (no Docker mounts there).
RUN printf 'piebox\n' > /etc/hostname && \
    mkdir -p /opt/piebox-image && \
    printf '127.0.0.1\tlocalhost piebox\n' > /opt/piebox-image/hosts && \
    printf 'options use-vc\nnameserver 1.1.1.1\n' > /opt/piebox-image/resolv.conf

# The `qreta` login user: locked password, bash, uid/gid 1000, sudo group.
RUN groupadd -g 1000 qreta && \
    useradd -u 1000 -g 1000 -m -d /home/qreta -s /bin/bash qreta && \
    usermod -aG sudo qreta && \
    printf 'qreta ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/99-qreta && \
    chmod 0440 /etc/sudoers.d/99-qreta && \
    mkdir -p /run/sshd /home/qreta/.ssh /root/.ssh && \
    chmod 0700 /home/qreta/.ssh /root/.ssh

# sshd: key-only on port 2222, qreta only (kept from the pre-systemd image).
# StrictModes no: the zygote bakes qreta as uid 1000, but per-box keys are
# written on the HOST as the host user's uid (501 on macOS). An unprivileged
# host cannot chown them to 1000, so sshd's strict ownership check would
# reject every key. The box is single-user, so relax it.
# AuthorizedKeysFile points at a central, root-readable path: per-box keys
# are written by the HOST user onto a virtiofs rootfs owned by a different
# uid than the guest's qreta (1000), and neither ownership nor mode changes
# are reliable through the simplified virtiofs semantics. sshd runs its key
# lookup as root, so /etc/piebox/authorized_keys is always readable.
RUN mkdir -p /etc/piebox && \
    printf '%s\n' 'Port 2222' 'PermitRootLogin no' 'PubkeyAuthentication yes' \
        'PasswordAuthentication no' 'AllowUsers qreta' 'StrictModes no' \
        'AuthorizedKeysFile /etc/piebox/authorized_keys' \
        'ClientAliveInterval 5' 'ClientAliveCountMax 6' \
        > /etc/ssh/sshd_config.d/99-qreta.conf

# apt 3.2 drops gpgv into the _apt uid; under libkrun's cap-stripped virtiofs
# guest that exits 111. Pin the sandbox user to root.
RUN printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99-piebox-nosandbox

# --- services -----------------------------------------------------------
# The vsock -> sshd bridge as a systemd service. It binds AF_VSOCK port 2222
# on the guest and forwards to sshd on guest TCP 2222 (the host reaches it
# through a host UNIX socket created by libkrun).
COPY vsock-bridge.py /usr/local/bin/piebox-vsock-bridge
RUN chmod 0755 /usr/local/bin/piebox-vsock-bridge
COPY piebox-vsock-bridge.service /etc/systemd/system/piebox-vsock-bridge.service

# A small boot service: set the hostname at boot and add the local /etc/hosts
# line (Docker keeps /etc/hosts read-only during image build). cgroup v2 is
# mounted by systemd itself from the `systemd.unified_cgroup_hierarchy=1`
# kernel cmdline that piebox passes at boot.
COPY fix-ownership.service /etc/systemd/system/fix-ownership.service
COPY fix-home-uid.service /etc/systemd/system/fix-home-uid.service

# /etc/hosts and /etc/resolv.conf are baked into the FINAL stage (FROM scratch
# has no Docker bind mounts, unlike the builder). TCP resolver so TSI proxies
# DNS via vsock; local piebox hostname so `hostname -f` resolves.
# dbus-daemon --system gives systemctl its system bus socket
# (/run/dbus/system_bus_socket). Postinst in a container may not enable it.
RUN ln -sf /lib/systemd/system/dbus.service /etc/systemd/system/multi-user.target.wants/dbus.service && \
    systemctl enable ssh.service piebox-vsock-bridge.service fix-ownership.service fix-home-uid.service

# Bake root-owned, setuid source files for the boot-time sudo fix. The host
# extraction sets every file to the host uid and virtiofs ignores chown, so
# the boot unit copies these into a tmpfs (where root ownership works) and
# bind-mounts them into place. Keeping the correct files HERE means the unit
# needs no chown/chmod logic of its own.
RUN mkdir -p /opt/piebox-image/sudo/sudoers.d && \
    cp /usr/bin/sudo /opt/piebox-image/sudo/sudo && \
    chmod 4755 /opt/piebox-image/sudo/sudo && \
    cp /etc/sudoers /etc/sudo.conf /opt/piebox-image/sudo/ && \
    cp /etc/sudoers.d/* /opt/piebox-image/sudo/sudoers.d/ && \
    chmod 0440 /opt/piebox-image/sudo/sudoers /opt/piebox-image/sudo/sudo.conf \
        /opt/piebox-image/sudo/sudoers.d/*

# A marker so piebox can tell a properly built zygote from a random image.
RUN printf 'single-layer-systemd\n' > /etc/piebox-zygote

# ------------------------------------------------------------------ final --
# Flatten the builder's whole root into ONE layer. `docker export` of this
# image gives piebox a pristine rootfs tree to clone.
FROM scratch
COPY --from=builder / /
# Baked here (not in the builder) because Docker bind-mounts these paths
# read-only during build; the final scratch stage has no such mounts.
COPY --from=builder /opt/piebox-image/hosts /etc/hosts
COPY --from=builder /opt/piebox-image/resolv.conf /etc/resolv.conf

LABEL org.opencontainers.image.title="qretaio/debian" \
      org.opencontainers.image.description="piebox dev-box zygote base (Debian 13, systemd PID 1, qreta user, hostname piebox)" \
      org.opencontainers.image.source="https://github.com/qretaio/debian"
