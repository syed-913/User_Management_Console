# E-09 · Rollback restores the account files byte-for-byte

| | |
|---|---|
| **Claim** | "umc rollback" puts the four account files back exactly as they were before a transaction - verified with SHA-256 - and lists what it does not revert (home directories). |
| **Method** | 50 users are bulk-created in one transaction; the transaction is rolled back; checksums before and after are compared. Then the rollback itself is rolled back. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-09` |
| **Verdict** | ✅ PASS |

## Output

```text

$ sha256 of passwd, shadow, group, gshadow before
9a018fadcbe94aaa5ee321eea223ea0cab9097695f7d3658b13f9d5da05d2ad8
28a745c4a863a7a42e79d2cf28c2f934210603891b7d0dfa294d202e61b12b17
fba8bb452c66b84a9668a1c2214749dc74d04de836ea6243fc0f107b23a37ef5
fee3a91e50690da8c9a3c03b7c789566cf3fa36b3985fe34bb5813dc9b64292a

users now: 50

$ umc rollback --last
  ✓ rolled back 20260930T151015Z-44-1: the account files are exactly as they were before it
  ! not reverted (outside the account files): homes:50
  • txn 20260930T151016Z-502-1  ·  undo with: umc rollback 20260930T151016Z-502-1

$ sha256 after rollback
9a018fadcbe94aaa5ee321eea223ea0cab9097695f7d3658b13f9d5da05d2ad8
28a745c4a863a7a42e79d2cf28c2f934210603891b7d0dfa294d202e61b12b17
fba8bb452c66b84a9668a1c2214749dc74d04de836ea6243fc0f107b23a37ef5
fee3a91e50690da8c9a3c03b7c789566cf3fa36b3985fe34bb5813dc9b64292a
=> identical

$ umc rollback --last   (undo the undo)
users now: 50

$ umc history
  TXN                          TIME                 ACTOR      ACTION           STATE       SUMMARY
  20260930T151016Z-696-1       2026-09-30 15:10:16Z root       txn.rollback     committed   rollback of 20260930T151016Z-502-1
  20260930T151016Z-502-1       2026-09-30 15:10:16Z root       txn.rollback     rolled-back-by-20260930T151016Z-696-1 rollback of 20260930T151015Z-44-1
  20260930T151015Z-44-1        2026-09-30 15:10:15Z root       apply            rolled-back-by-20260930T151016Z-502-1 apply 50.csv: 50 to add, 0 to change, 0 to offboard
```
