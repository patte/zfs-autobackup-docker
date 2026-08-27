# zfs-autobackup-docker

A batteries included docker image for running [zfs-autobackup](https://github.com/psy0rz/zfs_autobackup).

Features:
- [x] SSH agent forwarding
- [x] SSH config with 48h connection persistence
- [x] Known hosts file, no `--strict-host-key-checking=no`
- [x] Based on `ubuntu:26.04`
- [x] GitHub Action to build and push the image to ghcr.io
- [x] Version pinning for `zfs-autobackup`
- [x] Pre-release channel

Image:
```
ghcr.io/patte/zfs-autobackup:latest
```

Tags:
- `latest` (alias `main`): latest stable release of zfs-autobackup
- `3.3` (etc.): pinned zfs-autobackup version
- `pre`: latest pre-release (equals `latest` when no pre-release is newer than stable)
- `4.0rc1` (etc.): pinned pre-release

New releases on PyPI are picked up and published by a daily check. The current stable and pre tags are rebuilt weekly so the Ubuntu base and apt packages stay fresh; older version tags stay at their last build. When a tag moves to a new image, the old image stays pullable by digest for 90 days and is then deleted. So pinning by digest gives you an immutable image, but only for 90 days after its build.

## Usage

First create a `known_hosts` file for the servers you want to connect to. This will be bind mounted into the container.
```bash
ssh-keyscan HOST >> known_hosts
```

Then run the container with the following command. Note that `--privileged` and `-v /dev:/dev` are required so that ZFS from inside the container can access the host's ZFS devices.
```bash
sudo podman run --rm \
  --privileged \
  -v /dev:/dev \
  --env SSH_AUTH_SOCK=$SSH_AUTH_SOCK \
  -v $SSH_AUTH_SOCK:$SSH_AUTH_SOCK \
  -v ./known_hosts:/root/.ssh/known_hosts \
  ghcr.io/patte/zfs-autobackup:main --help
```

Or just run the script [`zfs-autobackup`](./zfs-autobackup), which does the same thing (using podman or docker, whichever is available).
```bash
./zfs-autobackup --version
```

To use the pre-release channel (or any published tag), set `TAG`:
```bash
TAG=pre ./zfs-autobackup --version
```

### Example
Just run `./zfs-autobackup` where you would run `zfs-autobackup` e.g.:
```bash
./zfs-autobackup -v --ssh-target user@HOST --strip-path=1 --keep-source=10 --keep-target=10 HOST backupPool
```

## Build
To manually build the image, run the following command:
```bash
sudo podman build -t localhost/zfs-autobackup .
```

## For zfs-autobackup developers

To run a local zfs_autobackup checkout inside the container, mount it over the package installed in the container:
```bash
ZAB_SRC=~/src/zfs_autobackup ./zfs-autobackup --version
```
Changes in your local checkout are picked up on the next run, so you do not need to rebuild the image. This works as long as your checkout only uses dependencies already included in the image (currently `colorama`). If you add a new dependency, rebuild the image.

To build the image from a specific branch, tag, or commit, pass a pip-installable archive URL as `ZAB_SPEC`:

```bash
sudo podman build --build-arg ZAB_SPEC=https://github.com/psy0rz/zfs_autobackup/archive/refs/heads/master.tar.gz -t localhost/zfs-autobackup .
```
(An archive URL avoids needing git in the image; `refs/heads/<branch>`, `refs/tags/<tag>`, or a commit SHA all work.)
