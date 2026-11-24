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

create table if not exists public.market_price_overrides (
  id bigint generated always as identity primary key,
  ticker text not null references public.market_stocks (ticker),
  fixed_price numeric(14, 2) not null check (fixed_price > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null check (ends_at > starts_at),
  created_at timestamptz not null default now(),
  unique (ticker, starts_at)
);

alter table public.scheduled_market_events enable row level security;
alter table public.market_price_overrides enable row level security;
alter table public.market_state add column if not exists daily_target_date date;

create table if not exists public.daily_market_targets (
  ticker text primary key references public.market_stocks (ticker) on delete cascade,
  target_price numeric(14, 2) not null check (target_price > 0),
  target_percent numeric(6, 2) not null,
  target_date date not null,
  created_at timestamptz not null default now()
);

alter table public.daily_market_targets enable row level security;

grant select (id, news_id, body, created_at) on public.news_comments to anon, authenticated;

create table if not exists public.user_task_rewards (
  user_id uuid not null references auth.users (id) on delete cascade,
  task text not null,
  reward numeric(14, 2) not null check (reward > 0),
  claimed_at timestamptz not null default now(),
  primary key (user_id, task)
);

alter table public.user_task_rewards enable row level security;

create table if not exists public.profile_gifts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  amount numeric(14, 2) not null check (amount > 0),
  message text not null,
  received_at timestamptz not null default now(),
  shown_at timestamptz
);
alter table public.profile_gifts enable row level security;
drop policy if exists profile_gifts_read_self on public.profile_gifts;
create policy profile_gifts_read_self on public.profile_gifts
for select to authenticated using (user_id = auth.uid());
drop policy if exists profile_gifts_update_self on public.profile_gifts;
create policy profile_gifts_update_self on public.profile_gifts
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());
grant select, update (shown_at) on public.profile_gifts to authenticated;

create table if not exists public.referrals (
  referrer_id uuid not null references auth.users (id) on delete cascade,
  referred_id uuid primary key references auth.users (id) on delete cascade,
  reward numeric(14, 2) not null default 1000 check (reward > 0),
  created_at timestamptz not null default now(),
  unique (referrer_id, referred_id)
);
alter table public.referrals enable row level security;
drop policy if exists referrals_read_self on public.referrals;
create policy referrals_read_self on public.referrals
for select to authenticated
using (referrer_id = auth.uid() or referred_id = auth.uid());
grant select on public.referrals to authenticated;

drop policy if exists user_task_rewards_read_self on public.user_task_rewards;
create policy user_task_rewards_read_self on public.user_task_rewards
for select to authenticated
using (user_id = auth.uid());

grant select on public.user_task_rewards to authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end;
$$;

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
  v_percent numeric(6, 2);
  stock_row record;
begin
  select daily_target_date
  into v_last_date
  from public.market_state
  where id = true;

  if v_last_date is distinct from v_day then
    for stock_row in select ticker, base_price from public.market_stocks loop
      v_percent := (10 + floor(random() * 41)::integer)
        * case when random() < 0.5 then -1 else 1 end;

      insert into public.daily_market_targets (
        ticker, target_price, target_percent, target_date, created_at
      )
      values (
        stock_row.ticker,
        round(greatest(0.01, stock_row.base_price * (1 + v_percent / 100.0)), 2),
        v_percent,
        v_day,
        v_now
      )
      on conflict (ticker) do update
      set target_price = excluded.target_price,
          target_percent = excluded.target_percent,
          target_date = excluded.target_date,
          created_at = excluded.created_at;
    end loop;

    update public.market_state
    set daily_target_date = v_day
    where id = true;
  end if;

  update public.market_stocks as stock
  set price = greatest(
        0.01,
        round(
          case
            when random() < 0.65
              then stock.price + (target.target_price - stock.price) * (0.03 + random() * 0.05)
            else stock.price
          end,
          2
        )
      ),
      updated_at = v_now
  from public.daily_market_targets target
  where target.ticker = stock.ticker
    and target.target_date = v_day;
end;
$$;

revoke all on function public.apply_daily_market_targets() from public, anon, authenticated;

create or replace function public.advance_market()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.apply_daily_market_targets();
  perform public.advance_market_internal();
end;
$$;

revoke all on function public.advance_market() from public, anon, authenticated;
grant execute on function public.advance_market() to anon, authenticated;

create or replace function public.claim_task_reward(p_task text, p_reward numeric)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_balance numeric(14, 2);
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if p_task <> 'install_app' or p_reward <> 1000 then
    raise exception 'Invalid task reward';
  end if;
  if exists (
    select 1
    from public.user_task_rewards
    where user_id = auth.uid() and task = p_task
  ) then
    raise exception 'Reward already claimed';
  end if;

  insert into public.user_task_rewards (user_id, task, reward)
  values (auth.uid(), p_task, p_reward);

  update public.wallets
  set balance = balance + p_reward
  where user_id = auth.uid()
  returning balance into current_balance;

  if current_balance is null then
    raise exception 'Wallet not found';
  end if;
  return current_balance;
end;
$$;

revoke all on function public.claim_task_reward(text, numeric) from public, anon;
grant execute on function public.claim_task_reward(text, numeric) to authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_username text;
  new_nickname text;
begin
  new_username := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    'user-' || left(new.id::text, 8)
  );
  new_nickname := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'nickname'), ''),
    new_username
  );
  insert into public.profiles (id, username, nickname)
  values (new.id, left(new_username, 24), left(new_nickname, 24))
  on conflict (id) do nothing;
  insert into public.wallets (user_id, balance)
  values (new.id, 500)
  on conflict (user_id) do nothing;
  insert into public.chat_messages (user_id, body)
  values (new.id, 'Привет, трейдер ' || left(new_nickname, 24) || '!')
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

insert into public.market_stocks (ticker, english_name, name, price, base_price)
values
  ('FYF', 'fyfik', 'Файфик', 120, 120),
  ('KAT', 'Kate', 'Kate', 110, 110)
on conflict (ticker) do nothing;

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
  ('CVK', 'down', 'Все искали ключи от Civic одновременно — инвесторы занервничали'),
  ('FYF', 'up', 'Популярный стрим поднял интерес к fyfik'),
  ('FYF', 'up', 'Российские стримеры заметили FYF — акции растут'),
  ('FYF', 'up', 'Поддержка Kuertov укрепила котировки FYF'),
  ('FYF', 'down', 'Активность российских стримов снизилась — FYF просел'),
  ('FYF', 'down', 'Громкий стрим закончился, интерес к fyfik ослаб'),
  ('FYF', 'down', 'Стриминговое сообщество ушло в боковик — FYF снизился'),
  ('KAT', 'up', 'Мандарины подешевели — Kate получил поддержку'),
  ('KAT', 'up', 'Погода в Москве улучшилась — KAT растёт'),
  ('KAT', 'up', 'Приближение учебной сессии увеличило интерес к Kate'),
  ('KAT', 'down', 'Цена мандаринов выросла — Kate просел'),
  ('KAT', 'down', 'Погода в Москве ухудшилась — котировки KAT снизились'),
  ('KAT', 'down', 'Учебная сессия подошла ближе — инвесторы стали осторожнее')
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

  if v_now - v_last_tick >= interval '1 second' then
    update public.market_stocks
    set price = greatest(
          0.01,
          round(
            price * (
              1 +
              case
                when random() < 0.01 then (case when random() < 0.5 then -1 else 1 end) * (10 + floor(random() * 21)::integer)
                when random() < 0.07 then (case when random() < 0.5 then -1 else 1 end) * (6 + floor(random() * 5)::integer)
                else (case when random() < 0.5 then -1 else 1 end) * (1 + floor(random() * 5)::integer)
              end / 100.0
            ),
            2
          )
        ),
        updated_at = v_now
    where not exists (
      select 1
      from public.market_price_overrides price_lock
      where price_lock.ticker = market_stocks.ticker
        and price_lock.starts_at <= v_now
        and price_lock.ends_at > v_now
    );

    update public.market_state
    set last_tick_at = v_now
    where id = true;
  end if;

  if v_now - v_last_news >= interval '1 hour' then
    select ticker, direction, text
    into selected_ticker, selected_direction, selected_text
    from public.news_templates
    where not exists (
      select 1
      from public.market_price_overrides price_lock
      where price_lock.ticker = news_templates.ticker
        and price_lock.starts_at <= v_now
        and price_lock.ends_at > v_now
    )
    order by random()
    limit 1;

    news_change := (
      1 + floor(random() * 5)::integer
    ) * case when selected_direction = 'up' then 1 else -1 end;

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
