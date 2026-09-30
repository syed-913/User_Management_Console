# E-15 · Temporary passwords expire if not changed in time

| | |
|---|---|
| **Claim** | A generated temporary password must be changed within the deadline (24 h by default). "umc sweep" locks accounts that miss it and erases their credential-slip entries; accounts whose user changed the password are activated. A shadow expiry date is a backstop even if the sweep never runs. |
| **Method** | Two users get temporary passwords. One "changes" it (last-change date updated). The sweep runs with a simulated clock (UMC_NOW, honoured only in --root sandboxes) one minute before and one minute after the deadline. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `9c1a154` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-15` |
| **Verdict** | ✅ PASS |

## Output

```text
deadline: 2026-10-01 15:13:43 UTC

$ shadow (lastchg=0 forces a change at first login; field 8 is the backstop expiry day)
early.bird:0:20728
late.comer:0:20728

$ credential slip (root-only, 0600) - passwords masked here
total 8
-rw------- 1 root root 103 Sep 30 15:13 20260930T151343Z-242-1.csv
-rw------- 1 root root 103 Sep 30 15:13 20260930T151343Z-39-1.csv
username,temporary_password,must_change_by,full_name
late.comer,****-****-****,2026-10-01 15:13 UTC,""
username,temporary_password,must_change_by,full_name
early.bird,****-****-****,2026-10-01 15:13 UTC,""

$ UMC_NOW=deadline-60s umc sweep
  ✓ activated (password changed): early.bird
  • txn 20260930T151344Z-470-1  ·  undo with: umc rollback 20260930T151344Z-470-1

$ UMC_NOW=deadline+60s umc sweep
  ! locked, temporary password not changed in time: late.comer (reissue with: umc user passwd NAME --generate)
  • txn 20260930T151344Z-573-1  ·  undo with: umc rollback 20260930T151344Z-573-1

$ umc user show late.comer
    password           locked
    locked             password locked, account expired
    expires            1970-01-02 (EXPIRED)
    password changed   must change at next login

$ ls root/umc/credentials   (the slip is shredded once every entry is resolved)
```
