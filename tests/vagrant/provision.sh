#!/bin/sh
# Vagrant "deps" provisioner: the same packages as the test containers, plus
# openssh-server for the e2e SSH tests. Idempotent.
set -eu
sh /opt/umc/tests/docker/install-deps.sh
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null
else
    dnf install -y -q openssh-server policycoreutils >/dev/null
fi
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd
if command -v getenforce >/dev/null 2>&1; then echo "SELinux: $(getenforce)"; fi
echo "provisioned: $(. /etc/os-release; echo "$PRETTY_NAME")"
