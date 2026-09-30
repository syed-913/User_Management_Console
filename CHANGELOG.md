# Changelog

## 2.0.0 (unreleased)

A rewrite of the engine that keeps v1's goals (one file, no
`useradd`/`usermod`/`passwd`, the same console look) and makes them hold.
Security-relevant findings are summarised in
[docs/SECURITY-ADVISORY-v1.md](docs/SECURITY-ADVISORY-v1.md); the design is
explained in [docs/DESIGN.md](docs/DESIGN.md).

### Fixed: findings from the v1 review

| ID | v1 behaviour | Now |
|---|---|---|
| F-01 | account files staged under fixed names in `/tmp` | temp files created with `mktemp` next to the target |
| F-02 | `/etc/passwd`, `/etc/group` left mode `0600` | owner, group, mode, SELinux label preserved |
| F-03 | SELinux label of `/tmp` carried into `/etc` | label copied from the original (`chcon --reference`) |
| F-04 | `mv` across filesystems, no fsync, four separate moves | same-directory rename, fsync file + directory, journal |
| F-05 | new user's GID could belong to an existing group | IDs free as UID *and* GID, NSS-checked |
| F-06 | deleting `bin` ran `rm -rf /bin`; `root` deletable | protected accounts; removals only strictly below allowed home roots |
| F-07 | unlock could leave an empty password field | refused |
| F-08 | SSH keys written as root through user symlinks | written as the user, symlinks refused |
| F-09 | backup after the change; rotation and restore globs never matched | journal with pre/post images; rollback; crash recovery |
| F-10 | removing `bob` rewrote `bobby`/`bobcat`; duplicate members | exact-token membership editing |
| F-11 | `&`, `\|`, `:` in comments corrupted `/etc/passwd` | no `sed` on user data; `:` refused |
| F-12 | IDs from 65535 upwards (counted `nobody`); ignored `login.defs` | `UID_MIN..UID_MAX`, `SYS_*` ranges |
| F-13 | no lock interoperability; lost updates | shadow-utils `.lock` + `lckpwdf` |
| F-14 | lock file truncated before locking; "check locks" misreported itself | lock taken first, PID written after; `umc locks` |
| F-15 | empty password stored as openssl's `<NULL>` | refused; every hash validated before writing |
| F-16 | here-strings (temp files on bash < 5.1); plaintext CSV passwords | pipes only; plaintext refused by default |
| F-17 | policy menu edited `PASS_MIN_LEN` (ignored by PAM) | `pwquality.conf`; `pwscore` when available |
| F-18 | integrity check looked at the last line only, grepped English `pwck` output | full structural validation, blast-radius check |
| F-19 | "lock" did not stop SSH key logins | lock = `!` + account expiry |
| F-20 | orphan cleanup would delete LDAP users' homes | removed; `audit` reports instead; NSS-aware |
| F-21 | home removed before accounts; `tar` errors ignored | archive → verify → commit → remove |
| F-22 | sudoers written unvalidated | `visudo -cf`, atomic, `0440`, revoke, dot-safe names |
| F-23 | Rocky/Alma/Fedora rejected by OS detection | capability detection |
| F-24 | expiry dates a day early east of UTC | all dates UTC |
| F-25 | hard-coded defaults; existing directories adopted | `login.defs` / `/etc/default/useradd`; foreign directories refused |
| F-26 | shells not checked | must be in `/etc/shells` and exist |
| F-27 | moved homes nested; parents created `0700` | refuses existing targets; parents `0755` |
| F-28 | invalid characters silently stripped | rejected with a reason |
| F-29 | audit mixed locked and empty passwords | 24 checks with severities and CIS mapping |
| F-30 | export CSV broke on commas; formula injection | RFC 4180 quoting; formulas neutralised |
| F-31 | logged `$?` of an unrelated command; no actor | journald fields + hash-chained JSONL; `loginuid` |
| F-32 | interactive only; `BASE_DIR` hard-coded; artificial `sleep`s | CLI with exit codes; `--root`; no fake delays |
| F-33 | password rule was an invalid regex outside UTF-8 locales | `LC_ALL=C`; policy from `pwquality.conf` |

### Added

- Command-line interface for every operation, `--json`, `--dry-run`, documented exit codes
- `--root DIR` for offline images, chroots and test fixtures
- Joiner/mover/leaver lifecycle: `offboard`, `reinstate`, `delete`
- Bulk import of any CSV/JSON layout: `import inspect`, `plan`, `apply` (all-or-nothing, idempotent, identity-aware, `--prune`)
- Temporary passwords with an activation deadline, `umc sweep` and its systemd timer
- Roles (`/etc/umc/roles.d`), access rules (`/etc/umc/rules.conf`), import profiles
- `audit` (CIS-mapped), `export` (access review), `policy show|set`
- `history`, `show`, `rollback`, `recover`, `locks`, `log verify`, `doctor`
- Subordinate UID/GID ranges for rootless containers; `pam_faillock` reset on unlock
- Parallel password hashing for SHA-512 and yescrypt; warning (doctor, policy, audit AUD-24) when `login.defs` and PAM use different hash algorithms
- Test-suite (129 tests + 4 VM end-to-end tests), 9-distribution container matrix, evidence reports, CI
- `tests/vagrant/verify.sh`: boots each pinned box, runs everything, removes what it downloaded; six VMs pass (E-16)

### Removed

- `shared/umc.sh` (a copy for the old NFS share; VMs now sync the repository itself)
- `tests/vagrant/smoke.sh` (replaced by `verify.sh --smoke`)
- "Clean orphaned home dirs" (it treated directory-service users' homes as orphans; see F-20)

## 1.0 (tag `v1.0`)

Interactive, menu-driven script editing the account files directly.
