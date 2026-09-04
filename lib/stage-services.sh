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

  # Add docker group and add target user to it.
  if ! getent group docker >/dev/null 2>&1; then
    info "creating docker group"
    groupadd docker || warn "groupadd docker failed (continuing)"
  fi
  if [[ -n "${OMEDORA_TARGET_USER}" ]]; then
    info "adding ${OMEDORA_TARGET_USER} to docker group"
    usermod -aG docker "${OMEDORA_TARGET_USER}" \
      || warn "usermod -aG docker ${OMEDORA_TARGET_USER} failed (continuing)"
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
