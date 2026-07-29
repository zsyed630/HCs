-- =====================================================================
--  fprd_pulse.sql        PRODUCTION MONITORING
--
--  Watches the FS_CEBD master build in FPRD. Read only. No input.
--  Designed to be run repeatedly for the length of the run.
--
--  PRODUCTION SAFETY - this differs from the QA version deliberately:
--
--    * ALTER SESSION DISABLE PARALLEL QUERY. The QA pulse grabbed PX
--      servers for its own monitoring queries and consumed about 51 DB
--      seconds of the run it was measuring. Not acceptable here.
--
--    * every query carries the marker FSCEBD_PULSE and every scan of
--      the shared pool excludes it, so the monitor cannot report on
--      itself. The QA version detected its own SQL as DBMS_STATS
--      activity and raised a false warning.
--
--    * section B leads with a single-row dictionary read rather than a
--      shared pool scan. It is the definitive test and costs nothing.
--
--    * shared pool scans are time-bounded and NO_PARALLEL hinted.
--
--  THE ONE NUMBER THAT MATTERS
--    PS_COMBO_DATA_TBL sample percentage. Before the change it gathered
--    at 100 percent. With ESTIMATE_PERCENT = 1 honoured it will read
--    about 1 percent. PS_COMBO_DATA_BUDG has no preference and stays at
--    100 percent, which makes it a built-in control.
--
--  BASELINES for FDC_COMBO_BUILD_MASTER_RUNCNTL, measured in FPRD
--    pre-upgrade   72.7 min   (11 runs)
--    post-upgrade 202.3 min   (3 runs, last was 186.7 on 07-15)
--    FSQUA with the fix, idle box   36.8 min
--    realistic expectation here     45 to 70 min
-- =====================================================================

SET DEFINE OFF
SET LINESIZE 150
SET PAGESIZE 0
SET HEADING OFF
SET FEEDBACK OFF
SET VERIFY OFF
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

-- keep the monitor off the parallel servers the job needs
ALTER SESSION DISABLE PARALLEL QUERY;

DECLARE
  c_good  CONSTANT NUMBER := 72.7;
  c_bad   CONSTANT NUMBER := 202.3;
  c_tab   CONSTANT VARCHAR2(30) := 'PS_COMBO_DATA_TBL';

  v_db     VARCHAR2(30);
  v_line   PLS_INTEGER := 0;

  v_pi     NUMBER;
  v_rc     VARCHAR2(64);
  v_oprid  VARCHAR2(64);
  v_beg    DATE;
  v_fin    DATE;
  v_stat   VARCHAR2(30);
  v_mins   NUMBER;
  v_live   BOOLEAN := FALSE;

  v_nr     NUMBER;
  v_ss     NUMBER;
  v_pct    NUMBER;
  v_la     DATE;

  v_tot    NUMBER := 0;
  v_stats  NUMBER := 0;
  v_app    NUMBER := 0;
  v_n      PLS_INTEGER := 0;

  PROCEDURE p(s IN VARCHAR2) IS
  BEGIN
    v_line := v_line + 1;
    DBMS_OUTPUT.PUT_LINE(s);
  END p;

  PROCEDURE hdr(s IN VARCHAR2) IS
  BEGIN
    p(' ');
    p(RPAD('=', 148, '='));
    p(s);
    p(RPAD('=', 148, '='));
  END hdr;

  FUNCTION clean(s IN VARCHAR2, n IN PLS_INTEGER) RETURN VARCHAR2 IS
  BEGIN
    RETURN SUBSTR(REPLACE(REPLACE(REPLACE(NVL(s,' '), CHR(10),' '),
                                  CHR(13),' '), CHR(9),' '), 1, n);
  END clean;

  FUNCTION pct(a IN NUMBER, b IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    IF NVL(b,0) = 0 THEN RETURN '0%'; END IF;
    RETURN TO_CHAR(ROUND(a*100/b)) || '%';
  END pct;

BEGIN
  SELECT /* FSCEBD_PULSE */ UPPER(name) INTO v_db FROM v$database;
  p(RPAD('=', 148, '='));
  p('FPRD PULSE v2    db=' || v_db || '    at='
    || TO_CHAR(SYSDATE,'YYYY-MM-DD HH24:MI:SS'));
  p(RPAD('=', 148, '='));

  -- ==================================================================
  hdr('A - RUN STATUS');
  -- ==================================================================
  BEGIN
    SELECT /* FSCEBD_PULSE */ PRCSINSTANCE, RUNCNTLID, OPRID, RUNSTATUS,
           BEGINDTTM, ENDDTTM
    INTO   v_pi, v_rc, v_oprid, v_stat, v_beg, v_fin
    FROM  (SELECT PRCSINSTANCE, RUNCNTLID, OPRID, RUNSTATUS, BEGINDTTM, ENDDTTM
           FROM   SYSADM.PSPRCSRQST
           WHERE  PRCSNAME='FS_CEBD' AND BEGINDTTM IS NOT NULL
           ORDER  BY BEGINDTTM DESC)
    WHERE ROWNUM = 1;
    v_live := (v_fin IS NULL);
    v_mins := ROUND((NVL(v_fin,SYSDATE) - v_beg)*1440, 1);

    p('  process instance : ' || v_pi || '     run control : ' || NVL(v_rc,'(null)'));
    p('  oprid            : ' || v_oprid || '     status : ' || v_stat);
    p('  started          : ' || TO_CHAR(v_beg,'YYYY-MM-DD HH24:MI:SS')
      || CASE WHEN v_live THEN '    RUNNING'
              ELSE '    finished ' || TO_CHAR(v_fin,'HH24:MI:SS') END);
    p('  elapsed          : ' || v_mins || ' minutes');
    p(' ');
    p('  vs pre-upgrade  72.7 min : ' || pct(v_mins, c_good));
    p('  vs post-upgrade 202.3 min: ' || pct(v_mins, c_bad));
    IF v_live AND v_mins > 90 THEN
      p('  >> past 90 minutes. Read section B and D before assuming trouble;');
      p('     production concurrency alone can account for this.');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  no FS_CEBD run found: ' || SUBSTR(SQLERRM,1,60));
    v_beg := SYSDATE - 1/24; v_oprid := 'NONE';
  END;

  p(' ');
  p('  ' || RPAD('INST',6) || RPAD('SID',8) || RPAD('SERIAL',9)
    || RPAD('SQL_ID',15) || RPAD('PLAN_HASH',13) || RPAD('STATE',9)
    || RPAD('EVENT',34) || 'SECS');
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     s.inst_id i, s.sid sd, s.serial# sr, s.sql_id sq,
                     q.plan_hash_value ph, s.state st, s.event ev,
                     s.seconds_in_wait sw
              FROM   gv$session s
              LEFT   JOIN gv$sql q ON q.inst_id = s.inst_id
                                  AND q.sql_id = s.sql_id
                                  AND q.child_number = s.sql_child_number
              WHERE  s.username='SYSADM'
              AND    (UPPER(s.client_identifier) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(s.program) LIKE '%PSAE%')
              ORDER  BY s.logon_time)
    LOOP
      p('  ' || RPAD(r.i,6) || RPAD(r.sd,8) || RPAD(r.sr,9)
        || RPAD(NVL(r.sq,'-'),15) || RPAD(NVL(TO_CHAR(r.ph),'-'),13)
        || RPAD(NVL(r.st,'-'),9)
        || RPAD(clean(r.ev,32),34) || NVL(r.sw,0));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  session lookup: ' || SUBSTR(SQLERRM,1,50));
  END;

  -- ==================================================================
  hdr('B - IS THE FIX WORKING   (read this first)');
  -- ==================================================================
  BEGIN
    SELECT /* FSCEBD_PULSE */ num_rows, sample_size, last_analyzed
    INTO   v_nr, v_ss, v_la
    FROM   dba_tab_statistics
    WHERE  owner='SYSADM' AND table_name=c_tab AND object_type='TABLE';
    v_pct := ROUND(v_ss/NULLIF(v_nr,0)*100, 2);

    p('  ' || RPAD(c_tab,26) || ' rows=' || NVL(TO_CHAR(v_nr),'null')
      || '  sample=' || NVL(TO_CHAR(v_ss),'null')
      || '  = ' || NVL(TO_CHAR(v_pct),'?') || '%');
    p('  last analyzed : ' || NVL(TO_CHAR(v_la,'YYYY-MM-DD HH24:MI:SS'),'never'));
    p(' ');
    IF v_la IS NULL OR v_la < v_beg THEN
      p('  >> not gathered yet in this run. No verdict available.');
    ELSIF v_pct <= 5 THEN
      p('  >> WORKING. Sampling at ' || v_pct || ' percent, not 100.');
      p('     ESTIMATE_PERCENT is being honoured over the DDL model.');
    ELSE
      p('  >> NOT WORKING. Still sampling at ' || v_pct || ' percent.');
      p('     The preference is not overriding the model. Check that all');
      p('     four preferences are still present on ' || c_tab || '.');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p('  read failed: ' || SUBSTR(SQLERRM,1,60));
  END;

  p(' ');
  p('  Control group. This table has no preference and must stay at 100%:');
  BEGIN
    SELECT /* FSCEBD_PULSE */ num_rows, sample_size
    INTO   v_nr, v_ss
    FROM   dba_tab_statistics
    WHERE  owner='SYSADM' AND table_name='PS_COMBO_DATA_BUDG'
    AND    object_type='TABLE';
    p('  PS_COMBO_DATA_BUDG         rows=' || NVL(TO_CHAR(v_nr),'null')
      || '  sample=' || NVL(TO_CHAR(v_ss),'null')
      || '  = ' || NVL(TO_CHAR(ROUND(v_ss/NULLIF(v_nr,0)*100,2)),'?') || '%');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  p(' ');
  p('  Preferences still in place:');
  BEGIN
    FOR r IN (SELECT /* FSCEBD_PULSE */ preference_name pn, preference_value pv
              FROM   dba_tab_stat_prefs
              WHERE  owner='SYSADM' AND table_name=c_tab
              ORDER  BY preference_name)
    LOOP
      p('    ' || RPAD(r.pn,34) || clean(r.pv,40));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('    unreadable'); END;

  p(' ');
  p('  Global preferences, for the tables that have no override:');
  BEGIN
    p('    METHOD_OPT       = ' || DBMS_STATS.GET_PREFS('METHOD_OPT'));
    p('    ESTIMATE_PERCENT = ' || DBMS_STATS.GET_PREFS('ESTIMATE_PERCENT'));
    p('    CASCADE          = ' || DBMS_STATS.GET_PREFS('CASCADE'));
  EXCEPTION WHEN OTHERS THEN NULL; END;

  -- ==================================================================
  hdr('C - WAIT PROFILE, LAST 15 MINUTES');
  -- ==================================================================
  p('  ' || RPAD('WAIT CLASS',16) || RPAD('EVENT',44) || LPAD('DB_SECS',10)
    || LPAD('PCT',7));
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     CASE WHEN session_state='ON CPU' THEN 'CPU'
                          ELSE NVL(wait_class,'unknown') END wc,
                     CASE WHEN session_state='ON CPU' THEN 'ON CPU'
                          ELSE NVL(event,'unknown') END ev,
                     COUNT(*) secs,
                     ROUND(RATIO_TO_REPORT(COUNT(*)) OVER ()*100,1) pc
              FROM   gv$active_session_history
              WHERE  sample_time > SYSTIMESTAMP - INTERVAL '15' MINUTE
              AND    (UPPER(client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY CASE WHEN session_state='ON CPU' THEN 'CPU'
                             ELSE NVL(wait_class,'unknown') END,
                        CASE WHEN session_state='ON CPU' THEN 'ON CPU'
                             ELSE NVL(event,'unknown') END
              ORDER  BY 3 DESC FETCH FIRST 10 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.wc,16) || RPAD(clean(r.ev,42),44)
        || LPAD(r.secs,10) || LPAD(r.pc,7));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,50));
  END;

  -- ==================================================================
  hdr('D - TOP SQL AND THE STATISTICS SHARE');
  -- ==================================================================
  BEGIN
    SELECT /* FSCEBD_PULSE */
           NVL(SUM(secs),0),
           NVL(SUM(CASE WHEN is_stats=1 THEN secs ELSE 0 END),0),
           NVL(SUM(CASE WHEN is_stats=0 THEN secs ELSE 0 END),0)
    INTO   v_tot, v_stats, v_app
    FROM (
      SELECT /*+ NO_PARALLEL */
             CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1))
                       LIKE '%DBMS_STATS%' THEN 1 ELSE 0 END is_stats,
             COUNT(*) secs
      FROM   gv$active_session_history h
      LEFT   JOIN gv$sql q ON q.sql_id=h.sql_id AND q.inst_id=h.inst_id
                          AND q.child_number=0
      WHERE  h.sample_time >= CAST(v_beg AS TIMESTAMP)
      AND    (UPPER(h.client_id) LIKE '%'||UPPER(v_oprid)||'%'
              OR UPPER(h.program) LIKE '%PSAE%')
      AND    NVL(UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1)),' ')
               NOT LIKE '%FSCEBD_PULSE%'
      GROUP  BY CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1))
                          LIKE '%DBMS_STATS%' THEN 1 ELSE 0 END);
  EXCEPTION WHEN OTHERS THEN
    p('  split failed: ' || SUBSTR(SQLERRM,1,50));
  END;

  p('  total db seconds : ' || v_tot);
  p('  statistics       : ' || v_stats || '   (' || pct(v_stats,v_tot) || ')');
  p('  application sql  : ' || v_app   || '   (' || pct(v_app,v_tot) || ')');
  p(' ');
  p('  Reference: FPRD run 26068516 was 82 percent statistics.');
  p('             FSQUA with the fix was 36 percent.');

  p(' ');
  p('  ' || RPAD('SQL_ID',15) || RPAD('KIND',8) || LPAD('DB_SECS',9)
    || LPAD('PLANS',7) || '  TEXT');
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     h.sql_id sq,
                     CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1))
                               LIKE '%DBMS_STATS%' THEN 'STATS' ELSE 'app' END kd,
                     COUNT(*) secs,
                     COUNT(DISTINCT h.sql_plan_hash_value) pl,
                     MIN(DBMS_LOB.SUBSTR(q.sql_fulltext,60,1)) tx
              FROM   gv$active_session_history h
              LEFT   JOIN gv$sql q ON q.sql_id=h.sql_id AND q.inst_id=h.inst_id
                                  AND q.child_number=0
              WHERE  h.sample_time >= CAST(v_beg AS TIMESTAMP)
              AND    h.sql_id IS NOT NULL
              AND    (UPPER(h.client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(h.program) LIKE '%PSAE%')
              AND    NVL(UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1)),' ')
                       NOT LIKE '%FSCEBD_PULSE%'
              GROUP  BY h.sql_id,
                     CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1))
                               LIKE '%DBMS_STATS%' THEN 'STATS' ELSE 'app' END
              ORDER  BY 3 DESC FETCH FIRST 12 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.sq,15) || RPAD(r.kd,8) || LPAD(r.secs,9)
        || LPAD(r.pl,7) || '  ' || clean(r.tx,58));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,50));
  END;

  -- ==================================================================
  hdr('E - GATHERS DURING THIS RUN');
  -- ==================================================================
  p('  ' || RPAD('TABLE',30) || LPAD('GATHERS',9) || '  FIRST      LAST');
  BEGIN
    FOR r IN (SELECT /* FSCEBD_PULSE */ table_name tn, COUNT(*) g,
                     MIN(stats_update_time) f, MAX(stats_update_time) l
              FROM   dba_tab_stats_history
              WHERE  owner='SYSADM'
              AND    stats_update_time >= CAST(v_beg AS TIMESTAMP)
              GROUP  BY table_name ORDER BY 2 DESC FETCH FIRST 12 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.tn,30) || LPAD(r.g,9) || '  '
        || TO_CHAR(r.f,'HH24:MI:SS') || '   ' || TO_CHAR(r.l,'HH24:MI:SS'));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: ' || SUBSTR(SQLERRM,1,50));
  END;


  -- ==================================================================
  hdr('F - FULL SQL MANIFEST   every statement seen in this run');
  -- ==================================================================
  p('  No top-N cutoff. The complete inventory, ordered by DB time.');
  p(' ');
  p('  ' || RPAD('SQL_ID',15) || RPAD('PLAN_HASH',13) || RPAD('KIND',7)
    || LPAD('DB_SECS',9) || RPAD('  NODES',9) || RPAD('FIRST',11)
    || RPAD('LAST',11) || 'TEXT');
  p('  ' || RPAD('-',146,'-'));
  v_n := 0;
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     h.sql_id sq, NVL(h.sql_plan_hash_value,0) ph,
                     COUNT(*) secs,
                     LISTAGG(DISTINCT TO_CHAR(h.inst_id),',')
                       WITHIN GROUP (ORDER BY TO_CHAR(h.inst_id)) nodes,
                     TO_CHAR(MIN(h.sample_time),'HH24:MI:SS') f,
                     TO_CHAR(MAX(h.sample_time),'HH24:MI:SS') l,
                     MAX(CASE WHEN UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1))
                                   LIKE '%DBMS_STATS%' THEN 'STATS'
                              ELSE 'app' END) kd,
                     MIN(DBMS_LOB.SUBSTR(q.sql_fulltext,52,1)) tx
              FROM   gv$active_session_history h
              LEFT   JOIN gv$sqlstats q ON q.sql_id = h.sql_id
              WHERE  h.sample_time >= CAST(v_beg AS TIMESTAMP)
              AND    h.sql_id IS NOT NULL
              AND    (UPPER(h.client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(h.program) LIKE '%PSAE%')
              AND    NVL(UPPER(DBMS_LOB.SUBSTR(q.sql_fulltext,300,1)),' ')
                       NOT LIKE '%FSCEBD_PULSE%'
              GROUP  BY h.sql_id, NVL(h.sql_plan_hash_value,0)
              ORDER  BY 3 DESC)
    LOOP
      v_n := v_n + 1;
      p('  ' || RPAD(r.sq,15) || RPAD(r.ph,13) || RPAD(r.kd,7)
        || LPAD(r.secs,9) || RPAD('  '||r.nodes,9) || RPAD(r.f,11)
        || RPAD(r.l,11) || clean(r.tx,50));
    END LOOP;
    p(' ');
    p('  distinct sql_id and plan combinations: ' || v_n);
  EXCEPTION WHEN OTHERS THEN p('  failed: '||SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('G - CURSOR METRICS   execs, timings, io, rows');
  -- ==================================================================
  p('  From GV$SQLSTATS. A statement in section F but missing here has');
  p('  aged out of the shared pool.');
  p(' ');
  p('  ' || RPAD('SQL_ID',15) || RPAD('PLAN_HASH',13) || LPAD('EXECS',8)
    || LPAD('ELAPSED_S',11) || LPAD('CPU_S',10) || LPAD('IO_S',10)
    || LPAD('S/EXEC',9) || LPAD('GETS/EXEC',12) || LPAD('ROWS/EXEC',11)
    || LPAD('PX',6));
  p('  ' || RPAD('-',146,'-'));
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     s.sql_id sq, s.plan_hash_value ph,
                     SUM(s.executions) ex,
                     ROUND(SUM(s.elapsed_time)/1e6,1) el,
                     ROUND(SUM(s.cpu_time)/1e6,1) cp,
                     ROUND(SUM(s.user_io_wait_time)/1e6,1) io,
                     ROUND(SUM(s.elapsed_time)/1e6
                           /GREATEST(SUM(s.executions),1),2) spe,
                     ROUND(SUM(s.buffer_gets)/GREATEST(SUM(s.executions),1)) gpe,
                     ROUND(SUM(s.rows_processed)/GREATEST(SUM(s.executions),1)) rpe,
                     SUM(s.px_servers_executions) px
              FROM   gv$sql s
              WHERE  s.last_active_time >= v_beg
              AND    s.parsing_schema_name = 'SYSADM'
              AND    UPPER(DBMS_LOB.SUBSTR(s.sql_fulltext,300,1))
                       NOT LIKE '%FSCEBD_PULSE%'
              GROUP  BY s.sql_id, s.plan_hash_value
              ORDER  BY 4 DESC FETCH FIRST 30 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.sq,15) || RPAD(NVL(TO_CHAR(r.ph),'-'),13)
        || LPAD(NVL(r.ex,0),8) || LPAD(r.el,11) || LPAD(r.cp,10)
        || LPAD(r.io,10) || LPAD(r.spe,9) || LPAD(NVL(r.gpe,0),12)
        || LPAD(NVL(r.rpe,0),11) || LPAD(NVL(r.px,0),6));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: '||SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('H - PLAN LINE HOTSPOTS   which operation burns the time');
  -- ==================================================================
  p('  ' || RPAD('SQL_ID',15) || RPAD('PLAN_HASH',13) || LPAD('LINE',6)
    || RPAD('  OPERATION',30) || RPAD('OPTIONS',22) || LPAD('DB_SECS',9)
    || LPAD('PCT',7));
  p('  ' || RPAD('-',146,'-'));
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     sql_id sq, sql_plan_hash_value ph, sql_plan_line_id ln,
                     sql_plan_operation op, sql_plan_options ops,
                     COUNT(*) secs,
                     ROUND(RATIO_TO_REPORT(COUNT(*)) OVER ()*100,1) pc
              FROM   gv$active_session_history
              WHERE  sample_time >= CAST(v_beg AS TIMESTAMP)
              AND    sql_plan_operation IS NOT NULL
              AND    (UPPER(client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY sql_id, sql_plan_hash_value, sql_plan_line_id,
                        sql_plan_operation, sql_plan_options
              ORDER  BY 6 DESC FETCH FIRST 20 ROWS ONLY)
    LOOP
      p('  ' || RPAD(r.sq,15) || RPAD(NVL(TO_CHAR(r.ph),'-'),13)
        || LPAD(NVL(TO_CHAR(r.ln),'-'),6) || RPAD('  '||clean(r.op,28),30)
        || RPAD(clean(NVL(r.ops,'-'),20),22) || LPAD(r.secs,9)
        || LPAD(r.pc,7));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: '||SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('I - PLAN INSTABILITY   more than one plan for one statement');
  -- ==================================================================
  v_n := 0;
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     sql_id sq, COUNT(DISTINCT sql_plan_hash_value) plans,
                     LISTAGG(DISTINCT TO_CHAR(sql_plan_hash_value),' ')
                       WITHIN GROUP (ORDER BY TO_CHAR(sql_plan_hash_value)) phs,
                     COUNT(*) secs
              FROM   gv$active_session_history
              WHERE  sample_time >= CAST(v_beg AS TIMESTAMP)
              AND    sql_id IS NOT NULL AND sql_plan_hash_value > 0
              AND    (UPPER(client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY sql_id
              HAVING COUNT(DISTINCT sql_plan_hash_value) > 1
              ORDER  BY 4 DESC)
    LOOP
      v_n := v_n + 1;
      p('  ' || RPAD(r.sq,15) || ' plans=' || r.plans
        || '  db_secs=' || r.secs || '   ' || clean(r.phs,90));
    END LOOP;
    IF v_n = 0 THEN
      p('  none. Every statement ran a single plan throughout.');
    ELSE
      p(' ');
      p('  A statement switching plans mid-run is worth investigating. A one');
      p('  percent sample gives less precise statistics, so this is exactly');
      p('  the risk the change introduces. Cross-check against section G.');
    END IF;
  EXCEPTION WHEN OTHERS THEN p('  failed: '||SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('J - ASH TIMELINE   10 minute buckets since the run started');
  -- ==================================================================
  p('  AAS is average active sessions in that bucket. A long stretch with');
  p('  the same dominant statement and a high AAS is the slow phase.');
  p(' ');
  p('  ' || RPAD('BUCKET',18) || LPAD('DB_SECS',9) || LPAD('AAS',7)
    || RPAD('  DOMINANT_SQL',18) || RPAD('PLAN_HASH',13) || LPAD('DOM%',6));
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     TO_CHAR(bkt,'MM-DD HH24:MI') b,
                     SUM(secs) tot,
                     ROUND(SUM(secs)/600,1) aas,
                     MAX(sq) KEEP (DENSE_RANK FIRST ORDER BY secs DESC) dsq,
                     MAX(ph) KEEP (DENSE_RANK FIRST ORDER BY secs DESC) dph,
                     ROUND(MAX(secs) KEEP (DENSE_RANK FIRST ORDER BY secs DESC)
                           *100/GREATEST(SUM(secs),1)) dpc
              FROM (
                SELECT TRUNC(CAST(sample_time AS DATE),'HH24')
                       + FLOOR(TO_NUMBER(TO_CHAR(CAST(sample_time AS DATE),'MI'))/10)
                         *10/1440 bkt,
                       sql_id sq, sql_plan_hash_value ph, COUNT(*) secs
                FROM   gv$active_session_history
                WHERE  sample_time >= CAST(v_beg AS TIMESTAMP)
                AND    (UPPER(client_id) LIKE '%'||UPPER(v_oprid)||'%'
                        OR UPPER(program) LIKE '%PSAE%')
                GROUP  BY TRUNC(CAST(sample_time AS DATE),'HH24')
                       + FLOOR(TO_NUMBER(TO_CHAR(CAST(sample_time AS DATE),'MI'))/10)
                         *10/1440,
                       sql_id, sql_plan_hash_value)
              GROUP  BY bkt ORDER BY bkt)
    LOOP
      p('  ' || RPAD(r.b,18) || LPAD(r.tot,9) || LPAD(r.aas,7)
        || RPAD('  '||NVL(r.dsq,'-'),18) || RPAD(NVL(TO_CHAR(r.dph),'-'),13)
        || LPAD(r.dpc,6));
    END LOOP;
  EXCEPTION WHEN OTHERS THEN p('  failed: '||SUBSTR(SQLERRM,1,60));
  END;

  -- ==================================================================
  hdr('K - LONGOPS, TEMP, BLOCKING');
  -- ==================================================================
  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     inst_id i, sid sd, opname op, sofar sf, totalwork tw,
                     elapsed_seconds es, time_remaining tr
              FROM   gv$session_longops
              WHERE  totalwork>0 AND sofar<totalwork
              ORDER  BY elapsed_seconds DESC FETCH FIRST 6 ROWS ONLY)
    LOOP
      p('  longop inst=' || r.i || ' sid=' || r.sd || '  ' || clean(r.op,28)
        || '  ' || ROUND(r.sf/NULLIF(r.tw,0)*100,1) || '%  elapsed=' || r.es
        || 's  remaining=' || NVL(TO_CHAR(r.tr),'?') || 's');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     s.inst_id i, s.sid sd, s.event ev, s.seconds_in_wait sw,
                     s.blocking_instance bi, s.blocking_session bs
              FROM   gv$session s
              WHERE  s.blocking_session IS NOT NULL
              ORDER  BY s.seconds_in_wait DESC FETCH FIRST 6 ROWS ONLY)
    LOOP
      p('  BLOCKED inst=' || r.i || ' sid=' || r.sd || '  ' || clean(r.ev,32)
        || '  ' || r.sw || 's  blocker=' || r.bi || ':' || r.bs);
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  BEGIN
    FOR r IN (SELECT /*+ NO_PARALLEL */ /* FSCEBD_PULSE */
                     inst_id i,
                     ROUND(MAX(temp_space_allocated)/1073741824,2) tg,
                     ROUND(MAX(pga_allocated)/1073741824,2) pg
              FROM   gv$active_session_history
              WHERE  sample_time > SYSTIMESTAMP - INTERVAL '15' MINUTE
              AND    (UPPER(client_id) LIKE '%'||UPPER(v_oprid)||'%'
                      OR UPPER(program) LIKE '%PSAE%')
              GROUP  BY inst_id)
    LOOP
      p('  inst ' || r.i || '  peak temp=' || NVL(TO_CHAR(r.tg),'0')
        || ' GB   peak pga=' || NVL(TO_CHAR(r.pg),'0') || ' GB');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL; END;

  p(RPAD('=',126,'='));
  p('END PULSE   elapsed=' || NVL(TO_CHAR(v_mins),'?')
    || ' min   pre-upgrade target=' || c_good || ' min');
END;
/

EXIT
