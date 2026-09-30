# E-02 · File ownership and permissions survive a change (v1 F-02 vs v2)

| | |
|---|---|
| **Claim** | v1 left /etc/passwd and /etc/group mode 0600 after the first change, so ordinary users could no longer map UIDs to names; v2 keeps the owner, group and mode of all four files exactly as they were. |
| **Method** | The same "create one user" action is performed with v1 (menu input on stdin) and with v2 in two fresh containers' worth of state; modes are listed and an unprivileged user tries to resolve a name. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `41699b1` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-02` |
| **Verdict** | ✅ PASS |

## Output

```text

## Before
  /etc/passwd  root:root 644
  /etc/shadow  root:shadow 640
  /etc/group  root:root 644
  /etc/gshadow  root:shadow 640

## v1: create user 'v1user' through its menu (1 -> a)
  /etc/passwd  root:root 600
  /etc/shadow  root:root 600
  /etc/group  root:root 600
  /etc/gshadow  root:root 600

$ su tester -c 'id -un; ls -ln /etc/passwd'
id: cannot find name for user ID 1000
1000
  CANNOT resolve user names any more

## Reset /etc, then v2: umc user create v2user
  ✓ user v2user created (uid 1001, gid 1001, home /home/v2user, shell /bin/sh)
  • no password set: log in with an SSH key, or set one with: umc user passwd v2user
  • home directory /home/v2user is ready
  • txn 20260930T124034Z-124-1  ·  undo with: umc rollback 20260930T124034Z-124-1
  /etc/passwd  root:root 644
  /etc/shadow  root:shadow 640
  /etc/group  root:root 644
  /etc/gshadow  root:shadow 640
tester
  can resolve names

## Summary
v1 left /etc/passwd at mode 600; v2 left it at 644 (expected 644)
```
