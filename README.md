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
- [x] Service mode: run on a cron schedule
- [x] TrueNAS: compose file for a Custom App

Image:
```
ghcr.io/patte/zfs-autobackup:latest
```

Tags:
- `latest` (alias `main`): latest stable release of zfs-autobackup
- `3` (etc.): latest stable release within a major version
- `3.3` (etc.): pinned zfs-autobackup version
- `pre`: latest pre-release (equals `latest` when no pre-release is newer than stable)
- `4.0rc1` (etc.): pinned pre-release

New releases on PyPI are picked up and published by a daily check. The current stable and pre tags are rebuilt weekly so the Ubuntu base and apt packages stay fresh; older version tags stay at their last build.

When a tag moves to a new image, the old image stays pullable by digest for 90 days and is then deleted. So pinning by digest gives you an immutable image, but only for 90 days after its build.

## Usage

First create a `known_hosts` file for the servers you want to connect to. This will be bind mounted into the container.
```bash
ssh-keyscan HOST >> known_hosts
```

Then run the container with the following command.
```bash
sudo podman run --rm \
  --cap-drop ALL --cap-add SYS_ADMIN --cap-add DAC_OVERRIDE \
  --security-opt no-new-privileges=true \
  --device /dev/zfs \
  --env SSH_AUTH_SOCK=$SSH_AUTH_SOCK \
  -v $SSH_AUTH_SOCK:$SSH_AUTH_SOCK \
  -v ./known_hosts:/root/.ssh/known_hosts \
  ghcr.io/patte/zfs-autobackup:latest --help
```
_ZFS inside the container needs `CAP_SYS_ADMIN` and `/dev/zfs`; `DAC_OVERRIDE` lets root in the container use your user's ssh-agent socket (can be dropped if you mount a key file instead)._

Or just run the script [`zfs-autobackup`](./zfs-autobackup), which does the same thing (using podman or docker, whichever is available).
```bash
./zfs-autobackup --version
```

Just run `./zfs-autobackup` where you would run `zfs-autobackup` e.g.:
```bash
./zfs-autobackup -v --ssh-target user@HOST --strip-path=1 --keep-source=10 --keep-target=10 HOST backupPool
```

To use the pre-release channel (or any published tag), set `TAG`:
```bash
TAG=pre ./zfs-autobackup --version
```

### Service mode (cron schedule)

By default the container behaves like the `zfs-autobackup` binary: it runs once with the given arguments and exits.

Set `CRON_SCHEDULE` to keep the container running and execute `zfs-autobackup` on that schedule e.g. for docker compose, TrueNAS or Unraid. The image is using [supercronic](https://github.com/aptible/supercronic) under the hood, so any cron expression supported by supercronic is supported here.

```yaml
services:
  zfs-autobackup:
    image: ghcr.io/patte/zfs-autobackup:latest
    restart: unless-stopped
    cap_drop: [ALL]
    cap_add: [SYS_ADMIN]
    security_opt: [no-new-privileges=true]
    devices:
      - /dev/zfs:/dev/zfs
    volumes:
      - ./ssh/id_ed25519:/root/.ssh/id_ed25519:ro
      - ./ssh/known_hosts:/root/.ssh/known_hosts:ro
    environment:
      TZ: Europe/Zurich
      CRON_SCHEDULE: "0 3 * * *"
      RUN_ON_STARTUP: "true"
    command: ["-v", "--ssh-target", "user@HOST", "--strip-path=1", "--keep-source=10", "--keep-target=10", "offsite", "backupPool/myhost"]
```

`CAP_SYS_ADMIN` and access to `/dev/zfs` are required so that ZFS inside the container can talk to the host's ZFS kernel module.

#### Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `CRON_SCHEDULE` | unset (one-shot mode) | Cron expression; keeps the container running and executes `zfs-autobackup` on that schedule. |
| `RUN_ON_STARTUP` | `false` | `true`: additionally run once immediately on start. |
| `TZ` | `UTC` | Timezone for the schedule and the snapshot names. |
| `PING_URL` | unset | healthchecks.io style monitoring pings, see below. |
| `UNHEALTHY_AFTER_FAILURES` | `2` | Consecutive failed runs after which the healthcheck reports unhealthy. |

These knobs only work in service mode (except `TZ`) as in one-shot only `zfs-autobackup` is run.

#### SSH key and known_hosts

No ssh agent in a long-running container, so use a dedicated key without passphrase and pin the host key:

```bash
mkdir -p ssh
ssh-keygen -t ed25519 -N '' -C zfs-autobackup -f ssh/id_ed25519
ssh-keyscan HOST >> ssh/known_hosts
```

Mount both read-only as in the example above. Add `ssh/id_ed25519.pub` to `~/.ssh/authorized_keys` on the target. The key has the same power there as the user it logs in as, so prefer a dedicated user with [`zfs allow` permissions](https://github.com/psy0rz/zfs_autobackup/wiki/Manual#running-without-root) over root.

For ports, jump hosts etc. mount your own ssh config to `/root/.ssh/config`. Start from [`ssh.config`](./ssh.config), so the connection sharing settings stay, and add a `Host` block to it.

#### Noticing failures

The image offers two options to get notified when things go wrong, so failing backups get noticed.
- `PING_URL`: [healthchecks.io](https://healthchecks.io) style monitoring (also understood by Uptime Kuma, Cronitor, ...): `$PING_URL/start` is requested before a run, `$PING_URL` after a successful and `$PING_URL/fail` (with the last log lines as body) after a failed run. The monitoring service then alerts on failures *and* on runs that don't happen at all.
- The container's healthcheck reports unhealthy when the scheduler is gone or the last two runs in a row failed (`UNHEALTHY_AFTER_FAILURES` to change the count), visible in `docker ps` and in platforms that display container health.

Also see [Monitoring](https://github.com/psy0rz/zfs_autobackup/wiki/Monitoring) in the zfs_autobackup wiki for more options.

#### TrueNAS

zfs-autobackup runs on TrueNAS (24.10 or newer, tested on 25.04, 25.10) as a *Custom App* with the compose file [`truenas/docker-compose.yaml`](./truenas/docker-compose.yaml):

0. The dataset the backups are received under needs to exist on the ssh target already, zfs-autobackup does not create it: `zfs create -p backup/truenas` there
1. Create a dataset for the app's state (ssh key, known_hosts), e.g. `tank/apps/zfs-autobackup`.
2. Adjust the settings block at the top of the compose file: backup name, datasets to back up, ssh target and target dataset, the config dataset from step 1, schedule and timezone.
3. Apps → Discover Apps → ⋮ (top right) → *Install via YAML*, paste the file, install.
4. On the first start the app generates an ssh key and prints the public key in the logs ("View logs" of `zfs-autobackup-init`); the first backup run fails because the target doesn't trust it yet. Add it to `authorized_keys` on the target, then restart the app: the backup runs again immediately and the logs show whether it works. See [Using your own ssh key](#using-your-own-ssh-key) if you want to provide a key yourself.

The compose file defines a single service with two containers:
- an init container prepares the config dataset on every start: ssh key, ssh config with host key pinning, the `autobackup:<name>` property on the selected datasets, an ssh connection check.
- the main container runs `zfs-autobackup` on the schedule. After two failed runs in a row the app shows as *Deploying* instead of *Running*; set `PING_URL` in the compose file to get notified.

The compose file is a normal one, it also works with `docker compose up -d` on other hosts with ZFS.

##### Caveats

We [proposed this as an app for the TrueNAS catalog](https://github.com/truenas/apps/pull/5685); it was declined because it accesses ZFS directly without coordination with the TrueNAS middleware.

What "without coordination" means in practice (tested on 25.04, 25.10):
- The app runs as root with `CAP_SYS_ADMIN` on `/dev/zfs`: full control over all datasets.
- zfs-autobackup's snapshots show up in the UI like any other
- Periodic snapshot tasks by TrueNAS on the same datasets are fine, each tool only thins its own naming scheme.
- The newest zfs-autobackup snapshot on each side carries a hold to protect the last common snapshot between the source and target; deleting it in the UI fails with "dataset is busy".
- The compose file passes `--exclude-received`, which tells zfs-autobackup to ignore datasets where the `autobackup:` property was received and only use the ones where it was set locally. The reason: when ZFS replicates a dataset it copies its properties too, including `autobackup:<name>=true`. A copy that a TrueNAS replication task makes of a dataset you selected for zfs-autobackup (e.g. `tank/photos` → `backuppool/photos`) would otherwise be marked for backup as well; zfs-autobackup would snapshot and hold the copy, and the TrueNAS replication task that owns it can then fail with "dataset is busy" as soon as it has to remove a snapshot that is held (its retention pruning the copy, or a rollback before an incremental receive). The same would happen when another machine running zfs-autobackup with the same backup name is replicated into this TrueNAS. With the flag, both cases just work.

**Removing the app** leaves the snapshots, the `autobackup:<name>` property and the hold on the newest snapshot behind. To clean up on the TrueNAS shell: `sudo zfs inherit -r autobackup:<name> <dataset>`, `sudo zfs release zfs_autobackup:<name> <dataset>@<snapshot>` for the held snapshot (`zfs list -t snapshot -H -o name -r <dataset> | xargs zfs holds` lists them), then delete the snapshots in the UI; same on the target.

##### Using your own ssh key

The init container only generates a key when `<config dataset>/ssh/` contains no id_* file, so you can provide one yourself before the first start (or replace the generated one later). E.g.

```bash
sudo mkdir -p /mnt/tank/apps/zfs-autobackup/ssh
sudo cp id_ed25519 /mnt/tank/apps/zfs-autobackup/ssh/   # private key, no passphrase
```

or copy the file in via an SMB/NFS share of that dataset. Ownership and permissions don't matter, the init container sets them (root, 0600). Any `id_*` file works (id_ed25519, id_rsa, …); with several, all are offered to the target. A keypair from Credentials → Backup Credentials → SSH Keypairs can be used the same way by pasting its private key into the file. Restart the app afterwards.

The same directory holds `known_hosts`. By default the target's host key is accepted on the first connection and pinned from then on. To pin it beforehand, put it there yourself and switch to strict checking:

```bash
ssh-keyscan backup.example.com | sudo tee -a /mnt/tank/apps/zfs-autobackup/ssh/known_hosts
```

and set `STRICT_HOST_KEY_CHECKING: "yes"` in the compose file.


<details>
<summary>

##### Alternatively, run the one-shot container from a TrueNAS cron job

</summary>

*System → Advanced Settings → Cron Jobs → Add*

Run As User: `root`

Command:

```bash
docker run --rm --cap-drop ALL --cap-add SYS_ADMIN --security-opt no-new-privileges=true --device /dev/zfs \
  -v /mnt/tank/apps/zfs-autobackup/ssh/id_ed25519:/root/.ssh/id_ed25519:ro \
  -v /mnt/tank/apps/zfs-autobackup/ssh/known_hosts:/root/.ssh/known_hosts:ro \
  ghcr.io/patte/zfs-autobackup:3 -v --ssh-target user@HOST --strip-path=1 offsite backupPool/truenas
```
</details>

## Build
To manually build the image, run the following command:
```bash
sudo podman build -t localhost/zfs-autobackup .
```

## Tests
CI builds the image and runs it on every pull request and before publishing.
```bash
docker build -t zfs-autobackup:test . && sudo tests/integration.sh zfs-autobackup:test
```

`tests/integration.sh IMAGE` runs the image against a file-backed pool and the local sshd (needs root, docker, zfs and sshd) and checks the one-shot usage, the wrapper script and service mode including pings and the healthcheck.

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
