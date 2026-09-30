#!/usr/bin/env bash
# TITLE: Compliance audit finds seeded misconfigurations
# CLAIM: "umc audit" detects common account misconfigurations, maps them to CIS Benchmark control titles, and returns exit code 10 with --fail-on so CI and monitoring can act on it.
# METHOD: A sandbox is seeded with 8 known problems; the audit is run in text and JSON form and with --fail-on high.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
printf 'toor:x:0:0::/root:/bin/bash\n' >> "$SB/etc/passwd"; printf 'toor::20000:0:99999:7:::\n' >> "$SB/etc/shadow"   # 1+2: UID 0, empty password
printf 'ghost::20000:0:99999:7:::\n' >> "$SB/etc/shadow"                                                            # 3: shadow without passwd
sed -i 's/^bobcat:[^:]*:/bobcat:$1$old$md5hash:/' "$SB/etc/shadow"                                                  # 4: MD5 hash
sed -i 's#^daemon:\(.*\):/usr/sbin/nologin$#daemon:\1:/bin/bash#' "$SB/etc/passwd"                                  # 5: system account with a shell
chmod 666 "$SB/etc/group"                                                                                          # 6: writable account file
umc -q sudo grant bobby --nopasswd                                                                                 # 7: NOPASSWD
mkdir -p "$SB/home/bobby/.ssh"; new_key > "$SB/home/bobby/.ssh/authorized_keys"; chown -R 1002:1002 "$SB/home/bobby/.ssh"
sed -i 's/^bobby:/bobby:!/' "$SB/etc/shadow"                                                                        # 8: '!'-locked but keys work
say "umc audit"; umc audit
say "umc audit --fail-on high; echo \$?"; umc audit --fail-on high >/dev/null; st=$?; echo "$st"; [[ $st == 10 ]] || rc=1
say "umc audit --json | head -c 300"; umc audit --json | head -c 300; echo
# (captured first: "umc audit | grep -q" would trip pipefail when grep exits early)
report=$(umc audit)
for id in AUD-01 AUD-02 AUD-08 AUD-10 AUD-11 AUD-12 AUD-13 AUD-16; do grep -q "FAIL  $id" <<< "$report" || { echo "MISSED $id"; rc=1; }; done
echo "all 8 seeded problems reported: $( ((rc == 0)) && echo yes || echo NO)"
drop_sandbox
verdict $rc
