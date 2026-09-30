# E-04 · New accounts get free, in-range IDs (v1 F-05 and F-12 vs v2)

| | |
|---|---|
| **Claim** | v1 reused a new user's UID as its GID without checking /etc/group, so a new user could land in an existing group (here: docker), and its bulk import counted 'nobody' and assigned UIDs from 65535 upwards; v2 allocates an ID that is free as both UID and GID inside login.defs' UID_MIN..UID_MAX. |
| **Method** | A docker group is created at GID 1001 (the next free UID). One user is created with v1 and one with v2; then two users are bulk-imported with v1's CSV import and with v2's apply. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `9c1a154` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-04` |
| **Verdict** | ✅ PASS |

## Output

```text

## Starting point
tester:x:1000:1000::/home/tester:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
docker:x:1001:

## v1: create user v1user (menu 1 -> a)

$ id v1user
uid=1001(v1user) gid=1001(docker) groups=1001(docker)

## v1: bulk import (menu 4 -> a) of two users
bulk.one:x:65535:65535:one:/home/bulk.one:/bin/bash
bulk.two:x:65536:65536:two:/home/bulk.two:/bin/bash

## Reset, then v2

$ id v2user
uid=1002(v2user) gid=1002(v2user) groups=1002(v2user)
bulk.one:x:1003:1003::/home/bulk.one:/bin/sh
bulk.two:x:1004:1004::/home/bulk.two:/bin/sh

## Summary
v2user's primary group: v2user
v2 bulk UIDs: 1003, 1004 (UID_MAX is 60000)
```
