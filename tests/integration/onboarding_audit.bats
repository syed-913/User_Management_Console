#!/usr/bin/env bats
# Temporary passwords with a deadline (sweep), compliance audit, export, policy.
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

@test "temporary password: forced change, deadline record, root-only slip" {
    run umc user create carol --generate-password
    expect 0
    [ "$(field shadow carol 3)" = 0 ]
    local dl; dl=$(st_field onboarding carol deadline)
    (( dl > $(date +%s) + 86000 && dl <= $(date +%s) + 86400 ))
    [ "$(field shadow carol 8)" = $(( dl / 86400 + 1 )) ]       # backstop: the day after the deadline
    [ "$(mode_of "$SB/root/umc/credentials")" = 700 ]
    [[ $output != *"-"????-* ]] || [[ $output == *"credentials"* ]]  # not printed unless --show-password
}

@test "sweep: not changed by the deadline -> locked, and the slip entry is destroyed" {
    umc user create carol --generate-password >/dev/null
    local dl; dl=$(st_field onboarding carol deadline)
    run env UMC_NOW=$((dl - 60)) "$UMC" --no-color --root "$SB" sweep
    expect 0
    contains "no onboarding deadlines"
    run env UMC_NOW=$((dl + 60)) "$UMC" --no-color --root "$SB" sweep
    expect 0
    contains "not changed in time: carol"
    [[ $(field shadow carol 2) == '!'* ]] && [ "$(field shadow carol 8)" = 1 ]
    ! st_row onboarding carol
    ! grep -qs '^carol,' "$SB"/root/umc/credentials/*.csv
}

@test "sweep: a changed password activates the account and restores the real expiry" {
    umc user create carol --generate-password --expire 2030-01-01 >/dev/null
    local lc; lc=$(today)
    sed -i "s/^carol:\\([^:]*\\):0:/carol:\\1:$lc:/" "$SB/etc/shadow"   # the user changed it
    run umc sweep
    expect 0
    contains "activated"
    [ "$(field shadow carol 8)" = 21915 ]                            # 2030-01-01
    ! st_row onboarding carol
}

@test "UMC_NOW is ignored on a live system (it only exists for sandbox tests)" {
    run ufn 'LIVE=true; UMC_NOW=0; now_epoch; echo $REPLY'
    (( output > 1700000000 ))
}

@test "audit: a clean fixture has no critical or high findings" {
    run umc audit --fail-on high
    expect 0
}

@test "audit: seeded problems are found, mapped to CIS, and --fail-on returns 10" {
    printf 'toor:x:0:0::/root:/bin/bash\n' >> "$SB/etc/passwd"
    printf 'toor::20000:0:99999:7:::\n' >> "$SB/etc/shadow"
    chmod 666 "$SB/etc/group"
    run umc audit
    expect 0
    contains "AUD-01"
    contains "Ensure root is the only UID 0 account"
    contains "AUD-02"
    contains "AUD-10"
    run umc audit --fail-on critical
    expect 10
}

@test "AUD-13: a '!'-locked account that still has SSH keys is reported" {
    umc user create carol >/dev/null
    umc user key add carol "$(new_key)" >/dev/null
    sed -i 's/^carol:!:/carol:!$6$x:/' "$SB/etc/shadow"      # locked the old way, no expiry
    run umc audit
    contains "AUD-13"
    contains "still allows key logins"
    umc user lock carol >/dev/null                            # UMC's lock adds the expiry
    run umc audit
    [[ $output == *"PASS  AUD-13"* ]]
}

@test "audit --json is valid and complete" {
    run umc audit --json
    expect 0
    [[ $output == '{"ok":true,"summary":'* ]]
    [ "$(grep -o '"id":"AUD-' <<< "$output" | wc -l)" -ge 23 ]
}

@test "export: an access-review CSV with one row per human account" {
    umc user create carol --comment "=HYPERLINK(evil)" >/dev/null
    run umc export
    expect 0
    [[ $(head -1 <<< "$output") == username,uid,gid,* ]]
    contains "'=HYPERLINK(evil)"                              # neutralised formula
    [ "$(grep -c '^carol,' <<< "$output")" = 1 ]
    ! grep -q '^daemon,' <<< "$output"
}

@test "policy: set updates pwquality.conf and login.defs; PASS_MIN_LEN is explained" {
    printf 'PASS_MIN_LEN 5\n' >> "$SB/etc/login.defs"
    run umc policy show
    contains "PAM ignores it"
    run umc policy set --min-length 14 --max-days 90 --apply-to-existing
    expect 0
    grep -q '^minlen = 14' "$SB/etc/security/pwquality.conf"
    grep -qE '^PASS_MAX_DAYS[[:space:]]+90' "$SB/etc/login.defs"
    [ "$(field shadow bobby 5)" = 90 ]
    [ "$(field shadow root 5)" = 99999 ]                       # system accounts untouched
}
