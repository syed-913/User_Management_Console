# E-05 · Crash consistency under SIGKILL

| | |
|---|---|
| **Claim** | However a commit is interrupted, the four account files are never torn or mutually inconsistent, and the next UMC run restores the exact state from before an interrupted transaction. |
| **Method** | The duration of "umc user create" is measured first. Then 400 times: start it, SIGKILL it at a random moment across its whole run, classify the moment from its journal entry (before the journal / journaled but not started / inside the commit / after the commit), run "umc recover", and check every invariant: each file complete and valid, passwd and shadow list the same users, group and gshadow the same groups, the user either fully exists or not at all. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-05` |
| **Verdict** | ✅ PASS |

## Output

```text
one 'umc user create' takes about 225 ms here; kills are spread over 0..247 ms

iterations                                                 400
killed before its journal entry existed                    313
killed after journaling, before the first rename           45
killed INSIDE the commit (rolled back by 'umc recover')    29
killed after the commit (verification / audit stage)       13
users that ended up created                                13
inconsistent states found                                  0

final audit of the sandbox:
  PASS  AUD-04  high     No duplicate UIDs
  PASS  AUD-05  high     No duplicate GIDs
  PASS  AUD-06  high     No duplicate user names
  PASS  AUD-07  high     No duplicate group names
  PASS  AUD-08  high     passwd/shadow and group/gshadow agree
  PASS  AUD-20  high     No interrupted UMC transactions
```
