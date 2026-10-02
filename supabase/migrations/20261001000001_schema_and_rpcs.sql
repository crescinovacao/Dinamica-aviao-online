-- Dinâmica do Avião Online — backend Supabase
-- Modelo de segurança: as tabelas ficam no schema privado "av" (não exposto pela API).
-- O navegador só chama as funções públicas av_* (SECURITY DEFINER), que aplicam todas as regras
-- no servidor: papéis, matriz de comunicação, gabarito, tempo, limites e identidade por token.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists av;
revoke all on schema av from public, anon, authenticated;

-- ───────────────────────── tabelas
create table av.plane_versions (
  version int primary key check (version between 1 and 5),
  answer  text  not null,
  sheets  jsonb not null            -- papel → lista de símbolos da folha
);

create table av.config (key text primary key, value text not null);

create table av.sessions (
  code        text primary key,
  fac_hash    bytea not null,       -- sha256 do token de quem facilita
  num_planes  int   not null check (num_planes between 1 and 5),
  ip_hash     bytea,
  created_at  timestamptz not null default now()
);

create table av.planes (
  code            text primary key,
  session_code    text not null references av.sessions(code) on delete cascade,
  idx             int  not null,
  version         int  not null references av.plane_versions(version),
  num_participants int not null check (num_participants between 6 and 11),
  timer_minutes   int  not null check (timer_minutes between 0 and 90),
  phase           text not null default 'lobby' check (phase in ('lobby','playing','ended')),
  timer_end       timestamptz,
  revealed        boolean not null default false,
  answer          text,
  correct         boolean,
  answered_by     text,
  created_at      timestamptz not null default now(),
  unique (session_code, idx)
);

create table av.participants (
  id           uuid primary key default gen_random_uuid(),
  plane_code   text  not null references av.planes(code) on delete cascade,
  token_hash   bytea not null,
  name         text  not null check (char_length(name) between 1 and 30),
  role         text  check (role in ('A','B1','B2','C','D','E','F','G','H','I','J')),
  seat         text  check (seat in ('A','B1','B2','C','D','E','F','G','H','I','J')),   -- assento escolhido no lobby
  symbols      text[],
  connected_at timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  unique (plane_code, token_hash)
);
create unique index participants_role_uq on av.participants (plane_code, role) where role is not null;

create table av.messages (
  id         bigint generated always as identity primary key,
  plane_code text not null references av.planes(code) on delete cascade,
  from_role  text not null,
  from_name  text not null,
  to_role    text not null,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create unique index participants_seat_uq on av.participants (plane_code, seat) where seat is not null;

create index messages_plane_id_idx on av.messages (plane_code, id);
create index planes_session_idx on av.planes (session_code);
create index sessions_created_idx on av.sessions (created_at);

alter table av.plane_versions enable row level security;
alter table av.config         enable row level security;
alter table av.sessions       enable row level security;
alter table av.planes         enable row level security;
alter table av.participants   enable row level security;
alter table av.messages       enable row level security;
revoke all on all tables in schema av from public, anon, authenticated;

-- ───────────────────────── funções internas (schema av, nunca expostas)
create function av.h(t text) returns bytea
language sql immutable set search_path = '' as
$$ select extensions.digest(convert_to(t, 'utf8'), 'sha256') $$;

create function av.ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as
$$ select (extract(epoch from t) * 1000)::bigint $$;

create function av.rand_code() returns text
language plpgsql volatile set search_path = '' as $$
declare
  ch constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(4);
  r text := '';
  i int;
begin
  for i in 0..3 loop r := r || substr(ch, (get_byte(b, i) % 32) + 1, 1); end loop;
  return r;
end $$;

-- Matriz de comunicação: A ↔ B1/B2; B1/B2 ↔ A, entre si e todos de C em diante; C+ ↔ B1/B2
create function av.can_send(f text, t text) returns boolean
language sql immutable set search_path = '' as $$
  select case
    when f = 'A'          then t in ('B1','B2')
    when f in ('B1','B2') then t <> f and t in ('A','B1','B2','C','D','E','F','G','H','I','J')
    else t in ('B1','B2')
  end
$$;

-- Plano da pessoa que facilita (precisa do token certo; sessões valem 24 h)
create function av.fac_plane(p_token text, p_code text) returns av.planes
language sql stable set search_path = '' as $$
  select p.* from av.planes p
  join av.sessions s on s.code = p.session_code
  where p.code = upper(coalesce(p_code, ''))
    and s.fac_hash = av.h(p_token)
    and p.created_at > now() - interval '24 hours'
$$;

-- Encerra sozinho quando o tempo acaba (a regra mora no servidor, não no relógio de alguém)
create function av.tick(p_code text) returns void
language sql volatile set search_path = '' as $$
  update av.planes set phase = 'ended'
  where code = p_code and phase = 'playing' and timer_end is not null and timer_end <= now()
$$;

-- No lobby, quem fechou a aba sem avisar libera a vaga depois de 90 s sem sinal
create function av.sweep_lobby(p_code text) returns void
language sql volatile set search_path = '' as $$
  delete from av.participants x
  using av.planes p
  where p.code = x.plane_code and p.code = p_code and p.phase = 'lobby'
    and x.role is null and x.last_seen < now() - interval '90 seconds'
$$;

-- Varredura de uma sessão inteira (usada pelo painel da facilitação)
create function av.sweep_session(p_session text) returns void
language plpgsql volatile set search_path = '' as $$
declare r record;
begin
  for r in select code from av.planes where session_code = p_session loop
    perform av.tick(r.code);
    perform av.sweep_lobby(r.code);
  end loop;
end $$;

create function av.parts_json(p_code text) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_object_agg(x.id, jsonb_build_object(
    'name', x.name, 'role', x.role, 'seat', x.seat,
    'online', x.last_seen > now() - interval '30 seconds',
    'connectedAt', av.ms(x.connected_at))), '{}'::jsonb)
  from av.participants x where x.plane_code = p_code
$$;

revoke all on all functions in schema av from public, anon, authenticated;

-- ───────────────────────── API pública (chamada pelo navegador)

-- Cria a sessão e os aviões
create function public.av_create_session(p_token text, p_num_planes int, p_num_part int, p_timer int, p_passcode text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pc text; v_ip bytea; v_code text; v_pcode text; v_tries int := 0;
  v_planes jsonb := '[]'::jsonb; i int; v_ver int;
  v_hdr text := nullif(current_setting('request.headers', true), '');
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then return jsonb_build_object('error','bad_token'); end if;
  if p_num_planes is null or p_num_part is null or p_timer is null
     or p_num_planes not between 1 and 5 or p_num_part not between 6 and 11 or p_timer not between 0 and 90 then
    return jsonb_build_object('error','bad_params');
  end if;

  select value into v_pc from av.config where key = 'fac_passcode_hash';
  if v_pc is not null then
    if p_passcode is null or p_passcode = '' then return jsonb_build_object('error','passcode_required'); end if;
    if encode(av.h(p_passcode), 'hex') <> v_pc then return jsonb_build_object('error','passcode_invalid'); end if;
  end if;

  v_ip := av.h(coalesce(split_part(coalesce(v_hdr::jsonb ->> 'x-forwarded-for', 'unknown'), ',', 1), 'unknown'));
  if (select count(*) from av.sessions where ip_hash = v_ip and created_at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('error','rate_limited');
  end if;
  if (select count(*) from av.sessions where created_at > now() - interval '1 hour') >= 300 then
    return jsonb_build_object('error','busy');
  end if;

  loop
    v_code := av.rand_code();
    begin
      insert into av.sessions (code, fac_hash, num_planes, ip_hash) values (v_code, av.h(p_token), p_num_planes, v_ip);
      exit;
    exception when unique_violation then
      v_tries := v_tries + 1; if v_tries > 30 then raise; end if;
    end;
  end loop;

  for i in 0 .. p_num_planes - 1 loop
    v_ver := (i % 5) + 1; v_tries := 0;
    loop
      v_pcode := av.rand_code();
      begin
        insert into av.planes (code, session_code, idx, version, num_participants, timer_minutes)
        values (v_pcode, v_code, i, v_ver, p_num_part, p_timer);
        exit;
      exception when unique_violation then
        v_tries := v_tries + 1; if v_tries > 30 then raise; end if;
      end;
    end loop;
    v_planes := v_planes || jsonb_build_object('code', v_pcode, 'version', v_ver, 'numParticipants', p_num_part, 'timerMinutes', p_timer);
  end loop;

  return jsonb_build_object('sessionCode', v_code, 'planes', v_planes, 'now', av.ms(now()));
end $$;

-- Recupera a sessão (só quem criou, com o mesmo token)
create function public.av_fac_load(p_token text, p_session text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s av.sessions%rowtype;
begin
  select * into s from av.sessions where code = upper(coalesce(p_session, ''));
  if not found then return jsonb_build_object('error','not_found'); end if;
  if s.fac_hash is distinct from av.h(p_token) then return jsonb_build_object('error','forbidden'); end if;
  if s.created_at < now() - interval '24 hours' then return jsonb_build_object('error','expired'); end if;
  return jsonb_build_object('sessionCode', s.code, 'now', av.ms(now()), 'planes',
    (select coalesce(jsonb_agg(jsonb_build_object('code', p.code, 'version', p.version,
        'numParticipants', p.num_participants, 'timerMinutes', p.timer_minutes) order by p.idx), '[]'::jsonb)
     from av.planes p where p.session_code = s.code));
end $$;

-- Painel da facilitação: todos os aviões da sessão numa só chamada
create function public.av_fac_poll(p_token text, p_session text, p_since jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare s av.sessions%rowtype; v jsonb;
begin
  select * into s from av.sessions where code = upper(coalesce(p_session, ''));
  if not found then return jsonb_build_object('error','not_found'); end if;
  if s.fac_hash is distinct from av.h(p_token) then return jsonb_build_object('error','forbidden'); end if;

  perform av.sweep_session(s.code);

  select coalesce(jsonb_object_agg(p.code, jsonb_build_object(
      'state', jsonb_build_object(
        'phase', p.phase,
        'timerEnd', case when p.timer_end is null then null else av.ms(p.timer_end) end,
        'revealed', p.revealed, 'answer', p.answer, 'correct', p.correct, 'answeredBy', p.answered_by),
      'key', pv.answer,
      'parts', av.parts_json(p.code),
      'msgs', coalesce((
        select jsonb_agg(jsonb_build_object('_key', m.id, 'fromRole', m.from_role, 'fromName', m.from_name,
                 'toRole', m.to_role, 'text', m.body, 'ts', av.ms(m.created_at)) order by m.id)
        from (select * from av.messages mm
              where mm.plane_code = p.code
                and mm.id > coalesce(nullif(p_since ->> p.code, '')::bigint, 0)
              order by mm.id limit 300) m), '[]'::jsonb)
    )), '{}'::jsonb)
  into v
  from av.planes p join av.plane_versions pv on pv.version = p.version
  where p.session_code = s.code;

  return jsonb_build_object('planes', v, 'now', av.ms(now()));
end $$;

-- Entrar numa sala (ou reconectar com o mesmo token)
create function public.av_join(p_code text, p_name text, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(coalesce(p_code, ''));
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
  p av.planes%rowtype; x av.participants%rowtype; v_count int;
begin
  if p_token is null or char_length(p_token) not between 32 and 128 then return jsonb_build_object('error','bad_token'); end if;
  if v_code !~ '^[A-Z0-9]{4}$' then return jsonb_build_object('error','not_found'); end if;
  if char_length(v_name) not between 1 and 30 then return jsonb_build_object('error','bad_name'); end if;

  select * into p from av.planes where code = v_code for update;
  if not found then return jsonb_build_object('error','not_found'); end if;
  if p.created_at < now() - interval '24 hours' then return jsonb_build_object('error','expired'); end if;
  perform av.tick(v_code);
  select * into p from av.planes where code = v_code;
  if p.phase = 'ended' then return jsonb_build_object('error','ended'); end if;

  select * into x from av.participants where plane_code = v_code and token_hash = av.h(p_token);
  if found then
    update av.participants set name = v_name, last_seen = now() where id = x.id;
  else
    if p.phase = 'playing' then return jsonb_build_object('error','started'); end if;
    perform av.sweep_lobby(v_code);
    select count(*) into v_count from av.participants where plane_code = v_code;
    if v_count >= p.num_participants then return jsonb_build_object('error','full'); end if;
    insert into av.participants (plane_code, token_hash, name) values (v_code, av.h(p_token), v_name) returning * into x;
  end if;

  return jsonb_build_object('pid', x.id, 'role', x.role, 'now', av.ms(now()),
    'meta', jsonb_build_object('numParticipants', p.num_participants, 'timerMinutes', p.timer_minutes, 'planeVersion', p.version));
end $$;

-- Saiu da sala: no lobby libera a vaga; depois do início só fica "offline"
create function public.av_leave(p_code text, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(coalesce(p_code, '')); v_phase text;
begin
  select phase into v_phase from av.planes where code = v_code;
  if v_phase = 'lobby' then
    delete from av.participants where plane_code = v_code and token_hash = av.h(p_token) and role is null;
  elsif v_phase is not null then
    update av.participants set last_seen = now() - interval '1 hour' where plane_code = v_code and token_hash = av.h(p_token);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Atualização da pessoa participante (também serve de sinal de presença)
create function public.av_poll(p_code text, p_token text, p_since bigint default 0)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(coalesce(p_code, ''));
  x av.participants%rowtype; p av.planes%rowtype; pv av.plane_versions%rowtype;
  v_state jsonb; v_msgs jsonb;
begin
  select * into x from av.participants where plane_code = v_code and token_hash = av.h(p_token);
  if not found then return jsonb_build_object('error','not_member'); end if;
  update av.participants set last_seen = now() where id = x.id;

  perform av.tick(v_code);
  perform av.sweep_lobby(v_code);
  select * into p from av.planes where code = v_code;
  select * into pv from av.plane_versions where version = p.version;

  v_state := jsonb_build_object(
    'phase', p.phase,
    'timerEnd', case when p.timer_end is null then null else av.ms(p.timer_end) end,
    'revealed', p.revealed,
    'answered', p.answer is not null);
  if p.revealed then   -- a resposta só chega ao navegador depois que a facilitação libera
    v_state := v_state || jsonb_build_object('answer', p.answer, 'correct', p.correct,
                 'answeredBy', p.answered_by, 'key', pv.answer);
  end if;

  if x.role is null then
    v_msgs := '[]'::jsonb;
  else
    select coalesce(jsonb_agg(jsonb_build_object('_key', m.id, 'fromRole', m.from_role, 'fromName', m.from_name,
             'toRole', m.to_role, 'text', m.body, 'ts', av.ms(m.created_at)) order by m.id), '[]'::jsonb)
    into v_msgs
    from (select * from av.messages mm
          where mm.plane_code = v_code and mm.id > coalesce(p_since, 0)
            and (mm.to_role = x.role or mm.from_role = x.role)
          order by mm.id limit 300) m;
  end if;

  return jsonb_build_object(
    'now', av.ms(now()),
    'meta', jsonb_build_object('numParticipants', p.num_participants, 'timerMinutes', p.timer_minutes, 'planeVersion', p.version),
    'state', v_state,
    'parts', av.parts_json(v_code),
    'me', jsonb_build_object('pid', x.id, 'role', x.role, 'seat', x.seat, 'symbols', to_jsonb(x.symbols)),
    'msgs', v_msgs);
end $$;

-- Iniciar: quem entrou primeiro tem vaga; os papéis são sorteados no servidor
create function public.av_start(p_token text, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p av.planes%rowtype; pv av.plane_versions%rowtype;
  v_ids uuid[]; v_pool text[]; v_used text[]; v_free text[]; v_seat text; v_role text; v_k int := 0; i int; n int;
  v_all constant text[] := array['A','B1','B2','C','D','E','F','G','H','I','J'];
begin
  select * into p from av.fac_plane(p_token, p_code);
  if p.code is null then return jsonb_build_object('error','forbidden'); end if;
  select * into p from av.planes where code = p.code for update;
  perform av.tick(p.code);
  perform av.sweep_lobby(p.code);
  select * into p from av.planes where code = p.code;
  if p.phase <> 'lobby' then return jsonb_build_object('error','bad_phase'); end if;

  select array_agg(id order by connected_at, id) into v_ids from (
    select id, connected_at from av.participants where plane_code = p.code
    order by connected_at, id limit p.num_participants) t;
  n := coalesce(array_length(v_ids, 1), 0);
  if n < 6 then return jsonb_build_object('error','too_few', 'min', 6); end if;

  -- papéis em jogo: os n primeiros. Quem escolheu um assento desses fica nele; o resto é sorteado.
  v_pool := v_all[1:n];
  select coalesce(array_agg(seat), '{}'::text[]) into v_used
    from av.participants where id = any (v_ids) and seat = any (v_pool);
  select coalesce(array_agg(r order by random()), '{}'::text[]) into v_free
    from unnest(v_pool) r where not (r = any (v_used));
  select * into pv from av.plane_versions where version = p.version;

  for i in 1 .. n loop
    select seat into v_seat from av.participants where id = v_ids[i];
    if v_seat is not null and v_seat = any (v_pool) then
      v_role := v_seat;
    else
      v_k := v_k + 1; v_role := v_free[v_k];
    end if;
    update av.participants set role = v_role,
      symbols = array(select jsonb_array_elements_text(pv.sheets -> v_role))
    where id = v_ids[i];
  end loop;

  update av.planes set phase = 'playing', revealed = false, answer = null, correct = null, answered_by = null,
    timer_end = case when p.timer_minutes > 0 then now() + make_interval(mins => p.timer_minutes) else null end
  where code = p.code;
  return jsonb_build_object('ok', true);
end $$;

create function public.av_end(p_token text, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p av.planes%rowtype;
begin
  select * into p from av.fac_plane(p_token, p_code);
  if p.code is null then return jsonb_build_object('error','forbidden'); end if;
  update av.planes set phase = 'ended' where code = p.code and phase = 'playing';
  return jsonb_build_object('ok', true);
end $$;

create function public.av_reveal(p_token text, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p av.planes%rowtype;
begin
  select * into p from av.fac_plane(p_token, p_code);
  if p.code is null then return jsonb_build_object('error','forbidden'); end if;
  update av.planes set revealed = true where code = p.code and phase = 'ended';
  return jsonb_build_object('ok', true);
end $$;

-- Escolher (ou liberar, com null) o assento no lobby
create function public.av_pick_seat(p_code text, p_token text, p_role text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(coalesce(p_code, ''));
  x av.participants%rowtype; p av.planes%rowtype;
  v_all constant text[] := array['A','B1','B2','C','D','E','F','G','H','I','J'];
begin
  select * into p from av.planes where code = v_code for update;
  if not found then return jsonb_build_object('error','not_found'); end if;
  select * into x from av.participants where plane_code = v_code and token_hash = av.h(p_token);
  if not found then return jsonb_build_object('error','not_member'); end if;
  if p.phase <> 'lobby' then return jsonb_build_object('error','not_lobby'); end if;
  if p_role is null or p_role = '' then
    update av.participants set seat = null where id = x.id;
    return jsonb_build_object('ok', true);
  end if;
  if not (p_role = any (v_all[1:p.num_participants])) then return jsonb_build_object('error','bad_seat'); end if;
  if exists (select 1 from av.participants where plane_code = v_code and seat = p_role and id <> x.id) then
    return jsonb_build_object('error','seat_taken');
  end if;
  update av.participants set seat = p_role where id = x.id;
  return jsonb_build_object('ok', true);
end $$;

-- Mensagem: só durante a rodada, dentro da matriz, com limite de ritmo
create function public.av_send(p_token text, p_code text, p_to text, p_text text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(coalesce(p_code, ''));
  v_text text := btrim(coalesce(p_text, ''));
  x av.participants%rowtype; p av.planes%rowtype; v_id bigint; v_ts timestamptz;
begin
  select * into x from av.participants where plane_code = v_code and token_hash = av.h(p_token);
  if not found then return jsonb_build_object('error','not_member'); end if;
  perform av.tick(v_code);
  select * into p from av.planes where code = v_code;
  if p.phase <> 'playing' then return jsonb_build_object('error','not_playing'); end if;
  if x.role is null then return jsonb_build_object('error','no_role'); end if;
  if char_length(v_text) not between 1 and 500 then return jsonb_build_object('error','bad_text'); end if;
  if not av.can_send(x.role, coalesce(p_to, '')) then return jsonb_build_object('error','not_allowed'); end if;
  if not exists (select 1 from av.participants where plane_code = v_code and role = p_to) then
    return jsonb_build_object('error','not_allowed');
  end if;
  if (select count(*) from av.messages where plane_code = v_code and from_role = x.role
        and created_at > now() - interval '10 seconds') >= 10 then
    return jsonb_build_object('error','rate_limited');
  end if;
  if (select count(*) from av.messages where plane_code = v_code) >= 3000 then
    return jsonb_build_object('error','limit');
  end if;
  insert into av.messages (plane_code, from_role, from_name, to_role, body)
  values (v_code, x.role, x.name, p_to, v_text) returning id, created_at into v_id, v_ts;
  return jsonb_build_object('ok', true, 'id', v_id, 'ts', av.ms(v_ts));
end $$;

-- Resposta final: só a Pessoa A, uma vez, durante a rodada. O servidor confere o gabarito.
create function public.av_answer(p_token text, p_code text, p_symbol text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_code text := upper(coalesce(p_code, ''));
  x av.participants%rowtype; p av.planes%rowtype; pv av.plane_versions%rowtype;
begin
  select * into x from av.participants where plane_code = v_code and token_hash = av.h(p_token);
  if not found then return jsonb_build_object('error','not_member'); end if;
  select * into p from av.planes where code = v_code for update;
  perform av.tick(v_code);
  select * into p from av.planes where code = v_code;
  if p.phase <> 'playing' or p.answer is not null then return jsonb_build_object('error','not_playing'); end if;
  if x.role is distinct from 'A' then return jsonb_build_object('error','not_allowed'); end if;
  if p_symbol is null or p_symbol not in ('amp','fem','pro','sor','pct','mas') then return jsonb_build_object('error','bad_symbol'); end if;
  select * into pv from av.plane_versions where version = p.version;
  update av.planes set answer = p_symbol, correct = (p_symbol = pv.answer), answered_by = 'A', phase = 'ended'
  where code = v_code;
  return jsonb_build_object('ok', true);
end $$;

-- Permissões: só a API pública, só para o papel "anon" (chave publicável do site)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'av\_%' loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to anon', f.sig);
  end loop;
end $$;

-- Limpeza: apaga sessões com mais de 3 dias (pg_cron, de hora em hora)
create extension if not exists pg_cron with schema pg_catalog;
create function av.cleanup() returns void
language sql volatile set search_path = '' as $$
  delete from av.sessions where created_at < now() - interval '3 days'
$$;
revoke all on function av.cleanup() from public, anon, authenticated;
select cron.schedule('av-cleanup', '17 * * * *', 'select av.cleanup()');
