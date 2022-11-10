set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('SAPZRA', 'BWFI_AEDAT~0', 'INDEX', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
end;
/

[10:29 PM] Sabitoski, Aris
ALTER SESSION SET PARALLEL_FORCE_LOCAL=TRUE;


set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('SAPZRA', 'BWFI_AEDAT~1', 'INDEX', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
end;
/


set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('SAPZWA', 'ARFCSSTATE', 'TABLE', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_bytes);
dbms_output.put_line('FS2 Blocks = '||v_fs2_bytes);
dbms_output.put_line('FS3 Blocks = '||v_fs3_bytes);
dbms_output.put_line('FS4 Blocks = '||v_fs4_bytes);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
dbms_output.put_line('Full Blocks = '||v_full_bytes);
end;
/









SOLUTION
 Below given are the various ways to find segment level fragmentation for different TABLE and LOB segment types for different segment space management methods.

1. Tables in MSSM (Manual Segment Space Management) tablespaces
exec dbms_stats.gather_table_stats('<OWNER>','<TABLE NAME>');
select owner,table_name,round((blocks*8),2)||' kb' "TABLE SIZE",round((num_rows*avg_row_len/1024),2)||' kb' "ACTUAL DATA" from dba_tables where owner = 'SAPZRA' and table_name = 'VBRK';

select table_name,avg_row_len,round(((blocks*16/1024)),2)||'MB' "TOTAL_SIZE",
round((num_rows*avg_row_len/1024/1024),2)||'Mb' "ACTUAL_SIZE",
round(((blocks*16/1024)-(num_rows*avg_row_len/1024/1024)),2) ||'MB' "FRAGMENTED_SPACE",
(round(((blocks*16/1024)-(num_rows*avg_row_len/1024/1024)),2)/round(((blocks*16/1024)),2))*100 "percentage"
from all_tables WHERE table_name='&TABLE_NAME';
 
set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('SAPZRA', 'BWFI_AEDAT', 'TABLE', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes, <partition name>);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
end;
/
 
FS1 Blocks = 2084
FS2 Blocks = 25518
FS3 Blocks = 14746
FS4 Blocks = 44367
Full Blocks = 2385604

VBRP~Z04
VBRK~0


2. Tables in ASSM(Automatic Segment Space Management) tablespaces
set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('SAPZRA', 'BWFI_AEDAT', 'TABLE', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
end;
/
 unformatted_blocks : Total number of blocks unformatted
fs1_blocks : Number of blocks having at least 0 to 25% free space
fs2_blocks : Number of blocks having at least 25 to 50% free space
fs3_blocks : Number of blocks having at least 50 to 75% free space
fs4_blocks : Number of blocks having at least 75 to 100% free space
ful1_blocks : Total number of blocks full in the segment

Fragmentation is considered to be high if there are too many fs1, fs2 and fs3 blocks ( mostly fs1 and fs2 blocks) because these blocks might not allow inserts despite the free space and segment might need to extend when new inserts come in.
From a space-regain perspective, if there are too many fs3, fs4 blocks ( especially fs4 blocks ) and the possibility of future inserts is minimal, re-organizing the table will release lots of space.
Re-organizing the table compacts the blocks thereby increasing FULL blocks, reducing fs1, fs2,fs3 and fs4 blocks and thus reducing the total number of blocks.

To find fragmentation at partition level,

set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('SAPZCA', 'BUT000', 'TABLE PARTITION', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes, <partition name>);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
end;
/
 

3. LOBs in MSSM(Manual Segment Space Management) tablespaces
The size of the LOB segment can be found by querying dba_segments, as follows:
select bytes from dba_segments where segment_name ='<lob segment name>' and owner ='<table owner>';

To get the details of the table to which this LOB segment belong to:
SELECT TABLE_NAME, COLUMN_NAME FROM DBA_LOBS WHERE OWNER = '<owner>' AND SEGMENT_NAME= '<lob segment name>' ;

Check the space that is actually allocated to the LOB data :
select sum(dbms_lob.getlength (<lob column name>)) from <table_name>;

The difference between these two is free space and/or undo space. It is not possible to assess the actual empty space using the queries above alone, because of the UNDO segment size, which is virtually impossible to assess.

 

4. LOBs in ASSM (Automatic Segment Space Management) tablespaces
set serveroutput on
declare
v_unformatted_blocks number;
v_unformatted_bytes number;
v_fs1_blocks number;
v_fs1_bytes number;
v_fs2_blocks number;
v_fs2_bytes number;
v_fs3_blocks number;
v_fs3_bytes number;
v_fs4_blocks number;
v_fs4_bytes number;
v_full_blocks number;
v_full_bytes number;
begin
dbms_space.space_usage ('<owner>', '<lob segment name>', 'LOB', v_unformatted_blocks,
v_unformatted_bytes, v_fs1_blocks, v_fs1_bytes, v_fs2_blocks, v_fs2_bytes,
v_fs3_blocks, v_fs3_bytes, v_fs4_blocks, v_fs4_bytes, v_full_blocks, v_full_bytes);
dbms_output.put_line('Unformatted Blocks = '||v_unformatted_blocks);
dbms_output.put_line('FS1 Blocks = '||v_fs1_blocks);
dbms_output.put_line('FS2 Blocks = '||v_fs2_blocks);
dbms_output.put_line('FS3 Blocks = '||v_fs3_blocks);
dbms_output.put_line('FS4 Blocks = '||v_fs4_blocks);
dbms_output.put_line('Full Blocks = '||v_full_blocks);
end;
/
 

5. Securefile LOBs
set serveroutput on
declare
v_segment_size_blocks number;
v_segment_size_bytes number;
v_used_blocks number;
v_used_bytes number;
v_expired_blocks number;
v_expired_bytes number;
v_unexpired_blocks number;
v_unexpired_bytes number;
begin
dbms_space.space_usage ('<owner>', '<securefile segment name>', 'LOB', v_segment_size_blocks, v_segment_size_bytes, v_used_blocks, v_used_bytes, v_expired_blocks, v_expired_bytes, v_unexpired_blocks, v_unexpired_bytes);
dbms_output.put_line('Segment size in blocks = '||v_segment_size_blocks);
dbms_output.put_line('Used Blocks = '||v_used_blocks);
dbms_output.put_line('Expired Blocks = '||v_expired_blocks);
dbms_output.put_line('Unxpired Blocks = '||v_unexpired_blocks);
end;
/
segment_size_blocks : Number of blocks allocated to the segment
used_blocks : Number blocks allocated to the LOB that contains active data
expired_blocks : Number of expired blocks used by the LOB to keep version data
unexpired_blocks : Number of unexpired blocks used by the LOB to keep version data

Expired blocks and unexpired blocks contain UNDO data and will be reused.
