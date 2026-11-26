begin;

create table if not exists public.user_activity (
  user_id uuid primary key references auth.users (id) on delete cascade,
  last_seen_at timestamptz not null default now(),
  total_seconds bigint not null default 0 check (total_seconds >= 0),
  is_active boolean not null default false
);

alter table public.user_activity enable row level security;

drop policy if exists user_activity_read_admin on public.user_activity;
create policy user_activity_read_admin on public.user_activity
for select to authenticated using (public.is_admin());

revoke all on public.user_activity from public, anon, authenticated;
grant select on public.user_activity to authenticated;

create or replace function public.record_user_activity(p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_is_active is null then
    raise exception 'Activity state is required';
  end if;

  insert into public.user_activity as current_activity (
    user_id, last_seen_at, total_seconds, is_active
  )
  values (v_user_id, v_now, 0, p_is_active)
  on conflict (user_id) do update
  set total_seconds = current_activity.total_seconds + case
        when current_activity.is_active
          and v_now >= current_activity.last_seen_at
          and v_now - current_activity.last_seen_at <= interval '90 seconds'
          then floor(extract(epoch from (v_now - current_activity.last_seen_at)))::bigint
        else 0
      end,
      last_seen_at = v_now,
      is_active = p_is_active;
end;
$$;

revoke all on function public.record_user_activity(boolean) from public, anon;
grant execute on function public.record_user_activity(boolean) to authenticated;

commit;
