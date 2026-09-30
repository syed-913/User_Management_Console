# E-14 · HR exports are read as they are

| | |
|---|---|
| **Claim** | UMC reads HR exports without reformatting: semicolon or comma delimiters, UTF-8 BOM, UTF-16, Windows line endings, quoted fields, accented names, day-first dates, HR status words and nested JSON - and says exactly how it interpreted them. |
| **Method** | "umc import inspect" and "umc apply" are run on three fixtures plus a UTF-16 (Excel "Unicode Text") conversion of one of them. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `9c1a154` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-14` |
| **Verdict** | ✅ PASS |

## Output

```text

$ file /src/tests/fixtures/imports/*
hr_api_nested.json
hr_export_semicolon.csv
team_manifest.json

$ umc import inspect hr_export_semicolon.csv
  hr_export_semicolon.csv
    format     CSV · delimiter: semicolon (European Excel) · UTF-8 with BOM, Windows line endings (CRLF) · 5 record(s)
    mapping
      "Employee ID"                -> external_id (alias)
      "First Name"                 -> first_name (alias)
      "Last Name"                  -> last_name (alias)
      "E-Mail"                     -> email (alias)
      "Department"                 -> department (alias)
      "Job Title"                  -> title (alias)
      "Contract End"               -> expire (alias)
      "Status"                     -> state (alias)
      "Manager"                    -> ignored
    usernames  5 derived (pattern 'first.last', or from the e-mail address)
    example    row 2 -> alice.khan  "Alice Khan,,,,alice.khan@example.com"  (from e-mail)
    example    row 3 -> jose.nunez  "José Núñez,,,,1002"  (from name (first.last))
    example    row 4 -> chen.wei  "Chen Wei,,,,chen.wei@example.com"  (from e-mail)
    next       umc plan -f hr_export_semicolon.csv

$ umc import inspect hr_api_nested.json
  hr_api_nested.json
    format     JSON (records under "data.employees") · UTF-8 · 3 record(s)
    mapping
      "workerId"                   -> external_id (alias)
      "name_first"                 -> first_name (alias)
      "name_last"                  -> last_name (alias)
      "email"                      -> email (alias)
      "department"                 -> department (alias)
      "endDate"                    -> expire (alias)
      "active"                     -> state (alias)
    usernames  3 derived (pattern 'first.last', or from the e-mail address)
    example    record 1 -> priya.sharma  "Priya Sharma,,,,priya.sharma@example.com"  (from e-mail)
    example    record 2 -> lars.o  "Lars Østergård,,,,lars.o@example.com"  (from e-mail)
    example    record 3 -> ana.lima  "Ana Lima,,,,ana.lima@example.com"  (from e-mail)
    next       umc plan -f hr_api_nested.json

$ umc import inspect unicode_text.txt   (the same export saved as UTF-16)
  unicode_text.txt
    format     CSV · delimiter: semicolon (European Excel) · UTF-16 (converted to UTF-8), Windows line endings (CRLF) · 5 record(s)
    mapping
      "﻿Employee ID"             -> external_id (alias)

$ umc apply -f hr_export_semicolon.csv

  Plan for hr_export_semicolon.csv  (5 record(s), CSV)
    + user  alice.khan (from e-mail)  temporary password  expires 2027-12-31
    + user  jose.nunez (from name (first.last))  temporary password
    + user  chen.wei (from e-mail)  temporary password  (created locked)
    + user  mary.obrien (from e-mail)  temporary password  expires 2027-06-15
    = 1 account(s) already as described

  Plan: 4 to add, 0 to change, 0 to offboard.  (nothing has been changed)
  ✓ applied hr_export_semicolon.csv: 4 to add, 0 to change, 0 to offboard
  • 4 temporary password(s) in /root/umc/credentials/20260930T151342Z-182-1.csv (root only); each must be changed within 24 h
  • home directory /home/alice.khan is ready
  • home directory /home/jose.nunez is ready
  • home directory /home/chen.wei is ready
  • home directory /home/mary.obrien is ready
  • txn 20260930T151342Z-182-1  ·  undo with: umc rollback 20260930T151342Z-182-1

$ umc apply -f hr_api_nested.json --create-groups

  Plan for hr_api_nested.json  (3 record(s), JSON)
    + user  priya.sharma (from e-mail)  temporary password
    + user  lars.o (from e-mail)  temporary password  expires 2027-03-31
    = 1 account(s) already as described

  Plan: 2 to add, 0 to change, 0 to offboard.  (nothing has been changed)
  ✓ applied hr_api_nested.json: 2 to add, 0 to change, 0 to offboard
  • 2 temporary password(s) in /root/umc/credentials/20260930T151343Z-462-1.csv (root only); each must be changed within 24 h
  • home directory /home/priya.sharma is ready
  • home directory /home/lars.o is ready
  • txn 20260930T151343Z-462-1  ·  undo with: umc rollback 20260930T151343Z-462-1

$ umc user list
  USER                     UID  HOME                     PASSWORD     EXPIRES
  admin                   1000  /home/admin              set          -
  bobby                   1002  /home/bobby              set          -
  bobcat                  1003  /home/bobcat             set          -
  alice.khan              1004  /home/alice.khan         set          2026-10-02
  jose.nunez              1005  /home/jose.nunez         set          2026-10-02
  chen.wei                1006  /home/chen.wei           locked       1970-01-02
  mary.obrien             1007  /home/mary.obrien        set          2026-10-02
  priya.sharma            1008  /home/priya.sharma       set          2026-10-02
  lars.o                  1009  /home/lars.o             set          2026-10-02
```
