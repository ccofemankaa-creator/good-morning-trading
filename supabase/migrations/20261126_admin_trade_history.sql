begin;

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

alter table public.trade_history enable row level security;

drop policy if exists trade_history_read_admin on public.trade_history;
create policy trade_history_read_admin on public.trade_history
for select to authenticated using (public.is_admin());

grant select on public.trade_history to authenticated;

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

commit;
