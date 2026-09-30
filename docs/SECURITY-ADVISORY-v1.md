# Security advisory: UMC v1.0

| | |
|---|---|
| **Affected** | UMC v1.0 (git tag `v1.0`, commit `13e7ef0`) when pointed at a real `/etc` (`BASE_DIR="/"`) |
| **Fixed in** | UMC v2.0.0 |
| **Found by** | a self-review of v1 before the v2 rewrite (September 2026) |
| **Action** | Do not use v1. Upgrade to v2. |

The v1 script as published operated on a sandbox (`BASE_DIR="/home/vagrant"`),
so the most severe issues only apply once that variable points at `/`, which is
what the tool was built to do. They are published here because documenting and
fixing your own bugs is part of the project.

This advisory describes causes and impact only. It deliberately contains no
step-by-step exploitation instructions.

## Summary

| ID | Severity | Issue | CWE | v2 fix | Regression test / evidence |
|---|---|---|---|---|---|
| F-01 | Critical | Account databases were staged in `/tmp` under fixed names (`/tmp/shadow` …). A local user who creates those files first ends up owning the file that is later moved into place as `/etc/shadow` | CWE-377, CWE-379 | Replacement files are created with `mktemp` **in the target directory** (root-owned, `0600`, `O_EXCL`) and renamed over the original | `tests/integration/engine.bats` "F-01", `tests/live/live.bats`, [E-01](../evidence/E-01-no-tmp-staging.md) |
| F-02 | Critical | After the first change, `/etc/passwd` and `/etc/group` were mode `0600` (umask + `cp` + `chmod 600`), breaking name resolution for every non-root process | CWE-732 | Owner, group, mode and SELinux label are copied from the original file | "F-02" tests, [E-02](../evidence/E-02-file-permissions.md) |
| F-05 | High | A new user's GID was set equal to its UID without checking `/etc/group`, so a new account could inherit an existing group's privileges (e.g. `docker`) | CWE-269 | IDs must be free as UID **and** GID, inside `login.defs` ranges, and unknown to NSS | "F-05" test, [E-04](../evidence/E-04-id-allocation.md) |
| F-06 | High | Deleting a system account ran `rm -rf` on its home, e.g. `/bin` for user `bin`; `root` could be deleted | CWE-22 | UID-0, system, protected and last-admin accounts are refused; homes are removed only strictly below allowed roots, if owned by the user, never across mount points | "F-06" test |
| F-07 | High | Unlocking an account whose hash was just `!` produced an **empty** password field | CWE-521 | Unlock never produces an empty field | "F-07" test |
| F-08 | High | SSH keys were written as root inside a user-controlled directory, following symbolic links | CWE-59 | Writes inside home directories run **as the user** (`setpriv`) and refuse symbolic links | "F-08" test |
| F-13 | High | No interoperable locking; files were read before any lock was taken, so concurrent `useradd`/`passwd` changes could be silently lost | CWE-362 | shadow-utils `.lock` protocol + `lckpwdf` (`/etc/.pwd.lock`), taken before reading | "F-13" tests, [E-07](../evidence/E-07-concurrency.md) |
| F-16 | Medium | Passwords passed through here-strings (disk-backed temp files in bash < 5.1), plaintext passwords in CSV | CWE-312 | Secrets only via pipes and variables; plaintext passwords in files refused by default | unit tests |
| F-19 | Medium | "Lock" only prefixed `!`, which does not stop SSH public-key logins | CWE-284 | Lock = `!` **and** account expiry | "F-19" test, audit check AUD-13 |
| F-22 | Medium | sudoers files written without `visudo -c`; a malformed file disables sudo for everyone | CWE-20 | Every rule is validated with `visudo -cf` and installed atomically, `0440` | "F-22" tests |
| F-33 | Low | The password-strength rule was an invalid regular expression outside UTF-8 collation locales (`grep: Invalid range end`), so user creation failed in the C locale | CWE-185 | `LC_ALL=C` pinned; policy read from `pwquality.conf`; no locale-dependent ranges | unit tests |

The full list of 33 v1 findings, including the functional ones (corrupted
group memberships, broken rollback, off-by-one dates…), is in
[`CHANGELOG.md`](../CHANGELOG.md).

## Root cause, in one sentence

v1 treated "copy to `/tmp`, edit with `sed`, `mv` back" as atomic and safe. It
is neither: the copy crosses a shared, world-writable directory, `mv` across
filesystems is copy-and-delete, text substitution is not field editing, and
without the locks other tools use, "atomic" says nothing about concurrency.
v2's design (see [DESIGN.md](DESIGN.md)) follows shadow-utils' own
`lib/commonio.c` instead.
