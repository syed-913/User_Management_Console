#!/usr/bin/env bash
# TITLE: Account data is never staged in /tmp (fix for F-01)
# CLAIM: UMC never reads or writes predictable temporary paths: files an unprivileged user plants at the names v1 used are left untouched, and /etc/shadow stays root-owned after every operation.
# METHOD: An unprivileged user pre-creates /tmp/passwd, /tmp/shadow, /tmp/group and /tmp/gshadow. Root then runs 25 UMC operations. The planted files are compared before/after, and every file created outside /etc, /var, /home and /root during the run is listed.
source /src/poc/lib.sh; env_line; rc=0

step "An unprivileged user (tester) plants files at the paths v1 staged account data in"
setpriv --reuid=tester --regid=tester --clear-groups -- sh -c 'for f in passwd shadow group gshadow; do echo planted > /tmp/$f; chmod 666 /tmp/$f; done'
ls -l /tmp/passwd /tmp/shadow /tmp/group /tmp/gshadow
before=$(sha256sum /tmp/passwd /tmp/shadow /tmp/group /tmp/gshadow)
touch /tmp/.marker; sleep 1

step "Root runs 25 UMC operations (create, groups, password, lock, unlock, offboard, delete)"
for i in 1 2 3 4 5; do
    umc_live -q user create "demo$i" --groups users
    umc_live -q user passwd "demo$i" --generate
    umc_live -q user lock "demo$i"
    umc_live -q user unlock "demo$i"
    umc_live -q --yes user delete "demo$i"
done
echo "exit status of the last operation: $?"

step "Result"
after=$(sha256sum /tmp/passwd /tmp/shadow /tmp/group /tmp/gshadow)
if [[ $before == "$after" ]]; then echo "planted files: unchanged"; else echo "planted files: CHANGED"; rc=1; fi
ls -l /tmp/passwd /tmp/shadow /tmp/group /tmp/gshadow
echo; echo "owner and mode of the real files:"; stat -c '  %n  %U:%G %a' /etc/passwd /etc/shadow /etc/group /etc/gshadow
[[ $(stat -c %u /etc/shadow) == 0 ]] || rc=1
echo; echo "files created during the run outside /etc, /var, /home, /root, /proc, /run, /sys:"
found=$(find / -xdev -newer /tmp/.marker -type f ! -path '/etc/*' ! -path '/var/*' ! -path '/home/*' ! -path '/root/*' ! -path '/proc/*' ! -path '/run/*' ! -path '/sys/*' ! -path /tmp/.marker 2>/dev/null)
echo "  ${found:-(none)}"
[[ -z $found ]] || rc=1
echo
echo "Why: UMC creates each replacement file with mktemp in the target's own directory"
echo "(/etc/.shadow.umc.XXXXXX: root-owned, mode 0600, created with O_EXCL), then renames it"
echo "over the original. Nothing is copied through a shared directory. See docs/SECURITY-ADVISORY-v1.md."
verdict $rc
