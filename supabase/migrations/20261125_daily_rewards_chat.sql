create table if not exists public.daily_trader_rankings (
  winner_date date not null,
  place smallint not null check (place between 1 and 3),
  user_id uuid not null references auth.users (id),
  nickname text not null,
  score numeric(14, 2) not null,
  reward numeric(14, 2) not null check (reward > 0),
  trade_count integer not null check (trade_count > 0),
  tickers text not null,
  created_at timestamptz not null default now(),
  primary key (winner_date, place),
  unique (winner_date, user_id)
);

alter table public.daily_trader_rankings
  add column if not exists trade_count integer not null default 1 check (trade_count > 0),
  add column if not exists tickers text not null default '';

create table if not exists public.daily_welcome_bonus_claims (
  user_id uuid not null references auth.users (id) on delete cascade,
  welcome_date date not null,
  amount numeric(14, 2) not null default 200 check (amount = 200),
  claimed_at timestamptz not null default now(),
  primary key (user_id, welcome_date)
);

alter table public.daily_trader_rankings enable row level security;
alter table public.daily_welcome_bonus_claims enable row level security;

create or replace function public.can_read_chat_message(p_created_at timestamptz)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_created_at >= now() - interval '7 days'
    or exists (
      select 1 from public.admin_users where user_id = auth.uid()
    );
$$;

revoke all on function public.can_read_chat_message(timestamptz) from public;
grant execute on function public.can_read_chat_message(timestamptz) to anon, authenticated;

drop policy if exists chat_messages_read on public.chat_messages;
create policy chat_messages_read on public.chat_messages
for select to anon, authenticated
using (public.can_read_chat_message(created_at));

drop policy if exists daily_rankings_read on public.daily_trader_rankings;
create policy daily_rankings_read on public.daily_trader_rankings
for select to anon, authenticated using (true);

grant select (winner_date, place, nickname, score, reward, trade_count, tickers)
  on public.daily_trader_rankings to anon, authenticated;

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
    when v_hour < 14 then 'Доброе утро'
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

create or replace function public.publish_daily_trader_winner()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_day date := (now() at time zone 'Europe/Moscow')::date;
  v_start timestamptz := ((v_day::text || ' 00:00:00')::timestamp at time zone 'Europe/Moscow');
  v_end timestamptz := (((v_day + 1)::text || ' 00:00:00')::timestamp at time zone 'Europe/Moscow');
  ranking_row record;
  admin_id uuid;
  ranking text := '';
  reward_amount numeric(14, 2);
begin
  perform pg_advisory_xact_lock(hashtext('daily-trader-winner-' || v_day::text));
  if exists (select 1 from public.daily_trader_rankings where winner_date = v_day) then
    return;
  end if;

  for ranking_row in
    select ranked.*
    from (
      select
        th.user_id,
        p.nickname,
        round(sum(th.profit_loss), 2) as score,
        count(*)::integer as trade_count,
        string_agg(distinct th.ticker, ', ' order by th.ticker) as tickers,
        row_number() over (
          order by sum(th.profit_loss) desc, max(w.balance) desc, p.nickname asc
        )::smallint as place
      from public.trade_history th
      join public.profiles p on p.id = th.user_id
      join public.wallets w on w.user_id = th.user_id
      where th.closed_at >= v_start and th.closed_at < v_end
      group by th.user_id, p.nickname
      having sum(th.profit_loss) > 0
    ) ranked
    where ranked.place <= 3
    order by ranked.place
  loop
    reward_amount := case ranking_row.place
      when 1 then 1000
      when 2 then 500
      else 300
    end;

    insert into public.daily_trader_rankings (
      winner_date, place, user_id, nickname, score, reward, trade_count, tickers
    )
    values (
      v_day, ranking_row.place, ranking_row.user_id,
      ranking_row.nickname, ranking_row.score, reward_amount,
      ranking_row.trade_count, ranking_row.tickers
    );

    update public.wallets
    set balance = balance + reward_amount
    where user_id = ranking_row.user_id;

    if ranking_row.place = 1 then
      insert into public.daily_trader_winners (
        winner_date, winner_id, nickname, score, reward
      )
      values (
        v_day, ranking_row.user_id, ranking_row.nickname,
        ranking_row.score, reward_amount
      )
      on conflict (winner_date) do nothing;
    end if;

    ranking := ranking ||
      case when ranking = '' then '' else ' · ' end ||
      ranking_row.place::text || ' место — ' || ranking_row.nickname ||
      ' (+' || round(ranking_row.score, 2)::text || '$), приз ' ||
      round(reward_amount, 2)::text || '$';
  end loop;

  if ranking = '' then
    return;
  end if;

  select user_id into admin_id
  from public.admin_users
  order by created_at
  limit 1;

  if admin_id is not null then
    insert into public.chat_messages (user_id, body)
    values (admin_id, left('Рейтинг GoodTrader за сегодня: ' || ranking, 240));
  end if;
end;
$$;

revoke all on function public.publish_daily_trader_winner() from public, anon, authenticated;

create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'daily-trader-winner') then
    perform cron.schedule(
      'daily-trader-winner',
      '0 18 * * *',
      'select public.publish_daily_trader_winner()'
    );
  end if;
end;
$$;
