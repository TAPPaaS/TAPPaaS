#!/usr/bin/env bash
# test the TAPPaaS installation
#
# It will run through a number of test, each either just be a status line OR it will haev a warning/failure message
# if something is wrong.
# details can be found in /home/tappaas/logs/test-config.log

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

BFR="\\r\\033[K"

msg_headline() {
  echo -e "${CL}${BOLD}========================================"
  echo -e "$1"
  echo -e "========================================${CL}"
}

msg_testing() {
  test_msg="$1"
  echo -ne "${YW}Testing: ${test_msg}..."
}

msg_ok() {
  echo -e "${GN}${msg}Success: ${CL}"
}

msg_warning() {
  echo -e "${BFR}${BOLD}${BL}Warning: ${msg}${CL}"
  echo "Warning: $msg" >> "$LOGFILE"
}

msg_error() {
  echo -e "${BFR}${BOLD}${RD}Error:   ${msg}${CL}"
  echo "Error: $msg" >> "$LOGFILE"
}

# check that hostname is tappaas-cicd
if [ "$(hostname)" != "tappaas-cicd" ]; then
  echo "This script must be run on the TAPPaaS-CICD host (hostname tappaas-cicd)."
  exit 1
fi

#TODO , make automatic use of LOGFILE in above functions
LOGFILE="/home/tappaas/logs/test-config.log"
mkdir -p /home/tappaas/logs
echo "TAPPaaS-CICD Test Log" > "$LOGFILE"
echo "======================" >> "$LOGFILE"
echo "" >> "$LOGFILE"

msg_headline "Testing TAPPaaS-CICD Installation"

msg_testing "Do the tappaas user exists"
if id "tappaas" &>/dev/null; then
  msg_ok
else
  msg_error
fi

msg_testing "Do the SSH keys exist for tappaas user"
if [ -f "/home/tappaas/.ssh/id_rsa" ] && [ -f "/home/tappaas/.ssh/id_rsa.pub" ]; then
  msg_ok
else
  msg_error
fi

msg_testing "Is the tappaas-cicd repo cloned"
if [ -d "/home/tappaas/TAPPaaS" ]; then
  msg_ok
else
  msg_error
fi
msg_testing "Is the NixOS configuration applied"
if [ -f "/etc/nixos/tappaas-cicd.nix" ]; then
  msg_ok
else
  msg_error
fi
msg_headline "Validating Module JSON Configurations"

# Validate all module JSON files (check_json is provided by common-install-routines.sh)
json_errors=0
json_count=0

for json_file in /home/tappaas/config/*.json; do
  # Skip schema/field definition files
  basename=$(basename "$json_file")
  case "$basename" in
    *-fields.json|configuration.json|zones.json)
      continue
      ;;
  esac

  ((json_count++))
  if ! check_json "$json_file" 2>&1 | tee -a "$LOGFILE"; then
    ((json_errors++))
  fi
  echo "" >> "$LOGFILE"
done

echo ""
if [ $json_errors -gt 0 ]; then
  echo -e "${RD}JSON Validation: $json_errors of $json_count module(s) have errors${CL}"
else
  echo -e "${GN}JSON Validation: All $json_count module(s) passed validation${CL}"
fi

msg_headline "TAPPaaS-CICD Installation Test Completed"

echo -e "\nDetailed log can be found in $LOGFILE\n"
