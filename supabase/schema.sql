create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null constraint profiles_username_length_check
    check (char_length(btrim(username)) between 2 and 24),
  nickname text not null check (char_length(btrim(nickname)) between 2 and 24),
  created_at timestamptz not null default now()
);

alter table public.profiles add column if not exists username text;

with ranked_profiles as (
  select id, nickname, row_number() over (
    partition by lower(btrim(nickname))
    order by created_at, id
  ) as duplicate_rank
  from public.profiles
  where username is null or btrim(username) = ''
)
update public.profiles as profiles
set username = case
  when ranked_profiles.duplicate_rank = 1 then left(btrim(ranked_profiles.nickname), 24)
  else 'user-' || left(profiles.id::text, 8)
end
from ranked_profiles
where profiles.id = ranked_profiles.id;

alter table public.profiles alter column username set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'profiles_username_length_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_username_length_check
      check (char_length(btrim(username)) between 2 and 24);
  end if;
end;
$$;

create unique index if not exists profiles_username_ci_unique_idx
  on public.profiles (lower(btrim(username)));

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.wallets (
  user_id uuid primary key references auth.users (id) on delete cascade,
  balance numeric(14, 2) not null default 1000 check (balance >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.market_stocks (
  ticker text primary key,
  english_name text not null,
  name text not null,
  price numeric(14, 2) not null check (price > 0),
  base_price numeric(14, 2) not null check (base_price > 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.news_templates (
  id bigint generated always as identity primary key,
  ticker text not null references public.market_stocks (ticker) on delete cascade,
  direction text not null check (direction in ('up', 'down')),
  text text not null
);

create table if not exists public.market_news (
  id bigint generated always as identity primary key,
  ticker text not null references public.market_stocks (ticker),
  text text not null,
  change numeric(6, 2) not null,
  created_at timestamptz not null default now()
);

create table if not exists public.market_state (
  id boolean primary key default true check (id),
  last_tick_at timestamptz not null default now(),
  last_news_at timestamptz not null default now()
);

alter table public.market_state
  add column if not exists daily_target_date date;

create table if not exists public.daily_market_targets (
  ticker text primary key references public.market_stocks (ticker) on delete cascade,
  target_price numeric(14, 2) not null check (target_price > 0),
  target_percent numeric(6, 2) not null,
  target_date date not null,
  created_at timestamptz not null default now()
);

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

create table if not exists public.positions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ticker text not null references public.market_stocks (ticker),
  side text not null check (side in ('long', 'short')),
  qty integer not null check (qty > 0 and qty <= 100000),
  entry_price numeric(14, 2) not null check (entry_price > 0),
  opened_at timestamptz not null default now()
);

create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 240),
  created_at timestamptz not null default now()
);

create table if not exists public.news_comments (
  id bigint generated always as identity primary key,
  news_id bigint not null references public.market_news (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 240),
  created_at timestamptz not null default now()
);

create table if not exists public.balance_adjustments (
  id bigint generated always as identity primary key,
  admin_id uuid not null references auth.users (id),
  target_user_id uuid not null references auth.users (id),
  delta numeric(14, 2) not null check (delta <> 0),
  reason text not null check (char_length(btrim(reason)) between 1 and 200),
  created_at timestamptz not null default now()
);

create table if not exists public.trade_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  ticker text not null,
  side text not null check (side in ('long', 'short')),
  qty integer not null check (qty > 0),
  entry_price numeric(14, 2) not null,
  exit_price numeric(14, 2) not null,
  profit_loss numeric(14, 2) not null,
  closed_at timestamptz not null default now()
);

create table if not exists public.profile_gifts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  amount numeric(14, 2) not null check (amount > 0),
  message text not null,
  received_at timestamptz not null default now(),
  shown_at timestamptz
);

create table if not exists public.daily_trader_winners (
  winner_date date primary key,
  winner_id uuid not null references auth.users (id),
  nickname text not null,
  score numeric(14, 2) not null,
  reward numeric(14, 2) not null default 500,
  created_at timestamptz not null default now()
);

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

create table if not exists public.daily_welcome_bonus_claims (
  user_id uuid not null references auth.users (id) on delete cascade,
  welcome_date date not null,
  amount numeric(14, 2) not null default 200 check (amount = 200),
  claimed_at timestamptz not null default now(),
  primary key (user_id, welcome_date)
);

create table if not exists public.user_task_rewards (
  user_id uuid not null references auth.users (id) on delete cascade,
  task text not null,
  reward numeric(14, 2) not null check (reward > 0),
  claimed_at timestamptz not null default now(),
  primary key (user_id, task)
);

create table if not exists public.referrals (
  referrer_id uuid not null references auth.users (id) on delete cascade,
  referred_id uuid primary key references auth.users (id) on delete cascade,
  reward numeric(14, 2) not null default 1000 check (reward > 0),
  created_at timestamptz not null default now(),
  unique (referrer_id, referred_id)
);

create unique index if not exists news_templates_unique_idx
  on public.news_templates (ticker, direction, text);

insert into public.market_stocks (ticker, english_name, name, price, base_price)
values
  ('GDM', 'Good Morning', 'Гуд Морнинг', 150, 150),
  ('NFR', 'Nefor', 'Нефор', 95, 95),
  ('BLN', 'Blond', 'Блонд', 70, 70),
  ('CVK', 'Civic', 'Цивик', 130, 130),
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

insert into public.market_state (id) values (true) on conflict (id) do nothing;

create index if not exists market_news_created_at_idx on public.market_news (created_at desc);
create index if not exists chat_messages_created_at_idx on public.chat_messages (created_at desc);
create index if not exists news_comments_news_id_created_at_idx
  on public.news_comments (news_id, created_at);
create index if not exists positions_user_id_idx on public.positions (user_id);

alter table public.profiles enable row level security;
alter table public.admin_users enable row level security;
alter table public.wallets enable row level security;
alter table public.market_stocks enable row level security;
alter table public.news_templates enable row level security;
alter table public.market_news enable row level security;
alter table public.market_state enable row level security;
alter table public.scheduled_market_events enable row level security;
alter table public.market_price_overrides enable row level security;
alter table public.daily_market_targets enable row level security;
alter table public.positions enable row level security;
alter table public.chat_messages enable row level security;
alter table public.news_comments enable row level security;
alter table public.balance_adjustments enable row level security;
alter table public.trade_history enable row level security;
alter table public.daily_trader_winners enable row level security;
alter table public.daily_trader_rankings enable row level security;
alter table public.daily_welcome_bonus_claims enable row level security;
alter table public.profile_gifts enable row level security;
alter table public.user_task_rewards enable row level security;
alter table public.referrals enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.admin_users where user_id = auth.uid()
  );
$$;

revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

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

create or replace function public.admin_delete_user(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'Administrators cannot delete their own account here';
  end if;
  if exists (select 1 from public.admin_users where user_id = p_user_id) then
    raise exception 'Administrator accounts cannot be deleted here';
  end if;

  delete from auth.users where id = p_user_id;
  if not found then
    raise exception 'User not found';
  end if;
end;
$$;

revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_username text;
  new_nickname text;
  referral_id uuid;
begin
  new_username := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
    'user-' || left(new.id::text, 8)
  );
  new_nickname := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'nickname'), ''),
    new_username
  );
  if char_length(new_username) < 2 then
    new_username := 'user-' || left(new.id::text, 8);
  end if;
  if char_length(new_nickname) < 2 then
    new_nickname := new_username;
  end if;

  insert into public.profiles (id, username, nickname)
  values (new.id, left(new_username, 24), left(new_nickname, 24))
  on conflict (id) do nothing;

  insert into public.wallets (user_id, balance)
  values (new.id, 500)
  on conflict (user_id) do nothing;

  insert into public.chat_messages (user_id, body)
  values (new.id, 'Привет, трейдер ' || left(new_nickname, 24) || '!')
  on conflict do nothing;

  begin
    referral_id := nullif(btrim(new.raw_user_meta_data ->> 'referral_id'), '')::uuid;
  exception when invalid_text_representation then
    referral_id := null;
  end;
  if referral_id is not null and referral_id <> new.id
     and exists (select 1 from public.wallets where user_id = referral_id) then
    insert into public.referrals (referrer_id, referred_id)
    values (referral_id, new.id)
    on conflict (referred_id) do nothing;
    if found then
      update public.wallets
      set balance = balance + 1000
      where user_id = referral_id;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
for select to anon, authenticated using (true);

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists admin_users_read_self on public.admin_users;
create policy admin_users_read_self on public.admin_users
for select to authenticated using (user_id = auth.uid());

drop policy if exists wallets_read_self_or_admin on public.wallets;
create policy wallets_read_self_or_admin on public.wallets
for select to authenticated using (user_id = auth.uid() or public.is_admin());

drop policy if exists market_stocks_read on public.market_stocks;
create policy market_stocks_read on public.market_stocks
for select to anon, authenticated using (true);

drop policy if exists market_news_read on public.market_news;
create policy market_news_read on public.market_news
for select to anon, authenticated using (true);

drop policy if exists positions_read_self_or_admin on public.positions;
create policy positions_read_self_or_admin on public.positions
for select to authenticated using (user_id = auth.uid() or public.is_admin());

drop policy if exists chat_messages_read on public.chat_messages;
create policy chat_messages_read on public.chat_messages
for select to anon, authenticated
using (public.can_read_chat_message(created_at));

drop policy if exists chat_messages_insert_self on public.chat_messages;
create policy chat_messages_insert_self on public.chat_messages
for insert to authenticated with check (user_id = auth.uid());

drop policy if exists chat_messages_delete_admin on public.chat_messages;
create policy chat_messages_delete_admin on public.chat_messages
for delete to authenticated using (public.is_admin());

drop policy if exists news_comments_read on public.news_comments;
create policy news_comments_read on public.news_comments
for select to anon, authenticated using (true);

drop policy if exists news_comments_insert_self on public.news_comments;
create policy news_comments_insert_self on public.news_comments
for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists balance_adjustments_read_admin on public.balance_adjustments;
create policy balance_adjustments_read_admin on public.balance_adjustments
for select to authenticated using (public.is_admin());

drop policy if exists trade_history_read_admin on public.trade_history;
create policy trade_history_read_admin on public.trade_history
for select to authenticated using (public.is_admin());

drop policy if exists daily_winners_read on public.daily_trader_winners;
create policy daily_winners_read on public.daily_trader_winners
for select to anon, authenticated using (true);

drop policy if exists daily_rankings_read on public.daily_trader_rankings;
create policy daily_rankings_read on public.daily_trader_rankings
for select to anon, authenticated using (true);

drop policy if exists profile_gifts_read_self on public.profile_gifts;
create policy profile_gifts_read_self on public.profile_gifts
for select to authenticated using (user_id = auth.uid());

drop policy if exists profile_gifts_update_self on public.profile_gifts;
create policy profile_gifts_update_self on public.profile_gifts
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

grant select on public.trade_history, public.daily_trader_winners to authenticated;
grant select (winner_date, place, nickname, score, reward, trade_count, tickers)
  on public.daily_trader_rankings to anon, authenticated;
grant select, update (shown_at) on public.profile_gifts to authenticated;

grant select on public.profiles, public.wallets, public.market_stocks,
  public.market_news, public.positions, public.chat_messages, public.news_comments to authenticated;
grant select on public.market_stocks, public.market_news to anon;
grant select (id, nickname) on public.profiles to anon;
grant select (id, user_id, body, created_at) on public.chat_messages to anon;
grant select (id, news_id, body, created_at, user_id) on public.news_comments to anon, authenticated;
grant select on public.market_stocks, public.market_news to anon;
grant update (nickname) on public.profiles to authenticated;
grant insert on public.chat_messages to authenticated;
grant insert on public.news_comments to authenticated;
grant delete on public.chat_messages to authenticated;
grant select on public.admin_users, public.balance_adjustments to authenticated;
grant usage, select on all sequences in schema public to authenticated;

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
  v_percent numeric(6, 2);
  stock_row record;
begin
  select daily_target_date
  into v_last_date
  from public.market_state
  where id = true;

  if v_last_date is distinct from v_day then
    for stock_row in
      select ticker, base_price
      from public.market_stocks
    loop
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

drop policy if exists user_task_rewards_read_self on public.user_task_rewards;
create policy user_task_rewards_read_self on public.user_task_rewards
for select to authenticated
using (user_id = auth.uid());

grant select on public.user_task_rewards to authenticated;

drop policy if exists referrals_read_self on public.referrals;
create policy referrals_read_self on public.referrals
for select to authenticated
using (referrer_id = auth.uid() or referred_id = auth.uid());

grant select on public.referrals to authenticated;

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
  if p_task = 'install_app' then
    if p_reward <> 500 then raise exception 'Invalid reward'; end if;
    if exists (
      select 1 from public.user_task_rewards
      where user_id = auth.uid() and task = p_task
    ) then raise exception 'Reward already claimed'; end if;
    insert into public.user_task_rewards (user_id, task, reward)
    values (auth.uid(), p_task, p_reward);
  elsif p_task = 'hourly' then
    if p_reward <> 100 then raise exception 'Invalid reward'; end if;
    if exists (
      select 1 from public.user_task_rewards
      where user_id = auth.uid() and task = p_task
        and claimed_at > now() - interval '1 hour'
    ) then raise exception 'Hourly reward not available yet'; end if;
    insert into public.user_task_rewards (user_id, task, reward)
    values (auth.uid(), p_task, p_reward)
    on conflict (user_id, task) do update
    set reward = public.user_task_rewards.reward + excluded.reward,
        claimed_at = now();
  else
    raise exception 'Unknown task';
  end if;

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

create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'market-advance') then
    perform cron.schedule(
      'market-advance',
      '* * * * *',
      'select public.advance_market()'
    );
  end if;
  if not exists (select 1 from cron.job where jobname = 'daily-trader-winner') then
    perform cron.schedule(
      'daily-trader-winner',
      '0 18 * * *',
      'select public.publish_daily_trader_winner()'
    );
  end if;
end;
$$;

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
  trade_cost numeric(14, 2);
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
  if trade_cost > current_balance then
    raise exception 'Insufficient balance';
  end if;

  update public.wallets
  set balance = balance - trade_cost
  where user_id = auth.uid()
  returning balance into current_balance;

  insert into public.positions (user_id, ticker, side, qty, entry_price)
  values (auth.uid(), p_ticker, p_side, p_qty, current_price);

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
  collateral numeric(14, 2);
  profit_loss numeric(14, 2);
  credit numeric(14, 2);
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

  select balance into current_balance
  from public.wallets
  where user_id = auth.uid()
  for update;

  collateral := round(current_position.entry_price * current_position.qty, 2);
  profit_loss := round(
    (case when current_position.side = 'long'
      then current_price - current_position.entry_price
      else current_position.entry_price - current_price
    end) * current_position.qty,
    2
  );
  credit := greatest(0, collateral + profit_loss);

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
    profit_loss
  );

  delete from public.positions where id = current_position.id;

  return current_balance;
end;
$$;

revoke all on function public.close_position(uuid) from public, anon;
grant execute on function public.close_position(uuid) to authenticated;

create or replace function public.admin_list_users()
returns table (
  user_id uuid,
  email text,
  nickname text,
  balance numeric
)
language plpgsql
stable
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
  select u.id, u.email::text, p.nickname, w.balance
  from auth.users u
  join public.profiles p on p.id = u.id
  join public.wallets w on w.user_id = u.id
  order by p.created_at desc;
end;
$$;

revoke all on function public.admin_list_users() from public, anon;
grant execute on function public.admin_list_users() to authenticated;

create or replace function public.admin_adjust_balance(
  p_user_id uuid,
  p_delta numeric,
  p_reason text
)
returns numeric
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_balance numeric(14, 2);
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  if p_delta is null or p_delta = 0 or abs(p_delta) > 1000000 then
    raise exception 'Invalid adjustment amount';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 200 then
    raise exception 'A reason is required';
  end if;

  update public.wallets
  set balance = balance + round(p_delta, 2)
  where user_id = p_user_id
    and balance + round(p_delta, 2) >= 0
  returning balance into new_balance;

  if new_balance is null then
    raise exception 'User not found or adjustment would make balance negative';
  end if;

  insert into public.balance_adjustments (admin_id, target_user_id, delta, reason)
  values (auth.uid(), p_user_id, round(p_delta, 2), btrim(p_reason));

  return new_balance;
end;
$$;

revoke all on function public.admin_adjust_balance(uuid, numeric, text) from public, anon;
grant execute on function public.admin_adjust_balance(uuid, numeric, text) to authenticated;
