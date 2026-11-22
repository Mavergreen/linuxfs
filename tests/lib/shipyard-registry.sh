# platform: host-agnostic
#   usage: . tests/lib/shipyard-registry.sh DIR
#          Sourced by tests that package. If $SHIPYARD_SCRIPTS does not register linuxfs, points SHIPYARD_SCRIPTS
#          at a copy of it under DIR whose product-names adds `linuxfs dev.mavergreen.linuxfs linuxfs`, so the
#          tests run before shipyard carries the line. Remove this once every shipyard release registers it.
if ! sh "$SHIPYARD_SCRIPTS/product-name.sh" identifier linuxfs > /dev/null 2>&1; then
  _sr_dir="$1/shipyard"
  rm -rf "$_sr_dir"; mkdir -p "$_sr_dir"
  cp -R "$SHIPYARD_SCRIPTS/.." "$_sr_dir/share" 2>/dev/null || cp -R "$SHIPYARD_SCRIPTS" "$_sr_dir/share"
  _sr_s="$_sr_dir/share/scripts"; [ -d "$_sr_s" ] || _sr_s="$_sr_dir/share"
  echo 'linuxfs dev.mavergreen.linuxfs linuxfs' >> "$_sr_s/product-names"
  SHIPYARD_SCRIPTS="$_sr_s"; SHIPYARD="$_sr_s"; export SHIPYARD_SCRIPTS SHIPYARD
  unset _sr_dir _sr_s
fi
