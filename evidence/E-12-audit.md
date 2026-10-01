# E-12 · Compliance audit finds seeded misconfigurations

| | |
|---|---|
| **Claim** | "umc audit" detects common account misconfigurations, maps them to CIS Benchmark control titles, and returns exit code 10 with --fail-on so CI and monitoring can act on it. |
| **Method** | A sandbox is seeded with 8 known problems; the audit is run in text and JSON form and with --fail-on high. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `0f07bf3` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-12` |
| **Verdict** | ✅ PASS |

## Output

```text

$ umc audit
  UMC compliance audit  Debian-like fixture · 24 checks · 2026-09-30 15:13 UTC
  FAIL  AUD-01  critical Only root has UID 0  (1)
          - toor: has UID 0 (full root privileges)
          CIS: "Ensure root is the only UID 0 account"
          fix: remove or re-number the extra UID-0 accounts
  FAIL  AUD-02  critical No account has an empty password field  (2)
          - toor: EMPTY password field: anyone can log in as toor where PAM allows nullok
          - ghost: EMPTY password field: anyone can log in as ghost where PAM allows nullok
          CIS: "Ensure /etc/shadow password fields are not empty"
          fix: lock them (umc user lock NAME) or set a password
  PASS  AUD-03  high     All accounts use shadowed passwords
  FAIL  AUD-04  high     No duplicate UIDs  (1)
          - toor: shares UID 0 with root
          CIS: "Ensure no duplicate UIDs exist"
          fix: give each account its own UID (umc user modify NAME --uid N)
  PASS  AUD-05  high     No duplicate GIDs
  PASS  AUD-06  high     No duplicate user names
  PASS  AUD-07  high     No duplicate group names
  FAIL  AUD-08  high     passwd/shadow and group/gshadow agree  (1)
          - ghost: is in /etc/shadow but not in /etc/passwd
          fix: add the missing entries (pwconv / grpconv) or remove orphans
  PASS  AUD-09  medium   Every primary group exists
  FAIL  AUD-10  high     Account files have safe owners and permissions  (1)
          - /etc/group: mode 666 owner uid 0 (expected 644, root-owned, not writable by others)
          CIS: "Ensure permissions on /etc/passwd, /etc/shadow, /etc/group, /etc/gshadow (and their - backups) are configured"
          fix: chmod/chown them back (644 root:root; shadow files 640 root:shadow or 000 root:root)
  FAIL  AUD-11  medium   No weak password hashes (MD5/DES)  (1)
          - bobcat: MD5 hash
          CIS: "Ensure strong password hashing algorithm is configured"
          fix: set new passwords; ENCRYPT_METHOD SHA512 or YESCRYPT in login.defs
  FAIL  AUD-12  medium   System accounts cannot log in  (1)
          - daemon: system account (uid 1) has login shell /bin/bash
          CIS: "Ensure system accounts do not have a valid login shell"
          fix: set their shell to /usr/sbin/nologin
  FAIL  AUD-13  high     Locked accounts cannot still log in with SSH keys  (1)
          - bobby: password is locked but /home/bobby/.ssh/authorized_keys still allows key logins
          fix: lock with umc user lock (adds account expiry) or remove the keys
  PASS  AUD-14  medium   Home directories exist, belong to their users, are not group/world-writable
  FAIL  AUD-15  medium   ~/.ssh and authorized_keys are private  (1)
          - bobby: /home/bobby/.ssh is mode 755 owned by uid 1002 (expected 700, owned by bobby)
          fix: chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; chown to the user
  FAIL  AUD-16  medium   No password-less sudo rules  (1)
          - /etc/sudoers.d/umc-user-bobby: bobby ALL=(ALL:ALL) NOPASSWD: ALL
          CIS: "Ensure users must provide password for privilege escalation"
          fix: remove NOPASSWD (umc sudo grant NAME without --nopasswd)
  PASS  AUD-17  medium   The shadow group is empty
  FAIL  AUD-18  low      Human passwords expire  (2)
          - admin: password never expires (max 99999 days)
          - bobcat: password never expires (max 99999 days)
          CIS: "Ensure password expiration is 365 days or less"
          fix: umc user aging NAME --max 365 (note: NIST SP 800-63B advises against forced periodic changes)
  PASS  AUD-19  low      No stale account-file locks
  PASS  AUD-20  high     No interrupted UMC transactions
  PASS  AUD-21  info     Accounts expiring within 14 days
  PASS  AUD-22  info     Onboarding: temporary passwords not yet changed
  PASS  AUD-23  info     Offboarded accounts past their retention period
  PASS  AUD-24  low      login.defs and PAM use the same password hashing algorithm

  Summary: 3 critical, 4 high, 4 medium, 2 low, 0 info

$ umc audit --fail-on high; echo $?
10

$ umc audit --json | head -c 300
{"ok":true,"summary":{"critical":3,"high":4,"medium":4,"low":2,"info":0},"checks":[{"id":"AUD-01","severity":"critical","title":"Only root has UID 0","cis":"Ensure root is the only UID 0 account","status":"fail","findings":1},{"id":"AUD-02","severity":"critical","title":"No account has an empty pass
all 8 seeded problems reported: yes
```
