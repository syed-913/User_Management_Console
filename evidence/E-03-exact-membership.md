# E-03 · Deleting "bob" leaves "bobby" and "bobcat" alone (v1 F-10 vs v2)

| | |
|---|---|
| **Claim** | v1 removed group members with a substring regex, so deleting user bob rewrote bobby to "by" and bobcat to "cat"; v2 edits member lists by exact name. |
| **Method** | Users bob, bobby and bobcat are created with shadow-utils and put into group devs. bob is deleted with v1 (menu input on stdin) and, from the same starting state, with v2. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-03` |
| **Verdict** | ✅ PASS |

## Output

```text

## Before
/etc/group:devs:x:1004:bobby,bob,bobcat
/etc/gshadow:devs:!::bobby,bob,bobcat

## v1: delete user bob (menu 1 -> g)
/etc/group:devs:x:1004:bycat
/etc/gshadow:devs:!::bycat

## Reset, then v2: umc user delete bob
  ! bob was not offboarded first (recommended: umc user offboard bob)
  ✓ user bob deleted (and its private group)
  • txn 20260930T150536Z-154-1  ·  undo with: umc rollback 20260930T150536Z-154-1
/etc/group:devs:x:1004:bobby,bobcat
/etc/gshadow:devs:!::bobby,bobcat

## Summary
v1 result: devs:x:1004:bycat
v2 result: devs:x:1004:bobby,bobcat
```
