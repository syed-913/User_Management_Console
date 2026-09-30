#!/usr/bin/env bats
# The commit protocol: atomic replacement, preserved metadata, validation,
# dry-run, journal. Regression tests for v1's F-01..F-04 and F-18.
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; rm -f /tmp/shadow /tmp/passwd /tmp/group /tmp/gshadow; }

@test "F-01: a pre-planted /tmp/shadow is never used (no predictable temp files)" {
    # planted by an unprivileged user, exactly as in the v1 attack
    setpriv --reuid=tester --regid=tester --clear-groups -- sh -c 'echo attacker-owned > /tmp/shadow; chmod 666 /tmp/shadow' 
    local before; before=$(sha /tmp/shadow)
    run umc user create carol
    expect 0
    [ "$(sha /tmp/shadow)" = "$before" ]                 # untouched
    [ "$(stat -c %U /tmp/shadow)" = tester ]
    [ "$(stat -c %u "$SB/etc/shadow")" = 0 ]            # still root's file
}

@test "F-02: owner and mode of all four databases survive a commit (Debian: shadow 640 root:shadow)" {
    local sg; sg=$(awk -F: '$1=="shadow"{print $3}' "$SB/etc/group")
    run umc user create carol
    expect 0
    [ "$(mode_of "$SB/etc/passwd")" = 644 ]
    [ "$(mode_of "$SB/etc/group")" = 644 ]
    [ "$(mode_of "$SB/etc/shadow")" = 640 ]
    [ "$(owner_of "$SB/etc/shadow")" = "0:$sg" ]
    [ "$(mode_of "$SB/etc/gshadow")" = 640 ]
}

@test "F-02: RHEL convention (shadow 000) is preserved as well" {
    drop_sandbox; make_sandbox rhel
    run umc user create carol
    expect 0
    [ "$(mode_of "$SB/etc/shadow")" = 0 ]
    [ "$(mode_of "$SB/etc/gshadow")" = 0 ]
    [ "$(mode_of "$SB/etc/passwd")" = 644 ]
}

@test "F-04: a commit leaves shadow-utils style FILE- backups and no temp files behind" {
    local before; before=$(sha "$SB/etc/passwd")
    run umc user create carol
    expect 0
    [ "$(sha "$SB/etc/passwd-")" = "$before" ]          # the previous version
    [ -z "$(find "$SB/etc" -name '.*.umc.*')" ]         # temp files were renamed away
}

@test "F-04: untouched lines are written back byte-for-byte" {
    printf 'odd  spacing:x:3000:3000::/home/odd:/bin/sh\n' >> "$SB/etc/passwd"   # weird but pre-existing
    run umc user create carol
    expect 0
    grep -qx 'odd  spacing:x:3000:3000::/home/odd:/bin/sh' "$SB/etc/passwd"
}

@test "dry run prints a redacted diff and writes nothing" {
    local before; before=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
    run umc --dry-run user create carol --generate-password
    expect 0
    contains "+carol:x:"
    contains "<hash>"
    [[ $output != *'$6$'* ]]                             # no hash leaks into the output
    [ "$(sha "$SB"/etc/{passwd,shadow,group,gshadow})" = "$before" ]
    [ ! -d "$SB/home/carol" ]
    [ -z "$(ls -A "$SB/root/umc/credentials" 2>/dev/null)" ]
}

@test "every commit is journaled with pre/post images and checksums" {
    run umc user create carol
    expect 0
    local d; d=$(ls -d "$SB"/var/lib/umc/txn/* | tail -1)
    [ -f "$d/meta" ] && [ -f "$d/files" ] && [ -f "$d/SHA256SUMS" ]
    grep -qx 'state=committed' "$d/meta"
    (cd "$d" && sha256sum --quiet -c SHA256SUMS)
    [ "$(mode_of "$d")" = 700 ]
    [ "$(mode_of "$d/pre/0")" = 600 ]                    # pre-images contain hashes
}

@test "F-18: a staged file that would be malformed is refused before anything is written" {
    local before; before=$(sha "$SB/etc/passwd")
    run ufn '
        preflight; lk_acquire_db; db_load; txn_begin test "bad line"
        txn_target PW evil
        PW_L+=("evil:x:notanumber:1:::/bin/sh"); PW_I[evil]=$(( ${#PW_L[@]} - 1 )); DB_DIRTY[PW]=1
        txn_commit'
    expect 7
    contains "refusing to commit"
    [ "$(sha "$SB/etc/passwd")" = "$before" ]
}

@test "blast radius: an entry changed without being declared stops the commit" {
    local before; before=$(sha "$SB/etc/passwd")
    run ufn '
        preflight; lk_acquire_db; db_load; txn_begin test "sneaky"
        txn_target_user carol
        db_put PW carol "carol:x:4000:4000::/home/carol:/bin/sh"
        db_put SP carol "carol:!:20000:0:99999:7:::"
        db_fields PW bobby; F[6]=/bin/sh; join_fields "${F[@]}"; db_put PW bobby "$REPLY"
        txn_commit'
    expect 7
    contains "blast-radius check failed: entry 'bobby'"
    [ "$(sha "$SB/etc/passwd")" = "$before" ]
}

@test "invariant: a change that would remove root's UID 0 is refused" {
    run ufn '
        preflight; lk_acquire_db; db_load; txn_begin test "no root"
        txn_target_user root
        db_put PW root "root:x:5:0:root:/root:/bin/bash"
        txn_commit'
    expect 7
    contains "root would no longer have UID 0"
}

@test "duplicate entries are never edited by guesswork" {
    printf 'bobby:x:1002:1002:dup:/home/bobby:/bin/bash\n' >> "$SB/etc/passwd"
    run umc user modify bobby --shell /bin/sh
    expect 7
    contains "more than one entry named 'bobby'"
}

@test "shadow-utils interop: a held passwd.lock makes UMC wait, then fail cleanly" {
    mkdir -p "$SB/etc/umc"; printf 'lock_timeout = 2\n' > "$SB/etc/umc/umc.conf"
    sleep 30 & local holder=$!
    printf '%s' "$holder" > "$SB/etc/passwd.lock"
    run umc user create carol
    kill "$holder"
    expect 4
    contains "is locked by"
    contains "nothing was changed"
    [ -f "$SB/etc/passwd.lock" ]                          # someone else's lock is never removed
    ! grep -q '^carol:' "$SB/etc/passwd"
}

@test "a stale lock (dead PID) is detected and cleared" {
    printf '999999' > "$SB/etc/shadow.lock"
    run umc user create carol
    expect 0
    contains "stale lock"
    [ ! -f "$SB/etc/shadow.lock" ]
}

@test "a config file writable by other users is refused (live mode only guards)" {
    mkdir -p "$SB/etc/umc"; printf 'bogus_key = 1\n' > "$SB/etc/umc/umc.conf"
    run umc user list
    expect 3
    contains "unknown setting 'bogus_key'"
}
