-- Quem já estava no avião pode reentrar depois do fim (recarregar a página e ver o resultado).
-- Só quem é novo continua barrado com 'ended'.
create or replace function public.av_join(p_code text, p_name text, p_token text)
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

  select * into x from av.participants where plane_code = v_code and token_hash = av.h(p_token);
  if found then
    update av.participants set name = v_name, last_seen = now() where id = x.id;
  else
    if p.phase = 'ended' then return jsonb_build_object('error','ended'); end if;
    if p.phase = 'playing' then return jsonb_build_object('error','started'); end if;
    perform av.sweep_lobby(v_code);
    select count(*) into v_count from av.participants where plane_code = v_code;
    if v_count >= p.num_participants then return jsonb_build_object('error','full'); end if;
    insert into av.participants (plane_code, token_hash, name) values (v_code, av.h(p_token), v_name) returning * into x;
  end if;

  return jsonb_build_object('pid', x.id, 'role', x.role, 'now', av.ms(now()),
    'meta', jsonb_build_object('numParticipants', p.num_participants, 'timerMinutes', p.timer_minutes, 'planeVersion', p.version));
end $$;

