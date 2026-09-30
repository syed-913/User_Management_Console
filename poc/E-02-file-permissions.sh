#!/usr/bin/env bash
# TITLE: File ownership and permissions survive a change (v1 F-02 vs v2)
# CLAIM: v1 left /etc/passwd and /etc/group mode 0600 after the first change, so ordinary users could no longer map UIDs to names; v2 keeps the owner, group and mode of all four files exactly as they were.
# METHOD: The same "create one user" action is performed with v1 (menu input on stdin) and with v2 in two fresh containers' worth of state; modes are listed and an unprivileged user tries to resolve a name.
source /src/poc/lib.sh; env_line; rc=0
cp -a /etc /tmp/etc.orig

step "Before"
stat -c '  %n  %U:%G %a' /etc/passwd /etc/shadow /etc/group /etc/gshadow

step "v1: create user 'v1user' through its menu (1 -> a)"
v1_prepare && v1_run '1\na\nv1user\nPassw0rd@x\nxr\n0\n'
stat -c '  %n  %U:%G %a' /etc/passwd /etc/shadow /etc/group /etc/gshadow
say "su tester -c 'id -un; ls -ln /etc/passwd'"
su -s /bin/sh tester -c 'id -un 2>&1; getent passwd root >/dev/null && echo "  can resolve names" || echo "  CANNOT resolve user names any more"'
v1_modes=$(stat -c %a /etc/passwd)

step "Reset /etc, then v2: umc user create v2user"
rm -rf /etc/passwd /etc/shadow /etc/group /etc/gshadow
cp -a /tmp/etc.orig/{passwd,shadow,group,gshadow} /etc/
umc_live user create v2user
stat -c '  %n  %U:%G %a' /etc/passwd /etc/shadow /etc/group /etc/gshadow
su -s /bin/sh tester -c 'id -un 2>&1; getent passwd root >/dev/null && echo "  can resolve names" || echo "  CANNOT resolve names"'

step "Summary"
echo "v1 left /etc/passwd at mode $v1_modes; v2 left it at $(stat -c %a /etc/passwd) (expected 644)"
[[ $(stat -c %a /etc/passwd) == 644 && $(stat -c %a /etc/shadow) == "$(stat -c %a /tmp/etc.orig/shadow)" ]] || rc=1
verdict $rc
