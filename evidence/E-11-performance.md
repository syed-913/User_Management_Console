# E-11 · Bulk performance - 1,000 users, compared like with like

| | |
|---|---|
| **Claim** | With the same hashing algorithm on both sides and all CPU cores available, "umc apply" creates 1,000 users (password hash and home directory each) faster than a useradd loop and than newusers, because it pays its fixed costs once per batch and hashes in parallel. Limits, measured below too: on one core UMC stays ahead of the useradd loop but newusers is faster with yescrypt (UMC starts one mkpasswd per hash), and for a single user useradd is much faster. |
| **Method** | Every run starts from the same fresh /etc in the same container. Each 1,000-user method runs once on all CPU cores and once pinned to one core (taskset). The algorithm column is read from the hashes actually written, and users, hashes and home directories are counted, so no method gets credit for work it skipped. Single user: average of 20 runs. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-11` |
| **Verdict** | ✅ PASS |

## Output

```text
method (1,000 users)                         cores hash       seconds  users hashed  homes
--- same algorithm: SHA-512
umc apply                                    12    SHA-512      5.073   1000   1000   1000
umc apply                                    1     SHA-512     11.461   1000   1000   1000
useradd -m loop + chpasswd -c SHA512         12    SHA-512     21.554   1000   1000   1000
useradd -m loop + chpasswd -c SHA512         1     SHA-512     24.632   1000   1000   1000
--- same algorithm: yescrypt
umc apply (hash_method = YESCRYPT)           12    yescrypt     7.257   1000   1000   1000
umc apply (hash_method = YESCRYPT)           1     yescrypt    24.390   1000   1000   1000
newusers (hashes through PAM)                12    yescrypt    17.164   1000   1000   1000
newusers (hashes through PAM)                1     yescrypt    17.029   1000   1000   1000
useradd -m loop + chpasswd -c YESCRYPT       12    yescrypt    31.353   1000   1000   1000
useradd -m loop + chpasswd -c YESCRYPT       1     yescrypt    31.266   1000   1000   1000

--- a single user (average of 20; no password, home created)
useradd -m                                         39 ms
umc user create (journal, validation, NSS check, audit)      389 ms

How to read this: UMC does not run faster code - the hashing is done by the same kind
of C code (openssl, mkpasswd) - it does less repeated work. A useradd loop starts a
process, takes the locks and rewrites all four account files (plus backups) once per
user; UMC does that once per batch, and spreads the hashing and the home directories
over the CPU cores. On one core only the first effect remains. For one user, UMC's fixed
safety work (journal, validation, verification, audit record) makes it slower.
```
