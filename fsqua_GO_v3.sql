-- =====================================================================
--  fsqua_GO.sql        VERSION 3
--
--  FSQUA ONLY. Safe to re-run. Steps already completed are detected and
--  skipped, so running this after v2 only finishes what v2 left undone.
--
--  V3 FIXES TWO DEFECTS IN V2
--
--  1. ESTIMATE_PERCENT verification compared GET_PREFS output against
--     the string '1'. GET_PREFS returns '1.000000'. The preference was
--     set correctly and the check reported a false FAIL. Now compares
--     numerically.
--
--  2. Statistics remediation trusted RESTORE_TABLE_STATS because it did
--     not raise an exception. It returned cleanly and changed nothing -
--     the thirteen TAO tables stayed at 1,000,000 rows and stayed
--     locked. V3 re-reads the value after every operation and escalates
--     until the value is actually correct, rather than trusting a
--     silent return.
--
--     Escalation order, per table:
--       a. unlock                       then re-read
--       b. restore from stats history   then re-read
--       c. delete the statistics        then re-read
--       d. set to 0 rows / 0 blocks     then re-read
--     FPRD holds these tables at 0 rows, so step d reproduces production
--     exactly. Stops at the first step that produces the right value.
--
--  Section 0 dumps the statistics history for one table so the reason
--  the restore did nothing can be established rather than guessed at.
--
--  TO APPLY, change ONE line in the DECLARE section:
--      c_mode  CONSTANT VARCHAR2(20) := 'DRY_RUN';   ->  'EXECUTE'
-- =====================================================================

SET DEFINE OFF
SET LINESIZE 118
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

SPOOL fsqua_GO_v3.log

DECLARE
  -- ==================================================================
  c_mode     CONSTANT VARCHAR2(20) := 'DRY_RUN';            -- or EXECUTE
  c_dbguard  CONSTANT VARCHAR2(30) := 'FSQUA';
  c_fixtable CONSTANT VARCHAR2(30) := 'PS_COMBO_DATA_TBL';
  c_tbl_deg  CONSTANT VARCHAR2(10) := '4';
  c_idx_name CONSTANT VARCHAR2(30) := 'PSACOMBO_DATA_TBL';
  -- ==================================================================

  v_db     VARCHAR2(30);
  v_go     BOOLEAN := TRUE;
  v_run    BOOLEAN := FALSE;
  v_line   PLS_INTEGER := 0;
  v_bad    PLS_INTEGER := 0;

  v_asof   TIMESTAMP WITH TIME ZONE;
  v_oldest TIMESTAMP WITH TIME ZONE;

  v_patch_cebd NUMBER := 0;
  v_patch_all  NUMBER := 0;
  v_bound      NUMBER := 0;
  v_locked     NUMBER := 0;
  v_fake       NUMBER := 0;
  v_tabdeg     VARCHAR2(20);
  v_idxdeg     VARCHAR2(20);
  v_nr         NUMBER;
  v_lk         VARCHAR2(10);
  v_how        VARCHAR2(30);

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE hdr(s IN VARCHAR2) IS
  BEGIN
    p(' ');
    p(RPAD('=', 116, '='));
    p(s);
    p(RPAD('=', 116, '='));
  END hdr;

  PROCEDURE chk(label IN VARCHAR2, val IN VARCHAR2, ok IN BOOLEAN) IS
  BEGIN
    IF NOT ok THEN v_go := FALSE; v_bad := v_bad + 1; END IF;
    p('  ' || RPAD(label, 46) || RPAD(SUBSTR(val, 1, 34), 36)
      || CASE WHEN ok THEN 'PASS' ELSE '** FAIL **' END);
  END chk;

  -- read back the live values for one table
  PROCEDURE peek(tab IN VARCHAR2) IS
  BEGIN
    SELECT MAX(num_rows), MAX(stattype_locked)
    INTO   v_nr, v_lk
    FROM   dba_tab_statistics
    WHERE  owner = 'SYSADM' AND table_name = tab AND object_type = 'TABLE';
  EXCEPTION WHEN OTHERS THEN
    v_nr := -1; v_lk := 'err';
  END peek;

  FUNCTION fixed RETURN BOOLEAN IS
  BEGIN
    RETURN v_lk IS NULL AND NVL(v_nr, -1) <> 1000000;
  END fixed;

BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;
  v_run := (UPPER(c_mode) = 'EXECUTE' AND v_db LIKE c_dbguard || '%');

  p(RPAD('=', 116, '='));
  p('FSQUA GO SCRIPT v3    db=' || v_db || '   mode=' || c_mode
    || '   at=' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  p(RPAD('=', 116, '='));

  IF v_db NOT LIKE c_dbguard || '%' THEN
    p(' ');
    p('REFUSING TO RUN. Database is ' || v_db || ', not ' || c_dbguard || '.');
    RETURN;
  END IF;

  IF NOT v_run THEN
    p('  DRY RUN. Nothing will be changed.');
    p('  To apply, edit the DECLARE section:  c_mode := EXECUTE');
  END IF;

  -- ==================================================================
  hdr('STEP 0 - WHY THE RESTORE DID NOTHING');
  -- ==================================================================
  BEGIN
    v_oldest := DBMS_STATS.GET_STATS_HISTORY_AVAILABILITY;
  EXCEPTION WHEN OTHERS THEN v_oldest := NULL;
  END;
  p('  stats history available from : '
    || NVL(TO_CHAR(v_oldest, 'YYYY-MM-DD HH24:MI:SS'), 'unknown'));
  p(' ');
  p('  Every saved statistics version for PS_FS_CEBD_TAO. If the only');
  p('  entries are at or after the tampering time, there was nothing');
  p('  older to restore and the call was a silent no-op.');
  p(' ');
  p('  ' || RPAD('STATS_UPDATE_TIME', 34) || 'TABLE');
  DECLARE v_n PLS_INTEGER := 0;
  BEGIN
    FOR r IN (SELECT table_name tn, stats_update_time st
              FROM   dba_tab_stats_history
              WHERE  owner = 'SYSADM' AND table_name = 'PS_FS_CEBD_TAO'
              ORDER  BY stats_update_time DESC
              FETCH FIRST 12 ROWS ONLY)
    LOOP
      v_n := v_n + 1;
      p('  ' || RPAD(TO_CHAR(r.st, 'YYYY-MM-DD HH24:MI:SS'), 34) || r.tn);
    END LOOP;
    IF v_n = 0 THEN
      p('  none - no saved versions at all, which fully explains it');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  query failed: ' || SUBSTR(SQLERRM, 1, 60));
  END;

  -- ==================================================================
  hdr('STEP 1 - PATCHES');
  -- ==================================================================
  SELECT COUNT(*) INTO v_patch_cebd FROM dba_sql_patches
   WHERE name LIKE 'PATCH_CEBD%';

  IF v_patch_cebd = 0 THEN
    p('  Already done. No PATCH_CEBD patches remain.');
  ELSE
    FOR r IN (SELECT name nm FROM dba_sql_patches
              WHERE name LIKE 'PATCH_CEBD%' ORDER BY created)
    LOOP
      IF v_run THEN
        BEGIN
          DBMS_SQLDIAG.DROP_SQL_PATCH(name => r.nm, ignore => TRUE);
          p('  DROPPED  ' || r.nm);
        EXCEPTION WHEN OTHERS THEN
          p('  FAILED   ' || r.nm || ' : ' || SUBSTR(SQLERRM, 1, 50));
        END;
      ELSE
        p('  would drop  ' || r.nm);
      END IF;
    END LOOP;
  END IF;

  -- ==================================================================
  hdr('STEP 2 - STATISTICS: ESCALATE UNTIL THE VALUE IS ACTUALLY RIGHT');
  -- ==================================================================
  BEGIN
    SELECT CAST(MIN(created) AS TIMESTAMP) - INTERVAL '1' MINUTE
    INTO   v_asof FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  EXCEPTION WHEN OTHERS THEN v_asof := NULL;
  END;
  IF v_asof IS NULL THEN
    -- patches already dropped, so fall back to just before the tampering
    v_asof := TO_TIMESTAMP_TZ('2026-07-27 12:58:04 +00:00',
                              'YYYY-MM-DD HH24:MI:SS TZH:TZM');
  END IF;
  p('  restore target : ' || TO_CHAR(v_asof, 'YYYY-MM-DD HH24:MI:SS'));
  p('  target state   : unlocked, and not 1000000 rows');
  p('  FPRD holds these tables at 0 rows, so 0 is the correct value.');
  p(' ');
  p('  ' || RPAD('TABLE', 24) || RPAD('BEFORE', 20) || RPAD('AFTER', 20) || 'RESOLVED BY');
  p('  ' || RPAD('-', 112, '-'));

  FOR t IN (SELECT DISTINCT table_name tn
            FROM   dba_tab_statistics
            WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
            AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
            AND    (stattype_locked IS NOT NULL OR num_rows = 1000000)
            ORDER  BY table_name)
  LOOP
    peek(t.tn);
    DECLARE
      v_before VARCHAR2(40) := NVL(TO_CHAR(v_nr), 'null')
                               || '/' || NVL(v_lk, 'unlocked');
    BEGIN
      v_how := 'not attempted';

      IF NOT v_run THEN
        p('  ' || RPAD(t.tn, 24) || RPAD(v_before, 20)
          || RPAD('-', 20) || 'would escalate');
      ELSE
        -- a. unlock
        BEGIN
          DBMS_STATS.UNLOCK_TABLE_STATS('SYSADM', t.tn);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        peek(t.tn);
        IF fixed THEN v_how := 'unlock'; END IF;

        -- b. restore from history
        IF NOT fixed THEN
          BEGIN
            DBMS_STATS.RESTORE_TABLE_STATS(ownname => 'SYSADM', tabname => t.tn,
                                           as_of_timestamp => v_asof,
                                           force => TRUE, no_invalidate => FALSE);
            BEGIN
              DBMS_STATS.UNLOCK_TABLE_STATS('SYSADM', t.tn);
            EXCEPTION WHEN OTHERS THEN NULL;
            END;
          EXCEPTION WHEN OTHERS THEN NULL;
          END;
          peek(t.tn);
          IF fixed THEN v_how := 'restore'; END IF;
        END IF;

        -- c. delete
        IF NOT fixed THEN
          BEGIN
            DBMS_STATS.DELETE_TABLE_STATS(ownname => 'SYSADM', tabname => t.tn,
                                          cascade_indexes => TRUE, force => TRUE,
                                          no_invalidate => FALSE);
          EXCEPTION WHEN OTHERS THEN NULL;
          END;
          peek(t.tn);
          IF fixed THEN v_how := 'delete'; END IF;
        END IF;

        -- d. set to zero, matching FPRD exactly
        IF NOT fixed THEN
          BEGIN
            DBMS_STATS.SET_TABLE_STATS(ownname => 'SYSADM', tabname => t.tn,
                                       numrows => 0, numblks => 0, avgrlen => 0,
                                       force => TRUE, no_invalidate => FALSE);
          EXCEPTION WHEN OTHERS THEN NULL;
          END;
          peek(t.tn);
          IF fixed THEN v_how := 'set to zero'; END IF;
        END IF;

        IF NOT fixed THEN v_how := '** STILL WRONG **'; END IF;

        p('  ' || RPAD(t.tn, 24) || RPAD(v_before, 20)
          || RPAD(NVL(TO_CHAR(v_nr), 'null') || '/' || NVL(v_lk, 'unlocked'), 20)
          || v_how);
      END IF;
    END;
  END LOOP;

  -- ==================================================================
  hdr('STEP 3 - DEGREE');
  -- ==================================================================
  BEGIN
    SELECT TRIM(degree) INTO v_tabdeg FROM dba_tables
    WHERE owner = 'SYSADM' AND table_name = c_fixtable;
    SELECT TRIM(degree) INTO v_idxdeg FROM dba_indexes
    WHERE owner = 'SYSADM' AND index_name = c_idx_name;
  EXCEPTION WHEN OTHERS THEN
    v_tabdeg := '?'; v_idxdeg := '?';
  END;

  IF v_tabdeg = c_tbl_deg AND UPPER(v_idxdeg) = 'DEFAULT' THEN
    p('  Already done. TABLE=' || v_tabdeg || '  INDEX=' || v_idxdeg);
  ELSIF v_run THEN
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE SYSADM.' || c_fixtable
                        || ' PARALLEL (DEGREE ' || c_tbl_deg || ')';
      p('  APPLIED  ALTER TABLE SYSADM.' || c_fixtable
        || ' PARALLEL (DEGREE ' || c_tbl_deg || ');');
    EXCEPTION WHEN OTHERS THEN
      p('  FAILED   alter table : ' || SUBSTR(SQLERRM, 1, 60));
    END;
    BEGIN
      EXECUTE IMMEDIATE 'ALTER INDEX SYSADM.' || c_idx_name || ' PARALLEL';
      p('  APPLIED  ALTER INDEX SYSADM.' || c_idx_name || ' PARALLEL;');
    EXCEPTION WHEN OTHERS THEN
      p('  FAILED   alter index : ' || SUBSTR(SQLERRM, 1, 60));
    END;
  ELSE
    p('  would align: TABLE ' || v_tabdeg || ' to ' || c_tbl_deg
      || ',  INDEX ' || v_idxdeg || ' to DEFAULT');
  END IF;

  -- ==================================================================
  hdr('STEP 4 - THE FIX: FOUR TABLE PREFERENCES');
  -- ==================================================================
  IF v_run THEN
    BEGIN
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable, 'ESTIMATE_PERCENT', '1');
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable, 'METHOD_OPT',
                                 'FOR ALL INDEXED COLUMNS SIZE 1');
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable, 'CASCADE', 'TRUE');
      -- override switch LAST so the three values above are already in place
      DBMS_STATS.SET_TABLE_PREFS('SYSADM', c_fixtable,
                                 'PREFERENCE_OVERRIDES_PARAMETER', 'TRUE');
      p('  All four preferences set.');
    EXCEPTION WHEN OTHERS THEN
      p('  FAILED : ' || SUBSTR(SQLERRM, 1, 70));
    END;
  ELSE
    p('  would set ESTIMATE_PERCENT=1, METHOD_OPT=FOR ALL INDEXED COLUMNS');
    p('            SIZE 1, CASCADE=TRUE, PREFERENCE_OVERRIDES_PARAMETER=TRUE');
  END IF;

  -- ==================================================================
  hdr('STEP 5 - VERIFICATION');
  -- ==================================================================
  p('  ' || RPAD('CHECK', 46) || RPAD('VALUE', 36) || 'STATUS');
  p('  ' || RPAD('-', 112, '-'));

  SELECT COUNT(*) INTO v_patch_cebd FROM dba_sql_patches WHERE name LIKE 'PATCH_CEBD%';
  SELECT COUNT(*) INTO v_patch_all  FROM dba_sql_patches;
  SELECT COUNT(DISTINCT sql_patch) INTO v_bound FROM gv$sql WHERE sql_patch IS NOT NULL;
  SELECT COUNT(CASE WHEN stattype_locked IS NOT NULL THEN 1 END),
         COUNT(CASE WHEN num_rows = 1000000 AND blocks = 25000 THEN 1 END)
  INTO   v_locked, v_fake
  FROM   dba_tab_statistics
  WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
  AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%');

  chk('PATCH_CEBD patches remaining',   TO_CHAR(v_patch_cebd), v_patch_cebd = 0);
  chk('total patches  (FPRD has 1)',    TO_CHAR(v_patch_all),  v_patch_all = 1);
  chk('patches bound to a cursor',      TO_CHAR(v_bound),      v_bound = 0);
  chk('tables with LOCKED statistics',  TO_CHAR(v_locked),     v_locked = 0);
  chk('tables with FAKE 1M statistics', TO_CHAR(v_fake),       v_fake = 0);

  BEGIN
    SELECT TRIM(degree) INTO v_tabdeg FROM dba_tables
    WHERE owner = 'SYSADM' AND table_name = c_fixtable;
    chk('degree  TABLE ' || c_fixtable, v_tabdeg, v_tabdeg = c_tbl_deg);
  EXCEPTION WHEN OTHERS THEN
    chk('degree  TABLE ' || c_fixtable, 'unreadable', FALSE);
  END;
  BEGIN
    SELECT TRIM(degree) INTO v_idxdeg FROM dba_indexes
    WHERE owner = 'SYSADM' AND index_name = c_idx_name;
    chk('degree  INDEX ' || c_idx_name, v_idxdeg, UPPER(v_idxdeg) = 'DEFAULT');
  EXCEPTION WHEN OTHERS THEN
    chk('degree  INDEX ' || c_idx_name, 'unreadable', FALSE);
  END;

  -- numeric comparison: GET_PREFS returns 1.000000, not 1
  DECLARE
    v_ep VARCHAR2(200);
    v_epn NUMBER;
  BEGIN
    v_ep := DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT', 'SYSADM', c_fixtable);
    BEGIN
      v_epn := TO_NUMBER(v_ep);
    EXCEPTION WHEN OTHERS THEN
      v_epn := NULL;
    END;
    chk('pref ESTIMATE_PERCENT', v_ep, v_epn = 1);
  EXCEPTION WHEN OTHERS THEN
    chk('pref ESTIMATE_PERCENT', 'unreadable', FALSE);
  END;

  BEGIN
    chk('pref METHOD_OPT',
        DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', c_fixtable),
        DBMS_STATS.GET_PREFS('METHOD_OPT', 'SYSADM', c_fixtable)
          = 'FOR ALL INDEXED COLUMNS SIZE 1');
    chk('pref CASCADE',
        DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', c_fixtable),
        UPPER(DBMS_STATS.GET_PREFS('CASCADE', 'SYSADM', c_fixtable)) = 'TRUE');
    chk('pref PREFERENCE_OVERRIDES_PARAMETER',
        DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER', 'SYSADM', c_fixtable),
        UPPER(DBMS_STATS.GET_PREFS('PREFERENCE_OVERRIDES_PARAMETER',
                                   'SYSADM', c_fixtable)) = 'TRUE');
  EXCEPTION WHEN OTHERS THEN
    chk('preference readback', SUBSTR(SQLERRM, 1, 30), FALSE);
  END;

  p(' ');
  p('  Final state of the FS_CEBD statistics:');
  p('  ' || RPAD('TABLE', 26) || LPAD('NUM_ROWS', 14) || LPAD('BLOCKS', 10)
    || '  LOCKED');
  FOR r IN (SELECT table_name tn, num_rows nr, blocks bl, stattype_locked lk
            FROM   dba_tab_statistics
            WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
            AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
            ORDER  BY table_name)
  LOOP
    p('  ' || RPAD(r.tn, 26) || LPAD(NVL(TO_CHAR(r.nr), 'null'), 14)
      || LPAD(NVL(TO_CHAR(r.bl), 'null'), 10) || '  ' || NVL(r.lk, 'no'));
  END LOOP;

  -- ==================================================================
  hdr('STEP 6 - VERDICT');
  -- ==================================================================
  IF NOT v_run THEN
    p('  DRY RUN COMPLETE. Nothing changed.');
    p('  To apply, edit the DECLARE section:  c_mode := EXECUTE');
  ELSIF v_go THEN
    p('  *** GO ***  FSQUA is prod-like and the fix is in place.');
    p(' ');
    p('    RUN CONTROL                       WAS      NOW      TARGET');
    p('    ------------------------------    ------   ------   ------');
    p('    FDC_COMBO_BUILD_MASTER_RUNCNTL    72.7 m   202.3 m  73 m');
    p('    coa                               13.4 m    80.8 m  13 m');
    p(' ');
    p('  WAS is the pre-upgrade FPRD average for that run control.');
    p('  Ask the user to enable AE timings and note the process instance.');
    p('  Afterwards, statistics share of DB time should fall from about');
    p('  82 percent to single digits.');
  ELSE
    p('  *** NO-GO ***  ' || v_bad || ' check(s) failed. Do not test yet.');
    p('  Send the failing lines and the STEP 2 and STEP 0 output on.');
  END IF;

  p(' ');
  p('  Undo the fix. Drop the override switch FIRST:');
  p('    BEGIN');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''PREFERENCE_OVERRIDES_PARAMETER'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''ESTIMATE_PERCENT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''METHOD_OPT'');');
  p('      DBMS_STATS.DELETE_TABLE_PREFS(''SYSADM'', ''' || c_fixtable
    || ''', ''CASCADE'');');
  p('    END;');
  p('    /');

  p(RPAD('=', 116, '='));
  p('END   db=' || v_db || '   mode=' || c_mode || '   failed_checks=' || v_bad
    || '   verdict=' || CASE WHEN NOT v_run THEN 'DRY RUN'
                             WHEN v_go THEN 'GO' ELSE 'NO-GO' END);
END;
/

SPOOL OFF

SET HEADING ON
SET FEEDBACK ON
SET PAGESIZE 5000
