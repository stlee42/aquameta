/*******************************************************************************
 * Semantics
 * A space to decorate the db schema with meaning
 *
 * Created by Aquameta Labs, an open source company in Portland Oregon, USA.
 * Company: http://aquameta.com/
 * Project: http://blog.aquameta.com/
 ******************************************************************************/
begin;

create schema semantics;
set search_path=semantics;

create table semantics.semantic_relation_purpose (
    id uuid primary key default public.uuid_generate_v4(),
    purpose text not null
);

create table semantics.semantic_relation (
    id meta.relation_id,
    purpose_id uuid references semantics.semantic_relation_purpose(id),
    widget_id uuid references widget.widget(id) not null,
    priority integer not null default 0
);

insert into semantics.semantic_relation_purpose (purpose) values 
    -- Old
    ('list_item_identifier'),
    ('grid_view_row'),

    -- Keepers
    ('overview'),
    ('list_view'),
    ('list_item'),
    ('row_detail'),
    ('new_row'),
    ('grid_view'),
    ('grid_row');


create table semantics.semantic_column_purpose (
    id uuid primary key default public.uuid_generate_v4(),
    purpose text not null
);

create table semantics.semantic_type (
    id meta.type_id,
    purpose_id uuid references semantics.semantic_column_purpose(id) not null,
    widget_id uuid references widget.widget(id) not null,
    priority integer not null default 0
);

-- Breaking changes
create table semantics.semantic_column (
    id meta.column_id,
    purpose_id uuid references semantics.semantic_column_purpose(id) not null,
    widget_id uuid references widget.widget(id) not null,
    priority integer not null default 0
);


insert into semantics.semantic_column_purpose (purpose) values
    -- Old
    ('form_field_label'),
    ('form_field_display'),
    ('form_field_edit uuid'),
    ('grid_view_label'),
    ('grid_field_display'),
    ('grid_field_edit'),

    -- Keepers
    ('form_field'),
    ('form_label'),
    ('form_display'),
    ('form_edit'),
    ('grid_label'),
    ('grid_display'),
    ('grid_edit');

create table semantics.foreign_key (
    id meta.foreign_key_id primary key,
    inline boolean default false
);




/*
 *
 *  Function thate returns display, edit, and new widget names for a given column
 *
 */
drop type if exists column_widgets cascade;
create type column_widgets as (
    display_widget_name text,
    edit_widget_name text,
    new_widget_name text
);
create or replace function semantics.column_semantics(schema text, relation text, column_name text)
returns semantics.column_widgets as $$

declare
    r semantics.column_widgets;
begin

with column_widgets as (
    select *
    from unnest(array['display', 'edit', 'new'], (

        select array[sc.display_widget_id, sc.edit_widget_id, sc.new_widget_id]
        from semantics."column" sc
        where (sc.id::meta.schema_id).name = schema
        and (sc.id::meta.relation_id).name = relation
        and (sc.id).name = column_name
        )

    ) as t(widget_use, widget_id)

), type_widgets as (
    select *
    from unnest(array['display', 'edit', 'new'], (

        select array[st.display_widget_id,  st.edit_widget_id, st.new_widget_id]
        from semantics.type st
            join meta."column" mc on mc.type_id = st.id
        where mc.schema_name = schema
        and mc.relation_name = relation
        and mc.name = column_name
        )

    ) as t(widget_use, widget_id)

), widgets as (
    select distinct on (r.widget_use) r.widget_use, w.name
    from (
        select * from column_widgets
        union all
        select * from type_widgets
    ) r
        join widget.widget w on w.id = r.widget_id
    where r.widget_id is not null
)

select
    ( select name from widgets where widget_use = 'display')::text,
    ( select name from widgets where widget_use = 'edit')::text,
    ( select name from widgets where widget_use = 'new')::text
into r;

return r;

end

$$ language plpgsql;



create or replace function semantics.relation_widget (
    relation_id meta.relation_id,
    widget_purpose text,
    default_bundle text
) returns setof widget.widget as
$$
begin
    return query execute 'select ' || (
        select string_agg(name, ', ')
        from meta.column
        where schema_name='widget'
            and relation_name='widget' ) ||
    ' from (
        select w.*, r.priority
        from semantics.semantic_relation r
            join semantics.semantic_relation_purpose rp on rp.id = r.purpose_id
            join widget.widget w on w.id = r.widget_id
        where r.id = meta.relation_id(' || quote_literal((relation_id::meta.schema_id).name) || ', ' || quote_literal((relation_id).name) || ')
            and rp.purpose = ' || quote_literal(widget_purpose) ||
        'union
        select *, -1 as priority from widget.bundled_widget(' || quote_literal(default_bundle) || ', ' || quote_literal(widget_purpose) || ')
    ) a
    order by priority desc
    limit 1';
end;
$$ language plpgsql;



create or replace function semantics.column_widget (
    column_id meta.column_id,
    widget_purpose text,
    default_bundle text
) returns setof widget.widget as
$$
begin
    return query execute 'select ' || (
        select string_agg(name, ', ')
        from meta.column
        where schema_name='widget'
            and relation_name='widget' ) ||
    ' from (
        select w.*, c.priority, ''c'' as type
        from semantics.semantic_column c
            join semantics.semantic_column_purpose cp on cp.id = c.purpose_id
            join widget.widget w on w.id = c.widget_id
        where c.id = meta.column_id(' || quote_literal((column_id::meta.schema_id).name) || ', ' ||
                                         quote_literal((column_id::meta.relation_id).name) || ', ' ||
                                         quote_literal((column_id).name) || ')
            and cp.purpose = ' || quote_literal(widget_purpose) ||
        ' union
        select w.*, t.priority, ''t'' as type
        from semantics.semantic_type t
            join semantics.semantic_column_purpose cp on cp.id = t.purpose_id
            join widget.widget w on w.id = t.widget_id
            join meta.column mc on mc.type_id = t.id
        where mc.id = meta.column_id(' || quote_literal((column_id::meta.schema_id).name) || ', ' ||
                                         quote_literal((column_id::meta.relation_id).name) || ', ' ||
                                         quote_literal((column_id).name) || ')
            and cp.purpose = ' || quote_literal(widget_purpose) ||
        ' union
        select *, -1 as priority, ''z'' as type
        from widget.bundled_widget(' || quote_literal(default_bundle) || ', ' || quote_literal(widget_purpose) || ')
    ) a
    order by type asc, priority desc
    limit 1';
end;
$$ language plpgsql;






---------------------------------------------------------------------------------
-- Legacy

create table semantics."column" (
    id meta.column_id primary key,
    form_field_widget_id uuid references widget.widget(id),
    form_field_label_widget_id uuid references widget.widget(id),
    form_field_display_widget_id uuid references widget.widget(id),
    form_field_edit_widget_id uuid references widget.widget(id),
    grid_view_label_widget_id uuid references widget.widget(id),
    grid_field_display_widget_id uuid references widget.widget(id),
    grid_field_edit_widget_id uuid references widget.widget(id)
);

create table semantics.relation (
    id meta.relation_id primary key,
    overview_widget_id uuid references widget.widget(id),
    grid_view_widget_id uuid references widget.widget(id),
    list_view_widget_id uuid references widget.widget(id),
    list_item_identifier_widget_id uuid references widget.widget(id),
    row_detail_widget_id uuid references widget.widget(id),
    grid_view_row_widget_id uuid references widget.widget(id),
    new_row_widget_id uuid references widget.widget(id)
);

create table semantics.type (
    id meta.type_id primary key,
    form_field_widget_id uuid references widget.widget(id),
    form_field_label_widget_id uuid references widget.widget(id),
    form_field_display_widget_id uuid references widget.widget(id),
    form_field_edit_widget_id uuid references widget.widget(id),
    grid_view_label_widget_id uuid references widget.widget(id),
    grid_field_display_widget_id uuid references widget.widget(id),
    grid_field_edit_widget_id uuid references widget.widget(id)

);





commit;

