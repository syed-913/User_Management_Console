# Shared helpers for the UMC test-suite (bats-core). Loaded with: load ../helpers
UMC=${UMC:-$(cd -- "$BATS_TEST_DIRNAME/../.." && pwd)/umc.sh}
FIX=$(cd -- "$BATS_TEST_DIRNAME/../fixtures" && pwd)

# make_sandbox [debian|rhel] -> $SB: a throw-away root tree for --root mode,
# with the owners and modes a real system has (git does not store them).
make_sandbox() {
    local flavor=${1:-debian} s u sg
    SB=$(mktemp -d "${BATS_TMPDIR:-/tmp}/umc-sb.XXXXXX")
    cp -a "$FIX/$flavor/etc" "$SB/etc"
    mkdir -p "$SB"/{bin,sbin,usr/bin,usr/sbin,home,var/mail,var/spool/mail,var/spool/cron,run/lock,root}
    for s in bin/sh bin/bash bin/sync usr/bin/bash usr/sbin/nologin sbin/nologin; do
        printf '#!/bin/sh\n' > "$SB/$s"; chmod 755 "$SB/$s"
    done
    chown -R 0:0 "$SB"
    chmod 755 "$SB" "$SB/etc"
    chmod 644 "$SB"/etc/{passwd,group,login.defs,shells,subuid,subgid}
    if [[ $flavor == debian ]]; then
        sg=$(awk -F: '$1=="shadow"{print $3}' "$SB/etc/group"); sg=${sg:-0}
        chown "0:$sg" "$SB"/etc/{shadow,gshadow}; chmod 640 "$SB"/etc/{shadow,gshadow}
    else
        chmod 000 "$SB"/etc/{shadow,gshadow}
    fi
    chmod 440 "$SB/etc/sudoers"; chmod 750 "$SB/etc/sudoers.d"
    while IFS=: read -r u _ uid gid _ home _; do
        [[ $home == /home/* ]] || continue
        mkdir -p "$SB$home"; chown "$uid:$gid" "$SB$home"; chmod 750 "$SB$home"
    done < "$SB/etc/passwd"
    export SB
}
drop_sandbox() { [[ -n ${SB:-} && $SB == "${BATS_TMPDIR:-/tmp}"/umc-sb.* ]] && rm -rf -- "$SB"; return 0; }

umc()      { "$UMC" --no-color --root "$SB" "$@"; }    # sandbox (offline tree)
umc_live() { "$UMC" --no-color "$@"; }                 # the container's own /etc

# ufn CODE [ARGS...] - run CODE with UMC's functions loaded, paths set to $SB.
ufn() {
    local code=$1; shift
    bash -c 'source "$1"; OPT_ROOT=$2; paths_init; cfg_resolve; code=$3; shift 3; eval "$code"' \
        _ "$UMC" "${SB:-}" "$code" "$@"
}

entry()  { grep "^$2:" "$SB/etc/$1"; }                 # entry FILE NAME
field()  { awk -F: -v n="$2" -v f="$3" '$1 == n { print $f }' "$SB/etc/$1"; }
mode_of(){ stat -c %a -- "$1"; }
owner_of(){ stat -c %u:%g -- "$1"; }
sha()    { sha256sum -- "$@" | awk '{print $1}'; }
today()  { echo $(( $(date -u +%s) / 86400 )); }
new_key() { local f; f=$(mktemp -u "${BATS_TMPDIR:-/tmp}/k.XXXXXX"); ssh-keygen -q -t ed25519 -N '' -C "${1:-test}" -f "$f"; cat "$f.pub"; rm -f "$f" "$f.pub"; }

# expect STATUS - after 'run', fail with the output if the status differs
expect() {
    if [[ $status -ne $1 ]]; then
        echo "expected exit $1, got $status"; echo "--- output ---"; echo "$output"
        return 1
    fi
}
contains() { [[ $output == *"$1"* ]] || { echo "output does not contain: $1"; echo "--- output ---"; echo "$output"; return 1; }; }
