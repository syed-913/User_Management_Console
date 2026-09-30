# E-16 · End-to-end tests in real VMs

| | |
|---|---|
| **Claim** | On real VMs with systemd, sshd, PAM and (on RHEL-family boxes) SELinux in enforcing mode, the full test-suite passes, account files keep their SELinux labels, a UMC lock refuses SSH public-key logins that a "!"-only lock lets through, journald receives structured records, and the sweep timer installs. |
| **Method** | `tests/vagrant/verify.sh libvirt` boots each pinned box, runs `tests/run.sh` inside it with `UMC_E2E=1` (unit, integration, live and end-to-end tests), destroys the VM and removes what the run downloaded. |
| **Environment** | Vagrant 2.4.9 · vagrant-libvirt 0.12.2 · host Ubuntu 24.04.5 LTS · UMC `d570975` · 2026-09-30 |
| **Reproduce** | `tests/vagrant/verify.sh libvirt rhel9 rocky9 alma9 debian12 debian13 ubuntu2204 ubuntu2404` |
| **Verdict** | ✅ PASS |

## Results

| VM | Box | SELinux | Result |
|---|---|---|---|
| rhel9 | `generic/rhel9 4.3.12` | - | skipped: needs a Red Hat subscription (RHSM_USERNAME/RHSM_PASSWORD) |
| rocky9 | `generic/rocky9 4.3.12` | Enforcing | PASS - 133 passed (2 skipped), 0 failed |
| alma9 | `bento/almalinux-9 202508.03.0` | Enforcing | PASS - 133 passed (2 skipped), 0 failed |
| debian12 | `generic/debian12 4.3.12` | - | PASS - 133 passed (2 skipped), 0 failed |
| debian13 | `debian/trixie64 13.20260519.1` | - | PASS - 133 passed (2 skipped), 0 failed |
| ubuntu2204 | `generic/ubuntu2204 4.3.12` | - | PASS - 133 passed (2 skipped), 0 failed |
| ubuntu2404 | `bento/ubuntu-24.04 202508.03.0` | - | PASS - 133 passed (2 skipped), 0 failed |

## End-to-end test lines per VM

### rocky9

```text
ok 130 F-03 / E-16: SELinux labels of the account files stay correct after commits
ok 131 F-19 / E-16: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not
ok 132 journald receives structured records (journalctl UMC_ACTION=...)
ok 133 the onboarding sweep can be installed as a systemd timer
```

### alma9

```text
ok 130 F-03 / E-16: SELinux labels of the account files stay correct after commits
ok 131 F-19 / E-16: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not
ok 132 journald receives structured records (journalctl UMC_ACTION=...)
ok 133 the onboarding sweep can be installed as a systemd timer
```

### debian12

```text
ok 130 F-03 / E-16: SELinux labels of the account files stay correct after commits # skip SELinux is not enforcing here
ok 131 F-19 / E-16: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not
ok 132 journald receives structured records (journalctl UMC_ACTION=...)
ok 133 the onboarding sweep can be installed as a systemd timer
```

### debian13

```text
ok 130 F-03 / E-16: SELinux labels of the account files stay correct after commits # skip SELinux is not enforcing here
ok 131 F-19 / E-16: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not
ok 132 journald receives structured records (journalctl UMC_ACTION=...)
ok 133 the onboarding sweep can be installed as a systemd timer
```

### ubuntu2204

```text
ok 130 F-03 / E-16: SELinux labels of the account files stay correct after commits # skip SELinux is not enforcing here
ok 131 F-19 / E-16: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not
ok 132 journald receives structured records (journalctl UMC_ACTION=...)
ok 133 the onboarding sweep can be installed as a systemd timer
```

### ubuntu2404

```text
ok 130 F-03 / E-16: SELinux labels of the account files stay correct after commits # skip SELinux is not enforcing here
ok 131 F-19 / E-16: a deployed key logs in; a UMC lock refuses it; a '!'-only lock would not
ok 132 journald receives structured records (journalctl UMC_ACTION=...)
ok 133 the onboarding sweep can be installed as a systemd timer
```
