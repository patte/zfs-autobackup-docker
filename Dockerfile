FROM ubuntu:26.04

# Install required packages
RUN apt-get update && apt-get install -y \
  mbuffer \
  zfsutils-linux \
  python3-pip \
  pipx \
  netcat-openbsd \
  openssh-client \
  ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install zfs-autobackup. ZAB_SPEC takes any pip install spec:
# a pinned version (zfs-autobackup==3.3), a pre-release (zfs-autobackup==4.0rc1),
# or an archive URL (https://github.com/psy0rz/zfs_autobackup/archive/refs/heads/master.tar.gz)
ARG ZAB_SPEC="zfs-autobackup"
RUN pipx install "$ZAB_SPEC"

# Set the PATH so pipx-installed apps are found
ENV PATH="/root/.local/bin:$PATH"

# Create SSH config to keep connections alive and reuse connection
RUN mkdir -p /root/.ssh && \
  echo "Host *" > /root/.ssh/config && \
  echo "    ServerAliveInterval 60" >> /root/.ssh/config && \
  echo "    ServerAliveCountMax 15" >> /root/.ssh/config && \
  echo "    ControlMaster auto" >> /root/.ssh/config && \
  echo "    ControlPath /root/.ssh/cm-%r@%h:%p" >> /root/.ssh/config && \
  echo "    ControlPersist 48h" >> /root/.ssh/config && \
  chmod 600 /root/.ssh/config

# Set the entrypoint
ENTRYPOINT ["zfs-autobackup"]
