begin;

create or replace function public.admin_trade_counts()
returns table (
  user_id uuid,
  closed_trades bigint,
  open_positions bigint,
  total_trades bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
  with closed_trade_counts as (
    select history.user_id, count(*)::bigint as closed_count
    from public.trade_history history
    group by history.user_id
  ),
  open_position_counts as (
    select pos.user_id, count(*)::bigint as open_count
    from public.positions pos
    group by pos.user_id
  )
  select profiles.id,
         coalesce(closed.closed_count, 0),
         coalesce(opened.open_count, 0),
         coalesce(closed.closed_count, 0) + coalesce(opened.open_count, 0)
  from public.profiles profiles
  left join closed_trade_counts closed on closed.user_id = profiles.id
  left join open_position_counts opened on opened.user_id = profiles.id
  order by profiles.created_at desc;
end;
$$;

revoke all on function public.admin_trade_counts() from public, anon;
grant execute on function public.admin_trade_counts() to authenticated;

commit;
