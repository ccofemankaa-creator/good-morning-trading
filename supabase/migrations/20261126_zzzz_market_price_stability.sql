begin;

create or replace function public.keep_market_stock_within_price_band()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.price := greatest(
    greatest(0.01::numeric, new.base_price * 0.55),
    least(999999999999.99::numeric, new.base_price * 1.45, new.price)
  );
  return new;
end;
$$;

drop trigger if exists market_stocks_price_band on public.market_stocks;
create trigger market_stocks_price_band
before insert or update of price, base_price on public.market_stocks
for each row
execute function public.keep_market_stock_within_price_band();

update public.market_stocks
set price = greatest(
      greatest(0.01::numeric, base_price * 0.55),
      least(999999999999.99::numeric, base_price * 1.45, price)
    ),
    updated_at = now()
where price < greatest(0.01::numeric, base_price * 0.55)
   or price > least(999999999999.99::numeric, base_price * 1.45);

create or replace function public.apply_daily_market_targets()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_day date := (v_now at time zone 'Europe/Moscow')::date;
  v_last_date date;
  v_last_tick timestamptz;
  v_target_magnitude numeric(14, 2);
  v_target_direction integer;
  v_liquidation_text text;
  v_target_price numeric(14, 2);
  stock_row record;
begin
  select daily_target_date, last_tick_at
  into v_last_date, v_last_tick
  from public.market_state
  where id = true
  for update;

  if v_now - v_last_tick < interval '1 second' then
    return;
  end if;

  update public.daily_market_targets
  set manual_target = false
  where manual_target
    and v_now >= created_at + make_interval(secs => ramp_seconds);

  if v_last_date is distinct from v_day then
    for stock_row in
      select stock.ticker, stock.price
      from public.market_stocks stock
      where not stock.event_driven
        and not exists (
          select 1
          from public.daily_market_targets target
          where target.ticker = stock.ticker
            and target.manual_target
            and v_now < target.created_at + make_interval(secs => target.ramp_seconds)
        )
    loop
      v_target_magnitude := 2 + floor(random() * 4)::integer;
      v_target_direction := case when random() < 0.5 then -1 else 1 end;
      v_target_price := greatest(
        0.01,
        round(stock_row.price * (1 + v_target_magnitude * v_target_direction / 100), 2)
      );

      insert into public.daily_market_targets (
        ticker, target_price, target_percent, target_date, start_price,
        ramp_seconds, manual_target, created_at
      )
      values (
        stock_row.ticker,
        v_target_price,
        least(9999.99, greatest(-9999.99,
          round((v_target_price / stock_row.price - 1) * 100, 2))),
        v_day,
        stock_row.price,
        3600,
        false,
        v_now
      )
      on conflict (ticker) do update
      set target_price = excluded.target_price,
          target_percent = excluded.target_percent,
          target_date = excluded.target_date,
          start_price = excluded.start_price,
          ramp_seconds = excluded.ramp_seconds,
          manual_target = false,
          created_at = excluded.created_at;
    end loop;

    update public.market_state
    set daily_target_date = v_day
    where id = true;
  end if;

  with market_movements as materialized (
    select
      stock.ticker,
      stock.price as current_price,
      stock.base_price,
      greatest(0.01::numeric, stock.base_price * 0.55) as lower_limit,
      least(999999999999.99::numeric, stock.base_price * 1.45) as upper_limit,
      case
        when news.created_at >= v_last_tick and news.change > 0 then 1
        when news.created_at >= v_last_tick and news.change < 0 then -1
        when target.target_price > stock.price then 1
        when target.target_price < stock.price then -1
        else 0
      end as signal_direction,
      case
        when news.created_at >= v_last_tick then
          least(45, greatest(1, ceil(abs(news.change))::integer))
        else 1 + floor(random() * 3)::integer
      end as change_percent,
      random() as shuffle
    from public.market_stocks stock
    left join public.daily_market_targets target
      on target.ticker = stock.ticker
      and (target.target_date = v_day or target.manual_target)
      and target.ramp_seconds > 0
    left join lateral (
      select item.change, item.created_at
      from public.market_news item
      where item.ticker = stock.ticker
        and item.created_at >= v_last_tick
      order by item.created_at desc, item.id desc
      limit 1
    ) news on true
  ),
  balanced_movements as materialized (
    select
      movements.*,
      row_number() over (
        order by
          case
            when movements.current_price <= movements.lower_limit then 0
            when movements.current_price >= movements.upper_limit then 4
            when movements.signal_direction > 0 then 1
            when movements.signal_direction = 0 then 2
            else 3
          end,
          movements.shuffle,
          movements.ticker
      ) as direction_rank,
      count(*) over () as stock_count
    from market_movements movements
  )
  update public.market_stocks as stock
  set price = case
        when movements.direction_rank <= (movements.stock_count + 1) / 2 then least(
          movements.upper_limit,
          ceil(movements.current_price
            * (100 + movements.change_percent) / 100.0 * 100) / 100
        )
        else greatest(
          movements.lower_limit,
          floor(movements.current_price
            * (100 - movements.change_percent) / 100.0 * 100) / 100
        )
      end,
      updated_at = v_now
  from balanced_movements movements
  where stock.ticker = movements.ticker;

  update public.market_state
  set last_tick_at = v_now
  where id = true;
end;
$$;

revoke all on function public.apply_daily_market_targets() from public, anon, authenticated;
revoke all on function public.keep_market_stock_within_price_band() from public, anon, authenticated;

commit;