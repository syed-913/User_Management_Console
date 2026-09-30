# E-10 · The blast-radius check refuses undeclared changes

| | |
|---|---|
| **Claim** | Every operation declares which entries it may touch; if the file about to be committed differs anywhere else (a bug, a corrupted edit), the commit is refused and nothing is written. |
| **Method** | A transaction that declares only user 'carol' is made to also alter user 'bobby' (simulating a bug in an operation). The commit is attempted and the files are compared. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `41699b1` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-10` |
| **Verdict** | ✅ PASS |

## Output

```text

$ stage: create carol (declared) + change bobby's shell (NOT declared), then commit

  ✗ ERROR: blast-radius check failed: entry 'bobby' in passwd changed but was not part of this operation
    state: nothing was changed
    next:  this is a bug in UMC; please report it (nothing was written)
exit status: 7
account files: unchanged

This check is independent of the code that edits entries: it compares the bytes
of the old and new file. It caught a real bug during development (renaming a
user declared only one of the two group entries it changed).
```
