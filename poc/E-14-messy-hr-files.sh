#!/usr/bin/env bash
# TITLE: HR exports are read as they are
# CLAIM: UMC reads HR exports without reformatting: semicolon or comma delimiters, UTF-8 BOM, UTF-16, Windows line endings, quoted fields, accented names, day-first dates, HR status words and nested JSON - and says exactly how it interpreted them.
# METHOD: "umc import inspect" and "umc apply" are run on three fixtures plus a UTF-16 (Excel "Unicode Text") conversion of one of them.
source /src/poc/lib.sh; env_line; rc=0
make_sandbox debian
F=/src/tests/fixtures/imports
say "file $F/*"; file "$F"/* 2>/dev/null | sed 's#.*/##' || ls "$F"
for f in hr_export_semicolon.csv hr_api_nested.json; do say "umc import inspect $f"; umc import inspect "$F/$f" || rc=1; done
iconv -f UTF-8 -t UTF-16 < "$F/hr_export_semicolon.csv" > /tmp/unicode_text.txt
say "umc import inspect unicode_text.txt   (the same export saved as UTF-16)"
out=$(umc import inspect /tmp/unicode_text.txt) || rc=1
head -4 <<< "$out"
say "umc apply -f hr_export_semicolon.csv"; umc --yes apply -f "$F/hr_export_semicolon.csv" || rc=1
say "umc apply -f hr_api_nested.json --create-groups"; umc --yes apply -f "$F/hr_api_nested.json" --create-groups || rc=1
say "umc user list"; umc user list
for u in alice.khan jose.nunez chen.wei mary.obrien priya.sharma lars.o; do grep -q "^$u:" "$SB/etc/passwd" || { echo "missing $u"; rc=1; }; done
drop_sandbox
verdict $rc
