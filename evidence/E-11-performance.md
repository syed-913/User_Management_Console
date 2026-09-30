# E-11 · Bulk performance - 1,000 users

| | |
|---|---|
| **Claim** | Creating 1,000 users with home directories and hashed passwords from one CSV is faster with "umc apply" than with a useradd loop or shadow-utils' newusers - while also being one validated, journaled, reversible transaction. |
| **Method** | Three runs on identical fresh /etc copies in the same container: (a) umc apply of a 1,000-row CSV (temporary passwords generated and SHA-512 hashed, homes created); (b) a loop of useradd -m plus one chpasswd; (c) newusers. Wall-clock time is measured with bash's time; for each method the number of users, of users that really have a password hash, and of home directories is counted, so no method gets credit for work it skipped. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `41699b1` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-11` |
| **Verdict** | ✅ PASS |

## Output

```text
method                                          seconds   users   hashed  homes
umc apply (1 transaction, validated, journaled)    5.176    1000     1000   1000
useradd -m loop + chpasswd -c SHA512             20.815    1000     1000   1000
newusers (shadow-utils batch tool)               17.047    1000     1000   1000

Why UMC is fast: one lock, one pass over each file, one openssl process per CPU
core for all hashes, and one NSS lookup for all new IDs. useradd rewrites all four
files for every single user. newusers is not idempotent, has no dry run, rollback or journal.
```
