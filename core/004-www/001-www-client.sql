/*******************************************************************************
 * WWW - client
 *
 * Created by Aquameta Labs, an open source company in Portland Oregon, USA.
 * Company: http://aquameta.com/
 * Project: http://blog.aquameta.com/
 ******************************************************************************/

begin;

create language plpythonu;
create schema www_client;
set search_path=www_client;



/*******************************************************************************
*
*
* UTILS
* General purpose http client utilities.
*
*
*******************************************************************************/


/*******************************************************************************
* urlencode
* via http://stackoverflow.com/questions/10318014/javascript-encodeuri-like-function-in-postgresql
*******************************************************************************/
CREATE OR REPLACE FUNCTION urlencode(in_str text, OUT _result text)
    STRICT IMMUTABLE AS $urlencode$
DECLARE
    _i      int4;
    _temp   varchar;
    _ascii  int4;
BEGIN
    _result = '';
    FOR _i IN 1 .. length(in_str) LOOP
        _temp := substr(in_str, _i, 1);
        IF _temp ~ '[0-9a-zA-Z:/@._?#-]+' THEN
            _result := _result || _temp;
        ELSE
            _ascii := ascii(_temp);
            IF _ascii > x'07ff'::int4 THEN
                RAISE EXCEPTION 'Won''t deal with 3 (or more) byte sequences.';
            END IF;
            IF _ascii <= x'07f'::int4 THEN
                _temp := '%'||to_hex(_ascii);
            ELSE
                _temp := '%'||to_hex((_ascii & x'03f'::int4)+x'80'::int4);
                _ascii := _ascii >> 6;
                _temp := '%'||to_hex((_ascii & x'01f'::int4)+x'c0'::int4)
                            ||_temp;
            END IF;
            _result := _result || upper(_temp);
        END IF;
    END LOOP;
    RETURN ;
END;
$urlencode$ LANGUAGE plpgsql;

/*******************************************************************************
* http_get
*******************************************************************************/
create or replace function www_client.http_get (url text) returns text
as $$

import urllib2

req = urllib2.Request(url)
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;

/*******************************************************************************
* http_post
*******************************************************************************/
create or replace function www_client.http_post(url text, data text)
returns text
as $$
import urllib2

req = urllib2.Request(url, data)
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;



/*******************************************************************************
* http_delete
*******************************************************************************/
create or replace function www_client.http_delete(url text)
returns text
as $$
import urllib2

req = urllib2.Request(url)
req.get_method = lambda: 'DELETE'
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;



/*******************************************************************************
* http_patch
*******************************************************************************/
create or replace function www_client.http_patch(url text, data text)
returns text
as $$
import urllib2

req = urllib2.Request(url, data)
req.get_method = lambda: 'PATCH'
response = urllib2.urlopen(req)
raw_response = response.read()
return raw_response

$$ language plpythonu;




/*******************************************************************************
*
*
* ENDPOINT CLIENT
*
*
*******************************************************************************/

/*******************************************************************************
* rows_select
*******************************************************************************/
create or replace function www_client.rows_select(http_remote_id uuid, relation_id meta.relation_id, args json, out response json)
as $$

select www_client.http_get ((select endpoint_url from bundle.remote_http where id=http_remote_id)
        || '/' || www_client.urlencode((relation_id.schema_id).name)
        || '/relation'
        || '/' || www_client.urlencode(relation_id.name)
        || '/rows'
    )::json;

$$ language sql;


/*******************************************************************************
* rows_insert
*******************************************************************************/
create or replace function www_client.rows_insert(http_remote_id uuid, args json, out response text)
as $$

select www_client.http_post (
    (select endpoint_url || '/insert' from bundle.remote_http where id=http_remote_id),
    args::text -- fixme?  does a post expect x=7&y=p&z=3 ?
);

$$ language sql;



/*******************************************************************************
* row_select
*******************************************************************************/
create or replace function www_client.row_select(http_remote_id uuid, row_id meta.row_id) returns json
as $$

select www_client.http_get (
    (
        select endpoint_url from bundle.remote_http where id=http_remote_id)
            || '/' || (row_id::meta.schema_id).name
            || '/table' 
            || '/' || (row_id::meta.relation_id).name
            || '/row'
            || '/' || row_id.pk_value
    )::json;

$$ language sql;


/*******************************************************************************
* field_select
*******************************************************************************/
create or replace function www_client.field_select(http_remote_id uuid, field_id meta.field_id) returns text
as $$

select www_client.http_get (
    (
        select endpoint_url from bundle.remote_http where id=http_remote_id)
            || '/' || (field_id::meta.schema_id).name
            || '/table' 
            || '/' || (field_id::meta.relation_id).name
            || '/row'
            || '/' || (field_id.row_id).pk_value
            || '/' || (field_id.column_id).name
    );

$$ language sql;


/*******************************************************************************
* row_delete
*******************************************************************************/
create or replace function www_client.row_delete(http_remote_id uuid, row_id meta.row_id) returns text
as $$

select www_client.http_delete (
    (
        select endpoint_url from bundle.remote_http where id=http_remote_id)
            || '/' || (row_id::meta.schema_id).name
            || '/table' 
            || '/' || (row_id::meta.relation_id).name
            || '/row'
            || '/' || row_id.pk_value
    );

$$ language sql;


--
--
-- row_insert(remote_id uuid, relation_id meta.relation_id, row_object json)
-- row_update(remote_id uuid, row_id meta.row_id, args json)
--
-- rows_select(remote_id uuid, relation_id meta.relation_id, args json)
-- rows_select_function(remote_id uuid, function_id meta.function_id)
--
--
--




/*******************************************************************************
*
*
* BUNDLE CONNECTIONS
*
*
*******************************************************************************/



create or replace function bundle.compare(in remote_http_id uuid)
returns table(local_commit_id uuid, remote_commit_id uuid)
as $$
declare
    local_bundle_id uuid;
begin
    select into local_bundle_id bundle_id from bundle.remote_http rh where rh.id = remote_http_id;
    return query
        with remote_commit as (select (json_array_elements(
                www_client.http_get(
                    r.endpoint_url
                        || '/bundle/table/commit/rows?bundle_id='
                        || r.bundle_id
                )::json->'result')->'row'->>'id')::uuid as id
            from bundle.remote_http r
            where r.id = remote_http_id
        )
        select c.id as local_commit_id, rc.id as remote_id
        from bundle.commit c
            full outer join remote_commit rc on rc.id=c.id
            where c.bundle_id = local_bundle_id;

end;
$$ language  plpgsql;


-- TRYING TO WRITE THIS IS UNSPEAKABLY PAINFUL.  THIS IS BROKEN.
create or replace function bundle.push(in remote_http_id uuid)
returns void -- table(_row_id meta.row_id)
as $$
declare
    ct integer;
begin
    raise notice '################################### PUSH ##########################';
    -- commits to push
    create table _bundlepacker_tmp (row_id text, the_row json);

    -- bundle
    insert into _bundlepacker_tmp
        select meta.row_id('bundle','bundle','id', bundle.id::text)::text, row_to_json(bundle)
        from bundle.bundle 
        join bundle.remote_http on remote_http.bundle_id=bundle.id;

    raise notice '####################### 1';
    select into ct count(*) from _bundlepacker_tmp;
    raise notice '####################### _bundlepacker_tmp has % records', ct;

    -- commit
    with unpushed_commits as (
        select commit.id from bundle.compare(remote_http_id) comp
            join bundle.commit on commit.id = comp.local_commit_id
            -- join bundle.remote_http r on r.bundle_id = c.id FIXME?
        -- where r.id = remote_http_id
            and comp.remote_commit_id is null)
     insert into _bundlepacker_tmp select /* (meta.row_id('bundle','commit','id', comm.id::text))::text */ 'testing', row_to_json(comm) from bundle.commit comm
        where comm.bundle_id::text in (select (row_id::meta.row_id).pk_value from _bundlepacker_tmp)
            and comm.id in (select id from unpushed_commits);

    raise notice '####################### 2';
    select into ct count(*) from _bundlepacker_tmp;
    raise notice '####################### _bundlepacker_tmp has % records', ct;

    -- rowset
    insert into _bundlepacker_tmp 
    select meta.row_id('bundle','rowset','id', rs.id::text)::text, row_to_json(rs)
        from bundle.rowset rs
        join bundle.commit c on c.rowset_id = rs.id
        where (c.id)::text in (select (row_id::meta.row_id).pk_value from _bundlepacker_tmp where (row_id::meta.relation_id).name = 'commit');

    raise notice '####################### 3';
    select into ct count(*) from _bundlepacker_tmp;
    raise notice '####################### _bundlepacker_tmp has % records', ct;

    -- rowset_row
    insert into _bundlepacker_tmp select meta.row_id('bundle','rowset_row','id', rr.id::text)::text, row_to_json(rr) from bundle.rowset_row rr
        where rr.rowset_id::text in (select (row_id::meta.row_id).pk_value from _bundlepacker_tmp where (row_id::meta.relation_id).name = 'rowset');

    -- rowset_row_field
    insert into _bundlepacker_tmp select meta.row_id('bundle','rowset_row_field','id', rrf.id::text)::text, row_to_json(rowset_row_field) from bundle.rowset_row_field rrf
        where rrf.rowset_row_id::text in (select (row_id::meta.row_id).pk_value from _bundlepacker_tmp where (row_id::meta.relation_id).name = 'rowset_row');


    select into ct count(*) from _bundlepacker_tmp;
    raise notice '####################### _bundlepacker_tmp has % records', ct;

    -- http://hashrocket.com/blog/posts/faster-json-generation-with-postgresql
    perform www_client.rows_insert (
        remote_http_id, 
        array_to_json(
            array_agg(
                row_to_json(
                    _bundlepacker_tmp
                )
            )
        ) 
    )
    from _bundlepacker_tmp;

    -- raise notice '%', records;

    -- perform www_client.rows_insert(remote_http_id, records);

    -- RETURN QUERY EXECUTE  'select row_id, meta.row_id_to_json(row_id) from _bundlepacker_tmp';
    -- RETURN QUERY EXECUTE 'select * from _bundlepacker_tmp';

end;
$$ language plpgsql;


commit;
