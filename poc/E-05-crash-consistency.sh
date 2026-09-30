#!/usr/bin/env bash
# TITLE: Crash consistency under SIGKILL
# CLAIM: However a commit is interrupted, the four account files are never torn or mutually inconsistent, and the next UMC run restores the exact state from before an interrupted transaction.
# METHOD: The duration of "umc user create" is measured first. Then 400 times: start it, SIGKILL it at a random moment across its whole run, classify the moment from its journal entry (before the journal / journaled but not started / inside the commit / after the commit), run "umc recover", and check every invariant: each file complete and valid, passwd and shadow list the same users, group and gshadow the same groups, the user either fully exists or not at all.
source /src/poc/lib.sh; env_line
make_sandbox debian
N=400
check() {
    awk -F: 'NF != 7 { bad = 1 } END { exit !bad }' "$SB/etc/passwd" && echo "malformed passwd"
    awk -F: 'NF != 9 { bad = 1 } END { exit !bad }' "$SB/etc/shadow" && echo "malformed shadow"
    diff <(cut -d: -f1 "$SB/etc/passwd" | sort) <(cut -d: -f1 "$SB/etc/shadow" | sort) >/dev/null || echo "passwd/shadow disagree"
    diff <(cut -d: -f1 "$SB/etc/group" | sort) <(cut -d: -f1 "$SB/etc/gshadow" | sort) >/dev/null || echo "group/gshadow disagree"
    local n=$1 a=0 b=0 c=0 d=0
    grep -q "^$n:" "$SB/etc/passwd" && a=1; grep -q "^$n:" "$SB/etc/shadow" && b=1
    grep -q "^$n:" "$SB/etc/group" && c=1; grep -q "^$n:" "$SB/etc/gshadow" && d=1
    [[ $a$b$c$d == 0000 || $a$b$c$d == 1111 ]] || echo "user $n half-created ($a$b$c$d)"
}
# calibrate: how long does one create take here?
t0=$(date +%s%N)
for i in 1 2 3 4 5; do "$UMC" --no-color -q --root "$SB" user create "calib$i" --no-home >/dev/null; done
ms=$(( ($(date +%s%N) - t0) / 5000000 ))
echo "one 'umc user create' takes about ${ms} ms here; kills are spread over 0..$((ms * 11 / 10)) ms"
declare -A when=([none]=0 [prepared]=0 [committing]=0 [committed]=0)
bad=0 created=0
for i in $(seq 1 $N); do
    before=$(ls "$SB/var/lib/umc/txn" | wc -l)
    "$UMC" --no-color -q --root "$SB" user create "crash$i" --no-home >/dev/null 2>&1 &
    pid=$!
    d=$(( RANDOM % (ms * 11 / 10 + 1) ))
    sleep "$(printf '%d.%03d' $((d / 1000)) $((d % 1000)))"
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    new=$(ls -t "$SB/var/lib/umc/txn" | head -1)
    st=none
    if (( $(ls "$SB/var/lib/umc/txn" | wc -l) > before )); then
        st=$(sed -n 's/^state=//p' "$SB/var/lib/umc/txn/$new/meta" 2>/dev/null); st=${st:-prepared}
    fi
    when[$st]=$(( ${when[$st]:-0} + 1 ))
    "$UMC" --no-color -q --root "$SB" recover >/dev/null 2>&1
    p=$(check "crash$i")
    [[ -z $p ]] || { bad=$((bad + 1)); echo "iteration $i (killed while '$st'): $p"; }
    grep -q "^crash$i:" "$SB/etc/passwd" && created=$((created + 1))
done
echo
printf '%-58s %s\n' "iterations" "$N"
printf '%-58s %s\n' "killed before its journal entry existed" "${when[none]}"
printf '%-58s %s\n' "killed after journaling, before the first rename" "${when[prepared]}"
printf '%-58s %s\n' "killed INSIDE the commit (rolled back by 'umc recover')" "${when[committing]}"
printf '%-58s %s\n' "killed after the commit (verification / audit stage)" "${when[committed]}"
printf '%-58s %s\n' "users that ended up created" "$created"
printf '%-58s %s\n' "inconsistent states found" "$bad"
echo
echo "final audit of the sandbox:"
"$UMC" --no-color --root "$SB" audit | grep -E 'AUD-0[4-8]|AUD-20'
drop_sandbox
verdict $(( bad > 0 || when[committing] == 0 )) "$( ((when[committing] == 0)) && echo 'no kill landed inside a commit; increase N')"
