# Backend (Supabase)

O site é um único `index.html`. Os dados ficam no Supabase, num schema privado (`av`).
O navegador só chama as funções `av_*` (via `/rest/v1/rpc/...`) com a chave **publicável**.
Papéis, matriz de comunicação, gabarito, tempo e limites são aplicados no servidor.

## Recriar em outro projeto/organização
1. Crie um projeto Supabase novo.
2. Rode, em ordem, no SQL Editor: `migrations/20261001000001_schema_and_rpcs.sql` e `migrations/20261001000002_seed_plane_versions.sql`.
3. Em `index.html`, troque `SUPABASE_URL` e `SUPABASE_KEY` (Project Settings → API → chave publicável).

## Senha de facilitação (opcional)
Por padrão qualquer pessoa com o link cria sessões (há limite por IP e global). Para exigir senha:

    insert into av.config (key, value)
    values ('fac_passcode_hash', encode(extensions.digest('SUA_SENHA', 'sha256'), 'hex'))
    on conflict (key) do update set value = excluded.value;

Para remover: `delete from av.config where key = 'fac_passcode_hash';`

## Limpeza
`pg_cron` apaga sessões com mais de 3 dias (job `av-cleanup`).
