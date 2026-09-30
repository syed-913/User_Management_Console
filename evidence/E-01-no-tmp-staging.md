# E-01 · Account data is never staged in /tmp (fix for F-01)

| | |
|---|---|
| **Claim** | UMC never reads or writes predictable temporary paths: files an unprivileged user plants at the names v1 used are left untouched, and /etc/shadow stays root-owned after every operation. |
| **Method** | An unprivileged user pre-creates /tmp/passwd, /tmp/shadow, /tmp/group and /tmp/gshadow. Root then runs 25 UMC operations. The planted files are compared before/after, and every file created outside /etc, /var, /home and /root during the run is listed. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `9c1a154` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-01` |
| **Verdict** | ✅ PASS |

## Output

```text

## An unprivileged user (tester) plants files at the paths v1 staged account data in
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/group
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/gshadow
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/passwd
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/shadow

## Root runs 25 UMC operations (create, groups, password, lock, unlock, offboard, delete)
exit status of the last operation: 0

## Result
planted files: unchanged
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/group
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/gshadow
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/passwd
-rw-rw-rw- 1 tester tester 8 Sep 30 15:05 /tmp/shadow

owner and mode of the real files:
  /etc/passwd  root:root 644
  /etc/shadow  root:shadow 640
  /etc/group  root:root 644
  /etc/gshadow  root:shadow 640

files created during the run outside /etc, /var, /home, /root, /proc, /run, /sys:
  (none)

Why: UMC creates each replacement file with mktemp in the target's own directory
(/etc/.shadow.umc.XXXXXX: root-owned, mode 0600, created with O_EXCL), then renames it
over the original. Nothing is copied through a shared directory. See docs/SECURITY-ADVISORY-v1.md.
```
