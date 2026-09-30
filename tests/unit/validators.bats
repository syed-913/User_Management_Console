#!/usr/bin/env bats
# Pure functions: validators, list handling, passwords, dates. No root tree is
# modified here; a sandbox only provides login.defs/pwquality.conf values.
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

@test "user names: first.last is accepted" {
    run ufn 'val_name "$1" && echo OK' alice.khan
    expect 0; [ "$output" = OK ]
}

@test "F-28: unsafe user names are rejected with a reason, never silently changed" {
    local bad
    for bad in "" "-rf" "12345" "." ".." "Alice" "a:b" "a b" "bob;id" "$(printf 'x%.0s' {1..40})"; do
        run ufn 'val_name "$1" || echo "REJECTED: $VAL_ERR"' "$bad"
        [[ $output == REJECTED:* ]] || { echo "accepted '$bad': $output"; return 1; }
    done
}

@test "comments may contain & and commas but not ':' or control characters (F-11)" {
    run ufn 'val_gecos "$1" && echo OK' 'R&D Team, Room 4'
    [ "$output" = OK ]
    run ufn 'val_gecos "$1" || echo "NO: $VAL_ERR"' 'Ops: team'
    contains "NO:"
    run ufn 'val_gecos "$1" || echo "NO: $VAL_ERR"' $'two\nlines'
    contains "control characters"
}

@test "paths are normalised; '..' and relative paths are refused" {
    run ufn 'val_path "$1" && echo "$REPLY"' '/home//alice/./x/'
    [ "$output" = /home/alice/x ]
    run ufn 'val_path "$1" || echo "NO"' '/home/../etc'
    [ "$output" = NO ]
    run ufn 'val_path "$1" || echo "NO"' 'home/alice'
    [ "$output" = NO ]
}

@test "F-24: dates are converted in UTC (2026-12-31 is day 20818 everywhere)" {
    run env TZ=Asia/Karachi bash -c 'source "$1"; OPT_ROOT=$2; paths_init; val_date 2026-12-31; echo $REPLY' _ "$UMC" "$SB"
    [ "$output" = 20818 ]
}

@test "dates: impossible calendar dates, 'never' and +DAYS" {
    run ufn 'val_date 2026-02-30 || echo "NO: $VAL_ERR"'
    contains "not a valid calendar date"
    run ufn 'val_date never && echo "[$REPLY]"'
    [ "$output" = "[]" ]
    run ufn 'val_date +10 && echo $REPLY'
    [ "$output" -eq $(( $(today) + 10 )) ]
}

@test "SSH keys: a real key passes; options, DSA and garbage are refused" {
    local k; k=$(new_key alice@laptop)
    run ufn 'val_sshkey "$1" && echo OK' "$k"
    expect 0; [ "$output" = OK ]
    run ufn 'val_sshkey "$1" || echo "NO: $VAL_ERR"' "command=\"/bin/sh\" $k"
    contains "not a supported"
    run ufn 'val_sshkey "$1" || echo "NO: $VAL_ERR"' "ssh-dss AAAAB3NzaC1kc3MAAACBAP$(printf 'A%.0s' {1..80})"
    contains "DSA"
    run ufn 'val_sshkey "$1" || echo "NO: $VAL_ERR"' "ssh-ed25519 not-base64!!"
    contains "NO:"
}

@test "pre-computed hashes: SHA-512/yescrypt accepted, MD5 refused" {
    run ufn 'val_hash "$1" && echo OK' '$6$salt$abcdefghijklmnopqrstuvwxyz'
    [ "$output" = OK ]
    run ufn 'val_hash "$1" || echo "NO: $VAL_ERR"' '$1$salt$abcdef'
    contains "MD5"
}

@test "F-10: removing 'bob' from a member list never touches 'bobby' or 'bobcat'" {
    run ufn 'list_del "bobby,bob,bobcat" bob; echo "$REPLY"'
    [ "$output" = "bobby,bobcat" ]
    run ufn 'list_del "bob,bobby" bob; echo "$REPLY"'
    [ "$output" = "bobby" ]
}

@test "F-10: adding a member twice keeps one copy (idempotent)" {
    run ufn 'list_add "alice" bob; list_add "$REPLY" bob; echo "$REPLY"'
    [ "$output" = "alice,bob" ]
}

@test "field splitting keeps empty and trailing fields" {
    run ufn 'split_fields "a::c:"; echo "${#F[@]}|${F[1]}|${F[3]}"'
    [ "$output" = "4||" ]
}

@test "password states: empty, none, locked, set" {
    run ufn 'for h in "" "!" "!!" "*" "!\$6\$x" "\$6\$x"; do pw_state "$h"; printf "%s " "$REPLY"; done'
    [ "$output" = "empty none none none locked set " ]
}

@test "temporary passwords: unique, readable, no look-alike characters" {
    run ufn 'pw_generate_many 200; printf "%s\n" "${GEN[@]}"'
    expect 0
    [ "$(printf '%s\n' "$output" | sort -u | wc -l)" -eq 200 ]
    ! grep -q '[0O1lI]' <<< "$output"
    while IFS= read -r p; do
        [[ $p =~ ^[A-Za-z2-9]{4}-[A-Za-z2-9]{4}-[A-Za-z2-9]{4}$ ]] || { echo "bad format: $p"; return 1; }
        [[ $p == *[a-z]* && $p == *[A-Z]* && $p == *[2-9]* ]] || { echo "missing a class: $p"; return 1; }
    done <<< "$output"
}

@test "password policy (pwquality.conf minlen=10 minclass=3) is enforced natively" {
    run ufn 'LIVE=false; pw_check "$1" alice || echo "NO: $VAL_ERR"' 'Short1!'
    contains "at least 10"
    run ufn 'LIVE=false; pw_check "$1" alice || echo "NO: $VAL_ERR"' 'alllowercaseletters'
    contains "mix at least 3"
    run ufn 'LIVE=false; pw_check "$1" alice || echo "NO: $VAL_ERR"' 'Xalice-2026!'
    contains "user name"
    run ufn 'LIVE=false; pw_check "$1" alice && echo OK' 'Tr0ub4dor&3-horse'
    [ "$output" = OK ]
}

@test "F-15: an empty password is refused before anything is hashed" {
    run ufn 'LIVE=false; pw_check "" alice || echo "NO: $VAL_ERR"'
    contains "empty"
}

@test "hashing: one openssl batch yields valid SHA-512 hashes in order" {
    run ufn 'PW_IN=(one two three); pw_hash_many; printf "%s\n" "${PW_OUT[@]}"'
    expect 0
    [ "$(wc -l <<< "$output")" -eq 3 ]
    while IFS= read -r h; do [[ $h == '$6$'* ]] || return 1; done <<< "$output"
}
