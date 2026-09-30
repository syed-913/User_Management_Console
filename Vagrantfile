# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# UMC test VMs - one Vagrantfile for libvirt/KVM, VirtualBox, VMware, Hyper-V
# and Parallels. VMs cover what containers cannot: SELinux in enforcing mode, a
# real sshd/PAM login, journald, systemd timers.
#
#   vagrant up rocky9                                   # default provider (libvirt here)
#   vagrant up debian12 --provider=virtualbox
#   UMC_BOXES=rhel9,ubuntu2404 vagrant up               # a subset
#   vagrant provision rocky9 --provision-with test      # run the test-suite incl. e2e
#   tests/vagrant/verify.sh libvirt rocky9              # boot, test, destroy, clean up downloads
#   tests/vagrant/verify.sh --smoke virtualbox          # which boxes work for YOU on your hypervisor
#
# Every box is pinned to an exact version. What has actually been booted and
# tested, with which provider and when, is recorded in
# evidence/E-16-vm-end-to-end.md and the README's compatibility table (libvirt).
# The boxes for the other providers are published on Vagrant Cloud but have not
# been booted by the maintainers of this repository.
#
# Box sources (checked 2026-09-30 via the Vagrant Cloud API):
#   bento/*    (Chef)     maintained; VirtualBox, VMware, Parallels, UTM.
#                         libvirt builds stopped after 202508.03.0. The libvirt
#                         bento/ubuntu-22.04 (202502.21.0) is UEFI-only: GPT with
#                         an EFI partition and empty MBR boot code, so it hangs at
#                         "Booting from Hard Disk" under vagrant-libvirt's default
#                         BIOS firmware - generic/ubuntu2204 is used instead.
#   generic/*  (Roboxes)  frozen since 2024-01 (4.3.12), but the only family
#                         that also covers Hyper-V and RHEL.
#   debian/*   (Debian cloud team) official; libvirt. crystax/debian13 was tried
#                         first and does not boot (malformed disk capacity in its
#                         metadata), which is why it was replaced.

BOXES = {
  #  name        libvirt box, version                    other providers' box, version            hyper-v box
  "rhel9"      => { libvirt: ["generic/rhel9", "4.3.12"],          other: ["generic/rhel9", "4.3.12"],             hyperv: ["generic/rhel9", "4.3.12"],    ip: "192.168.100.10" },
  "rocky9"     => { libvirt: ["generic/rocky9", "4.3.12"],         other: ["bento/rockylinux-9", "202510.26.0"],   hyperv: ["generic/rocky9", "4.3.12"],   ip: "192.168.100.40" },
  "alma9"      => { libvirt: ["bento/almalinux-9", "202508.03.0"], other: ["bento/almalinux-9", "202511.24.0"],    hyperv: ["generic/alma9", "4.3.12"],    ip: "192.168.100.50" },
  "debian12"   => { libvirt: ["generic/debian12", "4.3.12"],       other: ["bento/debian-12", "202510.26.0"],      hyperv: ["generic/debian12", "4.3.12"], ip: "192.168.100.20" },
  "debian13"   => { libvirt: ["debian/trixie64", "13.20260519.1"], other: ["bento/debian-13", "202510.26.0"],      hyperv: nil,                            ip: "192.168.100.60" },
  "ubuntu2204" => { libvirt: ["generic/ubuntu2204", "4.3.12"],    other: ["bento/ubuntu-22.04", "202510.26.0"],   hyperv: ["generic/ubuntu2204", "4.3.12"], ip: "192.168.100.70" },
  "ubuntu2404" => { libvirt: ["bento/ubuntu-24.04", "202508.03.0"],other: ["bento/ubuntu-24.04", "202510.26.0"],   hyperv: nil,                            ip: "192.168.100.30" },
}

wanted  = (ENV["UMC_BOXES"] || BOXES.keys.join(",")).split(",").map(&:strip)
memory  = (ENV["UMC_VM_MEMORY"] || "1536").to_i
cpus    = (ENV["UMC_VM_CPUS"] || "2").to_i
nfs     = ENV["UMC_SYNC"] == "nfs"
private = ENV["UMC_PRIVATE_NET"] == "1"   # a host-only network is not needed by the tests

Vagrant.configure("2") do |config|
  config.vm.box_check_update = false
  # Without NFS, keep Vagrant away from /etc/exports entirely (it would
  # otherwise "prune" old entries, which needs sudo).
  config.nfs.functional = false unless nfs
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # The repository is synced to /opt/umc. rsync works with every provider and
  # needs no NFS server or guest additions; UMC_SYNC=nfs for live editing.
  if nfs
    config.vm.synced_folder ".", "/opt/umc", type: "nfs", nfs_version: 4, nfs_udp: false
  else
    config.vm.synced_folder ".", "/opt/umc", type: "rsync",
      rsync__exclude: [".git/", ".vagrant/", "poc/.out/", "tests/.cache/vm/"]
  end

  # RHEL needs a subscription to install packages. With the vagrant-registration
  # plugin, credentials are taken from the environment - never from this file.
  if Vagrant.has_plugin?("vagrant-registration") && ENV["RHSM_USERNAME"]
    config.registration.username = ENV["RHSM_USERNAME"]
    config.registration.password = ENV["RHSM_PASSWORD"]
  end

  BOXES.each do |name, b|
    next unless wanted.include?(name)
    config.vm.define name, autostart: wanted.length == 1 || ENV["UMC_BOXES"] do |vm|
      vm.vm.hostname = "umc-#{name}"
      vm.vm.network "private_network", ip: b[:ip] if private

      vm.vm.provider :libvirt do |lv, override|
        override.vm.box, override.vm.box_version = b[:libvirt]
        lv.memory = memory
        lv.cpus = cpus
        # Since vagrant-libvirt 0.7 the plugin deletes its management network on
        # the last destroy, even one that existed before. Keep it; the test
        # driver (tests/vagrant/verify.sh) decides what to clean up.
        lv.management_network_keep = true
        # Some boxes (bento/ubuntu-22.04 202502.21.0) ship a Vagrantfile that sets
        # driver "qemu": pure software emulation, many times slower. Use KVM
        # whenever the host has it.
        lv.driver = ENV.fetch("UMC_LIBVIRT_DRIVER") { File.exist?("/dev/kvm") ? "kvm" : "qemu" }
      end
      %i[virtualbox vmware_desktop parallels].each do |p|
        vm.vm.provider p do |pv, override|
          override.vm.box, override.vm.box_version = b[:other]
          pv.memory = memory
          pv.cpus = cpus
        end
      end
      if b[:hyperv]                      # no Hyper-V build is published for the others
        vm.vm.provider :hyperv do |hv, override|
          override.vm.box, override.vm.box_version = b[:hyperv]
          hv.memory = memory
          hv.cpus = cpus
        end
      end

      # Same dependencies as the test containers, plus sshd for the e2e tests.
      vm.vm.provision "deps", type: "shell", path: "tests/vagrant/provision.sh"
      # Opt-in: vagrant provision NAME --provision-with test
      vm.vm.provision "test", type: "shell", run: "never",
        inline: "UMC_TEST_VM=1 UMC_E2E=1 bash /opt/umc/tests/run.sh"
      # Opt-in: vagrant provision NAME --provision-with smoke  (about 10 seconds)
      vm.vm.provision "smoke", type: "shell", run: "never",
        inline: "UMC_TEST_VM=1 bash /opt/umc/tests/vagrant/smoke-inside.sh"
    end
  end
end
