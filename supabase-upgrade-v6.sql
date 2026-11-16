-- ═══════════════════════════════════════════════════════════════
--  Trendos Camp Management — database upgrade for app v6.0
--  Room assets, maintenance, inspection photos, message log, AI usage.
--  Run ONCE in Supabase → SQL Editor → New query → paste all → Run.
--  Safe to run again. Your data is not changed.
-- ═══════════════════════════════════════════════════════════════

-- 1. Permission for a screen, including screens added after a role was made
--    (mirrors effPerm() in the app): Room Assets follows Rooms; Maintenance is
--    "edit" for anyone who may edit rooms or residents, otherwise as Rooms.
create or replace function public.trendos_perm(p jsonb, k text) returns text
language sql immutable as $$
  select coalesce(
    nullif(p->>k, ''),
    case k
      when 'revenue'     then nullif(p->>'mandays', '')
      when 'assets'      then nullif(p->>'rooms', '')
      when 'maintenance' then case when p->>'rooms' = 'edit' or p->>'residents' = 'edit' then 'edit' else nullif(p->>'rooms', '') end
    end,
    'none')
$$;

-- 2. Which screen's "edit" right covers each kind of record (mirrors COL_MODULE in the app)
create or replace function public.trendos_can_edit(p_collection text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r text; p jsonb;
begin
  select u.role, ro.perms into r, p
    from public.trendos_users u join public.trendos_roles ro on ro.id = u.role
   where u.id = auth.uid() and u.active;
  if r is null then return false; end if;
  if r = 'admin' then return true; end if;
  return case p_collection
    when 'meta'              then exists (select 1 from jsonb_each_text(p) e where e.value = 'edit')
    when 'settings'          then trendos_perm(p,'settings') = 'edit' or trendos_perm(p,'monthend') = 'edit' or trendos_perm(p,'invoices') = 'edit'
    when 'invoices'          then trendos_perm(p,'invoices') = 'edit' or trendos_perm(p,'monthend') = 'edit'
    when 'blocks'            then trendos_perm(p,'rooms') = 'edit'
    when 'rooms'             then trendos_perm(p,'rooms') = 'edit'
    when 'residents'         then trendos_perm(p,'residents') = 'edit'
    when 'movements'         then trendos_perm(p,'movement') = 'edit' or trendos_perm(p,'residents') = 'edit'
    when 'rates'             then trendos_perm(p,'rates') = 'edit'
    when 'monthEndPeriods'   then trendos_perm(p,'monthend') = 'edit'
    when 'closings'          then trendos_perm(p,'monthend') = 'edit'
    when 'cateringExtras'    then trendos_perm(p,'catering') = 'edit'
    when 'subleaseContracts' then trendos_perm(p,'sublease') = 'edit'
    when 'subleaseProviders' then trendos_perm(p,'sublease') = 'edit'
    when 'companies'         then trendos_perm(p,'companies') = 'edit'
    when 'assets'            then trendos_perm(p,'assets') = 'edit'
    when 'maintenance'       then trendos_perm(p,'maintenance') = 'edit'
    when 'inspections'       then trendos_perm(p,'maintenance') = 'edit' or trendos_perm(p,'residents') = 'edit'
    when 'messages'          then trendos_perm(p,'residents') = 'edit' or trendos_perm(p,'maintenance') = 'edit'
    else false end;
end $$;
grant execute on function public.trendos_perm(jsonb, text) to authenticated;
grant execute on function public.trendos_can_edit(text) to authenticated;

-- 3. Ready-made roles get the new screens (only where the role does not set them yet)
update public.trendos_roles set perms = '{"assets":"edit","maintenance":"edit"}'::jsonb || perms where id = 'manager';
update public.trendos_roles set perms = '{"assets":"view","maintenance":"view"}'::jsonb || perms where id = 'viewer';
update public.trendos_roles set perms = '{"assets":"view","maintenance":"edit"}'::jsonb || perms where id = 'entry-staff';
update public.trendos_roles set perms = '{"assets":"edit","maintenance":"edit"}'::jsonb || perms where id = 'supervisor';

-- 4. Photo store (room inspections and faults). Private: only signed-in, active users can see photos.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('trendos-photos', 'trendos-photos', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists trendos_photos_read   on storage.objects;
drop policy if exists trendos_photos_insert on storage.objects;
drop policy if exists trendos_photos_delete on storage.objects;
create policy trendos_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'trendos-photos' and public.trendos_role() is not null);
create policy trendos_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'trendos-photos' and (public.trendos_can_edit('maintenance') or public.trendos_can_edit('inspections')));
create policy trendos_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'trendos-photos' and public.trendos_role() = 'admin');

-- 5. AI usage per person per day (the server function stops at its daily limit)
create table if not exists public.trendos_ai_usage (
  user_id uuid not null,
  day     date not null default current_date,
  calls   integer not null default 0,
  primary key (user_id, day)
);
alter table public.trendos_ai_usage enable row level security;
revoke all on public.trendos_ai_usage from anon, authenticated;
create or replace function public.trendos_ai_tick() returns integer
language plpgsql volatile security definer set search_path = public as $$
declare n integer;
begin
  if public.trendos_role() is null then raise exception 'not allowed'; end if;
  insert into public.trendos_ai_usage (user_id, day, calls) values (auth.uid(), current_date, 1)
  on conflict (user_id, day) do update set calls = public.trendos_ai_usage.calls + 1
  returning calls into n;
  return n;
end $$;
create or replace function public.trendos_ai_today() returns integer
language sql stable security definer set search_path = public as $$
  select coalesce((select calls from public.trendos_ai_usage where user_id = auth.uid() and day = current_date), 0)
$$;
revoke execute on function public.trendos_ai_tick() from public, anon;
revoke execute on function public.trendos_ai_today() from public, anon;
grant execute on function public.trendos_ai_tick() to authenticated;
grant execute on function public.trendos_ai_today() to authenticated;

-- Done. Check: select id, perms->>'maintenance' as maintenance, perms->>'assets' as assets from public.trendos_roles;
