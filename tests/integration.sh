#!/bin/bash
# Integration tests for the zfs-autobackup image.
#
#   sudo tests/integration.sh IMAGE
#
# Needs root, docker, zfs (kernel module + zfsutils), python3, a running sshd
# that allows root key login (used as ssh target) and ssh-keygen. Creates a
# file-backed pool "zabtest", an ssh key in /root/.ssh/zabtest_ed25519 and a
# ping receiver on port 18080; everything is removed again at the end.
set -uo pipefail

image=${1:?usage: $0 IMAGE}
pool=zabtest
pool_file=/var/tmp/zabtest.img
key=/root/.ssh/zabtest_ed25519
ping_port=18080
gw=host.docker.internal
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
flags=(--cap-drop ALL --cap-add SYS_ADMIN --security-opt no-new-privileges=true --device /dev/zfs
       --add-host "$gw:host-gateway")
failed=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failed=1; }
check() { # check <description> <command...>: passes when the command succeeds
  local desc=$1; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}
check_log() { # check_log <description> <logfile> <grep pattern>: like check, prints the log on failure
  local desc=$1 file=$2 pattern=$3
  if grep -q "$pattern" "$file"; then pass "$desc"; else fail "$desc"; sed 's/^/    | /' "$file" | tail -25; fi
}
container_rm() { docker rm -f "$@" >/dev/null 2>&1 || true; }

cleanup() {
  container_rm zab-oneshot zab-args zab-ping zab-fail
  [[ -n "${ping_pid:-}" ]] && kill "$ping_pid" 2>/dev/null
  [[ -n "${SSH_AGENT_PID:-}" ]] && ssh-agent -k >/dev/null 2>&1
  zpool destroy "$pool" 2>/dev/null
  rm -f "$pool_file" "$key" "$key.pub"
  [[ -f /root/.ssh/authorized_keys && -n "${pubkey:-}" ]] && sed -i "\#$pubkey#d" /root/.ssh/authorized_keys
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- setup --------------------------------------------------------------------
echo "### setup"
[[ $EUID -eq 0 ]] || { echo "must run as root"; exit 1; }
modprobe zfs 2>/dev/null || true
zpool destroy "$pool" 2>/dev/null; rm -f "$pool_file"
truncate -s 2G "$pool_file"
zpool create -O mountpoint="/$pool" "$pool" "$pool_file"
zfs create "$pool/src"; zfs create "$pool/replica"; zfs create "$pool/sshreplica"
echo data > "/$pool/src/file"
zfs set autobackup:zabtest=true "$pool/src"

ssh-keygen -q -t ed25519 -N '' -f "$key"
pubkey=$(cut -d' ' -f2 "$key.pub")
mkdir -p /root/.ssh && cat "$key.pub" >> /root/.ssh/authorized_keys
ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null | sed "s/^127.0.0.1/$gw/" > "$tmp/known_hosts"
ssh -i "$key" -o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@127.0.0.1 true \
  || { echo "ssh root@127.0.0.1 with the test key does not work, check sshd (PermitRootLogin prohibit-password)"; exit 1; }

cat > "$tmp/pingsrv.py" <<EOF
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n) if n else b""
        open("$tmp/pings.log", "a").write(f"{self.command} {self.path} {len(body)} {body[-80:]!r}\n")
        self.send_response(200); self.end_headers()
    do_GET = do_POST = _h
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", $ping_port), H).serve_forever()
EOF
python3 "$tmp/pingsrv.py" & ping_pid=$!
sleep 1

write() { echo "$RANDOM" >> "/$pool/src/file"; } # so that zfs-autobackup has something to snapshot
last_snapshot() { zfs list -H -t snapshot -o name -s creation -r "$1" | tail -1; }

# --- one-shot mode --------------------------------------------------------------
echo "### one-shot mode"
out=$(docker run --rm "${flags[@]}" "$image" --version 2>&1)
check "--version prints the version" grep -q "zfs-autobackup v" <<<"$out"

docker run --rm "${flags[@]}" "$image" --bogus-argument >/dev/null 2>&1; rc=$?
check "unknown argument exits with 2 (got $rc)" test "$rc" -eq 2

docker run --rm "${flags[@]}" --entrypoint /healthcheck.sh "$image"; rc=$?
check "healthcheck is neutral in one-shot mode (rc $rc)" test "$rc" -eq 0

baked=$(docker run --rm "${flags[@]}" --entrypoint cat "$image" /root/.ssh/config | md5sum)
after=$(docker run --rm "${flags[@]}" --entrypoint /bin/bash "$image" -c '/entrypoint.sh --version >/dev/null; cat /root/.ssh/config; ls /run/zfs-autobackup* 2>/dev/null' | md5sum)
check "entrypoint leaves the image untouched" test "$baked" = "$after"

write
docker run --rm "${flags[@]}" "$image" -v --strip-path=1 --exclude-received zabtest "$pool/replica" >"$tmp/oneshot.log" 2>&1
check_log "local backup" "$tmp/oneshot.log" "All operations completed successfully"
check "local backup created a snapshot on the replica" test -n "$(last_snapshot "$pool/replica/src")"

echo "### one-shot mode via wrapper script with ssh agent and mounted known_hosts"
eval "$(ssh-agent -s)" >/dev/null; ssh-add "$key" 2>/dev/null
write
( cd "$tmp" && ENGINE=docker IMAGE="$image" DOCKER_ARGS="--add-host $gw:host-gateway" \
  "$repo/zfs-autobackup" -v --ssh-target "root@$gw" --strip-path=1 --exclude-received zabtest "$pool/sshreplica" ) >"$tmp/wrapper.log" 2>&1
check_log "wrapper: backup over ssh" "$tmp/wrapper.log" "All operations completed successfully"
check "wrapper: snapshot arrived on the ssh target" test -n "$(last_snapshot "$pool/sshreplica/src")"
ssh-agent -k >/dev/null; unset SSH_AGENT_PID SSH_AUTH_SOCK

# --- zfs version guard ----------------------------------------------------------
echo "### zfs version guard"
zfs_stub() { # zfs_stub <quoted stub lines>: run the entrypoint against a fake "zfs version"
  docker run --rm "${flags[@]}" --entrypoint /bin/bash "$image" -c \
    "printf '%s\n' '#!/bin/bash' $1 > /usr/local/bin/zfs; chmod +x /usr/local/bin/zfs; /entrypoint.sh --version" 2>&1
}

out=$(zfs_stub "'echo zfs-2.3.9-1' 'echo zfs-kmod-2.2.2-1'")
check "warns when the userland is newer than the host module" grep -q "warning: zfs userland 2.3 is newer than the host module 2.2" <<<"$out"

out=$(zfs_stub "'echo zfs-2.3.9-1' 'echo zfs-kmod-2.4.1-1'")
check "quiet when the userland is older than the host module" test 0 -eq "$(grep -c 'warning: zfs userland' <<<"$out")"

out=$(zfs_stub "'exit 1'")
check "runs anyway when zfs version is unavailable" grep -q "zfs-autobackup v" <<<"$out"

# and against the real module, so the parser is exercised on actual zfs version output
host_kmod=$(zfs version | sed -n '2s/^zfs-kmod-\([0-9]\+\.[0-9]\+\).*/\1/p')
img_userland=$(docker run --rm "${flags[@]}" --entrypoint zfs "$image" version | sed -n '1s/^zfs-\([0-9]\+\.[0-9]\+\).*/\1/p')
out=$(docker run --rm "${flags[@]}" --entrypoint /bin/bash "$image" -c "/entrypoint.sh --version" 2>&1)
if [[ -n $host_kmod && -n $img_userland && $img_userland != "$host_kmod" ]] &&
   [[ $(printf '%s\n%s\n' "$img_userland" "$host_kmod" | sort -V | tail -1) == "$img_userland" ]]; then
  check "warns against the real host module (userland $img_userland > module $host_kmod)" \
    grep -q "warning: zfs userland" <<<"$out"
else
  check "quiet against the real host module (userland $img_userland, module $host_kmod)" \
    test 0 -eq "$(grep -c 'warning: zfs userland' <<<"$out")"
fi

# --- service mode ------------------------------------------------------------------
echo "### service mode"
container_rm zab-args
docker run -d --name zab-args "${flags[@]}" -e CRON_SCHEDULE="@daily" -e RUN_ON_STARTUP=true "$image" \
  -v --snapshot-format "weird name-%Y%m%d%H%M%S" --strip-path=1 --exclude-received zabtest "$pool/replica" >/dev/null
write; sleep 8
docker logs zab-args >"$tmp/args.log" 2>&1
check_log "startup run without PING_URL succeeds" "$tmp/args.log" "run finished .* with exit code 0"
check "argument with spaces is passed unchanged" grep -q "Snapshot format            : weird name-" "$tmp/args.log"
check "scheduler started" grep -q "read crontab" "$tmp/args.log"
container_rm zab-args

container_rm zab-ping; : > "$tmp/pings.log"
write
docker run -d --name zab-ping "${flags[@]}" -v "$key:/root/.ssh/id_ed25519:ro" -v "$tmp/known_hosts:/root/.ssh/known_hosts:ro" \
  -e CRON_SCHEDULE="@daily" -e RUN_ON_STARTUP=true -e PING_URL="http://$gw:$ping_port/ping/ok" \
  --health-interval=5s --health-start-period=1s "$image" \
  -v --ssh-target "root@$gw" --strip-path=1 --exclude-received zabtest "$pool/sshreplica" >/dev/null
sleep 10
docker logs zab-ping >"$tmp/ping.log" 2>&1
check_log "service: backup over ssh with mounted key files" "$tmp/ping.log" "run finished .* with exit code 0"
check "service: /start ping" grep -q "GET /ping/ok/start" "$tmp/pings.log"
check_log "service: success ping" "$tmp/pings.log" "GET /ping/ok 0"
check "service: healthy after a successful run" test "$(docker inspect --format '{{.State.Health.Status}}' zab-ping)" = healthy
docker stop -t 5 zab-ping >/dev/null; container_rm zab-ping

echo "### service mode, failing runs (takes up to ~70s)"
container_rm zab-fail; : > "$tmp/pings.log"
docker run -d --name zab-fail "${flags[@]}" -e CRON_SCHEDULE="* * * * *" -e RUN_ON_STARTUP=true \
  -e PING_URL="http://$gw:$ping_port/ping/bad" --health-interval=5s --health-start-period=1s "$image" \
  -v zabtest "$pool/does/not/exist" >/dev/null
for _ in $(seq 1 80); do
  [[ "$(docker inspect --format '{{.State.Health.Status}}' zab-fail)" == unhealthy ]] && break
  sleep 1
done
failures=$(docker exec zab-fail cat /run/zfs-autobackup.failures)
health=$(docker inspect --format '{{.State.Health.Status}}' zab-fail)
check "unhealthy after consecutive failures (health=$health failures=$failures)" test "$health" = unhealthy -a "$failures" -ge 2
check_log "failure ping with log body" "$tmp/pings.log" "POST /ping/bad/fail [1-9][0-9]* .*does not exist"
container_rm zab-fail

echo
if [[ $failed -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; fi
exit $failed
