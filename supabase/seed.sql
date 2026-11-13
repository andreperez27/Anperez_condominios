-- ===========================================================================
-- SEED - CARGA DE CONFIGURACAO (DADOS FICTICIOS)
-- ===========================================================================
-- Este arquivo e VERSIONADO no Git. Por isso so pode conter DADO DE
-- CONFIGURACAO - nunca dado real do condominio.
--
-- O que entra: condominio (ficticio), fundos, rubricas, aliases das tres
-- taxonomias, catalogo de contas de origem, numeros de unidade, politica de
-- visibilidade e retencao do acesso_log.
--
-- O que NAO entra: lancamentos, valores, saldos, inadimplencia, consumo
-- por unidade, qualquer dado que identifique um morador.
--
-- Os dados REAIS entram por IMPORTACAO (staging -> aprovacao -> lancamentos),
-- nunca por seed.
--
-- Documento de referencia: docs\MODELO_DADOS.md
-- ===========================================================================

-- --------------------------------------------------------------------------
-- CONDOMINIO (ficticio)
-- --------------------------------------------------------------------------
insert into public.condominios (id, nome, cnpj, endereco, cidade, uf)
values (
    '11111111-1111-1111-1111-111111111111',
    'Condominio Residencial Exemplo',
    '11.222.333/0001-44',
    'Rua de Teste, 123',
    'Santo Andre',
    'SP'
)
on conflict (id) do nothing;

-- --------------------------------------------------------------------------
-- FUNDOS
-- --------------------------------------------------------------------------
-- O prefixo do codigo de conta identifica o fundo. ATENCAO: '1', '10', '15' e
-- '19' comecam igual - o prefixo e heuristica de FALLBACK; a verdade e o
-- mapeamento explicito em `contas_origem`.
insert into public.fundos (id, condominio_id, codigo, nome, natureza, prefixo_conta)
values
    ('21111111-1111-1111-1111-111111111101', '11111111-1111-1111-1111-111111111111', 'CC', 'CONTA CONDOMINIO', 'principal', '1'),
    ('21111111-1111-1111-1111-111111111102', '11111111-1111-1111-1111-111111111111', 'BENF', 'BENFEITORIAS', 'fundo', '2'),
    ('21111111-1111-1111-1111-111111111103', '11111111-1111-1111-1111-111111111111', 'FR', 'FUNDO DE RESERVA', 'fundo', '3'),
    ('21111111-1111-1111-1111-111111111104', '11111111-1111-1111-1111-111111111111', 'PINT', 'MANUTENCAO DE PINTURA', 'fundo', '15'),
    ('21111111-1111-1111-1111-111111111105', '11111111-1111-1111-1111-111111111111', 'SAL', 'SALAO DE FESTAS', 'fundo', '19'),
    ('21111111-1111-1111-1111-111111111106', '11111111-1111-1111-1111-111111111111', 'PA', 'PORTA AUTOMATICA', 'fundo', '10'),
    ('21111111-1111-1111-1111-111111111107', '11111111-1111-1111-1111-111111111111', 'APL', 'APLICACAO FINANCEIRA', 'aplicacao_financeira', NULL)
on conflict (id) do nothing;

-- --------------------------------------------------------------------------
-- RUBRICAS (taxonomia canonica)
-- --------------------------------------------------------------------------
insert into public.rubricas (id, condominio_id, codigo, nome, natureza, fundo_padrao, unidade_de_medida)
values
    ('31111111-1111-1111-1111-111111111101', '11111111-1111-1111-1111-111111111111', 'COTA_CONDOMINIAL', 'Cotas condominees', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111102', '11111111-1111-1111-1111-111111111111', 'AGUA', 'Consumo de agua', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111103', '11111111-1111-1111-1111-111111111111', 'GAS', 'Consumo de gas', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111104', '11111111-1111-1111-1111-111111111111', 'FUNDO_RESERVA', 'Cotas do fundo de reserva', 'receita', '21111111-1111-1111-1111-111111111103', 'R$'),
    ('31111111-1111-1111-1111-111111111105', '11111111-1111-1111-1111-111111111111', 'BENFEITORIAS', 'Cotas de benfeitorias', 'receita', '21111111-1111-1111-1111-111111111102', 'R$'),
    ('31111111-1111-1111-1111-111111111106', '11111111-1111-1111-1111-111111111111', 'SALAO_FESTAS', 'Cotas do salao de festas', 'receita', '21111111-1111-1111-1111-111111111105', 'R$'),
    ('31111111-1111-1111-1111-111111111107', '11111111-1111-1111-1111-111111111111', 'MANUT_PINTURA', 'Cotas de manutencao de pintura', 'receita', '21111111-1111-1111-1111-111111111104', 'R$'),
    ('31111111-1111-1111-1111-111111111108', '11111111-1111-1111-1111-111111111111', 'MULTAS', 'Multas', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111109', '11111111-1111-1111-1111-111111111111', 'ACORDOS', 'Receita de parcelas em acordo', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111110', '11111111-1111-1111-1111-111111111111', 'CORRECAO_MONETARIA', 'Correcao monetaria', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'RENDIMENTO_APLICACAO', 'Rendimento da aplicacao', 'receita', '21111111-1111-1111-1111-111111111107', 'R$'),
    ('31111111-1111-1111-1111-111111111112', '11111111-1111-1111-1111-111111111111', 'TRANSFERENCIA_CONTAS', 'Transferencia entre contas', 'transferencia', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111113', '11111111-1111-1111-1111-111111111111', 'TAXA_ADMINISTRACAO', 'Taxa de administracao', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111114', '11111111-1111-1111-1111-111111111111', 'RECEITAS_EVENTUAIS', 'Receitas eventuais', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111115', '11111111-1111-1111-1111-111111111111', 'ATRASO_COTA', 'Cotas em atraso', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111116', '11111111-1111-1111-1111-111111111111', 'ANTECIPACOES', 'Antecipacoes', 'receita', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111117', '11111111-1111-1111-1111-111111111111', 'DESPESA_PESSOAL', 'Despesas com pessoal', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111118', '11111111-1111-1111-1111-111111111111', 'CONCESSAO_SERVICOS', 'Concessao de servicos', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111119', '11111111-1111-1111-1111-111111111111', 'CONSERVACAO_PISCINA', 'Conservacao de piscina', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111120', '11111111-1111-1111-1111-111111111111', 'CONSERVE_PORTA', 'Conservacao da porta automatica', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111121', '11111111-1111-1111-1111-111111111111', 'CONSERVE_ELEVADOR', 'Conservacao de elevador', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111122', '11111111-1111-1111-1111-111111111111', 'MATERIAL_LIMPEZA', 'Material de limpeza', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111123', '11111111-1111-1111-1111-111111111111', 'ENERGIA_AREA_COMUM', 'Energia das areas comuns', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111124', '11111111-1111-1111-1111-111111111111', 'CAIXA_LOCAL', 'Caixa local', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111125', '11111111-1111-1111-1111-111111111111', 'DIVERSOS', 'Diversos', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111126', '11111111-1111-1111-1111-111111111111', 'TRIBUTOS_FOLHA', 'Tributos folha e fornecedores', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111127', '11111111-1111-1111-1111-111111111111', 'DESPESA_AGUA', 'Compra de agua', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111128', '11111111-1111-1111-1111-111111111111', 'DESPESA_GAS', 'Compra de gas', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111129', '11111111-1111-1111-1111-111111111111', 'SERVICOS_HIDRAULICOS', 'Servicos hidraulicos', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111130', '11111111-1111-1111-1111-111111111111', 'MANUT_COMUM', 'Manutencao de areas comuns', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$'),
    ('31111111-1111-1111-1111-111111111131', '11111111-1111-1111-1111-111111111111', 'LEITURA_CONSUMOS', 'Leitura de consumos', 'despesa', '21111111-1111-1111-1111-111111111101', 'R$')
on conflict (id) do nothing;

-- --------------------------------------------------------------------------
-- ALIASES - a ponte entre as tres taxonomias
-- --------------------------------------------------------------------------
-- `contexto` desambigua o caso 'mesmo alias, sentidos diferentes':
-- 'CONSUMO DE AGUA' no extrato e receita (1052) e despesa (1642).
insert into public.rubrica_aliases (rubrica_id, fonte, alias, contexto)
values
    ('31111111-1111-1111-1111-111111111101', 'extrato', 'COTAS CONDOMINIAIS', NULL),
    ('31111111-1111-1111-1111-111111111102', 'extrato', 'CONSUMO DE AGUA', 'receita:1052'),
    ('31111111-1111-1111-1111-111111111103', 'extrato', 'CONSUMO DE GAS', 'receita:1010'),
    ('31111111-1111-1111-1111-111111111104', 'extrato', 'COTAS DO MES FUNDO DE RESERVA', NULL),
    ('31111111-1111-1111-1111-111111111105', 'extrato', 'COTAS DO MES BENFEITORIAS', NULL),
    ('31111111-1111-1111-1111-111111111106', 'extrato', 'COTAS DO MES SALAO DE FESTAS', NULL),
    ('31111111-1111-1111-1111-111111111107', 'extrato', 'COTAS DO MES MANUT. PINTURA', NULL),
    ('31111111-1111-1111-1111-111111111108', 'extrato', 'MULTAS', NULL),
    ('31111111-1111-1111-1111-111111111108', 'extrato', 'MULTAS ARRECADADAS', NULL),
    ('31111111-1111-1111-1111-111111111109', 'extrato', 'RECEITA PARCELAS ACORDO', NULL),
    ('31111111-1111-1111-1111-111111111110', 'extrato', 'CORRECAO MONETARIA', NULL),
    ('31111111-1111-1111-1111-111111111111', 'extrato', 'REND.APLIC.FINANC', NULL),
    ('31111111-1111-1111-1111-111111111112', 'extrato', 'TRANSF. REGUL. ENTRE CONTAS', NULL),
    ('31111111-1111-1111-1111-111111111112', 'extrato', 'TRANSF.REGUL. ENTRE CONTAS', NULL),
    ('31111111-1111-1111-1111-111111111112', 'extrato', 'TRANSFERENCIAS', NULL),
    ('31111111-1111-1111-1111-111111111113', 'extrato', 'TAXA DE ADMINISTRACAO', NULL),
    ('31111111-1111-1111-1111-111111111114', 'extrato', 'RECEITAS EVENTUAIS', NULL),
    ('31111111-1111-1111-1111-111111111115', 'extrato', 'CONDOMINOS EM ATRASO', NULL),
    ('31111111-1111-1111-1111-111111111116', 'extrato', 'ANTECIPACOES', NULL),
    ('31111111-1111-1111-1111-111111111116', 'extrato', 'COTAS RECEB.P/ANTECIPACAO', NULL),
    ('31111111-1111-1111-1111-111111111116', 'extrato', 'COTAS RECEB P/ANTECIPACAO', NULL),
    ('31111111-1111-1111-1111-111111111117', 'extrato', 'DESPESA C/PESSOAL-TERCEIRIZADO', NULL),
    ('31111111-1111-1111-1111-111111111118', 'extrato', 'SERVICOS ELETRICOS', NULL),
    ('31111111-1111-1111-1111-111111111119', 'extrato', 'CONSERVACAO DE PISCINA', NULL),
    ('31111111-1111-1111-1111-111111111120', 'extrato', 'CONSERVACAO PORTA AUTOMATICA', NULL),
    ('31111111-1111-1111-1111-111111111121', 'extrato', 'CONSERVACAO DE ELEVADOR', NULL),
    ('31111111-1111-1111-1111-111111111122', 'extrato', 'MATERIAL DE LIMPEZA', NULL),
    ('31111111-1111-1111-1111-111111111123', 'extrato', 'CONSUMO DE LUZ', NULL),
    ('31111111-1111-1111-1111-111111111124', 'extrato', 'CAIXA LOCAL', NULL),
    ('31111111-1111-1111-1111-111111111125', 'extrato', 'DIVERSOS', NULL),
    ('31111111-1111-1111-1111-111111111126', 'extrato', 'TRIBUTOS FOLHA E FORNECEDORES', NULL),
    ('31111111-1111-1111-1111-111111111127', 'extrato', 'CONSUMO DE AGUA', 'despesa:1642'),
    ('31111111-1111-1111-1111-111111111128', 'extrato', 'CONSUMO DE GAS', 'despesa:1643'),
    ('31111111-1111-1111-1111-111111111129', 'extrato', 'SERVICOS HIDRAULICOS', NULL),
    ('31111111-1111-1111-1111-111111111130', 'extrato', 'MANUT AREAS COMUNS', NULL),
    ('31111111-1111-1111-1111-111111111131', 'extrato', 'LEITURA DE CONSUMOS', NULL),
    ('31111111-1111-1111-1111-111111111101', 'planilha_resumo', 'CONTA CONDOMINIO', NULL),
    ('31111111-1111-1111-1111-111111111104', 'planilha_resumo', 'FUNDO DE RESERVA', NULL),
    ('31111111-1111-1111-1111-111111111105', 'planilha_resumo', 'BENFEITORIAS', NULL),
    ('31111111-1111-1111-1111-111111111106', 'planilha_resumo', 'SALAO DE FESTAS', NULL),
    ('31111111-1111-1111-1111-111111111107', 'planilha_resumo', 'Mant. PINTURA', NULL),
    ('31111111-1111-1111-1111-111111111107', 'planilha_resumo', 'MANUT. PINTURA', NULL),
    ('31111111-1111-1111-1111-111111111111', 'planilha_resumo', 'APLICACAO BANCO EXEMPLO', NULL),
    ('31111111-1111-1111-1111-111111111111', 'planilha_resumo', 'APLICA??O BANCO EXEMPLO', NULL),
    ('31111111-1111-1111-1111-111111111101', 'balancete', 'CONTA CONDOMINIO', NULL),
    ('31111111-1111-1111-1111-111111111105', 'balancete', 'CONTA BENFEITORIAS', NULL),
    ('31111111-1111-1111-1111-111111111104', 'balancete', 'FUNDO DE RESERVA', NULL),
    ('31111111-1111-1111-1111-111111111107', 'balancete', 'MANUTENCAO DE PINTURA', NULL),
    ('31111111-1111-1111-1111-111111111106', 'balancete', 'SALAO DE FESTAS', NULL),
    ('31111111-1111-1111-1111-111111111117', 'balancete', 'DESPESAS COM PESSOAL', NULL),
    ('31111111-1111-1111-1111-111111111117', 'balancete', 'ENCARGOS SOCIAIS', NULL),
    ('31111111-1111-1111-1111-111111111118', 'balancete', 'CONCESSAO DE SERVICOS', NULL),
    ('31111111-1111-1111-1111-111111111118', 'balancete', 'SERVICO TERCERIZADO', NULL),
    ('31111111-1111-1111-1111-111111111118', 'balancete', 'MATERIAIS P/CONSERV. E MANUT.', NULL),
    ('31111111-1111-1111-1111-111111111124', 'balancete', 'CAIXA LOCAL', NULL)
on conflict do nothing;

-- --------------------------------------------------------------------------
-- CONTAS DE ORIGEM - o codigo contabil da administradora
-- --------------------------------------------------------------------------
-- As 20 contas mais usadas. As demais (94 no total) entram por importacao.
-- status = 'sugerida': nenhuma foi confirmada por humano ainda.
insert into public.contas_origem (condominio_id, codigo, descricao_origem, fundo_id, rubrica_id, status, origem_sugestao)
values
    ('11111111-1111-1111-1111-111111111111', '1001', 'CONDOMINOS EM ATRASO', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111115', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1002', 'COTAS CONDOMINIAIS', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111101', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1010', 'CONSUMO DE GAS', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111103', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1023', 'CORRECAO MONETARIA', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111110', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1026', 'REND.APLIC.FINANC', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111111', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1041', 'TRANSF. REGUL. ENTRE CONTAS', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111112', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1052', 'CONSUMO DE AGUA', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111102', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1098', 'MULTAS', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111108', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1102', 'TAXA DE ADMINISTRACAO', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111113', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '15002', 'COTAS DO MES MANUT. PINTURA', '21111111-1111-1111-1111-111111111104', '31111111-1111-1111-1111-111111111107', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1561', 'CONSERVACAO DE PISCINA', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111119', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1641', 'CONSUMO DE LUZ', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111123', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1642', 'CONSUMO DE AGUA', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111127', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1643', 'CONSUMO DE GAS', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111128', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1667', 'DESPESA C/PESSOAL-TERCEIRIZADO', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111117', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '1723', 'CAIXA LOCAL', '21111111-1111-1111-1111-111111111101', '31111111-1111-1111-1111-111111111124', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '19002', 'COTAS DO MES SALAO DE FESTAS', '21111111-1111-1111-1111-111111111105', '31111111-1111-1111-1111-111111111106', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '2002', 'COTAS DO MES BENFEITORIAS', '21111111-1111-1111-1111-111111111102', '31111111-1111-1111-1111-111111111105', 'sugerida', 'mapa_contas.yaml'),
    ('11111111-1111-1111-1111-111111111111', '3002', 'COTAS DO MES FUNDO DE RESERVA', '21111111-1111-1111-1111-111111111103', '31111111-1111-1111-1111-111111111104', 'sugerida', 'mapa_contas.yaml')
on conflict (condominio_id, codigo) do nothing;

-- --------------------------------------------------------------------------
-- UNIDADES - 18 andares x 4 posicoes
-- --------------------------------------------------------------------------
insert into public.unidades (condominio_id, numero, andar, posicao)
select
    '11111111-1111-1111-1111-111111111111',
    (a * 10 + p)::text,
    a,
    p
from generate_series(1, 18) as a
cross join generate_series(1, 4) as p
on conflict (condominio_id, numero) do nothing;

-- --------------------------------------------------------------------------
-- ORDEM DE GRANULARIDADE
-- --------------------------------------------------------------------------
insert into public.granularidade_ordem (granularidade, rank)
values ('fundo', 1), ('rubrica', 2), ('unidade', 3)
on conflict (granularidade) do nothing;

-- --------------------------------------------------------------------------
-- POLITICA DE VISIBILIDADE
-- --------------------------------------------------------------------------
-- granularidade_max: ate onde o papel pode chegar.
-- limiar_minimo_unidades: suprime agregados apoiados em MENOS unidades que isso.
--   auditor: 0 (sem supressao - ja ve o nominal).
--   leitor:  5 (padrao decidido pelo usuario).
insert into public.config_visibilidade (
    condominio_id, papel, granularidade_max, limiar_minimo_unidades, bloqueia_unidade
)
values
    ('11111111-1111-1111-1111-111111111111', 'auditor',         'unidade', 0, false),
    ('11111111-1111-1111-1111-111111111111', 'leitor',          'fundo',   5, true),
    ('11111111-1111-1111-1111-111111111111', 'sindico',         'unidade', 1, false),
    ('11111111-1111-1111-1111-111111111111', 'conselho_fiscal', 'unidade', 1, false)
on conflict (condominio_id, papel) do nothing;

-- --------------------------------------------------------------------------
-- RETENCAO DO ACESSO_LOG - 12 meses (padrao)
-- --------------------------------------------------------------------------
insert into public.config_retencao_acesso (condominio_id, meses_retencao)
values ('11111111-1111-1111-1111-111111111111', 12)
on conflict (condominio_id) do nothing;

-- --------------------------------------------------------------------------
-- O seed NAO cria usuarios. Os usuarios existem em auth.users e chegam por
-- convite (tabela convites). O ambiente de teste cria os usuarios de teste
-- em supabase/tests/.
-- ============================================================================
