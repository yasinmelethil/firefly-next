<#
    Compares the Next.js endpoint against the live PHP endpoint.

    Both servers must be running:
      PHP  : XAMPP Apache on :8090  (c:\xampp\htdocs\ffapi\firefly_api.php)
      Next : npm run dev            (C:\project\firefly-next)

    Writes and then removes organization rows with codes ZZ01-ZZ03, and product /
    warehousestock rows whose InventoryDetailsId starts ZZTEST, in BOTH databases.
    Real data is untouched.

    Usage:  powershell -File scripts\compare-with-php.ps1
            powershell -File scripts\compare-with-php.ps1 -EchoSql
            powershell -File scripts\compare-with-php.ps1 -TestStockErpMode

    -EchoSql           Assert the product responses are byte-identical INCLUDING
                       the raw-SQL prefix that firefly_api.php echoes. Requires
                       the Next server to have been started with
                       FFAPI_ECHO_SQL=1; without it the port emits clean JSON and
                       only the JSON tail is compared.

    -TestStockErpMode  Additionally exercise the warehousestock path by flipping
                       settings_common.stock_source to 'ERP' in both databases,
                       then restoring it. OFF by default: live MySQL is set to
                       'APP', and that is a production setting this script should
                       not change unless asked.
#>

param(
    [switch]$EchoSql,
    [switch]$TestStockErpMode
)

$PhpUrl  = 'http://localhost:8090/ffapi/firefly_api.php'
$NextUrl = 'http://localhost:3000/ffapi/firefly_api.php'

$Mysql    = 'C:\xampp\mysql\bin\mysql.exe'
$Psql     = 'C:\Program Files\PostgreSQL\18\bin\psql.exe'
$TestCodes = "'ZZ01','ZZ02','ZZ03'"
$TestInv   = 'ZZTEST-0000000001'
$TestInv2  = 'ZZTEST-0000000002'

# Master-data keys for the billtype / category / taxdetails / ledger / user
# endpoints. Every one starts ZZ so the cleanup below can scope itself safely.
$TestOrg    = 'ZZ01'
$TestBill   = 'ZZBT01'
$TestCat    = 'ZZCAT-0000000001'
$TestTax    = 'ZZTAX01'
# 20 chars exactly, and hyphenated: insert_ledger derives CentreCode from
# explode('-', LedgerId)[1], so the middle segment must be a valid varchar(4).
$TestLedger = 'ZZ01-ZZLG-0000000001'
$TestRout   = 'ZZRT01'
$TestUser   = 'ZZUSER01'

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

function Reset-ProductRows {
    # warehousestock first: its insert path is guarded on the product existing,
    # so leaving orphans would change what the next run exercises.
    & $Mysql -u root fireflydb -e "DELETE FROM warehousestock WHERE InventoryDetailsId LIKE 'ZZTEST%'; DELETE FROM product WHERE InventoryDetailsId LIKE 'ZZTEST%';" 2>&1 | Out-Null
    Invoke-Psql -Quiet "DELETE FROM warehousestock WHERE `"InventoryDetailsId`" LIKE 'ZZTEST%'; DELETE FROM product WHERE `"InventoryDetailsId`" LIKE 'ZZTEST%';"
}

<#
    Clears the master-data test rows from both databases.

    Children first, because two of the ported inserts are guarded on their parent
    existing (userprivilege needs the user, userledgerprivilege needs the ledger)
    and a leftover child would change what the next run exercises.

    Every predicate is ZZ-scoped. The rout cleanup also matches on Name so the
    RoutId='0' guard case can be tidied up if it ever fails and writes a row --
    without that, a `RoutId = '0'` predicate would risk a real production route.
#>
function Reset-MasterRows {
    & $Mysql -u root fireflydb -e 'DELETE FROM userprivilege WHERE UserId LIKE ''ZZ%''; DELETE FROM userledgerprivilege WHERE UserId LIKE ''ZZ%''; DELETE FROM `user` WHERE UserId LIKE ''ZZ%''; DELETE FROM ledger WHERE LedgerId LIKE ''ZZ%''; DELETE FROM rout WHERE RoutId LIKE ''ZZ%'' OR Name LIKE ''ZZ%''; DELETE FROM billtype WHERE BillTypeId LIKE ''ZZ%''; DELETE FROM category WHERE InventoryGroupId LIKE ''ZZ%''; DELETE FROM taxdetails WHERE TaxId LIKE ''ZZ%'';' 2>&1 | Out-Null

    Invoke-Psql -Quiet @'
DELETE FROM userprivilege        WHERE "UserId"           LIKE 'ZZ%';
DELETE FROM userledgerprivilege  WHERE "UserId"           LIKE 'ZZ%';
DELETE FROM "user"               WHERE "UserId"           LIKE 'ZZ%';
DELETE FROM ledger               WHERE "LedgerId"         LIKE 'ZZ%';
DELETE FROM rout                 WHERE "RoutId"           LIKE 'ZZ%' OR "Name" LIKE 'ZZ%';
DELETE FROM billtype             WHERE "BillTypeId"       LIKE 'ZZ%';
DELETE FROM category             WHERE "InventoryGroupId" LIKE 'ZZ%';
DELETE FROM taxdetails           WHERE "TaxId"            LIKE 'ZZ%';
'@
}

<#
    Same file-based trick as Invoke-Psql, for the same reason.

    The sync-loop fixtures are multi-statement and full of quotes, which does not
    survive `mysql -e "..."` through PowerShell's native-argument handling.
#>
function Invoke-MysqlFile {
    param([string]$Sql)
    $tmp = Join-Path $env:TEMP ("ffapi_" + [guid]::NewGuid().ToString('N') + ".sql")
    Set-Content -Path $tmp -Value $Sql -Encoding utf8
    try { & $Mysql -u root fireflydb -e "source $($tmp -replace '\\','/')" 2>&1 | Out-Null }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

<#
    Clears the sync-loop fixtures from both databases. Children first.

    Every predicate is ZZ-scoped except ledger, which is matched on LedgerName
    because the get_newcustomers fixture deliberately carries LedgerId = '' --
    a 'ZZ%' predicate on LedgerId would not match it, and a `LedgerId = ''`
    predicate would delete real unsynced customers.
#>
function Reset-SyncRows {
    $sql = @'
DELETE FROM orderdetails         WHERE ordermstr_id        LIKE 'ZZ%';
DELETE FROM ordercanceldetails   WHERE OrderCancelMasterId LIKE 'ZZ%';
DELETE FROM salesdetails         WHERE SaleMasterId        LIKE 'ZZ%';
DELETE FROM salesreturndetails   WHERE SaleReturnMasterId  LIKE 'ZZ%';
DELETE FROM purchaseorderdetails WHERE ordermstr_id        LIKE 'ZZ%';
DELETE FROM pdcdetails           WHERE PDCDetailsId        LIKE 'ZZ%';
DELETE FROM ordercancelmaster    WHERE OrderCancelMasterId LIKE 'ZZ%';
DELETE FROM ordermaster          WHERE OrderMasterId       LIKE 'ZZ%';
DELETE FROM salereturn           WHERE SaleReturnMasterId  LIKE 'ZZ%';
DELETE FROM salemaster           WHERE SaleMasterId        LIKE 'ZZ%';
DELETE FROM purchaseordermaster  WHERE ordermasterId       LIKE 'ZZ%';
DELETE FROM receipt              WHERE ReceiptId           LIKE 'ZZ%';
DELETE FROM payment              WHERE PaymentId           LIKE 'ZZ%';
DELETE FROM journal              WHERE JournalId           LIKE 'ZZ%';
DELETE FROM ledger               WHERE LedgerName          LIKE 'ZZ %';
'@
    Invoke-MysqlFile $sql
    # The same statements, with PostgreSQL's quoted CamelCase identifiers.
    Invoke-Psql -Quiet ($sql -replace '(?m)WHERE (\w+)', 'WHERE "$1"')
}

<#
    Seeds one document of every kind the ERP pulls, into both databases.

    Three things make this comparable byte-for-byte, and all three are easy to
    lose:

      - Status is 'Z', a character no production row uses. Every get_* filters on
        it, so the comparison sees only these fixtures even though live MySQL is
        full of real documents and PostgreSQL is empty.
      - Every timestamp is pinned. OrderDate/VoucherDate/CreatedTimeStamp all
        default to the insert time, so seeding the two databases a second apart
        would differ on the wire for no interesting reason.
      - led_id is explicit. It is an identity/AUTO_INCREMENT column whose value
        get_newcustomers puts on the wire as "ID", and the two sequences are
        nowhere near each other.

    ZZOM02 deliberately has no order lines, to exercise the empty-details path
    (which is [], not null and not "EMPTY"), and an unmatched LedgerId to
    exercise the COALESCE in the LEFT JOIN. The purchase order carries one
    received line and one zeroed line, so the ForFireFly filter has something to
    exclude.
#>
function Seed-SyncRows {
    $sql = @'
INSERT INTO ledger (led_id,OrganizationCode,CentreCode,LedgerId,LedgerType,LedgerName,RegionalName,Address,Email,Phone,UserName,mypassword,noofseats,seatstaken,CurrentBalance,LedgerCode,CustomCode,RoutId,TINNumber)
VALUES (990001,'ZZ01','ZZ01','','P','ZZ New Customer','ZZ Regional','ZZ Addr','zz@example.com','555','zzuser','zzpw',0,0,0,'ZZLC','ZZCC','ZZR','ZZTIN'),
       (990002,'ZZ01','ZZ01','ZZLED01','P','ZZ Party','ZZ Party Regional','ZZ Addr','zz@example.com','555','zzuser2','zzpw',0,0,0,'ZZLC2','ZZCC2','ZZR','ZZTIN');

INSERT INTO ordermaster (AUTOID,OrganizationCode,BillTypeId,OrderMasterId,OrderNumber,OrderDate,PartyDetails,LedgerId,NoofChair,Status,CreatedByUser,CreatedTimeStamp,TotalAmount,Description)
VALUES (990001,'ZZ01','ZZBT','ZZOM01','ZZON01','2026-07-28 19:18:21','ZZ party','ZZLED01',4,'Z','ZZUSER','2026-07-28 12:00:00',918.75,'ZZ order'),
       (990002,'ZZ01','ZZBT','ZZOM02','ZZON02','2026-07-28 19:18:22','ZZ party','ZZNOSUCHLEDGER',0,'Z','ZZUSER','2026-07-28 12:00:00',0,'ZZ empty order');

INSERT INTO orderdetails (ordermstr_id,InventoryDetailsId,UnitId,Quantity,Rate,TotalAmount,Description,CreatedByUser,CreatedTimeStamp)
VALUES ('ZZOM01','ZZINVENTORYDETAILS0000000001','ZZU',2,100.5,201,'ZZ line 1','ZZUSER','2026-07-28 12:00:00'),
       ('ZZOM01','ZZINV2','ZZU',1,717.75,717.75,'ZZ line 2','ZZUSER','2026-07-28 12:00:00');

INSERT INTO ordercancelmaster (AUTOID,OrganizationCode,BillTypeId,OrderCancelMasterId,OrderCancelNumber,OrderCancelDate,OrderMasterId,PartyDetails,LedgerId,Status,CreatedByUser,CreatedTimeStamp,TotalAmount,Description)
VALUES (990003,'ZZ01','ZZBT','ZZOC01','ZZOCN01','2026-07-28 19:18:23','ZZOM01','ZZ party','ZZLED01','Z','ZZUSER','2026-07-28 12:00:00',201,'ZZ cancel');

INSERT INTO ordercanceldetails (OrderCancelMasterId,OrderDetailsId,InventoryDetailsId,UnitId,Quantity,Rate,TotalAmount,Description,CreatedByUser,CreatedTimeStamp)
VALUES ('ZZOC01',1,'ZZINVENTORYDETAILS0000000001','ZZU',2,100.5,201,'ZZ cancel line','ZZUSER','2026-07-28 12:00:00');

INSERT INTO salemaster (AUTOID,OrganizationCode,BillTypeId,OrderMasterId,LedgerId,PartyDetails,VoucherDate,Status,GrossAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,DiscountPercentage,DiscountAmount,RoundOffAmount,TotalAmount,PaidAmount,CreatedByUser,CreatedTimeStamp,SaleMasterId,VoucherNumber,Description)
VALUES (990004,'ZZ01','ZZBT','ZZOM01,ZZOM02','ZZLED01','ZZ party','2026-07-28 19:18:24','Z',900,'ZZTAX',900,5,45,0,0,0.25,945.25,945.25,'ZZUSER','2026-07-28 12:00:00','ZZSM01','ZZVN01','ZZ sale');

INSERT INTO salesdetails (SaleMasterId,InventoryDetailsId,UnitId,Quantity,Rate,GrossAmount,DiscountPercentage,DiscountAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,TotalAmount,CreatedByUser,CreatedTimeStamp,Description,AddTaxId,AddTaxPercentage,AddTaxAmount,AddTaxId1,AddTaxPercentage1,AddTaxAmount1)
VALUES ('ZZSM01','ZZINVENTORYDETAILS0000000001','ZZU',2,450,900,0,0,'ZZTAX',900,5,45,945,'ZZUSER','2026-07-28 12:00:00','ZZ sale line','ZZAT',0,0,'ZZAT1',0,0);

INSERT INTO salereturn (AUTOID,OrganizationCode,BillTypeId,SaleMasterId,LedgerId,PartyDetails,VoucherDate,Status,GrossAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,DiscountPercentage,DiscountAmount,TotalAmount,PaidAmount,CreatedByUser,CreatedTimeStamp,SaleReturnMasterId,ReturnNumber,Description)
VALUES (990005,'ZZ01','ZZBT','ZZSM01','ZZLED01','ZZ party','2026-07-28 19:18:26','Z',450,'ZZTAX',450,5,22.5,0,0,472.5,472.5,'ZZUSER','2026-07-28 12:00:00','ZZSR01','ZZRN01','ZZ return');

INSERT INTO salesreturndetails (SaleReturnMasterId,InventoryDetailsId,UnitId,Quantity,Rate,GrossAmount,DiscountPercentage,DiscountAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,TotalAmount,CreatedByUser,CreatedTimeStamp,Description,AddTaxId,AddTaxPercentage,AddTaxAmount,AddTaxId1,AddTaxPercentage1,AddTaxAmount1)
VALUES ('ZZSR01','ZZINVENTORYDETAILS0000000001','ZZU',1,450,450,0,0,'ZZTAX',450,5,22.5,472.5,'ZZUSER','2026-07-28 12:00:00','ZZ return line','ZZAT',0,0,'ZZAT1',0,0);

INSERT INTO purchaseordermaster (AUTOID,OrganizationCode,BillTypeId,ordermasterId,OrderNumber,OrderDate,PartyDetails,LedgerId,Status,CreatedByUser,CreatedTimeStamp,TotalAmount,Description)
VALUES (990006,'ZZ01','ZZBT','ZZPO01','ZZPON01','2026-07-28 19:18:27','ZZ supplier','ZZLED01','Z','ZZUSER','2026-07-28 12:00:00',500,'ZZ po');

INSERT INTO purchaseorderdetails (ordermstr_id,InventoryDetailsId,UnitId,OrderQuantity,Rate,TotalAmount,Description,CreatedByUser,CreatedTimeStamp,UpdatedQuantity)
VALUES ('ZZPO01','ZZINVENTORYDETAILS0000000001','ZZU',10,50,500,'ZZ received line','ZZUSER','2026-07-28 12:00:00',7),
       ('ZZPO01','ZZINVZERO','ZZU',5,50,250,'ZZ zeroed line','ZZUSER','2026-07-28 12:00:00',0);

INSERT INTO receipt (AUTOID,BillTypeId,ReceiptId,ToLedgerId,ToLedgerDetails,FromLedgerId,FromLedgerDetails,VoucherDate,Amount,Adjustment,Status,CreatedByUser,CreatedTimeStamp,ReceiptNumber)
VALUES (990007,'ZZBT','ZZRC01','ZZTO','ZZ to details','ZZLED01','ZZ from details','2026-07-28 19:18:28',100.25,1.5,'Z','ZZUSER','2026-07-28 12:00:00','ZZRN01');

INSERT INTO payment (AUTOID,PaymentId,FromLedgerId,FromLedgerDetails,ToLedgerId,ToLedgerDetails,BillTypeId,Amount,PaymentNumber,VoucherDate,Status,CreatedByUser,CreatedTimeStamp)
VALUES (990008,'ZZPY01','ZZFROM','ZZ from details','ZZLED01','ZZ to details','ZZBT',200.5,'ZZPN01','2026-07-28 19:18:29','Z','ZZUSER','2026-07-28 12:00:00');

INSERT INTO journal (AUTOID,JournalId,FromLedgerId,FromLedgerDetails,ToLedgerId,ToLedgerDetails,BillTypeId,Amount,JournalNumber,VoucherDate,Status,CreatedByUser,CreatedTimeStamp)
VALUES (990009,'ZZJV01','ZZFROM','ZZ from details','ZZTO','ZZ to details','ZZBT',300.75,'ZZJN01','2026-07-28 19:18:30','Z','ZZUSER','2026-07-28 12:00:00');

INSERT INTO pdcdetails (OrganizationCode,AUTOID,PDCDetailsId,PDCNumber,VoucherDate,PartyLedgerId,BankLedgerId,PaymentMode,Amount,Type,ChequeNumber,ChequeDate,ReferenceId,Status,CreatedByUser,CreatedTimeStamp)
VALUES ('ZZ01',990010,'ZZPDC01','ZZPN01','2026-07-28 19:18:25','ZZLED01','ZZBANK','CQ',945.25,'R','ZZCHQ001','2026-07-28','ZZSM01','Z','ZZUSER','2026-07-28 12:00:00'),
       ('ZZ01',990011,'ZZPDC02','ZZPN02','2026-07-28 19:18:31','ZZLED01','ZZBANK','CD',50,'P','ZZCHQ002','2026-07-28','','Z','ZZUSER','2026-07-28 12:00:00');
'@
    Invoke-MysqlFile $sql
    # PostgreSQL needs every identifier quoted. Column lists and the tail of each
    # table name are the only bare identifiers in the text above.
    $pg = [regex]::Replace($sql, '(?m)^INSERT INTO (\w+) \(([^)]*)\)', {
        param($m)
        $cols = ($m.Groups[2].Value -split ',' | ForEach-Object { '"' + $_.Trim() + '"' }) -join ','
        "INSERT INTO $($m.Groups[1].Value) ($cols)"
    })
    Invoke-Psql -Quiet $pg
}

function Set-StockSource {
    param([string]$Value)
    & $Mysql -u root fireflydb -e "INSERT INTO settings_common (``key``,``value``) VALUES ('stock_source','$Value') ON DUPLICATE KEY UPDATE ``value``='$Value';" 2>&1 | Out-Null
    Invoke-Psql -Quiet "INSERT INTO settings_common (`"key`",`"value`") VALUES ('stock_source','$Value') ON CONFLICT (`"key`") DO UPDATE SET `"value`" = EXCLUDED.`"value`";"
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

# Strips anything before the first '{' -- for endpoints where PHP echoes its raw
# SQL ahead of the JSON, leaving a body that is not valid JSON at all.
function Get-JsonTail {
    param([string]$Body)
    $i = $Body.IndexOf('{')
    if ($i -lt 0) { return $Body }
    return $Body.Substring($i)
}

<#
    Mode 'Bytes'  - responses must be byte-identical.
    Mode 'Status' - only the STATUS field must agree. Used where both sides fail
                    for the same reason but each leaks its own driver's wording
                    (MySQL "Column 'X' cannot be null" vs PostgreSQL's not-null
                    violation text). Behaviour matches; the message tail does not.
    Mode 'Json'   - the JSON tails must be byte-identical, ignoring any raw-SQL
                    prefix. The port emits clean JSON unless FFAPI_ECHO_SQL=1,
                    so this is the meaningful comparison for insert_productwtimage
                    in its default configuration. Run with -EchoSql to demand
                    full byte equality instead.
#>
function Compare-Case {
    param(
        [string]$Name,
        [hashtable]$Body,
        [string]$Method = 'POST',
        [ValidateSet('Bytes','Status','Json')][string]$Mode = 'Bytes'
    )

    $php  = Invoke-Endpoint -Url $PhpUrl  -Body $Body -Method $Method
    $next = Invoke-Endpoint -Url $NextUrl -Body $Body -Method $Method

    if ($Mode -eq 'Bytes') {
        $same = ($php.Body -ceq $next.Body) -and ($php.Status -eq $next.Status)
    } elseif ($Mode -eq 'Json') {
        $same = ((Get-JsonTail $php.Body) -ceq (Get-JsonTail $next.Body)) -and ($php.Status -eq $next.Status)
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

# ---------------------------------------------------------------------------
# insert_productwtimage
# ---------------------------------------------------------------------------

<#
    A full 29-field payload, shaped exactly like the live traffic in
    c:\xampp\htdocs\ffapi\logs -- every value a string, isVeg always the literal
    "false", and the numeric-looking fields sent as "0.00" even where the column
    is an integer. Those are the cases the coercion helpers exist for, so the
    defaults deliberately keep them.
#>
function New-ProductBody {
    param(
        [string]$Inv = $TestInv,
        [string]$Name = 'Pilot Test Product',
        [string]$CurrentStock = '0.00',
        [string]$Stock = $null
    )
    $body = @{
        api                 = 'insert_productwtimage'
        OrganizationCode    = 'MMKP'
        ProductName         = $Name
        ProductRegionalName = ''
        Barcode             = '1800001'
        CustomBarcode       = ''
        Code                = '**'
        UnitId              = 'MMKP-MMKP-0000000010'
        UnitName            = 'Number'
        UnitShortName       = 'No'
        UnitRegionalName    = ''
        InventoryDetailsId  = $Inv
        InventoryGroupId    = 'MMKP-MMKP-0000000002'
        MRP                 = '0.00'
        SaleRate            = '47.62'
        MOP                 = '0.00'
        MLOP                = '0.00'
        PurchaseRate        = '0.00'
        AvgRate             = '0.00'
        LastPurchaseRate    = '0.00'
        isVeg               = 'false'
        Description         = ''
        CurrentStock        = $CurrentStock
        OrderLimit          = '10'
        TaxId               = 'MMKP-MMKP-0000000005'
        AddTaxId            = ''
        AddTaxId1           = ''
        HSNCode             = ''
        Size                = ''
        Colour              = ''
    }
    if ($Stock) {
        $body['Inventoriesstock'] = '[{"InventoryDetailsId":"' + $Inv +
            '","WarehouseId":"WH1","Warehouse":"Main","Stock":"' + $Stock +
            '","UnitShortName":"No"}]'
    }
    return $body
}

$ProductMode = if ($EchoSql) { 'Bytes' } else { 'Json' }

Write-Host "`n=== insert_productwtimage parity ===" -ForegroundColor White
if ($EchoSql) {
    Write-Host "    comparing FULL BYTES incl. the echoed SQL prefix (FFAPI_ECHO_SQL=1 expected on :3000)`n" -ForegroundColor DarkGray
} else {
    Write-Host "    comparing JSON tails; PHP prefixes raw SQL, the port emits clean JSON (see -EchoSql)`n" -ForegroundColor DarkGray
}
Reset-ProductRows

# 10. New product -> the INSERT branch. Also the ImagePath test: the column is
#     omitted from the INSERT entirely, so it must land as '' on both sides.
Compare-Case -Name '10. INSERT new product' -Body (New-ProductBody) -Mode $ProductMode

# 11. Same InventoryDetailsId again -> the UPDATE branch.
Compare-Case -Name '11. UPDATE existing product' -Body (New-ProductBody -Name 'Pilot Test Product RENAMED') -Mode $ProductMode

# 12. A save that changes nothing. PostgreSQL rowCount counts MATCHED rows so
#     this stays on the update path; MySQL's affected_rows would say 0.
Compare-Case -Name '12. UPDATE with no actual change' -Body (New-ProductBody -Name 'Pilot Test Product RENAMED') -Mode $ProductMode

# 13. Integer column fed a decimal string, as the ERP really sends it.
Compare-Case -Name '13. CurrentStock "12.7" into an int column' -Body (New-ProductBody -CurrentStock '12.7') -Mode $ProductMode

# 14. With a stock payload. Under the default stock_source='APP' both sides must
#     skip the warehousestock write entirely.
Compare-Case -Name '14. With Inventoriesstock (stock_source=APP)' -Body (New-ProductBody -Stock '5') -Mode $ProductMode

# 15. Missing required fields -> NULL into NOT NULL. Both must reject; each
#     reports it in its own driver's words, and PHP swallows the error and still
#     claims success, so only the resulting DB state is comparable here.
$partialProd = New-ProductBody -Inv $TestInv2
$partialProd.Remove('ProductName')
$partialProd.Remove('Barcode')
Compare-Case -Name '15. Missing fields' -Body $partialProd -Mode 'Status'

Write-Host "`n--- 16. Stored product comparison ($TestInv) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT InventoryDetailsId, ProductName, CAST(isVeg AS UNSIGNED) AS isVeg, CurrentStock, OrderLimit, CONCAT('[',ImagePath,']') AS ImagePath FROM product WHERE InventoryDetailsId='$TestInv';"
Invoke-Psql "SELECT `"InventoryDetailsId`", `"ProductName`", `"isVeg`", `"CurrentStock`", `"OrderLimit`", '['||`"ImagePath`"||']' AS `"ImagePath`" FROM product WHERE `"InventoryDetailsId`" = '$TestInv';"

Write-Host "--- 17. warehousestock rows (expect NONE on both, stock_source=APP) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT COUNT(*) AS mysql_rows FROM warehousestock WHERE InventoryDetailsId LIKE 'ZZTEST%';"
Invoke-Psql "SELECT count(*) AS pg_rows FROM warehousestock WHERE `"InventoryDetailsId`" LIKE 'ZZTEST%';"

if ($TestStockErpMode) {
    Write-Host "`n--- 18. warehousestock path with stock_source='ERP' ---" -ForegroundColor Magenta
    Write-Host "      temporarily flipping stock_source in BOTH databases" -ForegroundColor DarkGray
    try {
        Set-StockSource -Value 'ERP'
        Reset-ProductRows
        Compare-Case -Name '18. Product + stock, ERP mode' -Body (New-ProductBody -Stock '7.5') -Mode $ProductMode
        & $Mysql -u root fireflydb -e "SELECT InventoryDetailsId, WarehouseId, Warehouse, CurrentStock, Unit FROM warehousestock WHERE InventoryDetailsId LIKE 'ZZTEST%';"
        Invoke-Psql "SELECT `"InventoryDetailsId`", `"WarehouseId`", `"Warehouse`", `"CurrentStock`", `"Unit`" FROM warehousestock WHERE `"InventoryDetailsId`" LIKE 'ZZTEST%';"
    } finally {
        # Restore no matter what: 'APP' is the live production setting.
        Set-StockSource -Value 'APP'
        Write-Host "      stock_source restored to 'APP'" -ForegroundColor DarkGray
    }
}

Reset-ProductRows

# ---------------------------------------------------------------------------
# Master data: billtype, category, taxdetails, ledger, rout, user, privileges
#
# Unlike organization, these endpoints report failure with a fixed MESSAGE
# string rather than the driver's error text, so even the rejection cases can be
# compared byte for byte instead of only by STATUS.
# ---------------------------------------------------------------------------

# Booleans, not strings -- the ERP really sends the permission flags this way,
# and reproducing PDO::PARAM_STR's true->"1" / false->"" is the whole reason
# phpStr exists. A plain String() would store zeros across the board here.
$ViewPrivilegesJson = '[{"ViewName":"ZZView1","CanRead":true,"CanCreate":false,"CanUpdate":true,"CanDelete":false,"CanPrint":true,"CanEditRate":false,"MRP":true,"MOP":false,"MLOP":true,"SaleRate":false,"AvgRate":true,"PurchaseRate":false,"LastPurchaseRate":true,"Size":false,"Colour":true,"RateSelection":false}]'
$PrivilegesJson = '[{"UserId":"' + $TestUser + '","LedgerId":"' + $TestLedger + '","BlockTransactions":true}]'

function New-BillTypeBody {
    param([string]$Name = 'Pilot Bill Type', [string]$Start = '1')
    return @{
        api              = 'insert_billtype'
        OrganizationCode = $TestOrg
        BillTypeId       = $TestBill
        BillTypeName     = $Name
        StartNumber      = $Start
        Prefix           = 'ZZ'
        Suffix           = ''
        TaxType          = 'OP'
        VoucherType      = 'SI'
        CreatedByUser    = $TestUser
    }
}

function New-CategoryBody {
    param(
        [string]$Api   = 'insert_categorywtimage',
        [string]$Group = 'Pilot Category',
        [string]$Image
    )
    $b = @{
        api              = $Api
        OrganizationCode = $TestOrg
        InventoryGroupId = $TestCat
        GroupName        = $Group
        ParentGroup      = ''
        Colour           = '#FFFFFF'
    }
    if ($PSBoundParameters.ContainsKey('Image')) { $b['ImagePath'] = $Image }
    return $b
}

function New-TaxBody {
    param([string]$Name = 'Pilot Tax', [string]$Rate = '5.000', [string]$Id = $TestTax)
    return @{
        api             = 'insert_taxdetails'
        TaxId           = $Id
        TaxName         = $Name
        Rate            = $Rate
        CalculatingMode = 'OP'
        TaxType         = 'I'
    }
}

function New-LedgerBody {
    param(
        [string]$Ledger   = $TestLedger,
        [string]$Name     = 'Pilot Ledger',
        [string]$Balance  = '100.50',
        [string]$Rout     = $TestRout,
        [string]$RoutName = 'ZZ Pilot Rout',
        [string]$User     = 'zzledgeruser',
        [string]$Password = 'zzledgersecret'
    )
    return @{
        api              = 'insert_ledger'
        OrganizationCode = $TestOrg
        LedgerId         = $Ledger
        LedgerType       = 'P'
        LedgerName       = $Name
        RegionalName     = ''
        LedgerCode       = 'ZZLC01'
        CustomCode       = ''
        TINNumber        = ''
        Address          = '1 Test Road'
        Email            = 'ledger@example.com'
        Phone            = '9876543210'
        UserName         = $User
        mypassword       = $Password
        noofseats        = '0'
        seatstaken       = '0'
        RoutId           = $Rout
        RoutName         = $RoutName
        CurrentBalance   = $Balance
        IsActive         = '1'
    }
}

function New-UserBody {
    param([string]$Name = 'Pilot User', [string]$Id = $TestUser)
    return @{
        api                = 'insert_user'
        OrganizationCode   = $TestOrg
        UserId             = $Id
        Name               = $Name
        UserName           = 'zzuser'
        Password           = 'zzsecret'
        Phone              = '9876543210'
        DefSOBillType      = ''
        DefSOCBillType     = ''
        DefSIBillType      = ''
        DefRVBillType      = ''
        DefPVBillType      = ''
        DefPOBillType      = ''
        DefSRBillType      = ''
        DefJVBillType      = ''
        SaleTaxIncDiscount = '0'
        DefCashLedger      = ''
        DefCardBank        = ''
        RoutId             = $TestRout
        UseOnlyRoutLedgers = '0'
        IsAdmin            = '1'
        DefSaleRate        = ''
        DefWarehouseId     = ''
        Privileges         = $PrivilegesJson
        ViewPrivileges     = $ViewPrivilegesJson
    }
}

Write-Host "`n=== insert_billtype parity ===`n" -ForegroundColor White
Reset-MasterRows

Compare-Case -Name '19. INSERT new billtype' -Body (New-BillTypeBody)
Compare-Case -Name '20. UPDATE existing billtype' -Body (New-BillTypeBody -Name 'Pilot Bill Type RENAMED')
# StartNumber is int(11) and the ERP sends decimal strings. MySQL rounds half
# away from zero; mysqlInt reproduces it. "12.7" must land as 13 on both.
Compare-Case -Name '21. StartNumber "12.7" into an int column' -Body (New-BillTypeBody -Start '12.7')

# The live insert_billtype reads $_POST['TaxType'] unguarded -- only the
# commented-out earlier version defaults it to 'OP'. On the INSERT path both
# sides reject a missing field; see cases 54-55 for the UPDATE path, which does
# not behave the same way.
$noTaxType = New-BillTypeBody
$noTaxType['BillTypeId'] = 'ZZBT02'
$noTaxType.Remove('TaxType')
Compare-Case -Name '22. Missing TaxType is rejected (INSERT path)' -Body $noTaxType

Write-Host "`n--- 23. Stored billtype (StartNumber rounding) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT BillTypeId, BillTypeName, StartNumber FROM billtype WHERE BillTypeId='$TestBill';"
Invoke-Psql "SELECT `"BillTypeId`", `"BillTypeName`", `"StartNumber`" FROM billtype WHERE `"BillTypeId`" = '$TestBill';"

Write-Host "`n=== insert_categorywtimage / insert_category parity ===`n" -ForegroundColor White

Compare-Case -Name '24. INSERT new category (wtimage)' -Body (New-CategoryBody)
Compare-Case -Name '25. UPDATE existing category (wtimage)' -Body (New-CategoryBody -Group 'Pilot Category RENAMED')
# insert_category is the variant that writes ImagePath, substituting
# 'no_image.jpg' whenever the posted value is empty().
Compare-Case -Name '26. insert_category with an image' -Body (New-CategoryBody -Api 'insert_category' -Image 'zz_pilot.jpg')
Compare-Case -Name '27. insert_category with empty ImagePath' -Body (New-CategoryBody -Api 'insert_category' -Image '')

Write-Host "`n--- 28. Stored category (ImagePath after the empty-value call) ---" -ForegroundColor Magenta
Write-Host "      expect no_image.jpg on both" -ForegroundColor DarkGray
& $Mysql -u root fireflydb -e "SELECT InventoryGroupId, GroupName, ImagePath FROM category WHERE InventoryGroupId='$TestCat';"
Invoke-Psql "SELECT `"InventoryGroupId`", `"GroupName`", `"ImagePath`" FROM category WHERE `"InventoryGroupId`" = '$TestCat';"

# Now prove "wtimage" really does leave the image alone: run it again and the
# ImagePath written above must survive untouched.
Compare-Case -Name '29. wtimage leaves ImagePath alone' -Body (New-CategoryBody -Group 'Pilot Category FINAL')
Write-Host "--- 30. ImagePath after the wtimage call (expect no_image.jpg still) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT InventoryGroupId, GroupName, ImagePath FROM category WHERE InventoryGroupId='$TestCat';"
Invoke-Psql "SELECT `"InventoryGroupId`", `"GroupName`", `"ImagePath`" FROM category WHERE `"InventoryGroupId`" = '$TestCat';"

Write-Host "`n=== insert_taxdetails parity ===`n" -ForegroundColor White

Compare-Case -Name '31. INSERT new tax' -Body (New-TaxBody)
Compare-Case -Name '32. UPDATE existing tax' -Body (New-TaxBody -Name 'Pilot Tax RENAMED')
# Rate is decimal(10,3); PostgreSQL rejects '' where MySQL substitutes 0.
Compare-Case -Name '33. Empty Rate into a decimal column' -Body (New-TaxBody -Rate '')

# A *new* TaxId, so this takes the INSERT path where both engines reject.
$noTaxName = New-TaxBody -Id 'ZZTAX02'
$noTaxName.Remove('TaxName')
Compare-Case -Name '34. Missing TaxName is rejected (INSERT path)' -Body $noTaxName

Write-Host "`n--- 35. Stored tax (Rate after the empty-value call) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT TaxId, TaxName, Rate FROM taxdetails WHERE TaxId='$TestTax';"
Invoke-Psql "SELECT `"TaxId`", `"TaxName`", `"Rate`" FROM taxdetails WHERE `"TaxId`" = '$TestTax';"

Write-Host "`n=== insert_ledger / update_ledgerCurrentBalance parity ===`n" -ForegroundColor White

Compare-Case -Name '36. INSERT new ledger (+ rout)' -Body (New-LedgerBody)
# The UPDATE branch omits UserName and mypassword entirely, so these new values
# must be ignored while LedgerName changes.
Compare-Case -Name '37. UPDATE existing ledger' -Body (New-LedgerBody -Name 'Pilot Ledger RENAMED' -User 'CHANGED' -Password 'CHANGED')

Write-Host "`n--- 38. Stored ledger: credentials must survive the update ---" -ForegroundColor Magenta
Write-Host "      expect UserName=zzledgeruser, mypassword=zzledgersecret, CentreCode=ZZLG on both" -ForegroundColor DarkGray
& $Mysql -u root fireflydb -e "SELECT LedgerId, CentreCode, LedgerName, UserName, mypassword, CurrentBalance FROM ledger WHERE LedgerId='$TestLedger';"
Invoke-Psql "SELECT `"LedgerId`", `"CentreCode`", `"LedgerName`", `"UserName`", `"mypassword`", `"CurrentBalance`" FROM ledger WHERE `"LedgerId`" = '$TestLedger';"

# CentreCode is explode('-', LedgerId)[1]. With no hyphen that index is undefined
# -> null -> NOT NULL violation, so insert_ledger returns FALSE on both stacks.
Compare-Case -Name '39. LedgerId with no hyphen fails on CentreCode' -Body (New-LedgerBody -Ledger 'ZZNOHYPHEN01')

# PHP's empty() counts the string "0" as empty, so insert_rout skips the INSERT.
Compare-Case -Name '40. RoutId "0" skips the rout insert' -Body (New-LedgerBody -Rout '0' -RoutName 'ZZGuardRout')
Write-Host "--- 41. rout rows named ZZGuardRout (expect NONE on both) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT COUNT(*) AS mysql_rows FROM rout WHERE Name='ZZGuardRout';"
Invoke-Psql "SELECT count(*) AS pg_rows FROM rout WHERE `"Name`" = 'ZZGuardRout';"

Compare-Case -Name '42. update_ledgerCurrentBalance' -Body @{
    api = 'update_ledgerCurrentBalance'; LedgerId = $TestLedger; CurrentBalance = '4321.75'
}
# UPDATE-only and unchecked: a LedgerId matching nothing still reports success.
Compare-Case -Name '43. update_ledgerCurrentBalance, unknown ledger' -Body @{
    api = 'update_ledgerCurrentBalance'; LedgerId = 'ZZNOSUCHLEDGER'; CurrentBalance = '1.00'
}

Write-Host "`n--- 44. Stored CurrentBalance (expect 4321.75000000 on both) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT LedgerId, CurrentBalance FROM ledger WHERE LedgerId='$TestLedger';"
Invoke-Psql "SELECT `"LedgerId`", `"CurrentBalance`" FROM ledger WHERE `"LedgerId`" = '$TestLedger';"

Write-Host "`n=== insert_user / get_userprivilegeslist parity ===`n" -ForegroundColor White

Compare-Case -Name '45. INSERT new user (+ both privilege writes)' -Body (New-UserBody)
Compare-Case -Name '46. UPDATE existing user' -Body (New-UserBody -Name 'Pilot User RENAMED')

# The real assertion for phpStr: read the flags back through both stacks. The
# payload sent CanRead:true / CanCreate:false as JSON booleans, so this must come
# back as true/false in the same pattern on both sides. Binding them with a plain
# String() would store 0 everywhere and show up here as all-false.
Compare-Case -Name '47. get_userprivilegeslist reflects the boolean flags' -Body @{
    api = 'get_userprivilegeslist'; UserId = $TestUser
}

# No rows -> PHP's $data_array is never initialised and DATA lands as null, with
# STATUS still SUCCESS. Not [], and not an error.
Compare-Case -Name '48. get_userprivilegeslist for an unknown user (DATA null)' -Body @{
    api = 'get_userprivilegeslist'; UserId = 'ZZNOSUCHUSER'
}

# A *new* UserId, so this takes the INSERT path where both engines reject.
$noUserName = New-UserBody -Id 'ZZUSER02'
$noUserName.Remove('UserName')
Compare-Case -Name '49. Missing user field is rejected (INSERT path)' -Body $noUserName

Write-Host "`n--- 50. Stored userledgerprivilege (Block from JSON true -> 1) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT UserId, LedgerId, Block FROM userledgerprivilege WHERE UserId='$TestUser';"
Invoke-Psql "SELECT `"UserId`", `"LedgerId`", `"Block`" FROM userledgerprivilege WHERE `"UserId`" = '$TestUser';"

Write-Host "--- 51. Stored user.RoutId (the renamed column) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT UserId, Name, RoutId, IsAdmin FROM ``user`` WHERE UserId='$TestUser';"
Invoke-Psql "SELECT `"UserId`", `"Name`", `"RoutId`", `"IsAdmin`" FROM `"user`" WHERE `"UserId`" = '$TestUser';"

# The privilege insert is guarded on the user existing, so a payload for an
# unknown user must write nothing on either side while still reporting success.
Compare-Case -Name '52. insert_userprivileges for an unknown user' -Body @{
    api = 'insert_userprivileges'; UserId = 'ZZGHOSTUSER'; ViewPrivileges = $ViewPrivilegesJson
}
Write-Host "--- 53. userprivilege rows for ZZGHOSTUSER (expect NONE on both) ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT COUNT(*) AS mysql_rows FROM userprivilege WHERE UserId='ZZGHOSTUSER';"
Invoke-Psql "SELECT count(*) AS pg_rows FROM userprivilege WHERE `"UserId`" = 'ZZGHOSTUSER';"

<#
    54-55. Missing field on the UPDATE path. KNOWN DIVERGENCE, not asserted.

    Non-strict MySQL rejects NULL into a NOT NULL column on INSERT (error 1048)
    but silently coerces it to '' on UPDATE and reports success. Verified
    directly:

        INSERT INTO t (k,v) VALUES ('b', NULL);   -- ERROR 1048
        UPDATE t SET v = NULL WHERE k = 'a';      -- OK, v becomes ''

    PostgreSQL rejects both. The organization pilot only ever exercised the
    INSERT path, which is why the README recorded "MySQL rejects them" without
    qualification. See README "Known divergences".
#>
Write-Host "`n--- 54-55. Missing field on the UPDATE path (known divergence, informational) ---" -ForegroundColor Magenta
Write-Host "      MySQL blanks the column and reports SUCCESS; PostgreSQL rejects the write" -ForegroundColor DarkGray

$updateNoTaxName = New-TaxBody          # $TestTax already exists -> UPDATE path
$updateNoTaxName.Remove('TaxName')
$phpTax  = Invoke-Endpoint -Url $PhpUrl  -Body $updateNoTaxName
$nextTax = Invoke-Endpoint -Url $NextUrl -Body $updateNoTaxName
Write-Host "      54. insert_taxdetails, TaxName omitted" -ForegroundColor DarkGray
Write-Host "          PHP  $($phpTax.Body)"  -ForegroundColor Yellow
Write-Host "          NEXT $($nextTax.Body)" -ForegroundColor Cyan

$updateNoUserName = New-UserBody        # $TestUser already exists -> UPDATE path
$updateNoUserName.Remove('UserName')
$phpUsr  = Invoke-Endpoint -Url $PhpUrl  -Body $updateNoUserName
$nextUsr = Invoke-Endpoint -Url $NextUrl -Body $updateNoUserName
Write-Host "      55. insert_user, UserName omitted" -ForegroundColor DarkGray
Write-Host "          PHP  $($phpUsr.Body)"  -ForegroundColor Yellow
Write-Host "          NEXT $($nextUsr.Body)" -ForegroundColor Cyan

Write-Host "      resulting rows -- MySQL will show a blanked column, PostgreSQL the old value:" -ForegroundColor DarkGray
& $Mysql -u root fireflydb -e "SELECT TaxId, CONCAT('[',TaxName,']') AS TaxName FROM taxdetails WHERE TaxId='$TestTax';"
Invoke-Psql "SELECT `"TaxId`", '['||`"TaxName`"||']' AS `"TaxName`" FROM taxdetails WHERE `"TaxId`" = '$TestTax';"

Reset-MasterRows

# ---------------------------------------------------------------------------
# The sync loop: the 11 reads the ERP polls and the 13 writes that acknowledge
# them. Cases 56-92.
#
# Every read is compared with Status=Z, which no production row carries, so the
# assertions see only the seeded fixtures even though live MySQL holds real
# documents and PostgreSQL holds none.
# ---------------------------------------------------------------------------

Reset-SyncRows
Seed-SyncRows

$syncReads = @(
    @{ N = '56'; Api = 'get_ordermaster';                   What = 'master + details, and a master with no details' }
    @{ N = '57'; Api = 'get_ordercancelmaster';             What = 'the phantom NoofChair key, always null' }
    @{ N = '58'; Api = 'get_salemaster';                    What = 'SaleDetails + PdcDetails, LIMIT 100' }
    @{ N = '59'; Api = 'get_salereturnmaster';              What = 'the crossed OrdermstrID/SaleMasterID keys' }
    @{ N = '60'; Api = 'get_purchaseordermasterforFireFly'; What = 'UpdatedQuantity AS Quantity, zeroed lines excluded' }
    @{ N = '61'; Api = 'get_receipt';                       What = 'flat read, carries Adjustment' }
    @{ N = '62'; Api = 'get_payment';                       What = 'the payment id ships under the ReceiptId key' }
    @{ N = '63'; Api = 'get_journal';                       What = 'flat read' }
    @{ N = '64'; Api = 'get_pdcorcarddetails';              What = 'standalone cheques only (ReferenceId = "")' }
    @{ N = '65'; Api = 'get_pdcorcarddetailsforclearance';  What = 'same, without the ReferenceId predicate' }
)
foreach ($r in $syncReads) {
    Compare-Case -Name "$($r.N). $($r.Api) -- $($r.What)" -Body @{ api = $r.Api; Status = 'Z' }
}

# 66-75. The same ten reads with a Status nothing matches. DATA must be null and
# STATUS must still be SUCCESS -- the PHP master getters return the string
# 'EMPTY', foreach over a string only warns, and $data_array is never
# initialised. Not [].
$n = 66
foreach ($r in $syncReads) {
    Compare-Case -Name "$n. $($r.Api) with no matching rows (DATA must be null)" -Body @{ api = $r.Api; Status = '9' }
    $n++
}

<#
    76. get_newcustomers.

    The one read with no parameters: it selects every ledger whose LedgerId is
    still '', which is the queue the ERP drains. That makes it the only case here
    that cannot be scoped to the fixtures -- it compares the whole queue, so it
    assumes no *real* customer is sitting unsynced in MySQL. That is true today
    and is why led_id is seeded explicitly: the value reaches the wire as "ID".
#>
Compare-Case -Name '76. get_newcustomers -- ID <- led_id, NativeName <- RegionalName' -Body @{ api = 'get_newcustomers' }

# 77-87. The status updaters, against an id that matches nothing. PHP never looks
# at the affected row count, so a no-match still reports SUCCESS -- that is the
# behaviour being asserted, and it keeps these cases from mutating the fixtures
# the reads above depend on.
Compare-Case -Name '77. update_orderStatus (no match still SUCCEEDS)'  -Body @{ api = 'update_orderStatus';         ordermstr_id = 'ZZNOPE' }
Compare-Case -Name '78. update_ordercancelStatus'                      -Body @{ api = 'update_ordercancelStatus';   ordermstr_id = 'ZZNOPE' }
Compare-Case -Name '79. update_saleStatus'                             -Body @{ api = 'update_saleStatus';          SaleMasterId = 'ZZNOPE' }
Compare-Case -Name '80. update_saleReturnStatus'                       -Body @{ api = 'update_saleReturnStatus';    SaleReturnMasterId = 'ZZNOPE' }
Compare-Case -Name '81. update_purchaseorderStatus'                    -Body @{ api = 'update_purchaseorderStatus'; ordermstr_id = 'ZZNOPE' }
Compare-Case -Name '82. update_receiptStatus (lowercase receiptId)'    -Body @{ api = 'update_receiptStatus';       receiptId = 'ZZNOPE' }
Compare-Case -Name '83. update_paymentStatus (lowercase paymentId)'    -Body @{ api = 'update_paymentStatus';       paymentId = 'ZZNOPE' }
Compare-Case -Name '84. update_journalStatus (lowercase journalId)'    -Body @{ api = 'update_journalStatus';       journalId = 'ZZNOPE' }
Compare-Case -Name '85. update_pdcStatus'                              -Body @{ api = 'update_pdcStatus';           pdcdetailsId = 'ZZNOPE' }
Compare-Case -Name '86. update_pdcClearanceStatus'                     -Body @{ api = 'update_pdcClearanceStatus';  pdcdetailsId = 'ZZNOPE' }
Compare-Case -Name '87. update_pdcdetailsstatus (batch, status from payload)' -Body @{ api = 'update_pdcdetailsstatus'; pdcdetails = '[{"PDCDetailsId":"ZZNOPE"}]'; Status = 'Z' }

# 88. A malformed JSON blob is a no-op that still reports SUCCESS: json_decode
# returns null, foreach over null only warns, and the function returns 'TRUE'.
Compare-Case -Name '88. update_pdcdetailsstatus with a malformed blob' -Body @{ api = 'update_pdcdetailsstatus'; pdcdetails = 'not-json'; Status = 'Z' }

Compare-Case -Name '89. update_ledgersCurrentBalances (batch)' -Body @{ api = 'update_ledgersCurrentBalances'; ledgerdetails = '[{"LedgerId":"ZZNOPE","CurrentBalance":"1.00"}]' }
Compare-Case -Name '90. insert_productwithwarehousestock (standalone case)' -Body @{ api = 'insert_productwithwarehousestock'; Inventoriesstock = '[]' }

<#
    91-92. update_customerledgerId.

    91 uses an ID that matches nothing, so it asserts the envelope without
    touching the fixtures. 92 then runs the real write against the seeded
    led_id and checks what moved: the ledger row must take the assigned
    LedgerId, and the eight child tables must be UNCHANGED.

    That second assertion is the point. The PHP loop compares a varchar ledger
    column against $ID -- the integer led_id -- rather than the previous
    LedgerId, so it matches zero rows every time. A run that showed the child
    tables changing would mean the bug had been "fixed", which would be a
    behaviour change. It also depends on ID being bound as text: bound as a
    number, PostgreSQL raises "operator does not exist: character varying =
    integer" and rolls the whole transaction back.
#>
Compare-Case -Name '91. update_customerledgerId (no match)' -Body @{ api = 'update_customerledgerId'; ID = '999999'; LedgerId = 'ZZX'; CustomCode = 'ZZX'; LedgerCode = 'ZZX' }
Compare-Case -Name '92. update_customerledgerId (real write-back)' -Body @{ api = 'update_customerledgerId'; ID = '990001'; LedgerId = 'ZZASSIGNED'; CustomCode = 'ZZCC9'; LedgerCode = 'ZZLC9' }

Write-Host "--- 92a. ledger row must carry the assigned id on both ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT led_id, CONCAT('[',LedgerId,']') AS LedgerId, CustomCode, LedgerCode FROM ledger WHERE led_id=990001;"
Invoke-Psql "SELECT `"led_id`", '['||`"LedgerId`"||']' AS `"LedgerId`", `"CustomCode`", `"LedgerCode`" FROM ledger WHERE `"led_id`" = 990001;"

Write-Host "--- 92b. child tables must be UNCHANGED -- still ZZLED01 on both ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT 'ordermaster' AS t, LedgerId AS v FROM ordermaster WHERE OrderMasterId='ZZOM01' UNION ALL SELECT 'receipt.From', FromLedgerId FROM receipt WHERE ReceiptId='ZZRC01' UNION ALL SELECT 'payment.To', ToLedgerId FROM payment WHERE PaymentId='ZZPY01' UNION ALL SELECT 'pdc.Party', PartyLedgerId FROM pdcdetails WHERE PDCDetailsId='ZZPDC01';"
Invoke-Psql @'
SELECT 'ordermaster' AS t, "LedgerId" AS v FROM ordermaster WHERE "OrderMasterId" = 'ZZOM01'
UNION ALL SELECT 'receipt.From', "FromLedgerId"  FROM receipt    WHERE "ReceiptId"    = 'ZZRC01'
UNION ALL SELECT 'payment.To',   "ToLedgerId"    FROM payment    WHERE "PaymentId"    = 'ZZPY01'
UNION ALL SELECT 'pdc.Party',    "PartyLedgerId" FROM pdcdetails WHERE "PDCDetailsId" = 'ZZPDC01';
'@

Reset-SyncRows

Write-Host "`n=== $script:Pass passed, $script:Fail failed ===`n" -ForegroundColor White
if ($script:Fail -gt 0) { exit 1 }
