#!/usr/bin/env bash
# TITLE: New accounts get free, in-range IDs (v1 F-05 and F-12 vs v2)
# CLAIM: v1 reused a new user's UID as its GID without checking /etc/group, so a new user could land in an existing group (here: docker), and its bulk import counted 'nobody' and assigned UIDs from 65535 upwards; v2 allocates an ID that is free as both UID and GID inside login.defs' UID_MIN..UID_MAX.
# METHOD: A docker group is created at GID 1001 (the next free UID). One user is created with v1 and one with v2; then two users are bulk-imported with v1's CSV import and with v2's apply.
source /src/poc/lib.sh; env_line; rc=0
groupadd -g 1001 docker
cp -a /etc /tmp/etc.orig

step "Starting point"
getent passwd tester nobody; getent group docker

step "v1: create user v1user (menu 1 -> a)"
v1_prepare && v1_run '1\na\nv1user\nPassw0rd@x\nxr\n0\n'
say "id v1user"; id v1user
step "v1: bulk import (menu 4 -> a) of two users"
printf 'username,password,comment\nbulk.one,Passw0rd@1,one\nbulk.two,Passw0rd@2,two\n' > /tmp/bulk.csv
v1_run '4\na\n/tmp/bulk.csv\nyxr\n0\n'
grep -E '^bulk\.(one|two):' /etc/passwd

step "Reset, then v2"
rm -rf /etc/passwd /etc/shadow /etc/group /etc/gshadow /var/lib/umc
cp -a /tmp/etc.orig/{passwd,shadow,group,gshadow} /etc/
umc_live -q user create v2user; say "id v2user"; id v2user
printf 'username\nbulk.one\nbulk.two\n' > /tmp/bulk2.csv
umc_live -q --yes apply -f /tmp/bulk2.csv
grep -E '^bulk\.(one|two):' /etc/passwd

step "Summary"
g=$(id -gn v2user); echo "v2user's primary group: $g"
[[ $g == v2user ]] || rc=1
for u in bulk.one bulk.two; do (( $(id -u $u) < 60000 )) || rc=1; done
echo "v2 bulk UIDs: $(id -u bulk.one), $(id -u bulk.two) (UID_MAX is 60000)"
verdict $rc
