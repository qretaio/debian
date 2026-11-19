# qretaio/debian

The **zygote base image** for [piebox](https://github.com/qretaio/piebox) dev boxes.

A single-layer Debian 13 (trixie) aarch64 rootfs with all base customizations baked in:

- login user **`qreta`** (uid/gid 1000, locked password, passwordless sudo)
- hostname **`piebox`**
- `sshd` on port 2222 (key-only, `AllowUsers qreta`), the vsock→sshd bridge
- apt configured for libkrun's cap-stripped virtiofs guest
- the guest init (`/piebox-init.sh`) that boots the box

`piebox init` pulls this image, exports its filesystem into the zygote
directory, and clones that pristine tree into each box's persistent rootfs.
Per-box SSH public keys are injected on clone; everything else stays baked.

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
- `guest-init.sh`, `vsock-bridge.py` — the exact guest files exec'd by the
  libkrun backend. Kept in sync with `scripts/zygote/` in the piebox repo
  (the fallback path when no container runtime is available).
- `.github/workflows/build.yml` — builds/pushes the public image.
