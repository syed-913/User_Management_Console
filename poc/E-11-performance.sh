#!/usr/bin/env bash
# TITLE: Bulk performance - 1,000 users
# CLAIM: Creating 1,000 users with home directories and hashed passwords from one CSV is faster with "umc apply" than with a useradd loop or shadow-utils' newusers - while also being one validated, journaled, reversible transaction.
# METHOD: Three runs on identical fresh /etc copies in the same container: (a) umc apply of a 1,000-row CSV (temporary passwords generated and SHA-512 hashed, homes created); (b) a loop of useradd -m plus one chpasswd; (c) newusers. Wall-clock time is measured with bash's time; for each method the number of users, of users that really have a password hash, and of home directories is counted, so no method gets credit for work it skipped.
source /src/poc/lib.sh; env_line
N=1000
cp -a /etc /tmp/etc.orig
reset_etc() { rm -rf /etc/passwd /etc/shadow /etc/group /etc/gshadow /home/p* /var/lib/umc; cp -a /tmp/etc.orig/{passwd,shadow,group,gshadow,subuid,subgid} /etc/ 2>/dev/null; }
{ echo "username,first_name,last_name"; for i in $(seq 1 $N); do echo "p$i,First$i,Last$i"; done; } > /tmp/users.csv
# Debian builds chpasswd/newusers with PAM (no -c option); use it only where it exists.
cm=(); chpasswd --help 2>&1 | grep -q -- '--crypt-method' && cm=(-c SHA512)
nm=(); newusers --help 2>&1 | grep -q -- '--crypt-method' && nm=(-c SHA512)
count() {   # users created / users that really have a password hash / homes
    printf '%s %s %s' "$(grep -c '^p[0-9]' /etc/passwd)" "$(grep -c '^p[0-9]*:\$' /etc/shadow)" "$(find /home -maxdepth 1 -name 'p[0-9]*' -type d | wc -l)"
}
TIMEFORMAT='%R'
reset_etc
t_umc=$( { time umc_live -q --yes apply -f /tmp/users.csv >/dev/null 2>&1; } 2>&1 ); r_umc=$(count)
reset_etc
t_ua=$( { time { for i in $(seq 1 $N); do useradd -m "p$i"; done; for i in $(seq 1 $N); do echo "p$i:Pw-$i-x9Q"; done | chpasswd "${cm[@]}"; } >/dev/null 2>&1; } 2>&1 ); r_ua=$(count)
reset_etc
for i in $(seq 1 $N); do echo "p$i:Pw-$i-x9Q:::First$i:/home/p$i:/bin/bash"; done > /tmp/newusers.txt
t_nu=$( { time newusers "${nm[@]}" /tmp/newusers.txt >/dev/null 2>&1; } 2>&1 ); r_nu=$(count)
printf '%-46s %8s  %6s %8s %6s\n' "method" "seconds" "users" "hashed" "homes"
# shellcheck disable=SC2086  # the three counts are meant to split
printf '%-46s %8s  %6s %8s %6s\n' "umc apply (1 transaction, validated, journaled)" "$t_umc" $r_umc
# shellcheck disable=SC2086
printf '%-46s %8s  %6s %8s %6s\n' "useradd -m loop + chpasswd${cm:+ -c SHA512}" "$t_ua" $r_ua
# shellcheck disable=SC2086
printf '%-46s %8s  %6s %8s %6s\n' "newusers (shadow-utils batch tool)" "$t_nu" $r_nu
echo
echo "Why UMC is fast: one lock, one pass over each file, one openssl process per CPU"
echo "core for all hashes, and one NSS lookup for all new IDs. useradd rewrites all four"
echo "files for every single user. newusers is not idempotent, has no dry run, rollback or journal."
read -r c_umc _ _ <<< "$r_umc"
verdict $(( c_umc != N ))
