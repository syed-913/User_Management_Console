# User Management Console (UMC) 🛡️

A comprehensive, interactive, and highly robust Bash script designed to manage Linux users, groups, security policies, and bulk operations. 

> [!WARNING]  
> **Learning & Demonstration Purposes Only**  
> This script was developed primarily as a personal project to showcase expertise in advanced Bash scripting, file atomicity, and terminal UI automation. It has **not** been battle-tested in a real-world enterprise environment and should not be used in a production organization without thorough review.

## 🧪 Testing Environments
This script has been successfully tested on the following Vagrant boxes:
- **Ubuntu 24.04**
- **RHEL 9**
- **Debian 12**
- **Rocky 9**

*You can take a look at Vagrantfile in this repository*

---

## 🌟 Key Features & Expertise Demonstrated

This project intentionally avoids standard high-level binaries (like `useradd` or `usermod`) where possible, opting instead to directly and safely manipulate system files (`/etc/passwd`, `/etc/shadow`, etc.) to demonstrate a deep understanding of Linux system internals.

### 1. File Atomicity & Integrity Checks (`atomic_commit`)
To prevent system corruption, the script never edits live configuration files.
- All modifications are performed on temporary copies in `/tmp/`.
- Native `pwck` and `grpck` (in read-only mode) and structural `awk` column-checks validate the integrity of the temporary files.
- Only if the files pass all validation checks are they atomically swapped (`mv`) into `/etc/`.

### 2. Dry Run Mode (`--dry-run`)
Allows administrators to simulate operations without modifying disk state.
- Intercepts the `atomic_commit` and outputs a colorized `diff -u` showing exactly what lines *would* be changed.
- Safely bypasses destructive commands (e.g., environment provisioning, archiving, directory removal).

### 3. Automated Backups & Log Rotation
- **Idempotent Backups**: Every successful atomic commit triggers a `.tar.gz` backup of the core configuration files to `/var/backups/umc/`.
- **Log Rotation**: The boot initialization sequence automatically utilizes `find` to purge backup archives older than 30 days to prevent disk bloat.
- **Audit Trails**: All actions are logged to the system journal (`journalctl`) using the `logger` utility with appropriate severity levels.

### 4. Interactive & Animated UI
- A polished, cursor-driven terminal user interface utilizing ANSI escape codes (`\033`).
- Reusable UI helper functions (`draw_progress`, `task_status`, `show_success`) that provide staggered, animated feedback during operations.
- Centralized prompt handlers (`prompt_for_existing_user`) handle input sanitization and existence validation loops globally to keep code DRY (Don't Repeat Yourself).

### 5. Comprehensive Module Coverage
- **User Actions**: Provision environments (create users, `skel` copy, `chown`, `chmod 700`, SELinux `restorecon`), change shells, migrate home directories, reset passwords (via `openssl passwd -6`), lock/unlock accounts, set expirations, and securely deploy SSH keys.
- **Group Actions**: Create groups, manage group membership across both `group` and `gshadow` files, and safely assign passwordless `sudo` privileges via `/etc/sudoers.d/`.
- **Security & Audit**: Enforce `login.defs` password complexity, perform global audits (identifying unauthorized `UID 0` or empty password accounts), and scan `/home/` directories for permission violations or orphaned owners.
- **Bulk Operations**: Perform batch imports from CSV/JSON formats, generate user list reports, and clean up orphaned home directories.

---

## 🚀 Usage

Run the script with root privileges (enforced on boot):

```bash
# Launch the interactive console
sudo ./umc.sh

# Launch the console in Dry Run mode to preview changes
sudo ./umc.sh --dry-run
```

## 📜 Script Architecture

The script follows a monolithic, procedural architecture:
1. **Boot Checks**: Enforces `0077` umask, checks `EUID == 0`, identifies the host OS, checks for active file locks (`/var/lock/umc.lock`), and rotates old backups.
2. **Helper Library**: Contains the UI framework, prompt standardizations, system logging functions, and the core `atomic_commit` logic.
3. **Sub-Modules**: `USER_ACTIONS`, `GROUP_ACTIONS`, `SECURITY_AND_AUDIT`, `BULK_OPERATION`, and `SYSTEM_LOGS`.
4. **Main Loop**: Evaluates user input and routes to the appropriate sub-module.
