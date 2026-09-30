#!/usr/bin/env bash
# Run the UMC test-suite inside disposable containers - no hypervisor needed.
#
#   tests/run-in-docker.sh                     # default distro (debian12)
#   tests/run-in-docker.sh --all               # the whole CI matrix
#   tests/run-in-docker.sh rocky9 ubuntu2404   # pick distros
#   tests/run-in-docker.sh debian12 -- --filter F-02   # pass args to bats
#   tests/run-in-docker.sh --shell rocky9      # interactive shell for debugging
#
# The repo is mounted READ-ONLY at /src. Everything UMC changes happens inside
# the container (its own /etc or throw-away --root sandboxes) and vanishes when
# the container exits (--rm). Nothing on the host is modified.
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

declare -A IMAGES=(
    [debian12]=debian:12
    [debian13]=debian:13
    [ubuntu2204]=ubuntu:22.04
    [ubuntu2404]=ubuntu:24.04
    [rocky9]=rockylinux/rockylinux:9
    [alma9]=almalinux:9
    [fedora42]=fedora:42
    [ubi9]=registry.access.redhat.com/ubi9/ubi
    [ubi8]=registry.access.redhat.com/ubi8/ubi
)
ORDER=(debian12 debian13 ubuntu2204 ubuntu2404 rocky9 alma9 fedora42 ubi9 ubi8)

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

distros=() bats_args=() shell=false rebuild=false
while (($#)); do
    case $1 in
        --all) distros=("${ORDER[@]}") ;;
        --shell) shell=true ;;
        --rebuild) rebuild=true ;;
        -h|--help) usage; exit 0 ;;
        --) shift; bats_args=("$@"); break ;;
        *) [[ -n ${IMAGES[$1]:-} ]] || { echo "unknown distro: $1 (known: ${ORDER[*]})" >&2; exit 2; }
           distros+=("$1") ;;
    esac
    shift
done
((${#distros[@]})) || distros=(debian12)

# bats-core is fetched once (pinned) into the git-ignored cache.
if [[ ! -x $REPO/tests/.cache/bats-core/bin/bats ]]; then
    git clone --quiet --depth 1 --branch v1.14.0 \
        https://github.com/bats-core/bats-core.git "$REPO/tests/.cache/bats-core"
fi

failed=()
for d in "${distros[@]}"; do
    tag="umc-test:$d"
    if $rebuild || ! docker image inspect "$tag" >/dev/null 2>&1; then
        echo "==> building $tag (${IMAGES[$d]})"
        docker build -q --build-arg "BASE=${IMAGES[$d]}" -t "$tag" \
            -f "$REPO/tests/docker/Dockerfile" "$REPO" >/dev/null
    fi
    run=(docker run --rm --hostname "umc-$d" -v "$REPO:/src:ro" -e "UMC_TEST_DISTRO=$d")
    if $shell; then
        "${run[@]}" -it "$tag" bash
        exit
    fi
    echo "==> [$d] running test-suite"
    if "${run[@]}" "$tag" bash tests/run.sh "${bats_args[@]}"; then
        echo "==> [$d] PASS"
    else
        echo "==> [$d] FAIL"; failed+=("$d")
    fi
done

if ((${#failed[@]})); then
    echo "FAILED on: ${failed[*]}" >&2
    exit 1
fi
echo "All selected distros passed: ${distros[*]}"
