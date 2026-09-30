#!/usr/bin/env bash
# Runs inside a test VM (vagrant provision NAME --provision-with smoke).
# About ten seconds: can this box run UMC at all?
set -u
U=/opt/umc/umc.sh
fail=0
"$U" --no-color doctor | sed -n '2,12p'
"$U" --no-color -q user create smoke.test --generate-password || fail=1
getent passwd smoke.test >/dev/null || fail=1
"$U" --no-color -q --yes user delete smoke.test || fail=1
if command -v getenforce >/dev/null && [ "$(getenforce)" = Enforcing ]; then
    restorecon -n -v /etc/passwd /etc/shadow /etc/group /etc/gshadow | grep -q . && { echo "SELinux labels wrong"; fail=1; }
fi
"$U" --no-color log verify >/dev/null || fail=1
if ((fail)); then echo "SMOKE: FAIL"; exit 1; fi
echo "SMOKE: PASS"
