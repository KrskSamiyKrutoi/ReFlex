-- Рефлекс v1.1: бэкенд для Supabase. Выполни целиком в SQL Editor.
-- Потом: Project Settings → API → скопируй Project URL и anon key в CFG в index.html.
create extension if not exists pgcrypto with schema extensions;
create table rx_players(id uuid primary key default gen_random_uuid(),
  name text unique not null check (name ~ '^[A-Za-zА-Яа-яЁё0-9_]{3,16}$'),
  pass text not null, token uuid not null default gen_random_uuid(), xp int not null default 0);
create table rx_scores(player uuid references rx_players(id) on delete cascade, game text, val numeric not null, primary key(player,game));
alter table rx_players enable row level security;  -- политик нет: прямой доступ к таблицам закрыт,
alter table rx_scores enable row level security;   -- работа только через функции ниже

create function rx_register(p_name text,p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare r rx_players;
begin
  if length(p_pass)<6 then raise exception 'Пароль: минимум 6 символов'; end if;
  if p_name !~ '^[A-Za-zА-Яа-яЁё0-9_]{3,16}$' then raise exception 'Ник: 3–16 символов, буквы/цифры/_'; end if;
  if exists(select 1 from rx_players where lower(name)=lower(p_name)) then raise exception 'Ник уже занят'; end if;
  insert into rx_players(name,pass) values(p_name,crypt(p_pass,gen_salt('bf'))) returning * into r;
  return json_build_object('token',r.token,'name',r.name);
end $$;

create function rx_login(p_name text,p_pass text) returns json language plpgsql security definer set search_path = public, extensions as $$
declare r rx_players;
begin
  select * into r from rx_players where lower(name)=lower(p_name) and pass=crypt(p_pass,pass);
  if not found then raise exception 'Неверный ник или пароль'; end if;
  return json_build_object('token',r.token,'name',r.name);
end $$;

create function rx_submit(p_token uuid,p_game text,p_val numeric,p_xp int) returns void language plpgsql security definer set search_path = public, extensions as $$
declare pid uuid; old numeric; low boolean := p_game in('light','target','stroop','arrow','nums');
begin
  select id into pid from rx_players where token=p_token;
  if pid is null then raise exception 'Нет сессии, войди заново'; end if;
  if p_val<=0 or p_xp<0 or p_xp>400 then raise exception 'Некорректные данные'; end if;
  -- защита от явно нереальных результатов
  if (p_game='light' and p_val<100) or (p_game='target' and p_val<150) or (p_game='stroop' and p_val<250)
     or (p_game='arrow' and p_val<120) or (p_game='nums' and p_val<6) or (p_game in('odd','mole','gonogo') and p_val>80) then return; end if;
  update rx_players set xp=xp+p_xp where id=pid;
  select val into old from rx_scores where player=pid and game=p_game;
  if old is null then insert into rx_scores values(pid,p_game,p_val);
  elsif (low and p_val<old) or (not low and p_val>old) then update rx_scores set val=p_val where player=pid and game=p_game; end if;
end $$;

create function rx_top(p_game text) returns table(pname text,pval numeric) language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_game='xp' then
    return query select p.name,p.xp::numeric from rx_players p order by p.xp desc limit 20;
  else
    return query select p.name,s.val from rx_scores s join rx_players p on p.id=s.player where s.game=p_game
      order by case when p_game in('light','target','stroop','arrow','nums') then s.val else -s.val end limit 20;
  end if;
end $$;

grant execute on function rx_register(text,text), rx_login(text,text), rx_submit(uuid,text,numeric,int), rx_top(text) to anon, authenticated;
