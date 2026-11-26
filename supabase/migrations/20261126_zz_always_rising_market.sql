begin;

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
      greatest(
        0.01,
        round(
          case
            when target.ticker is null then stock.price
            else target.start_price
              + (target.target_price - target.start_price)
                * least(
                    1::numeric,
                    greatest(
                      0::numeric,
                      extract(epoch from (v_now - target.created_at))
                        / target.ramp_seconds
                    )
                  )
          end
            + (random()::numeric - 0.5)
              * greatest(0.01, round(stock.price * 0.000005, 2)),
          2
        )
      ) as next_price,
      greatest(0.01, round(stock.price * 0.000005, 2)) as jitter_step
    from public.market_stocks stock
    left join public.daily_market_targets target
      on target.ticker = stock.ticker
      and (target.target_date = v_day or target.manual_target)
      and target.ramp_seconds > 0
  )
  update public.market_stocks as stock
  set price = least(
        999999999999.99::numeric,
        greatest(
          movements.next_price,
          movements.current_price + movements.jitter_step
        )
      ),
      updated_at = v_now
  from market_movements movements
  where stock.ticker = movements.ticker;

  update public.market_state
  set last_tick_at = v_now
  where id = true;
end;
$$;

commit;
