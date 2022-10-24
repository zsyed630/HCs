set lines 400
set pages 200
set feedback off
set echo off
set scan on
set serverout on
set head off
set verify off

define STARTTIME='2022-09-12  07:00:00';
define ENDTIME='2022-09-19  19:00:00';


DECLARE
historical varchar2(100);
MOST_RECENT_EXEC_TIME number;
MOST_RECENT_EXEC_TIME_PERIOD varchar2(100) ;
obj_type varchar2(100);
fragmented_percentage number;
DEFINED_STARTTIME varchar2(100);
DEFINED_ENDTIME varchar2(100);
OBJECT_SIZE_GB number;
OBJECT_SIZE_MB number;
OBJECT_SIZE_KB number;
OBJECT_SIZE_BYTES number;
V_PCT_FREE number;
V_PCT_USED number;
V_INI_TRANS number;
V_LAST_ANALYZED date;
V_PHV number;
V_PHV_COUNT number;
V_SGA_MAX_SIZE varchar2(25);
V_SHARED_POOL_SIZE varchar2(25);
V_BUFFER_CACHE_SIZE varchar2(25);
V_CPU_COUNT number;
V_MIN_SNAP_ID number;
V_MAX_SNAP_ID number;
BEGIN
    select min(snap_id) into V_MIN_SNAP_ID from dba_hist_active_sess_history where sample_time BETWEEN TIMESTAMP '&STARTTIME' AND TIMESTAMP '&ENDTIME'; 
    select max(snap_id) into V_MAX_SNAP_ID from dba_hist_active_sess_history where sample_time BETWEEN TIMESTAMP '&STARTTIME' AND TIMESTAMP '&ENDTIME'; 
    select '&STARTTIME' into DEFINED_STARTTIME from dual;
    select '&ENDTIME' into DEFINED_ENDTIME from dual;

    dbms_output.put_line(chr(10));
    dbms_output.put_line('TOP OBJECTS BY MOST AMOUNT OF DML IN DATABASE FOR TIME PERIOD '||DEFINED_STARTTIME||' to '||DEFINED_ENDTIME);
    dbms_output.put_line('--------------------------------------------------------------');

    FOR v_unq_object_names in (select * from (select owner,object_name,subobject_name,object_type,sum(db_block_changes_delta) "db_block_changes_delta" from (SELECT distinct ss.snap_id,sego.owner,sego.object_name,sego.subobject_name,sego.object_type,seg.db_block_changes_delta FROM  dba_hist_seg_stat seg   JOIN  dba_hist_snapshot ss ON  seg.snap_id = ss.snap_id JOIN dba_hist_seg_stat_obj sego ON seg.DATAOBJ# = sego.DATAOBJ#  WHERE  ss.begin_interval_time BETWEEN TIMESTAMP '&STARTTIME' AND TIMESTAMP '&ENDTIME' and sego.owner not in ('SYS','** MISSING **','DBSNMP') and sego.object_type != 'LOB' group by ss.snap_id,sego.owner,sego.object_name,sego.subobject_name,sego.object_type,seg.db_block_changes_delta ORDER BY seg.db_block_changes_delta DESC) group by owner,object_name,subobject_name,object_type order by 5 desc) where rownum <= 200  )
    LOOP
--        select subobject_name into v_unq_object_names.subobject_name from dba_objects where data_object_id = v_unq_object_names.data_object_id;

            IF v_unq_object_names.object_type like '%PARTITION%'
            THEN

                select round(bytes) into OBJECT_SIZE_BYTES from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024/1024/1024) into OBJECT_SIZE_GB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024/1024) into OBJECT_SIZE_MB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024) into OBJECT_SIZE_KB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes) into OBJECT_SIZE_BYTES from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
            
                IF v_unq_object_names.object_type = 'INDEX PARTITION'
                THEN
                    select PCT_FREE into V_PCT_FREE from dba_ind_partitions where index_owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name ;
                    select INI_TRANS into V_INI_TRANS from dba_ind_partitions where index_owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name;
                    select LAST_ANALYZED into V_LAST_ANALYZED from dba_ind_partitions where index_owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name;
                ELSIF v_unq_object_names.object_type = 'INDEX SUBPARTITION'
                THEN
                    select PCT_FREE into V_PCT_FREE from dba_ind_subpartitions where index_owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name ;
                    select INI_TRANS into V_INI_TRANS from dba_ind_subpartitions where index_owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name;
                    select LAST_ANALYZED into V_LAST_ANALYZED from dba_ind_subpartitions where index_owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name;
                ELSIF v_unq_object_names.object_type = 'TABLE PARTITION'
                THEN
                    select PCT_FREE into V_PCT_FREE from dba_tab_partitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name;
                    select PCT_USED into V_PCT_USED from dba_tab_partitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name;
                    select INI_TRANS into V_INI_TRANS from dba_tab_partitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name;
                    select LAST_ANALYZED into V_LAST_ANALYZED from dba_tab_partitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name;
                ELSIF v_unq_object_names.object_type = 'TABLE SUBPARTITION'
                THEN
                    select PCT_FREE into V_PCT_FREE from dba_tab_subpartitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name;
                    select PCT_USED into V_PCT_USED from dba_tab_subpartitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name;
                    select INI_TRANS into V_INI_TRANS from dba_tab_subpartitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name;
                    select LAST_ANALYZED into V_LAST_ANALYZED from dba_tab_subpartitions where table_owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name and subpartition_name = v_unq_object_names.subobject_name;
                END IF;


                declare
                v_freespace1_bytes number;
                v_freespace2_bytes number;
                v_freespace3_bytes number;
                v_freespace4_bytes number;
                v_freespace1_blocks number;
                v_freespace2_blocks number;
                v_freespace3_blocks number;
                v_freespace4_blocks number;
                v_full_bytes number;
                v_full_blocks number;
                v_unformatted_bytes number;
                v_unformatted_blocks number;
                fragmented_percentage number;
                OBJECT_SIZE_BYTES number;
                BEGIN
                dbms_space.space_usage(
                segment_owner   => v_unq_object_names.owner,
                segment_name    => v_unq_object_names.object_name,
                segment_type    => v_unq_object_names.object_type,
                partition_name  => v_unq_object_names.subobject_name,
                fs1_bytes               => v_freespace1_bytes,
                fs1_blocks              => v_freespace1_blocks,
                fs2_bytes               => v_freespace2_bytes,
                fs2_blocks              => v_freespace2_blocks,
                fs3_bytes               => V_freespace3_bytes,
                fs3_blocks              => v_freespace3_blocks,
                fs4_bytes               => v_freespace4_bytes,
                fs4_blocks              => v_freespace4_blocks,
                full_bytes              => v_full_bytes,
                full_blocks     => v_full_blocks,
                unformatted_blocks => v_unformatted_blocks,
                unformatted_bytes => v_unformatted_bytes);
                select round(bytes) into OBJECT_SIZE_BYTES from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024/1024/1024) into OBJECT_SIZE_GB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024/1024) into OBJECT_SIZE_MB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024) into OBJECT_SIZE_KB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type; 
                select round(bytes) into OBJECT_SIZE_BYTES from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and partition_name = v_unq_object_names.subobject_name and segment_type = v_unq_object_names.object_type;
                select round(((v_freespace1_bytes+v_freespace2_bytes+v_freespace3_bytes+v_freespace4_bytes)/OBJECT_SIZE_BYTES)*100) into fragmented_percentage from dual;


                IF fragmented_percentage > 20 
                THEN
                dbms_output.put_line('');
                dbms_output.put_line('');
                dbms_output.put_line('-----------------------------------------------------------------');
                dbms_output.put_line('OWNER: '||v_unq_object_names.owner);
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('OBJECT_SIZE : '||OBJECT_SIZE_GB||'GB '||OBJECT_SIZE_MB||'MB '||OBJECT_SIZE_KB||'KB ');
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('PARTITION_NAME : '||v_unq_object_names.subobject_name);
                dbms_output.put_line('PARTITION_SIZE : '||OBJECT_SIZE_GB||'GB '||OBJECT_SIZE_MB||'MB '||OBJECT_SIZE_KB||'KB ');
                dbms_output.put_line('FRAGMENTED : YES, '||fragmented_percentage||'%');
                dbms_output.put_line('PCT_FREE : '||V_PCT_FREE);
                dbms_output.put_line('PCT_USED : '||V_PCT_USED);
                dbms_output.put_line('INI_TRANS : '||V_INI_TRANS);
                dbms_output.put_line('LAST_ANALYZED : '||V_LAST_ANALYZED);
                dbms_output.put_line('TIME PERIOD : '||DEFINED_STARTTIME||' TO '||DEFINED_ENDTIME);
                dbms_output.put_line('Blocks with Free Space (0-25%)  = '||v_freespace1_blocks);
                dbms_output.put_line('Blocks with Free Space (25-50%) = '||v_freespace2_blocks);
                dbms_output.put_line('Blocks with Free Space (50-75%) = '||v_freespace3_blocks);
                dbms_output.put_line('Blocks with Free Space (75-100%)= '||v_freespace4_blocks);
                dbms_output.put_line('Number of Full blocks           = '||v_full_blocks);
                dbms_output.put_line('-----------------------------------------------------------------');                
                dbms_output.put_line(chr(10));
                ELSE
                dbms_output.put_line('');
                dbms_output.put_line('');
                dbms_output.put_line('-----------------------------------------------------------------');
                dbms_output.put_line('OWNER: '||v_unq_object_names.owner);
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('OBJECT_SIZE : '||OBJECT_SIZE_GB||'GB '||OBJECT_SIZE_MB||'MB '||OBJECT_SIZE_KB||'KB ');
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('PARTITION_NAME : '||v_unq_object_names.subobject_name);
                dbms_output.put_line('PARTITION_SIZE : '||OBJECT_SIZE_GB||'GB '||OBJECT_SIZE_MB||'MB '||OBJECT_SIZE_KB||'KB ');
                dbms_output.put_line('FRAGMENTED : NO, '||fragmented_percentage||'%');
                dbms_output.put_line('PCT_FREE : '||V_PCT_FREE);
                dbms_output.put_line('PCT_USED : '||V_PCT_USED);
                dbms_output.put_line('INI_TRANS : '||V_INI_TRANS);
                dbms_output.put_line('LAST_ANALYZED : '||V_LAST_ANALYZED);
                dbms_output.put_line('TIME PERIOD : '||DEFINED_STARTTIME||' TO '||DEFINED_ENDTIME);
                dbms_output.put_line('Blocks with Free Space (0-25%)  = '||v_freespace1_blocks);
                dbms_output.put_line('Blocks with Free Space (25-50%) = '||v_freespace2_blocks);
                dbms_output.put_line('Blocks with Free Space (50-75%) = '||v_freespace3_blocks);
                dbms_output.put_line('Blocks with Free Space (75-100%)= '||v_freespace4_blocks);
                dbms_output.put_line('Number of Full blocks           = '||v_full_blocks);
                dbms_output.put_line('-----------------------------------------------------------------');                
                dbms_output.put_line(chr(10));
                END IF;
                END;

            ELSE

                IF v_unq_object_names.object_type = 'TABLE'
                THEN
                    select PCT_FREE into V_PCT_FREE from dba_tables where owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name;
                    select PCT_USED into V_PCT_USED from dba_tables where owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name;
                    select INI_TRANS into V_INI_TRANS from dba_tables where owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name;
                    select LAST_ANALYZED into V_LAST_ANALYZED from dba_tables where owner = v_unq_object_names.owner and table_name = v_unq_object_names.object_name;
                ELSIF v_unq_object_names.object_type = 'INDEX'
                THEN
                    select PCT_FREE into V_PCT_FREE from dba_indexes where owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name;
                    select INI_TRANS into V_INI_TRANS from dba_indexes where owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name;
                    select LAST_ANALYZED into V_LAST_ANALYZED from dba_indexes where owner = v_unq_object_names.owner and index_name = v_unq_object_names.object_name;
                END IF;

                declare
                v_freespace1_bytes number;
                v_freespace2_bytes number;
                v_freespace3_bytes number;
                v_freespace4_bytes number;
                v_freespace1_blocks number;
                v_freespace2_blocks number;
                v_freespace3_blocks number;
                v_freespace4_blocks number;
                v_full_bytes number;
                v_full_blocks number;
                v_unformatted_bytes number;
                v_unformatted_blocks number;
                fragmented_percentage number;
                OBJECT_SIZE_BYTES number;
                BEGIN
                dbms_space.space_usage(
                segment_owner   => v_unq_object_names.owner,
                segment_name    => v_unq_object_names.object_name,
                segment_type    => v_unq_object_names.object_type,
                fs1_bytes               => v_freespace1_bytes,
                fs1_blocks              => v_freespace1_blocks,
                fs2_bytes               => v_freespace2_bytes,
                fs2_blocks              => v_freespace2_blocks,
                fs3_bytes               => V_freespace3_bytes,
                fs3_blocks              => v_freespace3_blocks,
                fs4_bytes               => v_freespace4_bytes,
                fs4_blocks              => v_freespace4_blocks,
                full_bytes              => v_full_bytes,
                full_blocks     => v_full_blocks,
                unformatted_blocks => v_unformatted_blocks,
                unformatted_bytes => v_unformatted_bytes);
                select round(bytes) into OBJECT_SIZE_BYTES from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and segment_type = v_unq_object_names.object_type ;
                select round(((v_freespace1_bytes+v_freespace2_bytes+v_freespace3_bytes+v_freespace4_bytes)/OBJECT_SIZE_BYTES)*100) into fragmented_percentage from dual;
                select round(bytes/1024/1024/1024) into OBJECT_SIZE_GB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024/1024) into OBJECT_SIZE_MB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and segment_type = v_unq_object_names.object_type;
                select round(bytes/1024) into OBJECT_SIZE_KB from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and segment_type = v_unq_object_names.object_type;
                select round(bytes) into OBJECT_SIZE_BYTES from dba_segments where owner = v_unq_object_names.owner and segment_name = v_unq_object_names.object_name and segment_type = v_unq_object_names.object_type;
                
                IF fragmented_percentage > 20 
                THEN
              
                dbms_output.put_line('');
                dbms_output.put_line('');
                dbms_output.put_line('-----------------------------------------------------------------');
                dbms_output.put_line('OWNER: '||v_unq_object_names.owner);
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('OBJECT_SIZE : '||OBJECT_SIZE_GB||'GB '||OBJECT_SIZE_MB||'MB '||OBJECT_SIZE_KB||'KB ');
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('FRAGMENTED : YES, '||fragmented_percentage||'%');
                dbms_output.put_line('PCT_FREE : '||V_PCT_FREE);
                dbms_output.put_line('PCT_USED : '||V_PCT_USED);
                dbms_output.put_line('INI_TRANS : '||V_INI_TRANS);
                dbms_output.put_line('LAST_ANALYZED : '||V_LAST_ANALYZED);
                dbms_output.put_line('TIME PERIOD : '||DEFINED_STARTTIME||' TO '||DEFINED_ENDTIME);
                dbms_output.put_line('Blocks with Free Space (0-25%)  = '||v_freespace1_blocks);
                dbms_output.put_line('Blocks with Free Space (25-50%) = '||v_freespace2_blocks);
                dbms_output.put_line('Blocks with Free Space (50-75%) = '||v_freespace3_blocks);
                dbms_output.put_line('Blocks with Free Space (75-100%)= '||v_freespace4_blocks);
                dbms_output.put_line('Number of Full blocks           = '||v_full_blocks);
                dbms_output.put_line('-----------------------------------------------------------------');
                dbms_output.put_line(chr(10));
                ELSE
                dbms_output.put_line('');
                dbms_output.put_line('');
                dbms_output.put_line('-----------------------------------------------------------------');
                dbms_output.put_line('OWNER: '||v_unq_object_names.owner);
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('OBJECT_SIZE : '||OBJECT_SIZE_GB||'GB '||OBJECT_SIZE_MB||'MB '||OBJECT_SIZE_KB||'KB ');
                dbms_output.put_line('OBJECT_NAME : '||v_unq_object_names.object_name);
                dbms_output.put_line('OBJECT_TYPE : '||v_unq_object_names.object_type);
                dbms_output.put_line('FRAGMENTED : NO, '||fragmented_percentage||'%');
                dbms_output.put_line('PCT_FREE : '||V_PCT_FREE);
                dbms_output.put_line('PCT_USED : '||V_PCT_USED);
                dbms_output.put_line('INI_TRANS : '||V_INI_TRANS);
                dbms_output.put_line('LAST_ANALYZED : '||V_LAST_ANALYZED);
                dbms_output.put_line('TIME PERIOD : '||DEFINED_STARTTIME||' TO '||DEFINED_ENDTIME);
                dbms_output.put_line('Blocks with Free Space (0-25%)  = '||v_freespace1_blocks);
                dbms_output.put_line('Blocks with Free Space (25-50%) = '||v_freespace2_blocks);
                dbms_output.put_line('Blocks with Free Space (50-75%) = '||v_freespace3_blocks);
                dbms_output.put_line('Blocks with Free Space (75-100%)= '||v_freespace4_blocks);
                dbms_output.put_line('Number of Full blocks           = '||v_full_blocks);
                dbms_output.put_line('-----------------------------------------------------------------');
                dbms_output.put_line(chr(10));
                END IF;
                END;
            END IF;
        END LOOP;
END;
/


