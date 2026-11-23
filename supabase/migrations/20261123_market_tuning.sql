create table if not exists public.scheduled_market_events (
  id bigint generated always as identity primary key,
  ticker text not null references public.market_stocks (ticker),
  target_price numeric(14, 2) not null check (target_price > 0),
  execute_at timestamptz not null,
  news_text text not null,
  executed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (ticker, execute_at)
);

alter table public.scheduled_market_events enable row level security;

delete from public.news_templates;

insert into public.news_templates (ticker, direction, text)
values
  ('GDM', 'up', 'Разработчик выпил кофе — GDM вспомнил, как расти'),
  ('GDM', 'up', 'Кнопка «купить» выглядит убедительно — инвесторы поверили в GDM'),
  ('GDM', 'up', 'В проекте нашли ещё одну кнопку — аналитики повысили прогноз'),
  ('GDM', 'down', 'Разработчик открыл консоль с 17 ошибками — GDM ушёл на перекур'),
  ('GDM', 'down', 'Кофе закончился, аналитики тоже — акции GDM просели'),
  ('GDM', 'down', 'Курсор завис над кнопкой «продать» — рынок занервничал'),
  ('NFR', 'up', 'Новый трек короче очереди в поддержку — NFR взлетел'),
  ('NFR', 'up', 'Микрофон попал в чарт — инвесторы тоже включили бит'),
  ('NFR', 'up', 'Рэп-баттл выиграл микрофон, но оба трека в чарте'),
  ('NFR', 'down', 'Альбом перенесли на завтра — фанаты постарели на целый день'),
  ('NFR', 'down', 'Автотюн ушёл на техобслуживание — NFR просел'),
  ('NFR', 'down', 'Диджей поставил тишину на повтор — рынок не оценил эксперимент'),
  ('BLN', 'up', 'Во Вьетнаме солнце вышло на смену раньше начальника — BLN зеленеет'),
  ('BLN', 'up', 'Кофе со льдом распродали — рынок поверил в вечное лето'),
  ('BLN', 'up', 'Пальмы синхронно качнулись в такт — инвесторы заметили сигнал'),
  ('BLN', 'down', 'Дождь во Вьетнаме отменил фотосессию пальм — BLN покраснел'),
  ('BLN', 'down', 'Тайфун попросил отпуск и всё равно пришёл на рынок'),
  ('BLN', 'down', 'Зонт не прошёл техосмотр — прогноз по BLN испортился'),
  ('CVK', 'up', 'Civic припарковался так красиво, что аналитики купили акции'),
  ('CVK', 'up', 'В Civic нашли ещё одно место под стакан — CVK в плюсе'),
  ('CVK', 'up', 'Civic завёлся с первого раза — рынок назвал это чудом'),
  ('CVK', 'down', 'Робот-парковщик припарковался лучше человека — CVK задумался'),
  ('CVK', 'down', 'Навигатор предложил объезд на 400 километров — CVK просел'),
  ('CVK', 'down', 'Все искали ключи от Civic одновременно — инвесторы занервничали')
on conflict do nothing;

create or replace function public.advance_market_internal()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_last_tick timestamptz;
  v_last_news timestamptz;
  v_volatile boolean;
  v_tick_range numeric;
  v_current_price numeric(14, 2);
  scheduled_event record;
  selected_ticker text;
  selected_direction text;
  selected_text text;
  news_change numeric(6, 2);
begin
  select last_tick_at, last_news_at
  into v_last_tick, v_last_news
  from public.market_state
  where id = true
  for update;

  v_volatile := mod(extract(hour from (v_now at time zone 'Europe/Moscow'))::integer, 2) = 1;
  v_tick_range := case when v_volatile then 0.0016 else 0.0004 end;

  if v_now - v_last_tick >= interval '5 seconds' then
    update public.market_stocks
    set price = greatest(0.01, round(price * (1 + (random() - 0.5) * v_tick_range), 2)),
        updated_at = v_now;

    update public.market_state
    set last_tick_at = v_now
    where id = true;
  end if;

  if v_now - v_last_news >= interval '1 hour' then
    select ticker, direction, text
    into selected_ticker, selected_direction, selected_text
    from public.news_templates
    order by random()
    limit 1;

    news_change := case
      when v_volatile then 5
      else round(0.8 + random() * 0.7, 2)
    end * case when selected_direction = 'up' then 1 else -1 end;

    update public.market_stocks
    set price = greatest(0.01, round(price * (1 + news_change / 100), 2)),
        updated_at = v_now
    where ticker = selected_ticker;

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

      update public.market_stocks
      set price = scheduled_event.target_price,
          updated_at = v_now
      where ticker = scheduled_event.ticker;

      insert into public.market_news (ticker, text, change, created_at)
      values (scheduled_event.ticker, scheduled_event.news_text, news_change, v_now);
    end if;

    update public.scheduled_market_events
    set executed_at = v_now
    where id = scheduled_event.id;
  end loop;

  delete from public.market_news
  where id not in (
    select id from public.market_news order by created_at desc limit 100
  );
end;
$$;

do $$
declare
  current_price numeric(14, 2);
begin
  select price
  into current_price
  from public.market_stocks
  where ticker = 'NFR'
  for update;

  if not found then
    raise exception 'NFR stock is missing from market_stocks';
  end if;

  if current_price <> 140 then
    insert into public.market_news (ticker, text, change, created_at)
    values (
      'NFR',
      '«Нефор» пообещал выпустить альбом ровно после того, как акция дойдёт до 140',
      round((140 / current_price - 1) * 100, 2),
      now()
    );

    update public.market_stocks
    set price = 140,
        updated_at = now()
    where ticker = 'NFR';
  end if;

  insert into public.scheduled_market_events (ticker, target_price, execute_at, news_text)
  values (
    'NFR',
    90,
    timestamptz '2026-11-23 13:00:00+03',
    'Альбом «Нефора» снова перенесли — акция решила отдохнуть на отметке 90'
  )
  on conflict (ticker, execute_at) do nothing;
end;
$$;
