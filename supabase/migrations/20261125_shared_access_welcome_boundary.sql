grant select (id, news_id, body, created_at, user_id)
  on public.news_comments to anon, authenticated;

create or replace function public.claim_daily_welcome_bonus()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamp := now() at time zone 'Europe/Moscow';
  v_day date := v_now::date;
  v_hour integer := extract(hour from v_now)::integer;
  v_minute integer := extract(minute from v_now)::integer;
  v_nickname text;
  v_greeting text;
  v_claimed_date date;
  current_balance numeric(14, 2);
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if v_hour < 10 or v_hour >= 21 then
    return null;
  end if;

  insert into public.daily_welcome_bonus_claims (user_id, welcome_date)
  values (auth.uid(), v_day)
  on conflict (user_id, welcome_date) do nothing
  returning welcome_date into v_claimed_date;
  if v_claimed_date is null then
    return null;
  end if;

  select nickname into v_nickname
  from public.profiles
  where id = auth.uid();
  if v_nickname is null then
    raise exception 'Profile not found';
  end if;

  update public.wallets
  set balance = balance + 200
  where user_id = auth.uid()
  returning balance into current_balance;
  if current_balance is null then
    raise exception 'Wallet not found';
  end if;

  v_greeting := case
    when v_hour < 14 or (v_hour = 14 and v_minute = 0) then 'Доброе утро'
    when v_hour < 17 then 'Добрый день'
    else 'Добрый вечер'
  end;
  return jsonb_build_object(
    'title', v_greeting || ', трейдер «' || v_nickname || '»!',
    'message', 'Вам приветственный бонус 200$!',
    'balance', current_balance
  );
end;
$$;

revoke all on function public.claim_daily_welcome_bonus() from public, anon;
grant execute on function public.claim_daily_welcome_bonus() to authenticated;
