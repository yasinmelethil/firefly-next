<#
    Generates db\001_baseline.sql by concatenating db\tables\*.sql in dependency
    order. The per-table files are the source you edit; the baseline is derived,
    so the two cannot drift.

    Usage:  powershell -File scripts\build-baseline.ps1
#>

$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$TablesDir = Join-Path $Root 'db\tables'
$OutFile   = Join-Path $Root 'db\001_baseline.sql'

<#
    Creation order. Only one constraint is actually enforced by the schema --
    pos_modes must precede pos_mode_print_targets and pos_user_mode_prefs, the
    only two tables with real foreign keys. Everything else is grouped by
    dependency tier for readability, and so the order stays correct if foreign
    keys are ever added. See README "Schema translation rules".
#>
$Order = @(
    # Tier 0 - reference and master data, nothing points at them
    'organization', 'taxdetails', 'rout', 'counters',
    'settings_common', 'settings_urls', 'settings_upi',
    'printers', 'print_templates', 'pos_modes',
    # Tier 1 - depend on tier 0
    'billtype', 'category',
    'ledger', 'product',
    # Tier 2 - product satellites and users
    'user', 'gatepass', 'warehousestock', 'substock', 'product_images',
    # Tier 3 - permissions and per-user settings
    'userprivilege', 'userledgerprivilege', 'printersettings',
    'user_printers', 'user_print_formats',
    'pos_user_mode_prefs', 'pos_mode_print_targets',
    # Tier 4 - transaction masters
    'ordermaster', 'purchaseordermaster',
    # Tier 5 - transaction details
    'orderdetails', 'purchaseorderdetails', 'ordercancelmaster',
    'salemaster', 'ordercanceldetails', 'salesdetails',
    # Tier 6 - returns, stock ledger, financial vouchers
    'salereturn', 'stockposting',
    'receipt', 'payment', 'journal', 'pdcdetails',
    'salesreturndetails',
    # Tier 7 - infrastructure
    'schema_migrations'
)

# Every .sql in db\tables must appear in $Order exactly once, or the baseline
# would silently omit a table. _functions.sql is emitted separately, first.
$onDisk = Get-ChildItem -Path $TablesDir -Filter '*.sql' |
          Where-Object { $_.BaseName -ne '_functions' } |
          ForEach-Object { $_.BaseName }

$missing = $onDisk | Where-Object { $Order -notcontains $_ }
$extra   = $Order  | Where-Object { $onDisk -notcontains $_ }

if ($missing) { throw "In db\tables\ but not in `$Order: $($missing -join ', ')" }
if ($extra)   { throw "In `$Order but no such file in db\tables\: $($extra -join ', ')" }

$sb = [System.Text.StringBuilder]::new()

[void]$sb.AppendLine(@"
-- ============================================================================
-- db/001_baseline.sql -- the complete fireflydb schema, ported to PostgreSQL.
--
-- GENERATED FILE. Do not edit. Edit db/tables/<name>.sql and re-run:
--     powershell -File scripts\build-baseline.ps1
--
-- Creates all $($Order.Count) tables empty, translated from the live MySQL
-- ``fireflydb`` schema. Idempotent -- every statement is IF NOT EXISTS or
-- CREATE OR REPLACE, so re-running is a no-op.
--
-- Run as the postgres superuser, after db/000_create_database.sql:
--     psql -U postgres -d fireflydb_test -f db/001_baseline.sql
--
-- Identity columns start at 1 because the tables are created empty. If rows are
-- ever loaded from MySQL, every sequence must be setval'd to MAX(id) afterwards
-- or the first insert will collide.
-- ============================================================================

"@)

function Add-Section {
    param([string]$Name, [string]$Path)
    [void]$sb.AppendLine('-- ' + ('=' * 74))
    [void]$sb.AppendLine("-- $Name")
    [void]$sb.AppendLine('-- ' + ('=' * 74))
    [void]$sb.AppendLine((Get-Content -Path $Path -Raw).TrimEnd())
    [void]$sb.AppendLine('')
}

Add-Section -Name 'shared functions' -Path (Join-Path $TablesDir '_functions.sql')
foreach ($t in $Order) {
    Add-Section -Name $t -Path (Join-Path $TablesDir "$t.sql")
}

Set-Content -Path $OutFile -Value $sb.ToString().TrimEnd() -Encoding utf8

Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "  $($Order.Count) tables + shared functions" -ForegroundColor DarkGray
