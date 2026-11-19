# qretaio/debian

The **zygote base image** for [piebox](https://github.com/qretaio/piebox) dev boxes.

A single-layer Debian 13 (trixie) aarch64 rootfs with all base customizations baked in:

- **systemd as PID 1** — real services, timers, sockets, restart-on-crash,
  and cgroup v2 (booted with `systemd.unified_cgroup_hierarchy=1`)
- login user **`qreta`** (uid/gid 1000, locked password, passwordless sudo)
- hostname **`piebox`**
- `sshd` on port 2222 (key-only, `AllowUsers qreta`) and the vsock→sshd bridge,
  both as systemd units
- apt configured for libkrun's cap-stripped virtiofs guest

`piebox init` pulls this image, exports its filesystem into the zygote
directory, and clones that pristine tree into each box's persistent rootfs.
Per-box SSH public keys are injected on clone; everything else stays baked.
The libkrun backend boots libkrunfw's kernel directly with
`init=/sbin/init`, so no `/init.krun` init-blob is involved.

## Image

```
ghcr.io/qretaio/debian:latest      # aarch64, Debian 13 trixie
```

Built by GH Actions on push to `main` (`.github/workflows/build.yml`) on a
free `ubuntu-24.04-arm` runner. The image is public so CI VMs can pull it
without credentials.

## Layout

- `Dockerfile` — two-stage build: `debian:trixie` builder assembles the root,
  then `FROM scratch; COPY --from=builder / /` flattens it to one layer.
- `piebox-boot.service`, `piebox-vsock-bridge.service`, `vsock-bridge.py` —
  the systemd units + bridge that replace the old `/piebox-init.sh` script.
- `.github/workflows/build.yml` — builds/pushes the public image.
