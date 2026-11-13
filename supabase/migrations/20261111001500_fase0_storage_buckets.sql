-- ============================================================================
-- MIGRATION 015 — FASE 0: BUCKET DE ANEXOS E POLÍTICAS DE STORAGE
-- ============================================================================
-- Os comprovantes escaneados do caixa local (páginas 2+ dos PDFs) ficam no
-- bucket privado do Supabase Storage.
--
-- REGRA DE ACESSO (decisão do usuário):
--   O anexo é BLOQUEADO POR PADRÃO para o leitor. O auditor libera ANEXO POR
--   ANEXO (`anexos.liberado_para_leitor`), e a liberação é auditada.
--
--   Um comprovante, combinado com o extrato, permite reconstruir a operação
--   de uma unidade específica — mesmo sem nome de morador no documento. Por
--   isso o padrão é bloqueio, e a liberação é granular.
--
-- Documento de referência: docs\SEGURANCA_RLS.md §10
-- ============================================================================

-- ----------------------------------------------------------------------------
-- BUCKET
-- ----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'anexos',
    'anexos',
    false,                       -- NUNCA público
    26214400,                    -- 25 MB
    array['application/pdf','image/png','image/jpeg','image/webp']
)
on conflict (id) do update
    set public = false,
        file_size_limit = excluded.file_size_limit,
        allowed_mime_types = excluded.allowed_mime_types;

-- O comentário do bucket vai por COMMENT ON, que o Postgres não tem para
-- storage.buckets (a tabela é do schema storage, gerida pelo Supabase).
-- A descrição fica aqui, no código, e o bucket é privado por construção
-- (public = false).

-- ----------------------------------------------------------------------------
-- POLÍTICA DE LEITURA
-- ----------------------------------------------------------------------------
-- Três condições, todas necessárias:
--   1. o objeto está no bucket 'anexos';
--   2. o primeiro segmento do caminho é o id de um condomínio do usuário;
--   3. fn_anexo_acessivel() confirma: papel com acesso pleno OU anexo
--      individualmente liberado pelo auditor.
drop policy if exists anexos_leitura on storage.objects;
create policy anexos_leitura on storage.objects
    for select to authenticated
    using (
        bucket_id = 'anexos'
        and (storage.foldername(name))[1]
            in (select condominio_id::text from public.fn_condominios_do_usuario())
        and public.fn_anexo_acessivel(name)
    );

-- ----------------------------------------------------------------------------
-- POLÍTICA DE ESCRITA
-- ----------------------------------------------------------------------------
-- Só o auditor escreve no bucket, e só no próprio condomínio. O importador
-- (app_importador) tem seu próprio caminho, com credencial própria.
drop policy if exists anexos_escrita on storage.objects;
create policy anexos_escrita on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'anexos'
        and (storage.foldername(name))[1]
            in (select condominio_id::text from public.fn_condominios_do_usuario())
        and exists (
            select 1
            from public.fn_papeis_do_usuario(
                ((storage.foldername(name))[1])::uuid
            ) p
            where p = 'auditor'
        )
    );

drop policy if exists anexos_atualizacao on storage.objects;
create policy anexos_atualizacao on storage.objects
    for update to authenticated
    using (
        bucket_id = 'anexos'
        and (storage.foldername(name))[1]
            in (select condominio_id::text from public.fn_condominios_do_usuario())
    );

drop policy if exists anexos_remocao on storage.objects;
create policy anexos_remocao on storage.objects
    for delete to authenticated
    using (
        bucket_id = 'anexos'
        and (storage.foldername(name))[1]
            in (select condominio_id::text from public.fn_condominios_do_usuario())
        and exists (
            select 1
            from public.fn_papeis_do_usuario(
                ((storage.foldername(name))[1])::uuid
            ) p
            where p = 'auditor'
        )
    );

-- ----------------------------------------------------------------------------
-- REVOGAÇÃO DE PRIVILÉGIOS DE STORAGE
-- ----------------------------------------------------------------------------
-- O padrão do Supabase dá acesso amplo ao storage para authenticated. O
-- bucket é privado e as policies filtram; o revoke garante que nenhuma
-- operação fora das policies escape.
revoke all on storage.objects from public, anon, authenticated;
grant select, insert, update, delete on storage.objects to authenticated;
