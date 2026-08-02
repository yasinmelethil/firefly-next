<#
.SYNOPSIS
  PREPAREs every SQL statement in src/ against PostgreSQL and reports the ones
  the planner refuses.

.DESCRIPTION
  checkedSql() in src/lib/sql.ts catches one failure mode -- a $n the statement
  never mentions -- but it is a regex over the text and cannot see anything the
  server decides. The failure it misses is type resolution:

      COALESCE(NULLIF($1,''), "RoundOffAmount")
        ERROR:  COALESCE types text and numeric cannot be matched

      COALESCE(NULLIF("LedgerId",''), "led_id")
        ERROR:  COALESCE types character varying and integer cannot be matched

  Both are accepted by MySQL, both parse as valid SQL, and both surface at
  runtime as the endpoint quietly answering FALSE or a 500 -- every handler
  swallows its exception, because the PHP does. PREPARE runs the parser and the
  type resolver without executing anything, so it turns those into a build-time
  list.

  Statements are lifted out of the source text rather than imported, so no
  module has to export its SQL. Single-level ${CONST} references are resolved
  against other constants in the same file, which covers the shared column
  lists and predicate fragments. A statement still holding a ${...} after that
  -- the write statements built by cols()/binds()/setList() -- is reported as
  SKIPPED, not silently dropped: those are the ones checkedSql already guards.

.EXAMPLE
  powershell -File scripts\check-sql.ps1
#>

[CmdletBinding()]
param(
    [string]$Psql = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# --------------------------------------------------------------------------
# Connection: the same DATABASE_URL the app uses.
# --------------------------------------------------------------------------
$envFile = Join-Path $root '.env.local'
if (-not (Test-Path $envFile)) {
    Write-Host "No .env.local found at $envFile" -ForegroundColor Red
    exit 1
}
$url = (Get-Content $envFile | Where-Object { $_ -match '^\s*DATABASE_URL\s*=' }) -replace '^\s*DATABASE_URL\s*=\s*', ''
if (-not $url) {
    Write-Host 'DATABASE_URL is not set in .env.local' -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $Psql)) {
    Write-Host "psql not found at $Psql (override with -Psql)" -ForegroundColor Red
    exit 1
}

# --------------------------------------------------------------------------
# Extract `const NAME = ` + backtick + `...` + backtick from every source file.
# --------------------------------------------------------------------------
$constPattern = '(?ms)^const\s+(\w+)\s*=\s*`(.*?)`\s*;'
$sqlStart = '^\s*(SELECT|INSERT|UPDATE|DELETE|WITH)\b'

$statements = @()
foreach ($file in Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Filter *.ts) {
    # -Encoding UTF8 is required, not cosmetic. Windows PowerShell 5.1 falls back
    # to the ANSI codepage for a file with no BOM, and .ts files are BOM-less
    # UTF-8 -- so login's 'र' literal (U+0930) would be read as three Latin-1
    # characters, re-encoded as those, and PREPAREd. Still a valid string
    # literal, so the check reports ok while validating bytes nobody wrote.
    $text = Get-Content -Raw -Encoding UTF8 -Path $file.FullName
    $consts = @{}
    foreach ($m in [regex]::Matches($text, $constPattern)) {
        $consts[$m.Groups[1].Value] = $m.Groups[2].Value
    }

    foreach ($name in $consts.Keys) {
        $body = $consts[$name]
        # Resolve ${OTHER_CONST} against this file's constants. Three passes is
        # more nesting than any fragment here uses and terminates regardless.
        for ($pass = 0; $pass -lt 3; $pass++) {
            $body = [regex]::Replace($body, '\$\{(\w+)\}', {
                param($m)
                $key = $m.Groups[1].Value
                if ($consts.ContainsKey($key)) { $consts[$key] } else { $m.Value }
            })
        }
        if ($body -notmatch $sqlStart) { continue }

        $statements += [pscustomobject]@{
            File    = $file.FullName.Substring($root.Length + 1)
            Name    = $name
            Sql     = $body
            # A leftover ${...} is a call like cols(FIELDS), not a constant.
            Skipped = $body -match '\$\{'
        }
    }
}

# --------------------------------------------------------------------------
# PREPARE each one. Nothing is executed and nothing is written.
# --------------------------------------------------------------------------
$scratch = Join-Path $env:TEMP 'ffapi-check-sql.sql'
$pass = 0; $skip = 0; $fail = 0
$failures = @()

foreach ($s in ($statements | Sort-Object File, Name)) {
    if ($s.Skipped) {
        $skip++
        Write-Host ('  SKIP  {0,-34} {1}' -f $s.Name, '(built at runtime; checkedSql covers it)') -ForegroundColor DarkGray
        continue
    }

    "PREPARE ffapi_check AS`n$($s.Sql);" | Set-Content -Path $scratch -Encoding utf8
    $out = & $Psql $url -v ON_ERROR_STOP=1 -q -f $scratch 2>&1
    if ($LASTEXITCODE -eq 0) {
        $pass++
        Write-Host ('  ok    {0}' -f $s.Name) -ForegroundColor DarkGreen
    }
    else {
        $fail++
        $message = ($out | Where-Object { $_ -match 'ERROR|DETAIL|HINT' }) -join '; '
        Write-Host ('  FAIL  {0}' -f $s.Name) -ForegroundColor Red
        Write-Host ('        {0}' -f $message) -ForegroundColor Red
        $failures += [pscustomobject]@{ File = $s.File; Name = $s.Name; Message = $message }
    }
}

Remove-Item -Path $scratch -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ('{0} prepared, {1} skipped, {2} failed' -f $pass, $skip, $fail)
if ($fail -gt 0) {
    Write-Host ''
    foreach ($f in $failures) { Write-Host ('{0}  {1}' -f $f.File, $f.Name) -ForegroundColor Red }
    exit 1
}
exit 0
