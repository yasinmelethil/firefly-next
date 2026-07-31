<#
    Compares the Next.js endpoint against the live PHP endpoint.

    Both servers must be running:
      PHP  : XAMPP Apache on :8090  (c:\xampp\htdocs\ffapi\firefly_api.php)
      Next : npm run dev            (C:\project\firefly-next)

    Writes and then removes organization rows with codes ZZ01-ZZ03 in BOTH
    databases. Real data is untouched.

    Usage:  powershell -File scripts\compare-with-php.ps1
#>

$PhpUrl  = 'http://localhost:8090/ffapi/firefly_api.php'
$NextUrl = 'http://localhost:3000/ffapi/firefly_api.php'

$Mysql    = 'C:\xampp\mysql\bin\mysql.exe'
$Psql     = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$TestCodes = "'ZZ01','ZZ02','ZZ03'"

$script:Pass = 0
$script:Fail = 0

# PostgreSQL needs double-quoted CamelCase identifiers, but PowerShell mangles
# embedded double quotes when handing arguments to a native executable -- psql -c
# receives them unquoted and folds the names to lowercase. Going via a file keeps
# the SQL intact.
function Invoke-Psql {
    param([string]$Sql, [switch]$Quiet)
    $env:PGPASSWORD = 'firefly_dev_pw'
    $tmp = Join-Path $env:TEMP ("ffapi_" + [guid]::NewGuid().ToString('N') + ".sql")
    Set-Content -Path $tmp -Value $Sql -Encoding utf8
    try {
        if ($Quiet) { & $Psql -U firefly_app -d fireflydb_test -h localhost -v ON_ERROR_STOP=1 -f $tmp 2>&1 | Out-Null }
        else        { & $Psql -U firefly_app -d fireflydb_test -h localhost -v ON_ERROR_STOP=1 -f $tmp }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Reset-TestRows {
    & $Mysql -u root fireflydb -e "DELETE FROM organization WHERE OrganizationCode IN ($TestCodes);" 2>&1 | Out-Null
    Invoke-Psql -Quiet "DELETE FROM organization WHERE `"OrganizationCode`" IN ($TestCodes);"
}

function Invoke-Endpoint {
    param([string]$Url, [hashtable]$Body, [string]$Method = 'POST')
    try {
        if ($Method -eq 'POST') {
            $r = Invoke-WebRequest -Uri $Url -Method POST -Body $Body -UseBasicParsing -ErrorAction Stop
        } else {
            $r = Invoke-WebRequest -Uri $Url -Method $Method -UseBasicParsing -ErrorAction Stop
        }
        return [pscustomobject]@{
            Status      = [int]$r.StatusCode
            ContentType = $r.Headers['Content-Type']
            Cors        = $r.Headers['Access-Control-Allow-Origin']
            Body        = $r.Content
        }
    } catch {
        return [pscustomobject]@{
            Status = -1; ContentType = ''; Cors = ''; Body = "REQUEST FAILED: $($_.Exception.Message)"
        }
    }
}

function Get-Status {
    param([string]$Body)
    if ($Body -match '"STATUS":"([A-Z]+)"') { return $Matches[1] }
    return '(none)'
}

<#
    Mode 'Bytes'  - responses must be byte-identical.
    Mode 'Status' - only the STATUS field must agree. Used where both sides fail
                    for the same reason but each leaks its own driver's wording
                    (MySQL "Column 'X' cannot be null" vs PostgreSQL's not-null
                    violation text). Behaviour matches; the message tail does not.
#>
function Compare-Case {
    param(
        [string]$Name,
        [hashtable]$Body,
        [string]$Method = 'POST',
        [ValidateSet('Bytes','Status')][string]$Mode = 'Bytes'
    )

    $php  = Invoke-Endpoint -Url $PhpUrl  -Body $Body -Method $Method
    $next = Invoke-Endpoint -Url $NextUrl -Body $Body -Method $Method

    if ($Mode -eq 'Bytes') {
        $same = ($php.Body -ceq $next.Body) -and ($php.Status -eq $next.Status)
    } else {
        $same = ((Get-Status $php.Body) -ceq (Get-Status $next.Body)) -and ($php.Status -eq $next.Status)
    }

    if ($same) {
        $script:Pass++
        Write-Host "PASS  $Name" -ForegroundColor Green
        if ($Mode -eq 'Bytes') {
            Write-Host "      $($php.Body)" -ForegroundColor DarkGray
        } else {
            Write-Host "      both STATUS=$(Get-Status $php.Body); driver text differs by design:" -ForegroundColor DarkGray
            Write-Host "      PHP  $($php.Body)"  -ForegroundColor DarkGray
            Write-Host "      NEXT $($next.Body)" -ForegroundColor DarkGray
        }
    } else {
        $script:Fail++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      PHP  [$($php.Status)] $($php.Body)"  -ForegroundColor Yellow
        Write-Host "      NEXT [$($next.Status)] $($next.Body)" -ForegroundColor Cyan
    }
}

# A full, valid 25-field payload. Individual cases clone and tweak this.
function New-OrgBody {
    param([string]$Code = 'ZZ01', [string]$Name = 'Pilot Test Org')
    return @{
        api               = 'insert_organization'
        OrganizationCode  = $Code
        Type              = 'General'
        Name              = $Name
        RegionalName      = 'Pilot Regional'
        Address           = '123 Test Street'
        CityId            = '4319'
        ZipCode           = '682001'
        CountryCode       = 'IND'
        Phone1            = '9876543210'
        Phone2            = '9876543211'
        Fax               = '0484123456'
        EmailId           = 'pilot@example.com'
        Url               = 'https://example.com'
        Description       = 'Migration pilot record'
        ImagePath         = 'no_image.jpg'
        Longitude         = '76.2673'
        Latitude          = '9.9312'
        StartTime         = '09:00'
        EndTime           = '21:00'
        TINNumber         = 'TIN123456'
        DefCustSOBillType = 'SO1'
        DefCustSIBillType = 'SI1'
        DefCustSRBillType = 'SR1'
        DefCustBank       = 'BANK1'
        DefCustRate       = 'RATE1'
    }
}

Write-Host "`n=== insert_organization parity ===`n" -ForegroundColor White
Reset-TestRows

# 1. Insert a new organization.
Compare-Case -Name '1. INSERT new org' -Body (New-OrgBody)

# 2. Same code again with a changed Name -> takes the UPDATE path.
Compare-Case -Name '2. UPDATE existing org' -Body (New-OrgBody -Name 'Pilot Test Org RENAMED')

# 3. Omitted fields. Both sides must reject the write (missing field -> NULL into a
#    NOT NULL column). Each reports it in its own driver's words.
$partial = New-OrgBody -Code 'ZZ02'
$partial.Remove('Phone2')
$partial.Remove('Fax')
Compare-Case -Name '3. Missing fields are rejected' -Body $partial -Mode 'Status'

# 4. Unknown action.
Compare-Case -Name '4. Unknown api name' -Body @{ api = 'this_api_does_not_exist' }

# 5. POST with no api field -> empty body.
Compare-Case -Name '5. POST with no api field' -Body @{ something = 'else' }

# 6. GET -> empty body.
Compare-Case -Name '6. GET request' -Body @{} -Method 'GET'

# 7. Overlong value against a varchar(50) column. KNOWN DIVERGENCE, not asserted:
#    non-strict MySQL silently truncates to 50 chars and reports SUCCESS,
#    PostgreSQL rejects the value. See "Known divergences" in README.md.
$long = New-OrgBody -Code 'ZZ03' -Name ('X' * 100)
Write-Host "`n--- 7. Overlong Name (known divergence, informational) ---" -ForegroundColor Magenta
$phpLong  = Invoke-Endpoint -Url $PhpUrl  -Body $long
$nextLong = Invoke-Endpoint -Url $NextUrl -Body $long
Write-Host "      PHP  $($phpLong.Body)"  -ForegroundColor Yellow
Write-Host "      NEXT $($nextLong.Body)" -ForegroundColor Cyan

# 8. Headers.
Write-Host "`n--- 8. Header check ---" -ForegroundColor Magenta
$h1 = Invoke-Endpoint -Url $PhpUrl  -Body (New-OrgBody)
$h2 = Invoke-Endpoint -Url $NextUrl -Body (New-OrgBody)
Write-Host "      PHP  Content-Type=$($h1.ContentType) CORS=$($h1.Cors)"
Write-Host "      NEXT Content-Type=$($h2.ContentType) CORS=$($h2.Cors)"

# 9. Confirm the row actually landed identically in both databases.
Write-Host "`n--- 9. Stored row comparison (ZZ01) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT OrganizationCode, Name, Phone1, DefCustSIBilltype FROM organization WHERE OrganizationCode='ZZ01';"
Invoke-Psql "SELECT `"OrganizationCode`", `"Name`", `"Phone1`", `"DefCustSIBillType`" FROM organization WHERE `"OrganizationCode`" = 'ZZ01';"

Reset-TestRows

Write-Host "`n=== $script:Pass passed, $script:Fail failed ===`n" -ForegroundColor White
if ($script:Fail -gt 0) { exit 1 }
