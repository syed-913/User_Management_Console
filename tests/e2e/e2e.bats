#!/usr/bin/env bats
# VM-only end-to-end tests (UMC_E2E=1): SELinux, a real sshd login, journald,
# systemd. Run with: vagrant provision NAME --provision-with test
load ../helpers

setup_file() {
    export KEY=/root/.umc-e2e-key
    [[ -f $KEY ]] || ssh-keygen -q -t ed25519 -N '' -C e2e -f "$KEY"
}
ssh_as() { ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$1@127.0.0.1" true 2>/dev/null; }

@test "F-03 / E-16: SELinux labels of the account files stay correct after commits" {
    command -v getenforce >/dev/null && [ "$(getenforce)" = Enforcing ] || skip "SELinux is not enforcing here"
    umc_live user create e2e.selinux >/dev/null
    umc_live user lock e2e.selinux >/dev/null
    run restorecon -n -v /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/passwd- /etc/shadow-
    [ -z "$output" ]                                            # nothing would be relabelled
    [[ $(stat -c %C /etc/shadow) == *:shadow_t:* ]]
    [[ $(stat -c %C /etc/passwd) == *:passwd_file_t:* ]]
    [[ $(stat -c %C /home/e2e.selinux) == *:user_home_dir_t:* ]]
    umc_live --yes user delete e2e.selinux >/dev/null
}

@test "E-17: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not" {
    umc_live user create e2e.ssh --ssh-key "@$KEY.pub" >/dev/null
    ssh_as e2e.ssh                                               # works
    sed -i 's/^e2e.ssh:!/e2e.ssh:!!/' /etc/shadow               # the old-style lock: password only
    ssh_as e2e.ssh                                               # ...SSH keys still get in (v1: F-19)
    umc_live user lock e2e.ssh >/dev/null                        # UMC: password + account expiry
    ! ssh_as e2e.ssh
    umc_live user unlock e2e.ssh >/dev/null
    ssh_as e2e.ssh
    umc_live --yes user delete e2e.ssh >/dev/null
}

@test "journald receives structured records (journalctl UMC_ACTION=...)" {
    [ -S /run/systemd/journal/socket ] || skip "no journald"
    umc_live user create e2e.journal >/dev/null
    sleep 1
    run journalctl -q --no-pager -o cat UMC_ACTION=user.create UMC_TARGET=e2e.journal
    contains "e2e.journal"
    umc_live --yes user delete e2e.journal >/dev/null
}

@test "the onboarding sweep can be installed as a systemd timer" {
    [ -d /run/systemd/system ] || skip "no systemd"
    run umc_live sweep --install-timer
    expect 0
    systemctl is-active umc-sweep.timer
}
