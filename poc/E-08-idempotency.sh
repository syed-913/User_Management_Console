#!/usr/bin/env bash
# TITLE: Idempotency - running the same thing twice changes nothing
# CLAIM: Every UMC operation converges: repeating a create, a lock, a group change or a whole bulk apply leaves the account files byte-identical and exits 0.
# METHOD: Each operation runs twice in a sandbox; SHA-256 of the four files is compared after the first and second run.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
twice() {
    local a b
    umc "$@" >/dev/null 2>&1; a=$(sha "$SB"/etc/{passwd,shadow,group,gshadow} | sha256sum | cut -c1-16)
    out=$(umc "$@" 2>&1); st=$?; b=$(sha "$SB"/etc/{passwd,shadow,group,gshadow} | sha256sum | cut -c1-16)
    printf '%-58s exit %s  %s  %s\n' "umc $*" "$st" "$( [[ $a == "$b" ]] && echo "unchanged" || echo CHANGED)" "$(grep -oE '(= |already )[^(]*' <<< "$out" | head -1 | cut -c1-40)"
    [[ $a == "$b" && $st == 0 ]] || rc=1
}
twice user create carol --groups users
twice group create analysts
twice group add-member analysts carol
twice user lock carol
twice sudo grant carol
twice --yes apply -f /src/tests/fixtures/imports/team_manifest.json
twice --yes apply -f /src/tests/fixtures/imports/hr_export_semicolon.csv
drop_sandbox
verdict $rc
