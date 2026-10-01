# E-07 · No lost updates next to useradd and PAM (chpasswd)

| | |
|---|---|
| **Claim** | UMC takes both locking conventions (shadow-utils FILE.lock and lckpwdf's /etc/.pwd.lock), so running it at the same time as useradd and chpasswd never loses a change that any tool reported as successful. |
| **Method** | 3 rounds. In each: 20 "umc user create", 20 "useradd" and a "chpasswd" for the useradd users run concurrently, then 20 "umc user lock" run next to another chpasswd. Afterwards every acknowledged user must exist in passwd AND shadow, every UMC lock must be in place, and every chpasswd password must be set. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-07` |
| **Verdict** | ✅ PASS |

## Output

```text
lckpwdf method on this host:yes (fcntl via perl; this util-linux has no flock --fcntl)
round 1: 61 acknowledged operations checked
round 2: 61 acknowledged operations checked
round 3: 61 acknowledged operations checked

acknowledged operations: 183
lost updates:            0

$ grpck -r (shadow-utils' own consistency check)
  clean
```
