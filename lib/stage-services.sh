# lib/stage-services.sh — enable systemd services and set the default target.

stage_services() {
  require_root
  section "services: enabling + default target"

  # We can only systemctl enable in a booted systemd. In a chroot (e.g. when
  # running from a kickstart %post) systemctl will fail; warn instead of die.
  if ! systemctl --no-pager status >/dev/null 2>&1; then
    warn "systemctl not available (chroot?); skipping service enable"
    warn "remember to enable greetd.service manually after first boot:"
    warn "  systemctl set-default graphical.target"
    warn "  systemctl enable greetd.service"
    return 0
  fi

  # ── Docker group + user membership ──────────────────────────────────────────
  if ! getent group docker >/dev/null 2>&1; then
    info "creating docker group"
    groupadd docker || warn "groupadd docker failed (continuing)"
  fi
  if [[ -n "${OMEDORA_TARGET_USER}" ]]; then
    info "adding ${OMEDORA_TARGET_USER} to docker group"
    usermod -aG docker "${OMEDORA_TARGET_USER}" \
      || warn "usermod -aG docker ${OMEDORA_TARGET_USER} failed (continuing)"
  fi

  # ── libvirt group + user membership ─────────────────────────────────────────
  # virt-manager and virsh talk to libvirtd over a UNIX socket whose ACL is
  # the `libvirt` group; without group membership, every guest start pops a
  # polkit auth prompt. `groupadd -f` is a no-op when the group already exists,
  # so re-runs are safe. libvirt-daemon's RPM creates this group at install
  # time, but if the install skipped because @virtualization was already
  # done in a previous run, we still need to ensure the user is added.
  if ! getent group libvirt >/dev/null 2>&1; then
    info "creating libvirt group"
    groupadd -f libvirt 2>/dev/null || warn "groupadd libvirt failed (continuing)"
  fi
  if [[ -n "${OMEDORA_TARGET_USER}" ]] && getent group libvirt >/dev/null 2>&1; then
    info "adding ${OMEDORA_TARGET_USER} to libvirt group"
    usermod -aG libvirt "${OMEDORA_TARGET_USER}" \
      || warn "usermod -aG libvirt ${OMEDORA_TARGET_USER} failed (continuing)"
  fi

  for svc in "${OMEDORA_SERVICES_ENABLE[@]}"; do
    info "enabling ${svc}"
    systemctl enable "${svc}" || warn "failed to enable ${svc} (continuing)"
  done

  if [[ -n "${OMEDORA_SERVICES_DEFAULT}" ]]; then
    info "setting default target: ${OMEDORA_SERVICES_DEFAULT}"
    systemctl set-default "${OMEDORA_SERVICES_DEFAULT}" \
      || warn "set-default ${OMEDORA_SERVICES_DEFAULT} failed"
  fi
}
