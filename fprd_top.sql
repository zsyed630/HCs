-- =====================================================================
--  fprd_top.sql        LIVE VIEW  -  cheap enough to run every 30s
--
--  One screen. Run it in a tight loop alongside the 10-minute pulse.
--  Read only, no parallel, excludes its own SQL.
--
--      watch -n 30 "sqlplus -S / as sysdba @fprd_top.sql"
--
--  or without watch:
--      while true; do clear; sqlplus -S / as sysdba @fprd_top.sql; sleep 30; done
-- =====================================================================

SET DEFINE OFF
SET LINESIZE 140
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

ALTER SESSION DISABLE PARALLEL QUERY;

DECLARE
  v_beg   DATE;
  v_fin   DATE;
  v_pi    NUMBER;
  v_oprid VARCHAR2(64);
  v_rc    VARCHAR2(64);
  v_mins  NUMBER;
  v_nr    NUMBER;
  v_ss    NUMBER;
  v_la    DATE;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN DBMS_OUTPUT.PUT_LINE(s); END p;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(NVL(s,' '), CHR(10),' '), CHR(13),' '),1,n);
  END clean;

BEGIN
  BEGIN
    SELECT /* FSCEBD_PULSE */ PRCSINSTANCE, RUNCNTLID, OPRID, BEGINDTTM, ENDDTTM
    INTO   v_pi, v_rc, v_oprid, v_beg, v_fin
    FROM  (SELECT PRCSINSTANCE, RUNCNTLID, OPRID, BEGINDTTM, ENDDTTM
           FROM   SYSADM.PSPRCSRQST
           WHERE  PRCSNAME='FS_CEBD' AND BEGINDTTM IS NOT NULL
           ORDER  BY BEGINDTTM DESC)
    WHERE ROWNUM=1;
    v_mins := ROUND((NVL(v_fin,SYSDATE)-v_beg)*1440,1);
  EXCEPTION WHEN OTHERS THEN
    v_beg := SYSDATE-1/24; v_oprid := 'NONE'; v_mins := 0;
  END;

  p(RPAD('=',138,'='));
  p('FS_CEBD  ' || TO_CHAR(SYSDATE,'HH24:MI:SS')
    || '   pi=' || NVL(TO_CHAR(v_pi),'-')
    || '   ' || NVL(v_rc,'-')
    || '   elapsed=' || v_mins || 'm'
    || CASE WHEN v_fin IS NULL THEN '  RUNNING' ELSE '  DONE' END
    || '   targets: 72.7 good / 202.3 bad');
  p(RPAD('=',138,'='));

  -- sample percentage, the one number that matters
  BEGIN
    SELECT /* FSCEBD_PULSE */ num_rows, sample_size, last_analyzed
    INTO   v_nr, v_ss, v_la FROM dba_tab_statistics
    WHERE  owner='SYSADM' AND table_name='PS_COMBO_DATA_TBL'
    AND    object_type='TABLE';
    p('SAMPLE  PS_COMBO_DATA_TBL  ' || NVL(TO_CHAR(v_ss),'null') || ' of '
      || NVL(TO_CHAR(v_nr),'null') || '  = '
      || NVL(TO_CHAR(ROUND(v_ss/NULLIF(v_nr,0)*100,2)),'?') || '%'
      || '   analyzed ' || NVL(TO_CHAR(v_la,'MM-DD HH24:MI:SS'),'never')
      || CASE WHEN v_la IS NULL OR v_la < v_beg THEN '   (not yet this run)'
              WHEN v_ss/NULLIF(v_nr,0)*100 <= 5 THEN '   FIX WORKING'
              ELSE '   ** STILL 100 PERCENT **' END);
  EXCEPTION WHEN OTHERS THEN p('SAMPLE  unreadable'); END;

  p(' ');
  p('LIVE SESSIONS');
  p('  ' || RPAD('INST',5) || RPAD('SID',7) || RPAD('SQL_ID',15)
    || RPAD('PLAN_HASH',12) || RPAD('STATE',8) || RPAD('EVENT',32)
    || LPAD('WAIT_S',8));
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     s.inst_id i, s.sid sd, s.sql_id sq,
                     q.plan_hash_value ph,
                     s.state st, s.event ev, s.seconds_in_wait sw
              FROM   gv$session s
              LEFT   JOIN gv$sql q ON q.inst_id = s.inst_id
                                  AND q.sql_id = s.sql_id
                                  AND q.child_number = s.sql_child_number
              WHERE  s.username='SYSADM'
              AND    (UPPER(s.client_identifier) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(s.program) LIKE '%PSAE%')
              ORDER  BY s.logon_time)
    LOOP
      p('  ' || RPAD(r.i,5) || RPAD(r.sd,7) || RPAD(NVL(r.sq,'-'),15)
        || RPAD(NVL(TO_CHAR(r.ph),'-'),12) || RPAD(NVL(r.st,'-'),8)
        || RPAD(clean(r.ev,30),32) || LPAD(NVL(r.sw,0),8));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed'); END;

  p(' ');
  p('TOP SQL, LAST 5 MINUTES');
  p('  ' || RPAD('SQL_ID',15) || RPAD('PLAN_HASH',12) || LPAD('DB_S',7)
    || LPAD('PCT',6) || '  ' || RPAD('TOP EVENT',30) || 'TEXT');
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     h.sql_id sq, h.sql_plan_hash_value ph, COUNT(*) secs,
                     ROUND(RATIO_TO_REPORT(COUNT(*)) OVER ()*100,1) pc,
                     MAX(CASE WHEN h.session_state='ON CPU' THEN 'ON CPU'
                              ELSE NVL(h.event,'-') END) KEEP
                       (DENSE_RANK FIRST ORDER BY h.sample_time DESC) ev,
                     MIN(DBMS_LOB.SUBSTR(q.sql_fulltext,44,1)) tx
              FROM   gv$active_session_history h
              LEFT   JOIN gv$sqlstats q ON q.sql_id=h.sql_id
              WHERE  h.sample_time > SYSTIMESTAMP - INTERVAL '5' MINUTE
              AND    h.sql_id IS NOT NULL
              AND    (UPPER(h.client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(h.program) LIKE '%PSAE%')
              AND    NVL(UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1)),' ')
                       NOT LIKE '%FSCEBD_PULSE%'
              GROUP  BY h.sql_id, h.sql_plan_hash_value
              ORDER  BY 3 DESC FETCH FIRST 8 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.sq,15) || RPAD(NVL(TO_CHAR(r.ph),'-'),12)
        || LPAD(r.secs,7) || LPAD(r.pc,6) || '  '
        || RPAD(clean(r.ev,28),30) || clean(r.tx,42));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed'); END;

  p(' ');
  p('WAIT CLASS, LAST 5 MINUTES');
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     CASE WHEN session_state='ON CPU' THEN 'CPU'
                          ELSE NVL(wait_class,'?') END wc,
                     COUNT(*) secs,
                     ROUND(RATIO_TO_REPORT(COUNT(*)) OVER ()*100,1) pc
              FROM   gv$active_session_history
              WHERE  sample_time > SYSTIMESTAMP - INTERVAL '5' MINUTE
              AND    (UPPER(client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY CASE WHEN session_state='ON CPU' THEN 'CPU'
                             ELSE NVL(wait_class,'?') END
              ORDER  BY 2 DESC)
    LOOP
      p('  ' || RPAD(r.wc,18) || LPAD(r.secs,8) || LPAD(r.pc,7) || '%');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed'); END;

  p(RPAD('=',138,'='));
END;
/

EXIT
