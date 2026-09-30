#!/usr/bin/env bash
# Boots each test VM for one provider, runs the smoke test, destroys it, and
# prints a table - so anyone can check which pinned boxes work for them.
#   tests/vagrant/smoke.sh libvirt              all boxes, one at a time
#   tests/vagrant/smoke.sh virtualbox rocky9    one box
# Boxes are downloaded on first use (hundreds of MB each).
set -uo pipefail
provider=${1:?usage: smoke.sh PROVIDER [BOX...]}; shift
cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." || exit 1
boxes=("$@")
((${#boxes[@]})) || mapfile -t boxes < <(ruby -e 'eval(File.read("Vagrantfile")[/BOXES = \{.*?^\}/m]); puts BOXES.keys')
printf '%-12s %-10s %s\n' BOX PROVIDER RESULT
for b in "${boxes[@]}"; do
    log=$(mktemp)
    if UMC_BOXES=$b vagrant up "$b" --provider="$provider" >"$log" 2>&1; then
        if UMC_BOXES=$b vagrant provision "$b" --provision-with smoke >>"$log" 2>&1 && grep -q 'SMOKE: PASS' "$log"; then r="PASS"; else r="FAIL (smoke test, see $log)"; fi
    else
        r="FAIL (box did not boot, see $log)"
    fi
    UMC_BOXES=$b vagrant destroy -f "$b" >/dev/null 2>&1
    printf '%-12s %-10s %s  (%s)\n' "$b" "$provider" "$r" "$(date -u +%F)"
done
