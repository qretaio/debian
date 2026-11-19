# syntax=docker/dockerfile:1
#
# qretaio/debian — the piebox dev-box ZYGOTE base image.
#
# A single-layer, Debian 13 (trixie) aarch64/amd64 rootfs with everything the
# piebox dev box needs baked in: the `qreta` user, hostname `piebox`, sshd,
# sudo, apt config, the guest init and the vsock->sshd bridge. `piebox init`
# pulls this image, exports its filesystem into the zygote directory, and
# clones that tree per box; per-box SSH keys are injected on clone.
#
# Two-stage so the FINAL image is one layer: the builder assembles the whole
# root in /out, then `FROM scratch; ADD` flattens it into a single layer.

# ---------------------------------------------------------------- builder --
FROM debian:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Minimal userspace. apt itself (and gpgv) must exist for a dev box to run
# `apt update`; the rest are the usual interactive/SSH essentials.
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/var/lib/apt/lists \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        apt gnupg ca-certificates openssh-server sudo python3-minimal \
        iproute2 procps coreutils bash passwd && \
    apt-get clean

# Hostname: piebox. Both /etc/hostname and /etc/hosts for `hostname -f`.
RUN printf 'piebox\n' > /etc/hostname && \
    printf '127.0.0.1\tlocalhost piebox\n' > /etc/hosts

# The `qreta` login user: locked password, bash, uid/gid 1000, sudo group.
# The home files are created here with the base 1000 ids; piebox clones the
# zygote and rewrites ownership/keys for the host user's actual uid/gid.
RUN groupadd -g 1000 qreta && \
    useradd -u 1000 -g 1000 -m -d /home/qreta -s /bin/bash qreta && \
    usermod -aG sudo qreta && \
    printf 'qreta:!:20000:0:99999:7:::\n' >/dev/null && \
    printf 'qreta ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/99-qreta && \
    chmod 0440 /etc/sudoers.d/99-qreta

# sshd config for the dev box: port 2222, key-only, qreta only.
RUN printf '%s\n' 'Port 2222' 'PermitRootLogin no' 'PubkeyAuthentication yes' \
        'PasswordAuthentication no' 'AllowUsers qreta' \
        'ClientAliveInterval 5' 'ClientAliveCountMax 6' \
        > /etc/ssh/sshd_config.d/99-qreta.conf && \
    mkdir -p /run/sshd /home/qreta/.ssh /root/.ssh && \
    chmod 0700 /home/qreta/.ssh /root/.ssh

# apt 3.2 drops gpgv into the _apt uid; under libkrun's cap-stripped virtiofs
# guest that exits 111. Pin the sandbox user to root.
RUN printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99-piebox-nosandbox

# Guest-side init + vsock->sshd bridge. These are the exact files the libkrun
# backend execs (`/piebox-init.sh`) and starts; keep them in sync with the
# copies embedded in the piebox repo's scripts/zygote/ (which are the
# fallback path when no container runtime is available).
COPY guest-init.sh /piebox-init.sh
COPY vsock-bridge.py /piebox-vsock-bridge.py
RUN chmod 0755 /piebox-init.sh /piebox-vsock-bridge.py

# A marker so piebox can tell a properly built zygote from a random image.
RUN printf 'single-layer\n' > /etc/piebox-zygote

# ------------------------------------------------------------------ final --
# Flatten the builder's whole root into ONE layer. `docker export` of this
# image gives piebox a pristine rootfs tree to clone.
FROM scratch
COPY --from=builder / /

LABEL org.opencontainers.image.title="qretaio/debian" \
      org.opencontainers.image.description="piebox dev-box zygote base (Debian 13, qreta user, hostname piebox)" \
      org.opencontainers.image.source="https://github.com/qretaio/debian"
