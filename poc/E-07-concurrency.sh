#!/usr/bin/env bash
# TITLE: No lost updates next to useradd and PAM (chpasswd)
# CLAIM: UMC takes both locking conventions (shadow-utils FILE.lock and lckpwdf's /etc/.pwd.lock), so running it at the same time as useradd and chpasswd never loses a change that any tool reported as successful.
# METHOD: 3 rounds. In each: 20 "umc user create", 20 "useradd" and a "chpasswd" for the useradd users run concurrently, then 20 "umc user lock" run next to another chpasswd. Afterwards every acknowledged user must exist in passwd AND shadow, every UMC lock must be in place, and every chpasswd password must be set.
source /src/poc/lib.sh; env_line
echo "lckpwdf method on this host:$(umc_live doctor | sed -n 's/.*lckpwdf interop (\/etc\/.pwd.lock) *//p')"
lost=0 acked=0
for round in 1 2 3; do
    : > /tmp/acked
    for i in $(seq 1 20); do
        ( umc_live -q user create "r${round}u$i" >/dev/null 2>&1 && echo "r${round}u$i" >> /tmp/acked ) &
        ( useradd "r${round}s$i" >/dev/null 2>&1 && echo "r${round}s$i" >> /tmp/acked ) &
    done
    wait
    ( for i in $(seq 1 20); do echo "r${round}s$i:Chpw-$round-$i-long"; done | chpasswd >/dev/null 2>&1 && echo chpasswd-ok >> /tmp/acked ) &
    for i in $(seq 1 20); do ( umc_live -q user lock "r${round}u$i" >/dev/null 2>&1 && echo "lock:r${round}u$i" >> /tmp/acked ) & done
    wait
    while read -r n; do
        acked=$((acked + 1))
        case $n in
            chpasswd-ok) for i in $(seq 1 20); do grep -q "^r${round}s$i:\\\$" /etc/shadow || { echo "LOST chpasswd password r${round}s$i"; lost=$((lost + 1)); }; done ;;
            lock:*) grep -q "^${n#lock:}:!" /etc/shadow || { echo "LOST lock ${n#lock:}"; lost=$((lost + 1)); } ;;
            *) { grep -q "^$n:" /etc/passwd && grep -q "^$n:" /etc/shadow; } || { echo "LOST $n"; lost=$((lost + 1)); } ;;
        esac
    done < /tmp/acked
    echo "round $round: $(wc -l < /tmp/acked) acknowledged operations checked"
done
echo
echo "acknowledged operations: $acked"
echo "lost updates:            $lost"
say "grpck -r (shadow-utils' own consistency check)"; grpck -r && echo "  clean"
verdict $(( lost > 0 ))
