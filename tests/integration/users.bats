#!/usr/bin/env bats
# User lifecycle in a --root sandbox. Regression tests F-05..F-08, F-11,
# F-12, F-15, F-19, F-21, F-25..F-27.
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

@test "create: user-private group, shadow defaults from login.defs, home from /etc/skel" {
    run umc user create carol --comment "Carol Danvers" --groups users
    expect 0
    [ "$(field passwd carol 7)" = /bin/sh ]                     # SHELL from /etc/default/useradd
    [ "$(field passwd carol 3)" = "$(field passwd carol 4)" ]
    entry group carol
    [ "$(field shadow carol 5)" = 99999 ]
    [ "$(field shadow carol 2)" = '!' ]                         # no password yet
    [ -f "$SB/home/carol/.bashrc" ]
    [ "$(stat -c %u:%a "$SB/home/carol")" = "$(field passwd carol 3):755" ]  # UMASK 022
    [ "$(field passwd carol 3)" = 1001 ] || [ "$(field passwd carol 3)" = 1004 ]  # right after 1003, skipping docker
    [[ $(field group users 4) == *carol* ]]
}

@test "F-05: a new user never gets a GID that already belongs to another group (docker=1001)" {
    run umc user create carol
    expect 0
    local uid; uid=$(field passwd carol 3)
    [ "$uid" != 1001 ]
    [ "$(field passwd carol 4)" = "$uid" ]
    [ "$(awk -F: -v g="$uid" '$3==g{print $1}' "$SB/etc/group")" = carol ]
}

@test "F-12: 'nobody' (65534) does not push new IDs to 65535" {
    run umc user create carol
    expect 0
    (( $(field passwd carol 3) < 60000 ))
}

@test "F-12: an explicit --uid that is taken as a GID is refused" {
    run umc user create carol --uid 1001
    expect 6
    contains "already in use"
}

@test "create is idempotent: same request again is a no-op; a different one is a conflict" {
    umc user create carol --groups users >/dev/null
    local before; before=$(sha "$SB"/etc/{passwd,group})
    run umc user create carol --groups users
    expect 0
    contains "already exists with the requested settings"
    [ "$(sha "$SB"/etc/{passwd,group})" = "$before" ]
    run umc user create carol --shell /bin/bash
    expect 6
    contains "different settings"
}

@test "F-25: an existing directory is never handed to a new account" {
    mkdir -p "$SB/home/carol"; chown 1002:1002 "$SB/home/carol"   # bobby's leftovers
    run umc user create carol
    expect 1
    contains "belongs to uid 1002"
    contains "follow-up step"
    [ "$(stat -c %u "$SB/home/carol")" = 1002 ]
}

@test "F-26: a shell that is not in /etc/shells is refused" {
    run umc user create carol --shell /bin/zsh
    expect 2
    contains "not listed in /etc/shells"
}

@test "F-11: comments with & and commas are stored exactly (7 fields)" {
    run umc user create carol --comment 'R&D Team, Room 4'
    expect 0
    [ "$(field passwd carol 5)" = 'R&D Team, Room 4' ]
    [ "$(awk -F: '$1=="carol"{print NF}' "$SB/etc/passwd")" = 7 ]
    run umc user modify carol --comment 'A|B\C & D'
    expect 0
    [ "$(field passwd carol 5)" = 'A|B\C & D' ]
}

@test "F-15: password from stdin is policy-checked and hashed; empty input is refused" {
    umc user create carol >/dev/null
    run bash -c 'printf "\n" | "$1" --no-color --root "$2" user passwd carol --password-stdin' _ "$UMC" "$SB"
    expect 3
    [[ $(field shadow carol 2) != *NULL* ]]
    run bash -c 'printf "weak\n" | "$1" --no-color --root "$2" user passwd carol --password-stdin' _ "$UMC" "$SB"
    expect 3
    run bash -c 'printf "Correct-Horse-9\n" | "$1" --no-color --root "$2" user passwd carol --password-stdin' _ "$UMC" "$SB"
    expect 0
    [[ $(field shadow carol 2) == '$6$'* ]]
}

@test "F-19: lock = '!' prefix AND account expiry (so SSH keys are refused too)" {
    run umc user lock bobby --reason "security review"
    expect 0
    [[ $(field shadow bobby 2) == '!$6$'* ]]
    [ "$(field shadow bobby 8)" = 1 ]
    run umc user lock bobby
    expect 0
    contains "already locked"
}

@test "unlock restores exactly what lock changed (password and the old expiry)" {
    umc user expire bobby 2030-01-01 >/dev/null
    local exp; exp=$(field shadow bobby 8)
    umc user lock bobby >/dev/null
    run umc user unlock bobby
    expect 0
    [[ $(field shadow bobby 2) == '$6$'* ]]
    [ "$(field shadow bobby 8)" = "$exp" ]
}

@test "F-07: unlocking an account whose password is just '!' never leaves it empty" {
    umc user create carol >/dev/null                        # password field: "!"
    sed -i 's/^carol:!:/carol:!!:/' "$SB/etc/shadow"         # locked by 'passwd -l' elsewhere
    run umc user unlock carol
    expect 0
    [ -n "$(field shadow carol 2)" ]
    sed -i 's/^carol:[^:]*:/carol:!:/' "$SB/etc/shadow"
    run umc user unlock carol
    [ -n "$(field shadow carol 2)" ]
    [[ $status -eq 0 || $status -eq 6 ]]
}

@test "F-06: system accounts and root are protected (no rm -rf /bin)" {
    run umc user delete bin --yes
    expect 6
    contains "system account"
    run umc user delete root --yes
    expect 6
    contains "UID-0"
    [ -d "$SB/bin" ]
}

@test "last-admin protection: the only sudo member cannot be offboarded" {
    run umc user offboard admin
    expect 6
    contains "last usable administrator"
}

@test "F-21: delete archives and verifies the home BEFORE removing anything" {
    umc user create carol >/dev/null
    echo data > "$SB/home/carol/notes.txt"
    run umc --yes user delete carol
    expect 0
    ! grep -q '^carol:' "$SB/etc/passwd" "$SB/etc/shadow" "$SB/etc/group"
    [ ! -d "$SB/home/carol" ]
    local a; a=$(ls "$SB"/var/lib/umc/archive/carol-*-home-*.tar.gz)
    tar -tzf "$a" | grep -q 'carol/notes.txt'
    (cd "${a%/*}" && sha256sum -c "${a##*/}.sha256" >/dev/null)
}

@test "F-21: if archiving fails, the account is not deleted" {
    umc user create carol >/dev/null
    mkdir -p "$SB/var/lib/umc"; touch "$SB/var/lib/umc/archive"      # a file where the archive dir should be
    run umc --yes user delete carol
    [ "$status" -ne 0 ]
    contains "nothing was changed"
    grep -q '^carol:' "$SB/etc/passwd"
    [ -d "$SB/home/carol" ]
}

@test "F-10: deleting 'bob' keeps 'bobby' and 'bobcat' in their groups" {
    umc user create bob --groups devs >/dev/null
    [ "$(field group devs 4)" = "bobby,bobcat,bob" ]
    run umc --yes user delete bob --keep-home
    expect 0
    [ "$(field group devs 4)" = "bobby,bobcat" ]
    [ "$(field gshadow devs 4)" = "bobby,bobcat" ]
}

@test "offboard is reversible: lock, strip privileged groups, archive; reinstate restores" {
    umc user create carol --groups docker,users >/dev/null
    run umc user offboard carol --reason "left the company"
    expect 0
    [ "$(field shadow carol 8)" = 1 ]
    [[ $(field group docker 4) != *carol* ]]                 # privileged group removed
    [[ $(field group users 4) == *carol* ]]                  # ordinary group kept
    ls "$SB"/var/lib/umc/archive/carol-*-home-*.tar.gz
    [ -d "$SB/home/carol" ]                                  # nothing deleted
    run umc user reinstate carol
    expect 0
    [[ $(field group docker 4) == *carol* ]]
    [ "$(field shadow carol 8)" = "" ]
}

@test "F-08: SSH keys are written as the user, so a planted symlink cannot redirect them" {
    umc user create carol >/dev/null
    local uid; uid=$(field passwd carol 3)
    mkdir -p "$SB/root/.ssh"; : > "$SB/root/.ssh/authorized_keys"
    mkdir -p "$SB/home/carol/.ssh"; chown "$uid:$uid" "$SB/home/carol/.ssh"
    ln -s "$SB/root/.ssh/authorized_keys" "$SB/home/carol/.ssh/authorized_keys"
    run umc user key add carol "$(new_key carol@laptop)"
    [ "$status" -ne 0 ]
    contains "symbolic link"
    [ ! -s "$SB/root/.ssh/authorized_keys" ]                 # root's file untouched
}

@test "SSH keys: add is idempotent, files are private, remove works" {
    umc user create carol >/dev/null
    local k; k=$(new_key carol@laptop)
    run umc user key add carol "$k"
    expect 0
    run umc user key add carol "$k"
    expect 0
    contains "already present"
    [ "$(grep -c ssh-ed25519 "$SB/home/carol/.ssh/authorized_keys")" = 1 ]
    [ "$(mode_of "$SB/home/carol/.ssh")" = 700 ]
    [ "$(mode_of "$SB/home/carol/.ssh/authorized_keys")" = 600 ]
    run umc user key remove carol "$k"
    expect 0
    ! grep -q ssh-ed25519 "$SB/home/carol/.ssh/authorized_keys"
}

@test "F-27: moving a home keeps parent directories traversable" {
    umc user create carol >/dev/null
    run umc user modify carol --home /srv/people/carol --move-home
    expect 0
    [ -d "$SB/srv/people/carol" ] && [ ! -d "$SB/home/carol" ]
    [ "$(mode_of "$SB/srv/people")" = 755 ]
}

@test "rename carries memberships, the private group and subuid ranges along" {
    umc user create carol --groups devs >/dev/null
    run umc user modify carol --rename caroline
    expect 0
    entry passwd caroline && ! entry passwd carol
    entry group caroline
    [[ $(field group devs 4) == *caroline* ]]
    grep -q '^caroline:' "$SB/etc/subuid"
}

@test "subordinate IDs are allocated without overlap (rootless containers)" {
    umc user create carol >/dev/null
    umc user create dave >/dev/null
    [ "$(grep -c : "$SB/etc/subuid")" = 3 ]
    awk -F: '{ s[NR]=$2; e[NR]=$2+$3 } END { for (i=1;i<=NR;i++) for (j=i+1;j<=NR;j++) if (s[i] < e[j] && s[j] < e[i]) exit 1 }' "$SB/etc/subuid"
}

@test "roles: groups, shell and skeleton come from /etc/umc/roles.d" {
    mkdir -p "$SB/etc/umc/roles.d" "$SB/etc/umc/skel.d/dev"
    printf 'groups = devs,users\nshell = /bin/bash\n' > "$SB/etc/umc/roles.d/dev.conf"
    printf 'dev-only\n' > "$SB/etc/umc/skel.d/dev/.devrc"
    run umc user create carol --role dev
    expect 0
    [ "$(field passwd carol 7)" = /bin/bash ]
    [[ $(field group devs 4) == *carol* ]]
    [ -f "$SB/home/carol/.devrc" ]
}
