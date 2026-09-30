#!/usr/bin/env bats
# Live mode: the container's own /etc, real shadow-utils, real NSS.
# (tests/run.sh refuses to run outside a container or test VM.)
load ../helpers

teardown() { rm -f /tmp/shadow /tmp/passwd; }

@test "live: a new user resolves through NSS (post-commit verification uses getent)" {
    run umc_live user create live.one
    expect 0
    getent passwd live.one
    getent group live.one
}

@test "live F-02: /etc/passwd stays world-readable after a commit" {
    run umc_live user create live.two
    expect 0
    [ "$(mode_of /etc/passwd)" = 644 ]
    su -s /bin/sh tester -c 'id live.two' >/dev/null           # an unprivileged user can resolve names
}

@test "live F-01: a /tmp/shadow planted by an unprivileged user is never touched" {
    setpriv --reuid=tester --regid=tester --clear-groups -- sh -c 'echo trap > /tmp/shadow; chmod 666 /tmp/shadow'
    run umc_live user create live.three
    expect 0
    [ "$(cat /tmp/shadow)" = trap ]
    [ "$(stat -c %u /etc/shadow)" = 0 ]
}

@test "live interop: shadow-utils honours UMC's lock (useradd cannot run while UMC holds it)" {
    # take /etc/passwd.lock exactly the way UMC does, then ask useradd
    run bash -c '
        source "$1"; paths_init; cfg_resolve; CFG[lock_timeout]=5
        lk_hl /etc/passwd
        timeout 20 useradd blocked.user; echo "useradd exit $?"
        lk_release_all' _ "$UMC"
    contains "useradd exit"
    [[ $output != *"useradd exit 0"* ]]
    ! getent passwd blocked.user
}

@test "live F-13: UMC, useradd and chpasswd in parallel - no acknowledged change is lost" {
    local i
    for i in $(seq 1 8); do
        ( umc_live -q user create "par.umc$i" >/dev/null 2>&1 && echo "par.umc$i" >> /tmp/acked ) &
        ( useradd "par.sh$i" >/dev/null 2>&1 && echo "par.sh$i" >> /tmp/acked ) &
    done
    wait
    ( for i in $(seq 1 8); do echo "par.sh$i:Pw-$i-long-enough"; done | chpasswd 2>/dev/null ) &
    for i in $(seq 1 8); do umc_live -q user lock "par.umc$i" >/dev/null 2>&1; done
    wait
    local n
    while read -r n; do
        grep -q "^$n:" /etc/passwd || { echo "LOST passwd entry: $n"; return 1; }
        grep -q "^$n:" /etc/shadow || { echo "LOST shadow entry: $n"; return 1; }
    done < /tmp/acked
    for i in $(seq 1 8); do
        grep -q "^par.umc$i:!" /etc/shadow || { echo "lost lock of par.umc$i"; return 1; }
    done
    rm -f /tmp/acked
    pwck -r -q >/dev/null 2>&1 || [ $? -eq 2 ]            # 2 = warnings only (missing homes of useradd users)
    grpck -r >/dev/null
}

@test "live: shadow-utils tools accept everything UMC wrote (pwck/grpck)" {
    umc_live user create live.four --groups users >/dev/null
    umc_live group create live.grp >/dev/null
    umc_live group add-member live.grp live.four >/dev/null
    run grpck -r
    expect 0
    run pwck -r -q
    [[ $status -eq 0 || $status -eq 2 ]]
    ! grep -Eq 'invalid|duplicate' <<< "$output"
}

@test "live: the system password policy (pwscore) is used when installed" {
    command -v pwscore >/dev/null || skip "pwscore not installed on this image"
    umc_live user create live.five >/dev/null
    run bash -c 'printf "password\n" | "$1" --no-color user passwd live.five --password-stdin' _ "$UMC"
    expect 3
    contains "pwquality"
}

@test "live: --install-timer needs systemd and says so" {
    [ -d /run/systemd/system ] && skip "systemd is running here"
    run umc_live sweep --install-timer
    expect 1
    contains "cron"
}

@test "live: doctor reports capabilities without needing any optional tool" {
    run umc_live doctor
    expect 0
    contains "lckpwdf interop"
    contains "script integrity"
}
