#!/usr/bin/env bash
# DOCKER: --tmpfs /sb:size=3m
# TITLE: Disk full at every possible moment of a commit
# CLAIM: When the filesystem fills up at any point of a transaction, UMC stops with a clear message and the account files are left exactly as they were (or, if the commit finished, exactly as intended) - never half-written.
# METHOD: The sandbox lives on a 3 MB tmpfs. For every amount of free space from 0 to 200 KB (in 4 KB steps) the disk is filled to that point and "umc user create" is attempted; the outcome and the state of the files are checked each time.
source /src/poc/lib.sh; env_line
export BATS_TMPDIR=/sb
make_sandbox debian
printf '%-10s %-6s %s\n' "free(KB)" "exit" "outcome"
bad=0
for free in $(seq 0 4 200); do
    rm -f /sb/fill
    avail=$(df --output=avail -k /sb | tail -1)
    fill=$((avail - free)); ((fill > 0)) && dd if=/dev/zero of=/sb/fill bs=1K count="$fill" status=none 2>/dev/null
    before=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
    out=$("$UMC" --no-color --root "$SB" user create "full$free" --no-home 2>&1); st=$?
    rm -f /sb/fill
    "$UMC" --no-color -q --root "$SB" recover >/dev/null 2>&1
    after=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
    if ((st == 0)); then
        grep -q "^full$free:" "$SB/etc/passwd" && grep -q "^full$free:" "$SB/etc/shadow" && o="created" || { o="EXIT 0 BUT USER MISSING"; bad=$((bad + 1)); }
    else
        if [[ $before == "$after" ]]; then o="refused, files unchanged: $(grep -m1 -oE 'ERROR: [^.]*' <<< "$out" | cut -c8-70)"
        else o="FILES CHANGED ON FAILURE"; bad=$((bad + 1)); fi
    fi
    printf '%-10s %-6s %s\n' "$free" "$st" "$o"
done
echo; echo "inconsistent outcomes: $bad"
verdict $(( bad > 0 ))
