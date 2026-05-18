#!/usr/bin/env bash

# Initial checks and pre-requisites before running the script

### Umask is set to 0077 for better security upon file creation such as logs, backups etc.
umask 0077

# ══════════════════════════════════════════════════════════════════════════════
#  TERMINAL & COLOR CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
[[ $TERM_WIDTH -lt 80 ]] && TERM_WIDTH=80
[[ $TERM_WIDTH -gt 120 ]] && TERM_WIDTH=120

if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  C_RESET="" C_BOLD="" C_DIM=""
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_WHITE=""
else
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_RED="\033[91m"
  C_GREEN="\033[92m"
  C_YELLOW="\033[93m"
  C_BLUE="\033[94m"
  C_CYAN="\033[96m"
  C_WHITE="\033[97m"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  UI DRAWING FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

### Repeat a character N times
_repeat() {
  local char="$1" count="$2" out=""
  for ((i = 0; i < count; i++)); do out+="$char"; done
  printf "%s" "$out"
}

### Draw a full-width separator line (default ═)
draw_line() {
  local char="${1:-═}"
  printf '  %b%s%b\n' "$C_DIM" "$(_repeat "$char" $((TERM_WIDTH - 4)))" "$C_RESET"
}

### Draw the solid-block banner
draw_banner() {
  local w=$TERM_WIDTH
  local inner=$((w - 2))
  local title="U S E R   M A N A G E M E N T   C O N S O L E"
  local subtitle="[ VERSION 1.0 ]   [ USER: ROOT ]"
  local bar
  bar="$(_repeat '█' "$w")"

  _center_line() {
    local txt="$1" clr="${2:-}"
    local tlen=${#txt}
    local lpad=$(( (inner - tlen) / 2 ))
    local rpad=$(( inner - tlen - lpad ))
    printf '%b█%b' "$C_BLUE" "$C_RESET"
    printf '%*s' "$lpad" ''
    [[ -n "$clr" ]] && printf '%b' "$clr"
    printf '%s' "$txt"
    [[ -n "$clr" ]] && printf '%b' "$C_RESET"
    printf '%*s' "$rpad" ''
    printf '%b█%b\n' "$C_BLUE" "$C_RESET"
  }

  printf '\n%b%s%b\n' "$C_BLUE" "$bar" "$C_RESET"
  _center_line ""
  _center_line "$title" "${C_BOLD}${C_WHITE}"
  _center_line ""
  _center_line "$subtitle" "${C_DIM}${C_WHITE}"
  printf '%b%s%b\n' "$C_BLUE" "$bar" "$C_RESET"
}

### Draw breadcrumb trail
draw_breadcrumb() {
  local crumb="$1"
  if [[ -n "$crumb" ]]; then
    draw_line "═"
    printf '  %bUMC%b %b>%b %b%s%b\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET" "$C_WHITE" "$crumb" "$C_RESET"
  fi
  draw_line "═"
}

### Draw the lock/OS status bar
draw_status_bar() {
  local os="${SYSTEM_TYPE^^}"
  [[ -z "$os" ]] && os="DETECTING"
  draw_line "─"
  local left="LOCK: /var/lock/umc.lock [EQUIPPED]"
  local right="SYSTEM: ${os} DETECTED"
  local gap=$(( TERM_WIDTH - ${#left} - ${#right} - 6 ))
  [[ $gap -lt 2 ]] && gap=2
  printf '  %b%s%*s%s%b\n' "$C_DIM" "$left" "$gap" "" "$right" "$C_RESET"
  draw_line "═"
}

### Draw a main-menu style item:  [key] LABEL  →  description
draw_menu_item() {
  local key="$1" label="$2" desc="$3"
  local col=28
  local pad=$(( col - ${#key} - ${#label} - 1 ))
  [[ $pad -lt 2 ]] && pad=2
  printf '   %b%s%b %s%*s%b→%b  %s\n' \
    "${C_CYAN}${C_BOLD}" "$key" "$C_RESET" "$label" "$pad" "" "$C_DIM" "$C_RESET" "$desc"
}

### Draw a sub-menu pair of items in two columns
draw_menu_pair() {
  local key1="$1" lbl1="$2" key2="${3:-}" lbl2="${4:-}"
  local col=$(( TERM_WIDTH / 2 - 2 ))
  local item1="${key1} ${lbl1}"
  local pad1=$(( col - ${#item1} ))
  [[ $pad1 -lt 2 ]] && pad1=2
  if [[ -n "$key2" ]]; then
    printf '   %b%s%b %s%*s%b%s%b %s\n' \
      "${C_CYAN}${C_BOLD}" "$key1" "$C_RESET" "$lbl1" "$pad1" "" "${C_CYAN}${C_BOLD}" "$key2" "$C_RESET" "$lbl2"
  else
    printf '   %b%s%b %s\n' "${C_CYAN}${C_BOLD}" "$key1" "$C_RESET" "$lbl1"
  fi
}

### Full header: clear + banner + breadcrumb
draw_header() {
  clear
  draw_banner
  draw_breadcrumb "$1"
}

### Full footer: status bar + prompt
draw_footer() {
  printf "\n"
  draw_status_bar
}

### Task status line:  TASK: description ......  [ STATUS ]
task_status() {
  local desc="$1" status="$2" extra="${3:-}"
  local scol=$(( TERM_WIDTH - 16 ))
  local prefix="TASK: ${desc} "
  local dots=$(( scol - ${#prefix} - 2 ))
  [[ $dots -lt 3 ]] && dots=3
  local color=""
  case "$status" in
    DONE)    color="$C_GREEN" ;;
    FAIL)    color="$C_RED" ;;
    WAIT)    color="$C_YELLOW" ;;
    SUCCESS) color="$C_GREEN" ;;
    ERROR)   color="$C_RED" ;;
    *)       color="$C_WHITE" ;;
  esac
  printf '  %bTASK:%b %s %b%s%b  %b[ %s ]%b' \
    "$C_DIM" "$C_RESET" "$desc" "$C_DIM" "$(_repeat '.' "$dots")" "$C_RESET" "$color" "$status" "$C_RESET"
  [[ -n "$extra" ]] && printf ' %b→%b %s' "$C_DIM" "$C_RESET" "$extra"
  printf '\n'
}

### Progress bar header:  [ RUNNING ] ·······
draw_progress() {
  local label="${1:-}"
  local tag="[ RUNNING ]"
  local dots=$(( TERM_WIDTH - ${#tag} - 6 ))
  [[ $dots -lt 5 ]] && dots=5
  printf '\n  %b%s%b %b%s%b\n\n' \
    "${C_YELLOW}${C_BOLD}" "$tag" "$C_RESET" "$C_DIM" "$(_repeat '·' "$dots")" "$C_RESET"
  [[ -n "$label" ]] && printf '  %b%s%b\n\n' "$C_BOLD" "$label" "$C_RESET"
}

### Styled error message
show_error() {
  printf '  %b✗ ERROR:%b %s\n' "${C_RED}${C_BOLD}" "$C_RESET" "$1"
}

### Styled success message
show_success() {
  printf '  %b✓ SUCCESS:%b %s\n' "${C_GREEN}${C_BOLD}" "$C_RESET" "$1"
}

### Confirmation prompt → sets CONFIRMED=true/false
prompt_confirm() {
  local msg="${1:-Are you sure?}"
  printf '  %b%s%b %b[y/N]%b ' "$C_YELLOW" "$msg" "$C_RESET" "$C_DIM" "$C_RESET"
  read -r -n 1 ans
  printf '\n'
  # shellcheck disable=SC2034  # CONFIRMED is used by callers
  [[ "${ans,,}" == "y" ]] && CONFIRMED=true || CONFIRMED=false
}

### Press any key to continue
prompt_continue() {
  draw_line "·"
  printf '\n  %bPRESS ANY KEY TO CONTINUE...%b' "$C_DIM" "$C_RESET"
  read -r -n 1 -s
  printf '\n'
}

# ══════════════════════════════════════════════════════════════════════════════
#  INITIALIZATION & BOOT SEQUENCE
# ══════════════════════════════════════════════════════════════════════════════

### Boot splash
clear
draw_line "═"
printf '  %bU S E R   M A N A G E M E N T   C O N S O L E%b\n' "${C_BOLD}${C_WHITE}" "$C_RESET"
printf '  %b[ VERSION 1.0 ]   INITIALIZING...%b\n' "$C_DIM" "$C_RESET"
draw_line "═"
printf '\n'

### Checking if the script is running as root or not

if [[ $EUID = 0 ]]; then
  task_status "Verifying root privileges" "DONE"
  sleep 1
else
  task_status "Verifying root privileges" "FAIL"
  show_error "Script must be run as ROOT"
  exit 1
fi

### Base Directory (Defaults to root or /) to locate sub-directories such as etc, var, tmp.

BASE_DIR="/home/vagrant"

### Checking if the file exist in it's respective location

if [[ -f "$BASE_DIR/etc/passwd" ]] && [[ -f "$BASE_DIR/etc/group" ]] && [[ -f "$BASE_DIR/etc/shadow" ]] && [[ -f "$BASE_DIR/etc/gshadow" ]]; then
	task_status "Locating system files" "DONE"
	sleep 1
else
	task_status "Locating system files" "FAIL" "Missing files in $BASE_DIR"
	show_error "One or more required files missing from $BASE_DIR/etc/"
  exit 1
fi

### This function will log every single action to the journal, which can be read through jounalctl binary
LOGGING_MECHANISM () {
  local exit_code=$?
  local severity_level=$1 # must be in user.warning or user.info, facility must be user and levels could be info, warn, err, crit, notice
  local message=$2 # Message must be descriptive and clearly describe the problem and it's solution (if possible), also explains the consequences if the levels are inside consideration boundaries (such as warn, err, crit, alert etc.).
  logger -it umc-script -p "$severity_level" "$message Exit Code: $exit_code"
}

### OS detection logic (WORKING)

OS_DETECTION () {
  if [[ -f $BASE_DIR/etc/os-release ]]; then
    local name
    name=$(grep -wE "^ID" "$BASE_DIR/etc/os-release" | awk -F= '{print $2}' | tr -d '\"')
    name=${name,,}
    SYSTEM_TYPE=$name
    if [[ "$name" == "rhel" ]]; then
      task_status "Detecting operating system" "DONE" "Red Hat Enterprise Linux"
      sleep 1
      SYSTEM_TYPE=$name
    elif [[ "$name" == "debian" ]]; then
      task_status "Detecting operating system" "DONE" "Debian GNU/Linux"
      sleep 1
      SYSTEM_TYPE=$name
    elif [[ "$name" == "ubuntu" ]]; then
      task_status "Detecting operating system" "DONE" "Ubuntu"
      sleep 1
      SYSTEM_TYPE=$name
    else
      task_status "Detecting operating system" "FAIL" "Non-compatible system"
      exit 1
    fi
  else
    task_status "Detecting operating system" "FAIL" "No os-release file"
    exit 1
  fi
}

### Checking if the lock file already exist or not.

LOCK_FILE="$BASE_DIR/var/lock/umc.lock"

cleanup () {
  printf "\n"
  task_status "Cleaning up lock files" "DONE"
  rm -rf $LOCK_FILE
  exit 1
}

LOCK_CHECK () {
  local pid=$$
  if [[ -d $BASE_DIR/var/lock ]]; then
  if [[ -f $LOCK_FILE ]]; then
    local old_pid
    old_pid=$(cat $LOCK_FILE)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null ; then
      task_status "Acquiring file lock" "FAIL" "Script is currently busy"
      exit 1
    else
      task_status "Clearing stale lock (dead PID)" "DONE"
      sleep 1
      exec 9>"$LOCK_FILE"
      if flock -n 9; then
        task_status "Acquiring file lock" "DONE" "PID $$"
        sleep 1
        echo $pid >&9
        trap cleanup EXIT SIGTERM SIGINT
        return 0
      else
        task_status "Acquiring file lock" "FAIL" "Script is currently busy"
        exit 1
      fi
    fi
  else
    exec 9>"$LOCK_FILE"
    if flock -n 9; then
      task_status "Creating lock file" "DONE"
      sleep 1
      task_status "Acquiring file lock" "DONE" "PID $$"
      sleep 1
      echo "$pid" >&9
      trap cleanup EXIT SIGTERM SIGINT
      return 0
    else
      task_status "Acquiring file lock" "FAIL" "Script is currently busy"
      exit 1
    fi

  fi
  else
  task_status "Checking lock directory" "FAIL" "$BASE_DIR/var/lock/ does not exist"
  exit 1
  fi
}

### Creating a backup mechanism which runs as an initial function and stores backup of the user related files inside the var/backup directroy

BACKUP_MECHANISM () {
  local backup_archive
  backup_archive=$BASE_DIR/var/backups/umc/umc_backup.tar.gz.$(date +%F_%H-%M-%S)
  mkdir -p $BASE_DIR/var/backups/umc 
  tar -czPf "$backup_archive" $BASE_DIR/etc/{passwd,shadow,group,gshadow} 
  chmod 400 "$backup_archive"
  task_status "Creating backup archive" "DONE" "Read-only, timestamped"
}

OS_DETECTION

LOCK_CHECK

printf '\n'
draw_line "═"
printf '  %b✓ All checks passed. Launching console...%b\n' "${C_GREEN}${C_BOLD}" "$C_RESET"
draw_line "═"
sleep 1


# End of initial checks.
# ------------------------------------------------------------------------------------------------------------------------------------------

### Helper Functions

atomic_commit() {
  local user_msg="$1"
  local files_to_check=("${@:2}")
  local file_check=true
  
  task_status "Verifying integrity of temporary files" "WAIT"
  
  for f in "${files_to_check[@]}"; do
    if [[ "$f" == "$BASE_DIR/tmp/passwd" ]]; then
      tail -n 1 "$f" | awk -F : 'BEGIN {status=1} NF == 7 {status=0} END {exit status}' || file_check=false
    elif [[ "$f" == "$BASE_DIR/tmp/shadow" ]]; then
      tail -n 1 "$f" | awk -F : 'BEGIN {status=1} NF == 9 {status=0} END {exit status}' || file_check=false
    elif [[ "$f" == "$BASE_DIR/tmp/group" || "$f" == "$BASE_DIR/tmp/gshadow" ]]; then
      tail -n 1 "$f" | awk -F : 'BEGIN {status=1} NF == 4 {status=0} END {exit status}' || file_check=false
    fi
  done

  if $file_check; then
    task_status "Verifying integrity of temporary files" "DONE"
    task_status "Performing atomic move" "WAIT"
    
    for f in "${files_to_check[@]}"; do
      local dest
      dest=$(echo "$f" | sed "s|/tmp/|/etc/|")
      mv "$f" "$dest"
    done
    
    task_status "Performing atomic move" "DONE"
    LOGGING_MECHANISM "user.info" "UMC: Atomic commit successful for action: $user_msg."
    BACKUP_MECHANISM
    return 0
  else
    task_status "Verifying integrity of temporary files" "FAIL"
    show_error "Temporary files corrupted. Aborting atomic commit."
    LOGGING_MECHANISM "user.err" "UMC: Atomic commit failed. Corrupted files detected during $user_msg."
    return 1
  fi
}

validate_user_exists() {
  local uname="$1"
  if grep -qE "^$uname:" "$BASE_DIR/etc/passwd"; then
    return 0
  else
    show_error "User '$uname' does not exist."
    return 1
  fi
}

validate_group_exists() {
  local gname="$1"
  if grep -qE "^$gname:" "$BASE_DIR/etc/group"; then
    return 0
  else
    show_error "Group '$gname' does not exist."
    return 1
  fi
}

USER_ACTIONS () {
  
  create_new_user () {
    draw_header "[1] USER ACTIONS > [A] CREATE NEW USER"
    draw_progress "CREATING NEW SYSTEM USER"
    
    read -rt 180 -p "  Enter Username: " INPUT
    local username=${INPUT//[^a-zA-Z0-9_-]/}
    
    if grep -E "^$username:" $BASE_DIR/etc/passwd >/dev/null 2>&1 || getent passwd "$username" >/dev/null 2>&1; then
      show_error "User with the username \"$username\" already exists in this system"
      return 1
    fi

    while true; do
      read -rst 180 -p "  Password: " input_pass
      echo
      local leng="${#input_pass}"
      if [[ $leng -ge 8 ]]; then
          if grep -q "[0-9]" <<< "$input_pass"; then
              if grep -q "[A-Z]" <<< "$input_pass"; then
                if grep -qE "[\,\.\+\-\$\@\%\*\&\=\?]" <<< "$input_pass"; then
                  printf "  %b...%b\n" "$C_DIM" "$C_RESET"
                  sleep 1
                  show_success "Strong Password!"
                  printf "  %bWARN:%b Make sure to update default password policies through SECURITY & AUDIT -> ENFORCE PASSWORD COMPLEXITY\n" "$C_YELLOW" "$C_RESET"
                  break 1
                else
                  show_error "Please use special characters like <,*.$%-+@>!"
                  continue
                fi
              else
                show_error "Please use some upper case characters!"
                continue
              fi
          else
            show_error "Please use some numerical values!"
            continue
          fi
      else
            show_error "Password must be at least 8 characters!"
      fi
    done
    
    printf "\n"
    task_status "Preparing user creation" "WAIT"
    
    # Creating a UID (Same GID)
    local new_uid
    new_uid=$(( $(grep -v "nobody" $BASE_DIR/etc/passwd | awk -F ":" '{print $3}' | sort -n | tail -1) + 1  ))
    cp $BASE_DIR/etc/{passwd,group,shadow,gshadow} $BASE_DIR/tmp/ && chmod 600 $BASE_DIR/tmp/{passwd,shadow,group,gshadow}
    
    # Appending to the passwd file in /tmp directory
    echo "$username:x:$new_uid:$new_uid:Created from UMC Script:/home/$username:/bin/bash" >> $BASE_DIR/tmp/passwd
    # Appending to Group file in /tmp directory
    echo "$username:x:$new_uid:" >> $BASE_DIR/tmp/group
    # Creating the password's SHA 512 hash and appending it to shadow file in /tmp 
    local pass_hash
    pass_hash=$(openssl passwd -6 -stdin <<< "$input_pass")
    echo "$username:$pass_hash:$(( $(date +%s ) / 86400 )):0:99999:7:::" >> $BASE_DIR/tmp/shadow
    # Appending the required fields to ghsadow file in /tmp 
    echo "$username:!::" >> $BASE_DIR/tmp/gshadow
    
    task_status "Preparing user creation" "DONE"
    
    if atomic_commit "Create user $username" $BASE_DIR/tmp/{passwd,group,shadow,gshadow}; then
      task_status "Provisioning Environment" "WAIT"
      mkdir -p $BASE_DIR/home/"$username" && cp -r $BASE_DIR/etc/skel/. $BASE_DIR/home/"$username" && chown -R $new_uid:$new_uid $BASE_DIR/home/"$username" && chmod 700 $BASE_DIR/home/"$username"
      if [[ "$SYSTEM_TYPE" == "rhel" ]]; then
        restorecon -R $BASE_DIR/home/"$username" >/dev/null 2>&1
      fi
      task_status "Provisioning Environment" "DONE"
      printf "\n"
      show_success "User $username has been created successfully"
    else
      return 1
    fi
  }

  modify_account_properties () {
    draw_header "[1] USER ACTIONS > [B] MODIFY ACCOUNT"
    draw_progress "MODIFY ACCOUNT PROPERTIES"
    read -rt 180 -p "  Enter Username: " INPUT
    local username=${INPUT//[^a-zA-Z0-9_-]/}
    if ! validate_user_exists "$username"; then prompt_continue; return 1; fi

    change_default_shell () {
      draw_progress "CHANGING DEFAULT SHELL"
      printf "  %bWhich shell would you like to give to %s?%b\n\n" "$C_WHITE" "$username" "$C_RESET"
      printf "    %b[B]%b ash    %b[Z]%b sh    %b[K]%b sh\n\n" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
      read -rt 180 -p "  Enter selection: " shell_name
      local shell_name=${shell_name,,}
      local target_shell=""
      case "$shell_name" in
        b) target_shell="/bin/bash" ;;
        z) target_shell="/bin/zsh" ;;
        k) target_shell="/bin/ksh" ;;
        *) show_error "Invalid shell selection"; return 1 ;;
      esac
      
      task_status "Preparing file modification" "WAIT"
      cp $BASE_DIR/etc/passwd $BASE_DIR/tmp/passwd && chmod 600 $BASE_DIR/tmp/passwd
      sed -i "s|^\($username:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)[^:]*$|\1$target_shell|" $BASE_DIR/tmp/passwd
      task_status "Preparing file modification" "DONE"
      
      if atomic_commit "Change shell for $username" $BASE_DIR/tmp/passwd; then
         printf "\n"
         show_success "Shell updated successfully to $target_shell"
      fi
    }

    change_home_dir () {
      draw_progress "CHANGE HOME DIRECTORY"
      read -rt 180 -p "  Enter new absolute path (e.g. /home/newdir): " new_home
      if [[ ! "$new_home" = /* ]]; then
         show_error "Must be an absolute path"
         return 1
      fi
      task_status "Preparing file modification" "WAIT"
      local old_home
      old_home=$(awk -F: -v user="$username" '$1 == user {print $6}' $BASE_DIR/etc/passwd)
      cp $BASE_DIR/etc/passwd $BASE_DIR/tmp/passwd && chmod 600 $BASE_DIR/tmp/passwd
      sed -i "s|^\($username:[^:]*:[^:]*:[^:]*:[^:]*:\)[^:]*\(:[^:]*\)$|\1$new_home\2|" $BASE_DIR/tmp/passwd
      task_status "Preparing file modification" "DONE"
      
      if atomic_commit "Change home dir for $username" $BASE_DIR/tmp/passwd; then
         task_status "Moving home directory contents" "WAIT"
         if [[ -d "$BASE_DIR$old_home" ]]; then
            mkdir -p "$(dirname "$BASE_DIR$new_home")"
            mv "$BASE_DIR$old_home" "$BASE_DIR$new_home"
         else
            mkdir -p "$BASE_DIR$new_home"
            cp -r $BASE_DIR/etc/skel/. "$BASE_DIR$new_home"
            chown -R "$username":"$username" "$BASE_DIR$new_home"
         fi
         task_status "Moving home directory contents" "DONE"
         printf "\n"
         show_success "Home directory updated successfully"
      fi
    }

    change_acc_comment () {
      draw_progress "CHANGE ACCOUNT COMMENT"
      read -rt 180 -p "  Enter new comment (GECOS): " new_comment
      task_status "Preparing file modification" "WAIT"
      cp $BASE_DIR/etc/passwd $BASE_DIR/tmp/passwd && chmod 600 $BASE_DIR/tmp/passwd
      sed -i "s|^\($username:[^:]*:[^:]*:[^:]*:\)[^:]*\(:[^:]*:[^:]*\)$|\1$new_comment\2|" $BASE_DIR/tmp/passwd
      task_status "Preparing file modification" "DONE"
      if atomic_commit "Change comment for $username" $BASE_DIR/tmp/passwd; then
         printf "\n"
         show_success "Comment updated successfully"
      fi
    }

    while true; do
      draw_header "[1] USER ACTIONS > [B] MODIFY ACCOUNT"
      printf "\n"
      draw_menu_pair "[A]" "CHANGE DEFAULT SHELL" "[R]" "RETURN TO MAIN MENU"
      draw_menu_pair "[B]" "CHANGE HOME DIRECTORY" "" ""
      draw_menu_pair "[C]" "CHANGE ACCOUNT COMMENT / GECOS" "" ""
      draw_footer
      read -rt 180 -p "  SELECT ACTION: " ACTIONS
      local ACTIONS=${ACTIONS,,}
      case $ACTIONS in
        a) change_default_shell; prompt_continue;;
        b) change_home_dir; prompt_continue;;
        c) change_acc_comment; prompt_continue;;
        r) break;;
        *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
      esac
    done
  }

  reset_password () {
    draw_header "[1] USER ACTIONS > [C] RESET PASSWORD"
    draw_progress "RESET OR CHANGE USER PASSWORD"
    read -rt 180 -p "  Enter Username: " username
    if ! validate_user_exists "$username"; then prompt_continue; return 1; fi

    read -rst 180 -p "  New Password: " input_pass
    echo
    
    task_status "Generating hash & preparing modification" "WAIT"
    local pass_hash
    pass_hash=$(openssl passwd -6 -stdin <<< "$input_pass")
    cp $BASE_DIR/etc/shadow $BASE_DIR/tmp/shadow && chmod 600 $BASE_DIR/tmp/shadow
    sed -i "s|^\($username:\)[^:]*\(:.*\)|\1$pass_hash\2|" $BASE_DIR/tmp/shadow
    task_status "Generating hash & preparing modification" "DONE"
    
    if atomic_commit "Reset password for $username" $BASE_DIR/tmp/shadow; then
       printf "\n"
       show_success "Password reset successfully"
    fi
  }

  lock_unlock_user_account () {
    draw_header "[1] USER ACTIONS > [D] LOCK / UNLOCK"
    draw_progress "LOCK OR UNLOCK USER ACCOUNT"
    read -rt 180 -p "  Enter Username: " username
    if ! validate_user_exists "$username"; then prompt_continue; return 1; fi

    local current_hash
    current_hash=$(awk -F: -v u="$username" '$1==u {print $2}' $BASE_DIR/etc/shadow)
    local is_locked=false
    if [[ "$current_hash" == !* ]]; then is_locked=true; fi

    local action_msg="Account is currently "
    $is_locked && action_msg+="LOCKED." || action_msg+="UNLOCKED."
    printf "  %b%s%b\n\n" "$C_WHITE" "$action_msg" "$C_RESET"

    prompt_confirm "Toggle lock status for $username?"
    if [[ "$CONFIRMED" == true ]]; then
      task_status "Preparing shadow modification" "WAIT"
      cp $BASE_DIR/etc/shadow $BASE_DIR/tmp/shadow && chmod 600 $BASE_DIR/tmp/shadow
      if $is_locked; then
        sed -i "s|^\($username:\)!\(.*\)|\1\2|" $BASE_DIR/tmp/shadow
      else
        sed -i "s|^\($username:\)\(.*\)|\1!\2|" $BASE_DIR/tmp/shadow
      fi
      task_status "Preparing shadow modification" "DONE"
      if atomic_commit "Toggle lock for $username" $BASE_DIR/tmp/shadow; then
        printf "\n"
        show_success "Account lock status toggled successfully."
      fi
    fi
  }

  set_account_expiry () {
    draw_header "[1] USER ACTIONS > [E] SET EXPIRY"
    draw_progress "SET ACCOUNT EXPIRY DATE"
    read -rt 180 -p "  Enter Username: " username
    if ! validate_user_exists "$username"; then prompt_continue; return 1; fi

    read -rt 180 -p "  Enter Expiry Date (YYYY-MM-DD) or 'never': " exp_date
    local exp_days=""
    if [[ "$exp_date" != "never" ]]; then
       local epoch_sec
       if ! epoch_sec=$(date -d "$exp_date" +%s 2>/dev/null); then
          show_error "Invalid date format. Use YYYY-MM-DD."
          return 1
       fi
       exp_days=$(( epoch_sec / 86400 ))
    fi

    task_status "Preparing shadow modification" "WAIT"
    cp $BASE_DIR/etc/shadow $BASE_DIR/tmp/shadow && chmod 600 $BASE_DIR/tmp/shadow
    sed -i "s|^\($username:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:\)[^:]*\(:.*\)|\1$exp_days\2|" $BASE_DIR/tmp/shadow
    task_status "Preparing shadow modification" "DONE"

    if atomic_commit "Set expiry for $username" $BASE_DIR/tmp/shadow; then
       printf "\n"
       show_success "Account expiry updated successfully."
    fi
  }

  deploy_ssh_public_key () {
    draw_header "[1] USER ACTIONS > [F] DEPLOY SSH KEY"
    draw_progress "DEPLOY SSH PUBLIC KEY"
    read -rt 180 -p "  Enter Username: " username
    if ! validate_user_exists "$username"; then prompt_continue; return 1; fi

    read -rt 180 -p "  Paste Public Key string: " pub_key
    if [[ -z "$pub_key" ]]; then
       show_error "Key cannot be empty."
       return 1
    fi

    task_status "Deploying SSH Key" "WAIT"
    local homedir
    homedir=$(awk -F: -v u="$username" '$1==u {print $6}' $BASE_DIR/etc/passwd)
    local ssh_dir="$BASE_DIR$homedir/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"

    mkdir -p "$ssh_dir"
    echo "$pub_key" >> "$auth_keys"
    
    chown -R "$username":"$username" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys"
    task_status "Deploying SSH Key" "DONE"
    LOGGING_MECHANISM "user.info" "UMC: Deployed SSH key for user $username"
    printf "\n"
    show_success "SSH key deployed successfully."
  }

  delete_user () {
    draw_header "[1] USER ACTIONS > [G] DELETE USER"
    draw_progress "DELETE USER (SAFE ARCHIVE)"
    read -rt 180 -p "  Enter Username: " username
    if ! validate_user_exists "$username"; then prompt_continue; return 1; fi

    prompt_confirm "Are you sure you want to delete user $username?"
    if [[ "$CONFIRMED" == true ]]; then
       task_status "Archiving Home Directory" "WAIT"
       local homedir
       homedir=$(awk -F: -v u="$username" '$1==u {print $6}' $BASE_DIR/etc/passwd)
       local archive_path
       archive_path="$BASE_DIR/var/backups/umc/${username}_home_$(date +%F).tar.gz"
       mkdir -p "$BASE_DIR/var/backups/umc"
       if [[ -d "$BASE_DIR$homedir" ]]; then
          tar -czf "$archive_path" -C "$(dirname "$BASE_DIR$homedir")" "$(basename "$BASE_DIR$homedir")" 2>/dev/null
          rm -rf "$BASE_DIR$homedir"
       fi
       task_status "Archiving Home Directory" "DONE" "Saved to $archive_path"

       task_status "Preparing file removals" "WAIT"
       cp $BASE_DIR/etc/{passwd,shadow,group,gshadow} $BASE_DIR/tmp/
       sed -i "/^$username:/d" $BASE_DIR/tmp/passwd
       sed -i "/^$username:/d" $BASE_DIR/tmp/shadow
       sed -i "/^$username:/d" $BASE_DIR/tmp/group
       sed -i "/^$username:/d" $BASE_DIR/tmp/gshadow
       sed -i "s/,$username//g" $BASE_DIR/tmp/group
       sed -i "s/:$username/:/g" $BASE_DIR/tmp/group
       sed -i "s/,$username//g" $BASE_DIR/tmp/gshadow
       sed -i "s/:$username/:/g" $BASE_DIR/tmp/gshadow
       task_status "Preparing file removals" "DONE"

       if atomic_commit "Delete user $username" $BASE_DIR/tmp/{passwd,shadow,group,gshadow}; then
          printf "\n"
          show_success "User $username deleted successfully."
       fi
    fi
  }

  # Following is the sub-menu for USER ACTIONS
  while true; do
    draw_header "[1] USER ACTIONS"
    printf "\n"
    draw_menu_pair "[A]" "CREATE NEW USER" "[E]" "SET ACCOUNT EXPIRY"
    draw_menu_pair "[B]" "MODIFY ACCOUNT PROPERTIES" "[F]" "DEPLOY SSH PUBLIC KEY"
    draw_menu_pair "[C]" "RESET / CHANGE PASSWORD" "[G]" "DELETE USER (SAFE ARCHIVE)"
    draw_menu_pair "[D]" "LOCK / UNLOCK USER ACCOUNT" "[R]" "RETURN TO MAIN MENU"
    draw_footer
    read -rt 180 -p "  SELECT ACTION: " ACTION
    local ACTION=${ACTION,,}
    
    case $ACTION in
      a) create_new_user; prompt_continue;;
      b) modify_account_properties;;
      c) reset_password;;
      d) lock_unlock_user_account;;
      e) set_account_expiry;;
      f) deploy_ssh_public_key;;
      g) delete_user;;
      r) break;;
      *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
    esac
  done
}

GROUP_ACTIONS () {

  create_new_group () {
    draw_header "[2] GROUP ACTIONS > [A] CREATE NEW GROUP"
    draw_progress "CREATE NEW SYSTEM GROUP"
    read -rt 180 -p "  Enter Group Name: " INPUT
    local gname=${INPUT//[^a-zA-Z0-9_-]/}
    
    if grep -qE "^$gname:" "$BASE_DIR/etc/group"; then
      show_error "Group '$gname' already exists."
      return 1
    fi

    task_status "Preparing group creation" "WAIT"
    local new_gid
    new_gid=$(( $(awk -F ":" '{print $3}' "$BASE_DIR/etc/group" | sort -n | tail -1) + 1 ))
    [[ $new_gid -lt 1000 ]] && new_gid=1000

    cp "$BASE_DIR/etc/group" "$BASE_DIR/tmp/group"
    cp "$BASE_DIR/etc/gshadow" "$BASE_DIR/tmp/gshadow"
    
    echo "$gname:x:$new_gid:" >> "$BASE_DIR/tmp/group"
    echo "$gname:!::" >> "$BASE_DIR/tmp/gshadow"
    task_status "Preparing group creation" "DONE"

    if atomic_commit "Create group $gname" "$BASE_DIR/tmp/group" "$BASE_DIR/tmp/gshadow"; then
       printf "\n"
       show_success "Group $gname created successfully."
    fi
  }

  modify_group_membership () {
    draw_header "[2] GROUP ACTIONS > [B] MODIFY MEMBERSHIP"
    draw_progress "ADD OR REMOVE USER FROM GROUP"
    
    read -rt 180 -p "  Enter Group Name: " gname
    if ! validate_group_exists "$gname"; then return 1; fi

    read -rt 180 -p "  Enter Username: " uname
    if ! validate_user_exists "$uname"; then return 1; fi

    printf "  %bSelect action:%b\n" "$C_WHITE" "$C_RESET"
    printf "    %b[A]%b dd user to group\n" "$C_CYAN" "$C_RESET"
    printf "    %b[R]%b emove user from group\n\n" "$C_CYAN" "$C_RESET"
    read -rt 180 -p "  Selection: " action
    local action=${action,,}

    task_status "Preparing membership update" "WAIT"
    cp "$BASE_DIR/etc/group" "$BASE_DIR/tmp/group"
    cp "$BASE_DIR/etc/gshadow" "$BASE_DIR/tmp/gshadow"

    if [[ "$action" == "a" ]]; then
       # Add user to group
       sed -i "/^$gname:/ s/$/,$uname/" "$BASE_DIR/tmp/group"
       sed -i "/^$gname:/ s/:,/:/" "$BASE_DIR/tmp/group" # Fix empty member list comma
       sed -i "/^$gname:/ s/$/,$uname/" "$BASE_DIR/tmp/gshadow"
       sed -i "/^$gname:/ s/:,/:/" "$BASE_DIR/tmp/gshadow"
    elif [[ "$action" == "r" ]]; then
       # Remove user from group
       sed -i "/^$gname:/ s/,$uname//g" "$BASE_DIR/tmp/group"
       sed -i "/^$gname:/ s/:$uname,/:/g" "$BASE_DIR/tmp/group"
       sed -i "/^$gname:/ s/:$uname$/:/g" "$BASE_DIR/tmp/group"
       
       sed -i "/^$gname:/ s/,$uname//g" "$BASE_DIR/tmp/gshadow"
       sed -i "/^$gname:/ s/:$uname,/:/g" "$BASE_DIR/tmp/gshadow"
       sed -i "/^$gname:/ s/:$uname$/:/g" "$BASE_DIR/tmp/gshadow"
    else
       task_status "Preparing membership update" "FAIL"
       show_error "Invalid action selected."
       return 1
    fi
    task_status "Preparing membership update" "DONE"

    if atomic_commit "Modify group $gname membership for $uname" "$BASE_DIR/tmp/group" "$BASE_DIR/tmp/gshadow"; then
       printf "\n"
       show_success "Group membership updated successfully."
    fi
  }

  remove_group () {
    draw_header "[2] GROUP ACTIONS > [C] REMOVE GROUP"
    draw_progress "DELETE A SYSTEM GROUP"
    
    read -rt 180 -p "  Enter Group Name: " gname
    if ! validate_group_exists "$gname"; then return 1; fi

    local gid
    gid=$(awk -F: -v g="$gname" '$1==g {print $3}' "$BASE_DIR/etc/group")
    if awk -F: -v g="$gid" '$4==g {found=1} END {if (found) exit 0; else exit 1}' "$BASE_DIR/etc/passwd"; then
       show_error "Cannot remove group: it is the primary group of one or more users."
       return 1
    fi

    prompt_confirm "Are you sure you want to delete group $gname?"
    if [[ "$CONFIRMED" == true ]]; then
       task_status "Preparing group removal" "WAIT"
       cp "$BASE_DIR/etc/group" "$BASE_DIR/tmp/group"
       cp "$BASE_DIR/etc/gshadow" "$BASE_DIR/tmp/gshadow"
       
       sed -i "/^$gname:/d" "$BASE_DIR/tmp/group"
       sed -i "/^$gname:/d" "$BASE_DIR/tmp/gshadow"
       task_status "Preparing group removal" "DONE"

       if atomic_commit "Remove group $gname" "$BASE_DIR/tmp/group" "$BASE_DIR/tmp/gshadow"; then
          printf "\n"
          show_success "Group $gname removed successfully."
       fi
    fi
  }

  configure_sudoers () {
    draw_header "[2] GROUP ACTIONS > [D] CONFIGURE SUDOERS"
    draw_progress "GRANT SUDO PRIVILEGES"
    
    read -rt 180 -p "  Enter Username: " uname
    if ! validate_user_exists "$uname"; then return 1; fi

    prompt_confirm "Grant passwordless sudo to $uname?"
    local sudo_line=""
    if [[ "$CONFIRMED" == true ]]; then
       sudo_line="$uname ALL=(ALL) NOPASSWD:ALL"
    else
       sudo_line="$uname ALL=(ALL) ALL"
    fi

    task_status "Configuring sudoers file" "WAIT"
    local sudoers_dir="$BASE_DIR/etc/sudoers.d"
    mkdir -p "$sudoers_dir"
    echo "$sudo_line" > "$sudoers_dir/$uname"
    chmod 0440 "$sudoers_dir/$uname"
    task_status "Configuring sudoers file" "DONE"
    
    LOGGING_MECHANISM "user.info" "UMC: Sudoers configured for user $uname"
    printf "\n"
    show_success "Sudo privileges granted for $uname."
  }

  # Following is the sub-menu for GROUP ACTIONS 
  while true; do
    draw_header "[2] GROUP ACTIONS"
    printf "\n"
    draw_menu_pair "[A]" "CREATE NEW GROUP" "[D]" "CONFIGURE SUDOERS"
    draw_menu_pair "[B]" "MODIFY GROUP MEMBERSHIP" "[R]" "RETURN TO MAIN MENU"
    draw_menu_pair "[C]" "REMOVE GROUP" "" ""
    draw_footer
    read -rt 180 -p "  SELECT ACTION: " ACTION
    local ACTION=${ACTION,,}
    
    case $ACTION in
      a) create_new_group; prompt_continue;;
      b) modify_group_membership; prompt_continue;;
      c) remove_group; prompt_continue;;
      d) configure_sudoers; prompt_continue;;
      r) break;;
      *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
    esac
  done

}

SECURITY_AND_AUDIT () {

  enforce_password_complexity () {
    draw_header "[3] SECURITY & AUDIT > [A] PASSWORD COMPLEXITY"
    draw_progress "ENFORCE PASSWORD COMPLEXITY POLICIES"
    
    local login_defs="$BASE_DIR/etc/login.defs"
    if [[ ! -f "$login_defs" ]]; then
       touch "$login_defs"
    fi

    read -rt 180 -p "  Enter Minimum Password Length (e.g. 12): " min_len
    read -rt 180 -p "  Enter Maximum Days between changes (e.g. 90): " max_days

    task_status "Configuring login.defs" "WAIT"
    
    if grep -q "^PASS_MIN_LEN" "$login_defs"; then
       sed -i "s/^PASS_MIN_LEN.*/PASS_MIN_LEN    $min_len/" "$login_defs"
    else
       echo "PASS_MIN_LEN    $min_len" >> "$login_defs"
    fi

    if grep -q "^PASS_MAX_DAYS" "$login_defs"; then
       sed -i "s/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   $max_days/" "$login_defs"
    else
       echo "PASS_MAX_DAYS   $max_days" >> "$login_defs"
    fi

    task_status "Configuring login.defs" "DONE"
    LOGGING_MECHANISM "user.info" "UMC: Password complexity enforced (MinLen:$min_len, MaxDays:$max_days)"
    printf "\n"
    show_success "Password complexity policies updated."
  }

  global_account_audit () {
    draw_header "[3] SECURITY & AUDIT > [B] GLOBAL AUDIT"
    draw_progress "GLOBAL ACCOUNT AUDIT"
    
    printf "  %b[ Auditing Accounts with UID 0 ]%b\n" "$C_CYAN" "$C_RESET"
    local uid0_users
    uid0_users=$(awk -F: '$3 == "0" {print $1}' "$BASE_DIR/etc/passwd")
    for u in $uid0_users; do
      if [[ "$u" != "root" ]]; then
         printf "    %bWARNING:%b User %s has UID 0 (Root Privileges)\n" "$C_YELLOW" "$C_RESET" "$u"
      fi
    done

    printf "\n  %b[ Auditing Accounts with Empty Passwords ]%b\n" "$C_CYAN" "$C_RESET"
    local empty_pass
    empty_pass=$(awk -F: '$2 == "" || $2 == "*" || $2 == "!" {print $1}' "$BASE_DIR/etc/shadow")
    for u in $empty_pass; do
      printf "    %bWARNING:%b User %s has no usable password.\n" "$C_YELLOW" "$C_RESET" "$u"
    done

    printf "\n"
    task_status "Global Audit Completed" "DONE"
  }

  sync_passwd_and_shadow () {
    draw_header "[3] SECURITY & AUDIT > [C] SYNC FILES"
    draw_progress "SYNC PASSWD & SHADOW FILES"

    task_status "Checking for discrepancies" "WAIT"
    local out_of_sync=false
    
    for u in $(awk -F: '{print $1}' "$BASE_DIR/etc/passwd"); do
      if ! grep -q "^$u:" "$BASE_DIR/etc/shadow"; then
         printf "  %bISSUE:%b User %s missing from shadow file.\n" "$C_RED" "$C_RESET" "$u"
         out_of_sync=true
      fi
    done

    for u in $(awk -F: '{print $1}' "$BASE_DIR/etc/shadow"); do
      if ! grep -q "^$u:" "$BASE_DIR/etc/passwd"; then
         printf "  %bISSUE:%b User %s missing from passwd file.\n" "$C_RED" "$C_RESET" "$u"
         out_of_sync=true
      fi
    done

    if $out_of_sync; then
       task_status "Checking for discrepancies" "FAIL"
       show_error "Discrepancies found! Manual intervention recommended."
    else
       task_status "Checking for discrepancies" "DONE"
       printf "\n"
       show_success "No discrepancies found. Passwd & Shadow are synced."
    fi
  }

  directory_integrity_check () {
    draw_header "[3] SECURITY & AUDIT > [D] DIR INTEGRITY"
    draw_progress "DIRECTORY INTEGRITY CHECK"
    
    task_status "Scanning /home directories" "WAIT"
    local issues=0
    
    for dir in "$BASE_DIR/home"/*; do
      if [[ -d "$dir" ]]; then
         local owner
         owner=$(stat -c '%U' "$dir" 2>/dev/null)
         local perms
         perms=$(stat -c '%a' "$dir" 2>/dev/null)
         local dname
         dname=$(basename "$dir")
         
         if [[ "$owner" != "$dname" && "$owner" != "UNKNOWN" ]]; then
            printf "  %bWARNING:%b %s is owned by %s (Expected: %s)\n" "$C_YELLOW" "$C_RESET" "$dir" "$owner" "$dname"
            issues=$((issues+1))
         fi
         
         if [[ "$perms" != "700" && "$perms" != "755" && "$perms" != "750" ]]; then
            printf "  %bWARNING:%b %s has unsafe permissions: %s\n" "$C_YELLOW" "$C_RESET" "$dir" "$perms"
            issues=$((issues+1))
         fi
      fi
    done
    
    task_status "Scanning /home directories" "DONE"
    
    printf "\n"
    if [[ $issues -eq 0 ]]; then
       show_success "All home directories passed integrity check."
    else
       show_error "Found $issues integrity warnings."
    fi
  }

  # Following is the sub-menu for SECURITY & AUDIT
  while true; do
    draw_header "[3] SECURITY & AUDIT"
    printf "\n"
    draw_menu_pair "[A]" "ENFORCE PASSWORD COMPLEXITY" "[D]" "DIRECTORY INTEGRITY CHECK"
    draw_menu_pair "[B]" "GLOBAL ACCOUNT AUDIT" "[R]" "RETURN TO MAIN MENU"
    draw_menu_pair "[C]" "SYNC PASSWD & SHADOW" "" ""
    draw_footer
    read -rt 180 -p "  SELECT ACTION: " ACTION
    local ACTION=${ACTION,,}
    
    case $ACTION in
      a) enforce_password_complexity; prompt_continue;;
      b) global_account_audit; prompt_continue;;
      c) sync_passwd_and_shadow; prompt_continue;;
      d) directory_integrity_check; prompt_continue;;
      r) break;;
      *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
    esac
  done

}

BULK_OPERATION () {

  import_from_csv_json () {
    draw_header "[4] BULK OPERATIONS > [A] IMPORT USERS"
    draw_progress "IMPORT FROM CSV"
    
    read -rt 180 -p "  Enter absolute path to CSV file: " csv_file
    if [[ ! -f "$csv_file" ]]; then
       show_error "File not found."
       return 1
    fi
    
    printf "  %bFormat expected: username,password,comment%b\n\n" "$C_CYAN" "$C_RESET"
    prompt_confirm "Proceed with import?"
    if [[ "$CONFIRMED" == true ]]; then
       task_status "Preparing bulk import" "WAIT"
       cp "$BASE_DIR/etc/passwd" "$BASE_DIR/tmp/passwd"
       cp "$BASE_DIR/etc/shadow" "$BASE_DIR/tmp/shadow"
       cp "$BASE_DIR/etc/group" "$BASE_DIR/tmp/group"
       cp "$BASE_DIR/etc/gshadow" "$BASE_DIR/tmp/gshadow"
       chmod 600 "$BASE_DIR/tmp/"{passwd,shadow,group,gshadow}
       
       local imported=0
       while IFS=, read -r uname pass comment || [ -n "$uname" ]; do
          [[ -z "$uname" || "$uname" == "username" ]] && continue
          
          if grep -qE "^$uname:" "$BASE_DIR/tmp/passwd"; then
             continue
          fi
          
          local new_uid
          new_uid=$(( $(awk -F ":" '{print $3}' "$BASE_DIR/tmp/passwd" | sort -n | tail -1) + 1 ))
          [[ $new_uid -lt 1000 ]] && new_uid=1000
          
          echo "$uname:x:$new_uid:$new_uid:$comment:/home/$uname:/bin/bash" >> "$BASE_DIR/tmp/passwd"
          echo "$uname:x:$new_uid:" >> "$BASE_DIR/tmp/group"
          
          local pass_hash
          pass_hash=$(openssl passwd -6 -stdin <<< "$pass")
          echo "$uname:$pass_hash:$(( $(date +%s ) / 86400 )):0:99999:7:::" >> "$BASE_DIR/tmp/shadow"
          echo "$uname:!::" >> "$BASE_DIR/tmp/gshadow"
          
          imported=$((imported+1))
       done < "$csv_file"
       
       task_status "Preparing bulk import" "DONE"
       
       if [[ $imported -eq 0 ]]; then
          show_error "No new valid users found to import."
       else
          if atomic_commit "Bulk import $imported users" "$BASE_DIR/tmp/"{passwd,shadow,group,gshadow}; then
             printf "\n"
             show_success "Successfully imported $imported users."
             LOGGING_MECHANISM "user.info" "UMC: Bulk imported $imported users from $csv_file"
          fi
       fi
    fi
  }

  export_user_list_to_csv () {
    draw_header "[4] BULK OPERATIONS > [B] EXPORT USERS"
    draw_progress "EXPORT USER LIST TO CSV"
    
    local export_path
    export_path="$BASE_DIR/var/backups/umc/user_export_$(date +%F).csv"
    mkdir -p "$BASE_DIR/var/backups/umc"
    
    task_status "Generating CSV report" "WAIT"
    echo "username,uid,gid,home,shell,comment" > "$export_path"
    awk -F: '$3 >= 1000 {print $1","$3","$4","$6","$7","$5}' "$BASE_DIR/etc/passwd" >> "$export_path"
    task_status "Generating CSV report" "DONE"
    
    printf "\n"
    show_success "User list exported to $export_path"
    LOGGING_MECHANISM "user.info" "UMC: Exported user list to $export_path"
  }

  clean_orphaned_home_dirs () {
    draw_header "[4] BULK OPERATIONS > [C] CLEAN ORPHANED HOMES"
    draw_progress "CLEAN ORPHANED HOME DIRECTORIES"
    
    task_status "Scanning for orphaned directories" "WAIT"
    local orphaned=()
    for dir in "$BASE_DIR/home"/*; do
      if [[ -d "$dir" ]]; then
         local dname
         dname=$(basename "$dir")
         if ! grep -q "^$dname:" "$BASE_DIR/etc/passwd"; then
            orphaned+=("$dir")
         fi
      fi
    done
    task_status "Scanning for orphaned directories" "DONE"
    
    if [[ ${#orphaned[@]} -eq 0 ]]; then
       printf "\n"
       show_success "No orphaned home directories found."
       return 0
    fi
    
    printf "\n  %bFound %d orphaned directories:%b\n" "$C_CYAN" "${#orphaned[@]}" "$C_RESET"
    for dir in "${orphaned[@]}"; do
      printf "    %b- %s%b\n" "$C_YELLOW" "$dir" "$C_RESET"
    done
    printf "\n"
    
    prompt_confirm "Delete these orphaned directories?"
    if [[ "$CONFIRMED" == true ]]; then
       task_status "Deleting directories" "WAIT"
       for dir in "${orphaned[@]}"; do
          rm -rf "$dir"
       done
       task_status "Deleting directories" "DONE"
       printf "\n"
       show_success "Orphaned directories removed."
       LOGGING_MECHANISM "user.info" "UMC: Cleaned ${#orphaned[@]} orphaned home directories"
    fi
  }

  # Following is the sub-menu for BULK OPERATIONS
  while true; do
    draw_header "[4] BULK OPERATIONS"
    printf "\n"
    draw_menu_pair "[A]" "IMPORT FROM CSV/JSON" "[R]" "RETURN TO MAIN MENU"
    draw_menu_pair "[B]" "EXPORT USER LIST TO CSV" "" ""
    draw_menu_pair "[C]" "CLEAN ORPHANED HOME DIRs" "" ""
    draw_footer
    read -rt 180 -p "  SELECT ACTION: " ACTION
    local ACTION=${ACTION,,}
    
    case $ACTION in
      a) import_from_csv_json; prompt_continue;;
      b) export_user_list_to_csv; prompt_continue;;
      c) clean_orphaned_home_dirs; prompt_continue;;
      r) break;;
      *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
    esac
  done
}

SYSTEM_LOGS () {

  view_script_activity_log () {
    draw_header "[5] SYSTEM LOGS > [A] ACTIVITY LOG"
    draw_progress "VIEW SCRIPT ACTIVITY LOG"
    
    printf "  %bRecent Activity Logs (via journalctl):%b\n\n" "$C_CYAN" "$C_RESET"
    journalctl -t umc-script --no-pager -n 20 2>/dev/null | awk '{print "    "$0}'
    
    printf "\n"
  }

  restore_backup () {
    draw_header "[5] SYSTEM LOGS > [B] RESTORE BACKUP"
    draw_progress "RESTORE SYSTEM FILES FROM BACKUP"
    
    local backup_dir="$BASE_DIR/var/backups/umc"
    if [[ ! -d "$backup_dir" ]]; then
       show_error "Backup directory not found."
       return 1
    fi
    
    # shellcheck disable=SC2012
    local backups
    mapfile -t backups < <(ls -1t "$backup_dir"/*.tar.gz 2>/dev/null)
    
    if [[ ${#backups[@]} -eq 0 ]]; then
       show_error "No backups found."
       return 1
    fi
    
    printf "  %bAvailable Backups:%b\n" "$C_CYAN" "$C_RESET"
    local i=1
    for b in "${backups[@]}"; do
       printf "    %b[%d]%b %s\n" "$C_YELLOW" "$i" "$C_RESET" "$(basename "$b")"
       i=$((i+1))
    done
    printf "\n"
    
    read -rt 180 -p "  Select backup to restore (1-${#backups[@]}): " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#backups[@]}" ]; then
       local selected="${backups[$((sel-1))]}"
       prompt_confirm "Are you sure you want to restore $(basename "$selected")?"
       if [[ "$CONFIRMED" == true ]]; then
          task_status "Restoring files" "WAIT"
          tar -xzPf "$selected"
          task_status "Restoring files" "DONE"
          LOGGING_MECHANISM "user.warn" "UMC: Restored system files from backup $selected"
          printf "\n"
          show_success "System files restored successfully."
       fi
    else
       show_error "Invalid selection."
    fi
  }

  check_file_lock () {
    draw_header "[5] SYSTEM LOGS > [C] CHECK FILE LOCK"
    draw_progress "CHECK ACTIVE FILE LOCKS"
    
    if [[ -f "$LOCK_FILE" ]]; then
       local pid
       pid=$(cat "$LOCK_FILE")
       printf "  %bLock File Exists:%b %s\n" "$C_CYAN" "$C_RESET" "$LOCK_FILE"
       if kill -0 "$pid" 2>/dev/null; then
          printf "  %bStatus:%b %bActive%b (PID: %d)\n\n" "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET" "$pid"
          show_error "Another instance is actively running."
       else
          printf "  %bStatus:%b %bStale%b (Dead PID: %d)\n\n" "$C_CYAN" "$C_RESET" "$C_RED" "$C_RESET" "$pid"
          prompt_confirm "Remove stale lock?"
          if [[ "$CONFIRMED" == true ]]; then
             rm -f "$LOCK_FILE"
             show_success "Stale lock removed."
          fi
       fi
    else
       show_success "No lock file found."
    fi
  }

  # Following is the sub-menu for SYSTEM LOGS
  while true; do
    draw_header "[5] SYSTEM LOGS"
    printf "\n"
    draw_menu_pair "[A]" "VIEW SCRIPT ACTIVITY LOG" "[R]" "RETURN TO MAIN MENU"
    draw_menu_pair "[B]" "RESTORE BACKUP" "" ""
    draw_menu_pair "[C]" "CHECK FILE LOCKS" "" ""
    draw_footer
    read -rt 180 -p "  SELECT ACTION: " ACTION
    local ACTION=${ACTION,,}
    
    case $ACTION in
      a) view_script_activity_log; prompt_continue;;
      b) restore_backup; prompt_continue;;
      c) check_file_lock; prompt_continue;;
      r) break;;
      *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
    esac
  done

}

MAIN_MENU () {
  while true; do
    draw_header ""
    printf "\n"
    draw_menu_item "[1]" "USER ACTIONS" "Add, Modify, Delete, Lock, Passwords, SSH"
    draw_menu_item "[2]" "GROUP ACTIONS" "Add, Modify, Delete, Sudoers Assignment"
    draw_menu_item "[3]" "SECURITY & AUDIT" "Policy Enforcement, Integrity Checks"
    draw_menu_item "[4]" "BULK OPERATIONS" "CSV Import/Export, Orphan Cleanup"
    draw_menu_item "[5]" "SYSTEM LOGS" "Action Audit Trails, Lock Status, Backups"
    printf "\n"
    draw_menu_item "[0]" "QUIT CONSOLE" "Safe Exit & Environment Cleanup"
    printf "\n"
    draw_line "═"
    read -rt 180 -p "  ENTER SELECTION: " selection 
    
    case $selection in
      1) USER_ACTIONS;;
      2) GROUP_ACTIONS;;
      3) SECURITY_AND_AUDIT;;
      4) BULK_OPERATION;;
      5) SYSTEM_LOGS;;
      0) break;;
      *) show_error "Enter a valid option!"; read -p "  Press any key to retry..." -n 1 -r;;
    esac
  done
}

MAIN_MENU
