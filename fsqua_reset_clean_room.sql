-- =====================================================================
-- fsqua_reset_clean_room.sql
-- Target : FSQUA ONLY. Never run this in FPRD or FSTRN.
-- Purpose: Undo the manually applied SQL patches and synthetic/locked
--          statistics so the next FS_CEBD run is a valid reproduction
--          of the FPRD regression rather than a test of the patches.
-- Input  : NONE, except the safety switch below.
-- Safety : Defaults to DRY RUN. It prints exactly what it would do and
--          changes nothing until you flip the switch.
-- Order  : run AFTER the current job finishes and AFTER
--          fsqua_fs_cebd_collect.sql has captured this run.
-- =====================================================================

SET ECHO OFF
SET FEEDBACK ON
SET VERIFY OFF
SET LINESIZE 300
SET PAGESIZE 5000
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

-- ---------------------------------------------------------------------
-- SAFETY SWITCH.  DRY_RUN  -> report only, no change.
--                 EXECUTE  -> actually apply.
-- Change the one word below when you are ready.
-- ---------------------------------------------------------------------
DEFINE mode = DRY_RUN

SPOOL fsqua_reset_clean_room.log

PROMPT
PROMPT ==== GUARD: confirm this is FSQUA ====================================
SELECT d.name db_name, i.instance_name, i.host_name, d.open_mode,
       CASE WHEN UPPER(d.name) LIKE 'FSQUA%' THEN 'OK TO PROCEED'
            ELSE 'STOP - THIS IS NOT FSQUA' END guard
FROM   v$database d CROSS JOIN v$instance i;

PROMPT
PROMPT ==== STEP 1: SQL patches ============================================
DECLARE
  v_mode  VARCHAR2(20) := UPPER('~mode');
  v_db    VARCHAR2(30);
  v_n     PLS_INTEGER := 0;
BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;
  IF v_db NOT LIKE 'FSQUA%' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Refusing to run: database is ' || v_db || ', not FSQUA.');
  END IF;

  FOR p IN (SELECT name, status, created FROM dba_sql_patches ORDER BY created)
  LOOP
    v_n := v_n + 1;
    IF v_mode = 'EXECUTE' THEN
      BEGIN
        DBMS_SQLDIAG.DROP_SQL_PATCH(name => p.name, ignore => TRUE);
        DBMS_OUTPUT.PUT_LINE('DROPPED  patch ' || p.name);
      EXCEPTION WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('FAILED   patch ' || p.name || ' : ' || SQLERRM);
      END;
    ELSE
      DBMS_OUTPUT.PUT_LINE('would drop patch ' || p.name
        || '  status=' || p.status || '  created=' || TO_CHAR(p.created, 'YYYY-MM-DD HH24:MI:SS'));
    END IF;
  END LOOP;
  IF v_n = 0 THEN
    DBMS_OUTPUT.PUT_LINE('No SQL patches present.');
  END IF;
END;
/

PROMPT
PROMPT ==== STEP 2: statistics - unlock, then restore to pre-tamper point ==
PROMPT -- The restore timestamp is derived automatically: one minute before
PROMPT -- the earliest SQL patch was created, which is when the tampering
PROMPT -- session ran. If no patches remain, it falls back to the newest
PROMPT -- stats-history entry that predates the current day.
DECLARE
  v_mode    VARCHAR2(20) := UPPER('~mode');
  v_db      VARCHAR2(30);
  v_asof    TIMESTAMP WITH TIME ZONE;
  v_oldest  TIMESTAMP WITH TIME ZONE;
  v_n       PLS_INTEGER := 0;
  v_ok      PLS_INTEGER := 0;
  v_fail    PLS_INTEGER := 0;
BEGIN
  SELECT UPPER(name) INTO v_db FROM v$database;
  IF v_db NOT LIKE 'FSQUA%' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Refusing to run: database is ' || v_db || ', not FSQUA.');
  END IF;

  BEGIN
    SELECT CAST(MIN(created) AS TIMESTAMP) - INTERVAL '1' MINUTE
    INTO   v_asof
    FROM   dba_sql_patches;
  EXCEPTION WHEN OTHERS THEN
    v_asof := NULL;
  END;

  IF v_asof IS NULL THEN
    BEGIN
      SELECT MAX(stats_update_time)
      INTO   v_asof
      FROM   dba_tab_stats_history
      WHERE  owner = 'SYSADM'
      AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
      AND    stats_update_time < CAST(TRUNC(SYSDATE) AS TIMESTAMP);
    EXCEPTION WHEN OTHERS THEN
      v_asof := NULL;
    END;
  END IF;

  v_oldest := DBMS_STATS.GET_STATS_HISTORY_AVAILABILITY;
  DBMS_OUTPUT.PUT_LINE('stats history available from : ' || TO_CHAR(v_oldest, 'YYYY-MM-DD HH24:MI:SS'));
  DBMS_OUTPUT.PUT_LINE('restore target timestamp     : '
    || NVL(TO_CHAR(v_asof, 'YYYY-MM-DD HH24:MI:SS'), 'COULD NOT DERIVE'));

  IF v_asof IS NOT NULL AND v_asof < v_oldest THEN
    DBMS_OUTPUT.PUT_LINE('WARNING: target predates retained history. Restore will fail; '
      || 'stats will only be unlocked.');
  END IF;

  FOR t IN (SELECT DISTINCT table_name, stattype_locked
            FROM   dba_tab_statistics
            WHERE  owner = 'SYSADM'
            AND    object_type = 'TABLE'
            AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
            ORDER  BY table_name)
  LOOP
    v_n := v_n + 1;
    IF v_mode = 'EXECUTE' THEN
      IF t.stattype_locked IS NOT NULL THEN
        BEGIN
          DBMS_STATS.UNLOCK_TABLE_STATS('SYSADM', t.table_name);
          DBMS_OUTPUT.PUT_LINE('UNLOCKED ' || t.table_name);
        EXCEPTION WHEN OTHERS THEN
          DBMS_OUTPUT.PUT_LINE('UNLOCK FAILED ' || t.table_name || ' : ' || SQLERRM);
        END;
      END IF;

      IF v_asof IS NOT NULL THEN
        BEGIN
          DBMS_STATS.RESTORE_TABLE_STATS(
            ownname         => 'SYSADM',
            tabname         => t.table_name,
            as_of_timestamp => v_asof,
            force           => TRUE,
            no_invalidate   => FALSE);
          v_ok := v_ok + 1;
          DBMS_OUTPUT.PUT_LINE('RESTORED ' || t.table_name);
        EXCEPTION WHEN OTHERS THEN
          v_fail := v_fail + 1;
          DBMS_OUTPUT.PUT_LINE('RESTORE FAILED ' || t.table_name || ' : ' || SQLERRM
            || '  (left unlocked; the AE percent-UpdateStats step will regather)');
        END;
      END IF;
    ELSE
      DBMS_OUTPUT.PUT_LINE('would unlock+restore ' || RPAD(t.table_name, 26)
        || ' locked=' || NVL(t.stattype_locked, 'NO'));
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE('tables considered ' || v_n
    || '   restored ' || v_ok || '   restore failures ' || v_fail);
END;
/

PROMPT
PROMPT ==== STEP 3: parallel degree =======================================
PROMPT -- Not done here on purpose. The original degree is unknown and must
PROMPT -- not be guessed. Run fprd_generate_reset_ddl.sql against FPRD, then
PROMPT -- run the generated fsqua_restore_degree.gen.sql here.
SELECT 'TABLE' obj_class, table_name obj_name, degree
FROM   dba_tables
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
UNION ALL
SELECT 'INDEX', index_name, degree
FROM   dba_indexes
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
ORDER  BY 1, 2;

PROMPT
PROMPT ==== STEP 4: post-reset verification ===============================
SELECT COUNT(*) remaining_sql_patches FROM dba_sql_patches;

SELECT table_name, num_rows, blocks, avg_row_len, last_analyzed,
       stattype_locked
FROM   dba_tab_statistics
WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
AND    (table_name LIKE 'PS_FS_CEBD%' OR table_name LIKE 'PS_COMBO_DATA%')
ORDER  BY table_name;

SPOOL OFF

SET DEFINE ON
PROMPT
PROMPT Mode was: ~mode
PROMPT To apply for real, change the DEFINE near the top to EXECUTE and rerun.
PROMPT
