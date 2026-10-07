-- Pausar a dinâmica: a facilitação congela o avião e a tela de quem joga fica com aviso e blur até liberar.
-- O servidor guarda o instante da pausa (paused_at). Ao retomar, o fim do tempo é empurrado pela duração da pausa.
-- Enquanto pausado: o relógio não encerra o avião e mensagens e resposta final são recusadas com 'paused'.

alter table av.planes add column if not exists paused_at timestamptz;

-- Encerra sozinho quando o tempo acaba (a regra mora no servidor, não no relógio de alguém)
create or replace function av.tick(p_code text) returns void
language sql volatile set search_path = '' as $$
  update av.planes set phase = 'ended'
  where code = p_code and phase = 'playing' and paused_at is null and timer_end is not null and timer_end <= now()
$$;

-- Painel da facilitação: todos os aviões da sessão numa só chamada
create or replace function public.av_fac_poll(p_token text, p_session text, p_since jsonb default '{}'::jsonb)
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
        'paused', p.paused_at is not null,
        'pausedAt', case when p.paused_at is null then null else av.ms(p.paused_at) end,
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

-- Atualização da pessoa participante (também serve de sinal de presença)
create or replace function public.av_poll(p_code text, p_token text, p_since bigint default 0)
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
    'paused', p.paused_at is not null,
    'pausedAt', case when p.paused_at is null then null else av.ms(p.paused_at) end,
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
create or replace function public.av_start(p_token text, p_code text)
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

  update av.planes set phase = 'playing', paused_at = null, revealed = false, answer = null, correct = null, answered_by = null,
    timer_end = case when p.timer_minutes > 0 then now() + make_interval(mins => p.timer_minutes) else null end
  where code = p.code;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.av_end(p_token text, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p av.planes%rowtype;
begin
  select * into p from av.fac_plane(p_token, p_code);
  if p.code is null then return jsonb_build_object('error','forbidden'); end if;
  update av.planes set phase = 'ended', paused_at = null where code = p.code and phase = 'playing';
  return jsonb_build_object('ok', true);
end $$;

-- Mensagem: só durante a rodada, dentro da matriz, com limite de ritmo
create or replace function public.av_send(p_token text, p_code text, p_to text, p_text text)
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
  if p.paused_at is not null then return jsonb_build_object('error','paused'); end if;
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
create or replace function public.av_answer(p_token text, p_code text, p_symbol text)
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
  if p.paused_at is not null then return jsonb_build_object('error','paused'); end if;
  if x.role is distinct from 'A' then return jsonb_build_object('error','not_allowed'); end if;
  if p_symbol is null or p_symbol not in ('amp','fem','pro','sor','pct','mas') then return jsonb_build_object('error','bad_symbol'); end if;
  select * into pv from av.plane_versions where version = p.version;
  update av.planes set answer = p_symbol, correct = (p_symbol = pv.answer), answered_by = 'A', phase = 'ended'
  where code = v_code;
  return jsonb_build_object('ok', true);
end $$;


-- Pausar (p_paused = true) ou retomar (false). Repetir o mesmo pedido não muda nada.
create or replace function public.av_pause(p_token text, p_code text, p_paused boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p av.planes%rowtype;
begin
  select * into p from av.fac_plane(p_token, p_code);
  if p.code is null then return jsonb_build_object('error','forbidden'); end if;
  select * into p from av.planes where code = p.code for update;
  perform av.tick(p.code);
  select * into p from av.planes where code = p.code;
  if p.phase <> 'playing' then return jsonb_build_object('error','bad_phase'); end if;
  if coalesce(p_paused, false) then
    if p.paused_at is null then update av.planes set paused_at = now() where code = p.code; end if;
  elsif p.paused_at is not null then
    update av.planes set
      timer_end = case when timer_end is null then null else timer_end + (now() - paused_at) end,
      paused_at = null
    where code = p.code;
  end if;
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
