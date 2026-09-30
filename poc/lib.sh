# shellcheck shell=bash
# Shared by every evidence scenario. Runs INSIDE a disposable container
# (poc/run.sh starts it); never on a host.
set -uo pipefail
[[ -f /.dockerenv || -f /run/.containerenv || ${UMC_TEST_VM:-} == 1 ]] || { echo "refusing to run outside a container/VM" >&2; exit 2; }
export BATS_TEST_DIRNAME=/src/tests/unit BATS_TMPDIR=/tmp
# shellcheck source=../tests/helpers.bash
source /src/tests/helpers.bash
V1=/tmp/v1-umc.sh

env_line() {
    . /etc/os-release
    printf 'ENV: %s · bash %s · %s · %s CPU(s)\n' "$PRETTY_NAME" "${BASH_VERSION%%(*}" "$(flock --version 2>/dev/null | head -1)" "$(nproc)"
}
say()  { printf '\n$ %s\n' "$*"; }
step() { printf '\n## %s\n' "$*"; }
verdict() { if [[ $1 == 0 ]]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL${2:+ - $2}"; fi; }

# v1 exactly as tagged, with two disclosed changes so it can run unattended:
# it operates on / instead of its hard-coded /home/vagrant sandbox, and its
# cosmetic 'sleep 1' pauses are removed. Input is fed to its menus on stdin.
v1_prepare() {
    [[ -f /out/v1-umc.sh ]] || { echo "v1 script not provided"; return 1; }
    sed -e 's|^BASE_DIR="/home/vagrant"|BASE_DIR=""|' -e 's/^\([[:space:]]*\)sleep 1$/\1:/' /out/v1-umc.sh > "$V1"
    mkdir -p /var/lock /tmp
}
# LC_ALL=en_US.UTF-8: v1's password rule is an invalid regex in the C locale
# (finding F-33), so v1 can only create users under a locale like this one.
v1_run() { printf "$1" | TERM=dumb LC_ALL=en_US.UTF-8 timeout 60 bash "$V1" >/tmp/v1.out 2>&1; return 0; }
