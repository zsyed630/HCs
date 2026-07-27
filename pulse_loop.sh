#!/bin/bash
# =====================================================================
#  pulse_loop.sh   -   run fscebd_pulse.sql on a timer, append to a log
#
#  Usage:
#     ./pulse_loop.sh                 every 300s until FS_CEBD finishes
#     ./pulse_loop.sh 120             every 120s
#     ./pulse_loop.sh 300 FSQUA1      target the other node
#
#  Stop with Ctrl-C, or if backgrounded:  kill %1
#
#  Why a script file rather than a bash -c one-liner: the one-liner form
#  loses environment on some shells and is a quoting minefield. This also
#  redirects stdin from /dev/null and relies on the EXIT at the end of
#  the SQL, which is what fixes the "Error 45 initializing SQL*Plus"
#  seen when SQL*Plus is left waiting for input inside a loop.
# =====================================================================

INTERVAL="${1:-300}"
SID="${2:-$ORACLE_SID}"

if [ -z "$SID" ]; then
  echo "ORACLE_SID is not set and none was passed. Try:"
  echo "    . oraenv        (enter FSQUA2)"
  echo "    ./pulse_loop.sh 300"
  exit 1
fi
export ORACLE_SID="$SID"

if [ -z "$ORACLE_HOME" ]; then
  echo "ORACLE_HOME is not set. Source your environment first (. oraenv)."
  exit 1
fi
export PATH="$ORACLE_HOME/bin:$PATH"

SQLPLUS="$ORACLE_HOME/bin/sqlplus"
SCRIPT="$(dirname "$0")/fscebd_pulse.sql"
LOG="pulse_$(date +%Y%m%d_%H%M).log"

if [ ! -f "$SCRIPT" ]; then
  echo "cannot find $SCRIPT"
  exit 1
fi

echo "node     : $ORACLE_SID"
echo "interval : ${INTERVAL}s"
echo "log      : $(pwd)/$LOG"
echo "tail with: tail -f $(pwd)/$LOG"
echo

n=0
while true; do
  n=$((n+1))
  {
    echo "################################################################"
    echo "# PULSE $n   $(date '+%Y-%m-%d %H:%M:%S')   node=$ORACLE_SID"
    echo "################################################################"
  } >> "$LOG"

  "$SQLPLUS" -S / as sysdba @"$SCRIPT" >> "$LOG" 2>&1 < /dev/null

  # stop automatically once the job is no longer running
  STILL=$("$SQLPLUS" -S / as sysdba <<'SQLEOF' 2>/dev/null < /dev/null
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT COUNT(*) FROM SYSADM.PSPRCSRQST
 WHERE PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NULL
   AND BEGINDTTM > SYSDATE - 1;
EXIT
SQLEOF
)
  STILL=$(echo "$STILL" | tr -d '[:space:]')

  if [ "$STILL" = "0" ]; then
    {
      echo
      echo "################################################################"
      echo "# FS_CEBD is no longer running. Final pulse above. $(date)"
      echo "################################################################"
    } >> "$LOG"
    echo "job finished - loop stopping. Log: $(pwd)/$LOG"
    break
  fi

  sleep "$INTERVAL"
done
