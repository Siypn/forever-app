-- FOREVER: coach-managed mode + paid coach invites. Paste into Supabase > SQL Editor > Run. Safe to run more than once.
alter table public.coach_links add column if not exists managed boolean not null default false;
alter table public.coaches add column if not exists default_managed boolean not null default false;

create or replace function public.coach_writable_path(p text)
 returns boolean language sql immutable set search_path to ''
as $$
  select p like 'program/%' or p in ('nutrition/config', 'weight/config', 'coach/personal', 'coach/focus', 'coach/targets', 'coach/habits', 'nutrition/coachMeals') or p like 'coachNotes/%'
$$;

create or replace function public.connect_to_coach(p_code text)
 returns text language plpgsql security definer set search_path to ''
as $$
declare v_coach uuid; v_name text; v_def boolean; v_me uuid := auth.uid(); v_email text;
begin
  if v_me is null then raise exception 'not signed in'; end if;
  select c.user_id, coalesce(c.display_name, 'your coach'), c.default_managed into v_coach, v_name, v_def
    from public.coaches c where upper(c.code) = upper(trim(p_code));
  if v_coach is null then raise exception 'That coach code wasn''t found'; end if;
  if v_coach = v_me then raise exception 'That''s your own coach code'; end if;
  select u.email into v_email from auth.users u where u.id = v_me;
  insert into public.coach_links (coach_id, client_id, client_email, managed)
    values (v_coach, v_me, v_email, coalesce(v_def, false))
    on conflict (coach_id, client_id) do nothing;
  return v_name;
end $$;

drop function if exists public.my_coaches();
create function public.my_coaches()
 returns table(coach_id uuid, display_name text, connected_at timestamptz, managed boolean)
 language sql stable security definer set search_path to ''
as $$
  select l.coach_id, coalesce(c.display_name, 'Your coach'), l.created_at, l.managed
  from public.coach_links l join public.coaches c on c.user_id = l.coach_id
  where l.client_id = auth.uid();
$$;
revoke all on function public.my_coaches() from public, anon;
grant execute on function public.my_coaches() to authenticated;

create or replace function public.set_client_managed(p_client uuid, p_managed boolean)
 returns boolean language plpgsql security definer set search_path to ''
as $$
begin
  update public.coach_links set managed = coalesce(p_managed, false)
   where coach_id = auth.uid() and client_id = p_client;
  return found;
end $$;
revoke all on function public.set_client_managed(uuid, boolean) from public, anon;
grant execute on function public.set_client_managed(uuid, boolean) to authenticated;

create table if not exists public.app_admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.app_admins enable row level security;
create table if not exists public.coach_invites (
  code text primary key,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  used_by uuid references auth.users(id) on delete set null,
  used_at timestamptz
);
alter table public.coach_invites enable row level security;
insert into public.app_admins(user_id) select id from auth.users where email = 'alwayssimpyn@gmail.com' on conflict do nothing;

create or replace function public.am_i_admin()
 returns boolean language sql stable security definer set search_path to ''
as $$ select exists (select 1 from public.app_admins where user_id = auth.uid()) $$;
revoke all on function public.am_i_admin() from public, anon;
grant execute on function public.am_i_admin() to authenticated;

create or replace function public.create_coach_invite(p_note text)
 returns text language plpgsql security definer set search_path to ''
as $$
declare v text;
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then raise exception 'Only the app owner can create coach invites'; end if;
  loop
    v := 'COACH-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.coach_invites where code = v);
  end loop;
  insert into public.coach_invites(code, note, created_by) values (v, nullif(left(trim(coalesce(p_note, '')), 80), ''), auth.uid());
  return v;
end $$;
revoke all on function public.create_coach_invite(text) from public, anon;
grant execute on function public.create_coach_invite(text) to authenticated;

create or replace function public.list_coach_invites()
 returns table(code text, note text, created_at timestamptz, used_at timestamptz, used_by_email text)
 language plpgsql stable security definer set search_path to ''
as $$
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then return; end if;
  return query select i.code, i.note, i.created_at, i.used_at, u.email::text
    from public.coach_invites i left join auth.users u on u.id = i.used_by order by i.created_at desc limit 100;
end $$;
revoke all on function public.list_coach_invites() from public, anon;
grant execute on function public.list_coach_invites() to authenticated;

create or replace function public.revoke_coach_invite(p_code text)
 returns boolean language plpgsql security definer set search_path to ''
as $$
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then return false; end if;
  delete from public.coach_invites where code = upper(trim(p_code)) and used_by is null;
  return found;
end $$;
revoke all on function public.revoke_coach_invite(text) from public, anon;
grant execute on function public.revoke_coach_invite(text) to authenticated;

create or replace function public.become_coach(p_name text, p_invite text)
 returns text language plpgsql security definer set search_path to ''
as $$
declare v_me uuid := auth.uid(); v_code text; v_try int := 0; v_base text; v_inv text;
begin
  if v_me is null then raise exception 'not signed in'; end if;
  select code into v_code from public.coaches where user_id = v_me;
  if v_code is not null then return v_code; end if;
  select code into v_inv from public.coach_invites where code = upper(trim(coalesce(p_invite, ''))) and used_by is null for update;
  if v_inv is null then raise exception 'That coach invite code isn''t valid or was already used'; end if;
  v_base := upper(regexp_replace(coalesce(nullif(trim(p_name), ''), 'COACH'), '[^A-Za-z]', '', 'g'));
  if length(v_base) < 2 then v_base := 'COACH'; end if;
  v_base := left(v_base, 6);
  loop
    v_try := v_try + 1;
    v_code := 'FOREVER-' || v_base || '-' || lpad((floor(random() * 10000))::int::text, 4, '0');
    exit when not exists (select 1 from public.coaches where upper(code) = upper(v_code)) or v_try > 20;
  end loop;
  insert into public.coaches (user_id, code, display_name) values (v_me, v_code, left(coalesce(nullif(trim(p_name), ''), 'Coach'), 60));
  update public.coach_invites set used_by = v_me, used_at = now() where code = v_inv;
  return v_code;
end $$;
revoke all on function public.become_coach(text, text) from public, anon;
grant execute on function public.become_coach(text, text) to authenticated;

create or replace function public.set_coach_default_managed(p_managed boolean)
 returns boolean language plpgsql security definer set search_path to ''
as $$
begin
  update public.coaches set default_managed = coalesce(p_managed, false) where user_id = auth.uid();
  return found;
end $$;
revoke all on function public.set_coach_default_managed(boolean) from public, anon;
grant execute on function public.set_coach_default_managed(boolean) to authenticated;
