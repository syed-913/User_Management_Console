#!/usr/bin/env bash
# TITLE: The blast-radius check refuses undeclared changes
# CLAIM: Every operation declares which entries it may touch; if the file about to be committed differs anywhere else (a bug, a corrupted edit), the commit is refused and nothing is written.
# METHOD: A transaction that declares only user 'carol' is made to also alter user 'bobby' (simulating a bug in an operation). The commit is attempted and the files are compared.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
before=$(sha "$SB"/etc/{passwd,shadow,group,gshadow})
say "stage: create carol (declared) + change bobby's shell (NOT declared), then commit"
ufn '
    preflight; lk_acquire_db; db_load; txn_begin demo "create carol"
    txn_target_user carol
    db_put PW carol "carol:x:4000:4000::/home/carol:/bin/sh"
    db_put SP carol "carol:!:20000:0:99999:7:::"
    db_fields PW bobby; F[6]=/bin/sh; join_fields "${F[@]}"; db_put PW bobby "$REPLY"
    txn_commit' 2>&1
echo "exit status: $?"
[[ $before == "$(sha "$SB"/etc/{passwd,shadow,group,gshadow})" ]] && echo "account files: unchanged" || { echo "account files: CHANGED"; rc=1; }
echo
echo "This check is independent of the code that edits entries: it compares the bytes"
echo "of the old and new file. It caught a real bug during development (renaming a"
echo "user declared only one of the two group entries it changed)."
drop_sandbox
verdict $rc
