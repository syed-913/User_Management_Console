#!/usr/bin/env bats
# Rollback, crash recovery, audit-log integrity, history, locks (F-09, F-13, F-14).
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

last_txn() { ls "$SB/var/lib/umc/txn" | tail -1; }

@test "F-09: rollback restores the account files byte-for-byte" {
    local before; before=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
    umc user create carol --groups devs >/dev/null
    run umc rollback "$(last_txn)"
    expect 0
    [ "$(sha "$SB"/etc/{passwd,shadow,group,gshadow})" = "$before" ]
    contains "not reverted"                                    # the home dir is reported, not hidden
}

@test "rollback --last undoes the newest change, and a rollback can itself be rolled back" {
    umc user create carol >/dev/null
    local after; after=$(sha "$SB/etc/passwd")
    run umc rollback --last
    expect 0
    ! entry passwd carol
    run umc rollback --last
    expect 0
    [ "$(sha "$SB/etc/passwd")" = "$after" ]
}

@test "rollback refuses to clobber later changes unless --force" {
    umc user create carol >/dev/null
    local t1; t1=$(last_txn)
    umc user create dave >/dev/null
    run umc rollback "$t1"
    expect 6
    contains "changed after"
    entry passwd dave
    run umc rollback "$t1" --force
    expect 0
    ! entry passwd carol
}

@test "crash recovery: SIGKILL half-way through a commit is rolled back on the next run" {
    local before; before=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
    run env UMC_FAULT=kill-after-install:2 "$UMC" --no-color --root "$SB" user create carol
    [ "$status" -eq 137 ]                                      # killed by SIGKILL
    grep -qx 'state=committing' "$SB"/var/lib/umc/txn/*/meta   # the journal knows
    run umc user list
    contains "interrupted transaction"
    run umc recover
    expect 0
    contains "interrupted transaction"
    [ "$(sha "$SB"/etc/{passwd,shadow,group,gshadow})" = "$before" ]
    grep -qx 'state=recovered' "$SB"/var/lib/umc/txn/*/meta
}

@test "every mutating command recovers automatically before doing its own work" {
    run env UMC_FAULT=kill-after-install:3 "$UMC" --no-color --root "$SB" user create carol
    [ "$status" -eq 137 ]
    run umc user create dave
    expect 0
    contains "restoring the state from before it"
    ! entry passwd carol && entry passwd dave
}

@test "F-14: the UMC lock records its holder only after acquiring it" {
    umc user create carol >/dev/null
    read -r pid < "$SB/run/lock/umc.lock"
    [[ $pid =~ ^[0-9]+$ ]]
}

@test "F-13: two UMC processes serialise instead of losing an update" {
    ( umc user create par.one >/dev/null ) & ( umc user create par.two >/dev/null ) & wait
    entry passwd par.one && entry passwd par.two
    entry shadow par.one && entry shadow par.two
}

@test "audit log: every change is a chained record; editing a line is detected" {
    umc user create carol >/dev/null
    umc user lock carol >/dev/null
    run umc log verify
    expect 0
    contains "hash chain verified"
    sed -i '1s/"user.create"/"user.delete"/' "$SB/var/log/umc/audit.jsonl"
    run umc log verify
    expect 7
    contains "does not chain"
}

@test "audit log: deleting a record is detected" {
    umc user create carol >/dev/null; umc user create dave >/dev/null; umc user lock dave >/dev/null
    sed -i '2d' "$SB/var/log/umc/audit.jsonl"
    run umc log verify
    expect 7
}

@test "F-31: audit records name the actor and never contain secrets" {
    printf 'Correct-Horse-9\n' | umc user create carol --password-stdin >/dev/null
    umc user passwd carol --generate >/dev/null
    grep -q '"action":"user.create"' "$SB/var/log/umc/audit.jsonl"
    grep -q '"actor":"' "$SB/var/log/umc/audit.jsonl"
    ! grep -q 'Correct-Horse-9' "$SB/var/log/umc/audit.jsonl"
    ! grep -q '\$6\$' "$SB/var/log/umc/audit.jsonl"
}

@test "history lists transactions; show redacts password hashes" {
    printf 'Correct-Horse-9\n' | umc user create carol --password-stdin >/dev/null
    run umc history
    expect 0
    contains "user.create"
    run umc show "$(last_txn)"
    expect 0
    contains "<hash>"
    [[ $output != *'$6$'* ]]
}

@test "locks: stale shadow-utils locks are reported and can be cleared" {
    printf '999999' > "$SB/etc/group.lock"
    run umc locks
    expect 0
    contains "STALE"
    run umc locks --clear-stale
    expect 0
    [ ! -f "$SB/etc/group.lock" ]
}

@test "F-32: --json output is machine-readable and errors are JSON too" {
    run umc --json user create carol
    expect 0
    [[ $output == '{"ok":true,'* ]]
    run umc --json user create bin
    [[ $output == *'"ok":false'* ]]
}
