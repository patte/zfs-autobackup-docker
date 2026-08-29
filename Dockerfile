FROM debian:trixie-slim

# zfsutils-linux is in contrib. --no-install-recommends: python3-pip and friends
# otherwise pull build-essential and a full gcc toolchain that nothing here needs.
RUN sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
  && apt-get update && apt-get install -y --no-install-recommends \
  mbuffer \
  zfsutils-linux \
  python3-venv \
  netcat-openbsd \
  openssh-client \
  procps \
  ca-certificates \
  curl \
  tzdata \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# supercronic runs zfs-autobackup on a schedule in service mode (CRON_SCHEDULE set)
ARG SUPERCRONIC_VERSION=0.2.49
ARG TARGETARCH
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
  && case "$arch" in \
    amd64) sha256=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
    arm64) sha256=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
    *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
  esac \
  && curl -fsSLo /usr/local/bin/supercronic \
    "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${arch}" \
  && echo "${sha256}  /usr/local/bin/supercronic" | sha256sum -c - \
  && chmod +x /usr/local/bin/supercronic

# Install zfs-autobackup. ZAB_SPEC takes any pip install spec:
# a pinned version (zfs-autobackup==3.3), a pre-release (zfs-autobackup==4.0rc1),
# or an archive URL (https://github.com/psy0rz/zfs_autobackup/archive/refs/heads/master.tar.gz)
# pip is removed afterwards, the venv is only ever built here.
ARG ZAB_SPEC="zfs-autobackup"
RUN python3 -m venv /opt/zab \
  && /opt/zab/bin/pip install --no-cache-dir "$ZAB_SPEC" \
  && rm -rf /opt/zab/lib/python3*/site-packages/pip* /opt/zab/bin/pip*

# Set the PATH so the venv's apps are found
ENV PATH="/opt/zab/bin:$PATH"

# SSH config: keep connections alive and reuse one connection (see ssh.config)
COPY ssh.config /root/.ssh/config
RUN chmod 600 /root/.ssh/config

COPY entrypoint.sh service-run.sh healthcheck.sh /
RUN chmod +x /entrypoint.sh /service-run.sh /healthcheck.sh

# Reports unhealthy in service mode when the scheduler died or the last runs failed
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=1 CMD ["/healthcheck.sh"]

# Runs zfs-autobackup with the given arguments, or on a schedule when CRON_SCHEDULE is set
ENTRYPOINT ["/entrypoint.sh"]
