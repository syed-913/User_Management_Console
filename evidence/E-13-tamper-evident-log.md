# E-13 · The audit log is tamper-evident

| | |
|---|---|
| **Claim** | Each audit record carries the SHA-256 of the previous record, so editing, deleting or inserting a line is detected by "umc log verify" (and each record's hash is also sent to journald where available). |
| **Method** | 10 operations are logged; the chain is verified; then one record is edited, one is deleted, and one is inserted, verifying after each. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-13` |
| **Verdict** | ✅ PASS |

## Output

```text

$ head -2 audit.jsonl
{"seq":1,"ts":"2026-09-30T15:13:39Z","host":"ca2cfc0431bc","actor":"root","loginuid":"","sudo_user":"","tty":"","from":"","root":"/tmp/umc-sb.eZdyfu","action":"user.create","target":"log1","result":"success","txn":"20260930T151339Z-39-1","detail":"uid 1004","prev":"0000000000000000000000000000000000000000000000000000000000000000"}
{"seq":2,"ts":"2026-09-30T15:13:40Z","host":"ca2cfc0431bc","actor":"root","loginuid":"","sudo_user":"","tty":"","from":"","root":"/tmp/umc-sb.eZdyfu","action":"user.lock","target":"log1","result":"success","txn":"20260930T151340Z-214-1","detail":"locked","prev":"b74ea1562a036751e617b62df5205d222e1c56d8c90ad3593a4054d870382e04"}

$ umc log verify
  ✓ audit log intact: 10 record(s), hash chain verified (head d2bcf14cff9c6993...)

$ edit record 3 (change the target)

  ✗ ERROR: audit log verification FAILED: line 4 does not chain to line 3 (a line was edited, inserted or deleted)
    state: nothing was changed
    next:  compare with the copy in journald: journalctl SYSLOG_IDENTIFIER=umc

$ delete record 5

  ✗ ERROR: audit log verification FAILED: line 5 does not chain to line 4 (a line was edited, inserted or deleted)
    state: nothing was changed
    next:  compare with the copy in journald: journalctl SYSLOG_IDENTIFIER=umc

$ insert a forged record after record 2

  ✗ ERROR: audit log verification FAILED: line 3 does not chain to line 2 (a line was edited, inserted or deleted)
    state: nothing was changed
    next:  compare with the copy in journald: journalctl SYSLOG_IDENTIFIER=umc

$ restore the original
  ✓ audit log intact: 10 record(s), hash chain verified (head d2bcf14cff9c6993...)

Limit (stated honestly): root can recompute the whole chain. Forward the journald
copy (UMC_CHAIN field) to a remote log server - that is the real control.
```
