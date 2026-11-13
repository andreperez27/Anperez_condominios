-- ============================================================================
-- MIGRATION 001 — FASE 0: ENUMS
-- ============================================================================
-- Todos os enums do modelo. Criados numa migration própria porque os demais
-- scripts referenciam os tipos e o Postgres exige que existam antes.
--
-- Documento de referência: docs\MODELO_DADOS.md
--
-- Idempotente: `create type` não é idempotente no Postgres, então usamos o
-- bloco DO com verificação (o padrão do Postgres para "criar se não existir").
-- ============================================================================

-- Papel de negócio do usuário NO CONDOMÍNIO.
-- NOTA: papel NÃO é um role do Postgres. Todos os autenticados são
-- `authenticated`; a separação acontece dentro de views e funções, sempre
-- testando o papel contra o condomínio da própria linha.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'papel_membro') then
        create type public.papel_membro as enum (
            'auditor',          -- hoje: você
            'leitor',           -- hoje: Sr. Adilson
            'sindico',          -- futuro
            'conselho_fiscal',  -- futuro
            'admin_plataforma'  -- futuro
        );
    end if;
end
$$;

-- Fonte contábil de um documento.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'fonte_contabil') then
        create type public.fonte_contabil as enum (
            'extrato',
            'balancete',
            'caixa_local',
            'planilha_resumo'
        );
    end if;
end
$$;

-- Status de uma competência POR FONTE.
-- 'sem_fonte' = a competência existe mas não há documento daquela fonte.
-- Aparece como pendência no painel; nunca como "mês vazio".
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_fonte') then
        create type public.status_fonte as enum (
            'sem_fonte',
            'importado',
            'conciliado',
            'fechado'
        );
    end if;
end
$$;

-- Estado da classificação de um lançamento.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_classificacao') then
        create type public.status_classificacao as enum (
            'sugerida',   -- vinda do mapeamento automático
            'confirmada'   -- decidida por humano
        );
    end if;
end
$$;

-- De onde veio a classificação.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'origem_classificacao') then
        create type public.origem_classificacao as enum (
            'conta',
            'palavra_chave',
            'manual',
            'importacao',
            'planilha'
        );
    end if;
end
$$;

-- Natureza da rubrica.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'natureza_rubrica') then
        create type public.natureza_rubrica as enum (
            'receita',
            'despesa',
            'transferencia',
            'patrimonio'
        );
    end if;
end
$$;

-- Natureza do fundo/recurso.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'natureza_fundo') then
        create type public.natureza_fundo as enum (
            'principal',            -- CONTA CONDOMÍNIO
            'fundo',                -- BENFEITORIAS, RESERVA, PINTURA, SALÃO
            'aplicacao_financeira'  -- APLICAÇÃO BANCO EXEMPLO
        );
    end if;
end
$$;

-- Estado da transferência interna.
-- NOTA: não existe 'nao_aplicavel'. Um lançamento que não é transferência
-- interna simplesmente não tem grupo_transferencia_id — não tem linha em
-- transferencias_internas. "Não é transferência" e "transferência ainda não
-- revisada" são coisas diferentes; só a segunda precisa de estado.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_transferencia') then
        create type public.status_transferencia as enum (
            'sugerida',
            'confirmada',
            'rejeitada'
        );
    end if;
end
$$;

-- Estado da duplicata candidata.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_duplicata') then
        create type public.status_duplicata as enum (
            'pendente',
            'duplicata_confirmada',
            'nao_duplicata'
        );
    end if;
end
$$;

-- Critério que casou o par de duplicatas.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'criterio_duplicata') then
        create type public.criterio_duplicata as enum (
            'mesma_tupla_no_arquivo',
            'mesmo_valor_data_conta',
            'mesmo_documento',
            'mesmo_historico_normalizado'
        );
    end if;
end
$$;

-- Sentido do movimento. O valor é sempre POSITIVO; o sinal vem do tipo.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'tipo_movimento') then
        create type public.tipo_movimento as enum (
            'credito',
            'debito'
        );
    end if;
end
$$;

-- Estado do lançamento. Lançamento nunca é apagado.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_lancamento') then
        create type public.status_lancamento as enum (
            'ativo',
            'estornado',
            'cancelado'
        );
    end if;
end
$$;

-- Estado da linha na área de conferência.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_staging') then
        create type public.status_staging as enum (
            'novo',
            'duplicado_candidato',
            'conflito',
            'erro_parse',
            'rejeitado',
            'aprovado'
        );
    end if;
end
$$;

-- Estado da execução de importação.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_importacao') then
        create type public.status_importacao as enum (
            'em_andamento',
            'concluida',
            'erro',
            'cancelada'
        );
    end if;
end
$$;

-- Estado da fonte (arquivo) de importação.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_fonte_arquivo') then
        create type public.status_fonte_arquivo as enum (
            'detectado',
            'importado',
            'ignorado_duplicata',
            'erro'
        );
    end if;
end
$$;

-- Estado da conciliação extrato x balancete (por fundo e competência).
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_conciliacao') then
        create type public.status_conciliacao as enum (
            'sem_fonte',
            'conciliado',
            'divergente',
            'nao_aplicavel'
        );
    end if;
end
$$;

-- Tipos de pendência/achado. A pendência é o núcleo da auditoria.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'tipo_pendencia') then
        create type public.tipo_pendencia as enum (
            'classificacao',
            'classificacao_sugerida',
            'duplicata',
            'divergencia',
            'conferencia_importacao',
            'documento_faltante',
            'lancamento_orfao',
            'competencia_sem_fonte',
            'arquivo_ilegivel',
            'senha_necessaria',
            'validacao_manual',
            'unidade_desconhecida'
        );
    end if;
end
$$;

-- De onde veio a pendência.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'origem_pendencia') then
        create type public.origem_pendencia as enum (
            'extrato',
            'balancete',
            'caixa_local',
            'planilha_resumo',
            'importacao',
            'manual',
            'sistema'
        );
    end if;
end
$$;

-- Gravidade da pendência.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'gravidade_pendencia') then
        create type public.gravidade_pendencia as enum (
            'baixa',
            'media',
            'alta',
            'critica'
        );
    end if;
end
$$;

-- Estado da pendência.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_pendencia') then
        create type public.status_pendencia as enum (
            'aberta',
            'em_analise',
            'resolvida',
            'ignorada'
        );
    end if;
end
$$;

-- Tipo do documento.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'tipo_documento') then
        create type public.tipo_documento as enum (
            'nota_fiscal',
            'boleto',
            'comprovante',
            'contrato',
            'ata',
            'anexo',
            'outro'
        );
    end if;
end
$$;

-- Estado da vinculação do anexo ao lançamento.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_anexo') then
        create type public.status_anexo as enum (
            'sugerido',
            'vinculado',
            'rejeitado'
        );
    end if;
end
$$;

-- Taxonomia de origem dos aliases de rubrica.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'fonte_alias') then
        create type public.fonte_alias as enum (
            'extrato',
            'planilha_resumo',
            'balancete',
            'manual'
        );
    end if;
end
$$;

-- Forma da operação registrada no acesso_log.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'operacao_acesso') then
        create type public.operacao_acesso as enum (
            'select',
            'insert',
            'update',
            'delete',
            'rpc',
            'storage',
            'anexo'
        );
    end if;
end
$$;

-- Estado da contestação/comentário (síndico e conselho fiscal).
do $$
begin
    if not exists (select 1 from pg_type where typname = 'status_contestacao') then
        create type public.status_contestacao as enum (
            'aberta',
            'em_analise',
            'acolhida',
            'rejeitada'
        );
    end if;
end
$$;

-- Tipo da contestação.
do $$
begin
    if not exists (select 1 from pg_type where typname = 'tipo_contestacao') then
        create type public.tipo_contestacao as enum (
            'comentario',
            'contestacao'
        );
    end if;
end
$$;
