<#
    Diffs the PostgreSQL schema against the live MySQL fireflydb, column by
    column, applying the type-mapping rules from README.md.

    Eyeballing 42 tables and 528 columns does not catch a transposed width or a
    dropped NOT NULL; this does.

    Requires MySQL running (XAMPP) and PostgreSQL reachable as firefly_app.

    Usage:  powershell -File scripts\compare-schema.ps1
            powershell -File scripts\compare-schema.ps1 -PgSchema scratch
#>

param(
    [string]$PgSchema = 'public',
    [string]$PgDatabase = 'fireflydb_test'
)

$ErrorActionPreference = 'Stop'

$Mysql = 'C:\xampp\mysql\bin\mysql.exe'
$Psql  = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'

<#
    Deliberate divergences. Anything reported outside this list is a real defect.

    The two renames are the pilot's rule in action: MySQL spells the columns
    "...Billtype", the API payload spells them "...BillType", and PostgreSQL's
    quoted identifiers cannot paper over the difference, so the API wins.
#>
$Renames = @{
    'organization.DefCustSIBilltype' = 'DefCustSIBillType'
    'organization.DefCustSRBilltype' = 'DefCustSRBillType'
}

# Tables given a primary key PostgreSQL needs for ON CONFLICT but MySQL lacks.
# Reported for visibility, never counted as a failure.
$AddedKeys = @{
    'organization'   = 'OrganizationCode'
    'userprivilege'  = 'UserId, ViewName'
    'printersettings'= 'OrganizationCode, VoucherType, UserId'
    'warehousestock' = 'InventoryDetailsId, WarehouseId (promoted from UNIQUE uq_inv_wh)'
}

function ConvertFrom-MysqlType {
    param([string]$T)
    $t = $T.Trim()

    if ($t -match '^varchar\((\d+)\)$')  { return "varchar($($Matches[1]))" }
    if ($t -match '^char\((\d+)\)$')     { return "varchar($($Matches[1]))" }   # trailing-space rule
    if ($t -match '^tinyint')            { return 'smallint' }
    if ($t -match '^bit\(1\)$')          { return 'smallint' }                  # product.isVeg
    if ($t -match '^bigint')             { return 'bigint' }
    if ($t -match '^int|^mediumint|^smallint') { return 'integer' }
    if ($t -match '^decimal\((\d+),(\d+)\)$') { return "numeric($($Matches[1]),$($Matches[2]))" }
    if ($t -eq 'datetime' -or $t -eq 'timestamp') { return 'timestamp(0)' }
    if ($t -eq 'date')                   { return 'date' }
    if ($t -match '^(long|medium|tiny)?text$') { return 'text' }
    if ($t -match '^enum\((.+)\)$') {
        # varchar sized to the longest label, plus a CHECK (verified separately).
        $labels = [regex]::Matches($Matches[1], "'([^']*)'") | ForEach-Object { $_.Groups[1].Value }
        $max = ($labels | Measure-Object -Property Length -Maximum).Maximum
        return "varchar($max)"
    }
    return "UNMAPPED:$t"
}

function ConvertFrom-PgType {
    param([string]$DataType, [string]$CharLen, [string]$NumPrec, [string]$NumScale, [string]$DtPrec)
    switch ($DataType) {
        'character varying'           { return "varchar($CharLen)" }
        'smallint'                    { return 'smallint' }
        'integer'                     { return 'integer' }
        'bigint'                      { return 'bigint' }
        'numeric'                     { return "numeric($NumPrec,$NumScale)" }
        'timestamp without time zone' { return "timestamp($DtPrec)" }
        'date'                        { return 'date' }
        'text'                        { return 'text' }
        default                       { return "UNMAPPED:$DataType" }
    }
}

# ---- read MySQL ------------------------------------------------------------
$myQuery = @"
SELECT TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_TYPE, IS_NULLABLE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA='fireflydb'
ORDER BY TABLE_NAME, ORDINAL_POSITION;
"@
$myRows = & $Mysql -u root -N -B -e $myQuery
if ($LASTEXITCODE -ne 0) { throw "mysql.exe failed. Is XAMPP running?" }

$my = @{}
$myTables = New-Object System.Collections.Generic.HashSet[string]
foreach ($line in $myRows) {
    if (-not $line) { continue }
    $f = $line -split "`t"
    [void]$myTables.Add($f[0])
    $my["$($f[0]).$($f[1])"] = [pscustomobject]@{
        Table = $f[0]; Column = $f[1]; Ordinal = [int]$f[2]
        Type = ConvertFrom-MysqlType $f[3]; RawType = $f[3]; Nullable = $f[4]
    }
}

# ---- read PostgreSQL -------------------------------------------------------
$pgQuery = @"
SELECT table_name, column_name, ordinal_position, data_type,
       coalesce(character_maximum_length::text,''), coalesce(numeric_precision::text,''),
       coalesce(numeric_scale::text,''), coalesce(datetime_precision::text,''), is_nullable
FROM information_schema.columns
WHERE table_schema='$PgSchema'
ORDER BY table_name, ordinal_position;
"@
$env:PGPASSWORD = 'firefly_dev_pw'
$pgRows = & $Psql -U firefly_app -d $PgDatabase -h localhost -tA -F "`t" -c $pgQuery
if ($LASTEXITCODE -ne 0) { throw "psql failed. Is PostgreSQL running?" }

$pg = @{}
$pgTables = New-Object System.Collections.Generic.HashSet[string]
foreach ($line in $pgRows) {
    if (-not $line) { continue }
    $f = $line -split "`t"
    [void]$pgTables.Add($f[0])
    $pg["$($f[0]).$($f[1])"] = [pscustomobject]@{
        Table = $f[0]; Column = $f[1]; Ordinal = [int]$f[2]
        Type = ConvertFrom-PgType $f[3] $f[4] $f[5] $f[6] $f[7]; Nullable = $f[8]
    }
}

# ---- compare ---------------------------------------------------------------
$problems = New-Object System.Collections.Generic.List[string]
$notes    = New-Object System.Collections.Generic.List[string]

foreach ($t in ($myTables | Sort-Object)) {
    if (-not $pgTables.Contains($t)) { $problems.Add("MISSING TABLE      $t") }
}
foreach ($t in ($pgTables | Sort-Object)) {
    if (-not $myTables.Contains($t)) { $problems.Add("EXTRA TABLE        $t  (not in MySQL)") }
}

$matchedPg = New-Object System.Collections.Generic.HashSet[string]

foreach ($key in ($my.Keys | Sort-Object)) {
    $m = $my[$key]
    if (-not $pgTables.Contains($m.Table)) { continue }

    $pgCol = $m.Column
    if ($Renames.ContainsKey($key)) {
        $pgCol = $Renames[$key]
        $notes.Add("RENAMED (expected) $($m.Table).$($m.Column) -> $pgCol")
    }
    $pgKey = "$($m.Table).$pgCol"

    if (-not $pg.ContainsKey($pgKey)) {
        $problems.Add("MISSING COLUMN     $pgKey")
        continue
    }
    [void]$matchedPg.Add($pgKey)
    $p = $pg[$pgKey]

    if ($m.Type -ne $p.Type) {
        $problems.Add("TYPE               $pgKey  mysql=$($m.RawType) -> expected $($m.Type), got $($p.Type)")
    }
    if ($m.Nullable -ne $p.Nullable) {
        # A column pulled into a new primary key is necessarily NOT NULL.
        $inAddedKey = $AddedKeys.ContainsKey($m.Table) -and ($AddedKeys[$m.Table] -like "*$pgCol*")
        if ($inAddedKey -and $p.Nullable -eq 'NO') {
            $notes.Add("NOT NULL via new PK $pgKey")
        } else {
            $problems.Add("NULLABILITY        $pgKey  mysql=$($m.Nullable) pg=$($p.Nullable)")
        }
    }
    if ($m.Ordinal -ne $p.Ordinal) {
        # SELECT * key order follows ordinal position, so this matters on the wire.
        $problems.Add("COLUMN ORDER       $pgKey  mysql=#$($m.Ordinal) pg=#$($p.Ordinal)")
    }
}

foreach ($key in ($pg.Keys | Sort-Object)) {
    if ($matchedPg.Contains($key)) { continue }
    if ($my.ContainsKey($key)) { continue }
    # Extra columns would show up as unexpected keys in every SELECT * response.
    $problems.Add("EXTRA COLUMN       $key  (not in MySQL)")
}

# ---- report ----------------------------------------------------------------
Write-Host ""
Write-Host "MySQL fireflydb  ->  PostgreSQL $PgDatabase.$PgSchema" -ForegroundColor White
Write-Host "  $($myTables.Count) MySQL tables, $($my.Count) columns" -ForegroundColor DarkGray
Write-Host "  $($pgTables.Count) PostgreSQL tables, $($pg.Count) columns" -ForegroundColor DarkGray
Write-Host ""

Write-Host "Deliberate divergences:" -ForegroundColor Cyan
foreach ($n in ($notes | Sort-Object -Unique)) { Write-Host "  $n" -ForegroundColor DarkCyan }
foreach ($t in ($AddedKeys.Keys | Sort-Object)) {
    Write-Host "  ADDED PRIMARY KEY  $t ($($AddedKeys[$t]))" -ForegroundColor DarkCyan
}
Write-Host ""

if ($problems.Count -eq 0) {
    Write-Host "No unexplained differences." -ForegroundColor Green
    exit 0
}

Write-Host "$($problems.Count) unexplained difference(s):" -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  $p" -ForegroundColor Yellow }
exit 1
