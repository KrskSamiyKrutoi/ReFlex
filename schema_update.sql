-- Рефлекс v1.10.4: облачное сохранение прогресса, коды переноса и промокоды.
-- Запусти в SQL Editor ОДИН раз, после schema.sql.
alter table rx_players add column if not exists save jsonb;
create table if not exists rx_transfer(code text primary key, data jsonb not null, expires timestamptz not null);
create table if not exists rx_promo(code text primary key, xp int not null default 0, max_uses int not null default 1, uses int not null default 0, active boolean not null default true);
create table if not exists rx_promo_used(player uuid references rx_players(id) on delete cascade, code text, primary key(player,code));
alter table rx_transfer enable row level security;
alter table rx_promo enable row level security;
alter table rx_promo_used enable row level security;

-- облачное сохранение: не даёт старому устройству затереть более свежий прогресс
create or replace function rx_save(p_token uuid,p_data jsonb,p_force boolean default false) returns json language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; old jsonb;
begin
  select id,save into pid,old from rx_players where token=p_token;
  if pid is null then raise exception 'Нет сессии, войди заново'; end if;
  if pg_column_size(p_data)>200000 then raise exception 'Слишком большой объём'; end if;
  if not p_force and old is not null and coalesce((old->>'plays')::int,0)>coalesce((p_data->>'plays')::int,0) then
    return json_build_object('conflict',true,'data',old);
  end if;
  update rx_players set save=p_data where id=pid;
  return json_build_object('ok',true);
end $$;

create or replace function rx_load(p_token uuid) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb;
begin
  select save into r from rx_players where token=p_token;
  return r;
end $$;

-- одноразовый код переноса прогресса (30 минут), аккаунт не нужен
create or replace function rx_code_make(p_data jsonb) returns text language plpgsql security definer set search_path = public, extensions as $$
declare c text;
begin
  if pg_column_size(p_data)>200000 then raise exception 'Слишком большой объём'; end if;
  delete from rx_transfer where expires<now();
  c:='RX-'||upper(substr(md5(random()::text||clock_timestamp()::text),1,4))||'-'||upper(substr(md5(random()::text||clock_timestamp()::text),1,4));
  insert into rx_transfer values(c,p_data,now()+interval '30 minutes');
  return c;
end $$;

-- ввод кода: перенос прогресса или промокод (для промокода нужен аккаунт)
create or replace function rx_code_use(p_code text,p_token uuid default null) returns json language plpgsql security definer set search_path = public, extensions as $$
declare c text:=upper(trim(p_code)); d jsonb; pr rx_promo; pid uuid;
begin
  delete from rx_transfer where code=c and expires>now() returning data into d;
  if d is not null then return json_build_object('type','save','data',d); end if;
  select * into pr from rx_promo where code=c and active and uses<max_uses;
  if not found then raise exception 'Код не найден или уже использован'; end if;
  select id into pid from rx_players where token=p_token;
  if pid is null then raise exception 'Для промокода войди в аккаунт'; end if;
  if exists(select 1 from rx_promo_used where player=pid and code=c) then raise exception 'Ты уже использовал этот код'; end if;
  insert into rx_promo_used values(pid,c);
  update rx_promo set uses=uses+1 where code=c;
  return json_build_object('type','promo','xp',pr.xp);
end $$;

grant execute on function rx_save(uuid,jsonb,boolean), rx_load(uuid), rx_code_make(jsonb), rx_code_use(text,uuid) to anon, authenticated;

-- Пример промокода (раскомментируй и запусти): код HELLO даёт 100 XP, можно использовать 50 раз
-- insert into rx_promo(code,xp,max_uses) values('HELLO',100,50);
