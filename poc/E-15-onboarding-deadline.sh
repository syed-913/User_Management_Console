#!/usr/bin/env bash
# TITLE: Temporary passwords expire if not changed in time
# CLAIM: A generated temporary password must be changed within the deadline (24 h by default). "umc sweep" locks accounts that miss it and erases their credential-slip entries; accounts whose user changed the password are activated. A shadow expiry date is a backstop even if the sweep never runs.
# METHOD: Two users get temporary passwords. One "changes" it (last-change date updated). The sweep runs with a simulated clock (UMC_NOW, honoured only in --root sandboxes) one minute before and one minute after the deadline.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
umc -q user create early.bird --generate-password
umc -q user create late.comer --generate-password
dl=$(st_field onboarding late.comer deadline)
printf 'deadline: %s\n' "$(date -u -d "@$dl" '+%F %T UTC')"
say "shadow (lastchg=0 forces a change at first login; field 8 is the backstop expiry day)"; grep -E '^(early.bird|late.comer):' "$SB/etc/shadow" | cut -d: -f1,3,8
say "credential slip (root-only, 0600) - passwords masked here"; ls -l "$SB"/root/umc/credentials/; sed -E 's/,[A-Za-z2-9]{4}-[A-Za-z2-9]{4}-[A-Za-z2-9]{4},/,****-****-****,/' "$SB"/root/umc/credentials/*.csv
sed -i "s/^early.bird:\([^:]*\):0:/early.bird:\1:$(( $(date +%s) / 86400 )):/" "$SB/etc/shadow"      # early.bird changed the password
say "UMC_NOW=deadline-60s umc sweep"; UMC_NOW=$((dl - 60)) "$UMC" --no-color --root "$SB" sweep
say "UMC_NOW=deadline+60s umc sweep"; UMC_NOW=$((dl + 60)) "$UMC" --no-color --root "$SB" sweep
say "umc user show late.comer"; umc user show late.comer | grep -E 'password|locked|expires'
grep -q '^late.comer:!' "$SB/etc/shadow" || rc=1
grep -qs '^late.comer,' "$SB"/root/umc/credentials/*.csv && { echo "slip entry still present"; rc=1; }
say "ls root/umc/credentials   (the slip is shredded once every entry is resolved)"; ls -A "$SB/root/umc/credentials"
drop_sandbox
verdict $rc
