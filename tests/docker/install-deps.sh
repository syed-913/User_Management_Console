#!/bin/sh
# Installs the packages the UMC test-suite needs inside a disposable test
# container. Runs at image build time only (see tests/docker/Dockerfile).
#
# Split into "required" (UMC itself or the harness cannot work without them)
# and "optional" (UMC detects them at runtime and degrades gracefully - the
# test-suite checks both paths, so a missing optional package is not fatal).
set -eu

if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        bash coreutils util-linux openssl tar gzip findutils diffutils \
        procps passwd login sudo openssh-client ca-certificates >/dev/null
    # optional capabilities
    apt-get install -y -qq --no-install-recommends \
        libpwquality-tools whois >/dev/null 2>&1 || true
    # en_US.UTF-8 is only needed to run v1 in the evidence scripts: v1's
    # password rule is an invalid regex in the C locale (finding F-33).
    apt-get install -y -qq --no-install-recommends locales >/dev/null 2>&1 &&
        localedef -i en_US -f UTF-8 en_US.UTF-8 || true
    rm -rf /var/lib/apt/lists/*
elif command -v dnf >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
    PM=dnf; command -v dnf >/dev/null 2>&1 || PM=microdnf
    # No explicit "coreutils": minimal images ship coreutils-single (same
    # tools, one binary) and the two packages conflict.
    $PM install -y -q \
        bash util-linux openssl tar gzip findutils diffutils \
        procps-ng shadow-utils sudo openssh-clients glibc-common >/dev/null
    $PM install -y -q libpwquality >/dev/null 2>&1 || true
    $PM clean all >/dev/null 2>&1 || true
else
    echo "install-deps: unsupported package manager" >&2
    exit 1
fi

# Tests need an unprivileged account to play the attacker in PoCs.
id tester >/dev/null 2>&1 || useradd -m -s /bin/bash tester
