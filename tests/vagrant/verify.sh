#!/usr/bin/env bash
# Boots each test VM in turn, runs the test-suite inside it (including the
# VM-only end-to-end tests), destroys the VM, and removes everything THIS RUN
# downloaded or created. Anything that existed before the run is left alone.
#
#   tests/vagrant/verify.sh libvirt                     every box (rhel9 only with RHSM_USERNAME/RHSM_PASSWORD)
#   tests/vagrant/verify.sh libvirt rocky9 debian12     selected boxes
#   tests/vagrant/verify.sh --smoke virtualbox          quick check: does each box boot and run UMC?
#   --keep-downloads                                    keep the boxes this run downloaded
#   --keep-network NAME                                 leave this libvirt network defined (stopped) afterwards
#
# Cleanup rules (checked against a snapshot taken before the first VM boots):
#   * each VM is destroyed right after its tests, also on failure or Ctrl-C
#   * Vagrant boxes that were not installed before are removed
#   * libvirt: box image volumes that were not in the pool before are deleted
#     (vagrant-libvirt copies each box into the pool; 'vagrant box remove'
#     alone would leave that copy behind), and libvirt networks are returned to
#     the state they were in: definitions of pre-existing networks are saved
#     first and restored if anything deletes them; running/stopped state and
#     autostart are restored; networks new to this run are removed if unused
#     (unless named with --keep-network, which leaves them defined but stopped -
#     re-defined if needed: vagrant-libvirt 0.12 deletes a management network it
#     created itself on every destroy, whatever management_network_keep says)
#
# Exit status: 0 when every box passed (or was skipped), 1 when any failed.
# Logs: tests/.cache/vm/   Report: evidence/E-16-vm-end-to-end.md (full mode)
set -uo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit "${1:-0}"; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo" || exit 1

mode=full keep=false provider="" boxes=() keepnets=()
while (($#)); do
    case $1 in
        --smoke) mode=smoke ;;
        --keep-downloads) keep=true ;;
        --keep-network) [[ -n ${2:-} ]] || usage 2; keepnets+=("$2"); shift ;;
        -h|--help) usage 0 ;;
        -*) echo "unknown option $1" >&2; usage 2 ;;
        *) if [[ -z $provider ]]; then provider=$1; else boxes+=("$1"); fi ;;
    esac
    shift
done
[[ -n $provider ]] || usage 2
command -v vagrant >/dev/null || { echo "vagrant is not installed" >&2; exit 2; }
if ((${#boxes[@]} == 0)); then
    mapfile -t boxes < <(ruby -e 'eval(File.read("Vagrantfile")[/^BOXES = \{.*?^\}/m]); puts BOXES.keys')
fi
out=$repo/tests/.cache/vm
mkdir -p "$out"

LV=(virsh -c qemu:///system)
box_list() {
    vagrant box list --machine-readable 2>/dev/null |
        awk -F, '$3 == "box-name" { n = $4 } $3 == "box-provider" { p = $4 } $3 == "box-version" { print n "|" p "|" $4 }'
}
vol_list() { "${LV[@]}" vol-list --pool default 2>/dev/null | awk 'NR > 2 && NF { print $1 }'; }
net_list() { "${LV[@]}" net-list --all 2>/dev/null | awk 'NR > 2 && NF { print $1 "|" $2 "|" $3 }'; }
in_list() { local x=$1 e; shift; for e; do [[ $e == "$x" ]] && return 0; done; return 1; }

# --- snapshot: what exists now is never removed -------------------------------------
mapfile -t BOX0 < <(box_list)
VOL0=() NET0=()
if [[ $provider == libvirt ]]; then
    mapfile -t VOL0 < <(vol_list)
    mapfile -t NET0 < <(net_list)
    for e in "${NET0[@]}"; do                 # save definitions, to restore anything that gets deleted
        "${LV[@]}" net-dumpxml --inactive "${e%%|*}" > "$out/net-${e%%|*}.xml" 2>/dev/null
    done
fi

cleanup_downloads() {
    $keep && return 0
    local e n p v vol
    while IFS= read -r e; do
        [[ -n $e ]] || continue
        in_list "$e" "${BOX0[@]}" && continue
        IFS='|' read -r n p v <<< "$e"
        echo "    cleanup: removing box $n ($p $v), downloaded by this run"
        vagrant box remove "$n" --provider "$p" --box-version "$v" --force >/dev/null 2>&1 ||
            echo "    ! could not remove box $n $v - remove it with: vagrant box remove $n --box-version $v"
    done < <(box_list)
    [[ $provider == libvirt ]] || return 0
    while IFS= read -r vol; do
        [[ -n $vol ]] || continue
        in_list "$vol" "${VOL0[@]}" && continue
        if [[ $vol == *_vagrant_box_image_* ]]; then
            echo "    cleanup: deleting libvirt image volume $vol (created by this run)"
            "${LV[@]}" vol-delete --pool default "$vol" >/dev/null 2>&1 ||
                echo "    ! could not delete volume $vol - delete it with: virsh -c qemu:///system vol-delete --pool default $vol"
        else
            echo "    ! new volume $vol is not a box image (a VM disk?) - left in place, please check it"
        fi
    done < <(vol_list)
}

save_keepnets() {   # remember --keep-network definitions while they exist
    [[ $provider == libvirt ]] || return 0
    local n
    for n in "${keepnets[@]}"; do
        "${LV[@]}" net-dumpxml --inactive "$n" > "$out/keepnet-$n.xml.tmp" 2>/dev/null &&
            mv -f "$out/keepnet-$n.xml.tmp" "$out/keepnet-$n.xml"
        rm -f "$out/keepnet-$n.xml.tmp"
    done
}
net_in_use() {   # NAME: is any defined domain attached to this network?
    local d
    while IFS= read -r d; do
        [[ -n $d ]] || continue
        "${LV[@]}" domiflist "$d" 2>/dev/null | awk 'NR > 2 { print $3 }' | grep -qx -- "$1" && return 0
    done < <("${LV[@]}" list --all --name 2>/dev/null)
    return 1
}
cleanup_networks() {
    [[ $provider == libvirt ]] || return 0
    local e n st auto b0 st0 auto0 now=()
    mapfile -t now < <(net_list)
    # 1. pre-existing networks: back to exactly how they were
    for b0 in "${NET0[@]}"; do
        IFS='|' read -r n st0 auto0 <<< "$b0"
        st=""
        for e in "${now[@]}"; do [[ ${e%%|*} == "$n" ]] && { IFS='|' read -r _ st auto <<< "$e"; }; done
        if [[ -z $st ]]; then
            echo "    cleanup: restoring libvirt network $n (it existed before this run and was deleted)"
            "${LV[@]}" net-define "$out/net-$n.xml" >/dev/null 2>&1 || { echo "    ! could not restore network $n from $out/net-$n.xml"; continue; }
            [[ $auto0 == yes ]] && "${LV[@]}" net-autostart "$n" >/dev/null 2>&1
            [[ $st0 == active ]] && "${LV[@]}" net-start "$n" >/dev/null 2>&1
            continue
        fi
        net_in_use "$n" && continue
        if [[ $st0 == inactive && $st == active ]]; then
            echo "    cleanup: stopping libvirt network $n again (it was stopped before this run)"
            "${LV[@]}" net-destroy "$n" >/dev/null 2>&1
        elif [[ $st0 == active && $st == inactive ]]; then
            "${LV[@]}" net-start "$n" >/dev/null 2>&1
        fi
        if [[ $auto0 != "$auto" ]]; then
            if [[ $auto0 == yes ]]; then "${LV[@]}" net-autostart "$n" >/dev/null 2>&1; else "${LV[@]}" net-autostart --disable "$n" >/dev/null 2>&1; fi
        fi
    done
    # 2. networks created by this run
    for e in "${now[@]}"; do
        IFS='|' read -r n st auto <<< "$e"
        for b0 in "${NET0[@]}"; do [[ ${b0%%|*} == "$n" ]] && continue 2; done
        net_in_use "$n" && continue
        if in_list "$n" "${keepnets[@]}"; then
            echo "    cleanup: leaving libvirt network $n defined but stopped (--keep-network)"
            "${LV[@]}" net-destroy "$n" >/dev/null 2>&1
            "${LV[@]}" net-autostart --disable "$n" >/dev/null 2>&1
            continue
        fi
        echo "    cleanup: removing libvirt network $n (created by this run)"
        "${LV[@]}" net-destroy "$n" >/dev/null 2>&1; "${LV[@]}" net-undefine "$n" >/dev/null 2>&1
    done
    # 3. --keep-network networks that were created and then deleted again during the run
    for n in "${keepnets[@]}"; do
        "${LV[@]}" net-info "$n" >/dev/null 2>&1 && continue
        for b0 in "${NET0[@]}"; do [[ ${b0%%|*} == "$n" ]] && continue 2; done   # handled in 1.
        [[ -s $out/keepnet-$n.xml ]] || continue
        echo "    cleanup: re-defining libvirt network $n, stopped (--keep-network; vagrant-libvirt deleted it on destroy)"
        "${LV[@]}" net-define "$out/keepnet-$n.xml" >/dev/null 2>&1 ||
            echo "    ! could not re-define network $n from $out/keepnet-$n.xml"
    done
}

CURRENT=""
finish() {
    if [[ -n $CURRENT ]]; then
        echo "    cleanup: destroying VM $CURRENT"
        save_keepnets
        UMC_BOXES=$CURRENT vagrant destroy -f "$CURRENT" >/dev/null 2>&1
        CURRENT=""
    fi
    cleanup_downloads
    cleanup_networks
}
trap 'finish; exit 130' INT TERM
trap finish EXIT

DLERR='could not be found or could not be accessed in the remote catalog|Could not resolve host|Failed to connect to|An error occurred while downloading'
declare -A RES=() SEL=() E2E=() CNT=()
for b in "${boxes[@]}"; do
    log=$out/$b.$mode.log
    : > "$log"
    if [[ $b == rhel9 && -z ${RHSM_USERNAME:-} ]]; then
        RES[$b]="skipped: needs a Red Hat subscription (RHSM_USERNAME/RHSM_PASSWORD)"
        echo "==> $b: skipped (no Red Hat subscription credentials)"
        continue
    fi
    echo "==> $b: booting ($provider) - log: ${log#"$repo"/}"
    CURRENT=$b
    booted=false dlfail=false
    for try in 1 2; do               # a failed download (network) gets one more try; a box that does not boot does not
        from=$(($(wc -l < "$log") + 1))
        UMC_BOXES=$b vagrant up "$b" --provider="$provider" >>"$log" 2>&1 && { booted=true; break; }
        if tail -n "+$from" "$log" | grep -qE "$DLERR"; then dlfail=true; else dlfail=false; break; fi
        ((try == 1)) && { echo "    $b: the box download failed - trying again in 60 s"; sleep 60; }
    done
    if $booted; then
        SEL[$b]=$(grep -oE 'SELinux: [A-Za-z]+' "$log" | tail -1 | cut -d' ' -f2)
        echo "==> $b: running the $mode tests"
        if [[ $mode == smoke ]]; then
            UMC_BOXES=$b vagrant provision "$b" --provision-with smoke >>"$log" 2>&1
            if grep -q 'SMOKE: PASS' "$log"; then RES[$b]="PASS"; else RES[$b]="FAIL (smoke test)"; fi
        else
            UMC_BOXES=$b vagrant provision "$b" --provision-with test >>"$log" 2>&1
            pass=$(grep -cE ': ok [0-9]+ ' "$log"); fail=$(grep -cE ': not ok [0-9]+ ' "$log"); skip=$(grep -cE ': ok [0-9]+ .*# skip' "$log")
            CNT[$b]="$pass passed ($skip skipped), $fail failed"
            if ((fail == 0 && pass > 0)); then RES[$b]="PASS"; else RES[$b]="FAIL"; fi
            E2E[$b]=$(grep -E ': (not )?ok [0-9]+ (F-03 /|F-19 /|journald|the onboarding sweep)' "$log" | sed -E 's/^.*: ((not )?ok [0-9]+ )/\1/')
        fi
    elif $dlfail; then
        RES[$b]="FAIL (the box could not be downloaded - network or catalogue problem, see the log)"
    else
        RES[$b]="FAIL (the box did not boot)"
    fi
    echo "==> $b: ${RES[$b]}${CNT[$b]:+ - ${CNT[$b]}}"
    save_keepnets
    UMC_BOXES=$b vagrant destroy -f "$b" >>"$log" 2>&1
    CURRENT=""
    cleanup_downloads                       # right away: never more than one box on disk
done

echo
printf '%-12s %-10s %-11s %s\n' VM PROVIDER SELINUX RESULT
for b in "${boxes[@]}"; do printf '%-12s %-10s %-11s %s\n' "$b" "$provider" "${SEL[$b]:--}" "${RES[$b]:-?}${CNT[$b]:+ - ${CNT[$b]}}"; done

rc=0
for b in "${boxes[@]}"; do [[ ${RES[$b]:-} == PASS || ${RES[$b]:-} == skipped* ]] || rc=1; done
[[ $mode == full ]] || exit "$rc"
# --- evidence report ---------------------------------------------------------------
commit=$(git rev-parse --short HEAD 2>/dev/null)
{
    printf '# E-16 · End-to-end tests in real VMs\n\n| | |\n|---|---|\n'
    printf '| **Claim** | On real VMs with systemd, sshd, PAM and (on RHEL-family boxes) SELinux in enforcing mode, the full test-suite passes, account files keep their SELinux labels, a UMC lock refuses SSH public-key logins that a "!"-only lock lets through, journald receives structured records, and the sweep timer installs. |\n'
    printf '| **Method** | `tests/vagrant/verify.sh %s` boots each pinned box, runs `tests/run.sh` inside it with `UMC_E2E=1` (unit, integration, live and end-to-end tests), destroys the VM and removes what the run downloaded. |\n' "$provider"
    printf '| **Environment** | %s · vagrant-libvirt %s · host %s · UMC `%s` · %s |\n' "$(vagrant --version)" "$(vagrant plugin list 2>/dev/null | sed -n 's/^vagrant-libvirt (\([^,]*\).*/\1/p')" "$(. /etc/os-release; echo "$PRETTY_NAME")" "$commit" "$(date -u +%F)"
    printf '| **Reproduce** | `tests/vagrant/verify.sh %s %s` |\n' "$provider" "${boxes[*]}"
    v="✅ PASS"; ((rc == 0)) || v="❌ FAIL"
    printf '| **Verdict** | %s |\n\n' "$v"
    printf '## Results\n\n| VM | Box | SELinux | Result |\n|---|---|---|---|\n'
    for b in "${boxes[@]}"; do
        bx=$(ruby -e 'eval(File.read("Vagrantfile")[/^BOXES = \{.*?^\}/m]); b = BOXES[ARGV[0]]; k = { "libvirt" => :libvirt, "hyperv" => :hyperv }.fetch(ARGV[1], :other); puts b && b[k] ? b[k].join(" ") : "?"' "$b" "$provider" 2>/dev/null)
        printf '| %s | `%s` | %s | %s |\n' "$b" "$bx" "${SEL[$b]:--}" "${RES[$b]}${CNT[$b]:+ - ${CNT[$b]}}"
    done
    printf '\n## End-to-end test lines per VM\n'
    for b in "${boxes[@]}"; do
        [[ -n ${E2E[$b]:-} ]] || continue
        printf '\n### %s\n\n```text\n%s\n```\n' "$b" "${E2E[$b]}"
    done
} > "$repo/evidence/E-16-vm-end-to-end.md"
echo "report: evidence/E-16-vm-end-to-end.md"
exit "$rc"
