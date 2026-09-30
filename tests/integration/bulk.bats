#!/usr/bin/env bats
# Bulk import: any CSV/JSON layout -> inspect -> plan -> apply (all-or-nothing,
# idempotent, identity-aware).
load ../helpers

IMP=$(cd -- "$BATS_TEST_DIRNAME/../fixtures/imports" && pwd)

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

@test "inspect explains a semicolon CSV with BOM, CRLF and HR column names" {
    run umc import inspect "$IMP/hr_export_semicolon.csv"
    expect 0
    contains "semicolon"
    contains "UTF-8 with BOM"
    contains "CRLF"
    contains '"E-Mail"'
    contains "-> email"
    contains '"Manager"'
    contains "ignored"
}

@test "plan shows every change and writes nothing" {
    local before; before=$(sha "$SB"/etc/*)
    run umc plan -f "$IMP/hr_export_semicolon.csv"
    expect 0
    contains "+ user  alice.khan"
    contains "+ user  jose.nunez"
    contains "(created locked)"
    contains "4 to add"
    [ "$(sha "$SB"/etc/*)" = "$before" ]
}

@test "apply creates the users with temporary passwords, deadlines and a credential slip" {
    run umc --yes apply -f "$IMP/hr_export_semicolon.csv"
    expect 0
    entry passwd alice.khan
    [ "$(field shadow alice.khan 3)" = 0 ]                      # must change at first login
    [ -n "$(field shadow alice.khan 8)" ]                        # deadline backstop
    [ -f "$SB/var/lib/umc/onboarding/alice.khan" ]
    local slip; slip=$(ls "$SB"/root/umc/credentials/*.csv)
    [ "$(mode_of "$slip")" = 600 ]
    [ "$(grep -c , "$slip")" = 5 ]                               # header + 4 users
    [[ $(field shadow chen.wei 2) == '!'* ]]                     # "On leave" -> locked
    ! entry passwd omar.farooq                                   # "Terminated", never had an account
}

@test "apply is idempotent: the same file again changes nothing" {
    umc --yes apply -f "$IMP/hr_export_semicolon.csv" >/dev/null
    local before; before=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
    run umc --yes apply -f "$IMP/hr_export_semicolon.csv"
    expect 0
    contains "already matches"
    [ "$(sha "$SB"/etc/{passwd,shadow,group,gshadow})" = "$before" ]
}

@test "a nested JSON export is understood (records under data.employees)" {
    run umc --yes apply -f "$IMP/hr_api_nested.json" --create-groups
    expect 0
    entry passwd priya.sharma
    entry passwd lars.o
    ! entry passwd ana.lima                                      # active: false
}

@test "native manifest: groups with fixed GIDs, key-only users, +DAYS expiry" {
    run umc --yes apply -f "$IMP/team_manifest.json"
    expect 0
    [ "$(field group developers 3)" = 3000 ]
    [ "$(field shadow dev.one 2)" = '!' ]                        # key-only: no password at all
    grep -q ssh-ed25519 "$SB/home/dev.one/.ssh/authorized_keys"
    [[ $(field group support 4) == *dev.two* ]]
    [ -n "$(field shadow contractor 8)" ]
}

@test "all-or-nothing: one bad row blocks the whole file" {
    printf 'username,email,expire\ngood.one,good@example.com,2027-01-01\nbad row,bad@example.com,2027-13-45\n' > "$SB/bad.csv"
    local before; before=$(sha "$SB"/etc/passwd)
    run umc --yes apply -f "$SB/bad.csv"
    expect 3
    contains "all-or-nothing"
    contains "row 3"
    [ "$(sha "$SB"/etc/passwd)" = "$before" ]
}

@test "--skip-invalid applies the good rows and writes a rejects report" {
    printf 'username,email\ngood.one,good@example.com\nBad Row,bad@example.com\n' > "$SB/mixed.csv"
    run umc --yes apply -f "$SB/mixed.csv" --skip-invalid
    expect 0
    entry passwd good.one
    [ -f "$SB/mixed.rejects.txt" ]
    grep -q 'row 3' "$SB/mixed.rejects.txt"
}

@test "plain-text passwords in a file are refused unless explicitly allowed" {
    printf 'username,password\nx.user,Secret123!\n' > "$SB/pw.csv"
    run umc --yes apply -f "$SB/pw.csv"
    expect 3
    contains "plain-text password"
}

@test "identity: the same employee id keeps the same account even if the name changes" {
    printf 'employee_id,first_name,last_name\n77,Maria,Silva\n' > "$SB/v1.csv"
    umc --yes apply -f "$SB/v1.csv" >/dev/null
    printf 'employee_id,first_name,last_name,shell\n77,Maria,Costa,/bin/bash\n' > "$SB/v2.csv"
    run umc --yes apply -f "$SB/v2.csv"
    expect 0
    entry passwd maria.silva
    ! entry passwd maria.costa
    [ "$(field passwd maria.silva 7)" = /bin/bash ]
}

@test "two different people with the same name get distinct accounts" {
    printf 'employee_id,first_name,last_name\n1,Sam,Lee\n2,Sam,Lee\n' > "$SB/twins.csv"
    run umc --yes apply -f "$SB/twins.csv"
    expect 0
    entry passwd sam.lee && entry passwd sam.lee2
}

@test "status Terminated offboards an existing account; --prune only touches UMC's accounts" {
    printf 'employee_id,username\n5,keep.me\n6,leave.me\n' > "$SB/a.csv"
    umc --yes apply -f "$SB/a.csv" >/dev/null
    printf 'employee_id,username,status\n5,keep.me,Active\n6,leave.me,Terminated\n' > "$SB/b.csv"
    run umc --yes apply -f "$SB/b.csv"
    expect 0
    [ -f "$SB/var/lib/umc/offboarded/leave.me" ]
    printf 'employee_id,username\n6,leave.me\n' > "$SB/c.csv"
    run umc --yes apply -f "$SB/c.csv" --prune
    expect 0
    [ -f "$SB/var/lib/umc/offboarded/keep.me" ]                 # UMC-managed and missing -> offboarded
    [ ! -f "$SB/var/lib/umc/offboarded/bobby" ]                 # never managed by UMC -> untouched
    [ "$(field shadow bobby 8)" = "" ]
}

@test "unknown groups block the import unless --create-groups is given" {
    printf 'username,groups\nnew.one,analysts\n' > "$SB/g.csv"
    run umc --yes apply -f "$SB/g.csv"
    expect 3
    contains "groups that do not exist: analysts"
    run umc --yes apply -f "$SB/g.csv" --create-groups
    expect 0
    [[ $(field group analysts 4) == *new.one* ]]
}

@test "a UTF-16 (Excel 'Unicode Text') export is converted" {
    printf 'username\tfirst_name\r\nutf.user\tZoë\r\n' | iconv -f UTF-8 -t UTF-16 > "$SB/u16.txt"
    run umc import inspect "$SB/u16.txt"
    expect 0
    contains "UTF-16"
    contains "tab"
}

@test "rules.conf turns HR attributes into access (birthright groups)" {
    mkdir -p "$SB/etc/umc"
    printf 'department=engineering -> groups=devs\ntitle=*manager* -> groups=users\n' > "$SB/etc/umc/rules.conf"
    printf 'username,department,title\neng.one,Engineering,Engineer\nmgr.one,Sales,Account Manager\n' > "$SB/r.csv"
    run umc --yes apply -f "$SB/r.csv"
    expect 0
    [[ $(field group devs 4) == *eng.one* ]]
    [[ $(field group users 4) == *mgr.one* ]]
}

@test "mover: groups granted by an earlier import are revoked when the rules no longer apply" {
    mkdir -p "$SB/etc/umc"
    printf 'department=engineering -> groups=devs\n' > "$SB/etc/umc/rules.conf"
    printf 'employee_id,username,department\n9,mover.one,Engineering\n' > "$SB/m1.csv"
    umc --yes apply -f "$SB/m1.csv" >/dev/null
    umc group add-member users mover.one >/dev/null              # granted by hand, not by UMC
    printf 'employee_id,username,department\n9,mover.one,Sales\n' > "$SB/m2.csv"
    run umc --yes apply -f "$SB/m2.csv"
    expect 0
    [[ $(field group devs 4) != *mover.one* ]]                  # revoked (UMC granted it)
    [[ $(field group users 4) == *mover.one* ]]                 # kept (UMC did not grant it)
}

@test "import profiles: --map, --save-profile and --profile" {
    printf 'Login ID;Nome\nx.person;Pessoa X\n' > "$SB/p.csv"
    run umc import inspect "$SB/p.csv" --map 'Login ID=username' --map 'Nome=full_name' --save-profile hr
    expect 0
    [ -f "$SB/etc/umc/import-profiles/hr.map" ]
    run umc --yes apply -f "$SB/p.csv" --profile hr
    expect 0
    [ "$(field passwd x.person 5)" = "Pessoa X" ]
}
