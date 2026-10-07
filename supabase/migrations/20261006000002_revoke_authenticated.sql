-- Só o papel "anon" (chave publicável do site) chama a API da dinâmica. Não há login de usuário,
-- então o papel "authenticated" não precisa executar as funções av_*. A av_pause (nova) tinha herdado
-- esse acesso do padrão do Supabase; aqui ele é removido de todas, para ficar uniforme.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'av\_%' loop
    execute format('revoke all on function %s from authenticated', f.sig);
  end loop;
end $$;
