#!/usr/bin/env bats
# Groups and sudo rules (F-10, F-22).
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

@test "group create allocates a free GID and is idempotent" {
    run umc group create analysts
    expect 0
    entry group analysts && entry gshadow analysts
    run umc group create analysts
    expect 0
    contains "already exists"
}

@test "F-10: add-member twice keeps one entry; remove-member touches only the exact name" {
    umc user create bob >/dev/null
    umc group add-member devs bob >/dev/null
    run umc group add-member devs bob
    expect 0
    [ "$(field group devs 4)" = "bobby,bobcat,bob" ]
    run umc group remove-member devs bob
    expect 0
    [ "$(field group devs 4)" = "bobby,bobcat" ]
    [ "$(field gshadow devs 4)" = "bobby,bobcat" ]
}

@test "a group that is someone's primary group cannot be deleted" {
    run umc group delete bobby
    expect 6
    contains "primary group of: bobby"
}

@test "the group that grants sudo cannot be deleted" {
    run umc group delete sudo --force
    expect 6
    contains "grants sudo"
}

@test "F-22: sudo rules are validated by visudo and installed 0440" {
    run umc sudo grant bobby --commands '/usr/bin/systemctl restart nginx, /usr/bin/journalctl'
    expect 0
    local f="$SB/etc/sudoers.d/umc-user-bobby"
    [ "$(mode_of "$f")" = 440 ]
    grep -q '^bobby ALL=(ALL:ALL) /usr/bin/systemctl restart nginx, /usr/bin/journalctl$' "$f"
    visudo -c -q -f "$f"
}

@test "F-22: user names with a dot get a file name sudo does not skip" {
    umc user create jane.doe >/dev/null
    run umc sudo grant jane.doe
    expect 0
    [ -f "$SB/etc/sudoers.d/umc-user-jane_doe" ]
    [ ! -e "$SB/etc/sudoers.d/umc-user-jane.doe" ]
}

@test "F-22: an invalid command list is refused before anything is written" {
    run umc sudo grant bobby --commands 'systemctl'
    expect 2
    [ ! -e "$SB/etc/sudoers.d/umc-user-bobby" ]
}

@test "sudo revoke removes the rule; revoking twice is a no-op" {
    umc sudo grant bobby >/dev/null
    run umc sudo revoke bobby
    expect 0
    [ ! -e "$SB/etc/sudoers.d/umc-user-bobby" ]
    run umc sudo revoke bobby
    expect 0
    contains "already as requested"
}

@test "NOPASSWD grants carry a warning" {
    run umc sudo grant bobby --nopasswd
    expect 0
    contains "NOPASSWD"
    grep -q 'NOPASSWD: ALL' "$SB/etc/sudoers.d/umc-user-bobby"
}
