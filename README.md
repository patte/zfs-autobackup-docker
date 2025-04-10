# zfs-autobackup-docker

A batteries included docker image for running [zfs-autobackup](https://github.com/psy0rz/zfs_autobackup).

Features:
- [x] SSH agent forwarding
- [x] SSH config with 48h connection persistence
- [x] Known hosts file, no `--strict-host-key-checking=no`
- [x] Based on `ubuntu:24.04`
- [x] GitHub Action to build (daily) and push the image to ghcr.io
- [ ] Version pinning for `zfs-autobackup` (currently using the latest version)

Image:
```
ghcr.io/patte/zfs-autobackup:main
```

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

Or just run the script [`zfs-autobackup`](./zfs-autobackup), which does the same thing.
```bash
./zfs-autobackup --version
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