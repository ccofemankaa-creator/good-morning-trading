begin;

alter table public.daily_trader_rankings
  drop constraint if exists daily_trader_rankings_place_check,
  drop constraint if exists daily_trader_rankings_reward_check;

alter table public.daily_trader_rankings
  add constraint daily_trader_rankings_place_check
    check (place between 1 and 5),
  add constraint daily_trader_rankings_reward_check
    check (reward >= 0);

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
  ranking text;
  reward_amount numeric(14, 2);
begin
  perform pg_advisory_xact_lock(hashtext('daily-trader-winner-' || v_day::text));
  if exists (select 1 from public.daily_trader_rankings where winner_date = v_day) then
    return;
  end if;

  select admins.user_id
  into admin_id
  from public.admin_users admins
  join public.profiles profiles on profiles.id = admins.user_id
  where lower(btrim(profiles.nickname)) = 'goodtrader'
  order by admins.created_at
  limit 1;

  if admin_id is null then
    raise exception 'GoodTrader admin profile not found';
  end if;

  ranking := '';
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
    where ranked.place <= 5
    order by ranked.place
  loop
    reward_amount := case ranking_row.place
      when 1 then 1000
      when 2 then 500
      when 3 then 300
      else 0
    end;

    insert into public.daily_trader_rankings (
      winner_date, place, user_id, nickname, score, reward, trade_count, tickers
    )
    values (
      v_day, ranking_row.place, ranking_row.user_id,
      ranking_row.nickname, ranking_row.score, reward_amount,
      ranking_row.trade_count, ranking_row.tickers
    );

    if reward_amount > 0 then
      update public.wallets
      set balance = balance + reward_amount
      where user_id = ranking_row.user_id;
    end if;

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
      case when ranking = '' then '' else '; ' end ||
      ranking_row.place::text || '. ' ||
      case
        when char_length(ranking_row.nickname) > 20
          then left(ranking_row.nickname, 17) || '...'
        else ranking_row.nickname
      end ||
      ' +' || round(ranking_row.score)::text || '$';
  end loop;

  if ranking = '' then
    insert into public.chat_messages (user_id, body)
    values (
      admin_id,
      'Рейтинг GoodTrader за сегодня: сегодня нет закрытых прибыльных сделок.'
    );
    return;
  end if;

  insert into public.chat_messages (user_id, body)
  values (admin_id, left('Рейтинг GoodTrader за сегодня: ' || ranking, 240));
end;
$$;

revoke all on function public.publish_daily_trader_winner() from public, anon, authenticated;

commit;
