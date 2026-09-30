#!/usr/bin/env bash
# TITLE: Bulk performance - 1,000 users, compared like with like
# CLAIM: With the same hashing algorithm on both sides and all CPU cores available, "umc apply" creates 1,000 users (password hash and home directory each) faster than a useradd loop and than newusers, because it pays its fixed costs once per batch and hashes in parallel. Limits, measured below too: on one core UMC stays ahead of the useradd loop but newusers is faster with yescrypt (UMC starts one mkpasswd per hash), and for a single user useradd is much faster.
# METHOD: Every run starts from the same fresh /etc in the same container. Each 1,000-user method runs once on all CPU cores and once pinned to one core (taskset). The algorithm column is read from the hashes actually written, and users, hashes and home directories are counted, so no method gets credit for work it skipped. Single user: average of 20 runs.
source /src/poc/lib.sh; env_line
N=1000
cp -a /etc /tmp/etc.orig
reset_etc() { rm -rf /etc/passwd /etc/shadow /etc/group /etc/gshadow /home/p[0-9]* /home/s[0-9]* /var/lib/umc; cp -a /tmp/etc.orig/{passwd,shadow,group,gshadow,subuid,subgid} /etc/; }
{ echo "username"; for i in $(seq 1 $N); do echo "p$i"; done; } > /tmp/users.csv
for i in $(seq 1 $N); do echo "p$i:Pw-$i-x9Q:::First$i:/home/p$i:/bin/bash"; done > /tmp/newusers.txt
printf 'hash_method = YESCRYPT\n' > /tmp/yescrypt.conf
UMC_SHA=(/src/umc.sh --no-color -q --yes apply -f /tmp/users.csv)
UMC_YES=(/src/umc.sh --no-color -q --config /tmp/yescrypt.conf --yes apply -f /tmp/users.csv)
LOOP='for i in $(seq 1 '$N'); do useradd -m "p$i"; done; for i in $(seq 1 '$N'); do echo "p$i:Pw-$i-x9Q"; done | chpasswd -c "$1"'
TIMEFORMAT='%R'
declare -A T=()

# row KEY LABEL CORES CMD... - run on fresh files, print time and what really happened
row() {
    local key=$1 label=$2 cores=$3 t u h d algo first; shift 3
    reset_etc
    if [[ $cores == 1 ]]; then t=$( { time taskset -c 0 "$@" >/dev/null 2>&1; } 2>&1 )
    else t=$( { time "$@" >/dev/null 2>&1; } 2>&1 ); fi
    first=$(awk -F: '$1 == "p1" { print $2 }' /etc/shadow)
    case $first in '$6$'*) algo=SHA-512 ;; '$y$'*) algo=yescrypt ;; *) algo="none" ;; esac
    u=$(grep -c '^p[0-9]' /etc/passwd)
    h=$(awk -F: '$1 ~ /^p[0-9]+$/ && $2 ~ /^\$(6|y)\$/' /etc/shadow | wc -l)
    d=$(find /home -maxdepth 1 -name 'p[0-9]*' -type d | wc -l)
    T[$key]=$t
    printf '%-44s %-5s %-9s %8s %6s %6s %6s\n' "$label" "$cores" "$algo" "$t" "$u" "$h" "$d"
}
all=$(nproc)
printf '%-44s %-5s %-9s %8s %6s %6s %6s\n' "method (1,000 users)" "cores" "hash" "seconds" "users" "hashed" "homes"
echo "--- same algorithm: SHA-512"
row umc_sha_all  "umc apply"                        "$all" "${UMC_SHA[@]}"
row umc_sha_one  "umc apply"                        1      "${UMC_SHA[@]}"
row ua_sha_all   "useradd -m loop + chpasswd -c SHA512" "$all" bash -c "$LOOP" _ SHA512
row ua_sha_one   "useradd -m loop + chpasswd -c SHA512" 1      bash -c "$LOOP" _ SHA512
echo "--- same algorithm: yescrypt"
row umc_yes_all  "umc apply (hash_method = YESCRYPT)" "$all" "${UMC_YES[@]}"
row umc_yes_one  "umc apply (hash_method = YESCRYPT)" 1      "${UMC_YES[@]}"
row nu_all       "newusers (hashes through PAM)"    "$all" newusers /tmp/newusers.txt
row nu_one       "newusers (hashes through PAM)"    1      newusers /tmp/newusers.txt
row ua_yes_all   "useradd -m loop + chpasswd -c YESCRYPT" "$all" bash -c "$LOOP" _ YESCRYPT
row ua_yes_one   "useradd -m loop + chpasswd -c YESCRYPT" 1      bash -c "$LOOP" _ YESCRYPT

echo
echo "--- a single user (average of 20; no password, home created)"
reset_etc; t=$( { time for i in $(seq 1 20); do useradd -m "s$i"; done; } 2>&1 )
printf '%-44s %8s ms\n' "useradd -m" "$(awk -v t="$t" 'BEGIN { printf "%.0f", t * 1000 / 20 }')"
reset_etc; t=$( { time for i in $(seq 1 20); do /src/umc.sh --no-color -q user create "s$i"; done; } 2>&1 )
printf '%-44s %8s ms\n' "umc user create (journal, validation, NSS check, audit)" "$(awk -v t="$t" 'BEGIN { printf "%.0f", t * 1000 / 20 }')"

echo
echo "How to read this: UMC does not run faster code - the hashing is done by the same kind"
echo "of C code (openssl, mkpasswd) - it does less repeated work. A useradd loop starts a"
echo "process, takes the locks and rewrites all four account files (plus backups) once per"
echo "user; UMC does that once per batch, and spreads the hashing and the home directories"
echo "over the CPU cores. On one core only the first effect remains. For one user, UMC's fixed"
echo "safety work (journal, validation, verification, audit record) makes it slower."

faster() { awk -v a="${T[$1]}" -v b="${T[$2]}" 'BEGIN { exit !(a < b) }'; }
rc=0
faster umc_sha_all ua_sha_all || { echo "CLAIM NOT MET: umc (SHA-512) not faster than the useradd loop"; rc=1; }
faster umc_yes_all nu_all     || { echo "CLAIM NOT MET: umc (yescrypt) not faster than newusers"; rc=1; }
faster umc_yes_all ua_yes_all || { echo "CLAIM NOT MET: umc (yescrypt) not faster than the useradd loop"; rc=1; }
verdict $rc
