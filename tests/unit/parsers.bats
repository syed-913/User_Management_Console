#!/usr/bin/env bats
# The built-in JSON and CSV readers, date/status parsing, transliteration and
# CSV export escaping.
load ../helpers

setup()    { make_sandbox debian; }
teardown() { drop_sandbox; }

json() { printf '%s' "$1" | ufn 'awk "$AWK_JSON"'; }

@test "JSON: nested objects and arrays are flattened to paths" {
    run json '{"a":{"b":[1,"x",true,null]}}'
    expect 0
    contains $'a.b[0]\tn\t1'
    contains $'a.b[1]\ts\tx'
    contains $'a.b[2]\tb\ttrue'
    contains $'a.b[3]\tz\t'
}

@test "JSON: escapes, \\u sequences and surrogate pairs decode to UTF-8" {
    run json '{"n":"José \"J\" \\ /","e":"😀"}'
    contains $'n\ts\tJosé "J" \\ /'
    contains $'e\ts\t😀'
}

@test "JSON: control characters inside strings are marked, not passed through" {
    run json '{"n":"a\nb"}'
    contains $'n\ts\ta\177b'
}

@test "JSON: syntax errors are reported with a position" {
    run json '{"a":1,}'
    contains "!error"
    run json '{"a":"unterminated}'
    contains "unterminated string"
    run json '[1,2] trailing'
    contains "unexpected text"
}

csv() { printf "$2" | ufn 'awk -v D="$1" "$AWK_CSV"' "$1"; }

@test "CSV: quoted delimiters, doubled quotes and line breaks inside fields" {
    run csv , 'name,comment\nalice,"Khan, Alice"\nbob,"say ""hi"""\ncarol,"two\nlines"\n'
    expect 0
    [ "$(sed -n 2p <<< "$output" | tr '\037' '|')" = "2|alice|Khan, Alice" ]
    [ "$(sed -n 3p <<< "$output" | tr '\037' '|')" = '3|bob|say "hi"' ]
    [ "$(sed -n 4p <<< "$output" | tr '\037\177' '|~')" = "4|carol|two~lines" ]
}

@test "CSV: Windows line endings are removed" {
    run csv ';' 'a;b\r\n1;2\r\n'
    [ "$(sed -n 2p <<< "$output" | tr '\037' '|')" = "2|1|2" ]
}

@test "CSV: the delimiter is detected (comma, semicolon, tab, pipe)" {
    local d
    for d in , ';' $'\t' '|'; do
        run bash -c 'printf "a%sb%sc\n1%s2%s3\n4%s5%s6\n" "$1" "$1" "$1" "$1" "$1" "$1" | awk "$2"' _ "$d" "$(ufn 'printf "%s" "$AWK_SNIFF"')"
        case $d in ,) [ "$output" = 1 ] ;; ';') [ "$output" = 2 ] ;; $'\t') [ "$output" = 3 ] ;; '|') [ "$output" = 4 ] ;; esac
    done
}

@test "dates as HR systems write them; ambiguous ones are refused" {
    run ufn 'for d in 31/12/2026 12/31/2026 31.12.2026 2026/12/31 2026-12-31T08:00:00Z 46387; do imp_date "$d"; printf "%s " "$REPLY"; done'
    [ "$output" = "20818 20818 20818 20818 20818 20818 " ]
    run ufn 'imp_date 03/04/2027 || echo "NO: $VAL_ERR"'
    contains "ambiguous"
    run ufn 'IMP_DATEFMT=mdy; imp_date 03/04/2027; days_to_date $REPLY; echo $REPLY'
    [ "$output" = 2027-03-04 ]
}

@test "HR status values map to present / locked / absent" {
    run ufn 'for s in Active "On leave" Terminated true false Suspended; do imp_state "$s"; printf "%s " "$REPLY"; done'
    [ "$output" = "present locked absent present absent locked " ]
    run ufn 'imp_state maybe || echo "NO"'
    [ "$output" = NO ]
}

@test "accented names are transliterated; non-Latin names are flagged" {
    run bash -c 'printf "José\tNúñez\t\t\n张伟\t\t\t\n" | awk "$1"' _ "$(ufn 'printf "%s" "$AWK_TRANSLIT"')"
    [ "$(sed -n 1p <<< "$output")" = $'Jose\tNunez\t\t' ]
    [[ $(sed -n 2p <<< "$output") == *'?'* ]]
}

@test "F-30: exported CSV cells are quoted and formula-safe (CWE-1236)" {
    run ufn 'for v in "=cmd|calc" "+1" "@SUM(A1)" "Khan, Alice" "plain"; do _csv_cell "$v"; printf "%s\n" "$REPLY"; done'
    [ "$(sed -n 1p <<< "$output")" = "\"'=cmd|calc\"" ]
    [ "$(sed -n 2p <<< "$output")" = "\"'+1\"" ]
    [ "$(sed -n 4p <<< "$output")" = '"Khan, Alice"' ]
    [ "$(sed -n 5p <<< "$output")" = plain ]
}

@test "JSON output of UMC is valid JSON (checked with UMC's own parser)" {
    run ufn 'OPT_JSON=true; WARNINGS=("a \"quoted\" warning"); jset name "$1"; jraw n 1; jemit | awk "$AWK_JSON"' $'x\ty'
    expect 0
    ! grep -q '!error' <<< "$output"
    contains $'name\ts\tx\177y'
}
