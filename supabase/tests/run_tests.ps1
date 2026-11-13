#!/usr/bin/env pwsh
# ============================================================================
# RODA A BATERIA COMPLETA DE TESTES DE SEGURANCA
# ============================================================================
# Uso:  pwsh -File supabase\tests\run_tests.ps1
#
# Requer o ambiente local no ar (supabase start) e o bootstrap ja executado
# (supabase\bootstrap\reset_local.ps1).
#
# Qualquer falha de seguranca FAZ O BUILD FALHAR (exit code 1).
# ============================================================================

$ErrorActionPreference = 'Stop'

$Raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Raiz

$Container = if ($env:SUPABASE_DB_CONTAINER) {
    $env:SUPABASE_DB_CONTAINER
} else {
    'supabase_db_anperez_condominios'
}

# Baterias pgTAP (dependem de 00_preparacao, que cria os usuarios de teste).
$Testes = @(
    '00_preparacao.test.sql',
    '01_leitor_tabela_detalhe.test.sql',
    '02_granularidade_limiar.test.sql',
    '03_isolamento_condominios.test.sql',
    '04_papeis_importador_anexos.test.sql',
    '06_matriz_views.test.sql',
    '07_matriz_funcoes.test.sql'
)

# Verificacoes AUTOCONTIDAS (SQL puro, sem pgtap, sem usuario, sem dado).
# O teste de drift roda no LOCAL e no REMOTO sem adaptation: ele le a
# lista permitida do proprio banco (public.config_grants_permitidos).
$TestesAutocontidos = @(
    '05_drift_grants.test.sql'
)

function Invoke-Psql {
    param([string]$Sql, [switch]$NaoFalhar, [string]$Usuario = 'postgres')

    $ErrorActionPreference = 'Continue'

    # `.ToString()` em cada item: o PowerShell embrulha a saida de stderr do
    # psql em ErrorRecord, e a formatacao padrao ("NativeCommandError")
    # polui a saida com a palavra "ERROR" mesmo quando o teste passou.
    $saida = $Sql | docker exec -i $Container psql -U $Usuario -d postgres -q -v ON_ERROR_STOP=1 2>&1 |
              ForEach-Object { $_.ToString() }
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($codigo -ne 0 -and -not $NaoFalhar) {
        $saida | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "psql falhou (exit $codigo)"
    }
    return $saida
}

# Envia um ARQUIVO SQL ao psql sem passar pelo pipe do PowerShell.
#
# Por que nao usar o pipe: o PS 5.1 escreve texto no pipe na codificacao do
# console (ANSI) e o Get-Content sem -Encoding le como ANSI tambem. O
# resultado: todo acento dos arquivos virava "?" no banco. Isso nao quebrava
# nenhuma logica (eram comentarios), mas quebrou a verificacao de
# idempotencia, que compara as definicoes das funcoes (comentarios inclusos)
# antes e depois de reaplicar as migrations.
#
# Aqui o arquivo vai por `docker cp` (bytes integros) e o psql roda com -f.
function Invoke-PsqlArquivo {
    param([string]$Caminho, [switch]$NaoFalhar, [string]$Usuario = 'postgres')

    $ErrorActionPreference = 'Continue'

    $nome = Split-Path $Caminho -Leaf
    docker cp $Caminho ("$Container`:/tmp/$nome") | Out-Null

    $saida = docker exec $Container psql -U $Usuario -d postgres -q -v ON_ERROR_STOP=1 -f "/tmp/$nome" 2>&1 |
              ForEach-Object { $_.ToString() }
    $codigo = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($codigo -ne 0 -and -not $NaoFalhar) {
        $saida | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "psql falhou no arquivo $nome (exit $codigo)"
    }
    return $saida
}

# As migrations novas que a Etapa 7 criou - a secao de idempotencia as
# reaplica e compara o estado antes/depois (ver o fim do runner).
$MigrationsIdempotentes = @(
    '20261112001700_fase0_rpc_permissao.sql',
    '20261112001800_fase0_views_limiar.sql',
    '20261112001900_fase0_revoga_grants_permitidos.sql'
)

# Snapshot textual de TUDO que vive no schema public (definicoes + grants).
# Serve de comparacao: se a reaplicacao mudar alguma coisa, o build quebra.
$SqlSnapshot = @'
select 'fn|' || p.proname || '|' || pg_get_functiondef(p.oid) || '|' || coalesce(p.proacl::text, '-')
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
union all
select 'rel|' || c.relname || '|' || coalesce(c.relacl::text, '-') || '|' ||
       coalesce(pg_get_viewdef(c.oid, true), '-')
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public'
   and c.relkind in ('r', 'v', 'm', 'S')
order by 1;
'@

$falhas = 0
$total  = 0

# ----------------------------------------------------------------------------
# INSTRUMENTACAO: track_functions = 'all'
# ----------------------------------------------------------------------------
# A secao de cobertura de funcoes (08) prova que TODA funcao de producao foi
# EXECUTADA de verdade - a prova vem de pg_stat_user_functions, que so conta
# chamada quando o track_functions esta ligado.
#
# O postgres local NAO e superusuario (so o supabase_admin e), e por isso a
# ligacao e feita com ALTER SYSTEM + reload, como superuser.
# `pg_stat_reset()` zera os contadores: so o que rodar a partir daqui conta.
Write-Host ''
Write-Host '=== instrumentacao: track_functions = all ===' -ForegroundColor Cyan

$saidaInstr = Invoke-Psql "alter system set track_functions = 'all';
select pg_reload_conf();
select pg_stat_reset();" -Usuario 'supabase_admin' -NaoFalhar
$saidaInstr | ForEach-Object { Write-Host $_ }

$total++
if ($LASTEXITCODE -ne 0) {
    $falhas++
    Write-Host 'FALHOU: instrumentacao (track_functions)' -ForegroundColor Red
} else {
    Write-Host 'OK: instrumentacao (track_functions = all)' -ForegroundColor Green
}

foreach ($t in $Testes) {
    $caminho = Join-Path $PSScriptRoot $t
    Write-Host ''
    Write-Host "=== $t ===" -ForegroundColor Cyan

    # A preparacao (usuarios de teste, helpers, fixtures) roda ANTES de cada
    # bateria: um `supabase db reset` apaga as funcoes de teste, e as
    # baterias dependem delas.
    if ($t -ne '00_preparacao.test.sql') {
        Invoke-PsqlArquivo $caminho | Out-Null
        # A fixture do B vem ANTES da limpeza: `test_limpar_dados` apaga
        # competencias e fontes de importacao.
        # Ordem importa: `test_limpar_dados` apaga competencias e fontes
        # de importacao (inclusive as do condominio B), entao a fixture do
        # B vem DEPOIS da limpeza.
        Invoke-Psql "select public.test_limpar_dados();
select public.test_criar_fixture_cond_b();
select public.test_criar_lancamentos_fixture();
select public.test_criar_fixture_matriz();" | Out-Null
    }

    $saida = Invoke-PsqlArquivo $caminho
    $saida | ForEach-Object { Write-Host $_ }

    # Conta os "ok" e "not ok" do pgTAP.
    # A saida do psql vem como array de linhas; o join garante uma unica
    # string para o regex.
    $texto = ($saida | Out-String)
    $ok    = ([regex]::Matches($texto, '(?m)^\s*ok\s+\d+')).Count
    $notOk = ([regex]::Matches($texto, '(?m)^\s*not ok\s+\d+')).Count
    $total += $ok
    $falhas += $notOk

    if ($notOk -gt 0) {
        Write-Host "FALHOU: $notOk teste(s) em $t" -ForegroundColor Red
    } else {
        Write-Host "OK: $ok teste(s) em $t" -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------
# VERIFICACOES AUTOCONTIDAS (drift de grants)
# ----------------------------------------------------------------------------
# Nao dependem de 00_preparacao: nao criam usuario, nao criam dado, e
# rodam no remoto com o MESMO arquivo.
foreach ($t in $TestesAutocontidos) {
    $caminho = Join-Path $PSScriptRoot $t
    Write-Host ''
    Write-Host "=== $t (autocontido) ===" -ForegroundColor Cyan

    $saidaAc = Invoke-PsqlArquivo $caminho -NaoFalhar
    $saidaAc | ForEach-Object { Write-Host $_ }

    $textoAc = ($saidaAc | Out-String)
    # O prefixo "psql:<arquivo>:<linha>:" aparece quando o SQL roda com -f;
    # o regex aceita os dois formatos.
    $okAc    = ([regex]::Matches($textoAc, '(?im)^(?:psql:[^\r\n]*?:\s*)?NOTICE:\s+OK')).Count
    $notOkAc = ([regex]::Matches($textoAc, '(?im)^(?:psql:[^\r\n]*?:\s*)?ERROR')).Count
    $total   += $okAc
    $falhas  += $notOkAc

    if ($notOkAc -gt 0) {
        Write-Host "FALHOU: $notOkAc verificacao(oes) em $t" -ForegroundColor Red
    } else {
        Write-Host "OK: $okAc verificacao(oes) de drift em $t" -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------
# AUDITORIA ESTATICA DAS MIGRATIONS (REVOKE explicito)
# ----------------------------------------------------------------------------
# Nao toca no banco: varre os arquivos de migration e exige que TODO objeto
# criado receba, NA PROPRIA migration, REVOKE explicito de anon/
# authenticated (e de public, nas funcoes). Ver o cabecalho de
# supabase\tests\audita_migrations.py.
Write-Host ''
Write-Host '=== auditoria estatica das migrations ===' -ForegroundColor Cyan

$python = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $python) {
    Write-Host 'python nao encontrado -- pulando a auditoria estatica' -ForegroundColor Yellow
} else {
    $saidaAud = & $python (Join-Path $PSScriptRoot 'audita_migrations.py') 2>&1 |
                ForEach-Object { $_.ToString() }
    $saidaAud | ForEach-Object { Write-Host $_ }

    $codigoAud = $LASTEXITCODE
    $total++
    if ($codigoAud -ne 0) {
        $falhas++
        Write-Host 'FALHOU: auditoria estatica das migrations' -ForegroundColor Red
    } else {
        Write-Host 'OK: auditoria estatica das migrations' -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------
# VARREDURA DE ENCODING (UTF-8 sem BOM, sem mojibake)
# ----------------------------------------------------------------------------
# Nao toca no banco: confere que todo arquivo de texto do repositorio esta
# em UTF-8 valido, sem BOM, sem assinatura de dupla codificacao, e que os
# .ps1 sao ASCII puro (o PS 5.1 le .ps1 sem BOM como ANSI). Ver o
# cabecalho de supabase\tools\varre_encoding.py.
Write-Host ''
Write-Host '=== varredura de encoding ===' -ForegroundColor Cyan

if (-not $python) {
    Write-Host 'python nao encontrado - pulando a varredura de encoding' -ForegroundColor Yellow
} else {
    $saidaEnc = & $python (Join-Path $Raiz 'supabase\tools\varre_encoding.py') 2>&1 |
                ForEach-Object { $_.ToString() }
    $saidaEnc | ForEach-Object { Write-Host $_ }

    $codigoEnc = $LASTEXITCODE
    $total++
    if ($codigoEnc -ne 0) {
        $falhas++
        Write-Host 'FALHOU: varredura de encoding' -ForegroundColor Red
    } else {
        Write-Host 'OK: varredura de encoding' -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------
# TESTE DE PONTA A PONTA (API REST, tokens reais)
# ----------------------------------------------------------------------------
# Nao usa `set local role` nem GUCs simulados: faz login de verdade pela
# API de autenticacao do Supabase local e chama as funcoes e views pelo
# endpoint REST -- exatamente como o front faria.
Write-Host ''
Write-Host '=== e2e: API REST com token real ===' -ForegroundColor Cyan

if (-not $python) {
    Write-Host 'python nao encontrado -- pulando o teste e2e' -ForegroundColor Yellow
} else {
    $saidaE2e = & $python (Join-Path $PSScriptRoot 'e2e_rest.py') 2>&1
    $saidaE2e | ForEach-Object { Write-Host $_ }

    $textoE2e = ($saidaE2e | Out-String)
    $okE2e = ([regex]::Matches($textoE2e, '(?m)^\s*ok\s+\d+\.')).Count
    $notOkE2e = ([regex]::Matches($textoE2e, '(?m)^\s*NOT OK\s+\d+\.')).Count
    $total += $okE2e
    $falhas += $notOkE2e

    if ($notOkE2e -gt 0) {
        Write-Host "FALHOU: $notOkE2e verificacao(oes) no e2e" -ForegroundColor Red
    } else {
        Write-Host "OK: $okE2e verificacao(oes) no e2e" -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------------
# COBERTURA DE FUNCOES (apos a bateria, com track_functions = 'all')
# ----------------------------------------------------------------------------
# Protecao estrutural: toda funcao de producao do schema public precisa ter
# um caminho feliz E uma negacao exercitados de verdade. Foi o que expos as
# duas RPCs que nunca funcionaram (fn_aprovar_staging e
# fn_reconciliar_competencia) - a bateria passava sem exercitar o caminho
# feliz delas.
#
# O arquivo e autocontido e NAO depende de pgtap: usa NOTICE (OK) e
# EXCEPTION (falha), como o teste de drift.
Write-Host ''
Write-Host '=== cobertura de funcoes (08) ===' -ForegroundColor Cyan

$caminhoCobertura = Join-Path $PSScriptRoot '08_cobertura_funcoes.test.sql'
$saidaCob = Invoke-PsqlArquivo $caminhoCobertura -NaoFalhar
$saidaCob | ForEach-Object { Write-Host $_ }

$textoCob = ($saidaCob | Out-String)
# O prefixo "psql:<arquivo>:<linha>:" aparece quando o SQL roda com -f;
# o regex aceita os dois formatos.
$okCob    = ([regex]::Matches($textoCob, '(?im)^(?:psql:[^\r\n]*?:\s*)?NOTICE:\s+OK')).Count
$notOkCob = ([regex]::Matches($textoCob, '(?im)^(?:psql:[^\r\n]*?:\s*)?ERROR')).Count
$total   += $okCob
$falhas  += $notOkCob

if ($notOkCob -gt 0) {
    Write-Host "FALHOU: $notOkCob verificacao(oes) de cobertura de funcoes" -ForegroundColor Red
} else {
    Write-Host "OK: $okCob verificacao(oes) de cobertura de funcoes" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# IDEMPOTENCIA DAS MIGRATIONS NOVAS (reaplica e compara o estado)
# ----------------------------------------------------------------------------
# Reaplica as 3 migrations criadas na Etapa 7 e compara o snapshot do schema
# public (definicoes + grants) antes e depois. Se a reaplicacao mudar
# alguma coisa, a migration NAO era idempotente e o build quebra.
Write-Host ''
Write-Host '=== idempotencia das migrations novas ===' -ForegroundColor Cyan

$snapshotAntes = (Invoke-Psql $SqlSnapshot) -join "`n"

$idempotenteOk = $true
foreach ($m in $MigrationsIdempotentes) {
    $caminhoMig = Join-Path $Raiz ("supabase\migrations\" + $m)
    if (-not (Test-Path $caminhoMig)) {
        Write-Host "migration ausente: $m" -ForegroundColor Red
        $idempotenteOk = $false
        continue
    }

    # Envia o arquivo por docker cp (bytes integros): pelo pipe do PS 5.1 os
    # acentos viravam "?" e o snapshot compararia definicoes diferentes.
    $saidaMig = Invoke-PsqlArquivo $caminhoMig -NaoFalhar
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FALHOU ao reaplicar: $m" -ForegroundColor Red
        $saidaMig | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        $idempotenteOk = $false
    }
}

$snapshotDepois = (Invoke-Psql $SqlSnapshot) -join "`n"

$total++
if ($idempotenteOk -and ($snapshotAntes -eq $snapshotDepois)) {
    Write-Host 'OK: migrations reaplicadas sem mudar o estado (idempotentes)' -ForegroundColor Green
} else {
    $falhas++
    Write-Host 'FALHOU: reaplicacao mudou o estado (migration nao idempotente)' -ForegroundColor Red
    $antesL = $snapshotAntes -split "`n"
    $depoisL = $snapshotDepois -split "`n"
    Compare-Object $antesL $depoisL |
        Select-Object -First 20 |
        ForEach-Object { Write-Host ("  " + $_.SideIndicator + " " + $_.InputObject) -ForegroundColor Red }
}

# ----------------------------------------------------------------------------
# DESLIGA A INSTRUMENTACAO (track_functions volta ao padrao 'none')
# ----------------------------------------------------------------------------
Invoke-Psql "alter system set track_functions = 'none';
select pg_reload_conf();" -Usuario 'supabase_admin' -NaoFalhar | Out-Null

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host "Total de testes: $total" -ForegroundColor Cyan
if ($falhas -gt 0) {
    Write-Host "FALHAS: $falhas" -ForegroundColor Red
    Write-Host 'BUILD FALHOU' -ForegroundColor Red
    exit 1
}
Write-Host 'Todas as verificacoes de seguranca passaram.' -ForegroundColor Green
Write-Host 'BUILD OK' -ForegroundColor Green
exit 0
