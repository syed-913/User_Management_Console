# E-08 · Idempotency - running the same thing twice changes nothing

| | |
|---|---|
| **Claim** | Every UMC operation converges: repeating a create, a lock, a group change or a whole bulk apply leaves the account files byte-identical and exits 0. |
| **Method** | Each operation runs twice in a sandbox; SHA-256 of the four files is compared after the first and second run. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `41699b1` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-08` |
| **Verdict** | ✅ PASS |

## Output

```text
umc user create carol --groups users                       exit 0  unchanged  = user carol already exists with the req
umc group create analysts                                  exit 0  unchanged  = group analysts already exists 
umc group add-member analysts carol                        exit 0  unchanged  = membership of analysts already as requ
umc user lock carol                                        exit 0  unchanged  = user carol is already locked 
umc sudo grant carol                                       exit 0  unchanged  = sudo rule for carol already as request
umc --yes apply -f /src/tests/fixtures/imports/team_manifest.json exit 0  unchanged  = 3 account
umc --yes apply -f /src/tests/fixtures/imports/hr_export_semicolon.csv exit 0  unchanged  = 5 account
```
