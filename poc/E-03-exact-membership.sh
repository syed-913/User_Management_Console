#!/usr/bin/env bash
# TITLE: Deleting "bob" leaves "bobby" and "bobcat" alone (v1 F-10 vs v2)
# CLAIM: v1 removed group members with a substring regex, so deleting user bob rewrote bobby to "by" and bobcat to "cat"; v2 edits member lists by exact name.
# METHOD: Users bob, bobby and bobcat are created with shadow-utils and put into group devs. bob is deleted with v1 (menu input on stdin) and, from the same starting state, with v2.
source /src/poc/lib.sh; env_line; rc=0
for u in bob bobby bobcat; do useradd -m "$u"; done
groupadd devs; gpasswd -M bobby,bob,bobcat devs >/dev/null
cp -a /etc /tmp/etc.orig

step "Before"
grep '^devs:' /etc/group /etc/gshadow

step "v1: delete user bob (menu 1 -> g)"
v1_prepare && v1_run '1\ng\nbob\nyr\n0\n'
grep '^devs:' /etc/group /etc/gshadow
v1_line=$(grep '^devs:' /etc/group)

step "Reset, then v2: umc user delete bob"
rm -rf /etc/passwd /etc/shadow /etc/group /etc/gshadow /var/lib/umc
cp -a /tmp/etc.orig/{passwd,shadow,group,gshadow} /etc/
mkdir -p /home/bob && chown bob: /home/bob 2>/dev/null
umc_live --yes user delete bob --keep-home
grep '^devs:' /etc/group /etc/gshadow

step "Summary"
echo "v1 result: $v1_line"
echo "v2 result: $(grep '^devs:' /etc/group)"
[[ $(grep '^devs:' /etc/group) == "devs:x:$(getent group devs | cut -d: -f3):bobby,bobcat" ]] || rc=1
verdict $rc
