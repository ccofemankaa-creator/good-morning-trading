begin;

alter table public.daily_market_targets
  add column if not exists start_price numeric(14, 2),
  add column if not exists ramp_seconds integer not null default 3600,
  add column if not exists manual_target boolean not null default false;

update public.market_stocks
set price = greatest(price, 1),
    updated_at = now()
where price < 1;

update public.market_stocks
set price = 70,
    base_price = 70,
    updated_at = now()
where ticker = 'FYF';

update public.scheduled_market_events
set executed_at = now()
where ticker = 'NFR'
  and target_price = 90
  and execute_at <= now()
  and executed_at is null
  and news_text = 'Альбом «Нефора» снова перенесли — акция решила отдохнуть на отметке 90';

update public.daily_market_targets targets
set start_price = stocks.price,
    target_price = stocks.price,
    target_percent = 0,
    target_date = (now() at time zone 'Europe/Moscow')::date,
    ramp_seconds = 3600,
    manual_target = false,
    created_at = now()
from public.market_stocks stocks
where targets.ticker = stocks.ticker;

insert into public.daily_market_targets (
  ticker, target_price, target_percent, target_date, start_price,
  ramp_seconds, manual_target, created_at
)
select ticker, price, 0, (now() at time zone 'Europe/Moscow')::date,
       price, 3600, false, now()
from public.market_stocks
on conflict (ticker) do nothing;

alter table public.daily_market_targets
  alter column start_price set not null;

insert into public.news_templates (ticker, direction, text)
values
  ('GDM', 'up', 'Кнопка «сохранить» сработала с первого раза — инвесторы не поверили глазам'),
  ('GDM', 'down', 'В задаче написали «маленькая правка» — GDM приготовился к марафону'),
  ('NFR', 'up', 'Трек включили даже соседи — NFR получил поддержку аудитории'),
  ('NFR', 'down', 'На репетиции забыли, кто ставит бит, — рынок взял паузу'),
  ('BLN', 'up', 'Пальма дала прогноз погоды без единой ошибки — BLN подрос'),
  ('BLN', 'down', 'Кокос опоздал на совещание — инвесторы назвали это тревожным сигналом'),
  ('CVK', 'up', 'Навигатор сказал «поверните в небо» — CVK набирает высоту'),
  ('CVK', 'down', 'Civic долго искал парковку и пропустил открытие биржи'),
  ('FYF', 'up', 'Стрим задержался, зато зрители дождались роста FYF'),
  ('FYF', 'down', 'Донат пришёл из будущего, а рынок пока не дождался'),
  ('KAT', 'up', 'Мандарины пришли без косточек — рынок увидел знак'),
  ('KAT', 'down', 'Прогноз обещал солнце, но забыл уточнить какое')
on conflict do nothing;

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
  v_target_direction integer;
  v_target_magnitude numeric(14, 2);
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

  if v_now - v_last_news >= interval '1 hour' then
    select ticker, direction, text
    into selected_ticker, selected_direction, selected_text
    from public.news_templates
    where not exists (
      select 1
      from public.daily_market_targets target
      where target.ticker = news_templates.ticker
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
      where not exists (
        select 1
        from public.daily_market_targets target
        where target.ticker = stock.ticker
          and target.manual_target
          and v_now < target.created_at + make_interval(secs => target.ramp_seconds)
      )
    loop
      v_target_magnitude := case
        when random() < 0.05 then 47
        else 1 + floor(random() * 15)::integer
      end;
      v_target_direction := case
        when stock_row.ticker = selected_ticker then
          case when selected_direction = 'up' then 1 else -1 end
        else case when random() < 0.5 then -1 else 1 end
      end;
      v_target_price := greatest(
        1,
        round(stock_row.price + v_target_magnitude * v_target_direction, 2)
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

      if stock_row.ticker = selected_ticker then
        news_change := least(9999.99, greatest(-9999.99,
          round((v_target_price / stock_row.price - 1) * 100, 2)));
      end if;
    end loop;

    insert into public.market_news (ticker, text, change, created_at)
    values (selected_ticker, selected_text, news_change, v_now);

    delete from public.market_news
    where id not in (
      select id from public.market_news order by created_at desc limit 100
    );

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
      news_change := least(9999.99, greatest(-9999.99,
        round((scheduled_event.target_price / v_current_price - 1) * 100, 2)));

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
      where not exists (
        select 1
        from public.daily_market_targets target
        where target.ticker = stock.ticker
          and target.manual_target
          and v_now < target.created_at + make_interval(secs => target.ramp_seconds)
      )
    loop
      v_target_magnitude := case
        when random() < 0.05 then 47
        else 1 + floor(random() * 15)::integer
      end;
      v_target_direction := case when random() < 0.5 then -1 else 1 end;
      v_target_price := greatest(
        1,
        round(stock_row.price + v_target_magnitude * v_target_direction, 2)
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

  update public.market_stocks as stock
  set price = greatest(
        1,
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

insert into public.market_state (id, last_tick_at, last_news_at, daily_target_date)
values (true, now(), now(), (now() at time zone 'Europe/Moscow')::date)
on conflict (id) do update
set last_tick_at = excluded.last_tick_at,
    last_news_at = excluded.last_news_at,
    daily_target_date = excluded.daily_target_date;

insert into public.daily_market_targets (
  ticker, target_price, target_percent, target_date, start_price,
  ramp_seconds, manual_target, created_at
)
select
  stock.ticker,
  300,
  least(9999.99, greatest(-9999.99, round((300 / stock.price - 1) * 100, 2))),
  (now() at time zone 'Europe/Moscow')::date,
  stock.price,
  3600,
  true,
  now()
from public.market_stocks stock
where stock.ticker = 'CVK'
on conflict (ticker) do update
set target_price = excluded.target_price,
    target_percent = excluded.target_percent,
    target_date = excluded.target_date,
    start_price = excluded.start_price,
    ramp_seconds = excluded.ramp_seconds,
    manual_target = true,
    created_at = excluded.created_at;

insert into public.market_news (ticker, text, change, created_at)
select
  stock.ticker,
  'Цивик взлетел после того, как навигатор сказал «поверните в небо» — CVK плавно набирает высоту к $300',
  least(9999.99, greatest(-9999.99, round((300 / stock.price - 1) * 100, 2))),
  now()
from public.market_stocks stock
where stock.ticker = 'CVK';

commit;
