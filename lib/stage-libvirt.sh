# lib/stage-libvirt.sh — libvirt daemon configuration.
#
# On Fedora, firewalld uses nftables as its backend. Libvirt's own firewall
# rules are generated for iptables, and when the kernel's nftables pipeline
# processes packets before iptables (netfilter hook ordering), VM traffic
# can be dropped — causing "VMs can't reach the internet" even when routing
# and NAT config inside the guest are correct.
#
# Setting firewall_backend = "iptables" in libvirtd.conf makes libvirt use
# the iptables compat layer via the nft-compat kernel module, preserving
# hook ordering so libvirt's rules fire before firewalld's.

stage_libvirt() {
  require_root

  section "libvirt: firewall backend + daemon config"

  local conf="/etc/libvirt/libvirtd.conf"
  if [[ ! -f "${conf}" ]]; then
    warn "${conf} not found; skipping libvirt configuration"
    return 0
  fi

  # ── firewall_backend ───────────────────────────────────────────────────────
  # Uncomment or insert firewall_backend = "iptables".
  if grep -q '^#*firewall_backend' "${conf}"; then
    if grep -q '^firewall_backend.*iptables' "${conf}"; then
      info "firewall_backend already set to iptables in ${conf}"
    else
      info "setting firewall_backend = \"iptables\" in ${conf}"
      sed -i \
        's/^#*firewall_backend.*/firewall_backend = "iptables"/' \
        "${conf}"
    fi
  else
    info "appending firewall_backend = \"iptables\" to ${conf}"
    printf '\n# Use iptables compat layer so libvirt rules fire before firewalld\nfirewall_backend = "iptables"\n' \
      >> "${conf}"
  fi

  # ── libvirtd TCP listen (optional — only if TLS is configured) ─────────────
  # The default is unix socket only, which is fine for virt-manager and virsh
  # running locally. Leave it alone unless the user explicitly needs TCP.

  info "libvirt configuration complete"
}
