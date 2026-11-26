create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username text not null constraint profiles_username_length_check
    check (char_length(btrim(username)) between 2 and 24),
  nickname text not null check (char_length(btrim(nickname)) between 2 and 24),
  created_at timestamptz not null default now()
);

create table if not exists public.user_activity (
  user_id uuid primary key references auth.users (id) on delete cascade,
  last_seen_at timestamptz not null default now(),
  total_seconds bigint not null default 0 check (total_seconds >= 0),
  is_active boolean not null default false
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
  event_driven boolean not null default false,
  updated_at timestamptz not null default now()
);

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

revoke all on function public.keep_market_stock_within_price_band() from public, anon, authenticated;

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

alter table public.market_stocks
  add column if not exists event_driven boolean not null default false;

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
  start_price numeric(14, 2) not null check (start_price > 0),
  ramp_seconds integer not null default 3600 check (ramp_seconds > 0),
  manual_target boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.daily_market_targets
  add column if not exists start_price numeric(14, 2),
  add column if not exists ramp_seconds integer not null default 3600,
  add column if not exists manual_target boolean not null default false;

update public.daily_market_targets targets
set start_price = stocks.price
from public.market_stocks stocks
where targets.ticker = stocks.ticker
  and targets.start_price is null;

alter table public.daily_market_targets
  alter column start_price set not null;

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

create table if not exists public.positions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  ticker text not null references public.market_stocks (ticker),
  side text not null check (side in ('long', 'short')),
  qty integer not null check (qty > 0 and qty <= 100000),
  entry_price numeric(14, 2) not null check (entry_price > 0),
  opening_fee numeric(20, 2) not null default 0 check (opening_fee >= 0),
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
  place smallint not null check (place between 1 and 5),
  user_id uuid not null references auth.users (id),
  nickname text not null,
  score numeric(14, 2) not null,
  reward numeric(14, 2) not null check (reward >= 0),
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
  ('FYF', 'fyfik', 'Файфик', 70, 70),
  ('KAT', 'Kate', 'Kate', 110, 110),
  ('KRK', 'Krak', 'Krak', 10000000, 10000000),
  ('SGM', 'Sigma', 'Сигма', 20000000, 20000000),
  ('GASP', 'Gaspromt', 'Газпромт', 15000000, 15000000),
  ('DOLBAEB', 'DOLBAEB', 'Долбаёб', 60000000, 60000000)
on conflict (ticker) do nothing;

update public.market_stocks
set event_driven = true
where ticker in ('KRK', 'SGM', 'GASP', 'DOLBAEB');

alter table public.daily_market_liquidations enable row level security;

delete from public.news_templates;

insert into public.news_templates (ticker, direction, text)
values
  ('GDM', 'up', 'Проша подрос на 2 сантиметра — GDM пересмотрел стратегию, хотя связь с экономикой никто не нашёл'),
  ('GDM', 'up', 'Барселона объявила тренировку — персонаж GDM уже потратил выигрыш, которого ещё нет'),
  ('GDM', 'up', 'Кофейня открылась рядом — GDM обнаружил новый стратегический рынок'),
  ('GDM', 'up', 'Сборная Испании получила поддержку болельщиков — GDM включил оптимизм без проверки соперника'),
  ('GDM', 'down', 'Барселона проиграла тренировочный матч — болельщики проверяют прочность нервной системы'),
  ('GDM', 'down', 'Арабика подорожала — персонаж GDM снова обещал отказаться от кофе'),
  ('GDM', 'down', 'В Москве дождь сменился снегом — GDM пересмотрел и прогноз, и обувь'),
  ('GDM', 'down', 'Футбольный прогноз не сбылся — персонаж GDM назвал ставку пожертвованием букмекеру'),
  ('NFR', 'up', 'Новый трек короче очереди в поддержку — NFR взлетел'),
  ('NFR', 'up', 'Микрофон попал в чарт — инвесторы тоже включили бит'),
  ('NFR', 'up', 'Рэп-баттл выиграл микрофон, но оба трека в чарте'),
  ('NFR', 'down', 'Альбом перенесли на завтра — фанаты постарели на целый день'),
  ('NFR', 'down', 'Автотюн ушёл на техобслуживание — NFR просел'),
  ('NFR', 'down', 'Диджей поставил тишину на повтор — рынок не оценил эксперимент'),
  ('NFR', 'up', 'Трек включили даже соседи — NFR получил поддержку аудитории'),
  ('NFR', 'down', 'На репетиции забыли, кто ставит бит, — рынок взял паузу'),
  ('BLN', 'up', 'Во Вьетнаме солнце вышло на смену раньше начальника — BLN зеленеет'),
  ('BLN', 'up', 'Кофе со льдом распродали — рынок поверил в вечное лето'),
  ('BLN', 'up', 'Пальмы синхронно качнулись в такт — инвесторы заметили сигнал'),
  ('BLN', 'down', 'Дождь во Вьетнаме отменил фотосессию пальм — BLN покраснел'),
  ('BLN', 'down', 'Тайфун попросил отпуск и всё равно пришёл на рынок'),
  ('BLN', 'down', 'Зонт не прошёл техосмотр — прогноз по BLN испортился'),
  ('BLN', 'up', 'Пальма дала прогноз погоды без единой ошибки — BLN подрос'),
  ('BLN', 'down', 'Кокос опоздал на совещание — инвесторы назвали это тревожным сигналом'),
  ('CVK', 'up', 'Civic припарковался так красиво, что аналитики купили акции'),
  ('CVK', 'up', 'В Civic нашли ещё одно место под стакан — CVK в плюсе'),
  ('CVK', 'up', 'Civic завёлся с первого раза — рынок назвал это чудом'),
  ('CVK', 'down', 'Робот-парковщик припарковался лучше человека — CVK задумался'),
  ('CVK', 'down', 'Навигатор предложил объезд на 400 километров — CVK просел'),
  ('CVK', 'down', 'Все искали ключи от Civic одновременно — инвесторы занервничали'),
  ('CVK', 'up', 'Навигатор сказал «поверните в небо» — CVK набирает высоту'),
  ('CVK', 'down', 'Civic долго искал парковку и пропустил открытие биржи'),
  ('FYF', 'up', 'Популярный стрим поднял интерес к fyfik'),
  ('FYF', 'up', 'Российские стримеры заметили FYF — акции растут'),
  ('FYF', 'up', 'Поддержка Kuertov укрепила котировки FYF'),
  ('FYF', 'down', 'Активность российских стримов снизилась — FYF просел'),
  ('FYF', 'down', 'Громкий стрим закончился, интерес к fyfik ослаб'),
  ('FYF', 'down', 'Стриминговое сообщество ушло в боковик — FYF снизился'),
  ('FYF', 'up', 'Стрим задержался, зато зрители дождались роста FYF'),
  ('FYF', 'down', 'Донат пришёл из будущего, а рынок пока не дождался'),
  ('KAT', 'up', 'Мандарины подешевели — Kate получил поддержку'),
  ('KAT', 'up', 'Погода в Москве улучшилась — KAT растёт'),
  ('KAT', 'up', 'Приближение учебной сессии увеличило интерес к Kate'),
  ('KAT', 'down', 'Цена мандаринов выросла — Kate просел'),
  ('KAT', 'down', 'Погода в Москве ухудшилась — котировки KAT снизились'),
  ('KAT', 'down', 'Учебная сессия подошла ближе — инвесторы стали осторожнее'),
  ('KAT', 'up', 'Мандарины пришли без косточек — рынок увидел знак'),
  ('KAT', 'down', 'Прогноз обещал солнце, но забыл уточнить какое')
on conflict do nothing;

insert into public.market_state (id) values (true) on conflict (id) do nothing;
insert into public.daily_market_liquidations (market_day)
values ((now() at time zone 'Europe/Moscow')::date)
on conflict (market_day) do nothing;

create index if not exists market_news_created_at_idx on public.market_news (created_at desc);
create index if not exists chat_messages_created_at_idx on public.chat_messages (created_at desc);
create index if not exists news_comments_news_id_created_at_idx
  on public.news_comments (news_id, created_at);
create index if not exists positions_user_id_idx on public.positions (user_id);

alter table public.profiles enable row level security;
alter table public.admin_users enable row level security;
alter table public.user_activity enable row level security;
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

create or replace function public.record_user_activity(p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;
  if p_is_active is null then
    raise exception 'Activity state is required';
  end if;

  insert into public.user_activity as current_activity (
    user_id, last_seen_at, total_seconds, is_active
  )
  values (v_user_id, v_now, 0, p_is_active)
  on conflict (user_id) do update
  set total_seconds = current_activity.total_seconds + case
        when current_activity.is_active
          and v_now >= current_activity.last_seen_at
          and v_now - current_activity.last_seen_at <= interval '90 seconds'
          then floor(extract(epoch from (v_now - current_activity.last_seen_at)))::bigint
        else 0
      end,
      last_seen_at = v_now,
      is_active = p_is_active;
end;
$$;

revoke all on function public.record_user_activity(boolean) from public, anon;
grant execute on function public.record_user_activity(boolean) to authenticated;

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

drop policy if exists user_activity_read_admin on public.user_activity;
create policy user_activity_read_admin on public.user_activity
for select to authenticated using (public.is_admin());

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
grant select on public.user_activity to authenticated;
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
  v_last_news timestamptz;
  v_current_price numeric(14, 2);
  v_target_price numeric(14, 2);
  v_target_direction integer;
  v_target_magnitude numeric(14, 2);
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

create or replace function public.admin_trade_counts()
returns table (
  user_id uuid,
  closed_trades bigint,
  open_positions bigint,
  total_trades bigint
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
  with closed_trade_counts as (
    select history.user_id, count(*)::bigint as closed_count
    from public.trade_history history
    group by history.user_id
  ),
  open_position_counts as (
    select pos.user_id, count(*)::bigint as open_count
    from public.positions pos
    group by pos.user_id
  )
  select profiles.id,
         coalesce(closed.closed_count, 0),
         coalesce(opened.open_count, 0),
         coalesce(closed.closed_count, 0) + coalesce(opened.open_count, 0)
  from public.profiles profiles
  left join closed_trade_counts closed on closed.user_id = profiles.id
  left join open_position_counts opened on opened.user_id = profiles.id
  order by profiles.created_at desc;
end;
$$;

revoke all on function public.admin_trade_counts() from public, anon;
grant execute on function public.admin_trade_counts() to authenticated;

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
