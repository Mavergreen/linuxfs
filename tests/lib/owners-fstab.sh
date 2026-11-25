# platform: host-agnostic
#   Sourced by tests/smoke-mavericks.sh (and tests/parity-test.sh, with a sudo of its own): the smoke's /etc/fstab owners
#   line (item 6), put on and taken away as root by sudo -n.
#   owners_fstab_add FSTAB LINE   LINE appended to FSTAB on a line of its own: a newline first when FSTAB's last byte is
#                                 not one (a hand edit can leave it so), lest LINE join the entry before it
#   owners_fstab_gone FSTAB TAG   every line holding TAG taken out of FSTAB, the rest kept as they were (rewritten in
#                                 place, so FSTAB keeps its owner and mode); 0 when none is left
owners_fstab_add() {
  sudo -n sh -c 'test -z "$(tail -c 1 "$1" 2> /dev/null)" || echo >> "$1"; printf "%s\n" "$2" >> "$1"' _ "$1" "$2"
}
owners_fstab_gone() {
  if grep -qF -- "$2" "$1" 2> /dev/null; then
    # FSTAB is rewritten only from a copy written whole: grep's 1 is fine (every line was ours), its 2 or a copy that
    #   could not be written leaves FSTAB as it was
    sudo -n sh -c 'if { grep -vF -- "$2" "$1"; test $? -le 1; } > "$1.owners-tmp"; then cat "$1.owners-tmp" > "$1"; fi
      rm -f "$1.owners-tmp"' _ "$1" "$2" 2> /dev/null
  fi
  ! grep -qF -- "$2" "$1" 2> /dev/null
}
