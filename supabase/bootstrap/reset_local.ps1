# ============================================================================
# BOOTSTRAP DO AMBIENTE LOCAL (PowerShell)
# ============================================================================
# Deve ser executado depois de `supabase db reset` e ANTES dos testes.
#
# POR QUE EXISTE
# --------------
# No Postgres, cada papel so pode alterar os PROPRIOS default privileges.
# O papel `postgres` (que executa as migrations) NAO e superuser no Supabase
# local, entao ele nao consegue revogar os default privileges do
# `supabase_admin`:
#
#   ERROR: permission denied to change default privileges
#
# Como o `supabase_admin` E superuser, o revoke roda como ele.
#
# Sem esse passo, qualquer tabela/funcao/view criada DEPOIS nasce com
# privilegio de `anon` e `authenticated` - e a garantia de acesso do leitor
# se quebra silenciosamente.
#
# Uso:  pwsh -File supabase\bootstrap\reset_local.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'

$Raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $Raiz

$Container = if ($env:SUPABASE_DB_CONTAINER) {
    $env:SUPABASE_DB_CONTAINER
} else {
    'supabase_db_anperez_condominios'
}

Write-Host '=== 1/4 - aguardando o banco ==='
$pronto = $false
for ($i = 0; $i -lt 60; $i++) {
    docker exec $Container pg_isready -U postgres -d postgres *> $null
    if ($LASTEXITCODE -eq 0) { $pronto = $true; break }
    Start-Sleep -Seconds 2
}
if (-not $pronto) { throw "banco nao ficou pronto: $Container" }
Write-Host 'banco pronto'

Write-Host '=== 2/4 - zerando os privilegios padrao (como supabase_admin) ==='
Get-Content 'supabase\bootstrap\00-zerar_privilegios_padrao.sql' -Raw |
    docker exec -i $Container psql -U supabase_admin -d postgres
if ($LASTEXITCODE -ne 0) { throw 'falha ao zerar privilegios padrao' }

Write-Host '=== 3/4 - instalando pgtap e ajustando o search_path ==='
@'
create extension if not exists pgtap with schema extensions;
create extension if not exists pgcrypto with schema extensions;
alter database postgres set search_path = public, extensions, pg_temp;
'@ | docker exec -i $Container psql -U postgres -d postgres
if ($LASTEXITCODE -ne 0) { throw 'falha ao instalar extensoes' }

Write-Host '=== 4/4 - carga de seed (configuracao ficticia) ==='
Get-Content 'supabase\seed.sql' -Raw |
    docker exec -i $Container psql -U postgres -d postgres -v ON_ERROR_STOP=1
if ($LASTEXITCODE -ne 0) { throw 'falha na carga do seed' }

Write-Host '=== bootstrap concluido ==='
