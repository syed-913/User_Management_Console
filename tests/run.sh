#!/usr/bin/env bash
# UMC test-suite entry point.
#
#   bash tests/run.sh [bats options]        e.g.  bash tests/run.sh --filter F-02
#
# The suite needs root and rewrites /etc inside its environment (the "live"
# tests), so it REFUSES to run anywhere but a disposable container or VM:
#   tests/run-in-docker.sh   (containers, no hypervisor needed)
#   vagrant provision --provision-with test   (VMs: SELinux, sshd)
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

in_sandbox=false
[[ -f /.dockerenv || -f /run/.containerenv ]] && in_sandbox=true
[[ ${UMC_TEST_VM:-} == 1 ]] && in_sandbox=true          # set by the Vagrant provisioner
if ! $in_sandbox; then
    echo "tests/run.sh: refusing to run outside a container or test VM (it rewrites /etc)." >&2
    echo "use: tests/run-in-docker.sh" >&2
    exit 2
fi
((EUID == 0)) || { echo "tests/run.sh: must run as root (inside the container/VM)" >&2; exit 2; }

bats=$(command -v bats || true)
[[ -n $bats ]] || bats=$here/.cache/bats-core/bin/bats
[[ -x $bats ]] || { echo "bats-core not found (tests/run-in-docker.sh fetches it)" >&2; exit 2; }

# Paths given on the command line (arguments that exist) replace the defaults.
suites=()
for a in "$@"; do [[ -e $a ]] && { suites=(); break; }; done
has_path=false
for a in "$@"; do [[ -e $a ]] && has_path=true; done
if ! $has_path; then
    suites=("$here/unit" "$here/integration" "$here/live")
    [[ ${UMC_E2E:-} == 1 ]] && suites+=("$here/e2e")
fi
export BATS_TMPDIR=${BATS_TMPDIR:-/tmp}
exec "$bats" --print-output-on-failure "$@" "${suites[@]}"
