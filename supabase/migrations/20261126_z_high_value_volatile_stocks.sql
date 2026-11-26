begin;

alter table public.market_stocks
  add column if not exists event_driven boolean not null default false;

alter table public.daily_market_targets
  add column if not exists start_price numeric(14, 2),
  add column if not exists ramp_seconds integer not null default 3600,
  add column if not exists manual_target boolean not null default false;

alter table public.positions
  add column if not exists opening_fee numeric(20, 2) not null default 0
    check (opening_fee >= 0);

update public.daily_market_targets targets
set start_price = stocks.price
from public.market_stocks stocks
where targets.ticker = stocks.ticker
  and targets.start_price is null;

alter table public.daily_market_targets
  alter column start_price set not null;

insert into public.market_stocks (
  ticker, english_name, name, price, base_price, event_driven
)
values
  ('KRK', 'Krak', 'Krak', 10000000, 10000000, true),
  ('SGM', 'Sigma', 'Сигма', 20000000, 20000000, true),
  ('DOLBAEB', 'DOLBAEB', 'Долбаёб', 60000000, 60000000, true)
on conflict (ticker) do nothing;

update public.market_stocks
set event_driven = true
where ticker in ('KRK', 'SGM', 'DOLBAEB');

create table if not exists public.daily_market_liquidations (
  market_day date primary key,
  ticker text references public.market_stocks (ticker),
  price_before numeric(14, 2),
  price_after numeric(14, 2),
  news_text text,
  created_at timestamptz not null default now(),
  check (
    (ticker is null and price_before is null and price_after is null and news_text is null)
    or
    (ticker is not null and price_before is not null and price_after is not null and news_text is not null)
  )
);

alter table public.daily_market_liquidations enable row level security;

insert into public.daily_market_liquidations (market_day)
values ((now() at time zone 'Europe/Moscow')::date)
on conflict (market_day) do nothing;

create or replace function public.publish_market_event(
  p_ticker text,
  p_category text,
  p_direction text,
  p_news_text text
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current_price numeric(14, 2);
  v_target_price numeric(14, 2);
  v_change_percent numeric(6, 2);
  v_event_id bigint;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  if p_category is null or p_category not in (
    'ordinary', 'notable', 'scandal', 'catastrophe', 'black_swan'
  ) then
    raise exception 'Invalid market event category';
  end if;
  if p_direction is null or p_direction not in ('up', 'down') then
    raise exception 'Invalid market event direction';
  end if;
  if p_news_text is null or char_length(btrim(p_news_text)) not between 1 and 240 then
    raise exception 'News text must contain 1 to 240 characters';
  end if;

  select price
  into v_current_price
  from public.market_stocks
  where ticker = p_ticker
  for share;

  if v_current_price is null then
    raise exception 'Unknown stock';
  end if;

  v_change_percent := case p_category
    when 'ordinary' then 2 + floor(random() * 4)::integer
    when 'notable' then 6 + floor(random() * 7)::integer
    when 'scandal' then 15 + floor(random() * 6)::integer
    when 'catastrophe' then 25 + floor(random() * 11)::integer
    when 'black_swan' then 40 + floor(random() * 21)::integer
  end;

  if p_category <> 'catastrophe' and p_direction = 'down' then
    v_change_percent := -v_change_percent;
  end if;

  v_target_price := greatest(
    0.01,
    round(v_current_price * (1 + v_change_percent / 100), 2)
  );

  insert into public.scheduled_market_events (
    ticker, target_price, execute_at, news_text
  )
  values (p_ticker, v_target_price, now(), btrim(p_news_text))
  returning id into v_event_id;

  return v_event_id;
end;
$$;

revoke all on function public.publish_market_event(text, text, text, text) from public, anon;
grant execute on function public.publish_market_event(text, text, text, text) to authenticated;

create or replace function public.advance_market_internal()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_last_news timestamptz;
  v_current_price numeric(14, 2);
  v_target_price numeric(14, 2);
  v_target_magnitude numeric(14, 2);
  v_target_direction integer;
  v_liquidation_text text;
  scheduled_event record;
  stock_row record;
  selected_ticker text;
  selected_direction text;
  selected_text text;
  news_change numeric(6, 2);
  v_day date := (v_now at time zone 'Europe/Moscow')::date;
begin
  select last_news_at
  into v_last_news
  from public.market_state
  where id = true
  for update;

  if v_last_news is null then
    raise exception 'Market state row is missing';
  end if;

  if not exists (
    select 1
    from public.daily_market_liquidations
    where market_day = v_day
  ) then
    select ticker, price
    into stock_row
    from public.market_stocks
    order by random()
    limit 1
    for update;

    if stock_row.ticker is null then
      raise exception 'No stock is available for daily liquidation';
    end if;

    v_target_price := greatest(0.01, round(stock_row.price * 0.5, 2));
    v_liquidation_text := 'Ликвидация дня: ' || stock_row.ticker ||
      ' потеряла половину стоимости. Рынок называет это «чёрным лебедем».';

    update public.market_stocks
    set price = v_target_price,
        updated_at = v_now
    where ticker = stock_row.ticker;

    insert into public.daily_market_targets (
      ticker, target_price, target_percent, target_date, start_price,
      ramp_seconds, manual_target, created_at
    )
    values (
      stock_row.ticker, v_target_price, -50, v_day, v_target_price,
      3600, true, v_now
    )
    on conflict (ticker) do update
    set target_price = excluded.target_price,
        target_percent = excluded.target_percent,
        target_date = excluded.target_date,
        start_price = excluded.start_price,
        ramp_seconds = excluded.ramp_seconds,
        manual_target = excluded.manual_target,
        created_at = excluded.created_at;

    insert into public.market_news (ticker, text, change, created_at)
    values (stock_row.ticker, v_liquidation_text, -50, v_now);

    insert into public.daily_market_liquidations (
      market_day, ticker, price_before, price_after, news_text
    )
    values (
      v_day, stock_row.ticker, stock_row.price, v_target_price, v_liquidation_text
    );

    update public.market_state
    set last_news_at = v_now
    where id = true;
    v_last_news := v_now;
  end if;

  if exists (
    select 1
    from public.scheduled_market_events
    where executed_at is null and execute_at <= v_now
  ) then
    update public.market_state
    set last_news_at = v_now
    where id = true;
    v_last_news := v_now;
  end if;

  if v_now - v_last_news >= interval '1 hour' then
    select templates.ticker, templates.direction, templates.text
    into selected_ticker, selected_direction, selected_text
    from public.news_templates templates
    join public.market_stocks stocks using (ticker)
    where not stocks.event_driven
      and not exists (
        select 1
        from public.daily_market_targets target
        where target.ticker = templates.ticker
          and target.manual_target
          and v_now < target.created_at + make_interval(secs => target.ramp_seconds)
      )
    order by random()
    limit 1;

    if selected_ticker is null then
      raise exception 'No eligible hourly market news template found';
    end if;

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
      v_target_direction := case
        when stock_row.ticker = selected_ticker then
          case when selected_direction = 'up' then 1 else -1 end
        else case when random() < 0.5 then -1 else 1 end
      end;
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
        round((v_target_price / stock_row.price - 1) * 100, 2),
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

      if stock_row.ticker = selected_ticker then
        news_change := round((v_target_price / stock_row.price - 1) * 100, 2);
      end if;
    end loop;

    insert into public.market_news (ticker, text, change, created_at)
    values (selected_ticker, selected_text, news_change, v_now);

    update public.market_state
    set last_news_at = v_now
    where id = true;
  end if;

  for scheduled_event in
    select id, ticker, target_price, news_text
    from public.scheduled_market_events
    where executed_at is null and execute_at <= v_now
    order by execute_at, id
    for update
  loop
    select price
    into v_current_price
    from public.market_stocks
    where ticker = scheduled_event.ticker
    for update;

    if found then
      news_change := round((scheduled_event.target_price / v_current_price - 1) * 100, 2);

      insert into public.daily_market_targets (
        ticker, target_price, target_percent, target_date, start_price,
        ramp_seconds, manual_target, created_at
      )
      values (
        scheduled_event.ticker,
        scheduled_event.target_price,
        news_change,
        v_day,
        v_current_price,
        3600,
        true,
        v_now
      )
      on conflict (ticker) do update
      set target_price = excluded.target_price,
          target_percent = excluded.target_percent,
          target_date = excluded.target_date,
          start_price = excluded.start_price,
          ramp_seconds = excluded.ramp_seconds,
          manual_target = true,
          created_at = excluded.created_at;

      insert into public.market_news (ticker, text, change, created_at)
      values (scheduled_event.ticker, scheduled_event.news_text, news_change, v_now);
    end if;

    update public.scheduled_market_events
    set executed_at = v_now
    where id = scheduled_event.id;
  end loop;

  update public.market_stocks stock
  set price = price_lock.fixed_price,
      updated_at = v_now
  from public.market_price_overrides price_lock
  where stock.ticker = price_lock.ticker
    and price_lock.starts_at <= v_now
    and price_lock.ends_at > v_now
    and stock.price <> price_lock.fixed_price;

  delete from public.market_news
  where id not in (
    select id from public.market_news order by created_at desc limit 100
  );
end;
$$;

revoke all on function public.advance_market_internal() from public, anon, authenticated;

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
        round((v_target_price / stock_row.price - 1) * 100, 2),
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

  update public.market_stocks stock
  set price = greatest(
        0.01,
        round(
          target.start_price
            + (target.target_price - target.start_price)
              * least(
                  1::numeric,
                  greatest(
                    0::numeric,
                    extract(epoch from (v_now - target.created_at))
                      / target.ramp_seconds
                  )
                ),
          2
        )
      ),
      updated_at = v_now
  from public.daily_market_targets target
  where target.ticker = stock.ticker
    and (target.target_date = v_day or target.manual_target)
    and target.ramp_seconds > 0;

  update public.market_state
  set last_tick_at = v_now
  where id = true;
end;
$$;

revoke all on function public.apply_daily_market_targets() from public, anon, authenticated;

create or replace function public.place_order(
  p_ticker text,
  p_side text,
  p_qty integer
)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_price numeric(14, 2);
  current_balance numeric(14, 2);
  trade_cost numeric(20, 2);
  commission numeric(20, 2);
  total_charge numeric(20, 2);
  commission_rate numeric(4, 3);
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if p_side not in ('long', 'short') then
    raise exception 'Invalid order side';
  end if;
  if p_qty is null or p_qty < 1 or p_qty > 100000 then
    raise exception 'Invalid quantity';
  end if;

  select price into current_price
  from public.market_stocks
  where ticker = p_ticker
  for share;

  if current_price is null then
    raise exception 'Unknown stock';
  end if;

  select balance into current_balance
  from public.wallets
  where user_id = auth.uid()
  for update;

  if current_balance is null then
    raise exception 'Wallet not found';
  end if;

  trade_cost := round(current_price * p_qty, 2);
  commission_rate := case when p_side = 'long' then 0.02 else 0.03 end;
  commission := round(trade_cost * commission_rate, 2);
  total_charge := trade_cost + commission;
  if total_charge > current_balance then
    raise exception 'Insufficient balance';
  end if;

  update public.wallets
  set balance = balance - total_charge
  where user_id = auth.uid()
  returning balance into current_balance;

  insert into public.positions (user_id, ticker, side, qty, entry_price, opening_fee)
  values (auth.uid(), p_ticker, p_side, p_qty, current_price, commission);

  return current_balance;
end;
$$;

revoke all on function public.place_order(text, text, integer) from public, anon;
grant execute on function public.place_order(text, text, integer) to authenticated;

create or replace function public.close_position(p_position_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_position public.positions%rowtype;
  current_price numeric(14, 2);
  current_balance numeric(14, 2);
  collateral numeric(20, 2);
  gross_profit_loss numeric(20, 2);
  net_profit_loss numeric(20, 2);
  credit numeric(20, 2);
  opening_fee numeric(20, 2);
  closing_fee numeric(20, 2);
  exit_notional numeric(20, 2);
  closing_fee_rate numeric(4, 3);
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select * into current_position
  from public.positions
  where id = p_position_id and user_id = auth.uid()
  for update;

  if current_position.id is null then
    raise exception 'Position not found';
  end if;

  select price into current_price
  from public.market_stocks
  where ticker = current_position.ticker;

  if current_price is null then
    raise exception 'Stock price not found';
  end if;

  select balance into current_balance
  from public.wallets
  where user_id = auth.uid()
  for update;

  if current_balance is null then
    raise exception 'Wallet not found';
  end if;

  collateral := round(current_position.entry_price * current_position.qty, 2);
  gross_profit_loss := round(
    (case when current_position.side = 'long'
      then current_price - current_position.entry_price
      else current_position.entry_price - current_price
    end) * current_position.qty,
    2
  );
  closing_fee_rate := case when current_position.side = 'long' then 0.03 else 0.02 end;
  opening_fee := current_position.opening_fee;
  exit_notional := round(current_price * current_position.qty, 2);
  closing_fee := round(exit_notional * closing_fee_rate, 2);
  credit := greatest(0, collateral + gross_profit_loss - closing_fee);
  net_profit_loss := credit - collateral - opening_fee;

  update public.wallets
  set balance = balance + credit
  where user_id = auth.uid()
  returning balance into current_balance;

  insert into public.trade_history (
    user_id, ticker, side, qty, entry_price, exit_price, profit_loss
  )
  values (
    auth.uid(),
    current_position.ticker,
    current_position.side,
    current_position.qty,
    current_position.entry_price,
    current_price,
    net_profit_loss
  );

  delete from public.positions where id = current_position.id;

  return current_balance;
end;
$$;

revoke all on function public.close_position(uuid) from public, anon;
grant execute on function public.close_position(uuid) to authenticated;

select pg_notify('pgrst', 'reload schema');

commit;
