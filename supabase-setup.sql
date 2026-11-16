-- ═══════════════════════════════════════════════════════════════
--  Trendos Camp Management — Supabase database setup  (v6.0)
--  Run in Supabase → SQL Editor → New query → paste all → Run.
--  Safe to run again, and upgrades a database set up with v5.x.
-- ═══════════════════════════════════════════════════════════════

-- 0. Master administrator: always full access, cannot be switched off
create or replace function public.trendos_master_email() returns text
language sql immutable as $$ select 'toanash@gmail.com'::text $$;

-- 1. Data: one row per record, stored as flexible JSON
create table if not exists public.trendos_records (
  collection  text        not null,
  id          text        not null,
  data        jsonb       not null default '{}'::jsonb,
  deleted     boolean     not null default false,   -- deletes are soft: recoverable
  updated_at  timestamptz not null default now(),
  updated_by  uuid        default auth.uid(),
  primary key (collection, id)
);

-- 2. Every previous version of every record
create table if not exists public.trendos_history (
  history_id  bigserial   primary key,
  collection  text        not null,
  record_id   text        not null,
  data        jsonb,
  deleted     boolean,
  changed_at  timestamptz not null default now(),
  changed_by  uuid
);
create index if not exists trendos_history_record on public.trendos_history (collection, record_id, changed_at desc);

-- 3. Roles: what each role may view / edit, screen by screen
create table if not exists public.trendos_roles (
  id          text        primary key,
  name        text        not null,
  perms       jsonb       not null default '{}'::jsonb,   -- {"residents":"edit","invoices":"view",...}
  builtin     boolean     not null default false,
  created_at  timestamptz not null default now()
);
insert into public.trendos_roles (id, name, perms, builtin, created_at) values
 ('admin',   'Administrator', '{}', true, now() - interval '3 seconds'),
 ('manager', 'Manager', '{"dashboard":"edit","rooms":"edit","residents":"edit","movement":"edit","rates":"edit","mandays":"edit","monthend":"edit","invoices":"edit","catering":"edit","sublease":"edit","reports":"edit","companies":"edit","settings":"view"}', true, now() - interval '2 seconds'),
 ('viewer',  'Viewer',  '{"dashboard":"view","rooms":"view","residents":"view","movement":"view","rates":"view","mandays":"view","monthend":"view","invoices":"view","catering":"view","sublease":"view","reports":"view","companies":"view","settings":"view"}', true, now() - interval '1 second')
on conflict (id) do nothing;
-- ready-made roles (can be edited or deleted in the app)
insert into public.trendos_roles (id, name, perms, builtin) values
 ('entry-staff', 'Entry Staff', '{"dashboard":"view","rooms":"view","residents":"edit","movement":"view"}', false),
 ('supervisor',  'Supervisor',  '{"dashboard":"view","rooms":"view","residents":"edit","movement":"edit","rates":"view","mandays":"view","monthend":"edit","invoices":"edit","catering":"edit","sublease":"view","reports":"view","companies":"view","settings":"view"}', false)
on conflict (id) do nothing;

-- 4. Who may sign in
create table if not exists public.trendos_users (
  id          uuid        primary key references auth.users(id) on delete cascade,
  email       text,
  name        text,
  role        text        not null default 'viewer',
  active      boolean     not null default false,
  created_at  timestamptz not null default now()
);
alter table public.trendos_users add column if not exists username text;
alter table public.trendos_users add column if not exists approved_at timestamptz;   -- null + inactive = waiting for approval
update public.trendos_users set approved_at = created_at where active and approved_at is null;
alter table public.trendos_users drop constraint if exists trendos_users_role_check;
create unique index if not exists trendos_users_username on public.trendos_users (lower(username));
do $$ begin
  alter table public.trendos_users add constraint trendos_users_role_fk
    foreign key (role) references public.trendos_roles(id) on update cascade;
exception when duplicate_object then null; end $$;

-- 5. Helpers
create or replace function public.trendos_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.trendos_users where id = auth.uid() and active
$$;

-- Permission for a screen, including screens added after a role was made
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

-- Which screen's "edit" right covers each kind of record (mirrors COL_MODULE in the app)
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

-- sign in with a username: look up the email behind it (active accounts only)
create or replace function public.trendos_login_email(p_login text) returns text
language sql stable security definer set search_path = public as $$
  select email from public.trendos_users where lower(username) = lower(trim(p_login)) and active limit 1
$$;

-- request-access form: is a username still free? (true / false only, no account details)
create or replace function public.trendos_username_free(p_username text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.trendos_users where lower(username) = lower(trim(p_username)))
$$;

-- 6. New accounts get a profile. The master email becomes the active administrator (username "admin");
--    everyone else starts as an inactive viewer until an administrator switches them on.
create or replace function public.trendos_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare is_master boolean := lower(new.email) = public.trendos_master_email();
        uname text := nullif(lower(trim(new.raw_user_meta_data->>'username')), '');
begin
  if is_master then uname := coalesce(uname, 'admin'); end if;
  if uname is not null and exists (select 1 from public.trendos_users where lower(username) = uname) then uname := null; end if;
  insert into public.trendos_users (id, email, name, username, role, active, created_at, approved_at)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
          uname,
          case when is_master then 'admin' else 'viewer' end,
          is_master, now(), case when is_master then now() end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists trendos_on_auth_user_created on auth.users;
create trigger trendos_on_auth_user_created
  after insert on auth.users for each row execute function public.trendos_handle_new_user();

-- accounts created before this script ran
insert into public.trendos_users (id, email, name, role, active, created_at)
select u.id, u.email, split_part(u.email, '@', 1), 'viewer', false, u.created_at from auth.users u
on conflict (id) do nothing;
update public.trendos_users set role = 'admin', active = true, approved_at = coalesce(approved_at, now()),
       username = coalesce(username, case when not exists (select 1 from public.trendos_users x where lower(x.username) = 'admin') then 'admin' end)
 where lower(email) = public.trendos_master_email();

-- the master account can never lose admin rights or be switched off
create or replace function public.trendos_protect_master() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if lower(coalesce(old.email, new.email)) = public.trendos_master_email() then
    new.role := 'admin'; new.active := true;
  end if;
  return new;
end $$;
drop trigger if exists trendos_users_protect_master on public.trendos_users;
create trigger trendos_users_protect_master
  before update on public.trendos_users for each row execute function public.trendos_protect_master();

-- 7. Stamp who changed what, and keep the previous version in history
create or replace function public.trendos_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  if tg_op = 'UPDATE' and (old.data is distinct from new.data or old.deleted is distinct from new.deleted) then
    insert into public.trendos_history (collection, record_id, data, deleted, changed_at, changed_by)
    values (old.collection, old.id, old.data, old.deleted, old.updated_at, old.updated_by);
  end if;
  return new;
end $$;
drop trigger if exists trendos_records_touch on public.trendos_records;
create trigger trendos_records_touch
  before insert or update on public.trendos_records for each row execute function public.trendos_touch();

-- 8. Security rules
alter table public.trendos_records enable row level security;
alter table public.trendos_users   enable row level security;
alter table public.trendos_history enable row level security;
alter table public.trendos_roles   enable row level security;

drop policy if exists trendos_records_read   on public.trendos_records;
drop policy if exists trendos_records_insert on public.trendos_records;
drop policy if exists trendos_records_update on public.trendos_records;
drop policy if exists trendos_records_delete on public.trendos_records;
create policy trendos_records_read   on public.trendos_records for select to authenticated using (public.trendos_role() is not null);
create policy trendos_records_insert on public.trendos_records for insert to authenticated with check (public.trendos_can_edit(collection));
create policy trendos_records_update on public.trendos_records for update to authenticated
  using (public.trendos_role() is not null) with check (public.trendos_can_edit(collection));
create policy trendos_records_delete on public.trendos_records for delete to authenticated using (public.trendos_role() = 'admin');

drop policy if exists trendos_users_read   on public.trendos_users;
drop policy if exists trendos_users_update on public.trendos_users;
create policy trendos_users_read   on public.trendos_users for select to authenticated
  using (id = auth.uid() or public.trendos_role() is not null);
create policy trendos_users_update on public.trendos_users for update to authenticated
  using (public.trendos_role() = 'admin') with check (public.trendos_role() = 'admin');

drop policy if exists trendos_roles_read  on public.trendos_roles;
drop policy if exists trendos_roles_write on public.trendos_roles;
drop policy if exists trendos_roles_update on public.trendos_roles;
drop policy if exists trendos_roles_delete on public.trendos_roles;
create policy trendos_roles_read   on public.trendos_roles for select to authenticated using (true);
create policy trendos_roles_write  on public.trendos_roles for insert to authenticated with check (public.trendos_role() = 'admin');
create policy trendos_roles_update on public.trendos_roles for update to authenticated
  using (public.trendos_role() = 'admin' and id <> 'admin') with check (public.trendos_role() = 'admin' and id <> 'admin');
create policy trendos_roles_delete on public.trendos_roles for delete to authenticated
  using (public.trendos_role() = 'admin' and not builtin);

drop policy if exists trendos_history_read on public.trendos_history;
create policy trendos_history_read on public.trendos_history for select to authenticated using (public.trendos_role() = 'admin');

revoke all on public.trendos_records, public.trendos_users, public.trendos_history, public.trendos_roles from anon;
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.trendos_records to authenticated;
grant select, update on public.trendos_users to authenticated;
grant select, insert, update, delete on public.trendos_roles to authenticated;
grant select on public.trendos_history to authenticated;
grant execute on function public.trendos_role() to authenticated;
grant execute on function public.trendos_can_edit(text) to authenticated;
grant execute on function public.trendos_login_email(text) to anon, authenticated;
grant execute on function public.trendos_username_free(text) to anon, authenticated;

-- 9. Live updates
do $$ begin
  alter publication supabase_realtime add table public.trendos_records;
exception when duplicate_object then null;
end $$;

-- 10. v6: new screens for ready-made roles, photo store, AI usage
-- 10a. Ready-made roles get the new screens (only where the role does not set them yet)
update public.trendos_roles set perms = '{"assets":"edit","maintenance":"edit"}'::jsonb || perms where id = 'manager';
update public.trendos_roles set perms = '{"assets":"view","maintenance":"view"}'::jsonb || perms where id = 'viewer';
update public.trendos_roles set perms = '{"assets":"view","maintenance":"edit"}'::jsonb || perms where id = 'entry-staff';
update public.trendos_roles set perms = '{"assets":"edit","maintenance":"edit"}'::jsonb || perms where id = 'supervisor';

-- 10b. Photo store (room inspections and faults). Private: only signed-in, active users can see photos.
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

-- 10c. AI usage per person per day (the server function stops at its daily limit)
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

-- Done. Check: select email, username, role, active from public.trendos_users;
