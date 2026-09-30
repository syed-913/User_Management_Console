#!/usr/bin/env bash
# TITLE: Rollback restores the account files byte-for-byte
# CLAIM: "umc rollback" puts the four account files back exactly as they were before a transaction - verified with SHA-256 - and lists what it does not revert (home directories).
# METHOD: 50 users are bulk-created in one transaction; the transaction is rolled back; checksums before and after are compared. Then the rollback itself is rolled back.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
{ echo "employee_id,first_name,last_name"; for i in $(seq 1 50); do echo "$i,First$i,Last$i"; done; } > /tmp/50.csv
say "sha256 of passwd, shadow, group, gshadow before"; sha "$SB"/etc/{passwd,shadow,group,gshadow} | tee /tmp/before
umc -q --yes apply -f /tmp/50.csv
echo; echo "users now: $(grep -c '^first' "$SB/etc/passwd")"
say "umc rollback --last"; umc rollback --last
say "sha256 after rollback"; sha "$SB"/etc/{passwd,shadow,group,gshadow} | tee /tmp/after
diff -q /tmp/before /tmp/after && echo "=> identical" || { echo "=> DIFFERENT"; rc=1; }
say "umc rollback --last   (undo the undo)"; umc -q rollback --last
echo "users now: $(grep -c '^first' "$SB/etc/passwd")"
[[ $(grep -c '^first' "$SB/etc/passwd") == 50 ]] || rc=1
say "umc history"; umc history --limit 3
drop_sandbox
verdict $rc
