#!/usr/bin/env bash
# TITLE: The audit log is tamper-evident
# CLAIM: Each audit record carries the SHA-256 of the previous record, so editing, deleting or inserting a line is detected by "umc log verify" (and each record's hash is also sent to journald where available).
# METHOD: 10 operations are logged; the chain is verified; then one record is edited, one is deleted, and one is inserted, verifying after each.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
for i in 1 2 3 4 5; do umc -q user create "log$i"; umc -q user lock "log$i"; done
L=$SB/var/log/umc/audit.jsonl
say "head -2 audit.jsonl"; head -2 "$L"
say "umc log verify"; umc log verify || rc=1
cp "$L" /tmp/good
say "edit record 3 (change the target)"; sed -i '3s/"log2"/"someone"/' "$L"; umc log verify; [[ $? == 7 ]] || rc=1
cp /tmp/good "$L"; say "delete record 5"; sed -i '5d' "$L"; umc log verify; [[ $? == 7 ]] || rc=1
cp /tmp/good "$L"; say "insert a forged record after record 2"; sed -i '2a {"seq":99,"action":"user.create","prev":"0000000000000000000000000000000000000000000000000000000000000000"}' "$L"; umc log verify; [[ $? == 7 ]] || rc=1
cp /tmp/good "$L"; say "restore the original"; umc log verify || rc=1
echo
echo "Limit (stated honestly): root can recompute the whole chain. Forward the journald"
echo "copy (UMC_CHAIN field) to a remote log server - that is the real control."
drop_sandbox
verdict $rc
