FROM ubuntu:24.04

# Install required packages
RUN apt-get update && apt-get install -y \
  zfsutils-linux \
  python3-pip \
  pipx \
  openssh-client \
  ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install zfs-autobackup
RUN pipx install zfs-autobackup

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