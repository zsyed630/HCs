#!/bin/bash
# =====================================================================
#  fprd_pulse_loop.sh
#
#  Runs fprd_pulse.sql on a timer while the FS_CEBD master build runs,
#  appends to a log, and stops itself when the job finishes.
#
#  USAGE
#      . oraenv                     enter your node, e.g. FPRD1 or FPRD2
#      chmod +x fprd_pulse_loop.sh
#      nohup ./fprd_pulse_loop.sh 600 > fprd_pulse_nohup.out 2>&1 &
#      tail -f ~/fscebd_pulse/fprd_pulse_*.log
#
#  ARGUMENTS
#      $1  interval in seconds, default 600 (10 minutes)
#      $2  ORACLE_SID, defaults to the current one
#
#  STOPPING
#      kill %1          or        pkill -f fprd_pulse_loop
#      It also stops on its own once FS_CEBD is no longer running, and
#      after a 5 hour safety cap so it cannot be left running forever.
#
#  PRODUCTION NOTES
#      * 10 minute default, not 5. The monitor should be invisible.
#      * the SQL disables parallel query for its own session
#      * SQL*Plus gets stdin from /dev/null and the script ends in EXIT,
#        which is what avoids "Error 45 initializing SQL*Plus" in a loop
#      * strictly read only, nothing here changes the database
# =====================================================================

set -u

INTERVAL="${1:-600}"
SID="${2:-${ORACLE_SID:-}}"
MAXHOURS=5

if [ -z "$SID" ]; then
  echo "ORACLE_SID not set. Source your environment first:"
  echo "    . oraenv          then enter the node, e.g. FPRD1"
  exit 1
fi
export ORACLE_SID="$SID"

if [ -z "${ORACLE_HOME:-}" ]; then
  echo "ORACLE_HOME not set. Source your environment first (. oraenv)."
  exit 1
fi
export PATH="$ORACLE_HOME/bin:$PATH"

SQLPLUS="$ORACLE_HOME/bin/sqlplus"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/fprd_pulse.sql"
LOG="$HERE/fprd_pulse_$(date +%Y%m%d_%H%M).log"

if [ ! -f "$SCRIPT" ]; then
  echo "cannot find $SCRIPT"
  exit 1
fi

echo "node     : $ORACLE_SID"
echo "interval : ${INTERVAL}s"
echo "log      : $LOG"
echo "safety   : stops after ${MAXHOURS}h or when FS_CEBD ends"
echo "tail     : tail -f $LOG"
echo

START=$(date +%s)
n=0

while true; do
  n=$((n+1))
  {
    echo "################################################################"
    echo "# PULSE $n   $(date '+%Y-%m-%d %H:%M:%S')   node=$ORACLE_SID"
    echo "################################################################"
  } >> "$LOG"

  "$SQLPLUS" -S / as sysdba @"$SCRIPT" >> "$LOG" 2>&1 < /dev/null

  # keep a per-pulse copy of just the SQL manifest, so the inventory can
  # be diffed pulse to pulse to see what appeared or disappeared
  awk '/^F - FULL SQL MANIFEST/,/^G - CURSOR METRICS/' "$LOG" \
    | tail -n +1 > "$HERE/manifest_$(printf '%03d' $n).txt" 2>/dev/null || true

  # is FS_CEBD still running
  STILL=$("$SQLPLUS" -S / as sysdba <<'SQLEOF' 2>/dev/null < /dev/null
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF
SELECT /* FSCEBD_PULSE */ COUNT(*) FROM SYSADM.PSPRCSRQST
 WHERE PRCSNAME = 'FS_CEBD' AND ENDDTTM IS NULL
   AND BEGINDTTM > SYSDATE - 1;
EXIT
SQLEOF
)
  STILL=$(echo "$STILL" | tr -dc '0-9')
  STILL=${STILL:-1}

  if [ "$STILL" = "0" ] && [ "$n" -gt 1 ]; then
    {
      echo
      echo "################################################################"
      echo "# FS_CEBD is no longer running. Final pulse above."
      echo "# $(date '+%Y-%m-%d %H:%M:%S')"
      echo "################################################################"
    } >> "$LOG"
    echo "job finished. log: $LOG"
    break
  fi

  NOW=$(date +%s)
  if [ $(( (NOW - START) / 3600 )) -ge "$MAXHOURS" ]; then
    echo "# safety cap of ${MAXHOURS}h reached, stopping" >> "$LOG"
    echo "safety cap reached. log: $LOG"
    break
  fi

  sleep "$INTERVAL"
done

# ---------------------------------------------------------------------
# final summary, appended once the loop ends
# ---------------------------------------------------------------------
"$SQLPLUS" -S / as sysdba >> "$LOG" 2>&1 < /dev/null <<'SQLEOF'
SET HEADING ON FEEDBACK OFF PAGESIZE 200 LINESIZE 140
COL runcntlid FORMAT A34
COL table_name FORMAT A26
PROMPT
PROMPT ================ FINAL SUMMARY ================
PROMPT
PROMPT -- last 10 FS_CEBD runs
SELECT /* FSCEBD_PULSE */ PRCSINSTANCE, RUNCNTLID, RUNSTATUS,
       TO_CHAR(BEGINDTTM,'MM-DD HH24:MI:SS') began,
       TO_CHAR(ENDDTTM  ,'MM-DD HH24:MI:SS') ended,
       ROUND((CAST(ENDDTTM AS DATE)-CAST(BEGINDTTM AS DATE))*1440,1) mins
FROM  (SELECT * FROM SYSADM.PSPRCSRQST
        WHERE PRCSNAME='FS_CEBD' ORDER BY BEGINDTTM DESC)
WHERE ROWNUM <= 10;
PROMPT
PROMPT -- did the sample percentage drop
SELECT /* FSCEBD_PULSE */ table_name, num_rows, sample_size,
       ROUND(sample_size/NULLIF(num_rows,0)*100,2) pct_sampled,
       TO_CHAR(last_analyzed,'MM-DD HH24:MI:SS') last_analyzed
FROM   dba_tab_statistics
WHERE  owner='SYSADM' AND object_type='TABLE'
AND    table_name IN ('PS_COMBO_DATA_TBL','PS_COMBO_DATA_BUDG')
ORDER  BY table_name;
PROMPT
PROMPT PS_COMBO_DATA_TBL near 1 percent means the fix fired.
PROMPT PS_COMBO_DATA_BUDG stays at 100 percent, it has no preference.
EXIT
SQLEOF

echo
echo "final summary appended to $LOG"
