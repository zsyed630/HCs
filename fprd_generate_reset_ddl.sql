-- =====================================================================
-- fprd_generate_reset_ddl.sql
-- Target : FPRD  (production - READ ONLY, nothing is changed here)
-- Purpose: FPRD is the authority for what these objects are supposed to
--          look like. The Copilot script set NOPARALLEL in FSQUA without
--          recording the prior degree, so the correct degree cannot be
--          guessed - it has to be read from FPRD.
-- Output : a ready-to-run DDL block, printed to screen and spooled to
--          fsqua_restore_degree.gen.sql, to be executed in FSQUA.
-- Input  : NONE.
-- =====================================================================

SET ECHO OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET LINESIZE 300
SET PAGESIZE 0
SET TRIMSPOOL ON
SET HEADING OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE '~'

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

PROMPT
PROMPT -- ============ FPRD REFERENCE STATE (read this, change nothing) ====
PROMPT

SET HEADING ON
SET PAGESIZE 5000
SET FEEDBACK ON

COL table_name FORMAT A32
COL index_name FORMAT A32
COL degree     FORMAT A12

SELECT table_name, degree, instances, num_rows, blocks, last_analyzed,
       partitioned
FROM   dba_tables
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
ORDER  BY table_name;

SELECT index_name, table_name, degree, instances, uniqueness, status,
       num_rows, last_analyzed
FROM   dba_indexes
WHERE  owner = 'SYSADM'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
ORDER  BY table_name, index_name;

SELECT table_name, num_rows, blocks, avg_row_len, sample_size,
       last_analyzed, stattype_locked, stale_stats
FROM   dba_tab_statistics
WHERE  owner = 'SYSADM' AND object_type = 'TABLE'
AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
ORDER  BY table_name;

PROMPT
PROMPT -- FPRD must have ZERO of these. If any row returns, FPRD is also
PROMPT -- contaminated and the scope of this problem just grew.
SELECT name, status, created, description FROM dba_sql_patches ORDER BY created;
SELECT name, status, force_matching, created FROM dba_sql_profiles ORDER BY created;

PROMPT
PROMPT -- ============ GENERATED DDL FOR FSQUA ============================
PROMPT

SET HEADING OFF
SET PAGESIZE 0
SET FEEDBACK OFF

SPOOL fsqua_restore_degree.gen.sql

DECLARE
  v_n PLS_INTEGER := 0;
BEGIN
  DBMS_OUTPUT.PUT_LINE('-- Generated from FPRD on ' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
  DBMS_OUTPUT.PUT_LINE('-- Run this in FSQUA only. Restores parallel degree to the FPRD value.');
  DBMS_OUTPUT.PUT_LINE(' ');

  FOR t IN (SELECT table_name, TRIM(degree) deg
            FROM   dba_tables
            WHERE  owner = 'SYSADM'
            AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
            ORDER  BY table_name)
  LOOP
    v_n := v_n + 1;
    IF UPPER(t.deg) = 'DEFAULT' THEN
      DBMS_OUTPUT.PUT_LINE('ALTER TABLE SYSADM.' || t.table_name || ' PARALLEL;');
    ELSIF t.deg = '1' THEN
      DBMS_OUTPUT.PUT_LINE('ALTER TABLE SYSADM.' || t.table_name || ' NOPARALLEL;');
    ELSE
      DBMS_OUTPUT.PUT_LINE('ALTER TABLE SYSADM.' || t.table_name
        || ' PARALLEL (DEGREE ' || t.deg || ');');
    END IF;
  END LOOP;

  FOR i IN (SELECT index_name, TRIM(degree) deg
            FROM   dba_indexes
            WHERE  owner = 'SYSADM'
            AND    (table_name LIKE 'PS_COMBO_DATA%' OR table_name LIKE 'PS_FS_CEBD%')
            ORDER  BY index_name)
  LOOP
    v_n := v_n + 1;
    IF UPPER(i.deg) = 'DEFAULT' THEN
      DBMS_OUTPUT.PUT_LINE('ALTER INDEX SYSADM.' || i.index_name || ' PARALLEL;');
    ELSIF i.deg = '1' THEN
      DBMS_OUTPUT.PUT_LINE('ALTER INDEX SYSADM.' || i.index_name || ' NOPARALLEL;');
    ELSE
      DBMS_OUTPUT.PUT_LINE('ALTER INDEX SYSADM.' || i.index_name
        || ' PARALLEL (DEGREE ' || i.deg || ');');
    END IF;
  END LOOP;

  DBMS_OUTPUT.PUT_LINE(' ');
  DBMS_OUTPUT.PUT_LINE('-- ' || v_n || ' statement(s) generated.');
END;
/

SPOOL OFF

SET HEADING ON
SET PAGESIZE 5000
SET FEEDBACK ON
SET DEFINE ON

PROMPT
PROMPT Generated file: fsqua_restore_degree.gen.sql
PROMPT Review it, then run it in FSQUA as step 3 of the reset.
PROMPT
