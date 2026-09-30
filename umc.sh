#!/bin/bash
# ==============================================================================
#   U S E R   M A N A G E M E N T   C O N S O L E   (UMC)                v2.0.0
# ------------------------------------------------------------------------------
#   Transactional local-account management for Linux, in one bash file.
#
#   * Edits /etc/{passwd,shadow,group,gshadow} itself. It never calls useradd,
#     usermod, userdel, groupadd, gpasswd, passwd, chage, chpasswd or newusers.
#   * Uses the same locking and commit protocol as shadow-utils, so it is safe
#     to run next to those tools, PAM and vipw.
#   * Every change is a journaled transaction: dry-run, rollback, crash recovery.
#
#   Copyright (c) 2026 syed-913 - MIT License (see LICENSE).
#   README.md: usage   docs/DESIGN.md: architecture, commit protocol, threat model
# ==============================================================================
#
#   Map of this file (search for the banners, e.g. "§5 "):
#     §0  runtime baseline          §8   home directories & SSH keys
#     §1  output & error model      §9   account operations
#     §2  config & host facts       §10  bulk import, plan & apply
#     §3  audit trail               §11  compliance audit, export, policy
#     §4  locking                   §12  safety-net commands
#     §5  database & transactions   §13  command-line interface
#     §6  validators & ID allocation §14 interactive console (TUI)
#     §7  passwords & secrets       §15  main
# ==============================================================================

# shellcheck disable=SC2178,SC2128
# ^ Deliberate, file-wide: functions use locals with the same names (out, keys,
#   in...) as arrays in one function and strings in another. shellcheck does not
#   track function scope and reports those as type changes.
# shellcheck disable=SC2016
# ^ awk programs and the privilege-dropped snippet are single-quoted on purpose.
# shellcheck disable=SC2174
# ^ 'mkdir -p -m 0700' only sets the deepest directory's mode, but umask 077
#   (§0) already makes every parent it creates 0700.
# shellcheck disable=SC2015
# ^ Every 'A && B || C' in this file was reviewed: B is an assignment that
#   cannot fail, or is deliberately part of the condition.

# ==============================================================================
# §0  RUNTIME BASELINE - a root tool must not trust the environment it inherits
# ==============================================================================

# bash >= 4.4 (the oldest supported: RHEL 8). Written in old syntax on purpose
# so an older shell reaches this message instead of a syntax error further down.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "umc: bash 4.4 or newer is required (this is ${BASH_VERSION:-not bash})" >&2
    exit 1
fi

# No 'set -e': its rules silently change inside if/&&/||/functions, which is
# exactly where a transactional tool needs precise control. Every step that
# changes state is checked explicitly instead (§1 die, §5 txn_commit).
set -o nounset -o pipefail
shopt -s extglob
umask 077                      # private by default; public files get explicit modes
export LC_ALL=C                # byte-exact sort/regex, untranslated tool output
export TZ=UTC                  # every date UMC stores or prints is UTC
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
IFS=$' \t\n'
unset -v CDPATH GLOBIGNORE ENV BASH_ENV 2>/dev/null || true

readonly UMC_VERSION=2.0.0
UMC_SELF=${BASH_SOURCE[0]}

# Exit codes are part of the interface (README, "Exit codes").
readonly E_OK=0 E_FAIL=1 E_USAGE=2 E_INVALID=3 E_LOCKED=4 E_NOTFOUND=5 \
         E_CONFLICT=6 E_INTEGRITY=7 E_ROLLEDBACK=8 E_AUDIT=10

# Global options, set by the CLI parser (§13).
OPT_ROOT="" OPT_DRY_RUN=false OPT_YES=false OPT_JSON=false OPT_QUIET=false
OPT_COLOR=auto OPT_CONFIG="" OPT_DEBUG=false

# ==============================================================================
# §1  OUTPUT & ERROR MODEL
#     Results go to stdout, diagnostics to stderr. Every error says what failed,
#     what state the system is in now, and what to do next.
# ==============================================================================

C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE=""

ui_colors() {
    local want=false
    case $OPT_COLOR in
        always) want=true ;;
        never)  want=false ;;
        *)      [[ -z ${NO_COLOR:-} && -t 1 && ${TERM:-dumb} != dumb ]] && want=true ;;
    esac
    if $want; then
        C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[91m' C_GREEN=$'\e[92m'
        C_YELLOW=$'\e[93m' C_BLUE=$'\e[94m' C_CYAN=$'\e[96m' C_WHITE=$'\e[97m'
    else
        C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE=""
    fi
}

WARNINGS=()
say()  { $OPT_QUIET || $OPT_JSON || printf '%s\n' "$*"; }
ok()   { $OPT_QUIET || $OPT_JSON || printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { $OPT_QUIET || $OPT_JSON || printf '  %s•%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
same() { $OPT_QUIET || $OPT_JSON || printf '  %s= %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn() {
    WARNINGS+=("$*")
    $OPT_QUIET || printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

# --- JSON output --------------------------------------------------------------
# json_str VALUE -> REPLY holds a quoted, escaped JSON string.
json_str() {
    local s=$1 out="" c i
    s=${s//\\/\\\\} s=${s//\"/\\\"}
    s=${s//$'\n'/\\n} s=${s//$'\r'/\\r} s=${s//$'\t'/\\t}
    if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
        for ((i = 0; i < ${#s}; i++)); do
            c=${s:i:1}
            [[ $c == [$'\x01'-$'\x1f'] ]] && printf -v c '\\u%04x' "'$c"
            out+=$c
        done
        s=$out
    fi
    REPLY="\"$s\""
}
# json_arr VALUE... -> REPLY holds a JSON array of strings.
json_arr() {
    local v out=""
    for v; do json_str "$v"; out+=${out:+,}$REPLY; done
    REPLY="[$out]"
}

# Commands add fields to the result with jset/jraw; jemit prints the object.
J=()
jset() { json_str "$2"; J+=("\"$1\":$REPLY"); }
jraw() { J+=("\"$1\":$2"); }
jemit() {
    $OPT_JSON || return 0
    local IFS=,
    json_arr "${WARNINGS[@]}"
    printf '{"ok":true,%s%s"warnings":%s}\n' "${J[*]}" "${J[*]:+,}" "$REPLY"
}

# --- errors ---------------------------------------------------------------------
TXN_PHASE=none TXN_ID=""       # see §5
AUDIT_READY=false IN_DIE=false AUDIT_ACTION="" AUDIT_TARGET=""

state_text() {
    case $TXN_PHASE in
        none|staged) REPLY="nothing was changed" ;;
        committing)  REPLY="the commit was interrupted; the next UMC run restores the previous state from the journal (txn $TXN_ID)" ;;
        committed)   REPLY="the account changes are committed (txn $TXN_ID) but a follow-up step failed; re-running the same command is safe" ;;
        rolledback)  REPLY="every change was rolled back automatically (txn $TXN_ID)" ;;
        *)           REPLY="unknown" ;;
    esac
}

# die CODE WHAT [STATE] [NEXT]
die() {
    local code=$1 what=$2 state=${3:-} next=${4:-}
    if [[ -z $state ]]; then state_text; state=$REPLY; fi
    if $AUDIT_READY && ! $IN_DIE; then
        IN_DIE=true
        audit_event "${AUDIT_ACTION:-umc}" "$AUDIT_TARGET" "error" "$what" || true
    fi
    if $OPT_JSON; then
        local w s n
        json_str "$what"; w=$REPLY; json_str "$state"; s=$REPLY; json_str "$next"; n=$REPLY
        printf '{"ok":false,"exit":%d,"error":%s,"state":%s,"next":%s}\n' "$code" "$w" "$s" "$n"
    fi
    printf '\n  %s✗ ERROR:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$what" >&2
    printf '    %sstate:%s %s\n' "$C_DIM" "$C_RESET" "$state" >&2
    [[ -n $next ]] && printf '    %snext: %s %s\n' "$C_DIM" "$C_RESET" "$next" >&2
    exit "$code"
}
bug()       { die "$E_FAIL" "internal error: $*" "" "this is a bug in UMC - please report it together with 'umc doctor' output"; }
usage_err() { die "$E_USAGE" "$1" "nothing was changed" "${2:-see: umc help}"; }

# --- traps: guaranteed cleanup, signals blocked during the commit ---------------
CLEANUP=() SHRED=()
on_exit() {
    local rc=$? p
    trap - EXIT
    # Files that held secrets (unfinished credential slips) are overwritten first.
    for p in "${SHRED[@]}"; do
        [[ -f $p ]] || continue
        if command -v shred >/dev/null 2>&1; then shred -u -- "$p" 2>/dev/null || rm -f -- "$p"; else rm -f -- "$p"; fi
    done
    for p in "${CLEANUP[@]}"; do [[ -n $p ]] && rm -rf -- "$p"; done
    lk_release_all
    exit "$rc"
}
on_signal() {
    local code=130
    case $1 in TERM) code=143 ;; HUP) code=129 ;; esac
    printf '\n' >&2
    die "$code" "interrupted by SIG$1"
}
traps_install() {
    trap on_exit EXIT
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    trap 'on_signal HUP' HUP
}
# While the commit renames files, INT/TERM/HUP are *ignored* - not just
# trapped - because ignored signals are inherited by child processes: Ctrl-C
# cannot kill an 'mv' half-way through the sequence. SIGKILL cannot be blocked;
# that case is covered by the journal (txn_recover).
critical_begin() { trap '' INT TERM HUP; }
critical_end()   { traps_install; }

debug_install() {
    $OPT_DEBUG || return 0
    set -o errtrace
    trap 'printf "  [debug] exit %d at line %d: %s  (%s)\n" "$?" "$LINENO" "$BASH_COMMAND" "${FUNCNAME[*]:0:4}" >&2' ERR
}

# ==============================================================================
# §2  CONFIG & HOST FACTS
#     Defaults come from the host's own files (login.defs, /etc/default/useradd)
#     so UMC behaves like the distro's tools. /etc/umc/umc.conf can override
#     them. It is parsed, never 'source'd: sourcing a config file as root would
#     turn anyone who can edit it into root.
# ==============================================================================

paths_init() {
    R=${OPT_ROOT%/}
    LIVE=true
    [[ -n $R ]] && LIVE=false
    ETC=$R/etc
    F_PASSWD=$ETC/passwd F_SHADOW=$ETC/shadow F_GROUP=$ETC/group F_GSHADOW=$ETC/gshadow
    STATE=$R/var/lib/umc
    TXN_DIR=$STATE/txn ARCHIVE_DIR=$STATE/archive
    LOG_DIR=$R/var/log/umc AUDIT_LOG=$R/var/log/umc/audit.jsonl
    if   [[ -d $R/run/lock ]]; then UMC_LOCK=$R/run/lock/umc.lock
    elif [[ -d $R/var/lock ]]; then UMC_LOCK=$R/var/lock/umc.lock
    else UMC_LOCK=$STATE/umc.lock
    fi
    CFG_FILE=${OPT_CONFIG:-$ETC/umc/umc.conf}
}

declare -A CFG=(
    [name_regex]='^[a-z_][a-z0-9_.-]*[$]?$'
    [name_max_len]=32
    [home_base]=''               # '' = HOME from /etc/default/useradd, else /home
    [home_roots]=''              # where 'delete' may remove homes; '' = home_base
    [default_shell]=''           # '' = SHELL from /etc/default/useradd, else /bin/bash
    [default_groups]=''
    [protected_users]=''         # never locked/offboarded/deleted (root always is)
    [privileged_groups]='sudo wheel admin adm docker lxd libvirt'
    [txn_keep_count]=100
    [txn_keep_days]=90
    [offboard_retention_days]=30
    [onboarding_deadline_hours]=24
    [credentials_dir]=''         # '' = /root/umc/credentials
    [username_pattern]='first.last'
    [reuse_ids]=no
    [lock_timeout]=15
    [archive_home_on_offboard]=yes
    [hash_method]=''             # '' = ENCRYPT_METHOD from login.defs
)

cfg_load() {
    local f=$CFG_FILE line key val n=0
    [[ -e $f ]] || return 0
    if $LIVE; then
        local st
        st=$(stat -Lc '%u %a' -- "$f") || die "$E_FAIL" "cannot stat $f"
        # A config file that non-root users can edit would let them steer a root tool.
        if [[ ${st%% *} != 0 ]] || (( 8#${st##* } & 8#022 )); then
            die "$E_INVALID" "$f must be owned by root and not writable by group/others" \
                "nothing was changed" "chown root:root '$f' && chmod 0644 '$f'"
        fi
    fi
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        line=${line%%#*}
        line=${line##+([[:space:]])} line=${line%%+([[:space:]])}
        [[ -z $line ]] && continue
        [[ $line == *=* ]] || die "$E_INVALID" "$f:$n: expected 'key = value'"
        key=${line%%=*} val=${line#*=}
        key=${key%%+([[:space:]])} val=${val##+([[:space:]])}
        val=${val#\"} val=${val%\"}
        [[ -n ${CFG[$key]+x} ]] || die "$E_INVALID" "$f:$n: unknown setting '$key'" \
            "nothing was changed" "remove it or fix the spelling (see examples/umc.conf)"
        cfg_check "$key" "$val" || die "$E_INVALID" "$f:$n: $key: $VAL_ERR"
        CFG[$key]=$val
    done < "$f"
}

cfg_check() {
    local k=$1 v=$2
    VAL_ERR=""
    case $k in
        name_max_len|txn_keep_count|txn_keep_days|offboard_retention_days|onboarding_deadline_hours|lock_timeout)
            [[ $v =~ ^[0-9]+$ ]] || VAL_ERR="must be a whole number" ;;
        reuse_ids|archive_home_on_offboard)
            [[ $v == yes || $v == no ]] || VAL_ERR="must be yes or no" ;;
        home_base|default_shell|credentials_dir)
            [[ -z $v || $v == /* ]] || VAL_ERR="must be an absolute path" ;;
        home_roots)
            local p; for p in $v; do [[ $p == /* ]] || VAL_ERR="'$p' is not an absolute path"; done ;;
        name_regex)
            [[ x =~ $v ]]; (( $? != 2 )) || VAL_ERR="not a valid regular expression" ;;
        username_pattern)
            [[ $v =~ ^(first\.last|flast|firstl|first_last|last\.first|first)$ ]] ||
                VAL_ERR="must be one of: first.last flast firstl first_last last.first first" ;;
        hash_method)
            [[ $v =~ ^(|SHA512|YESCRYPT)$ ]] || VAL_ERR="must be SHA512 or YESCRYPT" ;;
    esac
    [[ -z $VAL_ERR ]]
}

# login.defs / /etc/default/useradd - the distro's own account defaults.
declare -A DEFS=() UADEF=()
DEFS_LOADED=false
defs_load() {
    $DEFS_LOADED && return 0
    DEFS_LOADED=true
    local k v _
    if [[ -r $ETC/login.defs ]]; then
        while read -r k v _; do
            [[ -z $k || $k == \#* ]] && continue
            v=${v#\"} v=${v%\"}
            DEFS[$k]=$v
        done < "$ETC/login.defs"
    fi
    if [[ -r $ETC/default/useradd ]]; then
        while IFS='=' read -r k v; do
            [[ -z $k || $k == \#* ]] && continue
            v=${v#\"} v=${v%\"}
            UADEF[$k]=$v
        done < "$ETC/default/useradd"
    fi
}
defs_get()  { defs_load; REPLY=${DEFS[$1]:-$2}; }
uadef_get() { defs_load; REPLY=${UADEF[$1]:-$2}; }

# Effective defaults, resolved once.
cfg_resolve() {
    defs_load
    [[ -n ${CFG[home_base]} ]]     || { uadef_get HOME /home; CFG[home_base]=$REPLY; }
    [[ -n ${CFG[home_roots]} ]]    || CFG[home_roots]=${CFG[home_base]}
    [[ -n ${CFG[default_shell]} ]] || { uadef_get SHELL /bin/bash; CFG[default_shell]=$REPLY; }
    [[ -n ${CFG[credentials_dir]} ]] || CFG[credentials_dir]=/root/umc/credentials
    if [[ -z ${CFG[hash_method]} ]]; then
        defs_get ENCRYPT_METHOD SHA512
        CFG[hash_method]=${REPLY^^}
    fi
}

# /etc/os-release is informational only: behaviour is driven by capabilities.
declare -A OS=()
os_info() {
    local f k v
    for f in "$ETC/os-release" "$R/usr/lib/os-release"; do [[ -r $f ]] && break; done
    OS=([ID]=unknown [ID_LIKE]="" [VERSION_ID]="" [PRETTY_NAME]="unknown Linux")
    [[ -r $f ]] || return 0
    while IFS='=' read -r k v; do
        [[ $k =~ ^(ID|ID_LIKE|VERSION_ID|PRETTY_NAME)$ ]] || continue
        v=${v#[\"\']} v=${v%[\"\']}
        OS[$k]=$v
    done < "$f"
}

# Capabilities: "can this host do X?", probed lazily and cached. Asking what the
# host can do works on distros UMC has never heard of; matching distro names
# (what v1 did) broke on Rocky Linux.
declare -A CAPS=()
cap_has() {
    [[ -n ${CAPS[$1]+x} ]] || CAPS[$1]=$(_cap_probe "$1")
    [[ ${CAPS[$1]} == 1 ]]
}
_cap_probe() {
    local r=0
    case $1 in
        selinux)      $LIVE && [[ -e /sys/fs/selinux/enforce ]] && command -v chcon >/dev/null && r=1 ;;
        journald)     [[ -S /run/systemd/journal/socket ]] && logger --help 2>&1 | grep -q -- '--journald' && r=1 ;;
        syslog)       [[ -S /dev/log ]] && command -v logger >/dev/null && r=1 ;;
        fcntl_lock)   flock --help 2>&1 | grep -q -- '--fcntl' && r=1 ;;
        openssl6)     [[ $(printf 'x\n' | openssl passwd -6 -stdin 2>/dev/null) == '$6$'* ]] && r=1 ;;
        yescrypt)     command -v mkpasswd >/dev/null && mkpasswd -m help 2>&1 | grep -qw yescrypt && r=1 ;;
        nscd)         [[ -S /run/nscd/socket || -S /var/run/nscd/socket ]] && command -v nscd >/dev/null && r=1 ;;
        sssd)         [[ -S /var/lib/sss/pipes/nss ]] && command -v sss_cache >/dev/null && r=1 ;;
        systemd)      [[ -d /run/systemd/system ]] && r=1 ;;
        *)            command -v "$1" >/dev/null 2>&1 && r=1 ;;
    esac
    echo "$r"
}

pkg_hint() {
    case $1 in
        flock|setpriv|logger|mountpoint) REPLY="util-linux" ;;
        openssl)    REPLY="openssl" ;;
        visudo)     REPLY="sudo" ;;
        ssh-keygen) REPLY="openssh-client (Debian) / openssh-clients (RHEL)" ;;
        pwscore)    REPLY="libpwquality-tools (Debian) / libpwquality (RHEL)" ;;
        mkpasswd)   REPLY="whois (Debian) / mkpasswd (RHEL, EPEL)" ;;
        iconv)      REPLY="libc-bin (Debian) / glibc-common (RHEL)" ;;
        tar|gzip)   REPLY="$1" ;;
        *)          REPLY="coreutils" ;;
    esac
}
need() {
    local b
    for b; do
        command -v "$b" >/dev/null 2>&1 && continue
        pkg_hint "$b"
        die "$E_FAIL" "required tool '$b' is not installed" "nothing was changed" "install the package that provides it: $REPLY"
    done
}

# Tools every mutating command relies on (checked before anything is touched).
readonly CORE_TOOLS="awk sort cp mv ln rm mkdir chmod chown stat mktemp cmp flock sha256sum tail sync date od tar gzip"

preflight() {
    if (( EUID != 0 )); then
        die "$E_FAIL" "UMC must run as root" "nothing was changed" "run it with sudo"
    fi
    # shellcheck disable=SC2086  # word splitting of the tool list is intended
    need $CORE_TOOLS
    if ! $LIVE; then
        [[ -d $R && -f $F_PASSWD ]] ||
            die "$E_USAGE" "--root $R does not look like a Linux root tree (no $F_PASSWD)"
    fi
    [[ -f $F_PASSWD && -f $F_SHADOW && -f $F_GROUP ]] ||
        die "$E_FAIL" "the account databases are incomplete (need $F_PASSWD, $F_SHADOW, $F_GROUP)"
}

# ==============================================================================
# §3  AUDIT TRAIL
#     Every change is recorded twice:
#       * journald with structured fields: journalctl UMC_ACTION=user.create
#         (plain syslog/authpriv when journald is absent)
#       * /var/log/umc/audit.jsonl, one JSON object per line. Each line stores
#         the SHA-256 of the line before it, so editing or deleting a line
#         breaks the chain ('umc log verify'). Each line's own hash also goes
#         to journald, so rewriting the whole file is detectable too.
#     Root can still rewrite both locally; forwarding logs off the host is the
#     real control. Tamper-*evident*, not tamper-*proof*.
#     Secrets are never passed to audit_event.
# ==============================================================================

ACTOR="" ACTOR_LOGINUID="" ACTOR_SUDO="" ACTOR_TTY="" ACTOR_FROM=""
audit_actor_init() {
    local lu=""
    [[ -r /proc/self/loginuid ]] && read -r lu < /proc/self/loginuid
    [[ $lu == 4294967295 ]] && lu=""
    ACTOR_LOGINUID=$lu
    ACTOR_SUDO=${SUDO_USER:-}
    ACTOR_TTY=$(tty 2>/dev/null) || ACTOR_TTY=""
    ACTOR_FROM=${SSH_CLIENT:-}
    ACTOR_FROM=${ACTOR_FROM%% *}
    # loginuid is set by the kernel at login and survives sudo/su, so it names
    # the human even after 'sudo -i'.
    if [[ -n $lu ]]; then
        local ent
        ent=$(getent passwd "$lu" 2>/dev/null) && ACTOR=${ent%%:*}
    fi
    [[ -n $ACTOR ]] || ACTOR=${ACTOR_SUDO:-$(id -un 2>/dev/null || echo "uid$EUID")}
}

_sha256() { REPLY=$(printf '%s\n' "$1" | sha256sum); REPLY=${REPLY%% *}; }

# audit_event ACTION TARGET RESULT [DETAIL]
audit_event() {
    local action=$1 target=$2 result=$3 detail=${4:-} fd last prev seq=1 ts line prio=5
    detail=${detail//$'\n'/ }
    [[ -d $LOG_DIR ]] || mkdir -p -m 0700 -- "$LOG_DIR" 2>/dev/null || return 1
    exec {fd}>>"$AUDIT_LOG" || return 1
    if ! flock -w 10 "$fd"; then exec {fd}>&-; return 1; fi
    last=$(tail -n 1 -- "$AUDIT_LOG" 2>/dev/null) || last=""
    if [[ -n $last ]]; then
        _sha256 "$last"; prev=$REPLY
        [[ $last =~ ^\{\"seq\":([0-9]+), ]] && seq=$((BASH_REMATCH[1] + 1))
    else
        prev=0000000000000000000000000000000000000000000000000000000000000000
    fi
    printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1
    local f_host f_actor f_sudo f_tty f_from f_action f_target f_result f_txn f_detail f_root
    json_str "${HOSTNAME:-}"; f_host=$REPLY
    json_str "$ACTOR";        f_actor=$REPLY
    json_str "$ACTOR_SUDO";   f_sudo=$REPLY
    json_str "$ACTOR_TTY";    f_tty=$REPLY
    json_str "$ACTOR_FROM";   f_from=$REPLY
    json_str "$action";       f_action=$REPLY
    json_str "$target";       f_target=$REPLY
    json_str "$result";       f_result=$REPLY
    json_str "$TXN_ID";       f_txn=$REPLY
    json_str "$detail";       f_detail=$REPLY
    json_str "$R";            f_root=$REPLY
    line="{\"seq\":$seq,\"ts\":\"$ts\",\"host\":$f_host,\"actor\":$f_actor,\"loginuid\":\"$ACTOR_LOGINUID\",\"sudo_user\":$f_sudo,\"tty\":$f_tty,\"from\":$f_from,\"root\":$f_root,\"action\":$f_action,\"target\":$f_target,\"result\":$f_result,\"txn\":$f_txn,\"detail\":$f_detail,\"prev\":\"$prev\"}"
    printf '%s\n' "$line" >&"$fd"
    exec {fd}>&-

    [[ $result == error || $result == rolled-back ]] && prio=3
    local msg="umc: $action ${target:+$target }by $ACTOR: $result${TXN_ID:+ (txn $TXN_ID)}${detail:+ - $detail}"
    _sha256 "$line"
    if cap_has journald; then
        printf 'MESSAGE=%s\nPRIORITY=%s\nSYSLOG_IDENTIFIER=umc\nUMC_ACTION=%s\nUMC_TARGET=%s\nUMC_ACTOR=%s\nUMC_RESULT=%s\nUMC_TXN=%s\nUMC_ROOT=%s\nUMC_SEQ=%s\nUMC_CHAIN=%s\n' \
            "$msg" "$prio" "$action" "$target" "$ACTOR" "$result" "$TXN_ID" "$R" "$seq" "$REPLY" |
            logger --journald 2>/dev/null || true
    elif cap_has syslog; then
        logger -t umc -p "authpriv.$([[ $prio == 3 ]] && echo err || echo notice)" -- "$msg" 2>/dev/null || true
    fi
    return 0
}

# ==============================================================================
# §4  LOCKING
#     Linux has two independent locking conventions for the account files and
#     the kernel does not make them exclude each other, so UMC takes both:
#       1. /etc/.pwd.lock - lckpwdf(3), a POSIX fcntl() lock used by glibc,
#          pam_unix (password changes, incl. chpasswd on Debian), vipw and
#          systemd-sysusers. Taken with 'flock --fcntl' (an OFD lock, which
#          conflicts with lckpwdf) on util-linux >= 2.39; older systems get a
#          tiny python3 or perl helper that holds the same fcntl lock for as
#          long as UMC runs (and loses it automatically if UMC is killed).
#       2. /etc/passwd.lock, shadow.lock, group.lock, gshadow.lock - the
#          shadow-utils hard-link protocol used by useradd, usermod, passwd,
#          chage, gpasswd (lib/commonio.c): write your PID to FILE.PID, then
#          link() it to FILE.lock. link() fails if the lock exists, so exactly
#          one process wins; a lock whose PID is dead is stale.
#     Order is fixed (umc -> .pwd.lock -> passwd -> shadow -> group -> gshadow),
#     the same order shadow-utils uses, so two tools can never deadlock.
#     Locks are taken BEFORE the files are read; read-modify-write without a
#     lock is how v1 lost concurrent password changes (F-13).
# ==============================================================================

LK_UMC_FD="" LK_PWD_FD="" LK_HL=() LK_PWD_PID="" LK_PWD_IN=""

lk_umc() {
    mkdir -p -- "${UMC_LOCK%/*}" || die "$E_FAIL" "cannot create ${UMC_LOCK%/*}"
    exec {LK_UMC_FD}>>"$UMC_LOCK" || die "$E_FAIL" "cannot open $UMC_LOCK"
    if ! flock -w "${CFG[lock_timeout]}" "$LK_UMC_FD"; then
        local holder=""
        read -r holder < "$UMC_LOCK" 2>/dev/null || true
        die "$E_LOCKED" "another UMC process is running${holder:+ (pid $holder)}" "nothing was changed" \
            "wait for it to finish; 'umc locks' shows who holds which lock"
    fi
    # Record the holder only AFTER acquiring the lock. v1 truncated the file
    # before locking and so erased the running instance's PID (F-14).
    printf '%s\n' "$BASHPID" > "$UMC_LOCK"
}

# Helpers that hold an fcntl() write lock on $1 until stdin closes. Used only
# when 'flock --fcntl' is missing. They print "locked" or "busy".
readonly LCKPWDF_PY='import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
end = time.time() + float(sys.argv[2])
while True:
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
    except OSError:
        if time.time() >= end: print("busy", flush=True); sys.exit(1)
        time.sleep(0.2)
print("locked", flush=True)
sys.stdin.read()'
readonly LCKPWDF_PL='use Fcntl; my ($f, $t) = @ARGV;
sysopen(my $fh, $f, O_RDWR | O_CREAT, 0600) or die "open $f: $!";
my $end = time + $t; my $lk = pack("s s x4 q q l x4", F_WRLCK, 0, 0, 0, 0);
until (fcntl($fh, F_SETLK, $lk)) { if (time >= $end) { print "busy\n"; exit 1 } select(undef, undef, undef, 0.2) }
$| = 1; print "locked\n"; while (<STDIN>) {}'

# lckpwdf_method -> REPLY: flock | python3 | perl | none
lckpwdf_method() {
    if cap_has fcntl_lock; then REPLY=flock
    elif command -v python3 >/dev/null 2>&1; then REPLY=python3
    elif command -v perl >/dev/null 2>&1 && perl -MConfig -e 'exit(($Config{longsize} == 8 && $Config{byteorder} =~ /^1234/) ? 0 : 1)' 2>/dev/null; then REPLY=perl
    else REPLY=none
    fi
}

lk_pwd() {
    $LIVE || return 0                  # shadow-utils skips lckpwdf with --prefix, too
    local t=${CFG[lock_timeout]} line=""
    lckpwdf_method
    case $REPLY in
        flock)
            exec {LK_PWD_FD}>>"$ETC/.pwd.lock" || die "$E_FAIL" "cannot open $ETC/.pwd.lock"
            flock --fcntl -w "$t" "$LK_PWD_FD" && return 0 ;;
        python3|perl)
            # Signals are ignored in the helper so a Ctrl-C cannot drop the lock mid-commit.
            if [[ $REPLY == python3 ]]; then
                coproc LKPWD { trap '' INT TERM HUP; exec python3 -c "$LCKPWDF_PY" "$ETC/.pwd.lock" "$t"; }
            else
                coproc LKPWD { trap '' INT TERM HUP; exec perl -e "$LCKPWDF_PL" "$ETC/.pwd.lock" "$t"; }
            fi
            # shellcheck disable=SC2153  # LKPWD_PID is set by 'coproc LKPWD'
            LK_PWD_PID=$LKPWD_PID LK_PWD_IN=${LKPWD[1]}
            read -r -t $((t + 5)) line <&"${LKPWD[0]}" || line=""
            [[ $line == locked ]] && return 0 ;;
        none)
            return 0 ;;                # documented: hard-link locks only (umc doctor shows this)
    esac
    die "$E_LOCKED" "$ETC/.pwd.lock is held (a password change through PAM, or vipw, is in progress)" \
        "nothing was changed" "retry in a moment"
}

# lk_hl FILE - shadow-utils compatible lock on FILE (creates FILE.lock).
lk_hl() {
    local file=$1 lock=$1.lock tmp=$1.$BASHPID pid deadline links
    deadline=$((SECONDS + CFG[lock_timeout]))
    while :; do
        rm -f -- "$tmp"
        printf '%s' "$BASHPID" > "$tmp" || die "$E_FAIL" "cannot create $tmp"
        if ln -- "$tmp" "$lock" 2>/dev/null; then
            links=$(stat -c %h -- "$tmp")
            rm -f -- "$tmp"
            [[ $links == 2 ]] || die "$E_LOCKED" "lock $lock is inconsistent (link count $links)"
            LK_HL+=("$lock")
            return 0
        fi
        rm -f -- "$tmp"
        pid=""
        read -r pid < "$lock" 2>/dev/null || true
        if [[ $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null && [[ ! -d /proc/$pid ]]; then
            warn "removing stale lock $lock (process $pid no longer exists)"
            rm -f -- "$lock"
            continue
        fi
        if ((SECONDS >= deadline)); then
            local who=""
            [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/comm ]] && read -r who < "/proc/$pid/comm"
            die "$E_LOCKED" "$file is locked by ${who:-process} ${pid:-?} (another tool is editing accounts)" \
                "nothing was changed" "retry when it finishes; 'umc locks' shows all lock holders"
        fi
        sleep 1
    done
}

lk_acquire_db() {
    lk_umc
    lk_pwd
    local f
    for f in "$F_PASSWD" "$F_SHADOW" "$F_GROUP" "$F_GSHADOW"; do
        [[ -e $f ]] && lk_hl "$f"
    done
    return 0
}

lk_release_all() {
    local i l pid
    for ((i = ${#LK_HL[@]} - 1; i >= 0; i--)); do
        l=${LK_HL[i]}
        pid=""
        read -r pid < "$l" 2>/dev/null || true
        [[ $pid == "$BASHPID" ]] && rm -f -- "$l"   # never remove someone else's lock
    done
    LK_HL=()
    if [[ -n $LK_PWD_FD ]]; then exec {LK_PWD_FD}>&-; LK_PWD_FD=""; fi
    if [[ -n $LK_PWD_PID ]]; then
        [[ -n $LK_PWD_IN ]] && { exec {LK_PWD_IN}>&- 2>/dev/null || true; }
        kill "$LK_PWD_PID" 2>/dev/null
        wait "$LK_PWD_PID" 2>/dev/null
        LK_PWD_PID="" LK_PWD_IN=""
    fi
    if [[ -n $LK_UMC_FD ]]; then exec {LK_UMC_FD}>&-; LK_UMC_FD=""; fi
    return 0
}

# ==============================================================================
# §5  DATABASE & TRANSACTIONS
#     The four files are loaded into memory once, under lock. Operations change
#     individual entries by name (never regex over whole lines: v1's F-10/F-11),
#     and untouched lines are written back byte-for-byte. txn_commit then runs
#     the protocol from shadow-utils' commonio.c:
#
#       render -> validate -> blast-radius check -> journal pre-images
#       -> [signals blocked] for each file: temp file IN THE SAME DIRECTORY
#          (mktemp: root-owned, 0600, O_EXCL), copy owner/mode/SELinux label
#          from the original, fsync, keep FILE- backup, rename() over the
#          original -> fsync the directory -> [signals restored]
#       -> verify what is on disk (and through NSS) -> roll back on mismatch
#
#     rename() is atomic only within one filesystem, which is why the temp file
#     lives next to its target and not in /tmp (v1: F-01, F-04).
# ==============================================================================

# Accessed through namerefs (local -n _L=${db}_L), which shellcheck cannot see.
# shellcheck disable=SC2034
declare -a PW_L=() SP_L=() GR_L=() GS_L=()
# shellcheck disable=SC2034
declare -A PW_I=() SP_I=() GR_I=() GS_I=() DB_DUPS=() DB_DIRTY=() DB_HAS=()
readonly DEL=$'\x01'                  # tombstone for a deleted line

db_path() {
    case $1 in
        PW) REPLY=$F_PASSWD ;; SP) REPLY=$F_SHADOW ;;
        GR) REPLY=$F_GROUP ;;  GS) REPLY=$F_GSHADOW ;;
        *) bug "db_path: unknown database '$1'" ;;
    esac
}

db_load() {
    local k
    DB_DUPS=() DB_DIRTY=()
    for k in PW SP GR GS; do _db_load_one "$k"; done
    return 0
}
_db_load_one() {
    local -n _L=${1}_L
    db_path "$1"
    _L=()
    if [[ -f $REPLY ]]; then
        mapfile -t _L < "$REPLY" || die "$E_FAIL" "cannot read $REPLY"
        DB_HAS[$1]=1
    else
        DB_HAS[$1]=0
    fi
    _db_reindex "$1"
}
_db_reindex() {
    local -n _L=${1}_L _I=${1}_I
    local i line name
    _I=()
    for i in "${!_L[@]}"; do
        line=${_L[i]}
        [[ $line == "$DEL" || $line != *:* ]] && continue
        name=${line%%:*}
        [[ -z $name || $name == [+-]* ]] && continue    # NIS compat entries: left alone
        # shellcheck disable=SC2004  # _I is an associative array (via nameref): the $ is required
        if [[ -n ${_I[$name]+x} ]]; then DB_DUPS[$1:$name]=1; else _I[$name]=$i; fi
    done
}

db_exists() { local -n _I=${1}_I; [[ -n ${_I[$2]+x} ]]; }
db_line()   { local -n _L=${1}_L _I=${1}_I; [[ -n ${_I[$2]+x} ]] || return 1; REPLY=${_L[${_I[$2]}]}; }

# split_fields LINE -> F[] (empty and trailing fields kept; no globbing, no IFS games)
split_fields() {
    local s=$1
    F=()
    while [[ $s == *:* ]]; do F+=("${s%%:*}"); s=${s#*:}; done
    F+=("$s")
}
db_fields() { db_line "$1" "$2" || return 1; split_fields "$REPLY"; }
join_fields() { local IFS=:; REPLY="$*"; }

_db_check_dup() {
    [[ -z ${DB_DUPS[$1:$2]+x} ]] && return 0
    db_path "$1"
    die "$E_INTEGRITY" "$REPLY contains more than one entry named '$2'; refusing to guess which one to change" \
        "nothing was changed" "fix the duplicate by hand (vipw / vigr), then retry"
}

# db_put DB NAME LINE - insert or replace the entry NAME.
db_put() {
    local -n _L=${1}_L _I=${1}_I
    _db_check_dup "$1" "$2"
    [[ ${3%%:*} == "$2" ]] || bug "db_put: entry does not start with '$2:'"
    [[ $3 != *[$'\n\r']* ]] || bug "db_put: line break inside an entry"
    if [[ -n ${_I[$2]+x} ]]; then
        _L[${_I[$2]}]=$3
    else
        _L+=("$3")
        _I[$2]=$((${#_L[@]} - 1))
    fi
    DB_DIRTY[$1]=1
}
db_del() {
    local -n _L=${1}_L _I=${1}_I
    _db_check_dup "$1" "$2"
    [[ -n ${_I[$2]+x} ]] || return 0
    _L[${_I[$2]}]=$DEL
    unset "_I[$2]"
    DB_DIRTY[$1]=1
}
# db_names DB -> NAMES[] in file order
db_names() {
    local -n _L=${1}_L
    local line name
    NAMES=()
    for line in "${_L[@]}"; do
        [[ $line == "$DEL" || $line != *:* ]] && continue
        name=${line%%:*}
        [[ -z $name || $name == [+-]* ]] && continue
        NAMES+=("$name")
    done
}
db_render() {
    local -n _L=${1}_L
    local line out=()
    for line in "${_L[@]}"; do [[ $line == "$DEL" ]] || out+=("$line"); done
    if ((${#out[@]})); then printf '%s\n' "${out[@]}" > "$2"; else : > "$2"; fi
}

# Comma-separated member lists (group field 4, gshadow fields 3 and 4):
# exact-token matching, so removing 'bob' can never touch 'bobby' (v1: F-10).
list_has() { [[ ",$1," == *",$2,"* ]]; }
list_add() { if [[ -z $1 ]]; then REPLY=$2; elif list_has "$1" "$2"; then REPLY=$1; else REPLY=$1,$2; fi; }
list_del() {
    local IFS=, t out=()
    for t in $1; do [[ -n $t && $t != "$2" ]] && out+=("$t"); done
    REPLY="${out[*]}"
}
list_rename() {
    local IFS=, t out=()
    for t in $1; do [[ $t == "$2" ]] && t=$3; [[ -n $t ]] && out+=("$t"); done
    REPLY="${out[*]}"
}

# --- transactions ---------------------------------------------------------------
TXN_ACTION="" TXN_SUMMARY="" WORK="" TXN_SEQ=0 TXN_ORDER=publish TXN_RESTORE=false TXN_CHANGED=false
declare -A TXN_TARGET=() TXN_XNEW=() TXN_XIDX=()
declare -a TXN_XFILES=() TXN_VERIFY=() TXN_EFFECTS=() TXN_INSTALLED=()

txn_begin() {   # ACTION SUMMARY
    TXN_ACTION=$1 TXN_SUMMARY=$2
    TXN_SEQ=$((TXN_SEQ + 1))
    printf -v TXN_ID '%(%Y%m%dT%H%M%SZ)T-%s-%s' -1 "$BASHPID" "$TXN_SEQ"
    mkdir -p -m 0700 -- "$STATE" "$TXN_DIR" || die "$E_FAIL" "cannot create $TXN_DIR"
    WORK=$(mktemp -d -- "$STATE/work.XXXXXX") || die "$E_FAIL" "cannot create a private work directory in $STATE"
    CLEANUP+=("$WORK")
    mkdir -- "$WORK/new" "$WORK/x" || die "$E_FAIL" "cannot prepare $WORK"
    TXN_TARGET=() TXN_XNEW=() TXN_XIDX=() TXN_XFILES=() TXN_VERIFY=() TXN_EFFECTS=() TXN_INSTALLED=()
    TXN_ORDER=publish TXN_RESTORE=false TXN_CHANGED=false MANAGED_DIRTY=false
    TXN_PHASE=staged
    SUBID_NEXT=() SUBID_HAS=()
}

# Declare the blast radius: which entries this transaction is *meant* to touch.
txn_target()       { local k=$1 n; shift; for n; do TXN_TARGET[$k:$n]=1; done; }
txn_target_user()  { txn_target PW "$1"; txn_target SP "$1"; }
txn_target_group() { txn_target GR "$1"; txn_target GS "$1"; }

# txn_xfile PATH [MODE OWNER GROUP] -> REPLY = staging copy to edit.
# For files other than the four databases (sudoers.d, subuid, login.defs,
# UMC's own state). A file that does not exist yet is created with MODE.
txn_xfile() {
    local p=$1 i
    if [[ -n ${TXN_XIDX[$p]+x} ]]; then REPLY=$WORK/x/${TXN_XIDX[$p]}; return 0; fi
    i=${#TXN_XFILES[@]}
    TXN_XFILES+=("$p")
    TXN_XIDX[$p]=$i
    if [[ -e $p || -L $p ]]; then
        [[ -f $p && ! -L $p ]] || die "$E_INTEGRITY" "$p is not a regular file; refusing to replace it"
        cp -- "$p" "$WORK/x/$i" || die "$E_FAIL" "cannot stage $p"
    else
        : > "$WORK/x/$i"
        TXN_XNEW[$p]="${2:-0600} ${3:-0} ${4:-0}"
    fi
    REPLY=$WORK/x/$i
}
txn_xdelete() { txn_xfile "$1"; : > "$REPLY.delete"; }

# Installs NEW as DST using the commit protocol. $3 = "db" keeps a DST- backup.
_install_file() {
    local new=$1 dst=$2 kind=${3:-x} dir base tmp meta
    dir=${dst%/*} base=${dst##*/}
    [[ -d $dir ]] || mkdir -p -- "$dir" || return 1
    tmp=$(mktemp -- "$dir/.$base.umc.XXXXXX") || return 1
    CLEANUP+=("$tmp")
    cat -- "$new" > "$tmp" || return 1
    if [[ -e $dst ]]; then
        chown --reference="$dst" -- "$tmp" && chmod --reference="$dst" -- "$tmp" || return 1
        if cap_has selinux; then chcon --reference="$dst" -- "$tmp" 2>/dev/null || true; fi
    else
        meta=${TXN_XNEW[$dst]:-"0644 0 0"}
        read -r m o g <<< "$meta"
        chown "$o:$g" -- "$tmp" && chmod "$m" -- "$tmp" || return 1
    fi
    sync -- "$tmp" || return 1                       # data on disk before the rename
    if [[ $kind == db && -e $dst ]]; then
        ln -f -- "$dst" "$dst-" || return 1          # shadow-utils style FILE- backup
    fi
    mv -f -T -- "$tmp" "$dst" || return 1
    if cap_has selinux && [[ ! -e $dst- || $kind != db ]] && cap_has restorecon; then
        restorecon -- "$dst" 2>/dev/null || true
    fi
    TXN_INSTALLED+=("$dst")
    return 0
}

# Test hook: UMC_FAULT=kill-after-install:N makes UMC SIGKILL itself right
# after the N-th file of a commit is in place, to prove crash recovery.
# Honoured ONLY in --root sandbox mode; it does nothing on a live system.
_fault_point() {
    $LIVE && return 0
    [[ ${UMC_FAULT:-} == "kill-after-install:$1" ]] && kill -KILL "$BASHPID"
    return 0
}

txn_commit() {
    local k f i changed=() xchanged=() src nfile=0
    [[ $TXN_PHASE == staged ]] || bug "txn_commit called in phase $TXN_PHASE"
    $MANAGED_DIRTY && _managed_flush

    # 1. Render the staged databases; drop files whose content did not change,
    #    so re-running a command that is already satisfied changes nothing.
    for k in GR GS SP PW; do
        [[ -n ${DB_DIRTY[$k]+x} ]] || continue
        db_render "$k" "$WORK/new/$k"
        db_path "$k"
        cmp -s -- "$WORK/new/$k" "$REPLY" || changed+=("$k")
    done
    for i in "${!TXN_XFILES[@]}"; do
        f=${TXN_XFILES[i]} src=$WORK/x/$i
        if [[ -e $src.delete ]]; then
            [[ -e $f ]] && xchanged+=("$i")
        elif [[ ! -e $f ]] || ! cmp -s -- "$src" "$f"; then
            xchanged+=("$i")
        fi
    done
    if ((${#changed[@]} + ${#xchanged[@]} == 0)); then
        TXN_PHASE=none TXN_CHANGED=false
        return 0
    fi

    # 2. Validate: structure, invariants, blast radius.
    $TXN_RESTORE || txn_validate "${changed[@]}"
    for i in "${xchanged[@]}"; do _validate_xfile "${TXN_XFILES[i]}" "$WORK/x/$i"; done

    # 3. Dry run stops here.
    if $OPT_DRY_RUN; then
        txn_show_diff "${changed[@]}" -- "${xchanged[@]}"
        TXN_PHASE=none TXN_CHANGED=false
        return 0
    fi

    # 4. Journal: pre-images + post-images + checksums, fsync'd.
    txn_journal_write "${changed[@]}" -- "${xchanged[@]}"

    # 5. Install.
    local order=(GR GS SP PW)
    [[ $TXN_ORDER == unpublish ]] && order=(PW SP GS GR)   # deletions: make the user disappear first
    TXN_PHASE=committing
    _txn_meta_set state committing
    critical_begin
    for k in "${order[@]}"; do
        [[ " ${changed[*]} " == *" $k "* ]] || continue
        db_path "$k"
        _install_file "$WORK/new/$k" "$REPLY" db || _txn_commit_failed "$REPLY"
        nfile=$((nfile + 1)); _fault_point "$nfile"
    done
    for i in "${xchanged[@]}"; do
        f=${TXN_XFILES[i]}
        if [[ -e $WORK/x/$i.delete ]]; then
            rm -f -- "$f" || _txn_commit_failed "$f"
            TXN_INSTALLED+=("$f")
        else
            _install_file "$WORK/x/$i" "$f" x || _txn_commit_failed "$f"
        fi
    done
    local d dirs=()
    for f in "${TXN_INSTALLED[@]}"; do
        d=${f%/*}
        [[ " ${dirs[*]} " == *" $d "* ]] || dirs+=("$d")
    done
    sync -- "${dirs[@]}" 2>/dev/null || sync
    _txn_meta_set state committed
    TXN_PHASE=committed TXN_CHANGED=true
    critical_end

    # 6. Verify, and undo everything if the result is not what was intended.
    txn_verify
    txn_prune
    return 0
}

# A step of the install failed (disk full, I/O error...): put back every file
# that was already replaced, from the journal.
_txn_commit_failed() {
    local what=$1
    if _txn_install_images "$TXN_DIR/$TXN_ID" pre; then
        _txn_meta_set state rolled-back
        TXN_PHASE=rolledback
        critical_end
        die "$E_ROLLEDBACK" "could not install $what (disk full or I/O error?)" "" \
            "check free space and 'dmesg', then retry"
    fi
    critical_end
    die "$E_INTEGRITY" "could not install $what, and restoring the previous files also failed" \
        "PARTIALLY CHANGED - the journal $TXN_DIR/$TXN_ID holds the previous files" \
        "fix the disk problem, then run: umc recover"
}

txn_verify() {
    local d=$TXN_DIR/$TXN_ID n rel why="" drift=() line lost=""
    # (a) What is on disk should be byte-identical to what was written. If it
    #     is not, a program that ignores the account-file locks wrote at the
    #     same time. Restoring our pre-images would then destroy ITS change,
    #     so in that case UMC never rolls back: it checks that its own entries
    #     survived and reports.
    while IFS=$'\t' read -r n rel _; do
        if [[ -e $d/post/$n.absent ]]; then [[ -e $R$rel ]] && drift+=("$rel"); continue; fi
        cmp -s -- "$d/post/$n" "$R$rel" || drift+=("$rel")
    done < "$d/files"
    if ((${#drift[@]})); then
        local t db nm fpath
        for t in "${!TXN_TARGET[@]}"; do
            db=${t%%:*} nm=${t#*:}
            db_path "$db"; fpath=$REPLY
            [[ " ${drift[*]} " == *" ${fpath#"$R"} "* ]] || continue
            # the entry as UMC wrote it must still be in the file
            if db_line "$db" "$nm"; then grep -qxF -- "$REPLY" "$fpath" || lost+=" $nm"; fi
        done
        if [[ -n $lost ]]; then
            die "$E_INTEGRITY" "another program rewrote ${drift[*]} at the same time without honouring the account-file locks, and UMC's change to:$lost was overwritten" \
                "COMMITTED BUT OVERWRITTEN by the other program (journal: $d); nothing was rolled back, so the other program's change is kept" \
                "re-run the same command; 'umc doctor' shows which lock protocols this host supports"
        fi
        warn "another program changed ${drift[*]} during the commit; UMC's own entries are intact"
    fi
    # (b) Live systems: flush name-service caches, then resolve through NSS
    #     exactly like login would.
    if [[ -z $why ]] && $LIVE; then
        nss_flush
        local c kind name id ent
        for c in "${TXN_VERIFY[@]}"; do
            IFS=: read -r kind name id <<< "$c"
            case $kind in
                user)  ent=$(getent passwd "$name" 2>/dev/null) || { why="getent cannot see new user '$name'"; break; }
                       split_fields "$ent"; [[ ${F[2]} == "$id" ]] || { why="getent returns uid ${F[2]} for '$name' (expected $id)"; break; } ;;
                group) ent=$(getent group "$name" 2>/dev/null) || { why="getent cannot see new group '$name'"; break; }
                       split_fields "$ent"; [[ ${F[2]} == "$id" ]] || { why="getent returns gid ${F[2]} for '$name' (expected $id)"; break; } ;;
            esac
        done
    fi
    [[ -z $why ]] && return 0
    ((${#drift[@]})) && die "$E_INTEGRITY" "post-commit verification failed: $why" \
        "COMMITTED; not rolled back because another program changed the same files" "inspect with: umc show $TXN_ID"

    critical_begin
    if _txn_install_images "$d" pre; then
        _txn_meta_set state rolled-back
        TXN_PHASE=rolledback
        critical_end
        $LIVE && nss_flush
        die "$E_ROLLEDBACK" "post-commit verification failed: $why" "" \
            "inspect 'nsswitch.conf' and other tools editing accounts; details: umc show $TXN_ID"
    fi
    critical_end
    die "$E_INTEGRITY" "verification failed ($why) and the automatic rollback failed" \
        "PARTIALLY CHANGED - journal: $d" "run: umc recover"
}

nss_flush() {
    if cap_has nscd; then nscd -i passwd 2>/dev/null; nscd -i group 2>/dev/null; fi
    if cap_has sssd; then sss_cache -UG 2>/dev/null; fi
    return 0
}

# --- journal ----------------------------------------------------------------------
# $TXN_DIR/<id>/  meta (key=value), files (n<TAB>path<TAB>mode uid gid),
#                 pre/<n> and post/<n> (or <n>.absent), SHA256SUMS
txn_journal_write() {
    local d=$TXN_DIR/$TXN_ID k i n=0 p rel st sep=false
    mkdir -m 0700 -- "$d" "$d/pre" "$d/post" || die "$E_FAIL" "cannot create journal $d"
    : > "$d/files"
    for k in "$@"; do
        if [[ $k == -- ]]; then sep=true; continue; fi
        if $sep; then
            p=${TXN_XFILES[k]}
            _journal_add "$d" "$n" "$p" "$WORK/x/$k"
        else
            db_path "$k"; p=$REPLY
            _journal_add "$d" "$n" "$p" "$WORK/new/$k"
        fi
        n=$((n + 1))
    done
    ( cd -- "$d" && sha256sum -- pre/* post/* > SHA256SUMS ) || die "$E_FAIL" "cannot checksum journal $d"
    {
        printf 'id=%s\n' "$TXN_ID"
        printf 'ts=%(%Y-%m-%dT%H:%M:%SZ)T\nepoch=%(%s)T\n' -1 -1
        printf 'actor=%s\n' "$ACTOR"
        printf 'action=%s\n' "$TXN_ACTION"
        printf 'summary=%s\n' "${TXN_SUMMARY//$'\n'/ }"
        printf 'root=%s\n' "$R"
        printf 'state=prepared\n'
    } > "$d/meta" || die "$E_FAIL" "cannot write journal $d"
    sync -- "$d"/pre/* "$d"/post/* "$d/files" "$d/SHA256SUMS" "$d/meta" "$d" "$TXN_DIR" 2>/dev/null ||
        die "$E_FAIL" "cannot fsync journal $d"
}
_journal_add() {   # DIR N PATH NEWCONTENT
    local d=$1 n=$2 p=$3 new=$4 rel=${3#"$R"} st
    if [[ -e $p ]]; then
        cp -- "$p" "$d/pre/$n" || die "$E_FAIL" "cannot journal $p"
        st=$(stat -c '%a %u %g' -- "$p")
    else
        : > "$d/pre/$n.absent"
        st=${TXN_XNEW[$p]:-"0644 0 0"}
    fi
    if [[ -e $new.delete ]]; then : > "$d/post/$n.absent"; else cp -- "$new" "$d/post/$n" || die "$E_FAIL" "cannot journal $p"; fi
    printf '%s\t%s\t%s\n' "$n" "$rel" "$st" >> "$d/files"
}

_txn_meta_set() {   # KEY VALUE (atomic rewrite, fsync'd)
    local m=$TXN_DIR/$TXN_ID/meta tmp
    [[ -f $m ]] || return 0
    tmp=$(mktemp -- "$m.XXXXXX") || return 1
    { grep -v "^$1=" -- "$m"; printf '%s=%s\n' "$1" "$2"; } > "$tmp" && sync -- "$tmp" && mv -f -- "$tmp" "$m" && sync -- "${m%/*}"
}
meta_get() {   # FILE KEY -> REPLY
    REPLY=""
    local k v
    while IFS='=' read -r k v; do [[ $k == "$2" ]] && REPLY=$v; done < "$1"
}

# _txn_install_images DIR pre|post - install a journal's images verbatim.
_txn_install_images() {
    local d=$1 which=$2 n rel st dst rc=0 m o g
    while IFS=$'\t' read -r n rel st; do
        dst=$R$rel
        if [[ -e $d/$which/$n.absent ]]; then
            rm -f -- "$dst" || rc=1
        else
            if [[ ! -e $dst ]]; then read -r m o g <<< "$st"; TXN_XNEW[$dst]="$m $o $g"; fi
            local kind=x
            [[ $dst == "$F_PASSWD" || $dst == "$F_SHADOW" || $dst == "$F_GROUP" || $dst == "$F_GSHADOW" ]] && kind=db
            _install_file "$d/$which/$n" "$dst" "$kind" || rc=1
        fi
    done < "$d/files"
    sync -- "$ETC" 2>/dev/null || sync
    return "$rc"
}

# Crash recovery: a transaction left in state=committing was interrupted
# (SIGKILL, power loss). Put back its pre-images: interrupted transactions are
# rolled back, never left half-applied. Must be called with the locks held.
txn_recover() {
    local m d id
    for m in "$TXN_DIR"/*/meta; do
        [[ -f $m ]] || continue
        grep -qx 'state=committing' -- "$m" || continue
        d=${m%/meta} id=${d##*/}
        ( cd -- "$d" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1 ||
            die "$E_INTEGRITY" "the journal of interrupted transaction $id is damaged" \
                "UNKNOWN - the transaction may be partially applied" \
                "compare $d/pre with the live files by hand (vipw -s / vigr -s)"
        warn "found interrupted transaction $id; restoring the state from before it"
        critical_begin
        if ! _txn_install_images "$d" pre; then
            critical_end
            die "$E_INTEGRITY" "could not restore the files of interrupted transaction $id" \
                "PARTIALLY CHANGED - journal: $d" "fix the underlying problem (disk space?) and run: umc recover"
        fi
        local save=$TXN_ID; TXN_ID=$id
        _txn_meta_set state recovered
        TXN_ID=$save
        critical_end
        audit_event txn.recover "$id" success "interrupted transaction rolled back"
    done
    return 0
}

# Keep the newest txn_keep_count transactions and anything younger than
# txn_keep_days; never prune an unfinished one.
txn_prune() {
    local keep=${CFG[txn_keep_count]} days=${CFG[txn_keep_days]} now ids=() id m st ep i
    printf -v now '%(%s)T' -1
    for m in "$TXN_DIR"/*/meta; do [[ -f $m ]] && ids+=("${m%/meta}"); done
    ((${#ids[@]} > keep)) || return 0
    for ((i = 0; i < ${#ids[@]} - keep; i++)); do
        m=${ids[i]}/meta
        meta_get "$m" state; st=$REPLY
        meta_get "$m" epoch; ep=${REPLY:-$now}
        [[ $st == committing || $st == prepared ]] && continue
        (( now - ep > days * 86400 )) && rm -rf -- "${ids[i]}"
    done
    return 0
}

# --- validation -------------------------------------------------------------------
# Structural checks for one database file. Prints "code|name" per issue.
readonly AWK_VALIDATE='
    /^[+-]/ { next }
    $0 == "" { print "empty-line|line" NR; next }
    {
        n = split($0, f, ":"); name = f[1]
        if (name == "") { print "no-name|line" NR; next }
        if (seen[name]++) print "duplicate|" name
        if (T == "PW") {
            if (n != 7) { print "fields|" name; next }
            if (f[3] !~ /^[0-9]+$/) print "bad-uid|" name
            if (f[4] !~ /^[0-9]+$/) print "bad-gid|" name
            if (f[3] == "0" && name != "root") print "uid0|" name
        } else if (T == "SP") {
            if (n != 9) { print "fields|" name; next }
            if (f[2] == "") print "empty-password|" name
            for (i = 3; i <= 8; i++) if (f[i] !~ /^-?[0-9]*$/) print "bad-number|" name
        } else if (T == "GR") {
            if (n != 4) { print "fields|" name; next }
            if (f[3] !~ /^[0-9]+$/) print "bad-gid|" name
            if (f[4] ~ /(^,|,,|,$)/) print "bad-members|" name
        } else if (T == "GS") {
            if (n != 4) { print "fields|" name; next }
            if (f[3] ~ /(^,|,,|,$)/ || f[4] ~ /(^,|,,|,$)/) print "bad-members|" name
        }
    }'

# Entries whose line differs between two versions of a file (independent of
# the in-memory engine - it compares the actual bytes).
readonly AWK_CHANGED_KEYS='
    function key(l,   i) { i = index(l, ":"); return i ? substr(l, 1, i - 1) : l }
    NR == FNR { old[$0]++; next }
    { new[$0]++ }
    END {
        for (l in old) if (old[l] != new[l]) k[key(l)] = 1
        for (l in new) if (new[l] != old[l]) k[key(l)] = 1
        for (x in k) print x
    }'

txn_validate() {
    local k file new issue name
    declare -A before=()
    for k in "$@"; do
        db_path "$k"; file=$REPLY new=$WORK/new/$k
        # (a) Structure: never introduce an issue that was not already there.
        #     Pre-existing problems are reported by 'umc audit' but do not
        #     block unrelated changes.
        before=()
        if [[ -f $file ]]; then
            while IFS= read -r issue; do before[$issue]=1; done < <(awk -v T="$k" "$AWK_VALIDATE" "$file")
        fi
        while IFS= read -r issue; do
            [[ -n ${before[$issue]+x} ]] && continue
            die "$E_INTEGRITY" "refusing to commit: the new ${file##*/} would contain a problem (${issue%%|*} at '${issue#*|}')" \
                "nothing was changed" "this indicates invalid input or a bug; nothing was written"
        done < <(awk -v T="$k" "$AWK_VALIDATE" "$new")
        # (b) Blast radius: every changed entry must have been declared.
        if [[ -f $file ]]; then
            while IFS= read -r name; do
                [[ -n ${TXN_TARGET[$k:$name]+x} ]] && continue
                die "$E_INTEGRITY" "blast-radius check failed: entry '$name' in ${file##*/} changed but was not part of this operation" \
                    "nothing was changed" "this is a bug in UMC; please report it (nothing was written)"
            done < <(awk "$AWK_CHANGED_KEYS" "$file" "$new")
        fi
    done
    # (c) Invariants that hold no matter what.
    if [[ " $* " == *" PW "* ]] && grep -q '^root:[^:]*:0:' -- "$F_PASSWD"; then
        grep -q '^root:[^:]*:0:' -- "$WORK/new/PW" ||
            die "$E_INTEGRITY" "refusing to commit: root would no longer have UID 0" "nothing was changed"
    fi
    # (d) Cross-file consistency for every entry this transaction touched.
    local t db n
    for t in "${!TXN_TARGET[@]}"; do
        db=${t%%:*} n=${t#*:}
        case $db in
            PW) if db_exists PW "$n"; then
                    db_exists SP "$n" || die "$E_INTEGRITY" "refusing to commit: user '$n' would have no shadow entry" "nothing was changed"
                elif db_exists SP "$n"; then
                    die "$E_INTEGRITY" "refusing to commit: shadow entry '$n' would be orphaned" "nothing was changed"
                fi ;;
            GR) if [[ ${DB_HAS[GS]} == 1 ]]; then
                    if db_exists GR "$n"; then
                        db_exists GS "$n" || die "$E_INTEGRITY" "refusing to commit: group '$n' would have no gshadow entry" "nothing was changed"
                    elif db_exists GS "$n"; then
                        die "$E_INTEGRITY" "refusing to commit: gshadow entry '$n' would be orphaned" "nothing was changed"
                    fi
                fi ;;
        esac
    done
    return 0
}

_validate_xfile() {   # PATH STAGED
    local p=$1 s=$2
    [[ -e $s.delete ]] && return 0
    case $p in
        "$ETC"/sudoers.d/*)
            if cap_has visudo; then
                local out
                out=$(visudo -c -q -f "$s" 2>&1) ||
                    die "$E_INTEGRITY" "refusing to install ${p#"$R"}: visudo rejects it (${out//$'\n'/ })" "nothing was changed"
            else
                die "$E_FAIL" "visudo is not available; refusing to write sudoers rules without validating them" \
                    "nothing was changed" "install sudo (it provides visudo)"
            fi ;;
        "$ETC"/subuid|"$ETC"/subgid)
            awk -F: 'NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }' "$s" ||
                die "$E_INTEGRITY" "refusing to commit: ${p##*/} would be malformed" "nothing was changed" ;;
    esac
    return 0
}

# Dry-run output: unified diff with password hashes redacted.
readonly AWK_REDACT='BEGIN { FS = OFS = ":" }
    (T == "SP" || T == "GS") && NF > 1 {
        p = $2; pre = ""
        while (substr(p, 1, 1) == "!") { pre = pre "!"; p = substr(p, 2) }
        if (p != "" && p != "*" && p != "!") $2 = pre "<hash>"
    }
    { print }'
txn_show_diff() {
    local k sep=false i f a b
    say ""
    say "  ${C_YELLOW}${C_BOLD}[ DRY RUN ]${C_RESET} nothing will be written. Changes this command would make:"
    for k in "$@"; do
        if [[ $k == -- ]]; then sep=true; continue; fi
        if $sep; then
            f=${TXN_XFILES[k]} a=$WORK/diff.a b=$WORK/x/$k
            if [[ -e $f ]]; then cp -- "$f" "$a"; else : > "$a"; fi
            [[ -e $b.delete ]] && { b=$WORK/diff.empty; : > "$b"; }
            _show_one_diff "${f#"$R"}" "$a" "$b"
        else
            db_path "$k"; f=$REPLY
            awk -v T="$k" "$AWK_REDACT" "$f" > "$WORK/diff.a"
            awk -v T="$k" "$AWK_REDACT" "$WORK/new/$k" > "$WORK/diff.b"
            _show_one_diff "${f#"$R"}" "$WORK/diff.a" "$WORK/diff.b"
        fi
    done
    return 0
}
_show_one_diff() {
    $OPT_JSON && return 0
    if cap_has diff; then
        diff -u --label "a$1" --label "b$1" -- "$2" "$3" | sed 's/^/    /'
    else
        printf '    --- %s\n' "$1"
        awk 'NR == FNR { o[$0]++; next } { n[$0]++; if (!($0 in o)) print "    +" $0 }
             END { for (l in o) if (!(l in n)) print "    -" l }' "$2" "$3"
    fi
    return 0
}

# ==============================================================================
# §6  VALIDATORS & ID ALLOCATION
#     Validators REJECT bad input with a reason; they never silently "fix" it.
#     (v1 turned 'j.doe' into 'jdoe' without telling anyone: F-28.)
# ==============================================================================

VAL_ERR=""
_vfail() { VAL_ERR=$1; return 1; }

val_name() {   # NAME [user|group]
    local n=$1 kind=${2:-user} re=${CFG[name_regex]}
    [[ -n $n ]]                   || _vfail "$kind name is empty" || return 1
    ((${#n} <= CFG[name_max_len])) || _vfail "$kind name '$n' is longer than ${CFG[name_max_len]} characters" || return 1
    [[ $n != -* ]]                || _vfail "$kind name '$n' may not start with '-' (tools would read it as an option)" || return 1
    [[ ! $n =~ ^[0-9]+$ ]]        || _vfail "$kind name '$n' is all digits (tools would confuse it with a numeric ID)" || return 1
    [[ $n != . && $n != .. ]]     || _vfail "'$n' is not a valid $kind name" || return 1
    [[ $n =~ $re ]]               || _vfail "$kind name '$n' does not match the naming policy $re" || return 1
}

val_gecos() {
    [[ $1 != *:* ]]                                || _vfail "the comment (GECOS) may not contain ':'" || return 1
    [[ $1 != *[$'\x01'-$'\x1f'$'\x7f']* ]]         || _vfail "the comment contains control characters" || return 1
    ((${#1} <= 255))                               || _vfail "the comment is longer than 255 characters" || return 1
}

# val_path PATH -> REPLY = normalised absolute path
val_path() {
    local p=$1 s part out=""
    [[ $p == /* ]]                                 || _vfail "'$p' is not an absolute path" || return 1
    [[ $p != *[:$'\x01'-$'\x1f'$'\x7f']* ]]        || _vfail "'$p' contains ':' or control characters" || return 1
    s=${p#/}
    while [[ -n $s ]]; do
        part=${s%%/*}
        if [[ $s == */* ]]; then s=${s#*/}; else s=""; fi
        case $part in
            ''|.) continue ;;
            ..)   _vfail "'$p' may not contain '..'"; return 1 ;;
        esac
        out+=/$part
    done
    REPLY=${out:-/}
}

val_shell() {
    val_path "$1" || return 1
    local s=$REPLY
    case $s in */nologin|/bin/false|/usr/bin/false) REPLY=$s; return 0 ;; esac
    grep -qxF -- "$s" "$ETC/shells" 2>/dev/null || _vfail "shell '$s' is not listed in /etc/shells" || return 1
    [[ -x $R$s ]]                                   || _vfail "shell '$s' does not exist on this system" || return 1
    REPLY=$s
}

# The clock. UMC_NOW (epoch seconds) is honoured ONLY in --root sandbox mode,
# so tests can fast-forward an onboarding deadline without waiting 24 h; it
# can never move time on a live system.
now_epoch() {
    if ! $LIVE && [[ ${UMC_NOW:-} =~ ^[0-9]+$ ]]; then REPLY=$UMC_NOW; else printf -v REPLY '%(%s)T' -1; fi
}
today_days() { now_epoch; REPLY=$((REPLY / 86400)); }
days_to_date() { printf -v REPLY '%(%Y-%m-%d)T' $(($1 * 86400)); }

# val_date DATE -> REPLY = days since 1970-01-01 (shadow format), '' for never.
# Accepts YYYY-MM-DD, 'never', and '+N' (N days from today). Always UTC:
# v1 used local midnight and was a day early east of Greenwich (F-24).
val_date() {
    local d=$1 s
    case $d in
        ''|never|none) REPLY=""; return 0 ;;
    esac
    if [[ $d =~ ^\+([0-9]{1,5})$ ]]; then
        local add=$((10#${BASH_REMATCH[1]}))     # save it: today_days runs its own =~
        today_days; REPLY=$((REPLY + add)); return 0
    fi
    [[ $d =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || _vfail "'$d' is not a date (use YYYY-MM-DD, +DAYS or never)" || return 1
    s=$(date -u -d "$d" +%s 2>/dev/null) && [[ $(date -u -d "@$s" +%F) == "$d" ]] ||
        _vfail "'$d' is not a valid calendar date" || return 1
    REPLY=$((s / 86400))
}

val_uint() {   # LABEL VALUE MIN MAX
    [[ $2 =~ ^[0-9]+$ ]] && (( 10#$2 >= $3 && 10#$2 <= $4 )) || _vfail "$1 must be a number between $3 and $4" || return 1
    REPLY=$((10#$2))
}

# Public SSH keys. Options such as command="..." are refused on purpose.
val_sshkey() {
    local k=$1 t b c f
    k=${k%$'\r'} k=${k##+([[:space:]])} k=${k%%+([[:space:]])}
    [[ $k != *[$'\x01'-$'\x1f']* ]] || _vfail "the SSH key contains control characters" || return 1
    read -r t b c <<< "$k"
    case $t in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
        ssh-dss) _vfail "DSA keys are obsolete (disabled by modern OpenSSH)"; return 1 ;;
        *)       _vfail "not a supported SSH public key (options like command=... are not accepted)"; return 1 ;;
    esac
    [[ $b =~ ^[A-Za-z0-9+/]+={0,3}$ ]] && ((${#b} >= 60)) || _vfail "the SSH key data is not valid base64" || return 1
    if cap_has ssh-keygen; then
        f=$(mktemp) || return 1
        CLEANUP+=("$f")
        printf '%s %s\n' "$t" "$b" > "$f"
        ssh-keygen -l -f "$f" >/dev/null 2>&1 || _vfail "ssh-keygen does not accept this key" || return 1
    fi
    REPLY="$t $b${c:+ $c}"
}

val_hash() {   # a pre-computed crypt(3) hash from a manifest
    case $1 in
        '$6$'*|'$y$'*|'$gy$'*|'$5$'*|'$2b$'*|'$2y$'*) [[ $1 != *[:$'\x01'-$'\x1f'\ ]* ]] && return 0 ;;
        '$1$'*) _vfail "MD5 password hashes are too weak; supply SHA-512 (\$6\$) or yescrypt (\$y\$)"; return 1 ;;
    esac
    _vfail "not a recognised password hash (expected \$6\$... or \$y\$...)"
}

# --- ID allocation -----------------------------------------------------------------
# Like shadow-utils: human IDs are "highest used in [UID_MIN, UID_MAX] + 1" (so a
# deleted user's UID is not recycled at once) and system IDs go top-down.
# A new user's UID must also be free as a GID (user-private group): v1 put new
# users into whatever group already had that number, e.g. docker (F-05).
# On live systems every candidate is also checked against NSS (LDAP/SSSD).
declare -A USED_UID=() USED_GID=()
ID_READY=false
id_init() {
    $ID_READY && return 0
    ID_READY=true
    local line r k v
    USED_UID=() USED_GID=()
    for line in "${PW_L[@]}"; do
        [[ $line == "$DEL" || $line != *:*:*:* ]] && continue
        r=${line#*:} r=${r#*:}; USED_UID[${r%%:*}]=1
    done
    for line in "${GR_L[@]}"; do
        [[ $line == "$DEL" || $line != *:*:*:* ]] && continue
        r=${line#*:} r=${r#*:}; USED_GID[${r%%:*}]=1
    done
    if [[ ${CFG[reuse_ids]} == no && -r $STATE/retired-ids ]]; then
        while read -r k v; do
            [[ $k == u ]] && USED_UID[$v]=1
            [[ $k == g ]] && USED_GID[$v]=1
        done < "$STATE/retired-ids"
    fi
}
id_mark() { [[ $1 == uid || $1 == pair ]] && USED_UID[$2]=1; [[ $1 == gid || $1 == pair ]] && USED_GID[$2]=1; return 0; }
_id_free() {   # WHAT ID
    case $1 in
        uid)  [[ -z ${USED_UID[$2]+x} ]] ;;
        gid)  [[ -z ${USED_GID[$2]+x} ]] ;;
        pair) [[ -z ${USED_UID[$2]+x} && -z ${USED_GID[$2]+x} ]] ;;
    esac
}

# id_alloc normal|system uid|gid|pair [COUNT] -> ID_OUT[]
id_alloc() {
    local class=$1 what=$2 count=${3:-1} pfx=UID min max cand step=1 wrapped=false id
    local got=() batch=() taken
    id_init
    [[ $what == gid ]] && pfx=GID
    if [[ $class == system ]]; then
        defs_get "${pfx}_MIN" 1000; max=$((REPLY - 1))
        defs_get "SYS_${pfx}_MAX" "$max"; max=$REPLY
        defs_get "SYS_${pfx}_MIN" 101; min=$REPLY
        cand=$max step=-1
    else
        defs_get "${pfx}_MIN" 1000; min=$REPLY
        defs_get "${pfx}_MAX" 60000; max=$REPLY
        # Continue after the highest UID (GID for groups) in the range; for a
        # user-private group, numbers that are taken as a GID are skipped below.
        cand=$min
        local -n _used=USED_UID
        [[ $what == gid ]] && local -n _used=USED_GID
        for id in "${!_used[@]}"; do (( id >= min && id <= max && id >= cand )) && cand=$((id + 1)); done
    fi
    while ((${#got[@]} < count)); do
        batch=()
        while ((${#batch[@]} < count - ${#got[@]} + 8)); do
            if ((cand > max || cand < min)); then
                if ((step == 1)) && ! $wrapped; then wrapped=true cand=$min; continue; fi
                break
            fi
            _id_free "$what" "$cand" && batch+=("$cand")
            cand=$((cand + step))
        done
        ((${#batch[@]})) || die "$E_CONFLICT" "no free ${pfx}s left between $min and $max" "nothing was changed" \
            "widen ${pfx}_MIN/${pfx}_MAX in /etc/login.defs"
        if $LIVE; then
            # One getent call checks the whole batch against LDAP/SSSD/NIS.
            declare -A taken=()
            local ent
            if [[ $what != gid ]]; then
                while IFS= read -r ent; do split_fields "$ent"; taken[${F[2]}]=1; done < <(getent passwd "${batch[@]}" 2>/dev/null)
            fi
            if [[ $what != uid ]]; then
                while IFS= read -r ent; do split_fields "$ent"; taken[${F[2]}]=1; done < <(getent group "${batch[@]}" 2>/dev/null)
            fi
            for id in "${batch[@]}"; do
                [[ -n ${taken[$id]+x} ]] && { id_mark "$what" "$id"; continue; }
                got+=("$id"); id_mark "$what" "$id"
                ((${#got[@]} == count)) && break
            done
            unset taken
        else
            for id in "${batch[@]}"; do
                got+=("$id"); id_mark "$what" "$id"
                ((${#got[@]} == count)) && break
            done
        fi
    done
    ID_OUT=("${got[@]}")
}

# Is NAME taken by a *network* account (LDAP/AD via SSSD)? Local entries are
# checked separately; creating a local account that shadows a directory
# account is a classic source of confusion.
nss_user_exists()  { $LIVE && getent passwd "$1" >/dev/null 2>&1; }
nss_group_exists() { $LIVE && getent group "$1" >/dev/null 2>&1; }

# ==============================================================================
# §7  PASSWORDS & SECRETS
#     Rules: secrets travel only through pipes and bash variables. Never on a
#     command line (visible in ps), never in here-strings (bash < 5.1 backs them
#     with temp files: F-16), never in logs, JSON output or journals.
# ==============================================================================

# The real password policy lives in pwquality.conf; login.defs' PASS_MIN_LEN
# is ignored by PAM, which is what v1's "password complexity" menu edited (F-17).
declare -A POL=()
pw_policy_load() {
    ((${#POL[@]})) && return 0
    POL=([minlen]=8 [minclass]=0 [dcredit]=0 [ucredit]=0 [lcredit]=0 [ocredit]=0 [maxrepeat]=0 [usercheck]=1)
    local f line
    for f in "$ETC/security/pwquality.conf" "$ETC"/security/pwquality.conf.d/*.conf; do
        [[ -r $f ]] || continue
        while IFS= read -r line; do
            line=${line%%#*}
            [[ $line =~ ^[[:space:]]*([a-z]+)[[:space:]]*=[[:space:]]*(-?[0-9]+) ]] || continue
            [[ -n ${POL[${BASH_REMATCH[1]}]+x} ]] && POL[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        done < "$f"
    done
    ((POL[minlen] >= 8)) || POL[minlen]=8     # UMC's floor
}

# pw_check PASSWORD USER - VAL_ERR never contains the password itself.
pw_check() {
    local p=$1 u=$2 classes=0 n
    [[ -n $p ]]                               || _vfail "the password is empty" || return 1
    [[ $p != *[$'\x01'-$'\x1f'$'\x7f']* ]]    || _vfail "the password contains control characters" || return 1
    if $LIVE && cap_has pwscore; then
        local out
        out=$(printf '%s\n' "$p" | pwscore "$u" 2>&1) && return 0
        out=${out//$'\n'/ }
        _vfail "rejected by the system password policy (pwquality):${out#*:}"
        return 1
    fi
    pw_policy_load
    ((${#p} >= POL[minlen]))                  || _vfail "the password must be at least ${POL[minlen]} characters long" || return 1
    [[ $p == *[a-z]* ]] && classes=$((classes + 1))
    [[ $p == *[A-Z]* ]] && classes=$((classes + 1))
    [[ $p == *[0-9]* ]] && classes=$((classes + 1))
    [[ $p == *[!a-zA-Z0-9]* ]] && classes=$((classes + 1))
    ((classes >= POL[minclass]))              || _vfail "the password must mix at least ${POL[minclass]} of: lower case, upper case, digits, symbols" || return 1
    n=${p//[!0-9]/};       (( POL[dcredit] >= 0 || ${#n} >= -POL[dcredit] )) || _vfail "the password needs at least $((-POL[dcredit])) digit(s)" || return 1
    n=${p//[!A-Z]/};       (( POL[ucredit] >= 0 || ${#n} >= -POL[ucredit] )) || _vfail "the password needs at least $((-POL[ucredit])) upper-case letter(s)" || return 1
    n=${p//[!a-z]/};       (( POL[lcredit] >= 0 || ${#n} >= -POL[lcredit] )) || _vfail "the password needs at least $((-POL[lcredit])) lower-case letter(s)" || return 1
    n=${p//[a-zA-Z0-9]/};  (( POL[ocredit] >= 0 || ${#n} >= -POL[ocredit] )) || _vfail "the password needs at least $((-POL[ocredit])) symbol(s)" || return 1
    if ((POL[maxrepeat] > 0)); then
        local i run=1
        for ((i = 1; i < ${#p}; i++)); do
            if [[ ${p:i:1} == "${p:i-1:1}" ]]; then run=$((run + 1)); else run=1; fi
            ((run <= POL[maxrepeat])) || _vfail "the password repeats a character more than ${POL[maxrepeat]} times in a row" || return 1
        done
    fi
    if ((POL[usercheck])) && ((${#u} >= 3)) && [[ ${p,,} == *"${u,,}"* ]]; then
        _vfail "the password must not contain the user name"
        return 1
    fi
    return 0
}

# Temporary passwords: unique per user, ~70 bits, no look-alike characters
# (0/O, 1/l/I), grouped for reading aloud, e.g. Kx7m-p9Qr-T4wz.
readonly PW_ALPHABET='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
pw_generate_many() {   # COUNT -> GEN[]
    local count=$1 groups=3 len n=${#PW_ALPHABET} limit b cur="" i pw bytes=()
    pw_policy_load
    while ((groups * 5 - 1 < POL[minlen])); do groups=$((groups + 1)); done
    len=$((groups * 4))
    limit=$(( (256 / n) * n ))            # rejection sampling: no modulo bias
    GEN=()
    while ((${#GEN[@]} < count)); do
        read -ra bytes < <(od -An -tu1 -N $(( (count - ${#GEN[@]}) * len * 2 + 32 )) /dev/urandom | tr -s ' \n' '  ')
        for b in "${bytes[@]}"; do
            ((b < limit)) || continue
            cur+=${PW_ALPHABET:b % n:1}
            ((${#cur} < len)) && continue
            if [[ $cur == *[a-z]* && $cur == *[A-Z]* && $cur == *[2-9]* ]]; then
                pw=""
                for ((i = 0; i < len; i += 4)); do pw+=${pw:+-}${cur:i:4}; done
                GEN+=("$pw")
                ((${#GEN[@]} == count)) && break
            fi
            cur=""
        done
    done
}

HASH_WARNED=false
pw_hash_method() {
    case ${CFG[hash_method]} in
        YESCRYPT)
            if cap_has yescrypt; then REPLY=yescrypt; return 0; fi
            $HASH_WARNED || warn "ENCRYPT_METHOD is YESCRYPT but 'mkpasswd' with yescrypt support is missing; using SHA-512 (install: whois / mkpasswd)"
            HASH_WARNED=true ;;
        SHA512) ;;
        *)  $HASH_WARNED || warn "ENCRYPT_METHOD '${CFG[hash_method]}' is weak or unknown; using SHA-512"
            HASH_WARNED=true ;;
    esac
    REPLY=sha512
}

# pw_hash_many: PW_IN[] -> PW_OUT[] (same order). SHA-512 hashing is split
# across CPU cores; one openssl process hashes a whole batch (measured ~2x
# faster than one process per password, before parallelism).
pw_hash_many() {
    local n=${#PW_IN[@]} method j jobs start chunk tmpd h
    PW_OUT=()
    ((n)) || return 0
    pw_hash_method; method=$REPLY
    if [[ $method == yescrypt ]]; then
        local p
        for p in "${PW_IN[@]}"; do
            h=$(printf '%s\n' "$p" | mkpasswd -m yescrypt --stdin 2>/dev/null) || die "$E_FAIL" "password hashing (mkpasswd) failed"
            PW_OUT+=("$h")
        done
    else
        need openssl
        cap_has openssl6 || die "$E_FAIL" "this OpenSSL cannot create SHA-512 crypt hashes (OpenSSL 1.1.1+ required)"
        jobs=$(nproc 2>/dev/null || echo 1)
        ((jobs > 8)) && jobs=8
        ((n < 64)) && jobs=1
        chunk=$(( (n + jobs - 1) / jobs ))
        if [[ -n $WORK && -d $WORK ]]; then tmpd=$WORK; else tmpd=$(mktemp -d) || die "$E_FAIL" "mktemp failed"; CLEANUP+=("$tmpd"); fi
        local pids=()
        for ((j = 0; j < jobs; j++)); do
            start=$((j * chunk))
            ((start < n)) || break
            printf '%s\n' "${PW_IN[@]:start:chunk}" | openssl passwd -6 -stdin > "$tmpd/hash.$j" 2>/dev/null &
            pids+=($!)
        done
        for j in "${!pids[@]}"; do wait "${pids[j]}" || die "$E_FAIL" "password hashing (openssl) failed"; done
        for j in "${!pids[@]}"; do mapfile -t -O "${#PW_OUT[@]}" PW_OUT < "$tmpd/hash.$j"; rm -f -- "$tmpd/hash.$j"; done
    fi
    ((${#PW_OUT[@]} == n)) || die "$E_FAIL" "password hashing returned ${#PW_OUT[@]} hashes for $n passwords"
    for h in "${PW_OUT[@]}"; do
        # v1 wrote openssl's "<NULL>" into /etc/shadow for an empty password (F-15).
        [[ $h =~ ^\$(6|y)\$[./0-9A-Za-z$]{20,}$ ]] || die "$E_FAIL" "password hashing produced an invalid hash; nothing was written"
    done
}

# Classify shadow field 2. Three different things are called "locked" on
# Linux: a '!' prefix (password only - SSH keys still work!), account expiry
# (blocks every login method) and pam_faillock's failed-login counter.
pw_state() {
    local h=$1 inner
    inner=${h##+(!)}
    if [[ -z $h ]]; then REPLY=empty
    elif [[ -z $inner || $inner == \** ]]; then REPLY=none
    elif [[ $h == \!* ]]; then REPLY=locked
    else REPLY="set"
    fi
}

# ==============================================================================
# §8  HOME DIRECTORIES & SSH KEYS
#     Anything written *inside* a user's home is written AS THAT USER
#     (setpriv drops uid, gid and supplementary groups). Then a symlink planted
#     by the user can only point at files the user could already write. v1
#     followed such symlinks as root (F-08).
# ==============================================================================

as_user() {   # UID GID COMMAND...
    setpriv --reuid="$1" --regid="$2" --clear-groups -- "${@:3}"
}

home_mode() {
    defs_get HOME_MODE ""
    [[ $REPLY =~ ^0?[0-7]{3}$ ]] && return 0
    defs_get UMASK 077
    local u=$REPLY
    [[ $u =~ ^0?[0-7]{3}$ ]] || u=077
    printf -v REPLY '%04o' $(( 8#777 & ~8#${u#0} ))
}

EFFECT_ERR=""
home_create() {   # NAME UID GID HOME ROLE
    local name=$1 uid=$2 gid=$3 home=$4 role=${5:-} dir=$R$4 parent owner
    EFFECT_ERR=""
    if [[ -e $dir || -L $dir ]]; then
        owner=$(stat -c %u -- "$dir" 2>/dev/null)
        [[ -d $dir && ! -L $dir && $owner == "$uid" ]] && return 0      # already there
        EFFECT_ERR="$home already exists and belongs to uid ${owner:-?}; refusing to give another account's files to '$name'"
        return 1
    fi
    parent=${dir%/*}
    if [[ ! -d $parent ]]; then
        # umask 022 so parents stay traversable (v1 created them 0700: F-27)
        ( umask 022; mkdir -p -- "$parent" ) || { EFFECT_ERR="cannot create ${parent#"$R"}"; return 1; }
    fi
    mkdir -m 0700 -- "$dir" || { EFFECT_ERR="cannot create $home"; return 1; }
    if [[ -d $ETC/skel ]]; then
        cp -a -- "$ETC/skel/." "$dir/" || { EFFECT_ERR="copying /etc/skel into $home failed"; return 1; }
    fi
    if [[ -n $role && -d $ETC/umc/skel.d/$role ]]; then
        cp -a -- "$ETC/umc/skel.d/$role/." "$dir/" || { EFFECT_ERR="copying the '$role' skeleton failed"; return 1; }
    fi
    chown -hR -- "$uid:$gid" "$dir" || { EFFECT_ERR="chown of $home failed"; return 1; }
    home_mode
    chmod "$REPLY" -- "$dir" || { EFFECT_ERR="chmod of $home failed"; return 1; }
    if cap_has selinux && cap_has restorecon; then restorecon -R -- "$dir" 2>/dev/null || true; fi
    mail_spool_create "$name" "$uid"
    return 0
}

mail_spool_create() {
    local v spool gid=""
    uadef_get CREATE_MAIL_SPOOL ""; v=${REPLY,,}
    [[ -z $v ]] && { defs_get CREATE_MAIL_SPOOL no; v=${REPLY,,}; }
    [[ $v == yes ]] || return 0
    for spool in "$R/var/spool/mail" "$R/var/mail"; do [[ -d $spool && ! -L $spool ]] && break; done
    [[ -d $spool ]] || return 0
    [[ -e $spool/$1 ]] && return 0
    db_fields GR mail && gid=${F[2]}
    : > "$spool/$1" && chown "$2:${gid:-0}" -- "$spool/$1" && chmod 0660 -- "$spool/$1"
    return 0
}

# Runs as the target user (never as root). $1=action $2=home, keys on stdin.
readonly KEYS_SNIPPET='
set -u; umask 077
act=$1 home=$2
cd -- "$home" || { echo "cannot enter $home" >&2; exit 10; }
if [ -L .ssh ]; then echo "~/.ssh is a symbolic link; refusing" >&2; exit 11; fi
ak=.ssh/authorized_keys
case $act in
add)
    mkdir -p .ssh && chmod 700 .ssh || exit 12
    if [ -L "$ak" ]; then echo "$ak is a symbolic link; refusing" >&2; exit 11; fi
    tmp=$(mktemp .ssh/.umc-keys.XXXXXX) || exit 12
    trap "rm -f -- \"$tmp\"" EXIT
    if [ -f "$ak" ]; then cat -- "$ak" > "$tmp" || exit 12; fi
    added=0
    while IFS= read -r key; do
        body=${key#* }; body=${body%% *}
        grep -qF -- " $body" "$tmp" && continue
        printf "%s\n" "$key" >> "$tmp" || exit 12
        added=$((added + 1))
    done
    chmod 600 "$tmp" && mv -f -- "$tmp" "$ak" || exit 12
    echo "$added" ;;
remove)
    [ -f "$ak" ] || { echo 0; exit 0; }
    if [ -L "$ak" ]; then echo "$ak is a symbolic link; refusing" >&2; exit 11; fi
    tmp=$(mktemp .ssh/.umc-keys.XXXXXX) || exit 12
    trap "rm -f -- \"$tmp\"" EXIT
    cp -- "$ak" "$tmp" || exit 12
    removed=0
    while IFS= read -r key; do
        body=${key#* }; body=${body%% *}
        if grep -qF -- " $body" "$tmp"; then
            grep -vF -- " $body" "$tmp" > "$tmp.n"; mv -f -- "$tmp.n" "$tmp"
            removed=$((removed + 1))
        fi
    done
    chmod 600 "$tmp" && mv -f -- "$tmp" "$ak" || exit 12
    echo "$removed" ;;
list)
    [ -f "$ak" ] && [ ! -L "$ak" ] && cat -- "$ak"; exit 0 ;;
disable)
    [ -f "$ak" ] || { echo 0; exit 0; }
    if [ -L "$ak" ]; then echo "$ak is a symbolic link; refusing" >&2; exit 11; fi
    cat -- "$ak" >> .ssh/authorized_keys.umc-disabled && rm -f -- "$ak" || exit 12
    echo 1 ;;
enable)
    d=.ssh/authorized_keys.umc-disabled
    [ -f "$d" ] && [ ! -L "$d" ] || { echo 0; exit 0; }
    if [ -L "$ak" ]; then echo "$ak is a symbolic link; refusing" >&2; exit 11; fi
    cat -- "$d" >> "$ak" && chmod 600 "$ak" && rm -f -- "$d" || exit 12
    echo 1 ;;
esac'

# keys_run ACTION NAME UID GID HOME [KEY...] -> REPLY = count
keys_run() {
    local act=$1 name=$2 uid=$3 gid=$4 home=$5 dir=$R$5 out
    shift 5
    EFFECT_ERR=""
    [[ -d $dir && ! -L $dir ]] || { EFFECT_ERR="$home does not exist"; return 1; }
    [[ $(stat -c %u -- "$dir") == "$uid" ]] || { EFFECT_ERR="$home is not owned by $name"; return 1; }
    cap_has setpriv || { EFFECT_ERR="setpriv (util-linux) is required to edit files inside a home directory safely"; return 1; }
    # (with pipefail, "(($#)) && printf" would fail the pipeline when there are no keys)
    if ! out=$( { if (($#)); then printf '%s\n' "$@"; fi; } | as_user "$uid" "$gid" /bin/bash -c "$KEYS_SNIPPET" umc-keys "$act" "$dir" 2>&1 ); then
        EFFECT_ERR="SSH key update for $name failed: ${out//$'\n'/ }"
        return 1
    fi
    if [[ $act != list ]] && cap_has selinux && cap_has restorecon; then restorecon -R -- "$dir/.ssh" 2>/dev/null || true; fi
    REPLY=$out
}

# Processes and sessions (live systems only).
user_procs() {   # UID -> REPLY = number of processes with that real UID
    local s k v n=0
    for s in /proc/[0-9]*/status; do
        while read -r k v _; do
            [[ $k == Uid: ]] || continue
            [[ $v == "$1" ]] && n=$((n + 1))
            break
        done < "$s" 2>/dev/null
    done
    REPLY=$n
}
user_kill_sessions() {   # NAME UID
    $LIVE || return 0
    if cap_has loginctl && cap_has systemd; then loginctl terminate-user "$1" 2>/dev/null || true; fi
    if cap_has pkill; then pkill -KILL -U "$2" 2>/dev/null || true
    else
        local s k v pid
        for s in /proc/[0-9]*/status; do
            pid=${s#/proc/}; pid=${pid%/status}
            while read -r k v _; do [[ $k == Uid: ]] && { [[ $v == "$2" ]] && kill -KILL "$pid" 2>/dev/null; break; }; done < "$s" 2>/dev/null
        done
    fi
    sleep 1
    user_procs "$2"
    ((REPLY == 0)) || { EFFECT_ERR="$REPLY process(es) of $1 survived SIGKILL"; return 1; }
}

# Archives: <archive_dir>/<name>-<uid>-<utc>.tar.gz plus .sha256, both 0400.
# The archive is verified BEFORE anything is removed; v1 discarded tar's
# errors and deleted the home anyway (F-21).
archive_dir() {   # NAME UID PATH LABEL -> REPLY = archive path ('' if nothing to archive)
    local dir=$R$3 a ts err
    REPLY=""
    [[ -d $dir && ! -L $dir ]] || return 0
    mkdir -p -m 0700 -- "$ARCHIVE_DIR" || { EFFECT_ERR="cannot create $ARCHIVE_DIR"; return 1; }
    printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    a=$ARCHIVE_DIR/$1-$2-$4-$ts.tar.gz
    [[ -e $a ]] && a=${a%.tar.gz}-$BASHPID.tar.gz
    if ! err=$(tar --numeric-owner -czf "$a" -C "${dir%/*}" -- "${dir##*/}" 2>&1); then
        rm -f -- "$a"
        EFFECT_ERR="archiving $3 failed: ${err//$'\n'/ }"
        return 1
    fi
    if ! tar -tzf "$a" >/dev/null 2>&1; then
        rm -f -- "$a"
        EFFECT_ERR="the archive of $3 could not be read back"
        return 1
    fi
    ( cd -- "$ARCHIVE_DIR" && sha256sum -- "${a##*/}" > "${a##*/}.sha256" ) && chmod 0400 -- "$a" "$a.sha256"
    REPLY=$a
}
archive_file() {   # NAME PATH LABEL -> copies a single file (crontab, mail spool) into the archive
    local f=$R$2 dst ts
    [[ -f $f && ! -L $f ]] || return 0
    mkdir -p -m 0700 -- "$ARCHIVE_DIR" || return 1
    printf -v ts '%(%Y%m%dT%H%M%SZ)T' -1
    dst=$ARCHIVE_DIR/$1-$3-$ts
    cp -p -- "$f" "$dst" && chmod 0400 -- "$dst"
}

home_remove() {   # NAME UID HOME
    local dir=$R$3 root ok=false
    EFFECT_ERR=""
    [[ -e $dir || -L $dir ]] || return 0
    [[ -d $dir && ! -L $dir ]] || { EFFECT_ERR="$3 is not a directory; not removing it"; return 1; }
    val_path "$3" && [[ $REPLY == "$3" ]] || { EFFECT_ERR="$3 is not a normalised path; not removing it"; return 1; }
    # Only strictly below an allowed root: this is what stops "delete user bin"
    # from running rm -rf /bin (v1: F-06).
    for root in ${CFG[home_roots]}; do [[ $3 == "${root%/}"/?* ]] && ok=true; done
    $ok || { EFFECT_ERR="$3 is outside the allowed home roots (${CFG[home_roots]}); left in place"; return 1; }
    [[ $(stat -c %u -- "$dir") == "$2" ]] || { EFFECT_ERR="$3 is not owned by uid $2; left in place"; return 1; }
    if command -v mountpoint >/dev/null && mountpoint -q -- "$dir"; then
        EFFECT_ERR="$3 is a mount point; left in place"; return 1
    fi
    rm -rf --one-file-system -- "$dir" || { EFFECT_ERR="removing $3 failed"; return 1; }
}

# ==============================================================================
# §9  ACCOUNT OPERATIONS
#     op_* functions stage changes inside an open transaction and never commit
#     or print results themselves. One command, or one bulk 'apply' of 500
#     users, becomes exactly one transaction: all or nothing.
# ==============================================================================

declare -A UO=() KEYS_FOR=()
ALREADY=false          # set by ops when the requested state already holds

# uo_list KEY -> LIST[] (a comma/space separated option split into words)
uo_list() {
    local v=${UO[$1]:-}
    v=${v//,/ }
    read -ra LIST <<< "$v"
}

user_load() {   # NAME -> U_* and S_* (returns 1 if there is no such user)
    db_fields PW "$1" || return 1
    U_UID=${F[2]} U_GID=${F[3]} U_GECOS=${F[4]} U_HOME=${F[5]} U_SHELL=${F[6]}
    S_HASH="" S_LAST="" S_MIN="" S_MAX="" S_WARN="" S_INACT="" S_EXPIRE="" S_RES=""
    if db_fields SP "$1"; then
        S_HASH=${F[1]} S_LAST=${F[2]} S_MIN=${F[3]} S_MAX=${F[4]} S_WARN=${F[5]} S_INACT=${F[6]} S_EXPIRE=${F[7]} S_RES=${F[8]:-}
    fi
    return 0
}
user_need() {
    user_load "$1" && return 0
    if nss_user_exists "$1"; then
        die "$E_NOTFOUND" "'$1' is a directory (LDAP/SSSD) account, not a local one" "nothing was changed" "manage it in the directory service"
    fi
    die "$E_NOTFOUND" "user '$1' does not exist" "nothing was changed" "list users with: umc user list"
}
sp_stage() {    # writes S_* back for user $1
    txn_target SP "$1"
    db_put SP "$1" "$1:$S_HASH:$S_LAST:$S_MIN:$S_MAX:$S_WARN:$S_INACT:$S_EXPIRE:$S_RES"
}
pw_stage() {    # writes U_* back for user $1
    txn_target PW "$1"
    db_put PW "$1" "$1:x:$U_UID:$U_GID:$U_GECOS:$U_HOME:$U_SHELL"
}

group_by_gid() {   # GID -> REPLY = group name
    local line r
    for line in "${GR_L[@]}"; do
        [[ $line == "$DEL" ]] && continue
        r=${line#*:} r=${r#*:}
        [[ ${r%%:*} == "$1" ]] && { REPLY=${line%%:*}; return 0; }
    done
    return 1
}
user_groups() {   # NAME -> GROUPS_OF[] (supplementary memberships, file order)
    local line f4
    GROUPS_OF=()
    for line in "${GR_L[@]}"; do
        [[ $line == "$DEL" || $line != *:*:*:* ]] && continue
        f4=${line##*:}
        list_has "$f4" "$1" && GROUPS_OF+=("${line%%:*}")
    done
}
group_users_primary() {   # GID -> REPLY = space list of users whose primary group it is
    local line r out=()
    for line in "${PW_L[@]}"; do
        [[ $line == "$DEL" || $line != *:*:*:* ]] && continue
        r=${line#*:} r=${r#*:} r=${r#*:}
        [[ ${r%%:*} == "$1" ]] && out+=("${line%%:*}")
    done
    REPLY="${out[*]}"
}

group_member_add() {   # GROUP USER
    local g=$1 u=$2
    db_fields GR "$g" || die "$E_NOTFOUND" "group '$g' does not exist" "nothing was changed" "create it first: umc group create $g"
    txn_target_group "$g"
    list_add "${F[3]}" "$u"
    if [[ $REPLY != "${F[3]}" ]]; then F[3]=$REPLY; join_fields "${F[@]}"; db_put GR "$g" "$REPLY"; fi
    if db_fields GS "$g"; then
        list_add "${F[3]}" "$u"
        if [[ $REPLY != "${F[3]}" ]]; then F[3]=$REPLY; join_fields "${F[@]}"; db_put GS "$g" "$REPLY"; fi
    fi
}
group_member_del() {   # GROUP USER  (members and gshadow administrators)
    local g=$1 u=$2
    db_fields GR "$g" || return 0
    if list_has "${F[3]}" "$u"; then
        txn_target_group "$g"
        list_del "${F[3]}" "$u"; F[3]=$REPLY; join_fields "${F[@]}"; db_put GR "$g" "$REPLY"
    fi
    if db_fields GS "$g" && { list_has "${F[2]}" "$u" || list_has "${F[3]}" "$u"; }; then
        txn_target_group "$g"
        list_del "${F[2]}" "$u"; F[2]=$REPLY
        list_del "${F[3]}" "$u"; F[3]=$REPLY
        join_fields "${F[@]}"; db_put GS "$g" "$REPLY"
    fi
    return 0
}

# The group that grants sudo on this host (RHEL: wheel, Debian: sudo).
admin_group() {
    local g
    for g in wheel sudo admin; do
        db_exists GR "$g" || continue
        grep -Eqs "^[[:space:]]*%${g}[[:space:]]" "$ETC/sudoers" "$ETC"/sudoers.d/* && { REPLY=$g; return 0; }
    done
    for g in sudo wheel; do db_exists GR "$g" && { REPLY=$g; return 0; }; done
    REPLY=""
    return 1
}

# --- UMC's own state (journaled with the accounts it describes) -----------------
# $STATE/managed        TSV: name uid external_id email created source groups_granted
# $STATE/locks/NAME     why and how UMC locked an account (so unlock can undo exactly that)
# $STATE/onboarding/N   temporary-password deadline
# $STATE/offboarded/N   what offboarding removed (so it can be reinstated)
# $STATE/retired-ids    IDs of deleted accounts (never reused unless reuse_ids=yes)
state_put() {   # PATH LINE...
    txn_xfile "$1" 0600 0 0
    printf '%s\n' "${@:2}" > "$REPLY"
}
state_del() { [[ -e $1 ]] && txn_xdelete "$1"; return 0; }
kv_get() {      # FILE KEY -> REPLY ('' if missing)
    REPLY=""
    [[ -f $1 ]] || return 1
    local k v
    while IFS='=' read -r k v; do [[ $k == "$2" ]] && { REPLY=$v; return 0; }; done < "$1"
    return 1
}

declare -A MANAGED=()   # name -> full TSV line (staged view)
MANAGED_READY=false
managed_load() {
    $MANAGED_READY && return 0
    MANAGED_READY=true
    MANAGED=()
    local line
    [[ -f $STATE/managed ]] || return 0
    while IFS= read -r line; do [[ -n $line ]] && MANAGED[${line%%$'\t'*}]=$line; done < "$STATE/managed"
}
# Changes are kept in memory and written once, just before the commit
# (a bulk apply of 1,000 users sorts the file once, not 1,000 times).
MANAGED_DIRTY=false
managed_put() {   # NAME UID EXTID EMAIL CREATED SOURCE GROUPS
    managed_load
    MANAGED[$1]="$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6"$'\t'"$7"
    MANAGED_DIRTY=true
}
managed_del() { managed_load; [[ -n ${MANAGED[$1]+x} ]] || return 0; unset "MANAGED[$1]"; MANAGED_DIRTY=true; }
_managed_flush() {
    txn_xfile "$STATE/managed" 0600 0 0
    local f=$REPLY
    if ((${#MANAGED[@]})); then printf '%s\n' "${MANAGED[@]}" | sort > "$f"; else : > "$f"; fi
    MANAGED_DIRTY=false
}
# TAB is an IFS *whitespace* character, so 'read' would merge empty fields;
# split by hand instead.
split_tabs() {
    local s=$1
    T=()
    while [[ $s == *$'\t'* ]]; do T+=("${s%%$'\t'*}"); s=${s#*$'\t'}; done
    T+=("$s")
}
managed_field() {  # NAME INDEX(0-6) -> REPLY
    managed_load
    REPLY=""
    [[ -n ${MANAGED[$1]+x} ]] || return 1
    split_tabs "${MANAGED[$1]}"
    REPLY=${T[$2]:-}
}

retire_ids() {   # UID GID (either may be empty)
    [[ ${CFG[reuse_ids]} == yes ]] && return 0
    [[ -n ${1:-}${2:-} ]] || return 0
    txn_xfile "$STATE/retired-ids" 0600 0 0
    [[ -n ${1:-} ]] && printf 'u %s\n' "$1" >> "$REPLY"
    [[ -n ${2:-} ]] && printf 'g %s\n' "$2" >> "$REPLY"
    return 0
}

# --- subordinate IDs (/etc/subuid, /etc/subgid) for rootless containers -----------
declare -A SUBID_NEXT=() SUBID_HAS=()
subid_alloc() {   # NAME
    local base f pfx staged min count max next line s c u
    for base in subuid subgid; do
        f=$ETC/$base
        [[ -f $f ]] || continue
        pfx=SUB_UID; [[ $base == subgid ]] && pfx=SUB_GID
        txn_xfile "$f"; staged=$REPLY
        defs_get "${pfx}_MIN" 100000; min=$REPLY
        defs_get "${pfx}_MAX" 600100000; max=$REPLY
        defs_get "${pfx}_COUNT" 65536; count=$REPLY
        ((count > 0)) || continue
        if [[ -z ${SUBID_NEXT[$base]+x} ]]; then     # scan the file once per transaction
            next=$min
            while IFS=: read -r u s c; do
                SUBID_HAS[$base:$u]=1
                [[ $s =~ ^[0-9]+$ && $c =~ ^[0-9]+$ ]] && ((s + c > next)) && next=$((s + c))
            done < "$staged"
            SUBID_NEXT[$base]=$next
        fi
        [[ -n ${SUBID_HAS[$base:$1]+x} ]] && continue
        SUBID_HAS[$base:$1]=1
        next=${SUBID_NEXT[$base]}
        ((next + count - 1 <= max)) || die "$E_CONFLICT" "no free ${base} range left (${pfx}_MAX=$max)"
        printf '%s:%s:%s\n' "$1" "$next" "$count" >> "$staged"
        SUBID_NEXT[$base]=$((next + count))
    done
    return 0
}
subid_del() {   # NAME [NEWNAME]  (delete, or rename when NEWNAME is given)
    local base f staged
    for base in subuid subgid; do
        f=$ETC/$base
        [[ -f $f ]] && grep -q "^$1:" -- "$f" || continue
        txn_xfile "$f"; staged=$REPLY
        awk -F: -v OFS=: -v u="$1" -v n="${2:-}" '$1 == u { if (n == "") next; $1 = n } { print }' "$staged" > "$staged.t" &&
            mv -f -- "$staged.t" "$staged"
    done
    return 0
}

# --- sudo rules -------------------------------------------------------------------
sudo_file_for() {   # PRINCIPAL -> REPLY (sudo ignores files whose name contains '.')
    local p=$1 base
    if [[ $p == %* ]]; then base=group-${p#%}; else base=user-$p; fi
    REPLY=$ETC/sudoers.d/umc-${base//./_}
}
sudo_stage_grant() {   # PRINCIPAL full|nopasswd COMMANDS
    local tag=""
    [[ $2 == nopasswd ]] && tag="NOPASSWD: "
    sudo_file_for "$1"
    txn_xfile "$REPLY" 0440 0 0
    {
        printf '# Managed by UMC - change it with "umc sudo grant/revoke", not by hand.\n'
        printf '%s ALL=(ALL:ALL) %s%s\n' "$1" "$tag" "${3:-ALL}"
    } > "$REPLY"
}
sudo_stage_revoke() { sudo_file_for "$1"; state_del "$REPLY"; }

# --- lockout protection ---------------------------------------------------------
# Refuses operations that would lock out root, the admin running UMC, a
# protected (break-glass) account, a system account, or the last admin.
guard_account() {   # NAME ACTION
    local n=$1 act=$2 p
    user_need "$n"
    [[ $n == root || $U_UID == 0 ]] && die "$E_CONFLICT" "refusing to $act '$n': it is a UID-0 account" "nothing was changed"
    for p in ${CFG[protected_users]//,/ }; do
        [[ $p == "$n" ]] && die "$E_CONFLICT" "refusing to $act '$n': it is listed in protected_users (umc.conf)" "nothing was changed"
    done
    if $LIVE && [[ $act != modify ]] && [[ $n == "$ACTOR" || $n == "${SUDO_USER:-}" ]]; then
        die "$E_CONFLICT" "refusing to $act '$n': that is the account you are logged in with" "nothing was changed" \
            "log in as another administrator to do this"
    fi
    defs_get UID_MIN 1000
    if ((U_UID < REPLY)) && [[ ${UO[system]:-0} != 1 ]]; then
        die "$E_CONFLICT" "refusing to $act '$n': UID $U_UID is a system account" "nothing was changed" \
            "pass --system if you really mean it"
    fi
    [[ $act == modify || ${UO[force]:-0} == 1 ]] && return 0
    _guard_last_admin "$n" "$act"
}
_guard_last_admin() {
    local n=$1 act=$2 g gid others=0 cand today members
    admin_group || return 0
    g=$REPLY
    db_fields GR "$g" || return 0
    gid=${F[2]}
    members=${F[3]//,/ }
    group_users_primary "$gid"
    members+=" $REPLY"
    [[ " $members " == *" $n "* ]] || return 0
    today_days; today=$REPLY
    for cand in $members; do
        [[ $cand == "$n" ]] && continue
        db_fields SP "$cand" || continue
        pw_state "${F[1]}"
        [[ $REPLY == set ]] || continue
        [[ -z ${F[7]} ]] || (( F[7] > today )) || continue
        others=$((others + 1))
    done
    if ((others == 0)) && db_fields SP root; then pw_state "${F[1]}"; [[ $REPLY == set ]] && others=1; fi
    ((others > 0)) || die "$E_CONFLICT" "refusing to $act '$n': it is the last usable administrator ('$g' group) and root has no password" \
        "nothing was changed" "make someone else an admin first, or pass --force"
}

# --- users ------------------------------------------------------------------------
# UO keys: name uid group groups gecos home shell expire role system no_home
#          hash force_change keys sudo sudo_cmds
op_user_create() {
    local n=${UO[name]} class=normal uid gid upg=true today exp minp maxp warnp inact shell home g last
    [[ ${UO[system]:-0} == 1 ]] && class=system
    db_exists PW "$n" && bug "op_user_create: '$n' already exists"
    nss_user_exists "$n" && die "$E_CONFLICT" "a directory (LDAP/SSSD) account named '$n' already exists" "nothing was changed" \
        "pick another name: a local account would shadow the directory account"
    if [[ -n ${UO[group]:-} ]]; then
        upg=false
        if [[ ${UO[group]} =~ ^[0-9]+$ ]]; then
            gid=${UO[group]}
            group_by_gid "$gid" || die "$E_NOTFOUND" "no group has GID $gid" "nothing was changed"
        else
            db_fields GR "${UO[group]}" || die "$E_NOTFOUND" "group '${UO[group]}' does not exist" "nothing was changed"
            gid=${F[2]}
        fi
        if [[ -n ${UO[uid]:-} ]]; then
            uid=${UO[uid]}; id_init
            _id_free uid "$uid" && ! { $LIVE && getent passwd "$uid" >/dev/null 2>&1; } ||
                die "$E_CONFLICT" "UID $uid is already in use" "nothing was changed"
            id_mark uid "$uid"
        else
            id_alloc "$class" uid; uid=${ID_OUT[0]}
        fi
    else
        db_exists GR "$n" && die "$E_CONFLICT" "a group named '$n' already exists" "nothing was changed" \
            "use --group $n to make it the primary group, or pick another user name"
        nss_group_exists "$n" && die "$E_CONFLICT" "a directory (LDAP/SSSD) group named '$n' already exists" "nothing was changed"
        if [[ ${UO[uid_prealloc]:-0} == 1 ]]; then
            uid=${UO[uid]}                     # already allocated (and NSS-checked) by id_alloc
        elif [[ -n ${UO[uid]:-} ]]; then
            uid=${UO[uid]}; id_init
            _id_free pair "$uid" && ! { $LIVE && { getent passwd "$uid" || getent group "$uid"; } >/dev/null 2>&1; } ||
                die "$E_CONFLICT" "ID $uid is already in use as a UID or GID" "nothing was changed" \
                    "choose another --uid; a user's private group needs the same free number (v1 bug F-05)"
            id_mark pair "$uid"
        else
            id_alloc "$class" pair; uid=${ID_OUT[0]}
        fi
        gid=$uid
    fi

    if [[ -n ${UO[shell]:-} ]]; then shell=${UO[shell]}
    elif [[ $class == system ]]; then
        shell=/usr/sbin/nologin; [[ -x $R$shell ]] || shell=/sbin/nologin
    else shell=${CFG[default_shell]}
    fi
    home=${UO[home]:-${CFG[home_base]%/}/$n}
    today_days; today=$REPLY
    defs_get PASS_MIN_DAYS 0;  minp=$REPLY
    defs_get PASS_MAX_DAYS 99999; maxp=$REPLY
    defs_get PASS_WARN_AGE 7;  warnp=$REPLY
    uadef_get INACTIVE -1;     inact=$REPLY; [[ $inact == -1 ]] && inact=""
    if [[ -n ${UO[expire]+x} ]]; then exp=${UO[expire]}
    else uadef_get EXPIRE ""; exp=""; [[ -n $REPLY ]] && val_date "$REPLY" && exp=$REPLY
    fi
    last=$today
    [[ ${UO[force_change]:-0} == 1 ]] && last=0

    txn_target_user "$n"
    db_put PW "$n" "$n:x:$uid:$gid:${UO[gecos]:-}:$home:$shell"
    db_put SP "$n" "$n:${UO[hash]:-!}:$last:$minp:$maxp:$warnp:$inact:$exp:"
    if $upg; then
        txn_target_group "$n"
        db_put GR "$n" "$n:x:$gid:"
        [[ ${DB_HAS[GS]} == 1 ]] && db_put GS "$n" "$n:!::"
        TXN_VERIFY+=("group:$n:$gid")
    fi
    uo_list groups
    for g in "${LIST[@]}"; do group_member_add "$g" "$n"; done
    [[ $class == normal ]] && subid_alloc "$n"
    [[ ${UO[sudo]:-none} != none ]] && sudo_stage_grant "$n" "${UO[sudo]}" "${UO[sudo_cmds]:-}"
    TXN_VERIFY+=("user:$n:$uid")
    if [[ ${UO[no_home]:-0} != 1 ]]; then
        TXN_EFFECTS+=("home|$n|$uid|$gid|$home|${UO[role]:-}")
    fi
    if [[ -n ${UO[keys]:-} ]]; then
        KEYS_FOR[$n]=${UO[keys]}
        TXN_EFFECTS+=("keys|$n|$uid|$gid|$home")
    fi
    CREATED_UID=$uid CREATED_GID=$gid CREATED_HOME=$home CREATED_SHELL=$shell
}

op_user_passwd() {   # NAME HASH FORCE_CHANGE(0|1)
    user_need "$1"
    local h=$2
    # A UMC-locked account stays locked: setting a password is not an unlock.
    if [[ -f $STATE/locks/$1 && $S_HASH == \!* ]]; then h="!$h"; LOCK_KEPT=true; else LOCK_KEPT=false; fi
    today_days
    S_HASH=$h S_LAST=$REPLY
    [[ $3 == 1 ]] && S_LAST=0
    sp_stage "$1"
}

op_user_lock() {   # NAME SOURCE REASON
    local n=$1 src=$2 reason=${3:-} added=no prev now
    user_need "$n"
    ALREADY=false
    if [[ $S_HASH == \!* && $S_EXPIRE == 1 ]]; then ALREADY=true; return 0; fi
    prev=$S_EXPIRE
    if [[ -f $STATE/locks/$n ]]; then          # keep the ORIGINAL expiry from the first lock
        kv_get "$STATE/locks/$n" prev_expire && prev=$REPLY
        kv_get "$STATE/locks/$n" added_bang && added=$REPLY
    fi
    if [[ $S_HASH != \!* ]]; then S_HASH="!$S_HASH"; added=yes; fi
    # '!' only disables the password; the expiry date also stops SSH keys (F-19).
    S_EXPIRE=1
    sp_stage "$n"
    now_epoch; now=$REPLY
    state_put "$STATE/locks/$n" "source=$src" "reason=${reason//$'\n'/ }" "added_bang=$added" "prev_expire=$prev" "ts=$now" "actor=$ACTOR"
}

op_user_unlock() {   # NAME
    local n=$1 lf=$STATE/locks/$1 newh exp added=unknown
    user_need "$n"
    ALREADY=false
    newh=$S_HASH exp=$S_EXPIRE
    if [[ -f $lf ]]; then
        kv_get "$lf" added_bang; added=$REPLY
        kv_get "$lf" prev_expire; exp=$REPLY
        [[ $added == yes ]] && newh=${S_HASH#!}
    else
        [[ $S_HASH == \!* ]] && newh=${S_HASH#!}
        if [[ -n $S_EXPIRE ]]; then
            today_days
            if ((S_EXPIRE <= REPLY)); then
                exp=""
                warn "'$n' had an account expiry in the past (not set by UMC); it was cleared"
            fi
        fi
    fi
    if [[ $newh == "$S_HASH" && $exp == "$S_EXPIRE" && ! -f $lf ]]; then ALREADY=true; return 0; fi
    # Stripping '!' from a bare "!" leaves an EMPTY hash, i.e. a passwordless
    # account. v1 did exactly that (F-07); passwd -u refuses, and so does UMC.
    [[ -n $newh ]] || die "$E_CONFLICT" "unlocking '$n' would leave an empty password field (passwordless login)" \
        "nothing was changed" "set a password instead: umc user passwd $n --generate"
    pw_state "$newh"
    [[ $REPLY == none ]] && warn "'$n' has no password: after unlocking, only SSH keys can be used to log in"
    S_HASH=$newh S_EXPIRE=$exp
    sp_stage "$n"
    state_del "$lf"
    TXN_EFFECTS+=("faillock|$n")
}

op_user_modify() {   # NAME ; UO: gecos shell home move add_groups remove_groups rename uid expire
    local n=$1 g newn
    user_need "$n"
    local old_uid=$U_UID old_home=$U_HOME
    txn_target_user "$n"
    [[ -n ${UO[gecos]+x} ]] && U_GECOS=${UO[gecos]}
    [[ -n ${UO[shell]:-} ]] && U_SHELL=${UO[shell]}
    [[ -n ${UO[expire]+x} ]] && S_EXPIRE=${UO[expire]}
    if [[ -n ${UO[home]:-} && ${UO[home]} != "$U_HOME" ]]; then
        U_HOME=${UO[home]}
        [[ ${UO[move]:-0} == 1 ]] && TXN_EFFECTS+=("move-home|$n|$old_home|$U_HOME")
    fi
    if [[ -n ${UO[uid]:-} && ${UO[uid]} != "$U_UID" ]]; then
        id_init
        _id_free uid "${UO[uid]}" && ! { $LIVE && getent passwd "${UO[uid]}" >/dev/null 2>&1; } ||
            die "$E_CONFLICT" "UID ${UO[uid]} is already in use" "nothing was changed"
        U_UID=${UO[uid]}
        TXN_EFFECTS+=("rechown|$n|$old_uid|$U_UID|$U_HOME")
        retire_ids "$old_uid"
    fi
    uo_list add_groups
    for g in "${LIST[@]}"; do group_member_add "$g" "$n"; done
    uo_list remove_groups
    for g in "${LIST[@]}"; do
        db_exists GR "$g" || die "$E_NOTFOUND" "group '$g' does not exist" "nothing was changed"
        group_member_del "$g" "$n"
    done
    newn=${UO[rename]:-}
    if [[ -n $newn && $newn != "$n" ]]; then
        db_exists PW "$newn" && die "$E_CONFLICT" "user '$newn' already exists" "nothing was changed"
        nss_user_exists "$newn" && die "$E_CONFLICT" "a directory account named '$newn' exists" "nothing was changed"
        txn_target_user "$newn"
        db_del PW "$n"; db_del SP "$n"
        # The user-private group follows the user when it has the same name and GID.
        if db_fields GR "$n" && [[ ${F[2]} == "$U_GID" ]] && ! db_exists GR "$newn"; then
            txn_target_group "$n"; txn_target_group "$newn"
            F[0]=$newn; join_fields "${F[@]}"; db_del GR "$n"; db_put GR "$newn" "$REPLY"
            if db_fields GS "$n"; then F[0]=$newn; join_fields "${F[@]}"; db_del GS "$n"; db_put GS "$newn" "$REPLY"; fi
        fi
        _rename_memberships "$n" "$newn"
        subid_del "$n" "$newn"
        sudo_file_for "$n"
        if [[ -e $REPLY ]]; then
            # Same rule, new principal: only the first word of each rule line changes.
            local oldf=$REPLY
            sudo_stage_revoke "$n"
            sudo_file_for "$newn"
            txn_xfile "$REPLY" 0440 0 0
            awk -v o="$n" -v nn="$newn" '$1 == o { sub(/^[^ \t]+/, nn) } { print }' "$oldf" > "$REPLY"
        fi
        managed_load
        if [[ -n ${MANAGED[$n]+x} ]]; then
            managed_field "$n" 2; local ext=$REPLY; managed_field "$n" 3; local em=$REPLY
            managed_field "$n" 4; local cr=$REPLY; managed_field "$n" 5; local src=$REPLY; managed_field "$n" 6; local gg=$REPLY
            managed_del "$n"; managed_put "$newn" "$U_UID" "$ext" "$em" "$cr" "$src" "$gg"
        fi
        n=$newn
    fi
    pw_stage "$n"
    sp_stage "$n"
    TXN_VERIFY+=("user:$n:$U_UID")
}
_rename_memberships() {   # OLD NEW
    local line name r
    for line in "${GR_L[@]}"; do
        [[ $line == "$DEL" ]] && continue
        list_has "${line##*:}" "$1" || continue
        name=${line%%:*}
        db_fields GR "$name"; list_rename "${F[3]}" "$1" "$2"; F[3]=$REPLY
        txn_target_group "$name"; join_fields "${F[@]}"; db_put GR "$name" "$REPLY"
    done
    for line in "${GS_L[@]}"; do
        [[ $line == "$DEL" ]] && continue
        r=${line#*:*:}
        [[ ",${r//:/,}," == *",$1,"* ]] || continue
        name=${line%%:*}
        db_fields GS "$name"
        list_rename "${F[2]}" "$1" "$2"; F[2]=$REPLY
        list_rename "${F[3]}" "$1" "$2"; F[3]=$REPLY
        txn_target_group "$name"; join_fields "${F[@]}"; db_put GS "$name" "$REPLY"
    done
}

op_user_aging() {   # NAME ; UO: min max warn inactive
    user_need "$1"
    [[ -n ${UO[min]+x} ]]      && S_MIN=${UO[min]}
    [[ -n ${UO[max]+x} ]]      && S_MAX=${UO[max]}
    [[ -n ${UO[warn]+x} ]]     && S_WARN=${UO[warn]}
    [[ -n ${UO[inactive]+x} ]] && S_INACT=${UO[inactive]}
    [[ ${UO[force_change]:-0} == 1 ]] && S_LAST=0
    sp_stage "$1"
}

# Leaver, step 1 (reversible): lock, expire, strip privileges, disable keys,
# end sessions, archive the home. Nothing is deleted.
op_user_offboard() {   # NAME REASON
    local n=$1 g removed=() priv now sudo_had=no
    guard_account "$n" offboard
    ALREADY=false
    if [[ -f $STATE/offboarded/$n ]]; then ALREADY=true; return 0; fi
    op_user_lock "$n" offboard "${2:-offboarded}"
    user_groups "$n"
    for g in "${GROUPS_OF[@]}"; do
        for priv in ${CFG[privileged_groups]}; do
            [[ $g == "$priv" ]] || continue
            group_member_del "$g" "$n"; removed+=("$g")
        done
    done
    sudo_file_for "$n"
    if [[ -e $REPLY ]]; then sudo_had=yes; sudo_stage_revoke "$n"; fi
    now_epoch; now=$REPLY
    local IFS=,
    state_put "$STATE/offboarded/$n" "ts=$now" "actor=$ACTOR" "reason=${2:-}" "removed_groups=${removed[*]}" \
        "sudo_revoked=$sudo_had" "delete_after=$((now + CFG[offboard_retention_days] * 86400))"
    unset IFS
    TXN_EFFECTS+=("kill|$n|$U_UID")
    TXN_EFFECTS+=("keys-disable|$n|$U_UID|$U_GID|$U_HOME")
    [[ ${CFG[archive_home_on_offboard]} == yes ]] && TXN_EFFECTS+=("archive-home|$n|$U_UID|$U_HOME")
    OFFBOARD_REMOVED="${removed[*]}"
}

# The inverse of offboarding, for people who come back.
op_user_reinstate() {   # NAME
    local n=$1 of=$STATE/offboarded/$1 g
    user_need "$n"
    [[ -f $of ]] || die "$E_NOTFOUND" "'$n' was not offboarded by UMC" "nothing was changed" "to unlock it, use: umc user unlock $n"
    op_user_unlock "$n"
    kv_get "$of" removed_groups
    for g in ${REPLY//,/ }; do db_exists GR "$g" && group_member_add "$g" "$n"; done
    kv_get "$of" sudo_revoked
    [[ $REPLY == yes ]] && warn "offboarding had revoked a sudo rule for '$n'; re-grant it explicitly if still needed (umc sudo grant $n)"
    state_del "$of"
    TXN_EFFECTS+=("keys-enable|$n|$U_UID|$U_GID|$U_HOME")
}

# Hard delete: explicit, archived first, guarded.
op_user_delete() {   # NAME ; UO: keep_home force
    local n=$1 g line
    guard_account "$n" delete
    if $LIVE; then
        user_procs "$U_UID"
        if ((REPLY > 0)) && [[ ${UO[force]:-0} != 1 ]]; then
            die "$E_CONFLICT" "'$n' still has $REPLY running process(es)" "nothing was changed" \
                "offboard first (umc user offboard $n) or add --force to kill them"
        fi
    fi
    TXN_ORDER=unpublish
    txn_target_user "$n"
    db_del PW "$n"; db_del SP "$n"
    for line in "${GR_L[@]}"; do
        [[ $line == "$DEL" ]] && continue
        list_has "${line##*:}" "$n" && group_member_del "${line%%:*}" "$n"
    done
    for line in "${GS_L[@]}"; do
        [[ $line == "$DEL" ]] && continue
        g=${line%%:*}
        db_fields GS "$g" && { list_has "${F[2]}" "$n" || list_has "${F[3]}" "$n"; } && group_member_del "$g" "$n"
    done
    # Remove the user-private group only if nobody else depends on it.
    DELETED_UPG=""
    if db_fields GR "$n" && [[ ${F[2]} == "$U_GID" && -z ${F[3]} ]]; then
        group_users_primary "$U_GID"
        if [[ -z $REPLY ]]; then
            txn_target_group "$n"; db_del GR "$n"; db_del GS "$n"; DELETED_UPG=$n
        else
            warn "group '$n' is still the primary group of: $REPLY - kept"
        fi
    fi
    subid_del "$n"
    sudo_stage_revoke "$n"
    state_del "$STATE/locks/$n"; state_del "$STATE/onboarding/$n"; state_del "$STATE/offboarded/$n"
    managed_del "$n"
    retire_ids "$U_UID" "${DELETED_UPG:+$U_GID}"
    local cron
    for cron in /var/spool/cron/crontabs/"$n" /var/spool/cron/"$n"; do
        [[ -f $R$cron ]] && TXN_EFFECTS+=("file-remove|$n|$cron|crontab")
    done
    for cron in /var/mail/"$n" /var/spool/mail/"$n"; do
        [[ -f $R$cron && ! -L $R$cron ]] && TXN_EFFECTS+=("file-remove|$n|$cron|mail")
    done
    if [[ ${UO[force]:-0} == 1 ]]; then TXN_EFFECTS=("kill|$n|$U_UID" "${TXN_EFFECTS[@]}"); fi
    [[ ${UO[keep_home]:-0} == 1 ]] || TXN_EFFECTS+=("home-remove|$n|$U_UID|$U_HOME")
}

# --- groups ------------------------------------------------------------------------
op_group_create() {   # NAME GID(optional) SYSTEM(0|1)
    local n=$1 gid=${2:-} class=normal
    [[ ${3:-0} == 1 ]] && class=system
    db_exists GR "$n" && bug "op_group_create: '$n' exists"
    nss_group_exists "$n" && die "$E_CONFLICT" "a directory (LDAP/SSSD) group named '$n' already exists" "nothing was changed"
    if [[ -n $gid ]]; then
        id_init
        _id_free gid "$gid" && ! { $LIVE && getent group "$gid" >/dev/null 2>&1; } ||
            die "$E_CONFLICT" "GID $gid is already in use" "nothing was changed"
        id_mark gid "$gid"
    else
        id_alloc "$class" gid; gid=${ID_OUT[0]}
    fi
    txn_target_group "$n"
    db_put GR "$n" "$n:x:$gid:"
    [[ ${DB_HAS[GS]} == 1 ]] && db_put GS "$n" "$n:!::"
    TXN_VERIFY+=("group:$n:$gid")
    CREATED_GID=$gid
}

op_group_delete() {   # NAME ; UO: force
    local n=$1 gid
    db_fields GR "$n" || die "$E_NOTFOUND" "group '$n' does not exist" "nothing was changed"
    gid=${F[2]}
    group_users_primary "$gid"
    [[ -z $REPLY ]] || die "$E_CONFLICT" "group '$n' is the primary group of: $REPLY" "nothing was changed" \
        "change their primary group or delete those users first"
    admin_group && [[ $REPLY == "$n" ]] && die "$E_CONFLICT" "refusing to delete '$n': it grants sudo on this host" "nothing was changed"
    defs_get GID_MIN 1000
    if ((gid < REPLY)) && [[ ${UO[force]:-0} != 1 ]]; then
        die "$E_CONFLICT" "refusing to delete '$n': GID $gid is a system group" "nothing was changed" "pass --force if you really mean it"
    fi
    TXN_ORDER=unpublish
    txn_target_group "$n"
    db_del GR "$n"; db_del GS "$n"
    sudo_stage_revoke "%$n"
    retire_ids "" "$gid"
}

# ==============================================================================
# §10 BULK: READ ANY HR EXPORT, THEN PLAN AND APPLY
#     The admin should not have to reformat HR's spreadsheet. UMC works out the
#     structure itself (encoding, delimiter, where the records are, which column
#     means what), SHOWS what it understood ('umc import inspect', 'umc plan')
#     and applies nothing until that has been seen. Guess -> show -> confirm.
#     No jq, no python: the JSON and CSV readers below are portable awk (they
#     also run on Debian's default mawk).
# ==============================================================================

# JSON -> one line per scalar: PATH <TAB> TYPE(s|n|b|z|o|a) <TAB> VALUE.
# Control characters inside strings become \177 so they are rejected later.
readonly AWK_JSON='
function err(m) { printf "!error\t%s (near character %d)\n", m, p; exit 3 }
function ws(   c) { while (p <= N) { c = substr(S, p, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") p++; else break } }
function fixkey(k) { gsub(/[.\[\]\t]/, "_", k); return k }
function emit(path, t, v) { print path "\t" t "\t" v }
function hexval(h,   i, c, v) { v = 0; h = tolower(h); for (i = 1; i <= 4; i++) { c = index("0123456789abcdef", substr(h, i, 1)); if (c == 0) err("bad \\u escape"); v = v * 16 + c - 1 } return v }
function utf8(c) {
    if (c < 32) return "\177"
    if (c < 128) return sprintf("%c", c)
    if (c < 2048) return sprintf("%c%c", 192 + int(c / 64), 128 + c % 64)
    if (c < 65536) return sprintf("%c%c%c", 224 + int(c / 4096), 128 + int(c / 64) % 64, 128 + c % 64)
    return sprintf("%c%c%c%c", 240 + int(c / 262144), 128 + int(c / 4096) % 64, 128 + int(c / 64) % 64, 128 + c % 64)
}
function str(   s, c, e, u, u2) {
    p++; s = ""
    while (p <= N) {
        c = substr(S, p, 1)
        if (c == "\"") { p++; return s }
        if (c == "\\") {
            e = substr(S, p + 1, 1); p += 2
            if (e == "\"" || e == "\\" || e == "/") s = s e
            else if (e == "n" || e == "t" || e == "r" || e == "b" || e == "f") s = s "\177"
            else if (e == "u") {
                u = hexval(substr(S, p, 4)); p += 4
                if (u >= 55296 && u <= 56319 && substr(S, p, 2) == "\\u") {
                    u2 = hexval(substr(S, p + 2, 4))
                    if (u2 >= 56320 && u2 <= 57343) { u = 65536 + (u - 55296) * 1024 + (u2 - 56320); p += 6 }
                }
                s = s utf8(u)
            } else err("invalid escape \\" e)
            continue
        }
        if (c < " ") c = "\177"
        s = s c; p++
    }
    err("unterminated string")
}
function num(path,   st) {
    st = p
    if (substr(S, p, 1) == "-") p++
    while (p <= N && substr(S, p, 1) ~ /[0-9.eE+-]/) p++
    emit(path, "n", substr(S, st, p - st))
}
function value(path,   c) {
    ws(); if (p > N) err("unexpected end of document")
    c = substr(S, p, 1)
    if (c == "{") obj(path)
    else if (c == "[") arr(path)
    else if (c == "\"") emit(path, "s", str())
    else if (c == "-" || (c >= "0" && c <= "9")) num(path)
    else if (substr(S, p, 4) == "true")  { p += 4; emit(path, "b", "true") }
    else if (substr(S, p, 5) == "false") { p += 5; emit(path, "b", "false") }
    else if (substr(S, p, 4) == "null")  { p += 4; emit(path, "z", "") }
    else err("unexpected character \"" c "\"")
}
function obj(path,   k, c) {
    p++; ws()
    if (substr(S, p, 1) == "}") { p++; emit(path, "o", ""); return }
    while (1) {
        ws(); if (substr(S, p, 1) != "\"") err("expected a quoted key")
        k = fixkey(str()); ws()
        if (substr(S, p, 1) != ":") err("expected : after key " k)
        p++
        value(path == "" ? k : path "." k)
        ws(); c = substr(S, p, 1)
        if (c == ",") { p++; continue }
        if (c == "}") { p++; return }
        err("expected , or }")
    }
}
function arr(path,   i, c) {
    p++; ws(); i = 0
    if (substr(S, p, 1) == "]") { p++; emit(path, "a", ""); return }
    while (1) {
        value(path "[" i "]"); i++
        ws(); c = substr(S, p, 1)
        if (c == ",") { p++; continue }
        if (c == "]") { p++; return }
        err("expected , or ]")
    }
}
BEGIN { RS = "\001" }
{ S = S $0 }
END { N = length(S); p = 1; value(""); ws(); if (p <= N) err("unexpected text after the JSON document") }'

# Which arrays of objects exist, and how many elements each has (outermost first).
readonly AWK_JSON_PREFIXES='BEGIN { FS = "\t" }
    match($1, /\[[0-9]+\]\./) {
        pre = substr($1, 1, RSTART - 1); k = pre SUBSEP substr($1, RSTART, RLENGTH - 1)
        if (!(k in seen)) { seen[k] = 1; cnt[pre]++ }
    }
    END { for (x in cnt) print cnt[x] "\t" x }'

# Records under prefix P -> INDEX <TAB> FIELD <TAB> VALUE (nested keys joined with _).
readonly AWK_JSON_RECORDS='BEGIN { FS = "\t"; pl = length(P) }
    {
        path = $1
        if (substr(path, 1, pl + 1) != P "[") next
        rest = substr(path, pl + 1)
        if (!match(rest, /^\[[0-9]+\]/)) next
        idx = substr(rest, 2, RLENGTH - 2); rest = substr(rest, RLENGTH + 1)
        if (substr(rest, 1, 1) != ".") next
        rest = substr(rest, 2)
        gsub(/\[[0-9]+\]/, "", rest); gsub(/\./, "_", rest)
        if ($2 == "o" || $2 == "a") next
        print idx "\t" rest "\t" $3
    }'

# Which delimiter makes the most lines agree on a field count? (quote-aware)
readonly AWK_SNIFF='BEGIN { d[1] = ","; d[2] = ";"; d[3] = "\t"; d[4] = "|" }
    NR > 50 { exit }
    { s = $0; sub(/\r$/, "", s); if (s == "") next
      lines++
      for (k = 1; k <= 4; k++) {
          c = 0; q = 0
          for (i = 1; i <= length(s); i++) { ch = substr(s, i, 1); if (ch == "\"") q = !q; else if (!q && ch == d[k]) c++ }
          n[k, lines] = c
      } }
    END {
        best = 1; bs = -1
        for (k = 1; k <= 4; k++) {
            for (x in h) delete h[x]
            mode = 0; mc = 0
            for (l = 1; l <= lines; l++) { v = n[k, l]; h[v]++; if (h[v] > mc || (h[v] == mc && v > mode)) { mc = h[v]; mode = v } }
            if (mode == 0) continue
            score = mc * 1000 + mode
            if (score > bs) { bs = score; best = k }
        }
        print best
    }'

# RFC 4180 CSV -> LINE \037 field \037 field ... (quotes, "" escapes, delimiters
# and line breaks inside quotes; a line break inside a field becomes \177).
readonly AWK_CSV='BEGIN { US = "\037"; inq = 0; nf = 0; fld = "" }
    function flush(   j, out) {
        f[++nf] = fld
        if (!(nf == 1 && f[1] == "")) { out = start; for (j = 1; j <= nf; j++) out = out US f[j]; print out }
        nf = 0; fld = ""
    }
    {
        s = $0; sub(/\r$/, "", s)
        if (!inq && index(s, "\"") == 0) {
            if (s == "") next
            n = split(s, a, D); out = NR
            for (j = 1; j <= n; j++) out = out US a[j]
            print out; next
        }
        if (inq) fld = fld "\177"; else start = NR
        len = length(s)
        for (i = 1; i <= len; i++) {
            c = substr(s, i, 1)
            if (inq) {
                if (c == "\"") { if (substr(s, i + 1, 1) == "\"") { fld = fld "\""; i++ } else inq = 0 }
                else fld = fld c
            } else if (c == "\"" && fld == "") inq = 1
            else if (c == D) { f[++nf] = fld; fld = "" }
            else fld = fld c
        }
        if (inq) next
        flush()
    }
    END { if (inq) { print "!error\tunterminated quoted field starting on line " start; exit 3 } }'

# Accented Latin letters -> ASCII (UTF-8 aware, byte-wise). Anything it cannot
# transliterate becomes "?" and the name is FLAGGED, never silently mangled.
readonly AWK_TRANSLIT='BEGIN {
    FS = OFS = "\t"
    m = "à a á a â a ã a ä a å a æ ae ç c è e é e ê e ë e ì i í i î i ï i ð d ñ n ò o ó o ô o õ o ö o ø o ù u ú u û u ü u ý y þ th ÿ y ß ss "
    m = m "À a Á a Â a Ã a Ä a Å a Æ ae Ç c È e É e Ê e Ë e Ì i Í i Î i Ï i Ð d Ñ n Ò o Ó o Ô o Õ o Ö o Ø o Ù u Ú u Û u Ü u Ý y Þ th "
    m = m "ā a Ā a ă a Ă a ą a Ą a ć c Ć c č c Č c ď d Ď d đ d Đ d ē e Ē e ė e Ė e ę e Ę e ě e Ě e ğ g Ğ g ī i Ī i į i Į i ı i İ i "
    m = m "ł l Ł l ń n Ń n ň n Ň n ō o Ō o ő o Ő o œ oe Œ oe ř r Ř r ś s Ś s ş s Ş s š s Š s ť t Ť t ţ t Ţ t ū u Ū u ů u Ů u "
    m = m "ű u Ű u ų u Ų u ź z Ź z ż z Ż z ž z Ž z"
    n = split(m, t, " "); for (i = 1; i < n; i += 2) map[t[i]] = t[i + 1]
}
function tr(s,   i, c, ch, out, L) {
    out = ""; L = length(s)
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (c >= "\300" && c <= "\337") { ch = substr(s, i, 2); i++; out = out ((ch in map) ? map[ch] : "?") }
        else if (c >= "\340" && c <= "\357") { i += 2; out = out "?" }
        else if (c >= "\360") { i += 3; out = out "?" }
        else out = out c
    }
    return out
}
{ for (k = 1; k <= NF; k++) $k = tr($k); print }'

# Header aliases (normalised: lower case, letters and digits only).
# '?x' entries are decided by looking at the column's values.
declare -A IMP_ALIAS=()
_imp_aliases() {
    ((${#IMP_ALIAS[@]})) && return 0
    local c a
    local -A tbl=(
        [username]="username user login loginname loginid account accountname samaccountname unixname linuxuser linuxusername handle unixusername"
        ['?uid']="uid userid"
        [uid]="uidnumber unixuid"
        ['?name']="name"
        [first_name]="firstname first givenname forename fname namefirst preferredfirstname"
        [last_name]="lastname last surname familyname sn lname namelast"
        [full_name]="fullname displayname cn commonname employeename legalname namefull"
        [email]="email emailaddress mail workemail businessemail primaryemail userprincipalname upn emailwork"
        [external_id]="id employeeid employeenumber empid empno staffid staffnumber personid workerid badgeid badge personnelnumber hrid"
        [department]="department dept division team orgunit businessunit ou"
        [title]="title jobtitle position designation"
        ['?role']="role"
        [role]="umcrole accessrole linuxrole"
        [groups]="groups group unixgroups linuxgroups memberof accessgroups"
        [shell]="shell loginshell"
        [home]="home homedir homedirectory"
        [expire]="expire expires expiry expirydate expirationdate enddate contractend contractenddate leavingdate lastday lastworkingday validuntil accountexpires terminationdate"
        [state]="state status employmentstatus accountstatus active enabled isactive"
        [ssh_key]="sshkey sshkeys publickey sshpublickey authorizedkeys pubkey"
        [password_hash]="passwordhash hash cryptpassword"
        [password]="password pass pwd initialpassword temppassword"
        [password_generate]="passwordgenerate"
        [password_force_change]="passwordforcechange"
        [phone]="phone workphone officephone telephone telephonenumber phonenumber mobile"
        [location]="location office room building site city"
        [comment]="comment gecos description"
        [sudo]="sudo"
    )
    for c in "${!tbl[@]}"; do for a in ${tbl[$c]}; do IMP_ALIAS[$a]=$c; done; done
}

declare -A RAW=() REC=() IMP_OVR=() IMP_GRP=() IMP_DEF=()
IMP_FILE="" IMP_TMP="" IMP_FORMAT="" IMP_ENC="" IMP_DELIM="" IMP_PREFIX="" IMP_NATIVE=false IMP_COUNT=0
IMP_COLS=() IMP_CANON=() IMP_HOW=() IMP_ROW=() IMP_ERR=() IMP_NOTES=() IMP_DERIVED=0
IMP_DATEFMT="" IMP_ALLOW_PLAIN=false IMP_SKIP_INVALID=false IMP_CREATE_GROUPS=false IMP_PRUNE=false IMP_FATAL=false
IMP_PROFILE="" IMP_SAVE_PROFILE="" IMP_CREDS_OUT=""

split_us() {   # split on \037 (not IFS whitespace, but done by hand for speed and safety)
    local s=$1
    T=()
    while [[ $s == *$'\037'* ]]; do T+=("${s%%$'\037'*}"); s=${s#*$'\037'}; done
    T+=("$s")
}
_trim() { local v=$1; v=${v##+([[:space:]])}; v=${v%%+([[:space:]])}; REPLY=$v; }
# A record with any problem is excluded from the plan and reported instead,
# so the plan shown is exactly the plan --skip-invalid would apply.
_imp_err() { IMP_ERR+=("${IMP_ROW[$1]}: $2"); REC[$1:bad]=1; }
join_by() { local IFS=$1; shift; REPLY="$*"; }

_imp_tmp() {
    [[ -n $IMP_TMP ]] && return 0
    IMP_TMP=$(mktemp -d) || die "$E_FAIL" "mktemp failed"
    CLEANUP+=("$IMP_TMP")
}

_imp_decode() {   # IN OUT
    local in=$1 out=$2 bom nul
    bom=$(head -c 4 -- "$in" | od -An -tx1 | tr -d ' \n')
    case $bom in
        fffe*|feff*)
            cap_has iconv || die "$E_FAIL" "${in##*/} is UTF-16 (Excel 'Unicode Text'); converting it needs iconv" "nothing was changed" "install glibc-common / libc-bin, or save the file as CSV UTF-8"
            iconv -f UTF-16 -t UTF-8 -- "$in" > "$out" || die "$E_INVALID" "${in##*/}: invalid UTF-16" "nothing was changed"
            IMP_ENC="UTF-16 (converted to UTF-8)" ;;
        efbbbf*)
            tail -c +4 -- "$in" > "$out"; IMP_ENC="UTF-8 with BOM" ;;
        *)
            nul=$(head -c 4096 -- "$in" | tr -d -c '\000' | wc -c)
            if ((nul > 0)) && cap_has iconv; then
                iconv -f UTF-16LE -t UTF-8 -- "$in" > "$out" || die "$E_INVALID" "${in##*/} looks like UTF-16 but cannot be converted" "nothing was changed"
                IMP_ENC="UTF-16LE without BOM (converted to UTF-8)"
            elif cap_has iconv && ! iconv -f UTF-8 -t UTF-8 -- "$in" >/dev/null 2>&1; then
                iconv -f WINDOWS-1252 -t UTF-8 -- "$in" > "$out" || die "$E_INVALID" "${in##*/}: unknown text encoding" "nothing was changed"
                IMP_ENC="Windows-1252 (converted to UTF-8)"
            else
                cp -- "$in" "$out"; IMP_ENC="UTF-8"
            fi ;;
    esac
    grep -q $'\r' -- "$out" && IMP_ENC+=", Windows line endings (CRLF)"
    return 0
}

imp_read() {   # FILE
    local f=$1 norm first size
    [[ -f $f && -r $f ]] || die "$E_NOTFOUND" "cannot read $f" "nothing was changed"
    size=$(stat -c %s -- "$f")
    ((size > 0)) || die "$E_INVALID" "$f is empty" "nothing was changed"
    ((size <= 52428800)) || die "$E_INVALID" "$f is larger than 50 MB" "nothing was changed" "split it into smaller files"
    IMP_FILE=$f
    _imp_tmp
    _imp_aliases
    norm=$IMP_TMP/input
    _imp_decode "$f" "$norm"
    first=$(tr -d ' \t\r\n' < "$norm" | head -c 1)
    RAW=() REC=() IMP_COLS=() IMP_ROW=() IMP_ERR=() IMP_NOTES=() IMP_GRP=() IMP_DEF=() IMP_COUNT=0 IMP_DERIVED=0 IMP_FATAL=false
    if [[ $first == '{' || $first == '[' ]]; then IMP_FORMAT=JSON; _imp_json "$norm"; else IMP_FORMAT=CSV; _imp_csv "$norm"; fi
    ((IMP_COUNT > 0)) || die "$E_INVALID" "${f##*/} contains no records" "nothing was changed"
    _imp_profile_load
    _imp_map_columns
    _imp_build_records
}

_imp_csv() {
    local f=$1 k d line i=0 c
    k=$(awk "$AWK_SNIFF" "$f")
    case $k in 2) d=';' ;; 3) d=$'\t' ;; 4) d='|' ;; *) d=',' ;; esac
    IMP_DELIM=$d
    local lines=()
    mapfile -t lines < <(awk -v D="$d" "$AWK_CSV" "$f")
    [[ ${lines[-1]:-} == '!error'* ]] && die "$E_INVALID" "${IMP_FILE##*/}: ${lines[-1]#*$'\t'}" "nothing was changed"
    ((${#lines[@]} >= 2)) || die "$E_INVALID" "${IMP_FILE##*/} has a header but no data rows" "nothing was changed"
    split_us "${lines[0]}"
    IMP_COLS=("${T[@]:1}")
    for ((i = 1; i < ${#lines[@]}; i++)); do
        split_us "${lines[i]}"
        IMP_ROW[i - 1]="row ${T[0]}"
        for ((c = 1; c < ${#T[@]}; c++)); do RAW[$((i - 1)):$((c - 1))]=${T[c]}; done
        ((${#T[@]} - 1 > ${#IMP_COLS[@]})) && IMP_ERR+=("row ${T[0]}: has $(( ${#T[@]} - 1 )) fields but the header has ${#IMP_COLS[@]} (a delimiter inside an unquoted value?)")
    done
    IMP_COUNT=$(( ${#lines[@]} - 1 ))
}

_imp_json() {
    local f=$1 flat=$IMP_TMP/flat best="" cnt p idx fld val col line
    awk "$AWK_JSON" "$f" > "$flat"
    if [[ $(head -n 1 -- "$flat") == '!error'* || $(tail -n 1 -- "$flat") == '!error'* ]]; then
        line=$(grep -m1 '^!error' "$flat")
        die "$E_INVALID" "${IMP_FILE##*/} is not valid JSON: ${line#*$'\t'}" "nothing was changed"
    fi
    if grep -q '^users\[[0-9]*\]\.' -- "$flat"; then
        IMP_NATIVE=true best=users
    else
        # The largest array of objects is the list of people; prefer usual names on a tie.
        local bc=0 name
        while IFS=$'\t' read -r cnt p; do
            name=${p##*.}
            if ((cnt > bc)) || { ((cnt == bc)) && [[ ${name,,} =~ ^(users|employees|people|members|records|data|items|staff|accounts|workers|results)$ ]]; }; then
                bc=$cnt best=$p
            fi
        done < <(awk "$AWK_JSON_PREFIXES" "$flat")
        ((bc > 0)) || die "$E_INVALID" "${IMP_FILE##*/}: no list of records (array of objects) was found" "nothing was changed"
    fi
    IMP_PREFIX=$best
    declare -A colidx=()
    local maxidx=-1
    while IFS=$'\t' read -r idx fld val; do
        if [[ -z ${colidx[$fld]+x} ]]; then colidx[$fld]=${#IMP_COLS[@]}; IMP_COLS+=("$fld"); fi
        col=${colidx[$fld]}
        if [[ -n ${RAW[$idx:$col]+x} && -n ${RAW[$idx:$col]} ]]; then RAW[$idx:$col]+=";$val"; else RAW[$idx:$col]=$val; fi
        ((idx > maxidx)) && maxidx=$idx
    done < <(awk -v P="$best" "$AWK_JSON_RECORDS" "$flat")
    IMP_COUNT=$((maxidx + 1))
    for ((idx = 0; idx < IMP_COUNT; idx++)); do IMP_ROW[idx]="record $((idx + 1))"; done
    if $IMP_NATIVE; then
        # Native manifest extras: "groups": [{name, gid, state}], "defaults": {...}
        local gname gi
        while IFS=$'\t' read -r idx fld val; do
            RAW[g$idx:$fld]=$val
        done < <(awk -v P=groups "$AWK_JSON_RECORDS" "$flat")
        for ((gi = 0; ; gi++)); do
            [[ -n ${RAW[g$gi:name]+x} ]] || break
            gname=${RAW[g$gi:name]}
            IMP_GRP[$gname]="${RAW[g$gi:gid]:-}|${RAW[g$gi:state]:-present}"
        done
        while IFS=$'\t' read -r p _ val; do
            [[ $p == defaults.* ]] || continue
            fld=${p#defaults.}; fld=${fld%%\[*}
            IMP_DEF[$fld]=${IMP_DEF[$fld]:+${IMP_DEF[$fld]};}$val
        done < "$flat"
    fi
}

# --map 'Source Column=field' and saved profiles (/etc/umc/import-profiles/NAME.map)
_imp_profile_load() {
    [[ -n $IMP_PROFILE ]] || return 0
    local f=$ETC/umc/import-profiles/$IMP_PROFILE.map line
    [[ -f $f ]] || die "$E_NOTFOUND" "import profile '$IMP_PROFILE' does not exist ($f)" "nothing was changed"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line || $line == \#* || $line != *=* ]] && continue
        [[ -n ${IMP_OVR[${line%%=*}]+x} ]] || IMP_OVR[${line%%=*}]=${line#*=}
    done < "$f"
}
readonly IMP_FIELDS=" username uid first_name last_name full_name email external_id department title role groups shell home expire state ssh_key password_hash password password_generate password_force_change phone location comment sudo ignore "

_imp_map_columns() {
    local i c norm canon vals v allnum allname allrole
    declare -A first_for=()
    IMP_CANON=() IMP_HOW=()
    for i in "${!IMP_COLS[@]}"; do
        c=${IMP_COLS[i]}
        norm=${c,,}; norm=${norm//[^a-z0-9]/}
        canon="" IMP_HOW[i]=""
        if [[ -n ${IMP_OVR[$c]+x} ]]; then canon=${IMP_OVR[$c]}; IMP_HOW[i]="--map"
        elif [[ -n ${IMP_OVR[$norm]+x} ]]; then canon=${IMP_OVR[$norm]}; IMP_HOW[i]="--map"
        else canon=${IMP_ALIAS[$norm]:-}
        fi
        [[ -z $canon || $IMP_FIELDS == *" $canon "* || $canon == \?* ]] ||
            die "$E_USAGE" "--map: '$canon' is not a field UMC knows" "nothing was changed" "fields:$IMP_FIELDS"
        [[ $canon == ignore ]] && canon=""
        if [[ $canon == \?* ]]; then
            # Decide by content: all numeric -> uid; all valid user names -> username; ...
            allnum=true allname=true allrole=true vals=0
            for ((v = 0; v < IMP_COUNT; v++)); do
                _trim "${RAW[$v:$i]:-}"; [[ -z $REPLY ]] && continue
                vals=$((vals + 1))
                [[ $REPLY =~ ^[0-9]+$ ]] || allnum=false
                [[ ${REPLY,,} =~ ${CFG[name_regex]} ]] || allname=false
                [[ -f $ETC/umc/roles.d/${REPLY,,}.conf ]] || allrole=false
            done
            case $canon in
                '?uid')  if $allnum && ((vals)); then canon=uid; else canon=username; fi ;;
                '?name') if $allname && ((vals)); then canon=username; else canon=full_name; fi ;;
                '?role') if $allrole && ((vals)); then canon=role; else canon=title; fi ;;
            esac
            IMP_HOW[i]="by content"
        fi
        [[ -n $canon && -z ${IMP_HOW[i]} ]] && IMP_HOW[i]="alias"
        if [[ -n $canon && -n ${first_for[$canon]+x} ]]; then
            IMP_NOTES+=("columns '${first_for[$canon]}' and '$c' both mean $canon; the first non-empty value wins")
        fi
        [[ -n $canon && -z ${first_for[$canon]+x} ]] && first_for[$canon]=$c
        IMP_CANON[i]=$canon
    done
    [[ -n ${first_for[username]+x}${first_for[email]+x}${first_for[full_name]+x} ]] ||
    [[ -n ${first_for[first_name]+x} && -n ${first_for[last_name]+x} ]] ||
        die "$E_INVALID" "${IMP_FILE##*/}: no column identifies the people (need a user name, an e-mail, or first + last name)" \
            "nothing was changed" "map a column explicitly, e.g. --map 'Login ID=username' (see: umc import inspect)"
}

# Dates as HR systems write them. Ambiguous ones are refused, not guessed.
imp_date() {   # VALUE -> REPLY days ('' = never)
    local v=$1 a b y s
    [[ $v =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[T\ ][0-9] ]] && v=${BASH_REMATCH[1]}     # ISO date-time
    case ${v,,} in ''|never|none|n/a|na|-|null) REPLY=""; return 0 ;; esac
    [[ $v =~ ^\+[0-9]{1,5}$ ]] && { val_date "$v"; return; }                 # +DAYS from today
    if [[ $v =~ ^[0-9]{5}$ ]] && ((10#$v >= 20000 && 10#$v <= 80000)); then   # Excel serial date
        REPLY=$((10#$v - 25569)); return 0
    fi
    if [[ $v =~ ^([0-9]{4})[-/.]([0-9]{1,2})[-/.]([0-9]{1,2})$ ]]; then
        printf -v v '%04d-%02d-%02d' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
        val_date "$v"; return
    fi
    if [[ $v =~ ^([0-9]{1,2})([./-])([0-9]{1,2})[./-]([0-9]{4})$ ]]; then
        a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[3]})) y=${BASH_REMATCH[4]}
        local fmt=$IMP_DATEFMT
        [[ ${BASH_REMATCH[2]} == . && -z $fmt ]] && fmt=dmy          # 31.12.2026 is always day-first
        if [[ -z $fmt ]]; then
            if ((a > 12)); then fmt=dmy; elif ((b > 12)); then fmt=mdy
            elif ((a == b)); then fmt=dmy
            else _vfail "'$1' is ambiguous (day/month or month/day?); pass --date-format dmy or mdy"; return 1
            fi
        fi
        if [[ $fmt == dmy ]]; then printf -v v '%s-%02d-%02d' "$y" "$b" "$a"; else printf -v v '%s-%02d-%02d' "$y" "$a" "$b"; fi
        val_date "$v"; return
    fi
    if [[ $v == *[A-Za-z]* ]] && s=$(date -u -d "$v" +%s 2>/dev/null); then REPLY=$((s / 86400)); return 0; fi
    _vfail "'$1' is not a date UMC understands"
}

imp_state() {   # VALUE -> REPLY present|locked|absent
    case ${1,,} in
        ''|active|a|hired|current|employed|enabled|present|true|yes|y|1|new|onboarding) REPLY=present ;;
        terminated|term|inactive|leaver|left|former|disabled|false|no|n|0|absent|deleted|offboarded|resigned|retired|fired) REPLY=absent ;;
        locked|suspended|onleave|'on leave'|leave|loa|'leave of absence'|paused|hold|'on hold') REPLY=locked ;;
        *) _vfail "status '$1' is not understood (use present/locked/absent, or Active/On leave/Terminated)"; return 1 ;;
    esac
}

# Rules: /etc/umc/rules.conf
#   department=Engineering -> role=dev
#   title=*Manager*        -> groups=managers
RULE_ATTR=() RULE_GLOB=() RULE_ACT=()
_imp_rules_load() {
    RULE_ATTR=() RULE_GLOB=() RULE_ACT=()
    local f=$ETC/umc/rules.conf line n=0 lhs rhs
    [[ -f $f ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1)); line=${line%%#*}
        _trim "$line"; line=$REPLY
        [[ -z $line ]] && continue
        [[ $line == *'->'* ]] || die "$E_INVALID" "$f:$n: expected 'attribute=pattern -> action'"
        lhs=${line%%->*} rhs=${line#*->}
        _trim "$lhs"; lhs=$REPLY; _trim "$rhs"; rhs=$REPLY
        [[ $lhs =~ ^(department|title|location|email|external_id|username)=(.+)$ ]] ||
            die "$E_INVALID" "$f:$n: the left side must be department=, title=, location=, email=, external_id= or username="
        RULE_ATTR+=("${BASH_REMATCH[1]}"); RULE_GLOB+=("${BASH_REMATCH[2],,}")
        [[ $rhs =~ ^(role|groups|shell|sudo)=(.+)$ ]] || die "$E_INVALID" "$f:$n: the action must be role=, groups=, shell= or sudo="
        RULE_ACT+=("$rhs")
    done < "$f"
}

_imp_build_records() {
    local r i k v canon names=()
    _imp_rules_load
    for ((r = 0; r < IMP_COUNT; r++)); do
        for i in "${!IMP_COLS[@]}"; do
            canon=${IMP_CANON[i]}
            [[ -n $canon ]] || continue
            _trim "${RAW[$r:$i]:-}"; v=$REPLY
            [[ -n $v ]] || continue
            [[ -n ${REC[$r:$canon]+x} ]] || REC[$r:$canon]=$v
        done
        for k in "${!IMP_DEF[@]}"; do                           # native manifest defaults
            [[ -n ${REC[$r:$k]+x} ]] || REC[$r:$k]=${IMP_DEF[$k]}
        done
        local em=${REC[$r:email]:-}
        names+=("${REC[$r:first_name]:-}"$'\t'"${REC[$r:last_name]:-}"$'\t'"${REC[$r:full_name]:-}"$'\t'"${em%%@*}")
    done
    # One awk process transliterates every name in the file.
    local tr=()
    mapfile -t tr < <(printf '%s\n' "${names[@]}" | awk "$AWK_TRANSLIT")
    for ((r = 0; r < IMP_COUNT; r++)); do _imp_norm_record "$r" "${tr[r]:-}"; done
    _imp_dedupe
}

_uname_from() {   # TEXT -> REPLY: lower case, letters/digits/._- only
    local v=${1,,}
    v=${v//[[:space:]]/}
    v=${v//[^a-z0-9._-]/}
    while [[ $v == *..* ]]; do v=${v//../.}; done
    v=${v##[^a-z_]*([^a-z_])}
    v=${v%%+([.-])}
    REPLY=${v:0:${CFG[name_max_len]}}
}

_imp_norm_record() {   # INDEX TRANSLITERATED(first\tlast\tfull\temaillocal)
    local r=$1 v f l full el k list=() g key keys=() gecos phone loc rule a
    local IFS=$' \t\n'
    # --- state
    if imp_state "${REC[$r:state]:-}"; then REC[$r:state]=$REPLY; else _imp_err "$r" "$VAL_ERR"; REC[$r:state]=invalid; fi
    # --- simple validated fields
    if [[ -n ${REC[$r:uid]:-} ]]; then val_uint uid "${REC[$r:uid]}" 1 4294967294 && REC[$r:uid]=$REPLY || _imp_err "$r" "$VAL_ERR"; fi
    if [[ -n ${REC[$r:email]:-} ]]; then
        v=${REC[$r:email],,}
        [[ $v =~ ^[^@[:space:]:,]+@[^@[:space:]:,]+$ ]] && REC[$r:email]=$v || _imp_err "$r" "e-mail '${REC[$r:email]}' is not valid"
    fi
    if [[ -n ${REC[$r:expire]+x} ]]; then imp_date "${REC[$r:expire]}" && REC[$r:expire]=$REPLY || _imp_err "$r" "$VAL_ERR"; fi
    if [[ -n ${REC[$r:shell]:-} ]]; then val_shell "${REC[$r:shell]}" && REC[$r:shell]=$REPLY || _imp_err "$r" "$VAL_ERR"; fi
    if [[ -n ${REC[$r:home]:-} ]]; then val_path "${REC[$r:home]}" && REC[$r:home]=$REPLY || _imp_err "$r" "$VAL_ERR"; fi
    if [[ -n ${REC[$r:password_hash]:-} ]]; then val_hash "${REC[$r:password_hash]}" || _imp_err "$r" "$VAL_ERR"; fi
    if [[ -n ${REC[$r:password]:-} && ${REC[$r:password],,} != none ]] && ! $IMP_ALLOW_PLAIN; then
        _imp_err "$r" "the file contains a plain-text password; UMC refuses those by default (remove the column: temporary passwords are generated, or pass --allow-plaintext)"
    fi
    if [[ -n ${REC[$r:sudo]:-} ]]; then
        case ${REC[$r:sudo],,} in
            yes|true|1|full|all) REC[$r:sudo]=full ;; nopasswd) REC[$r:sudo]=nopasswd ;;
            no|false|0|none) REC[$r:sudo]=none ;; *) _imp_err "$r" "sudo '${REC[$r:sudo]}' must be full, nopasswd or none" ;;
        esac
    fi
    if [[ -n ${REC[$r:role]:-} ]]; then
        REC[$r:role]=${REC[$r:role],,}
        [[ -f $ETC/umc/roles.d/${REC[$r:role]}.conf ]] || _imp_err "$r" "role '${REC[$r:role]}' is not defined in /etc/umc/roles.d/"
    fi
    # --- access rules (department/title -> role/groups)
    for rule in "${!RULE_ATTR[@]}"; do
        a=${RULE_ATTR[rule]}
        v=${REC[$r:$a]:-}; v=${v,,}
        # shellcheck disable=SC2053  # glob match is intended
        [[ -n $v && $v == ${RULE_GLOB[rule]} ]] || continue
        k=${RULE_ACT[rule]%%=*} v=${RULE_ACT[rule]#*=}
        case $k in
            role)   [[ -n ${REC[$r:role]:-} ]] || REC[$r:role]=$v ;;
            groups) REC[$r:groups]=${REC[$r:groups]:+${REC[$r:groups]};}$v ;;
            shell)  [[ -n ${REC[$r:shell]:-} ]] || REC[$r:shell]=$v ;;
            sudo)   [[ -n ${REC[$r:sudo]:-} ]] || REC[$r:sudo]=$v ;;
        esac
        REC[$r:rules]+="${REC[$r:rules]:+, }${RULE_ATTR[rule]}=${RULE_GLOB[rule]}"
    done
    # --- groups: any of ; | , and whitespace separate names
    if [[ -n ${REC[$r:groups]:-} ]]; then
        v=${REC[$r:groups]//[;|,]/ }
        list=()
        for g in $v; do
            val_name "$g" group || { _imp_err "$r" "group '$g': $VAL_ERR (map HR group names to Linux groups in /etc/umc/rules.conf)"; continue; }
            [[ " ${list[*]} " == *" $g "* ]] || list+=("$g")
        done
        REC[$r:groups]="${list[*]}"
    fi
    # --- SSH keys (several per cell: separated by line breaks or ';')
    if [[ -n ${REC[$r:ssh_key]:-} ]]; then
        v=${REC[$r:ssh_key]//$'\177'/;}
        keys=()
        while [[ -n $v ]]; do
            key=${v%%;*}
            if [[ $v == *\;* ]]; then v=${v#*;}; else v=""; fi
            _trim "$key"; [[ -z $REPLY ]] && continue
            if val_sshkey "$REPLY"; then keys+=("$REPLY"); else _imp_err "$r" "SSH key: $VAL_ERR"; fi
        done
        join_by $'\n' "${keys[@]}"; REC[$r:ssh_key]=$REPLY
    fi
    # --- control characters anywhere are refused
    for k in username first_name last_name full_name comment department title phone location external_id; do
        [[ ${REC[$r:$k]:-} == *[$'\x01'-$'\x1f'$'\x7f']* ]] && _imp_err "$r" "$k contains line breaks or control characters"
    done
    # --- the user name: explicit, else from the e-mail, else from the name
    split_tabs "$2"
    f=${T[0]:-} l=${T[1]:-} full=${T[2]:-} el=${T[3]:-}
    if [[ -n ${REC[$r:username]:-} ]]; then
        v=${REC[$r:username]}
        [[ $v != "${v,,}" ]] && IMP_NOTES+=("user names were converted to lower case (e.g. '$v')") && v=${v,,}
        if val_name "$v" user; then REC[$r:username]=$v REC[$r:how]=file; else _imp_err "$r" "$VAL_ERR"; fi
    else
        v="" REC[$r:how]=""
        if [[ -n $el && $el != *\?* ]]; then _uname_from "${el%%+*}"; v=$REPLY REC[$r:how]="from e-mail"; fi
        if [[ -z $v ]]; then
            [[ -z $f && -z $l && -n $full ]] && { f=${full%% *}; l=${full##* }; [[ $f == "$l" ]] && l=""; }
            if [[ $f$l == *\?* ]]; then
                _imp_err "$r" "the name '${REC[$r:first_name]:-}${REC[$r:last_name]:+ ${REC[$r:last_name]}}${REC[$r:full_name]:-}' cannot be transliterated to ASCII; add a user name for this person"
            elif [[ -n $f ]]; then
                case ${CFG[username_pattern]} in
                    first.last) _uname_from "$f"; v=$REPLY; _uname_from "$l"; v+=${REPLY:+.$REPLY} ;;
                    first_last) _uname_from "$f"; v=$REPLY; _uname_from "$l"; v+=${REPLY:+_$REPLY} ;;
                    last.first) _uname_from "$l"; v=$REPLY; _uname_from "$f"; v=${v:+$v.}$REPLY ;;
                    flast)      _uname_from "$f"; v=${REPLY:0:1}; _uname_from "$l"; v+=$REPLY ;;
                    firstl)     _uname_from "$f"; v=$REPLY; _uname_from "$l"; v+=${REPLY:0:1} ;;
                    first)      _uname_from "$f"; v=$REPLY ;;
                esac
                REC[$r:how]="from name (${CFG[username_pattern]})"
            fi
        fi
        if [[ -n $v ]] && val_name "$v" user; then REC[$r:username]=$v IMP_DERIVED=$((IMP_DERIVED + 1))
        elif [[ -n $v ]]; then _imp_err "$r" "derived user name '$v' is not valid ($VAL_ERR); add a user name for this person"
        elif [[ ${REC[$r:state]} != invalid ]] && [[ -z $f ]]; then _imp_err "$r" "no user name, e-mail or name to derive one from"
        fi
    fi
    # --- GECOS: "Full Name,Room,Work phone,Home phone,Other" (standard sub-fields)
    if [[ -n ${REC[$r:comment]:-} ]]; then
        gecos=${REC[$r:comment]}
    else
        full=${REC[$r:full_name]:-}
        [[ -z $full ]] && full="${REC[$r:first_name]:-}${REC[$r:last_name]:+ ${REC[$r:last_name]}}"
        loc=${REC[$r:location]:-} phone=${REC[$r:phone]:-} v=${REC[$r:email]:-${REC[$r:external_id]:-}}
        gecos="${full//,/ },${loc//,/ },${phone//,/ },,${v//,/ }"
        while [[ $gecos == *, ]]; do gecos=${gecos%,}; done
    fi
    gecos=${gecos//:/ }
    val_gecos "$gecos" && REC[$r:gecos]=$gecos || _imp_err "$r" "$VAL_ERR"
}

# Two different people in one file must not collapse into one account.
_imp_dedupe() {
    local r n
    declare -A seen_name=() seen_ext=() seen_mail=()
    for ((r = 0; r < IMP_COUNT; r++)); do
        n=${REC[$r:username]:-}
        [[ -n ${REC[$r:external_id]:-} ]] && { [[ -n ${seen_ext[${REC[$r:external_id]}]+x} ]] && _imp_err "$r" "employee id '${REC[$r:external_id]}' appears twice (also ${IMP_ROW[${seen_ext[${REC[$r:external_id]}]}]})"; seen_ext[${REC[$r:external_id]}]=$r; }
        [[ -n ${REC[$r:email]:-} ]] && { [[ -n ${seen_mail[${REC[$r:email]}]+x} ]] && _imp_err "$r" "e-mail '${REC[$r:email]}' appears twice (also ${IMP_ROW[${seen_mail[${REC[$r:email]}]}]})"; seen_mail[${REC[$r:email]}]=$r; }
        [[ -n $n ]] || continue
        if [[ -n ${seen_name[$n]+x} ]]; then
            if [[ ${REC[$r:how]} == file ]]; then _imp_err "$r" "user name '$n' appears twice (also ${IMP_ROW[${seen_name[$n]}]})"
            else
                local i=2
                while [[ -n ${seen_name[$n$i]+x} ]]; do i=$((i + 1)); done
                REC[$r:username]=$n$i REC[$r:how]+=", renamed from $n (duplicate in file)"
                n=$n$i
            fi
        fi
        seen_name[$n]=$r
    done
}

# ------------------------------------------------------------------------------
# PLAN: compare every record with the system. Nothing is written here.
# ------------------------------------------------------------------------------
ACT=()                          # "kind|name|record"
declare -A UPD=() TARGET_OF=()  # UPD[name:what]=value
PLAN_LINES=() PLAN_FP="" PLAN_UNCHANGED=0

plan_build() {
    local r n st ext em g want have k
    ACT=() UPD=() TARGET_OF=() PLAN_LINES=() PLAN_UNCHANGED=0
    managed_load
    declare -A by_ext=() by_mail=() matched=()
    for n in "${!MANAGED[@]}"; do
        split_tabs "${MANAGED[$n]}"
        [[ -n ${T[2]:-} ]] && by_ext[${T[2]}]=$n
        [[ -n ${T[3]:-} ]] && by_mail[${T[3]}]=$n
    done
    # groups declared in a native manifest
    for g in "${!IMP_GRP[@]}"; do
        val_name "$g" group || { IMP_ERR+=("groups: $VAL_ERR"); continue; }
        if [[ ${IMP_GRP[$g]#*|} == absent ]]; then
            db_exists GR "$g" && ACT+=("gdelete|$g|")
        elif ! db_exists GR "$g"; then
            ACT+=("gcreate|$g|")
        fi
    done
    for ((r = 0; r < IMP_COUNT; r++)); do
        st=${REC[$r:state]:-present}
        [[ $st == invalid || -n ${REC[$r:bad]+x} ]] && continue
        n=${REC[$r:username]:-}
        [[ -n $n ]] || continue
        ext=${REC[$r:external_id]:-} em=${REC[$r:email]:-}
        # Identity: the same person keeps the same account, even if their name changed.
        local target=""
        if [[ -n $ext && -n ${by_ext[$ext]+x} ]]; then target=${by_ext[$ext]}
        elif [[ -n $em && -n ${by_mail[$em]+x} ]]; then target=${by_mail[$em]}
        elif db_exists PW "$n"; then
            if [[ -n ${MANAGED[$n]+x} ]]; then
                split_tabs "${MANAGED[$n]}"
                if [[ -n $ext && -n ${T[2]} && ${T[2]} != "$ext" ]] || [[ -n $em && -n ${T[3]} && ${T[3]} != "$em" ]]; then
                    if [[ ${REC[$r:how]} == file ]]; then
                        _imp_err "$r" "user name '$n' belongs to a different person (managed account with another id/e-mail)"; continue
                    fi
                    local i=2; while db_exists PW "$n$i" || [[ -n ${TARGET_OF[$n$i]+x} ]]; do i=$((i + 1)); done
                    REC[$r:how]+=", '$n' is taken by someone else"
                    n=$n$i REC[$r:username]=$n
                else
                    target=$n
                fi
            elif [[ ${REC[$r:how]} == file ]]; then
                target=$n                                      # explicit name: adopt the existing account
            else
                _imp_err "$r" "derived user name '$n' already exists (an account UMC did not create); if it is the same person add a username column, otherwise add a different one"
                continue
            fi
        fi
        if [[ -n $target && $target != "$n" && ${REC[$r:how]} != file ]]; then
            REC[$r:username]=$target n=$target
        fi
        TARGET_OF[$n]=$r
        [[ -n $target ]] && matched[$target]=1
        if [[ -z $target ]]; then
            case $st in
                present) ACT+=("create|$n|$r") ;;
                locked)  ACT+=("create|$n|$r"); UPD[$n:lock_after]=1 ;;
                absent)  PLAN_UNCHANGED=$((PLAN_UNCHANGED + 1)) ;;
            esac
            continue
        fi
        _plan_existing "$n" "$r" "$st"
    done
    if $IMP_PRUNE; then
        for n in "${!MANAGED[@]}"; do
            [[ -n ${matched[$n]+x} || -n ${TARGET_OF[$n]+x} ]] && continue
            db_exists PW "$n" || continue
            [[ -f $STATE/offboarded/$n ]] && continue
            ACT+=("offboard|$n|")
            UPD[$n:why]="not in the file (--prune)"
        done
    fi
    _plan_render
}

_plan_existing() {   # NAME RECORD STATE
    local n=$1 r=$2 st=$3 changed=false g want=() have=() add=() rem=() granted="" k
    user_load "$n"
    if [[ $st == absent ]]; then
        if [[ -f $STATE/offboarded/$n ]]; then PLAN_UNCHANGED=$((PLAN_UNCHANGED + 1)); else ACT+=("offboard|$n|$r"); UPD[$n:why]="status: absent"; fi
        return
    fi
    if [[ -f $STATE/offboarded/$n ]]; then
        kv_get "$STATE/offboarded/$n" source
        if [[ $REPLY == import ]]; then ACT+=("reinstate|$n|$r"); changed=true
        else _imp_err "$r" "'$n' was offboarded by hand; reinstate it explicitly (umc user reinstate $n)"; return; fi
    fi
    if [[ $st == locked ]]; then
        [[ $S_HASH == \!* && $S_EXPIRE == 1 ]] || { ACT+=("lock|$n|$r"); changed=true; }
    elif [[ -f $STATE/locks/$n ]]; then
        kv_get "$STATE/locks/$n" source
        [[ $REPLY == import ]] && { ACT+=("unlock|$n|$r"); changed=true; }
    fi
    # attribute drift
    [[ -n ${REC[$r:gecos]:-} && ${REC[$r:gecos]} != "$U_GECOS" ]] && UPD[$n:gecos]=${REC[$r:gecos]}
    [[ -n ${REC[$r:shell]:-} && ${REC[$r:shell]} != "$U_SHELL" ]] && UPD[$n:shell]=${REC[$r:shell]}
    if [[ -n ${REC[$r:expire]+x} ]]; then
        local cur=$S_EXPIRE
        [[ -f $STATE/onboarding/$n ]] && { kv_get "$STATE/onboarding/$n" intended_expire; cur=$REPLY; }
        [[ $st == locked || -f $STATE/locks/$n ]] && { kv_get "$STATE/locks/$n" prev_expire && cur=$REPLY; }
        [[ ${REC[$r:expire]} != "$cur" ]] && UPD[$n:expire]=${REC[$r:expire]}
    fi
    # groups: add what is wanted; remove only what UMC itself granted earlier
    _plan_want_groups "$r"; want=("${LIST[@]}")
    user_groups "$n"; have=("${GROUPS_OF[@]}")
    for g in "${want[@]}"; do [[ " ${have[*]} " == *" $g "* ]] || add+=("$g"); done
    managed_field "$n" 6; granted=${REPLY//,/ }
    for g in $granted; do
        [[ " ${want[*]} " == *" $g "* ]] && continue
        [[ " ${have[*]} " == *" $g "* ]] && rem+=("$g")
    done
    ((${#add[@]})) && UPD[$n:add_groups]="${add[*]}"
    ((${#rem[@]})) && UPD[$n:remove_groups]="${rem[*]}"
    [[ -n ${REC[$r:ssh_key]:-} ]] && UPD[$n:keys]=1
    for k in gecos shell expire add_groups remove_groups; do
        [[ -n ${UPD[$n:$k]+x} ]] && { ACT+=("update|$n|$r"); changed=true; break; }
    done
    $changed || PLAN_UNCHANGED=$((PLAN_UNCHANGED + 1))
    return 0
}

_plan_want_groups() {   # RECORD -> LIST[] (file groups + role groups + defaults)
    local r=$1 g role f line out=()
    for g in ${REC[$r:groups]:-}; do out+=("$g"); done
    role=${REC[$r:role]:-}
    if [[ -n $role && -f $ETC/umc/roles.d/$role.conf ]]; then
        while IFS= read -r line; do
            line=${line%%#*}
            [[ $line =~ ^[[:space:]]*groups[[:space:]]*=(.*)$ ]] || continue
            for g in ${BASH_REMATCH[1]//,/ }; do [[ " ${out[*]} " == *" $g "* ]] || out+=("$g"); done
        done < "$ETC/umc/roles.d/$role.conf"
    fi
    for g in ${CFG[default_groups]//,/ }; do [[ " ${out[*]} " == *" $g "* ]] || out+=("$g"); done
    LIST=("${out[@]}")
}

_plan_render() {
    local a kind n r line counts_add=0 counts_chg=0 counts_del=0 g missing=()
    declare -A needg=()
    for a in "${ACT[@]}"; do
        IFS='|' read -r kind n r <<< "$a"
        case $kind in
            gcreate) local gg=${IMP_GRP[$n]:-}; gg=${gg%%|*}
                     line="+ group $n${gg:+ gid=$gg}"; counts_add=$((counts_add + 1)) ;;
            gdelete) line="- group $n"; counts_del=$((counts_del + 1)) ;;
            create)
                _plan_want_groups "$r"
                for g in "${LIST[@]}"; do db_exists GR "$g" || [[ ${IMP_GRP[$g]:-} == *'|present' ]] || needg[$g]=1; done
                local pw="temporary password"
                [[ -n ${REC[$r:password_hash]:-} ]] && pw="password hash from file"
                [[ -n ${REC[$r:ssh_key]:-} && -z ${REC[$r:password_hash]:-} ]] && pw="SSH key only"
                [[ ${REC[$r:password]:-} == [Nn][Oo][Nn][Ee] ]] && pw="no password"
                join_by , "${LIST[@]}"
                local how=${REC[$r:how]:-}; [[ $how == file ]] && how=""
                line="+ user  $n${how:+ ($how)}  ${REPLY:+groups=$REPLY  }${REC[$r:role]:+role=${REC[$r:role]}  }$pw"
                [[ -n ${REC[$r:expire]:-} ]] && { days_to_date "${REC[$r:expire]}"; line+="  expires $REPLY"; }
                [[ -n ${UPD[$n:lock_after]+x} ]] && line+="  (created locked)"
                counts_add=$((counts_add + 1)) ;;
            update)
                line="~ user  $n "
                [[ -n ${UPD[$n:gecos]+x} ]] && line+=" comment='${UPD[$n:gecos]}'"
                [[ -n ${UPD[$n:shell]+x} ]] && line+=" shell=${UPD[$n:shell]}"
                if [[ -n ${UPD[$n:expire]+x} ]]; then
                    if [[ -n ${UPD[$n:expire]} ]]; then days_to_date "${UPD[$n:expire]}"; line+=" expires=$REPLY"; else line+=" expires=never"; fi
                fi
                [[ -n ${UPD[$n:add_groups]+x} ]] && { line+=" +groups=${UPD[$n:add_groups]// /,}"; for g in ${UPD[$n:add_groups]}; do db_exists GR "$g" || [[ ${IMP_GRP[$g]:-} == *'|present' ]] || needg[$g]=1; done; }
                [[ -n ${UPD[$n:remove_groups]+x} ]] && line+=" -groups=${UPD[$n:remove_groups]// /,}"
                counts_chg=$((counts_chg + 1)) ;;
            lock)      line="~ user  $n  lock (password + account expiry)"; counts_chg=$((counts_chg + 1)) ;;
            unlock)    line="~ user  $n  unlock (was locked by an earlier import)"; counts_chg=$((counts_chg + 1)) ;;
            reinstate) line="~ user  $n  reinstate (was offboarded by an earlier import)"; counts_chg=$((counts_chg + 1)) ;;
            offboard)  line="- user  $n  offboard (${UPD[$n:why]:-status: absent}; locked, privileges removed, home archived - nothing deleted)"; counts_del=$((counts_del + 1)) ;;
        esac
        PLAN_LINES+=("$line")
    done
    for g in "${!needg[@]}"; do
        if $IMP_CREATE_GROUPS; then
            ACT=("gcreate|$g|" "${ACT[@]}"); PLAN_LINES=("+ group $g (referenced by users; --create-groups)" "${PLAN_LINES[@]}"); counts_add=$((counts_add + 1))
        else
            missing+=("$g")
        fi
    done
    if ((${#missing[@]})); then
        IMP_ERR+=("groups that do not exist: ${missing[*]} (create them, declare them in the manifest, or pass --create-groups)")
        IMP_FATAL=true
    fi
    PLAN_COUNTS="$counts_add to add, $counts_chg to change, $counts_del to offboard"
    local IFS=$'\n'
    _sha256 "${PLAN_LINES[*]}"; PLAN_FP=$REPLY
}

plan_print() {
    local l e
    if $OPT_JSON; then
        json_arr "${PLAN_LINES[@]}"; jraw plan "$REPLY"
        json_arr "${IMP_ERR[@]}"; jraw errors "$REPLY"
        jraw unchanged "$PLAN_UNCHANGED"; jset fingerprint "$PLAN_FP"
        return 0
    fi
    say ""
    say "  ${C_BOLD}Plan for ${IMP_FILE##*/}${C_RESET}  ${C_DIM}($IMP_COUNT record(s), $IMP_FORMAT)${C_RESET}"
    for l in "${PLAN_LINES[@]}"; do
        case ${l:0:1} in
            +) say "    ${C_GREEN}$l${C_RESET}" ;; '~') say "    ${C_YELLOW}$l${C_RESET}" ;; -) say "    ${C_RED}$l${C_RESET}" ;; *) say "    $l" ;;
        esac
    done
    ((PLAN_UNCHANGED)) && say "    ${C_DIM}= $PLAN_UNCHANGED account(s) already as described${C_RESET}"
    if ((${#IMP_ERR[@]})); then
        say ""
        say "  ${C_RED}${C_BOLD}${#IMP_ERR[@]} problem(s):${C_RESET}"
        for e in "${IMP_ERR[@]}"; do say "    ${C_RED}✗${C_RESET} $e"; done
    fi
    say ""
    say "  Plan: $PLAN_COUNTS.  ${C_DIM}(nothing has been changed)${C_RESET}"
}

# ------------------------------------------------------------------------------
# Commands: import inspect, plan, apply
# ------------------------------------------------------------------------------
_imp_opts() {
    IMP_FILE="" IMP_DATEFMT="" IMP_ALLOW_PLAIN=false IMP_SKIP_INVALID=false IMP_CREATE_GROUPS=false
    IMP_PRUNE=false IMP_PROFILE="" IMP_SAVE_PROFILE="" IMP_CREDS_OUT="" IMP_OVR=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            -f|--file)        _need_val "$@"; IMP_FILE=$2; shift ;;
            --map)            _need_val "$@"; [[ $2 == *=* ]] || usage_err "--map expects 'Column=field'"
                              IMP_OVR[${2%%=*}]=${2#*=}; shift ;;
            --profile)        _need_val "$@"; val_name "$2" group || usage_err "invalid profile name"; IMP_PROFILE=$2; shift ;;
            --save-profile)   _need_val "$@"; val_name "$2" group || usage_err "invalid profile name"; IMP_SAVE_PROFILE=$2; shift ;;
            --date-format)    _need_val "$@"; [[ $2 == dmy || $2 == mdy ]] || usage_err "--date-format is dmy or mdy"; IMP_DATEFMT=$2; shift ;;
            --allow-plaintext) IMP_ALLOW_PLAIN=true ;;
            --skip-invalid)   IMP_SKIP_INVALID=true ;;
            --create-groups)  IMP_CREATE_GROUPS=true ;;
            --prune)          IMP_PRUNE=true ;;
            --credentials-out) _need_val "$@"; IMP_CREDS_OUT=$2; shift ;;
            -*)               usage_err "unknown option: $1" ;;
            *)                [[ -z $IMP_FILE ]] || usage_err "unexpected argument '$1'"; IMP_FILE=$1 ;;
        esac
        shift
    done
    [[ -n $IMP_FILE ]] || usage_err "which file? use: -f FILE"
}

cmd_import() {
    local sub=${1:-}; shift || true
    [[ $sub == inspect ]] || usage_err "usage: umc import inspect FILE [--map 'Column=field'] [--profile NAME] [--save-profile NAME]"
    _imp_opts "$@"
    cfg_resolve
    engine_read
    imp_read "$IMP_FILE"
    plan_build
    local i d
    case $IMP_DELIM in ',') d="comma" ;; ';') d="semicolon (European Excel)" ;; $'\t') d="tab" ;; '|') d="pipe" ;; *) d="-" ;; esac
    if $OPT_JSON; then
        local cols=()
        for i in "${!IMP_COLS[@]}"; do json_str "${IMP_COLS[i]}"; local a=$REPLY; json_str "${IMP_CANON[i]}"; cols+=("{\"column\":$a,\"field\":$REPLY}"); done
        jset format "$IMP_FORMAT"; jset encoding "$IMP_ENC"; jraw records "$IMP_COUNT"
        local IFS=,; jraw mapping "[${cols[*]}]"; unset IFS
        json_arr "${IMP_ERR[@]}"; jraw problems "$REPLY"; jemit; return 0
    fi
    say "  ${C_BOLD}${IMP_FILE##*/}${C_RESET}"
    say "    format     $IMP_FORMAT${IMP_PREFIX:+ (records under \"$IMP_PREFIX\")}$([[ $IMP_FORMAT == CSV ]] && echo " · delimiter: $d") · $IMP_ENC · $IMP_COUNT record(s)"
    say "    mapping"
    for i in "${!IMP_COLS[@]}"; do
        if [[ -n ${IMP_CANON[i]} ]]; then
            say "      $(printf '%-28s' "\"${IMP_COLS[i]}\"") -> ${C_GREEN}${IMP_CANON[i]}${C_RESET} ${C_DIM}(${IMP_HOW[i]})${C_RESET}"
        else
            say "      $(printf '%-28s' "\"${IMP_COLS[i]}\"") -> ${C_DIM}ignored${C_RESET}"
        fi
    done
    ((IMP_DERIVED)) && say "    usernames  $IMP_DERIVED derived (pattern '${CFG[username_pattern]}', or from the e-mail address)"
    ((${#RULE_ATTR[@]})) && say "    rules      ${#RULE_ATTR[@]} access rule(s) from /etc/umc/rules.conf"
    for i in "${IMP_NOTES[@]}"; do say "    note       $i"; done
    local shown=0
    for ((i = 0; i < IMP_COUNT && shown < 3; i++)); do
        [[ -n ${REC[$i:username]:-} ]] || continue
        say "    example    ${IMP_ROW[i]} -> ${REC[$i:username]}  \"${REC[$i:gecos]:-}\"${REC[$i:how]:+  (${REC[$i:how]})}"
        shown=$((shown + 1))
    done
    if ((${#IMP_ERR[@]})); then
        say "    ${C_RED}problems   ${#IMP_ERR[@]}${C_RESET}"
        for i in "${IMP_ERR[@]}"; do say "      ${C_RED}✗${C_RESET} $i"; done
        say "    next       fix those rows (or use --skip-invalid), then: umc plan -f ${IMP_FILE##*/}"
    else
        say "    next       umc plan -f ${IMP_FILE##*/}"
    fi
    if [[ -n $IMP_SAVE_PROFILE ]]; then _imp_profile_save; fi
}

_imp_profile_save() {
    local d=$ETC/umc/import-profiles f i tmp
    f=$d/$IMP_SAVE_PROFILE.map
    ( umask 022; mkdir -p -- "$d" ) || die "$E_FAIL" "cannot create $d"
    tmp=$(mktemp -- "$f.XXXXXX") || die "$E_FAIL" "cannot write $f"
    {
        printf '# UMC import profile %s (saved %(%Y-%m-%d)T from %s)\n' "$IMP_SAVE_PROFILE" -1 "${IMP_FILE##*/}"
        for i in "${!IMP_COLS[@]}"; do printf '%s=%s\n' "${IMP_COLS[i]}" "${IMP_CANON[i]:-ignore}"; done
    } > "$tmp" && chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$f" || die "$E_FAIL" "cannot write $f"
    ok "mapping saved as profile '$IMP_SAVE_PROFILE' (use it next time: --profile $IMP_SAVE_PROFILE)"
    audit_event import.profile "$IMP_SAVE_PROFILE" success "saved from ${IMP_FILE##*/}"
}

cmd_plan() {
    _imp_opts "$@"
    cfg_resolve
    engine_read
    imp_read "$IMP_FILE"
    plan_build
    plan_print
    jemit
    ((${#IMP_ERR[@]} == 0)) || exit "$E_INVALID"
}

cmd_apply() {
    _imp_opts "$@"
    cfg_resolve
    # 1. Plan without locks and show it.
    engine_read
    imp_read "$IMP_FILE"
    plan_build
    plan_print
    local fp=$PLAN_FP
    if ((${#IMP_ERR[@]})) && { ! $IMP_SKIP_INVALID || $IMP_FATAL; }; then
        die "$E_INVALID" "${#IMP_ERR[@]} problem(s) in ${IMP_FILE##*/}; imports are all-or-nothing" "nothing was changed" \
            "fix the rows listed above, or re-run with --skip-invalid to apply only the valid ones"
    fi
    ((${#ACT[@]})) || { no_change "the system already matches ${IMP_FILE##*/}"; return 0; }
    if ! $OPT_YES && ! $OPT_DRY_RUN; then
        [[ -t 0 ]] || die "$E_USAGE" "apply needs --yes when it is not run from a terminal" "nothing was changed"
        local ans
        read -r -p "  Apply this plan? [y/N] " ans
        [[ ${ans,,} == y || ${ans,,} == yes ]] || die "$E_USAGE" "not confirmed" "nothing was changed"
    fi
    # 2. Lock, re-plan, and make sure nothing changed in between (optimistic
    #    concurrency: the admin approved exactly this plan).
    engine_begin apply "${IMP_FILE##*/}"
    ID_READY=false MANAGED_READY=false
    imp_read "$IMP_FILE"
    plan_build
    [[ $PLAN_FP == "$fp" ]] || die "$E_CONFLICT" "the system changed between the plan and the apply" "nothing was changed" "run apply again to see the new plan"
    ((${#IMP_ERR[@]})) && _imp_write_rejects
    _apply_execute
}

_imp_write_rejects() {
    local f=${IMP_FILE%.*}.rejects.txt e
    { printf '# rows skipped by umc apply --skip-invalid (%(%Y-%m-%d %H:%M UTC)T)\n' -1; for e in "${IMP_ERR[@]}"; do printf '%s\n' "$e"; done; } > "$f" 2>/dev/null &&
        warn "${#IMP_ERR[@]} invalid row(s) skipped; see $f" || warn "${#IMP_ERR[@]} invalid row(s) skipped"
}

_apply_execute() {
    local a kind n r creates=() i now
    for a in "${ACT[@]}"; do [[ ${a%%|*} == create ]] && creates+=("$a"); done
    # IDs for every new user in one go (and one NSS round-trip).
    local need_ids=0
    for a in "${creates[@]}"; do IFS='|' read -r kind n r <<< "$a"; [[ -z ${REC[$r:uid]:-} ]] && need_ids=$((need_ids + 1)); done
    local pool=()
    if ((need_ids)); then id_alloc normal pair "$need_ids"; pool=("${ID_OUT[@]}"); fi
    # Passwords: generated temporary ones by default, hashed in parallel.
    local ngen=0
    for a in "${creates[@]}"; do
        IFS='|' read -r kind n r <<< "$a"
        _rec_pwmode "$r"; [[ $REPLY == generate ]] && ngen=$((ngen + 1))
    done
    local temps=() hashes=()
    if ((ngen)); then
        if $OPT_DRY_RUN; then for ((i = 0; i < ngen; i++)); do temps+=(dry-run); hashes+=('$6$dryrun$x'); done
        else
            pw_generate_many "$ngen"; temps=("${GEN[@]}"); PW_IN=("${GEN[@]}"); pw_hash_many; hashes=("${PW_OUT[@]}"); PW_IN=() GEN=()
        fi
    fi
    now_epoch; now=$REPLY
    for a in "${ACT[@]}"; do
        IFS='|' read -r kind n r <<< "$a"
        case $kind in
            gcreate) local gg=${IMP_GRP[$n]:-}; op_group_create "$n" "${gg%%|*}" 0 ;;
            gdelete) UO=(); op_group_delete "$n" ;;
        esac
    done
    local gi=0 pi=0
    for a in "${ACT[@]}"; do
        IFS='|' read -r kind n r <<< "$a"
        case $kind in
            create)
                UO=([name]=$n [gecos]=${REC[$r:gecos]:-})
                [[ -n ${REC[$r:uid]:-} ]] && UO[uid]=${REC[$r:uid]} || { UO[uid]=${pool[pi]}; UO[uid_prealloc]=1; pi=$((pi + 1)); }
                [[ -n ${REC[$r:shell]:-} ]] && UO[shell]=${REC[$r:shell]}
                [[ -n ${REC[$r:home]:-} ]] && UO[home]=${REC[$r:home]}
                [[ -n ${REC[$r:expire]+x} ]] && UO[expire]=${REC[$r:expire]}
                [[ -n ${REC[$r:role]:-} ]] && { UO[role]=${REC[$r:role]}; role_apply "${REC[$r:role]}"; }
                [[ -n ${REC[$r:sudo]:-} ]] && UO[sudo]=${REC[$r:sudo]}
                [[ -n ${REC[$r:ssh_key]:-} ]] && UO[keys]=${REC[$r:ssh_key]}
                _plan_want_groups "$r"; join_by , "${LIST[@]}"; UO[groups]=$REPLY
                [[ -n ${UO[shell]:-} ]] && { val_shell "${UO[shell]}" || die "$E_INVALID" "${IMP_ROW[r]}: $VAL_ERR" "nothing was changed"; UO[shell]=$REPLY; }
                _rec_pwmode "$r"
                case $REPLY in
                    generate) UO[hash]=${hashes[gi]} UO[force_change]=1
                              onboard_stage "$n" "${temps[gi]}" "${REC[$r:gecos]:-}"; UO[expire]=$REPLY
                              gi=$((gi + 1)) ;;
                    hash)     UO[hash]=${REC[$r:password_hash]}
                              [[ ${REC[$r:password_force_change]:-} == true ]] && UO[force_change]=1 ;;
                esac
                op_user_create
                [[ -n ${UPD[$n:lock_after]+x} ]] && op_user_lock "$n" import "created locked (status in ${IMP_FILE##*/})"
                managed_put "$n" "$CREATED_UID" "${REC[$r:external_id]:-}" "${REC[$r:email]:-}" "$now" import "${UO[groups]:-}" ;;
            update)
                UO=()
                [[ -n ${UPD[$n:gecos]+x} ]] && UO[gecos]=${UPD[$n:gecos]}
                [[ -n ${UPD[$n:shell]+x} ]] && UO[shell]=${UPD[$n:shell]}
                [[ -n ${UPD[$n:expire]+x} ]] && UO[expire]=${UPD[$n:expire]}
                [[ -n ${UPD[$n:add_groups]+x} ]] && UO[add_groups]=${UPD[$n:add_groups]// /,}
                [[ -n ${UPD[$n:remove_groups]+x} ]] && UO[remove_groups]=${UPD[$n:remove_groups]// /,}
                if [[ -f $STATE/onboarding/$n && -n ${UO[expire]+x} ]]; then
                    # still onboarding: keep the deadline backstop, remember the new end date
                    kv_get "$STATE/onboarding/$n" deadline; local dl=$REPLY
                    state_put "$STATE/onboarding/$n" "issued=$now" "deadline=$dl" "intended_expire=${UO[expire]}" "txn=$TXN_ID"
                    unset 'UO[expire]'
                fi
                op_user_modify "$n"
                _plan_want_groups "$r"
                managed_load
                local ext="" em="" cr=$now
                if [[ -n ${MANAGED[$n]+x} ]]; then split_tabs "${MANAGED[$n]}"; ext=${T[2]}; em=${T[3]}; cr=${T[4]}; fi
                join_by , "${LIST[@]}"
                managed_put "$n" "$U_UID" "${REC[$r:external_id]:-$ext}" "${REC[$r:email]:-$em}" "$cr" import "$REPLY" ;;
            lock)      op_user_lock "$n" import "status in ${IMP_FILE##*/}" ;;
            unlock)    op_user_unlock "$n" ;;
            reinstate) op_user_reinstate "$n" ;;
            offboard)
                UO=()
                op_user_offboard "$n" "${UPD[$n:why]:-status in ${IMP_FILE##*/}}"
                txn_xfile "$STATE/offboarded/$n"; printf 'source=import\n' >> "$REPLY" ;;
        esac
        if [[ $kind == update && -n ${UPD[$n:keys]+x} ]]; then
            user_load "$n"; KEYS_FOR[$n]=${REC[$r:ssh_key]}; TXN_EFFECTS+=("keys|$n|$U_UID|$U_GID|$U_HOME")
        fi
    done
    temps=() hashes=()
    TXN_SUMMARY="apply ${IMP_FILE##*/}: $PLAN_COUNTS"
    cred_write_pending
    engine_commit || return 0
    cred_finalize
    ok "applied ${IMP_FILE##*/}: $PLAN_COUNTS"
    ((${#CRED_ROWS[@]})) && info "${#CRED_ROWS[@]} temporary password(s) in ${CRED_FILE#"$R"} (root only); each must be changed within ${CFG[onboarding_deadline_hours]} h"
    if [[ -n $IMP_CREDS_OUT && ${#CRED_ROWS[@]} -gt 0 ]]; then
        if [[ $IMP_CREDS_OUT == - ]]; then
            printf 'username,temporary_password,must_change_by,full_name\n'; printf '%s\n' "${CRED_ROWS[@]}"
        else
            ( umask 077; { printf 'username,temporary_password,must_change_by,full_name\n'; printf '%s\n' "${CRED_ROWS[@]}"; } > "$IMP_CREDS_OUT" ) &&
                info "credentials also written to $IMP_CREDS_OUT (0600)"
        fi
    fi
    CRED_ROWS=()
    jraw created "${#creates[@]}"
    engine_finish "$PLAN_COUNTS"
}

_rec_pwmode() {   # RECORD -> REPLY generate|hash|none
    local r=$1
    if [[ -n ${REC[$r:password_hash]:-} ]]; then REPLY="hash"
    elif [[ ${REC[$r:password]:-} == [Nn][Oo][Nn][Ee] || ${REC[$r:password_generate]:-} == false ]]; then REPLY=none
    elif [[ -n ${REC[$r:ssh_key]:-} && -z ${REC[$r:password_generate]:-} ]]; then REPLY=none      # key-only: no secret to leak
    else REPLY=generate
    fi
}

# ==============================================================================
# §11 COMPLIANCE AUDIT, ACCESS-REVIEW EXPORT, PASSWORD POLICY
# ==============================================================================

# Each check: id | severity | title | CIS Benchmark control it maps to | fix.
# CIS titles are quoted rather than numbered because numbering differs per
# distro and benchmark version.
readonly AUDIT_CHECKS='AUD-01|critical|Only root has UID 0|Ensure root is the only UID 0 account|remove or re-number the extra UID-0 accounts
AUD-02|critical|No account has an empty password field|Ensure /etc/shadow password fields are not empty|lock them (umc user lock NAME) or set a password
AUD-03|high|All accounts use shadowed passwords|Ensure accounts in /etc/passwd use shadowed passwords|run pwconv, then set new passwords
AUD-04|high|No duplicate UIDs|Ensure no duplicate UIDs exist|give each account its own UID (umc user modify NAME --uid N)
AUD-05|high|No duplicate GIDs|Ensure no duplicate GIDs exist|give each group its own GID
AUD-06|high|No duplicate user names|Ensure no duplicate user names exist|remove the duplicate line with vipw
AUD-07|high|No duplicate group names|Ensure no duplicate group names exist|remove the duplicate line with vigr
AUD-08|high|passwd/shadow and group/gshadow agree|(consistency: pwck -r / grpck -r)|add the missing entries (pwconv / grpconv) or remove orphans
AUD-09|medium|Every primary group exists|Ensure all groups in /etc/passwd exist in /etc/group|create the group or change the primary group
AUD-10|high|Account files have safe owners and permissions|Ensure permissions on /etc/passwd, /etc/shadow, /etc/group, /etc/gshadow (and their - backups) are configured|chmod/chown them back (644 root:root; shadow files 640 root:shadow or 000 root:root)
AUD-11|medium|No weak password hashes (MD5/DES)|Ensure strong password hashing algorithm is configured|set new passwords; ENCRYPT_METHOD SHA512 or YESCRYPT in login.defs
AUD-12|medium|System accounts cannot log in|Ensure system accounts do not have a valid login shell|set their shell to /usr/sbin/nologin
AUD-13|high|Locked accounts cannot still log in with SSH keys|(UMC: a "!" lock does not stop public-key logins)|lock with umc user lock (adds account expiry) or remove the keys
AUD-14|medium|Home directories exist, belong to their users, are not group/world-writable|Ensure local interactive user home directories are configured|umc user create NAME re-creates a missing home; chmod go-w
AUD-15|medium|~/.ssh and authorized_keys are private|(sshd StrictModes silently ignores keys otherwise)|chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys; chown to the user
AUD-16|medium|No password-less sudo rules|Ensure users must provide password for privilege escalation|remove NOPASSWD (umc sudo grant NAME without --nopasswd)
AUD-17|medium|The shadow group is empty|Ensure shadow group is empty|remove its members
AUD-18|low|Human passwords expire|Ensure password expiration is 365 days or less|umc user aging NAME --max 365 (note: NIST SP 800-63B advises against forced periodic changes)
AUD-19|low|No stale account-file locks|(operational)|umc locks --clear-stale
AUD-20|high|No interrupted UMC transactions|(operational)|umc recover
AUD-21|info|Accounts expiring within 14 days|(operational)|extend with umc user expire NAME DATE if still needed
AUD-22|info|Onboarding: temporary passwords not yet changed|(operational)|run umc sweep (or install its timer)
AUD-23|info|Offboarded accounts past their retention period|(operational)|delete explicitly when ready: umc user delete NAME'

declare -A CHK_SEV=() CHK_TITLE=() CHK_CIS=() CHK_FIX=() CHK_HITS=()
CHK_ORDER=() FND=()
_aud_defs() {
    local id sev title cis fix
    while IFS='|' read -r id sev title cis fix; do
        CHK_ORDER+=("$id"); CHK_SEV[$id]=$sev CHK_TITLE[$id]=$title CHK_CIS[$id]=$cis CHK_FIX[$id]=$fix CHK_HITS[$id]=0
    done <<< "$AUDIT_CHECKS"
}
_hit() { FND+=("$1|$2|$3"); CHK_HITS[$1]=$((CHK_HITS[$1] + 1)); }   # ID ITEM DETAIL
_sev_rank() { case $1 in critical) REPLY=4 ;; high) REPLY=3 ;; medium) REPLY=2 ;; low) REPLY=1 ;; *) REPLY=0 ;; esac; }

aud_run() {
    local line n f uid gid sh home umin today k v o g m
    declare -A seen_uid=() seen_gid=() seen_un=() seen_gn=() gids=()
    defs_get UID_MIN 1000; umin=$REPLY
    today_days; today=$REPLY
    # --- passwd
    for line in "${PW_L[@]}"; do
        [[ $line == "$DEL" || $line != *:* || $line == [+-]* ]] && continue
        split_fields "$line"
        n=${F[0]} uid=${F[2]:-} gid=${F[3]:-} home=${F[5]:-} sh=${F[6]:-}
        [[ $uid == 0 && $n != root ]] && _hit AUD-01 "$n" "has UID 0 (full root privileges)"
        [[ ${F[1]:-} != x ]] && _hit AUD-03 "$n" "password field in /etc/passwd is '${F[1]:0:1}...' instead of 'x'"
        [[ -n ${seen_un[$n]+x} ]] && _hit AUD-06 "$n" "appears more than once in /etc/passwd"
        seen_un[$n]=1
        if [[ -n ${seen_uid[$uid]+x} ]]; then _hit AUD-04 "$n" "shares UID $uid with ${seen_uid[$uid]}"; else seen_uid[$uid]=$n; fi
        db_exists SP "$n" || _hit AUD-08 "$n" "is in /etc/passwd but not in /etc/shadow"
        if ((uid < umin && uid != 0)) && [[ $n != sync && $n != shutdown && $n != halt ]]; then
            case $sh in */nologin|*/false|'') ;; *) _hit AUD-12 "$n" "system account (uid $uid) has login shell $sh" ;; esac
        fi
    done
    # --- group / gshadow
    for line in "${GR_L[@]}"; do
        [[ $line == "$DEL" || $line != *:* || $line == [+-]* ]] && continue
        split_fields "$line"
        n=${F[0]} gid=${F[2]:-}
        gids[$gid]=1
        [[ -n ${seen_gn[$n]+x} ]] && _hit AUD-07 "$n" "appears more than once in /etc/group"
        seen_gn[$n]=1
        if [[ -n ${seen_gid[$gid]+x} ]]; then _hit AUD-05 "$n" "shares GID $gid with ${seen_gid[$gid]}"; else seen_gid[$gid]=$n; fi
        [[ ${DB_HAS[GS]} == 1 ]] && ! db_exists GS "$n" && _hit AUD-08 "$n" "group is not in /etc/gshadow"
        [[ $n == shadow && -n ${F[3]:-} ]] && _hit AUD-17 shadow "has members: ${F[3]}"
    done
    if [[ ${DB_HAS[GS]} == 1 ]]; then
        db_names GS
        for n in "${NAMES[@]}"; do db_exists GR "$n" || _hit AUD-08 "$n" "is in /etc/gshadow but not in /etc/group"; done
    fi
    db_fields GR shadow && { group_users_primary "${F[2]}"; [[ -n $REPLY ]] && _hit AUD-17 shadow "is the primary group of: $REPLY"; }
    # --- shadow
    db_names SP
    for n in "${NAMES[@]}"; do
        db_fields SP "$n"
        db_exists PW "$n" || _hit AUD-08 "$n" "is in /etc/shadow but not in /etc/passwd"
        local h=${F[1]} exp=${F[7]:-} max=${F[4]:-}
        [[ -z $h ]] && _hit AUD-02 "$n" "EMPTY password field: anyone can log in as $n where PAM allows nullok"
        local inner=${h##+(!)}
        case $inner in
            '$1$'*) _hit AUD-11 "$n" "MD5 hash" ;;
            *) [[ $inner =~ ^[./0-9A-Za-z]{13}$ ]] && _hit AUD-11 "$n" "DES hash" ;;
        esac
        user_load "$n" 2>/dev/null || continue
        local human=false
        (( U_UID >= umin && U_UID < 65534 )) && human=true
        # locked with "!" but not expired, and keys present -> SSH still works
        if [[ $h == \!* ]] && { [[ -z $exp ]] || ((exp > today)); }; then
            local ak=$R$U_HOME/.ssh/authorized_keys
            [[ -f $ak && ! -L $ak ]] && grep -qE '(^|[[:space:]])(ssh-|ecdsa-|sk-)' -- "$ak" 2>/dev/null &&
                _hit AUD-13 "$n" "password is locked but $U_HOME/.ssh/authorized_keys still allows key logins"
        fi
        $human || continue
        pw_state "$h"
        [[ $REPLY == set ]] && { [[ -z $max || $max -gt 365 ]] && _hit AUD-18 "$n" "password never expires (max ${max:-unset} days)"; }
        [[ -n $exp ]] && ((exp > today && exp - today <= 14)) && { days_to_date "$exp"; _hit AUD-21 "$n" "expires on $REPLY"; }
        case $U_SHELL in */nologin|*/false) continue ;; esac
        local hd=$R$U_HOME
        if [[ ! -d $hd ]]; then _hit AUD-14 "$n" "home $U_HOME does not exist"
        else
            local o m
            o=$(stat -c %u -- "$hd") m=$(stat -c %a -- "$hd")
            [[ $o != "$U_UID" ]] && _hit AUD-14 "$n" "home $U_HOME is owned by uid $o"
            (( 8#$m & 8#022 )) && _hit AUD-14 "$n" "home $U_HOME is writable by group/others (mode $m)"
            local sd=$hd/.ssh
            if [[ -d $sd ]]; then
                o=$(stat -c %u -- "$sd") m=$(stat -c %a -- "$sd")
                { [[ $o != "$U_UID" ]] || (( 8#$m & 8#077 )); } && _hit AUD-15 "$n" "$U_HOME/.ssh is mode $m owned by uid $o (expected 700, owned by $n)"
                if [[ -f $sd/authorized_keys ]]; then
                    o=$(stat -c %u -- "$sd/authorized_keys") m=$(stat -c %a -- "$sd/authorized_keys")
                    { [[ $o != "$U_UID" ]] || (( 8#$m & 8#022 )); } && _hit AUD-15 "$n" "authorized_keys is mode $m owned by uid $o"
                fi
            fi
        fi
    done
    # --- primary groups exist
    for line in "${PW_L[@]}"; do
        [[ $line == "$DEL" || $line != *:*:*:* || $line == [+-]* ]] && continue
        split_fields "$line"
        [[ -n ${gids[${F[3]}]+x} ]] || _hit AUD-09 "${F[0]}" "primary GID ${F[3]} does not exist in /etc/group"
    done
    # --- file permissions (including the - backups)
    for f in passwd group passwd- group-; do
        [[ -e $ETC/$f ]] || continue
        read -r o g m < <(stat -c '%u %g %a' -- "$ETC/$f")
        { [[ $o != 0 ]] || (( 8#$m & 8#022 )); } && _hit AUD-10 "/etc/$f" "mode $m owner uid $o (expected 644, root-owned, not writable by others)"
    done
    for f in shadow gshadow shadow- gshadow-; do
        [[ -e $ETC/$f ]] || continue
        read -r o g m < <(stat -c '%u %g %a' -- "$ETC/$f")
        local sg=""
        db_fields GR shadow && sg=${F[2]}
        { [[ $o != 0 ]] || (( 8#$m & 8#137 )) || [[ $g != 0 && $g != "$sg" ]]; } &&
            _hit AUD-10 "/etc/$f" "mode $m owner $o:$g (expected 640 root:shadow or 000 root:root)"
    done
    # --- sudo NOPASSWD
    local sf
    for sf in "$ETC/sudoers" "$ETC"/sudoers.d/*; do
        [[ -f $sf ]] || continue
        while IFS= read -r line; do
            [[ $line =~ ^[[:space:]]*# || $line =~ ^[[:space:]]*Defaults ]] && continue
            [[ $line == *NOPASSWD* ]] && _hit AUD-16 "${sf#"$R"}" "${line##+([[:space:]])}"
        done < "$sf" 2>/dev/null
    done
    # --- locks, journal, onboarding, offboarding
    for f in "$F_PASSWD" "$F_SHADOW" "$F_GROUP" "$F_GSHADOW"; do
        [[ -e $f.lock ]] || continue
        read -r v < "$f.lock" 2>/dev/null || v=""
        [[ $v =~ ^[0-9]+$ ]] && ! kill -0 "$v" 2>/dev/null && _hit AUD-19 "${f#"$R"}.lock" "held by pid $v, which no longer exists"
    done
    for f in "$TXN_DIR"/*/meta; do
        [[ -f $f ]] && grep -qx 'state=committing' -- "$f" && { k=${f%/meta}; _hit AUD-20 "${k##*/}" "transaction was interrupted"; }
    done
    local now; now_epoch; now=$REPLY
    for f in "$STATE"/onboarding/*; do
        [[ -f $f ]] || continue
        kv_get "$f" deadline
        if ((now >= REPLY)); then _hit AUD-22 "${f##*/}" "deadline PASSED, account not yet locked (is the sweep timer running?)"
        else printf -v v '%(%Y-%m-%d %H:%M UTC)T' "$REPLY"; _hit AUD-22 "${f##*/}" "must change the temporary password by $v"; fi
    done
    for f in "$STATE"/offboarded/*; do
        [[ -f $f ]] || continue
        kv_get "$f" delete_after
        [[ $REPLY =~ ^[0-9]+$ ]] && ((now >= REPLY)) && _hit AUD-23 "${f##*/}" "retention period is over"
    done
    return 0
}

cmd_audit() {
    local fail_on="" id sev e item detail
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --fail-on) _need_val "$@"; [[ $2 =~ ^(critical|high|medium|low|info)$ ]] || usage_err "--fail-on critical|high|medium|low|info"; fail_on=$2; shift ;;
            --format)  _need_val "$@"; [[ $2 == json ]] && OPT_JSON=true; shift ;;
            *) usage_err "unknown option for audit: $1" ;;
        esac
        shift
    done
    cfg_resolve
    engine_read
    _aud_defs
    aud_run
    declare -A cnt=([critical]=0 [high]=0 [medium]=0 [low]=0 [info]=0)
    for e in "${FND[@]}"; do id=${e%%|*}; sev=${CHK_SEV[$id]}; cnt[$sev]=$((cnt[$sev] + 1)); done
    if $OPT_JSON; then
        local fj=() cj=() a b c d g
        for e in "${FND[@]}"; do
            IFS='|' read -r id item detail <<< "$e"
            json_str "$id"; a=$REPLY; json_str "${CHK_SEV[$id]}"; b=$REPLY; json_str "${CHK_TITLE[$id]}"; c=$REPLY
            json_str "$item"; d=$REPLY; json_str "$detail"; g=$REPLY
            fj+=("{\"id\":$a,\"severity\":$b,\"check\":$c,\"item\":$d,\"detail\":$g}")
        done
        for id in "${CHK_ORDER[@]}"; do
            json_str "${CHK_TITLE[$id]}"; a=$REPLY; json_str "${CHK_CIS[$id]}"; b=$REPLY
            cj+=("{\"id\":\"$id\",\"severity\":\"${CHK_SEV[$id]}\",\"title\":$a,\"cis\":$b,\"status\":\"$( ((CHK_HITS[$id])) && echo fail || echo pass)\",\"findings\":${CHK_HITS[$id]}}")
        done
        local IFS=,
        jraw summary "{\"critical\":${cnt[critical]},\"high\":${cnt[high]},\"medium\":${cnt[medium]},\"low\":${cnt[low]},\"info\":${cnt[info]}}"
        jraw checks "[${cj[*]}]"; jraw findings "[${fj[*]}]"
        unset IFS
        jemit
    else
        os_info
        say "  ${C_BOLD}UMC compliance audit${C_RESET}  ${C_DIM}${OS[PRETTY_NAME]} · ${#CHK_ORDER[@]} checks · $(printf '%(%Y-%m-%d %H:%M UTC)T' -1)${C_RESET}"
        for id in "${CHK_ORDER[@]}"; do
            sev=${CHK_SEV[$id]}
            if ((CHK_HITS[$id] == 0)); then
                say "  ${C_GREEN}PASS${C_RESET}  $id  $(printf '%-8s' "$sev") ${CHK_TITLE[$id]}"
                continue
            fi
            local col=$C_RED; [[ $sev == medium ]] && col=$C_YELLOW; [[ $sev == low || $sev == info ]] && col=$C_CYAN
            say "  ${col}$( [[ $sev == info ]] && echo "NOTE" || echo "FAIL")${C_RESET}  $id  $(printf '%-8s' "$sev") ${CHK_TITLE[$id]}  ${C_DIM}(${CHK_HITS[$id]})${C_RESET}"
            for e in "${FND[@]}"; do
                IFS='|' read -r item detail detail2 <<< "${e#*|}"
                [[ ${e%%|*} == "$id" ]] || continue
                say "          - $item: ${detail}${detail2:+|$detail2}"
            done
            [[ ${CHK_CIS[$id]} == \(* ]] || say "          ${C_DIM}CIS: \"${CHK_CIS[$id]}\"${C_RESET}"
            say "          ${C_DIM}fix: ${CHK_FIX[$id]}${C_RESET}"
        done
        say ""
        say "  Summary: ${cnt[critical]} critical, ${cnt[high]} high, ${cnt[medium]} medium, ${cnt[low]} low, ${cnt[info]} info"
    fi
    audit_event audit "" success "${cnt[critical]}C ${cnt[high]}H ${cnt[medium]}M ${cnt[low]}L"
    if [[ -n $fail_on ]]; then
        _sev_rank "$fail_on"; local th=$REPLY
        for e in "${FND[@]}"; do
            _sev_rank "${CHK_SEV[${e%%|*}]}"
            ((REPLY >= th && REPLY > 0)) && exit "$E_AUDIT"
        done
    fi
    return 0
}

# --- access-review export ---------------------------------------------------------
# CSV cells are quoted (GECOS contains commas) and cells that a spreadsheet
# would execute as a formula (=, +, -, @) are neutralised (CWE-1236; v1: F-30).
_csv_cell() {
    local v=$1
    [[ $v == [=+@-]* || $v == $'\t'* || $v == $'\r'* ]] && v="'$v"
    if [[ $v == *[,\"$'\n']* || $v == \'* ]]; then v=${v//\"/\"\"}; v="\"$v\""; fi
    REPLY=$v
}
cmd_export() {
    local fmt=csv out="" scope=human n umin cells=() rows=() c
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --format) _need_val "$@"; [[ $2 == csv || $2 == json ]] || usage_err "--format csv|json"; fmt=$2; shift ;;
            --output|-o) _need_val "$@"; out=$2; shift ;;
            --all) scope=all ;;
            *) usage_err "unknown option for export: $1" ;;
        esac
        shift
    done
    $OPT_JSON && fmt=json
    cfg_resolve
    engine_read
    defs_get UID_MIN 1000; umin=$REPLY
    local ag=""; admin_group && ag=$REPLY
    local hdr=(username uid gid primary_group groups full_name shell home password_state last_password_change password_max_days account_expires locked sudo ssh_keys managed_by_umc source onboarding_deadline offboarded)
    db_names PW
    local tmp; tmp=$(mktemp) || die "$E_FAIL" "mktemp failed"; CLEANUP+=("$tmp")
    {
        if [[ $fmt == csv ]]; then local IFS=,; printf '%s\n' "${hdr[*]}"; unset IFS; else printf '[\n'; fi
        local first=true
        for n in "${NAMES[@]}"; do
            user_load "$n"
            [[ $scope == all ]] || { (( U_UID >= umin && U_UID < 65534 )) || continue; }
            pw_state "$S_HASH"; local pst=$REPLY last="" exp="never" lock=no sudo=no keys=0 pg src="" onb="" off="" managed=no
            [[ $S_LAST == 0 ]] && last="must change at next login"
            [[ -n $S_LAST && $S_LAST != 0 ]] && { days_to_date "$S_LAST"; last=$REPLY; }
            [[ -n $S_EXPIRE ]] && { days_to_date "$S_EXPIRE"; exp=$REPLY; }
            [[ $pst == locked ]] && lock="password"
            today_days; [[ -n $S_EXPIRE ]] && ((S_EXPIRE <= REPLY)) && lock+="${lock/no/}+expired" && lock=${lock#no}
            lock=${lock#+}
            user_groups "$n"
            sudo_file_for "$n"; [[ -f $REPLY ]] && { grep -q NOPASSWD -- "$REPLY" && sudo=nopasswd || sudo=yes; }
            [[ -n $ag && " ${GROUPS_OF[*]} " == *" $ag "* ]] && sudo="${sudo/no/}${sudo:+ }group:$ag" && sudo=${sudo# }
            [[ -f $R$U_HOME/.ssh/authorized_keys && ! -L $R$U_HOME/.ssh/authorized_keys ]] &&
                keys=$(grep -cE '(^|[[:space:]])(ssh-|ecdsa-|sk-)' -- "$R$U_HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
            group_by_gid "$U_GID" && pg=$REPLY || pg=$U_GID
            managed_field "$n" 5 && { managed=yes src=$REPLY; }
            [[ -f $STATE/onboarding/$n ]] && { kv_get "$STATE/onboarding/$n" deadline; printf -v onb '%(%Y-%m-%dT%H:%MZ)T' "$REPLY"; }
            [[ -f $STATE/offboarded/$n ]] && { kv_get "$STATE/offboarded/$n" ts; printf -v off '%(%Y-%m-%d)T' "$REPLY"; }
            local vals=("$n" "$U_UID" "$U_GID" "$pg" "${GROUPS_OF[*]}" "${U_GECOS%%,*}" "$U_SHELL" "$U_HOME" "$pst" "$last" "${S_MAX:-}" "$exp" "$lock" "$sudo" "$keys" "$managed" "$src" "$onb" "$off")
            if [[ $fmt == csv ]]; then
                cells=()
                for c in "${vals[@]}"; do _csv_cell "$c"; cells+=("$REPLY"); done
                local IFS=,; printf '%s\n' "${cells[*]}"; unset IFS
            else
                local i obj=""
                for i in "${!hdr[@]}"; do json_str "${vals[i]}"; obj+=${obj:+,}"\"${hdr[i]}\":$REPLY"; done
                $first || printf ',\n'; first=false
                printf '  {%s}' "$obj"
            fi
        done
        [[ $fmt == json ]] && printf '\n]\n'
    } > "$tmp"
    if [[ -n $out ]]; then
        ( umask 077; cat -- "$tmp" > "$out" ) || die "$E_FAIL" "cannot write $out"
        ok "access review written to $out (mode 0600: it lists every account)"
    else
        cat -- "$tmp"
    fi
    audit_event export "${out:-stdout}" success "$fmt"
}

# --- password policy -----------------------------------------------------------------
_kv_file_set() {   # STAGED KEY VALUE SEPARATOR(=|space)
    local f=$1 k=$2 v=$3 sep=$4
    awk -v k="$k" -v v="$v" -v sep="$sep" '
        BEGIN { done = 0 }
        {
            line = $0; t = line; sub(/^[[:space:]]+/, "", t)
            if (!done && t !~ /^#/) {
                split(t, w, /[[:space:]=]+/)
                if (w[1] == k) { print (sep == "=" ? k " = " v : k "\t" v); done = 1; next }
            }
            print line
        }
        END { if (!done) print (sep == "=" ? k " = " v : k "\t" v) }' "$f" > "$f.t" && mv -f -- "$f.t" "$f"
}

cmd_policy() {
    local sub=${1:-show}; shift || true
    cfg_resolve
    case $sub in
        show)
            engine_read
            pw_policy_load
            local pam="no"
            grep -qs pam_pwquality "$ETC"/pam.d/* && pam=yes
            say "  ${C_BOLD}Password policy${C_RESET}"
            say "    pwquality (enforced by PAM: $pam)  minlen=${POL[minlen]} minclass=${POL[minclass]} dcredit=${POL[dcredit]} ucredit=${POL[ucredit]} lcredit=${POL[lcredit]} ocredit=${POL[ocredit]} maxrepeat=${POL[maxrepeat]} usercheck=${POL[usercheck]}"
            defs_get PASS_MAX_DAYS 99999; local mx=$REPLY; defs_get PASS_MIN_DAYS 0; local mn=$REPLY; defs_get PASS_WARN_AGE 7; local wn=$REPLY
            say "    login.defs aging (new accounts)    PASS_MAX_DAYS=$mx PASS_MIN_DAYS=$mn PASS_WARN_AGE=$wn ENCRYPT_METHOD=${CFG[hash_method]}"
            defs_get PASS_MIN_LEN ""; [[ -n $REPLY ]] && say "    ${C_DIM}note: PASS_MIN_LEN=$REPLY is set in login.defs but PAM ignores it; length is minlen in pwquality.conf${C_RESET}"
            say "    UMC temporary passwords            ${CFG[onboarding_deadline_hours]} h to change · offboard retention ${CFG[offboard_retention_days]} days"
            jraw minlen "${POL[minlen]}"; jraw minclass "${POL[minclass]}"; jraw max_days "$mx"; jraw min_days "$mn"; jraw warn_days "$wn"; jemit ;;
        set)
            local minlen="" minclass="" maxd="" mind="" warnd="" existing=false
            _expand_eq "$@"; set -- "${ARGV[@]}"
            while (($#)); do
                case $1 in
                    --min-length)  _need_val "$@"; val_uint --min-length "$2" 8 256 || usage_err "$VAL_ERR"; minlen=$REPLY; shift ;;
                    --min-classes) _need_val "$@"; val_uint --min-classes "$2" 0 4 || usage_err "$VAL_ERR"; minclass=$REPLY; shift ;;
                    --max-days)    _need_val "$@"; val_uint --max-days "$2" 1 99999 || usage_err "$VAL_ERR"; maxd=$REPLY; shift ;;
                    --min-days)    _need_val "$@"; val_uint --min-days "$2" 0 99999 || usage_err "$VAL_ERR"; mind=$REPLY; shift ;;
                    --warn-days)   _need_val "$@"; val_uint --warn-days "$2" 0 99999 || usage_err "$VAL_ERR"; warnd=$REPLY; shift ;;
                    --apply-to-existing) existing=true ;;
                    *) usage_err "unknown option for policy set: $1" ;;
                esac
                shift
            done
            [[ -n $minlen$minclass$maxd$mind$warnd ]] || usage_err "usage: umc policy set [--min-length N] [--min-classes N] [--max-days N] [--min-days N] [--warn-days N] [--apply-to-existing]"
            engine_begin policy.set ""
            if [[ -n $minlen$minclass ]]; then
                [[ -d $ETC/security ]] || die "$E_FAIL" "$ETC/security does not exist (is PAM installed?)"
                txn_xfile "$ETC/security/pwquality.conf" 0644 0 0; local pq=$REPLY
                [[ -n $minlen ]]   && _kv_file_set "$pq" minlen "$minlen" =
                [[ -n $minclass ]] && _kv_file_set "$pq" minclass "$minclass" =
                grep -qs pam_pwquality "$ETC"/pam.d/* ||
                    warn "pam_pwquality is not in the PAM stack: 'passwd' will not enforce this (UMC does, for passwords it sets). Enable it with authselect (RHEL) or install libpam-pwquality (Debian)."
            fi
            if [[ -n $maxd$mind$warnd ]]; then
                txn_xfile "$ETC/login.defs"; local ld=$REPLY
                [[ -n $maxd ]]  && _kv_file_set "$ld" PASS_MAX_DAYS "$maxd" " "
                [[ -n $mind ]]  && _kv_file_set "$ld" PASS_MIN_DAYS "$mind" " "
                [[ -n $warnd ]] && _kv_file_set "$ld" PASS_WARN_AGE "$warnd" " "
                if $existing; then
                    # login.defs only affects accounts created later; this applies it to today's users too.
                    local n umin c=0; defs_get UID_MIN 1000; umin=$REPLY
                    db_names PW
                    for n in "${NAMES[@]}"; do
                        user_load "$n"; (( U_UID >= umin && U_UID < 65534 )) || continue
                        [[ -n $maxd ]] && S_MAX=$maxd; [[ -n $mind ]] && S_MIN=$mind; [[ -n $warnd ]] && S_WARN=$warnd
                        sp_stage "$n"; c=$((c + 1))
                    done
                    info "aging will also be applied to $c existing account(s)"
                else
                    info "login.defs aging applies to accounts created from now on (add --apply-to-existing for current users)"
                fi
            fi
            TXN_SUMMARY="password policy"
            engine_commit || { $OPT_DRY_RUN || no_change "the policy already has these values"; return 0; }
            ok "password policy updated"
            engine_finish "min-length=${minlen:--} min-classes=${minclass:--} max-days=${maxd:--}" ;;
        *) usage_err "usage: umc policy show | umc policy set [options]" ;;
    esac
}

# ==============================================================================
# §12 SAFETY-NET COMMANDS: engine helpers, history, rollback, recovery, locks,
#     audit-log verification, onboarding sweep, doctor
# ==============================================================================

# engine_begin ACTION TARGET - everything a mutating command needs, in order.
engine_begin() {
    AUDIT_ACTION=$1 AUDIT_TARGET=$2
    preflight
    lk_acquire_db
    txn_recover
    db_load
    ID_READY=false MANAGED_READY=false
    txn_begin "$1" "$2"
}
# engine_read - for read-only commands: no locks (every file is replaced by
# rename(), so each file read is a consistent snapshot).
engine_read() {
    preflight
    db_load
    local m
    for m in "$TXN_DIR"/*/meta; do
        [[ -f $m ]] && grep -qx 'state=committing' -- "$m" &&
            warn "interrupted transaction ${m%/meta}: the next write command (or 'umc recover') will restore it"
    done
    return 0
}

# engine_commit - commit, report dry runs and no-ops. Returns 1 if there was nothing to do.
engine_commit() {
    txn_commit
    if $OPT_DRY_RUN; then
        _effects_preview
        say ""
        say "  ${C_YELLOW}(dry run: nothing was written)${C_RESET}"
        jraw dry_run true
        return 1
    fi
    $TXN_CHANGED || return 1
    return 0
}
_effects_preview() {
    local e kind a b c d e5
    for e in "${TXN_EFFECTS[@]}"; do
        IFS='|' read -r kind a b c d e5 <<< "$e"
        case $kind in
            home)          say "    would create home directory $d (from /etc/skel${e5:+ + role '$e5'})" ;;
            keys)          say "    would install SSH key(s) for $a" ;;
            keys-disable)  say "    would disable the SSH keys of $a" ;;
            keys-enable)   say "    would re-enable the SSH keys of $a" ;;
            kill)          say "    would end all sessions and processes of $a" ;;
            archive-home)  say "    would archive $c" ;;
            home-remove)   say "    would remove $c (after archiving it)" ;;
            file-remove)   say "    would archive and remove $b" ;;
            move-home)     say "    would move $b to $c" ;;
            rechown)       say "    would re-own files of uid $b in $d to uid $c" ;;
        esac
    done
    return 0
}

# Follow-up steps that happen after the account change is committed. Each one
# is idempotent, so a failed step is fixed by simply re-running the command.
EFFECT_FAILS=0 EFFECT_LOG=()
effects_run() {
    local e kind a b c d e5 ks
    EFFECT_FAILS=0 EFFECT_LOG=()
    for e in "${TXN_EFFECTS[@]}"; do
        IFS='|' read -r kind a b c d e5 <<< "$e"
        EFFECT_ERR=""
        case $kind in
            home)
                if home_create "$a" "$b" "$c" "$d" "$e5"; then info "home directory $d is ready"; EFFECT_LOG+=("home:$d")
                else _effect_failed; fi ;;
            keys)
                mapfile -t ks <<< "${KEYS_FOR[$a]}"
                if keys_run add "$a" "$b" "$c" "$d" "${ks[@]}"; then info "$REPLY new SSH key(s) installed for $a"; EFFECT_LOG+=("keys:$a")
                else _effect_failed; fi ;;
            keys-disable)
                if [[ -d $R$d ]]; then
                    if keys_run disable "$a" "$b" "$c" "$d"; then [[ $REPLY == 1 ]] && info "SSH keys of $a disabled (kept in ~/.ssh/authorized_keys.umc-disabled)"
                    else _effect_failed; fi
                fi ;;
            keys-enable)
                if [[ -d $R$d ]]; then
                    if keys_run enable "$a" "$b" "$c" "$d"; then [[ $REPLY == 1 ]] && info "SSH keys of $a re-enabled"
                    else _effect_failed; fi
                fi ;;
            kill)
                if $LIVE; then
                    user_procs "$b"
                    if ((REPLY > 0)); then
                        if user_kill_sessions "$a" "$b"; then info "sessions and processes of $a ended"; else _effect_failed; fi
                    fi
                fi ;;
            archive-home)
                if archive_dir "$a" "$b" "$c" home; then [[ -n $REPLY ]] && { info "home archived to ${REPLY#"$R"}"; EFFECT_LOG+=("archive:${REPLY#"$R"}"); }
                else _effect_failed; fi ;;
            home-remove)
                if home_remove "$a" "$b" "$c"; then [[ -n $c ]] && info "home directory $c removed"
                else _effect_failed; fi ;;
            file-remove)
                if archive_file "$a" "$b" "$c"; then rm -f -- "$R$b" && info "$c $b archived and removed"
                else EFFECT_ERR="could not archive $b; left in place"; _effect_failed; fi ;;
            faillock)
                if $LIVE && cap_has faillock; then faillock --user "$a" --reset >/dev/null 2>&1 || true; fi ;;
            move-home)
                if home_move "$a" "$b" "$c"; then info "home moved from $b to $c"; else _effect_failed; fi ;;
            rechown)
                if [[ -d $R$d && ! -L $R$d ]] && find "$R$d" -xdev -uid "$b" -exec chown -h "$c" {} + ; then
                    info "files in $d re-owned from uid $b to $c"
                    warn "files of uid $b outside $d (e.g. /tmp, /var) were not changed"
                else _effect_failed; fi ;;
        esac
    done
    if [[ ${#EFFECT_LOG[@]} -gt 0 && -f $TXN_DIR/$TXN_ID/meta ]]; then
        local IFS=' '
        _txn_meta_set effects "${EFFECT_LOG[*]}"
    fi
    return 0
}
_effect_failed() { warn "${EFFECT_ERR:-a follow-up step failed}"; EFFECT_FAILS=$((EFFECT_FAILS + 1)); }

home_move() {   # NAME OLD NEW
    local src=$R$2 dst=$R$3
    EFFECT_ERR=""
    [[ -d $src && ! -L $src ]] || { EFFECT_ERR="$2 does not exist; nothing to move (create $3 by re-running: umc user create)"; return 1; }
    [[ ! -e $dst && ! -L $dst ]] || { EFFECT_ERR="$3 already exists; refusing to move $2 into it"; return 1; }
    ( umask 022; mkdir -p -- "${dst%/*}" ) || { EFFECT_ERR="cannot create ${3%/*}"; return 1; }
    mv -T -- "$src" "$dst" || { EFFECT_ERR="moving $2 to $3 failed"; return 1; }
    if cap_has selinux && cap_has restorecon; then restorecon -R -- "$dst" 2>/dev/null || true; fi
}

# engine_finish SUMMARY - follow-up steps, audit record, result output.
engine_finish() {
    effects_run
    audit_event "$AUDIT_ACTION" "$AUDIT_TARGET" success "$1"
    jset txn "$TXN_ID"
    if ((EFFECT_FAILS > 0)); then
        die "$E_FAIL" "$EFFECT_FAILS follow-up step(s) failed (see the warnings above)" "" \
            "fix the cause and re-run the same command; it only redoes what is missing"
    fi
    info "txn $TXN_ID  ·  undo with: umc rollback $TXN_ID"
    jemit
}
no_change() {   # MESSAGE
    same "$1"
    jraw changed false
    jemit
}

# --- credential slips (temporary passwords) ------------------------------------
CRED_ROWS=() CRED_FILE=""
cred_add() {   # NAME PASSWORD DEADLINE_EPOCH GECOS
    local dl q g=${4%%,*}
    printf -v dl '%(%Y-%m-%d %H:%M UTC)T' "$3"
    q=${g//\"/\"\"}
    CRED_ROWS+=("$1,$2,$dl,\"$q\"")
}
# Written BEFORE the commit (so a secret is never lost after accounts exist)
# and shredded if the commit does not happen.
cred_write_pending() {
    ((${#CRED_ROWS[@]})) || return 0
    $OPT_DRY_RUN && return 0
    local dir=$R${CFG[credentials_dir]}
    mkdir -p -m 0700 -- "$dir" && chmod 0700 -- "$dir" || die "$E_FAIL" "cannot create $dir"
    CRED_FILE=$dir/$TXN_ID.csv
    SHRED+=("$CRED_FILE.pending")
    { printf 'username,temporary_password,must_change_by,full_name\n'; printf '%s\n' "${CRED_ROWS[@]}"; } > "$CRED_FILE.pending" ||
        die "$E_FAIL" "cannot write the credential slip $CRED_FILE"
    sync -- "$CRED_FILE.pending" 2>/dev/null || true
}
cred_finalize() {
    [[ -n $CRED_FILE && -f $CRED_FILE.pending ]] || return 0
    mv -f -- "$CRED_FILE.pending" "$CRED_FILE" || die "$E_FAIL" "cannot finalise $CRED_FILE"
    SHRED=("${SHRED[@]/"$CRED_FILE.pending"}")
    if ! $LIVE && [[ $R != /tmp/* ]]; then
        warn "temporary passwords were written INSIDE the --root tree ($CRED_FILE); move them out before distributing that image"
    fi
    jset credentials_file "${CRED_FILE#"$R"}"
}
cred_rewrite_without() {   # NAME: remove a user's line from every slip (after activation/deadline)
    local dir=$R${CFG[credentials_dir]} f tmp
    for f in "$dir"/*.csv; do
        [[ -f $f ]] || continue
        grep -q "^$1," -- "$f" || continue
        tmp=$(mktemp -- "$f.XXXXXX") || continue
        grep -v "^$1," -- "$f" > "$tmp"
        if (( $(wc -l < "$tmp") <= 1 )); then
            rm -f -- "$tmp"
            if command -v shred >/dev/null 2>&1; then shred -u -- "$f"; else rm -f -- "$f"; fi
        else
            chmod 0600 -- "$tmp"; mv -f -- "$tmp" "$f"
        fi
    done
    return 0
}

# onboard_stage NAME PASSWORD GECOS -> stages the deadline record; REPLY = shadow backstop day
onboard_stage() {
    local now dl backstop intended
    now_epoch; now=$REPLY
    dl=$((now + CFG[onboarding_deadline_hours] * 3600))
    backstop=$((dl / 86400 + 1))         # the day AFTER the deadline: never cuts in early
    intended=${UO[expire]:-}
    if [[ -n $intended ]] && ((intended < backstop)); then backstop=$intended; fi
    state_put "$STATE/onboarding/$1" "issued=$now" "deadline=$dl" "intended_expire=$intended" "txn=$TXN_ID"
    cred_add "$1" "$2" "$dl" "$3"
    ONBOARD_DEADLINE=$dl
    REPLY=$backstop
}

# --- history / show / rollback / recover -------------------------------------------
_txn_list() {   # -> TXNS[] newest first
    local m d
    TXNS=()
    for m in "$TXN_DIR"/*/meta; do [[ -f $m ]] && TXNS=("${m%/meta}" "${TXNS[@]}"); done
    return 0
}
_txn_find() {   # ID|--last -> REPLY = dir
    local id=$1
    if [[ $id == --last || $id == last ]]; then
        _txn_list
        local d
        for d in "${TXNS[@]}"; do
            meta_get "$d/meta" state
            [[ $REPLY == committed ]] && { REPLY=$d; return 0; }
        done
        die "$E_NOTFOUND" "there is no committed transaction to undo" "nothing was changed"
    fi
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[0-9]+$ ]] || usage_err "'$id' is not a transaction id (see: umc history)"
    [[ -f $TXN_DIR/$id/meta ]] || die "$E_NOTFOUND" "no transaction '$id'" "nothing was changed" "list them with: umc history"
    REPLY=$TXN_DIR/$id
}

cmd_history() {
    local limit=20 d n=0 id ts actor action summary st out=()
    while (($#)); do
        case $1 in
            --limit) val_uint --limit "${2:-}" 1 100000 || usage_err "$VAL_ERR"; limit=$REPLY; shift 2 ;;
            *) usage_err "unknown option for history: $1" ;;
        esac
    done
    engine_read
    _txn_list
    $OPT_JSON || printf '  %s%-28s %-20s %-10s %-16s %-11s %s%s\n' "$C_BOLD" TXN TIME ACTOR ACTION STATE SUMMARY "$C_RESET"
    for d in "${TXNS[@]}"; do
        ((n++ < limit)) || break
        id=${d##*/}
        meta_get "$d/meta" ts; ts=$REPLY
        meta_get "$d/meta" actor; actor=$REPLY
        meta_get "$d/meta" action; action=$REPLY
        meta_get "$d/meta" summary; summary=$REPLY
        meta_get "$d/meta" state; st=$REPLY
        if $OPT_JSON; then
            local a b c e f g
            json_str "$id"; a=$REPLY; json_str "$ts"; b=$REPLY; json_str "$actor"; c=$REPLY
            json_str "$action"; e=$REPLY; json_str "$st"; f=$REPLY; json_str "$summary"; g=$REPLY
            out+=("{\"txn\":$a,\"ts\":$b,\"actor\":$c,\"action\":$e,\"state\":$f,\"summary\":$g}")
        else
            printf '  %-28s %-20s %-10s %-16s %-11s %s\n' "$id" "${ts/T/ }" "${actor:0:10}" "$action" "$st" "$summary"
        fi
    done
    if $OPT_JSON; then local IFS=,; jraw transactions "[${out[*]}]"; jemit; fi
}

cmd_show() {
    [[ $# -eq 1 ]] || usage_err "usage: umc show TXN"
    engine_read
    _txn_find "$1"
    local d=$REPLY n rel st k v
    WORK=$(mktemp -d) || die "$E_FAIL" "mktemp failed"
    CLEANUP+=("$WORK")
    say "  ${C_BOLD}Transaction ${d##*/}${C_RESET}"
    while IFS='=' read -r k v; do say "    $k: $v"; done < "$d/meta"
    while IFS=$'\t' read -r n rel st; do
        local a=$WORK/a b=$WORK/b T=x
        [[ $rel == /etc/shadow ]] && T=SP
        [[ $rel == /etc/gshadow ]] && T=GS
        if [[ -e $d/pre/$n.absent ]]; then : > "$a"; else awk -v T="$T" "$AWK_REDACT" "$d/pre/$n" > "$a"; fi
        if [[ -e $d/post/$n.absent ]]; then : > "$b"; else awk -v T="$T" "$AWK_REDACT" "$d/post/$n" > "$b"; fi
        _show_one_diff "$rel" "$a" "$b"
    done < "$d/files"
    jset txn "${d##*/}"; jemit
}

cmd_rollback() {
    local target="" force=false
    while (($#)); do
        case $1 in
            --force) force=true ;;
            --last)  target=--last ;;
            -*)      usage_err "unknown option for rollback: $1" ;;
            *)       target=$1 ;;
        esac
        shift
    done
    [[ -n $target ]] || usage_err "usage: umc rollback TXN | --last"
    engine_begin txn.rollback "$target"
    _txn_find "$target"
    local d=$REPLY id=${REPLY##*/} n rel st cur changed=()
    meta_get "$d/meta" state
    [[ $REPLY == committed ]] || die "$E_CONFLICT" "transaction $id is '$REPLY', only committed transactions can be rolled back" "nothing was changed"
    ( cd -- "$d" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1 ||
        die "$E_INTEGRITY" "the journal of $id is damaged; refusing to restore from it" "nothing was changed"
    # Refuse to clobber later changes: every file must still be exactly what
    # that transaction left behind (unless --force).
    while IFS=$'\t' read -r n rel st; do
        if [[ -e $d/post/$n.absent ]]; then [[ -e $R$rel ]] && changed+=("$rel"); continue; fi
        cmp -s -- "$d/post/$n" "$R$rel" || changed+=("$rel")
    done < "$d/files"
    if ((${#changed[@]})) && ! $force; then
        die "$E_CONFLICT" "these files changed after $id: ${changed[*]}" "nothing was changed" \
            "roll back the later transactions first (umc history), or add --force to discard those later changes too"
    fi
    TXN_SUMMARY="rollback of $id"
    TXN_RESTORE=true
    while IFS=$'\t' read -r n rel st; do
        # shellcheck disable=SC2086  # $st is "mode uid gid": three arguments
        txn_xfile "$R$rel" $st
        if [[ -e $d/pre/$n.absent ]]; then : > "$REPLY.delete"; else cp -- "$d/pre/$n" "$REPLY"; fi
    done < "$d/files"
    engine_commit || { no_change "nothing to roll back: the files already match the state before $id"; return 0; }
    _txn_meta_set rollback_of "$id"
    local save=$TXN_ID; TXN_ID=$id; _txn_meta_set state rolled-back-by-"$save"; TXN_ID=$save
    ok "rolled back $id: the account files are exactly as they were before it"
    meta_get "$d/meta" effects
    if [[ -n $REPLY ]]; then
        warn "not reverted (outside the account files): ${REPLY// /, }"
    fi
    engine_finish "rollback of $id"
}

cmd_recover() {
    engine_begin txn.recover ""
    txn_recover
    TXN_PHASE=none
    ok "journal checked; no transaction is left half-applied"
    jemit
}

# --- locks --------------------------------------------------------------------------
cmd_locks() {
    local clear=false f l pid who state rows=() stale=()
    [[ ${1:-} == --clear-stale ]] && clear=true
    preflight
    for f in "$F_PASSWD" "$F_SHADOW" "$F_GROUP" "$F_GSHADOW"; do
        l=$f.lock
        [[ -e $l ]] || continue
        pid=""; read -r pid < "$l" 2>/dev/null || true
        who=""
        if [[ $pid =~ ^[0-9]+$ ]] && { kill -0 "$pid" 2>/dev/null || [[ -d /proc/$pid ]]; }; then
            [[ -r /proc/$pid/comm ]] && read -r who < "/proc/$pid/comm"
            state="held by ${who:-pid} $pid"
        else
            state="STALE (pid ${pid:-?} is gone)"; stale+=("$l")
        fi
        rows+=("${l#"$R"}|$state")
    done
    if [[ -e $UMC_LOCK ]]; then
        if flock -n "$UMC_LOCK" true 2>/dev/null; then rows+=("${UMC_LOCK#"$R"}|free"); else rows+=("${UMC_LOCK#"$R"}|held (umc running)"); fi
    fi
    if $LIVE && [[ -e $ETC/.pwd.lock ]] && cap_has fcntl_lock; then
        if flock --fcntl -n "$ETC/.pwd.lock" true 2>/dev/null; then rows+=("/etc/.pwd.lock|free"); else rows+=("/etc/.pwd.lock|held (lckpwdf)"); fi
    fi
    local r
    if ((${#rows[@]} == 0)); then ok "no account-file locks are held"; fi
    for r in "${rows[@]}"; do say "  ${r%%|*}  ${C_DIM}->${C_RESET} ${r#*|}"; done
    if $clear && ((${#stale[@]})); then
        lk_umc
        for l in "${stale[@]}"; do
            pid=""; read -r pid < "$l" 2>/dev/null || true
            if [[ $pid =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then rm -f -- "$l" && ok "removed stale lock ${l#"$R"}"; fi
        done
        audit_event locks.clear-stale "" success "${#stale[@]} stale lock(s)"
    elif ((${#stale[@]})); then
        info "remove stale locks with: umc locks --clear-stale"
    fi
    local IFS=,; json_arr "${rows[@]}"; jraw locks "$REPLY"; jemit
}

# --- audit log --------------------------------------------------------------------
cmd_log() {
    local sub=${1:-show}; shift || true
    preflight
    case $sub in
        verify) _log_verify ;;
        show)
            local limit=20
            [[ ${1:-} == --limit ]] && { val_uint --limit "${2:-}" 1 100000 || usage_err "$VAL_ERR"; limit=$REPLY; }
            [[ -f $AUDIT_LOG ]] || { info "the audit log is empty"; return 0; }
            if $OPT_JSON; then tail -n "$limit" -- "$AUDIT_LOG"; return 0; fi
            tail -n "$limit" -- "$AUDIT_LOG" | awk '
                function f(k,   m) { if (match($0, "\"" k "\":\"[^\"]*\"")) { m = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", m); sub("\"$", "", m); return m } return "" }
                { printf "  %-20s %-10s %-18s %-16s %-11s %s\n", f("ts"), f("actor"), f("action"), f("target"), f("result"), f("detail") }' ;;
        *) usage_err "usage: umc log show [--limit N] | umc log verify" ;;
    esac
}
# Verifies the hash chain. Two processes in total, however long the log:
# split writes every line to its own file, sha256sum hashes them all.
_log_verify() {
    [[ -s $AUDIT_LOG ]] || { ok "the audit log is empty; nothing to verify"; jemit; return 0; }
    local tmp n=0 prev=0000000000000000000000000000000000000000000000000000000000000000 h f line want bad=""
    tmp=$(mktemp -d) || die "$E_FAIL" "mktemp failed"
    CLEANUP+=("$tmp")
    split -l 1 -a 8 -d -- "$AUDIT_LOG" "$tmp/l" || die "$E_FAIL" "cannot read $AUDIT_LOG"
    local hashes=()
    mapfile -t hashes < <(cd -- "$tmp" && sha256sum -- l*)
    while IFS= read -r line; do
        [[ $line =~ \"prev\":\"([0-9a-f]{64})\"\}$ ]] || { bad="line $((n + 1)) is not a valid audit record"; break; }
        want=${BASH_REMATCH[1]}
        [[ $want == "$prev" ]] || { bad="line $((n + 1)) does not chain to line $n (a line was edited, inserted or deleted)"; break; }
        h=${hashes[n]%% *}
        prev=$h
        n=$((n + 1))
    done < "$AUDIT_LOG"
    if [[ -n $bad ]]; then
        audit_event log.verify "" error "$bad"
        die "$E_INTEGRITY" "audit log verification FAILED: $bad" "nothing was changed" \
            "compare with the copy in journald: journalctl SYSLOG_IDENTIFIER=umc"
    fi
    ok "audit log intact: $n record(s), hash chain verified (head ${prev:0:16}...)"
    jraw records "$n"; jset head "$prev"; jemit
}

# --- onboarding / offboarding sweep --------------------------------------------------
# Run by a systemd timer (or cron). Exact to the minute; the shadow expiry
# date set at creation is the backstop if the timer never runs.
cmd_sweep() {
    if [[ ${1:-} == --install-timer ]]; then _sweep_install_timer; return; fi
    [[ $# -eq 0 ]] || usage_err "usage: umc sweep [--install-timer]"
    engine_begin sweep ""
    local f n dl intended now activated=() expired=() due=() of
    now_epoch; now=$REPLY
    for f in "$STATE"/onboarding/*; do
        [[ -f $f ]] || continue
        n=${f##*/}
        if ! user_load "$n"; then state_del "$f"; continue; fi
        kv_get "$f" deadline; dl=$REPLY
        kv_get "$f" intended_expire; intended=$REPLY
        if [[ $S_LAST != 0 ]]; then
            # The user changed the temporary password: activation complete.
            S_EXPIRE=$intended
            sp_stage "$n"; state_del "$f"; activated+=("$n")
        elif ((now >= dl)); then
            UO=(); op_user_lock "$n" onboarding-deadline "temporary password not changed by the deadline"
            state_del "$f"; expired+=("$n")
        fi
    done
    for of in "$STATE"/offboarded/*; do
        [[ -f $of ]] || continue
        kv_get "$of" delete_after
        [[ $REPLY =~ ^[0-9]+$ ]] && ((now >= REPLY)) && due+=("${of##*/}")
    done
    TXN_SUMMARY="sweep: ${#activated[@]} activated, ${#expired[@]} expired"
    if engine_commit; then
        for n in "${activated[@]}" "${expired[@]}"; do cred_rewrite_without "$n"; done
        ((${#activated[@]})) && ok "activated (password changed): ${activated[*]}"
        ((${#expired[@]})) && warn "locked, temporary password not changed in time: ${expired[*]} (reissue with: umc user passwd NAME --generate)"
    else
        ok "no onboarding deadlines to act on"
    fi
    ((${#due[@]})) && info "offboarded past their retention period (delete explicitly when ready): ${due[*]}"
    json_arr "${activated[@]}"; jraw activated "$REPLY"
    json_arr "${expired[@]}"; jraw expired "$REPLY"
    json_arr "${due[@]}"; jraw deletion_due "$REPLY"
    if $TXN_CHANGED; then engine_finish "${#activated[@]} activated, ${#expired[@]} locked"; else jemit; fi
}
_sweep_install_timer() {
    $LIVE || usage_err "--install-timer only works on the live system"
    cap_has systemd || die "$E_FAIL" "systemd is not running here" "nothing was changed" "use cron instead: */15 * * * * root /usr/local/sbin/umc sweep --quiet"
    local self
    self=$(readlink -f -- "$UMC_SELF")
    engine_begin sweep.install-timer ""
    txn_xfile /etc/systemd/system/umc-sweep.service 0644 0 0
    printf '[Unit]\nDescription=UMC onboarding/offboarding sweep\n\n[Service]\nType=oneshot\nExecStart=%s sweep --quiet\n' "$self" > "$REPLY"
    txn_xfile /etc/systemd/system/umc-sweep.timer 0644 0 0
    printf '[Unit]\nDescription=Run the UMC sweep every 15 minutes\n\n[Timer]\nOnCalendar=*:0/15\nPersistent=true\n\n[Install]\nWantedBy=timers.target\n' > "$REPLY"
    TXN_SUMMARY="install umc-sweep.timer"
    engine_commit || { no_change "umc-sweep.timer is already installed"; systemctl enable --now umc-sweep.timer >/dev/null 2>&1; return 0; }
    systemctl daemon-reload && systemctl enable --now umc-sweep.timer >/dev/null 2>&1 ||
        warn "could not enable the timer; run: systemctl enable --now umc-sweep.timer"
    ok "umc-sweep.timer installed and started (every 15 minutes)"
    engine_finish "timer installed"
}

# --- doctor ------------------------------------------------------------------------
cmd_doctor() {
    local c st name
    os_info
    _dr() { printf '  %-34s %s\n' "$1" "$2"; }
    _yn() { if cap_has "$1"; then REPLY="${C_GREEN}yes${C_RESET}"; else REPLY="${C_YELLOW}no${C_RESET}${2:+  ($2)}"; fi; }
    say "  ${C_BOLD}UMC $UMC_VERSION - host report${C_RESET}"
    _dr "operating system" "${OS[PRETTY_NAME]} (id=${OS[ID]}${OS[ID_LIKE]:+, like ${OS[ID_LIKE]}})"
    _dr "bash" "$BASH_VERSION"
    _dr "mode" "$($LIVE && echo "live system (/)" || echo "offline tree --root $R")"
    _dr "running as root" "$( ((EUID == 0)) && echo yes || echo "NO - most commands need root")"
    lckpwdf_method
    case $REPLY in
        flock)   _dr "lckpwdf interop (/etc/.pwd.lock)" "${C_GREEN}yes${C_RESET} (flock --fcntl)" ;;
        python3|perl) _dr "lckpwdf interop (/etc/.pwd.lock)" "${C_GREEN}yes${C_RESET} (fcntl via $REPLY; this util-linux has no flock --fcntl)" ;;
        *)       _dr "lckpwdf interop (/etc/.pwd.lock)" "${C_YELLOW}no${C_RESET}  (PAM password changes are not excluded; install python3 or util-linux >= 2.39)" ;;
    esac
    _yn openssl6 "cannot hash passwords";       _dr "openssl SHA-512 crypt" "$REPLY"
    pw_hash_method >/dev/null 2>&1;             _dr "password hash method" "${CFG[hash_method]} -> ${REPLY:-sha512}"
    _yn yescrypt;                               _dr "yescrypt (mkpasswd)" "$REPLY"
    _yn pwscore "native policy checks are used"; _dr "pwscore (pwquality policy)" "$REPLY"
    _yn selinux;                                _dr "SELinux labels maintained" "$REPLY"
    _yn journald "falls back to syslog/file";   _dr "journald structured logging" "$REPLY"
    _yn setpriv "SSH key management disabled";  _dr "setpriv (privilege dropping)" "$REPLY"
    _yn visudo "sudo rules cannot be managed";  _dr "visudo (sudoers validation)" "$REPLY"
    _yn ssh-keygen "keys checked by syntax only"; _dr "ssh-keygen (key validation)" "$REPLY"
    _yn iconv "UTF-16 / Windows-1252 imports unsupported"; _dr "iconv (import encodings)" "$REPLY"
    _yn sssd;                                   _dr "sssd cache flush" "$REPLY"
    _yn nscd;                                   _dr "nscd cache flush" "$REPLY"
    _dr "subuid/subgid files" "$( [[ -f $ETC/subuid ]] && echo present || echo absent)"
    [[ -r $F_GROUP ]] && _db_load_one GR
    admin_group >/dev/null 2>&1;                _dr "admin (sudo) group" "${REPLY:-none found}"
    _dr "nsswitch passwd" "$(grep -E '^passwd:' "$ETC/nsswitch.conf" 2>/dev/null | tr -s ' ' || echo unknown)"
    _dr "config file" "$([[ -f $CFG_FILE ]] && echo "$CFG_FILE" || echo "none (built-in defaults)")"
    _dr "state / journal" "$STATE"
    _dr "audit log" "$AUDIT_LOG"
    if [[ -e $UMC_SELF ]]; then
        st=$(stat -Lc '%u %a' -- "$UMC_SELF" 2>/dev/null)
        if [[ ${st%% *} != 0 ]] || (( 8#${st##* } & 8#022 )); then
            _dr "script integrity" "${C_YELLOW}WARNING${C_RESET}: $UMC_SELF is writable by a non-root user (anyone who can edit it can run code as root)"
            _dr "" "install it with: install -o root -g root -m 0755 umc.sh /usr/local/sbin/umc"
        else
            _dr "script integrity" "${C_GREEN}ok${C_RESET} (root-owned, not group/world-writable)"
        fi
    fi
    c=0; for name in "$TXN_DIR"/*/meta; do [[ -f $name ]] && grep -qx 'state=committing' "$name" && c=$((c + 1)); done
    _dr "interrupted transactions" "$c"
    jset os "${OS[PRETTY_NAME]}"; jset bash "$BASH_VERSION"; jemit
}

# ==============================================================================
# §13 COMMAND-LINE INTERFACE
#     Every capability is a plain command with documented exit codes, so UMC
#     can be driven by Ansible, cron, CI or an HR pipeline. The interactive
#     console (§14) is only a front-end that runs these same commands.
# ==============================================================================

# --opt=value -> --opt value (so every handler only needs one form)
ARGV=()
_expand_eq() {
    ARGV=()
    local a
    for a; do
        if [[ $a == --*=* ]]; then ARGV+=("${a%%=*}" "${a#*=}"); else ARGV+=("$a"); fi
    done
}
_need_val() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || usage_err "option $1 needs a value"; }

# @FILE reads keys from a file; '-' from stdin.
_collect_keys() {   # SPEC... -> KEYS_OUT (newline-separated, validated)
    local spec line out=() src
    for spec; do
        if [[ $spec == @* ]]; then
            src=${spec#@}
            [[ -r $src ]] || usage_err "cannot read key file $src"
            while IFS= read -r line || [[ -n $line ]]; do
                line=${line%$'\r'}
                [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
                val_sshkey "$line" || die "$E_INVALID" "$src: $VAL_ERR"
                out+=("$REPLY")
            done < "$src"
        else
            val_sshkey "$spec" || die "$E_INVALID" "$VAL_ERR"
            out+=("$REPLY")
        fi
    done
    local IFS=$'\n'
    KEYS_OUT="${out[*]}"
}

# Reads one secret. Interactive: asks twice, hidden. Piped: first line of stdin.
_read_secret() {   # PROMPT -> REPLY
    local a b
    if [[ -t 0 ]]; then
        IFS= read -rs -p "  $1: " a || usage_err "no password given"; printf '\n' >&2
        IFS= read -rs -p "  repeat: " b || usage_err "no password given"; printf '\n' >&2
        [[ $a == "$b" ]] || die "$E_INVALID" "the two passwords do not match" "nothing was changed"
    else
        IFS= read -r a || usage_err "--password-stdin: nothing on stdin"
        a=${a%$'\r'}
    fi
    REPLY=$a
}

# --- umc user ... ---------------------------------------------------------------
cmd_user() {
    local sub=${1:-}; shift || true
    case $sub in
        create)    cmd_user_create "$@" ;;
        modify)    cmd_user_modify "$@" ;;
        passwd)    cmd_user_passwd "$@" ;;
        lock)      cmd_user_lock "$@" ;;
        unlock)    cmd_user_unlock "$@" ;;
        expire)    cmd_user_expire "$@" ;;
        aging)     cmd_user_aging "$@" ;;
        key|keys)  cmd_user_key "$@" ;;
        offboard)  cmd_user_offboard "$@" ;;
        reinstate) cmd_user_reinstate "$@" ;;
        delete)    cmd_user_delete "$@" ;;
        show)      cmd_user_show "$@" ;;
        list)      cmd_user_list "$@" ;;
        ''|help|-h|--help) help_topic user ;;
        *) usage_err "unknown command: user $sub" "see: umc help user" ;;
    esac
}

cmd_user_create() {
    local name="" pwmode=none pw="" hash="" show_pw=false g
    UO=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --uid)      _need_val "$@"; val_uint --uid "$2" 1 4294967294 || usage_err "$VAL_ERR"; UO[uid]=$REPLY; shift ;;
            --group|-g) _need_val "$@"; UO[group]=$2; shift ;;
            --groups|-G) _need_val "$@"; UO[groups]=$2; shift ;;
            --comment|-c) [[ $# -ge 2 ]] || usage_err "--comment needs a value"; val_gecos "$2" || usage_err "$VAL_ERR"; UO[gecos]=$2; shift ;;
            --home|-d)  _need_val "$@"; val_path "$2" || usage_err "$VAL_ERR"; UO[home]=$REPLY; shift ;;
            --shell|-s) _need_val "$@"; UO[shell]=$2; shift ;;
            --expire|-e) _need_val "$@"; val_date "$2" || usage_err "$VAL_ERR"; UO[expire]=$REPLY; shift ;;
            --role)     _need_val "$@"; UO[role]=$2; shift ;;
            --system)   UO[system]=1 ;;
            --no-home)  UO[no_home]=1 ;;
            --ssh-key)  _need_val "$@"; UO[keyspec]+="$2"$'\n'; shift ;;
            --sudo)     UO[sudo]=full ;;
            --sudo-nopasswd) UO[sudo]=nopasswd ;;
            --password-stdin)    pwmode=stdin ;;
            --generate-password) pwmode=generate ;;
            --password-hash) _need_val "$@"; val_hash "$2" || usage_err "$VAL_ERR"; pwmode=hash hash=$2; shift ;;
            --force-change) UO[force_change]=1 ;;
            --show-password) show_pw=true ;;
            -h|--help) help_topic user; return 0 ;;
            -*) usage_err "unknown option for 'user create': $1" "see: umc help user" ;;
            *)  [[ -z $name ]] || usage_err "unexpected argument '$1'"; name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || usage_err "usage: umc user create NAME [options]" "see: umc help user"
    val_name "$name" user || die "$E_INVALID" "$VAL_ERR" "nothing was changed"
    UO[name]=$name
    cfg_resolve
    [[ -n ${UO[role]:-} ]] && role_apply "${UO[role]}"
    if [[ -n ${UO[shell]:-} ]]; then val_shell "${UO[shell]}" || usage_err "$VAL_ERR"; UO[shell]=$REPLY; fi
    uo_list groups
    for g in "${LIST[@]}"; do val_name "$g" group || usage_err "$VAL_ERR"; done
    if [[ -n ${UO[keyspec]:-} ]]; then
        local specs=(); mapfile -t specs <<< "${UO[keyspec]%$'\n'}"
        _collect_keys "${specs[@]}"; UO[keys]=$KEYS_OUT
    fi
    [[ $pwmode == stdin ]] && { _read_secret "password for $name"; pw=$REPLY; }

    engine_begin user.create "$name"
    if user_load "$name"; then _user_create_existing; return; fi
    [[ $pwmode == stdin ]] && { pw_check "$pw" "$name" || die "$E_INVALID" "$VAL_ERR" "nothing was changed"; }

    local temp=""
    case $pwmode in
        hash)     UO[hash]=$hash ;;
        stdin)    if $OPT_DRY_RUN; then UO[hash]='$6$dryrun$x'; else PW_IN=("$pw"); pw_hash_many; UO[hash]=${PW_OUT[0]}; fi ;;
        generate) UO[force_change]=1
                  if $OPT_DRY_RUN; then UO[hash]='$6$dryrun$x'; temp=dry-run
                  else pw_generate_many 1; temp=${GEN[0]}; PW_IN=("$temp"); pw_hash_many; UO[hash]=${PW_OUT[0]}; fi ;;
    esac
    pw="" PW_IN=()
    if [[ $pwmode == generate ]]; then onboard_stage "$name" "$temp" "${UO[gecos]:-}"; UO[expire]=$REPLY; fi
    op_user_create
    managed_put "$name" "$CREATED_UID" "" "" "$(printf '%(%s)T' -1)" cli "${UO[groups]:-}"
    TXN_SUMMARY="create user $name (uid $CREATED_UID)"
    cred_write_pending
    engine_commit || return 0
    cred_finalize
    ok "user $name created (uid $CREATED_UID, gid $CREATED_GID, home $CREATED_HOME, shell $CREATED_SHELL)"
    if [[ $pwmode == generate ]]; then
        local dl; printf -v dl '%(%Y-%m-%d %H:%M UTC)T' "$ONBOARD_DEADLINE"
        info "temporary password: ${show_pw:+}$($show_pw && echo "$temp" || echo "in ${CRED_FILE#"$R"} (root only)")"
        info "it must be changed at first login, by $dl; otherwise the account is locked (umc sweep)"
    elif [[ $pwmode == none ]]; then
        info "no password set: log in with an SSH key, or set one with: umc user passwd $name"
    fi
    temp=""
    jset user "$name"; jraw uid "$CREATED_UID"; jraw gid "$CREATED_GID"; jset home "$CREATED_HOME"; jset shell "$CREATED_SHELL"
    engine_finish "uid $CREATED_UID"
}

# Idempotency: asking for a user that already exists is fine if every
# attribute that was asked for already holds. Missing follow-up steps (home,
# keys) are completed; anything that differs is a conflict, never silently changed.
_user_create_existing() {
    local n=${UO[name]} diffs=() g
    [[ -n ${UO[uid]:-} && ${UO[uid]} != "$U_UID" ]] && diffs+=("uid is $U_UID, not ${UO[uid]}")
    [[ -n ${UO[shell]:-} && ${UO[shell]} != "$U_SHELL" ]] && diffs+=("shell is $U_SHELL, not ${UO[shell]}")
    [[ -n ${UO[gecos]+x} && ${UO[gecos]} != "$U_GECOS" ]] && diffs+=("comment is '$U_GECOS'")
    [[ -n ${UO[home]:-} && ${UO[home]} != "$U_HOME" ]] && diffs+=("home is $U_HOME, not ${UO[home]}")
    [[ -n ${UO[expire]+x} && ${UO[expire]} != "$S_EXPIRE" ]] && diffs+=("account expiry differs")
    user_groups "$n"
    uo_list groups
    for g in "${LIST[@]}"; do
        [[ " ${GROUPS_OF[*]} " == *" $g "* ]] || diffs+=("not a member of $g")
    done
    if ((${#diffs[@]})); then
        local IFS=';'
        die "$E_CONFLICT" "user '$n' already exists with different settings: ${diffs[*]}" "nothing was changed" \
            "use 'umc user modify $n ...' to change it"
    fi
    TXN_PHASE=none
    [[ ${UO[no_home]:-0} == 1 ]] || TXN_EFFECTS+=("home|$n|$U_UID|$U_GID|$U_HOME|${UO[role]:-}")
    if [[ -n ${UO[keys]:-} ]]; then KEYS_FOR[$n]=${UO[keys]}; TXN_EFFECTS+=("keys|$n|$U_UID|$U_GID|$U_HOME"); fi
    if $OPT_DRY_RUN; then same "user $n already exists with the requested settings (dry run)"; jemit; return 0; fi
    effects_run
    ((EFFECT_FAILS == 0)) || die "$E_FAIL" "user $n exists, but $EFFECT_FAILS follow-up step(s) failed" "nothing was changed in the account files"
    same "user $n already exists with the requested settings (nothing to change)"
    jset user "$n"; jraw changed false; jemit
}

# Roles: /etc/umc/roles.d/NAME.conf -> default groups, shell, sudo, expiry.
role_apply() {
    local r=$1 f=$ETC/umc/roles.d/$1.conf line k v n=0
    val_name "$r" group || usage_err "invalid role name '$r'"
    [[ -f $f ]] || die "$E_NOTFOUND" "role '$r' is not defined" "nothing was changed" "create $f (see examples/roles.d/)"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1)); line=${line%%#*}; [[ $line == *=* ]] || continue
        k=${line%%=*} v=${line#*=}
        k=${k//[[:space:]]/} v=${v##+([[:space:]])} v=${v%%+([[:space:]])}
        case $k in
            groups)      UO[groups]=${UO[groups]:+${UO[groups]},}$v ;;
            shell)       [[ -n ${UO[shell]:-} ]] || UO[shell]=$v ;;
            sudo)        [[ $v =~ ^(none|full|nopasswd)$ ]] || die "$E_INVALID" "$f:$n: sudo must be none, full or nopasswd"
                         [[ -n ${UO[sudo]:-} ]] || UO[sudo]=$v ;;
            expire_days) [[ $v =~ ^[0-9]+$ ]] || die "$E_INVALID" "$f:$n: expire_days must be a number"
                         [[ -n ${UO[expire]+x} ]] || { today_days; UO[expire]=$((REPLY + v)); } ;;
            *) die "$E_INVALID" "$f:$n: unknown role setting '$k' (groups, shell, sudo, expire_days)" ;;
        esac
    done < "$f"
}

cmd_user_modify() {
    local name=""
    UO=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --comment|-c) [[ $# -ge 2 ]] || usage_err "--comment needs a value"; val_gecos "$2" || usage_err "$VAL_ERR"; UO[gecos]=$2; shift ;;
            --shell|-s)   _need_val "$@"; UO[shell]=$2; shift ;;
            --home|-d)    _need_val "$@"; val_path "$2" || usage_err "$VAL_ERR"; UO[home]=$REPLY; shift ;;
            --move-home)  UO[move]=1 ;;
            --add-groups) _need_val "$@"; UO[add_groups]=$2; shift ;;
            --remove-groups) _need_val "$@"; UO[remove_groups]=$2; shift ;;
            --rename)     _need_val "$@"; val_name "$2" user || usage_err "$VAL_ERR"; UO[rename]=$2; shift ;;
            --uid)        _need_val "$@"; val_uint --uid "$2" 1 4294967294 || usage_err "$VAL_ERR"; UO[uid]=$REPLY; shift ;;
            --expire|-e)  _need_val "$@"; val_date "$2" || usage_err "$VAL_ERR"; UO[expire]=$REPLY; shift ;;
            --system)     UO[system]=1 ;;
            -h|--help)    help_topic user; return 0 ;;
            -*) usage_err "unknown option for 'user modify': $1" ;;
            *)  [[ -z $name ]] || usage_err "unexpected argument '$1'"; name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || usage_err "usage: umc user modify NAME [options]"
    ((${#UO[@]})) || usage_err "nothing to modify: give at least one option" "see: umc help user"
    cfg_resolve
    if [[ -n ${UO[shell]:-} ]]; then val_shell "${UO[shell]}" || usage_err "$VAL_ERR"; UO[shell]=$REPLY; fi
    engine_begin user.modify "$name"
    guard_account "$name" modify
    op_user_modify "$name"
    TXN_SUMMARY="modify user $name"
    engine_commit || { $OPT_DRY_RUN || no_change "user $name already has these settings"; return 0; }
    ok "user $name updated${UO[rename]:+ (now '${UO[rename]}')}"
    jset user "${UO[rename]:-$name}"
    engine_finish "modified"
}

cmd_user_passwd() {
    local name="" mode="" hash="" force=0 pw="" temp="" show_pw=false
    UO=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --password-stdin) mode=stdin ;;
            --generate|--generate-password) mode=generate ;;
            --hash|--password-hash) _need_val "$@"; val_hash "$2" || usage_err "$VAL_ERR"; mode=hash hash=$2; shift ;;
            --force-change) force=1 ;;
            --show-password) show_pw=true ;;
            -h|--help) help_topic user; return 0 ;;
            -*) usage_err "unknown option for 'user passwd': $1" ;;
            *)  [[ -z $name ]] || usage_err "unexpected argument '$1'"; name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || usage_err "usage: umc user passwd NAME [--password-stdin|--generate|--hash H] [--force-change]"
    [[ -n $mode ]] || mode=stdin
    cfg_resolve
    [[ $mode == stdin ]] && { _read_secret "new password for $name"; pw=$REPLY; }
    engine_begin user.passwd "$name"
    user_need "$name"
    [[ $name == root ]] || guard_account "$name" modify
    case $mode in
        stdin)    pw_check "$pw" "$name" || die "$E_INVALID" "$VAL_ERR" "nothing was changed"
                  if $OPT_DRY_RUN; then hash='$6$dryrun$x'; else PW_IN=("$pw"); pw_hash_many; hash=${PW_OUT[0]}; fi ;;
        generate) force=1
                  if $OPT_DRY_RUN; then hash='$6$dryrun$x' temp=dry-run
                  else pw_generate_many 1; temp=${GEN[0]}; PW_IN=("$temp"); pw_hash_many; hash=${PW_OUT[0]}; fi ;;
    esac
    pw="" PW_IN=()
    op_user_passwd "$name" "$hash" "$force"
    if [[ $mode == generate ]]; then
        user_load "$name"
        UO[expire]=$S_EXPIRE
        [[ -f $STATE/onboarding/$name ]] && { kv_get "$STATE/onboarding/$name" intended_expire; UO[expire]=$REPLY; }
        onboard_stage "$name" "$temp" "$U_GECOS"
        S_EXPIRE=$REPLY S_HASH=$hash S_LAST=0
        $LOCK_KEPT && S_HASH="!$hash"
        sp_stage "$name"
    fi
    TXN_SUMMARY="set password of $name"
    cred_write_pending
    engine_commit || return 0
    cred_finalize
    ok "password of $name updated$( ((force)) && echo " (must be changed at next login)")"
    $LOCK_KEPT && warn "$name is locked by UMC and stays locked; unlock it with: umc user unlock $name"
    if [[ $mode == generate ]]; then
        info "temporary password: $($show_pw && echo "$temp" || echo "in ${CRED_FILE#"$R"} (root only)")"
    fi
    temp=""
    jset user "$name"
    engine_finish "password set"
}

cmd_user_lock() {
    local name="" reason=""
    UO=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --reason) [[ $# -ge 2 ]] || usage_err "--reason needs a value"; reason=$2; shift ;;
            --force)  UO[force]=1 ;;
            --system) UO[system]=1 ;;
            -*) usage_err "unknown option for 'user lock': $1" ;;
            *)  name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || usage_err "usage: umc user lock NAME [--reason TEXT]"
    cfg_resolve
    engine_begin user.lock "$name"
    guard_account "$name" lock
    op_user_lock "$name" manual "$reason"
    if $ALREADY; then no_change "user $name is already locked (password and account expiry)"; return 0; fi
    TXN_SUMMARY="lock $name"
    engine_commit || return 0
    ok "user $name locked: password disabled AND account expired, so SSH keys are refused too"
    jset user "$name"
    engine_finish "locked${reason:+: $reason}"
}

cmd_user_unlock() {
    [[ $# -eq 1 && $1 != -* ]] || usage_err "usage: umc user unlock NAME"
    cfg_resolve
    engine_begin user.unlock "$1"
    UO=()
    guard_account "$1" modify
    op_user_unlock "$1"
    if $ALREADY; then no_change "user $1 is not locked"; return 0; fi
    TXN_SUMMARY="unlock $1"
    engine_commit || return 0
    ok "user $1 unlocked"
    jset user "$1"
    engine_finish "unlocked"
}

cmd_user_expire() {
    [[ $# -eq 2 ]] || usage_err "usage: umc user expire NAME YYYY-MM-DD|+DAYS|never"
    val_date "$2" || usage_err "$VAL_ERR"
    local days=$REPLY
    cfg_resolve
    engine_begin user.expire "$1"
    UO=()
    guard_account "$1" modify
    [[ $S_EXPIRE == "$days" ]] && { no_change "the account expiry of $1 is already set to $2"; return 0; }
    S_EXPIRE=$days
    sp_stage "$1"
    TXN_SUMMARY="set expiry of $1 to $2"
    engine_commit || return 0
    if [[ -n $days ]]; then days_to_date "$days"; ok "account $1 expires on $REPLY (UTC)"; else ok "account $1 never expires"; fi
    jset user "$1"
    engine_finish "expiry $2"
}

cmd_user_aging() {
    local name=""
    UO=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --min)      _need_val "$@"; val_uint --min "$2" 0 99999 || usage_err "$VAL_ERR"; UO[min]=$REPLY; shift ;;
            --max)      _need_val "$@"; val_uint --max "$2" 0 99999 || usage_err "$VAL_ERR"; UO[max]=$REPLY; shift ;;
            --warn)     _need_val "$@"; val_uint --warn "$2" 0 99999 || usage_err "$VAL_ERR"; UO[warn]=$REPLY; shift ;;
            --inactive) _need_val "$@"; if [[ $2 == -1 || $2 == never ]]; then UO[inactive]=""; else val_uint --inactive "$2" 0 99999 || usage_err "$VAL_ERR"; UO[inactive]=$REPLY; fi; shift ;;
            --force-change) UO[force_change]=1 ;;
            -*) usage_err "unknown option for 'user aging': $1" ;;
            *)  name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] && ((${#UO[@]})) || usage_err "usage: umc user aging NAME [--min N] [--max N] [--warn N] [--inactive N|never] [--force-change]"
    cfg_resolve
    engine_begin user.aging "$name"
    guard_account "$name" modify
    op_user_aging "$name"
    TXN_SUMMARY="password aging of $name"
    engine_commit || { $OPT_DRY_RUN || no_change "password aging of $name already matches"; return 0; }
    ok "password aging of $name updated"
    jset user "$name"
    engine_finish "aging updated"
}

cmd_user_key() {
    local sub=${1:-} name=${2:-}
    shift 2 2>/dev/null || usage_err "usage: umc user key add|remove|list NAME [KEY|@FILE ...]"
    cfg_resolve
    case $sub in
        list)
            engine_read
            user_need "$name"
            keys_run list "$name" "$U_UID" "$U_GID" "$U_HOME" || die "$E_FAIL" "$EFFECT_ERR"
            local k n=0 out=()
            while IFS= read -r k; do
                [[ -z $k || $k == \#* ]] && continue
                n=$((n + 1)); out+=("$k")
                say "  $n. ${k:0:40}...${k: -30}"
            done <<< "$REPLY"
            ((n)) || info "$name has no authorized SSH keys"
            json_arr "${out[@]}"; jraw keys "$REPLY"; jemit ;;
        add|remove)
            (($#)) || usage_err "usage: umc user key $sub NAME KEY|@FILE ..."
            _collect_keys "$@"
            local keys=$KEYS_OUT ks=()
            engine_begin "user.key.$sub" "$name"
            user_need "$name"
            TXN_PHASE=none
            mapfile -t ks <<< "$keys"
            if $OPT_DRY_RUN; then say "  (dry run) would $sub ${#ks[@]} key(s) for $name"; jemit; return 0; fi
            keys_run "$sub" "$name" "$U_UID" "$U_GID" "$U_HOME" "${ks[@]}" || die "$E_FAIL" "$EFFECT_ERR" "nothing was changed"
            if [[ $REPLY == 0 ]]; then no_change "nothing to $sub: the key(s) were already ${sub/add/present}${sub/remove/absent}"; return 0; fi
            ok "$REPLY key(s) ${sub}ed for $name"
            audit_event "user.key.$sub" "$name" success "$REPLY key(s)"
            jset user "$name"; jraw count "$REPLY"; jemit ;;
        *) usage_err "usage: umc user key add|remove|list NAME [KEY|@FILE ...]" ;;
    esac
}

cmd_user_offboard() {
    local name="" reason=""
    UO=()
    _expand_eq "$@"; set -- "${ARGV[@]}"
    while (($#)); do
        case $1 in
            --reason) [[ $# -ge 2 ]] || usage_err "--reason needs a value"; reason=$2; shift ;;
            --force)  UO[force]=1 ;;
            --system) UO[system]=1 ;;
            -*) usage_err "unknown option for 'user offboard': $1" ;;
            *)  name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || usage_err "usage: umc user offboard NAME [--reason TEXT]"
    cfg_resolve
    engine_begin user.offboard "$name"
    op_user_offboard "$name" "$reason"
    if $ALREADY; then no_change "user $name is already offboarded"; return 0; fi
    TXN_SUMMARY="offboard $name"
    engine_commit || return 0
    ok "user $name offboarded: locked + expired${OFFBOARD_REMOVED:+, removed from: $OFFBOARD_REMOVED}"
    info "nothing was deleted; undo with 'umc user reinstate $name', or delete for good after ${CFG[offboard_retention_days]} days: umc user delete $name"
    jset user "$name"
    engine_finish "offboarded${reason:+: $reason}"
}

cmd_user_reinstate() {
    [[ $# -eq 1 && $1 != -* ]] || usage_err "usage: umc user reinstate NAME"
    cfg_resolve
    engine_begin user.reinstate "$1"
    UO=()
    op_user_reinstate "$1"
    TXN_SUMMARY="reinstate $1"
    engine_commit || { no_change "user $1 already reinstated"; return 0; }
    ok "user $1 reinstated (unlocked, groups restored)"
    jset user "$1"
    engine_finish "reinstated"
}

cmd_user_delete() {
    local name=""
    UO=()
    while (($#)); do
        case $1 in
            --keep-home) UO[keep_home]=1 ;;
            --force)     UO[force]=1 ;;
            --system)    UO[system]=1 ;;
            -*) usage_err "unknown option for 'user delete': $1" ;;
            *)  name=$1 ;;
        esac
        shift
    done
    [[ -n $name ]] || usage_err "usage: umc user delete NAME [--keep-home] [--force]"
    cfg_resolve
    engine_begin user.delete "$name"
    user_need "$name"
    if ! $OPT_YES && ! $OPT_DRY_RUN && [[ -t 0 ]]; then
        local ans
        read -r -p "  Permanently delete user '$name'? Type the user name to confirm: " ans
        [[ $ans == "$name" ]] || die "$E_USAGE" "not confirmed" "nothing was changed"
    fi
    [[ -f $STATE/offboarded/$name ]] || warn "$name was not offboarded first (recommended: umc user offboard $name)"
    local archive=""
    op_user_delete "$name"
    # Archive and verify BEFORE the accounts change: if this fails, nothing happened.
    if [[ ${UO[keep_home]:-0} != 1 ]] && ! $OPT_DRY_RUN; then
        archive_dir "$name" "$U_UID" "$U_HOME" home || die "$E_FAIL" "$EFFECT_ERR" "nothing was changed" "free disk space in $ARCHIVE_DIR, or use --keep-home"
        archive=$REPLY
    fi
    TXN_SUMMARY="delete user $name (uid $U_UID)"
    engine_commit || return 0
    ok "user $name deleted${DELETED_UPG:+ (and its private group)}"
    [[ -n $archive ]] && info "home archived to ${archive#"$R"} (sha256 alongside)"
    jset user "$name"; jset archive "${archive#"$R"}"
    engine_finish "deleted${archive:+, archive ${archive#"$R"}}"
}

cmd_user_show() {
    [[ $# -eq 1 ]] || usage_err "usage: umc user show NAME"
    cfg_resolve
    engine_read
    user_need "$1"
    local n=$1 pwst lock="no" exp="never" last="" onb="" offb="" sudo="no" keys=0 g
    pw_state "$S_HASH"; pwst=$REPLY
    today_days; local today=$REPLY
    case $pwst in
        locked) lock="password locked" ;;
        none)   lock="no password set" ;;
        empty)  lock="NO - EMPTY PASSWORD (anyone can log in)" ;;
    esac
    if [[ -n $S_EXPIRE ]]; then
        days_to_date "$S_EXPIRE"; exp=$REPLY
        if ((S_EXPIRE <= today)); then
            exp+=" (EXPIRED)"
            if [[ $lock == no ]]; then lock="account expired"; else lock+=", account expired"; fi
        fi
    fi
    case $S_LAST in
        0) last="must change at next login" ;;
        "") last="never" ;;
        *) days_to_date "$S_LAST"; last=$REPLY ;;
    esac
    [[ -f $STATE/onboarding/$n ]] && { kv_get "$STATE/onboarding/$n" deadline; printf -v onb '%(%Y-%m-%d %H:%M UTC)T' "$REPLY"; }
    [[ -f $STATE/offboarded/$n ]] && { kv_get "$STATE/offboarded/$n" ts; printf -v offb '%(%Y-%m-%d)T' "$REPLY"; }
    sudo_file_for "$n"; [[ -f $REPLY ]] && sudo="yes (${REPLY#"$R"})"
    user_groups "$n"
    admin_group && [[ " ${GROUPS_OF[*]} " == *" $REPLY "* ]] && sudo="${sudo/no/}${sudo:+ }via group $REPLY"
    if [[ -f $R$U_HOME/.ssh/authorized_keys && ! -L $R$U_HOME/.ssh/authorized_keys ]]; then
        keys=$(grep -cE '(^|[[:space:]])(ssh-|ecdsa-|sk-)' -- "$R$U_HOME/.ssh/authorized_keys" 2>/dev/null || echo 0)
    fi
    group_by_gid "$U_GID" || REPLY=$U_GID
    local pg=$REPLY
    if $OPT_JSON; then
        jset user "$n"; jraw uid "$U_UID"; jraw gid "$U_GID"; jset primary_group "$pg"
        json_arr "${GROUPS_OF[@]}"; jraw groups "$REPLY"
        jset comment "$U_GECOS"; jset home "$U_HOME"; jset shell "$U_SHELL"
        jset password "$pwst"; jset locked "$lock"; jset expires "$exp"; jset password_changed "$last"
        jraw ssh_keys "$keys"; jset sudo "$sudo"; jset onboarding_deadline "$onb"; jset offboarded "$offb"
        jemit; return 0
    fi
    printf '  %s%s%s\n' "$C_BOLD" "$n" "$C_RESET"
    printf '    %-18s %s\n' uid/gid "$U_UID / $U_GID ($pg)" groups "${GROUPS_OF[*]:-(none)}" comment "${U_GECOS:-(none)}" \
        home "$U_HOME" shell "$U_SHELL" password "$pwst" locked "$lock" expires "$exp" "password changed" "$last" \
        "aging min/max/warn" "${S_MIN:-0}/${S_MAX:-99999}/${S_WARN:-7}" "ssh keys" "$keys" sudo "$sudo"
    [[ -n $onb ]]  && printf '    %-18s %s\n' onboarding "temporary password must be changed by $onb"
    [[ -n $offb ]] && printf '    %-18s %s\n' offboarded "$offb"
    managed_field "$n" 5 && printf '    %-18s %s\n' "managed by UMC" "yes (source: $REPLY)"
    if $LIVE && cap_has faillock; then
        local fl; fl=$(faillock --user "$n" 2>/dev/null | grep -c '^[0-9]' || true)
        [[ $fl -gt 0 ]] && printf '    %-18s %s\n' faillock "$fl recent failed login(s) recorded"
    fi
    return 0
}

cmd_user_list() {
    local scope=human n min out=()
    case ${1:-} in --system) scope=system ;; --all) scope=all ;; ''|--human) ;; *) usage_err "usage: umc user list [--human|--system|--all]" ;; esac
    cfg_resolve
    engine_read
    defs_get UID_MIN 1000; min=$REPLY
    db_names PW
    $OPT_JSON || printf '  %s%-20s %7s  %-24s %-12s %s%s\n' "$C_BOLD" USER UID HOME PASSWORD EXPIRES "$C_RESET"
    for n in "${NAMES[@]}"; do
        user_load "$n"
        case $scope in
            human)  (( U_UID >= min && U_UID < 65534 )) || continue ;;
            system) (( U_UID < min || U_UID >= 65534 )) || continue ;;
        esac
        pw_state "$S_HASH"; local st=$REPLY e="-"
        [[ -n $S_EXPIRE ]] && { days_to_date "$S_EXPIRE"; e=$REPLY; }
        if $OPT_JSON; then
            json_str "$n"; local a=$REPLY; json_str "$U_HOME"; local b=$REPLY
            out+=("{\"user\":$a,\"uid\":$U_UID,\"home\":$b,\"password\":\"$st\",\"expires\":\"$e\"}")
        else
            printf '  %-20s %7s  %-24s %-12s %s\n' "$n" "$U_UID" "$U_HOME" "$st" "$e"
        fi
    done
    if $OPT_JSON; then local IFS=,; jraw users "[${out[*]}]"; jemit; fi
}

# --- umc group ... ---------------------------------------------------------------
cmd_group() {
    local sub=${1:-}; shift || true
    cfg_resolve
    case $sub in
        create)
            local name="" gid="" sys=0
            _expand_eq "$@"; set -- "${ARGV[@]}"
            while (($#)); do
                case $1 in
                    --gid) _need_val "$@"; val_uint --gid "$2" 1 4294967294 || usage_err "$VAL_ERR"; gid=$REPLY; shift ;;
                    --system) sys=1 ;;
                    -*) usage_err "unknown option for 'group create': $1" ;;
                    *)  name=$1 ;;
                esac
                shift
            done
            [[ -n $name ]] || usage_err "usage: umc group create NAME [--gid N] [--system]"
            val_name "$name" group || die "$E_INVALID" "$VAL_ERR" "nothing was changed"
            engine_begin group.create "$name"
            if db_fields GR "$name"; then
                [[ -z $gid || ${F[2]} == "$gid" ]] || die "$E_CONFLICT" "group $name exists with GID ${F[2]}, not $gid" "nothing was changed"
                TXN_PHASE=none; no_change "group $name already exists (gid ${F[2]})"; return 0
            fi
            op_group_create "$name" "$gid" "$sys"
            TXN_SUMMARY="create group $name"
            engine_commit || return 0
            ok "group $name created (gid $CREATED_GID)"
            jset group "$name"; jraw gid "$CREATED_GID"
            engine_finish "gid $CREATED_GID" ;;
        delete)
            local name="" ; UO=()
            while (($#)); do case $1 in --force) UO[force]=1 ;; -*) usage_err "unknown option: $1" ;; *) name=$1 ;; esac; shift; done
            [[ -n $name ]] || usage_err "usage: umc group delete NAME [--force]"
            engine_begin group.delete "$name"
            db_exists GR "$name" || { TXN_PHASE=none; no_change "group $name does not exist"; return 0; }
            op_group_delete "$name"
            TXN_SUMMARY="delete group $name"
            engine_commit || return 0
            ok "group $name deleted"
            jset group "$name"
            engine_finish "deleted" ;;
        add-member|remove-member)
            local g=${1:-}; shift || true
            [[ -n $g && $# -ge 1 ]] || usage_err "usage: umc group $sub GROUP USER..."
            engine_begin "group.$sub" "$g"
            db_exists GR "$g" || die "$E_NOTFOUND" "group '$g' does not exist" "nothing was changed"
            local u
            for u; do
                if [[ $sub == add-member ]]; then
                    db_exists PW "$u" || nss_user_exists "$u" || die "$E_NOTFOUND" "user '$u' does not exist" "nothing was changed"
                    group_member_add "$g" "$u"
                else
                    group_member_del "$g" "$u"
                fi
            done
            TXN_SUMMARY="$sub $g: $*"
            engine_commit || { $OPT_DRY_RUN || no_change "membership of $g already as requested"; return 0; }
            ok "group $g: ${sub/-member/}ed $*"
            jset group "$g"
            engine_finish "$*" ;;
        show)
            [[ $# -eq 1 ]] || usage_err "usage: umc group show NAME"
            engine_read
            db_fields GR "$1" || die "$E_NOTFOUND" "group '$1' does not exist"
            local gid=${F[2]} mem=${F[3]} prim members=()
            group_users_primary "$gid"; prim=$REPLY
            if $OPT_JSON; then
                read -ra members <<< "${mem//,/ }"
                json_arr "${members[@]}"; jraw members "$REPLY"
                read -ra members <<< "$prim"
                json_arr "${members[@]}"; jraw primary_for "$REPLY"
                jset group "$1"; jraw gid "$gid"; jemit
            else
                printf '  %s%s%s (gid %s)\n    members:      %s\n    primary for:  %s\n' "$C_BOLD" "$1" "$C_RESET" "$gid" "${mem:-(none)}" "${prim:-(none)}"
            fi ;;
        list)
            engine_read
            local line min out=()
            defs_get GID_MIN 1000; min=$REPLY
            for line in "${GR_L[@]}"; do
                [[ $line == "$DEL" || $line != *:*:*:* ]] && continue
                split_fields "$line"
                [[ ${1:-} == --all ]] || { (( F[2] >= min && F[2] < 65534 )) || continue; }
                if $OPT_JSON; then json_str "${F[0]}"; out+=("{\"group\":$REPLY,\"gid\":${F[2]}}"); else printf '  %-24s %7s  %s\n' "${F[0]}" "${F[2]}" "${F[3]}"; fi
            done
            if $OPT_JSON; then local IFS=,; jraw groups "[${out[*]}]"; jemit; fi ;;
        ''|help|-h|--help) help_topic group ;;
        *) usage_err "unknown command: group $sub" "see: umc help group" ;;
    esac
}

# --- umc sudo ... ------------------------------------------------------------------
cmd_sudo() {
    local sub=${1:-}; shift || true
    cfg_resolve
    case $sub in
        grant|revoke)
            local who="" mode=full cmds="" via=false
            _expand_eq "$@"; set -- "${ARGV[@]}"
            while (($#)); do
                case $1 in
                    --nopasswd) mode=nopasswd ;;
                    --commands) _need_val "$@"; cmds=$2; shift ;;
                    --via-group) via=true ;;
                    -*) usage_err "unknown option for 'sudo $sub': $1" ;;
                    *)  who=$1 ;;
                esac
                shift
            done
            [[ -n $who ]] || usage_err "usage: umc sudo $sub USER|%GROUP [--nopasswd] [--commands '/usr/bin/x, /usr/bin/y'] [--via-group]"
            if [[ -n $cmds ]]; then
                local c; local IFS=,
                for c in $cmds; do c=${c##+([[:space:]])}; [[ $c == /* && $c != *[\\:=]* ]] || usage_err "--commands: '$c' must be an absolute path"; done
                unset IFS
            fi
            engine_begin "sudo.$sub" "$who"
            if [[ $who == %* ]]; then db_exists GR "${who#%}" || nss_group_exists "${who#%}" || die "$E_NOTFOUND" "group '${who#%}' does not exist" "nothing was changed"
            else db_exists PW "$who" || nss_user_exists "$who" || die "$E_NOTFOUND" "user '$who' does not exist" "nothing was changed"
            fi
            grep -Eqs '^[#@]includedir[[:space:]]+/etc/sudoers\.d' "$ETC/sudoers" ||
                warn "/etc/sudoers has no '#includedir /etc/sudoers.d' line: rules written there are ignored by sudo"
            if $via; then
                [[ $who != %* ]] || usage_err "--via-group only works for users"
                admin_group || die "$E_NOTFOUND" "no sudo-granting group (wheel/sudo) exists here" "nothing was changed"
                local ag=$REPLY
                if [[ $sub == grant ]]; then group_member_add "$ag" "$who"; else UO=(); guard_account "$who" lock; group_member_del "$ag" "$who"; fi
            elif [[ $sub == grant ]]; then
                sudo_stage_grant "$who" "$mode" "$cmds"
            else
                [[ $who == %* ]] || { UO=(); guard_account "$who" lock; }
                sudo_stage_revoke "$who"
            fi
            TXN_SUMMARY="sudo $sub $who"
            engine_commit || { $OPT_DRY_RUN || no_change "sudo rule for $who already as requested"; return 0; }
            if [[ $sub == grant ]]; then ok "sudo granted to $who (${mode}${cmds:+, commands: $cmds})${via:+}"; else ok "sudo revoked for $who"; fi
            [[ $mode == nopasswd && $sub == grant ]] && warn "NOPASSWD rules let anyone with this account's session run commands as root without re-authenticating"
            jset principal "$who"
            engine_finish "$sub" ;;
        list)
            engine_read
            local f line out=()
            for f in "$ETC"/sudoers.d/umc-*; do
                [[ -f $f ]] || continue
                while IFS= read -r line; do
                    [[ -z $line || $line == \#* ]] && continue
                    say "  ${line}   ${C_DIM}(${f#"$R"})${C_RESET}"; out+=("$line")
                done < "$f"
            done
            if admin_group; then
                db_fields GR "$REPLY"
                say "  members of the '${F[0]}' group (sudo via group): ${F[3]:-(none)}"
            fi
            ((${#out[@]})) || info "no UMC-managed sudo rules"
            json_arr "${out[@]}"; jraw rules "$REPLY"; jemit ;;
        ''|help|-h|--help) help_topic sudo ;;
        *) usage_err "unknown command: sudo $sub" "see: umc help sudo" ;;
    esac
}

# --- help ----------------------------------------------------------------------------
help_main() {
    cat <<EOF
UMC $UMC_VERSION - transactional local-account management for Linux

Usage:  umc [global options] <command> [options]
        umc                         (on a terminal: the interactive console)

Users (joiner / mover / leaver)
  user create NAME [opts]           create an account (idempotent)
  user modify NAME [opts]           change comment, shell, home, groups, name, uid
  user passwd NAME                  set a password (--password-stdin | --generate | --hash)
  user lock | unlock NAME           lock = password AND expiry (blocks SSH keys too)
  user expire NAME DATE             YYYY-MM-DD, +DAYS or never
  user aging NAME [opts]            password min/max/warn/inactive days
  user key add|remove|list NAME     manage ~/.ssh/authorized_keys (as the user)
  user offboard NAME                leaver step 1: lock, strip privileges, archive (reversible)
  user reinstate NAME               undo an offboarding
  user delete NAME                  leaver step 2: archive, then delete (explicit)
  user show NAME | user list        inspect
Groups & sudo
  group create|delete|show|list     group add-member|remove-member GROUP USER...
  sudo grant|revoke USER|%GROUP     validated with visudo · sudo list
Bulk (declarative)
  import inspect FILE               explain how UMC reads an HR export (CSV/JSON, any layout)
  plan -f FILE                      show what apply would change (nothing is written)
  apply -f FILE                     make the system match the file, in one transaction
  export [--format csv|json]        access-review report
Security
  audit [--fail-on SEVERITY]        compliance checks (CIS-mapped), JSON with --json
  policy show | policy set [opts]   password policy (pwquality.conf + login.defs)
  sweep [--install-timer]           enforce onboarding deadlines (run every 15 min)
Safety net
  history | show TXN | rollback TXN|--last | recover
  locks [--clear-stale] | log show|verify | doctor

Global options
  --root DIR     operate on an offline tree (image, chroot, test fixture) instead of /
  -n, --dry-run  show the exact diff (hashes redacted) and write nothing
  -y, --yes      do not ask for confirmation      --json   machine-readable output
  -q, --quiet    only warnings and errors         --no-color
  --config FILE  alternative umc.conf             --debug  trace failing commands
  -V, --version  -h, --help [COMMAND]

Exit codes: 0 ok · 1 failure · 2 usage · 3 invalid input/policy · 4 locked · 5 not found
            6 conflict · 7 integrity check failed (nothing written) · 8 rolled back · 10 audit findings
EOF
}
help_topic() {
    case ${1:-} in
        user) cat <<'EOF'
umc user create NAME
    --uid N  --group G (primary)  --groups a,b  --comment TEXT  --home DIR  --shell PATH
    --expire YYYY-MM-DD|+DAYS|never  --role ROLE  --system  --no-home
    --ssh-key 'ssh-ed25519 AAAA...' | --ssh-key @keys.pub     (repeatable)
    --password-stdin | --generate-password [--show-password] | --password-hash '$6$...'
    --force-change  --sudo | --sudo-nopasswd
umc user modify NAME  --comment --shell --home DIR [--move-home] --add-groups --remove-groups
                      --rename NEW --uid N --expire DATE
umc user passwd NAME  [--password-stdin | --generate [--show-password] | --hash H] [--force-change]
umc user lock NAME [--reason TEXT] · umc user unlock NAME · umc user expire NAME DATE
umc user aging NAME [--min N] [--max N] [--warn N] [--inactive N|never] [--force-change]
umc user key add NAME KEY|@FILE... · key remove NAME KEY|@FILE... · key list NAME
umc user offboard NAME [--reason TEXT] · reinstate NAME · delete NAME [--keep-home] [--force]
umc user show NAME · umc user list [--human|--system|--all]
EOF
        ;;
        group) printf '%s\n' "umc group create NAME [--gid N] [--system]" "umc group delete NAME [--force]" \
                   "umc group add-member GROUP USER... · umc group remove-member GROUP USER..." "umc group show NAME · umc group list [--all]" ;;
        sudo)  printf '%s\n' "umc sudo grant USER|%GROUP [--nopasswd] [--commands '/usr/bin/a, /usr/bin/b'] [--via-group]" \
                   "umc sudo revoke USER|%GROUP [--via-group]" "umc sudo list" ;;
        *) help_main ;;
    esac
}

# ==============================================================================
# §14 INTERACTIVE CONSOLE (TUI)
#     The v1 look, kept on purpose. What changed underneath: every menu action
#     runs the SAME code path as the CLI (in a subshell, so a failure returns to
#     the menu instead of exiting), prints its CLI equivalent so admins learn
#     the automatable form, holds no lock while idle, and logs out after 15
#     idle minutes.
# ==============================================================================

TUI_DRY=false TUI_W=80 TUI_IDLE=900 TUI_RC=0

tui_width() {
    local c
    c=$(tput cols 2>/dev/null) || c=${COLUMNS:-80}
    [[ $c =~ ^[0-9]+$ ]] || c=80
    ((c < 80)) && c=80
    ((c > 120)) && c=120
    TUI_W=$c
}
_rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+=$1; done; REPLY=$s; }
tui_line() { _rep "${1:-═}" $((TUI_W - 4)); printf '  %s%s%s\n' "$C_DIM" "$REPLY" "$C_RESET"; }

tui_banner() {
    local inner=$((TUI_W - 2)) bar t
    _rep '█' "$TUI_W"; bar=$REPLY
    _center() {
        local txt=$1 clr=${2:-} l r
        l=$(( (inner - ${#txt}) / 2 )) r=$(( inner - ${#txt} - l ))
        printf '%s█%s%*s%s%s%s%*s%s█%s\n' "$C_BLUE" "$C_RESET" "$l" '' "$clr" "$txt" "$C_RESET" "$r" '' "$C_BLUE" "$C_RESET"
    }
    printf '\n%s%s%s\n' "$C_BLUE" "$bar" "$C_RESET"
    _center ""
    _center "U S E R   M A N A G E M E N T   C O N S O L E" "$C_BOLD$C_WHITE"
    _center ""
    t="[ VERSION $UMC_VERSION ]   [ ADMIN: ${ACTOR^^} ]   [ HOST: ${HOSTNAME:-?} ]"
    _center "$t" "$C_DIM$C_WHITE"
    printf '%s%s%s\n' "$C_BLUE" "$bar" "$C_RESET"
}
tui_crumb() {
    if [[ -n $1 ]]; then
        tui_line ═
        printf '  %sUMC%s %s>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET" "$C_WHITE" "$1" "$C_RESET"
    fi
    tui_line ═
}
tui_status() {
    local mode left right gap
    mode="LIVE /"; $LIVE || mode="ROOT $R"
    left="MODE: $mode   DRY-RUN: $($TUI_DRY && echo "ON " || echo OFF)"
    right="SYSTEM: ${OS[ID]^^} ${OS[VERSION_ID]}"
    gap=$(( TUI_W - ${#left} - ${#right} - 6 )); ((gap < 2)) && gap=2
    printf '\n'
    tui_line ─
    if $TUI_DRY; then printf '  %s%s%*s%s%s\n' "$C_YELLOW" "$left" "$gap" '' "$right" "$C_RESET"
    else printf '  %s%s%*s%s%s\n' "$C_DIM" "$left" "$gap" '' "$right" "$C_RESET"; fi
    tui_line ═
}
tui_header() { clear 2>/dev/null || printf '\n'; tui_banner; tui_crumb "${1:-}"; printf '\n'; }
tui_item() {
    local pad=$(( 28 - ${#1} - ${#2} - 1 )); ((pad < 2)) && pad=2
    printf '   %s%s%s %s%*s%s→%s  %s\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET" "$2" "$pad" '' "$C_DIM" "$C_RESET" "$3"
}
tui_pair() {
    local col=$(( TUI_W / 2 - 2 )) item1="$1 $2" pad
    pad=$(( col - ${#item1} )); ((pad < 2)) && pad=2
    if [[ -n ${3:-} ]]; then
        printf '   %s%s%s %s%*s%s%s%s %s\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET" "$2" "$pad" '' "$C_CYAN$C_BOLD" "$3" "$C_RESET" "$4"
    else
        printf '   %s%s%s %s\n' "$C_CYAN$C_BOLD" "$1" "$C_RESET" "$2"
    fi
}
tui_task() {   # DESCRIPTION STATUS [EXTRA] - the v1 "TASK: ....... [ DONE ]" line
    local dots col=$C_WHITE
    dots=$(( TUI_W - 16 - ${#1} - 8 )); ((dots < 3)) && dots=3
    case $2 in DONE|OK) col=$C_GREEN ;; FAIL) col=$C_RED ;; WARN) col=$C_YELLOW ;; esac
    _rep . "$dots"
    printf '  %sTASK:%s %s %s%s%s  %s[ %s ]%s%s\n' "$C_DIM" "$C_RESET" "$1" "$C_DIM" "$REPLY" "$C_RESET" "$col" "$2" "$C_RESET" "${3:+ $C_DIM→$C_RESET $3}"
}
tui_idle_exit() { printf '\n\n  %sIdle for %d minutes: session closed.%s\n' "$C_YELLOW" $((TUI_IDLE / 60)) "$C_RESET"; exit 0; }
tui_ask() {   # PROMPT VAR - one line of input, with the idle timeout
    local __v
    IFS= read -r -t "$TUI_IDLE" -p "  $1: " __v || tui_idle_exit
    printf -v "$2" '%s' "$__v"
}
tui_yes() {   # PROMPT -> 0 if y
    local a
    IFS= read -r -t "$TUI_IDLE" -n 1 -p "  $1 [y/N] " a || tui_idle_exit
    printf '\n'
    [[ ${a,,} == y ]]
}
tui_pause() {
    tui_line ·
    IFS= read -r -s -n 1 -t "$TUI_IDLE" -p "  PRESS ANY KEY TO CONTINUE..." _ || tui_idle_exit
    printf '\n'
}
tui_secret() {   # -> REPLY (asked twice, never echoed)
    local a b
    IFS= read -r -s -t "$TUI_IDLE" -p "  New password: " a || tui_idle_exit; printf '\n'
    IFS= read -r -s -t "$TUI_IDLE" -p "  Repeat:       " b || tui_idle_exit; printf '\n'
    [[ $a == "$b" ]] || { printf '  %s✗ the passwords do not match%s\n' "$C_RED" "$C_RESET"; REPLY=""; return 1; }
    REPLY=$a
}

# Runs one UMC command exactly as the CLI would (secrets, if any, on stdin).
tui_run() {
    local a=()
    $TUI_DRY && a+=(--dry-run)
    [[ -n $OPT_ROOT ]] && a+=(--root "$OPT_ROOT")
    a+=("$@")
    printf '  %sCLI equivalent:%s umc%s\n\n' "$C_DIM" "$C_RESET" "$(printf ' %q' "${a[@]}")"
    ( main "${a[@]}" )
    TUI_RC=$?
    printf '\n'
    ((TUI_RC == 0)) || tui_task "command finished" FAIL "exit code $TUI_RC"
}
tui_run_secret() {   # SECRET ARGS...
    local s=$1; shift
    printf '%s\n' "$s" | tui_run "$@"
}

tui_boot() {
    clear 2>/dev/null || true
    tui_line ═
    printf '  %sU S E R   M A N A G E M E N T   C O N S O L E%s\n' "$C_BOLD$C_WHITE" "$C_RESET"
    printf '  %s[ VERSION %s ]   INITIALIZING...%s\n' "$C_DIM" "$UMC_VERSION" "$C_RESET"
    tui_line ═
    printf '\n'
    if ((EUID == 0)); then tui_task "Verifying root privileges" DONE; else tui_task "Verifying root privileges" FAIL; die "$E_FAIL" "UMC must run as root" "nothing was changed" "sudo $0"; fi
    if [[ -f $F_PASSWD && -f $F_SHADOW && -f $F_GROUP ]]; then tui_task "Locating account databases" DONE "$ETC"; else tui_task "Locating account databases" FAIL; preflight; fi
    os_info; tui_task "Detecting operating system" DONE "${OS[PRETTY_NAME]}"
    if cap_has fcntl_lock; then tui_task "Lock interop (shadow-utils + lckpwdf)" DONE; else tui_task "Lock interop (shadow-utils + lckpwdf)" WARN "hard-link locks only"; fi
    if cap_has openssl6; then tui_task "Password hashing (SHA-512 crypt)" DONE; else tui_task "Password hashing" FAIL "openssl too old"; fi
    if cap_has selinux; then tui_task "SELinux labels" DONE "maintained"; fi
    local c=0 m
    for m in "$TXN_DIR"/*/meta; do [[ -f $m ]] && grep -qx 'state=committing' "$m" && c=$((c + 1)); done
    if ((c)); then tui_task "Journal" WARN "$c interrupted transaction(s): see SAFETY NET"; else tui_task "Journal" DONE "consistent"; fi
    printf '\n'; tui_line ═
    printf '  %s✓ Ready. Nothing is locked while you browse menus.%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    tui_line ═
}

tui_main() {
    [[ -t 0 && -t 1 ]] || usage_err "the console needs a terminal; use the CLI (umc help)"
    ui_colors
    tui_width
    cfg_resolve
    tui_boot
    sleep 1
    local sel
    while :; do
        tui_header ""
        tui_item "[1]" "USER ACTIONS"      "create, modify, passwords, lock, keys, offboard"
        tui_item "[2]" "GROUPS & SUDO"     "groups, members, validated sudo rules"
        tui_item "[3]" "SECURITY & AUDIT"  "CIS-mapped audit, policy, access review"
        tui_item "[4]" "BULK OPERATIONS"   "any CSV/JSON: inspect, plan, apply"
        tui_item "[5]" "SAFETY NET & LOGS" "history, undo, locks, audit log, doctor"
        printf '\n'
        tui_item "[D]" "DRY-RUN MODE"      "currently $($TUI_DRY && echo ON || echo OFF): preview every change"
        tui_item "[0]" "QUIT CONSOLE"      "nothing to clean up: no locks are held"
        tui_status
        IFS= read -r -t "$TUI_IDLE" -p "  ENTER SELECTION: " sel || tui_idle_exit
        case ${sel,,} in
            1) tui_users ;; 2) tui_groups ;; 3) tui_security ;; 4) tui_bulk ;; 5) tui_safety ;;
            d) if $TUI_DRY; then TUI_DRY=false; else TUI_DRY=true; fi ;;
            0|q) printf '\n'; exit 0 ;;
        esac
    done
}

tui_users() {
    local a u v w x
    while :; do
        tui_header "[1] USER ACTIONS"
        tui_pair "[A]" "CREATE NEW USER"        "[G]" "OFFBOARD USER (SOFT)"
        tui_pair "[B]" "MODIFY ACCOUNT"         "[H]" "REINSTATE USER"
        tui_pair "[C]" "SET / RESET PASSWORD"   "[I]" "DELETE USER (ARCHIVED)"
        tui_pair "[D]" "LOCK / UNLOCK"          "[J]" "SHOW USER"
        tui_pair "[E]" "SET ACCOUNT EXPIRY"     "[K]" "LIST USERS"
        tui_pair "[F]" "MANAGE SSH KEYS"        "[R]" "RETURN TO MAIN MENU"
        tui_status
        IFS= read -r -t "$TUI_IDLE" -p "  SELECT ACTION: " a || tui_idle_exit
        case ${a,,} in
            a) tui_header "[1] USER ACTIONS > [A] CREATE NEW USER"
               tui_ask "User name" u; [[ -n $u ]] || continue
               local args=(user create "$u")
               tui_ask "Comment / full name (Enter to skip)" v; [[ -n $v ]] && args+=(--comment "$v")
               tui_ask "Supplementary groups, comma separated (Enter to skip)" v; [[ -n $v ]] && args+=(--groups "$v")
               tui_ask "Login shell (Enter for ${CFG[default_shell]})" v; [[ -n $v ]] && args+=(--shell "$v")
               local roles=() f
               for f in "$ETC"/umc/roles.d/*.conf; do [[ -f $f ]] && { f=${f##*/}; roles+=("${f%.conf}"); }; done
               if ((${#roles[@]})); then tui_ask "Role (${roles[*]}) (Enter to skip)" v; [[ -n $v ]] && args+=(--role "$v"); fi
               tui_ask "Account expiry YYYY-MM-DD / +DAYS (Enter = never)" v; [[ -n $v ]] && args+=(--expire "$v")
               tui_ask "SSH public key (paste, or Enter to skip)" v; [[ -n $v ]] && args+=(--ssh-key "$v")
               printf '  Password: %s[G]%senerate temporary (recommended)  %s[S]%set now  %s[N]%sone (SSH key only)\n' \
                   "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
               tui_ask "Choice" w
               case ${w,,} in
                   s) tui_secret || { tui_pause; continue; }; x=$REPLY
                      tui_yes "Require a change at first login?" && args+=(--force-change)
                      args+=(--password-stdin); tui_run_secret "$x" "${args[@]}"; x="" ;;
                   n) tui_run "${args[@]}" ;;
                   *) tui_run "${args[@]}" --generate-password --show-password
                      printf '  %sThe temporary password is shown once; it is also in the root-only credential slip.%s\n' "$C_YELLOW" "$C_RESET" ;;
               esac
               tui_pause ;;
            b) tui_header "[1] USER ACTIONS > [B] MODIFY ACCOUNT"
               tui_ask "User name" u; [[ -n $u ]] || continue
               tui_pair "[A]" "CHANGE SHELL" "[E]" "REMOVE FROM GROUPS"
               tui_pair "[B]" "CHANGE HOME DIRECTORY" "[F]" "RENAME ACCOUNT"
               tui_pair "[C]" "CHANGE COMMENT / GECOS" "[G]" "CHANGE UID"
               tui_pair "[D]" "ADD TO GROUPS" "" ""
               tui_ask "Select" w
               case ${w,,} in
                   a) tui_ask "New shell (see /etc/shells)" v; tui_run user modify "$u" --shell "$v" ;;
                   b) tui_ask "New home directory" v
                      if tui_yes "Move the existing files there?"; then tui_run user modify "$u" --home "$v" --move-home; else tui_run user modify "$u" --home "$v"; fi ;;
                   c) tui_ask "New comment" v; tui_run user modify "$u" --comment "$v" ;;
                   d) tui_ask "Groups to add (comma separated)" v; tui_run user modify "$u" --add-groups "$v" ;;
                   e) tui_ask "Groups to remove (comma separated)" v; tui_run user modify "$u" --remove-groups "$v" ;;
                   f) tui_ask "New user name" v; tui_run user modify "$u" --rename "$v" ;;
                   g) tui_ask "New UID" v; tui_run user modify "$u" --uid "$v" ;;
                   *) continue ;;
               esac
               tui_pause ;;
            c) tui_header "[1] USER ACTIONS > [C] SET / RESET PASSWORD"
               tui_ask "User name" u; [[ -n $u ]] || continue
               if tui_yes "Generate a temporary password (the user must change it within ${CFG[onboarding_deadline_hours]} h)?"; then
                   tui_run user passwd "$u" --generate --show-password
               else
                   tui_secret || { tui_pause; continue; }; x=$REPLY
                   if tui_yes "Require a change at next login?"; then tui_run_secret "$x" user passwd "$u" --password-stdin --force-change
                   else tui_run_secret "$x" user passwd "$u" --password-stdin; fi
                   x=""
               fi
               tui_pause ;;
            d) tui_header "[1] USER ACTIONS > [D] LOCK / UNLOCK"
               tui_ask "User name" u; [[ -n $u ]] || continue
               tui_run user show "$u"
               tui_ask "[L]ock or [U]nlock" w
               case ${w,,} in
                   l) tui_ask "Reason (for the audit log)" v; tui_run user lock "$u" --reason "$v" ;;
                   u) tui_run user unlock "$u" ;;
               esac
               tui_pause ;;
            e) tui_header "[1] USER ACTIONS > [E] SET ACCOUNT EXPIRY"
               tui_ask "User name" u; tui_ask "Expiry: YYYY-MM-DD, +DAYS or never" v
               [[ -n $u && -n $v ]] && tui_run user expire "$u" "$v"
               tui_pause ;;
            f) tui_header "[1] USER ACTIONS > [F] MANAGE SSH KEYS"
               tui_ask "User name" u; [[ -n $u ]] || continue
               tui_ask "[A]dd, [R]emove or [L]ist" w
               case ${w,,} in
                   a) tui_ask "Paste the public key" v; tui_run user key add "$u" "$v" ;;
                   r) tui_ask "Paste the public key to remove" v; tui_run user key remove "$u" "$v" ;;
                   *) tui_run user key list "$u" ;;
               esac
               tui_pause ;;
            g) tui_header "[1] USER ACTIONS > [G] OFFBOARD USER"
               printf '  %sOffboarding locks the account, removes privileges, ends sessions and archives the home.\n  Nothing is deleted and it can be reversed (REINSTATE).%s\n\n' "$C_DIM" "$C_RESET"
               tui_ask "User name" u; [[ -n $u ]] || continue
               tui_ask "Reason (for the audit log)" v
               tui_yes "Offboard $u now?" && tui_run user offboard "$u" --reason "$v"
               tui_pause ;;
            h) tui_header "[1] USER ACTIONS > [H] REINSTATE USER"
               tui_ask "User name" u; [[ -n $u ]] && tui_run user reinstate "$u"
               tui_pause ;;
            i) tui_header "[1] USER ACTIONS > [I] DELETE USER"
               printf '  %sPermanent. The home directory is archived and verified first.%s\n\n' "$C_YELLOW" "$C_RESET"
               tui_ask "User name" u; [[ -n $u ]] || continue
               tui_ask "Type the user name again to confirm" v
               if [[ $v == "$u" ]]; then
                   if tui_yes "Keep the home directory in place?"; then tui_run --yes user delete "$u" --keep-home; else tui_run --yes user delete "$u"; fi
               else printf '  not confirmed; nothing was changed\n'; fi
               tui_pause ;;
            j) tui_header "[1] USER ACTIONS > [J] SHOW USER"; tui_ask "User name" u; [[ -n $u ]] && tui_run user show "$u"; tui_pause ;;
            k) tui_header "[1] USER ACTIONS > [K] LIST USERS"; tui_run user list; tui_pause ;;
            r) return 0 ;;
        esac
    done
}

tui_groups() {
    local a g u v
    while :; do
        tui_header "[2] GROUPS & SUDO"
        tui_pair "[A]" "CREATE GROUP"        "[E]" "GRANT SUDO"
        tui_pair "[B]" "DELETE GROUP"        "[F]" "REVOKE SUDO"
        tui_pair "[C]" "ADD MEMBERS"         "[G]" "LIST SUDO RULES"
        tui_pair "[D]" "REMOVE MEMBERS"      "[H]" "LIST GROUPS"
        tui_pair "[R]" "RETURN TO MAIN MENU" "" ""
        tui_status
        IFS= read -r -t "$TUI_IDLE" -p "  SELECT ACTION: " a || tui_idle_exit
        case ${a,,} in
            a) tui_header "[2] GROUPS > [A] CREATE GROUP"; tui_ask "Group name" g; [[ -n $g ]] && tui_run group create "$g"; tui_pause ;;
            b) tui_header "[2] GROUPS > [B] DELETE GROUP"; tui_ask "Group name" g
               [[ -n $g ]] && tui_yes "Delete group $g?" && tui_run group delete "$g"; tui_pause ;;
            c) tui_header "[2] GROUPS > [C] ADD MEMBERS"; tui_ask "Group" g; tui_ask "Users (space separated)" u
               # shellcheck disable=SC2086  # the user list is meant to split
               [[ -n $g && -n $u ]] && tui_run group add-member "$g" $u; tui_pause ;;
            d) tui_header "[2] GROUPS > [D] REMOVE MEMBERS"; tui_ask "Group" g; tui_ask "Users (space separated)" u
               # shellcheck disable=SC2086
               [[ -n $g && -n $u ]] && tui_run group remove-member "$g" $u; tui_pause ;;
            e) tui_header "[2] SUDO > [E] GRANT SUDO"
               printf '  %sPrefer group-based access; NOPASSWD removes re-authentication.%s\n\n' "$C_DIM" "$C_RESET"
               tui_ask "User (or %group)" u; [[ -n $u ]] || continue
               local args=(sudo grant "$u")
               tui_yes "Via the admin group (wheel/sudo) instead of a per-user rule?" && args+=(--via-group)
               if [[ " ${args[*]} " != *" --via-group "* ]]; then
                   tui_ask "Limit to commands (comma separated absolute paths, Enter = all)" v; [[ -n $v ]] && args+=(--commands "$v")
                   tui_yes "Passwordless (NOPASSWD)?" && args+=(--nopasswd)
               fi
               tui_run "${args[@]}"; tui_pause ;;
            f) tui_header "[2] SUDO > [F] REVOKE SUDO"; tui_ask "User (or %group)" u; [[ -n $u ]] || continue
               if tui_yes "Remove from the admin group as well as the per-user rule?"; then tui_run sudo revoke "$u" --via-group; fi
               tui_run sudo revoke "$u"; tui_pause ;;
            g) tui_header "[2] SUDO > [G] RULES"; tui_run sudo list; tui_pause ;;
            h) tui_header "[2] GROUPS > [H] LIST"; tui_run group list; tui_pause ;;
            r) return 0 ;;
        esac
    done
}

tui_security() {
    local a v w x y
    while :; do
        tui_header "[3] SECURITY & AUDIT"
        tui_pair "[A]" "COMPLIANCE AUDIT (CIS)"   "[D]" "ACCESS REVIEW EXPORT"
        tui_pair "[B]" "SHOW PASSWORD POLICY"     "[E]" "RUN ONBOARDING SWEEP"
        tui_pair "[C]" "SET PASSWORD POLICY"      "[R]" "RETURN TO MAIN MENU"
        tui_status
        IFS= read -r -t "$TUI_IDLE" -p "  SELECT ACTION: " a || tui_idle_exit
        case ${a,,} in
            a) tui_header "[3] SECURITY > [A] COMPLIANCE AUDIT"; tui_run audit; tui_pause ;;
            b) tui_header "[3] SECURITY > [B] PASSWORD POLICY"; tui_run policy show; tui_pause ;;
            c) tui_header "[3] SECURITY > [C] SET PASSWORD POLICY"
               local args=(policy set)
               tui_ask "Minimum length (Enter to keep)" v;        [[ -n $v ]] && args+=(--min-length "$v")
               tui_ask "Minimum character classes 0-4 (Enter to keep)" w; [[ -n $w ]] && args+=(--min-classes "$w")
               tui_ask "Maximum password age in days (Enter to keep)" x; [[ -n $x ]] && args+=(--max-days "$x")
               tui_ask "Warning days before expiry (Enter to keep)" y;  [[ -n $y ]] && args+=(--warn-days "$y")
               [[ -n $x$y ]] && tui_yes "Apply aging to existing accounts too?" && args+=(--apply-to-existing)
               ((${#args[@]} > 2)) && tui_run "${args[@]}"
               tui_pause ;;
            d) tui_header "[3] SECURITY > [D] ACCESS REVIEW EXPORT"
               printf -v v '/root/umc-access-review-%(%Y%m%d)T.csv' -1
               tui_ask "Output file (Enter for $v)" w
               tui_run export --output "${w:-$v}"; tui_pause ;;
            e) tui_header "[3] SECURITY > [E] ONBOARDING SWEEP"; tui_run sweep; tui_pause ;;
            r) return 0 ;;
        esac
    done
}

tui_bulk() {
    local a f
    while :; do
        tui_header "[4] BULK OPERATIONS"
        tui_pair "[A]" "INSPECT A FILE (CSV/JSON)" "[C]" "APPLY A FILE"
        tui_pair "[B]" "PLAN (PREVIEW) A FILE"     "[D]" "EXPORT USER LIST"
        tui_pair "[R]" "RETURN TO MAIN MENU"       "" ""
        tui_status
        IFS= read -r -t "$TUI_IDLE" -p "  SELECT ACTION: " a || tui_idle_exit
        case ${a,,} in
            a) tui_header "[4] BULK > [A] INSPECT"; tui_ask "Path to the CSV/JSON file" f; [[ -n $f ]] && tui_run import inspect "$f"; tui_pause ;;
            b) tui_header "[4] BULK > [B] PLAN"; tui_ask "Path to the CSV/JSON file" f; [[ -n $f ]] && tui_run plan -f "$f"; tui_pause ;;
            c) tui_header "[4] BULK > [C] APPLY"
               tui_ask "Path to the CSV/JSON file" f; [[ -n $f ]] || continue
               tui_run plan -f "$f"
               if ((TUI_RC == 0)) && tui_yes "Apply this plan?"; then tui_run --yes apply -f "$f"; fi
               tui_pause ;;
            d) tui_header "[4] BULK > [D] EXPORT"; tui_run export; tui_pause ;;
            r) return 0 ;;
        esac
    done
}

tui_safety() {
    local a t
    while :; do
        tui_header "[5] SAFETY NET & LOGS"
        tui_pair "[A]" "TRANSACTION HISTORY"  "[E]" "LOCK STATUS"
        tui_pair "[B]" "UNDO LAST CHANGE"     "[F]" "AUDIT LOG (RECENT)"
        tui_pair "[C]" "SHOW A TRANSACTION"   "[G]" "VERIFY AUDIT LOG"
        tui_pair "[D]" "ROLL BACK A TXN"      "[H]" "HOST DOCTOR"
        tui_pair "[R]" "RETURN TO MAIN MENU"  "" ""
        tui_status
        IFS= read -r -t "$TUI_IDLE" -p "  SELECT ACTION: " a || tui_idle_exit
        case ${a,,} in
            a) tui_header "[5] SAFETY NET > [A] HISTORY"; tui_run history; tui_pause ;;
            b) tui_header "[5] SAFETY NET > [B] UNDO LAST CHANGE"; tui_yes "Roll back the most recent committed transaction?" && tui_run rollback --last; tui_pause ;;
            c) tui_header "[5] SAFETY NET > [C] SHOW"; tui_ask "Transaction id" t; [[ -n $t ]] && tui_run show "$t"; tui_pause ;;
            d) tui_header "[5] SAFETY NET > [D] ROLL BACK"; tui_ask "Transaction id" t; [[ -n $t ]] && tui_yes "Roll back $t?" && tui_run rollback "$t"; tui_pause ;;
            e) tui_header "[5] SAFETY NET > [E] LOCKS"; tui_run locks; tui_pause ;;
            f) tui_header "[5] SAFETY NET > [F] AUDIT LOG"; tui_run log show; tui_pause ;;
            g) tui_header "[5] SAFETY NET > [G] VERIFY"; tui_run log verify; tui_pause ;;
            h) tui_header "[5] SAFETY NET > [H] DOCTOR"; tui_run doctor; tui_pause ;;
            r) return 0 ;;
        esac
    done
}

# ==============================================================================
# §15 MAIN
# ==============================================================================

main() {
    local args=() cmd
    # Global options are accepted anywhere on the command line.
    while (($#)); do
        case $1 in
            --root)       [[ $# -ge 2 ]] || usage_err "--root needs a directory"; OPT_ROOT=$2; shift ;;
            --root=*)     OPT_ROOT=${1#*=} ;;
            --config)     [[ $# -ge 2 ]] || usage_err "--config needs a file"; OPT_CONFIG=$2; shift ;;
            --config=*)   OPT_CONFIG=${1#*=} ;;
            -n|--dry-run) OPT_DRY_RUN=true ;;
            -y|--yes)     OPT_YES=true ;;
            --json)       OPT_JSON=true ;;
            -q|--quiet)   OPT_QUIET=true ;;
            --no-color)   OPT_COLOR=never ;;
            --color)      OPT_COLOR=always ;;
            --debug)      OPT_DEBUG=true ;;
            -V|--version) printf 'umc %s\n' "$UMC_VERSION"; exit 0 ;;
            --)           shift; args+=("$@"); break ;;
            *)            args+=("$1") ;;
        esac
        shift
    done
    ui_colors
    if [[ -n $OPT_ROOT ]]; then
        [[ $OPT_ROOT == /* ]] || usage_err "--root needs an absolute path"
        [[ -d $OPT_ROOT ]]    || usage_err "--root $OPT_ROOT is not a directory"
        OPT_ROOT=$(cd -- "$OPT_ROOT" && pwd -P)
        [[ $OPT_ROOT == / ]] && OPT_ROOT=""
    fi
    paths_init
    traps_install
    debug_install
    cfg_load
    cfg_resolve              # effective defaults, once, for every command
    audit_actor_init
    ((EUID == 0)) && AUDIT_READY=true

    set -- "${args[@]}"
    cmd=${1:-}
    (($#)) && shift
    case $cmd in
        '')            if [[ -t 0 && -t 1 ]]; then tui_main; else help_main; fi ;;
        tui|console)   tui_main ;;
        user)          cmd_user "$@" ;;
        group)         cmd_group "$@" ;;
        sudo)          cmd_sudo "$@" ;;
        import)        cmd_import "$@" ;;
        plan)          cmd_plan "$@" ;;
        apply)         cmd_apply "$@" ;;
        export)        cmd_export "$@" ;;
        audit)         cmd_audit "$@" ;;
        policy)        cmd_policy "$@" ;;
        sweep)         cmd_sweep "$@" ;;
        history)       cmd_history "$@" ;;
        show)          cmd_show "$@" ;;
        rollback|undo) cmd_rollback "$@" ;;
        recover)       cmd_recover "$@" ;;
        locks)         cmd_locks "$@" ;;
        log)           cmd_log "$@" ;;
        doctor)        cmd_doctor "$@" ;;
        help|-h|--help) help_topic "${1:-}" ;;
        version)       printf 'umc %s\n' "$UMC_VERSION" ;;
        *)             usage_err "unknown command '$cmd'" ;;
    esac
}

# Run only when executed; tests can 'source' this file to reach its functions.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
    exit "$E_OK"
fi
