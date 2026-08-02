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
    The ordered JSON key list of DATA[0], for Mode 'Keys'.

    -Path walks into a nested array before reading the keys, so
    'products' gives the keys of DATA[0].products[0].

    ConvertFrom-Json preserves property order in PowerShell 5.1, which is what
    makes this a meaningful assertion: it catches a dropped column, a misspelled
    alias, or a column emitted in the wrong position.
#>
function Get-DataKeys {
    param([string]$Body, [string]$Path = '')
    try { $o = (Get-JsonTail $Body) | ConvertFrom-Json } catch { return '(unparseable)' }
    $d = $o.DATA
    if ($d -isnot [array] -or $d.Count -eq 0) { return "(no rows) $($o.STATUS) $($o.MESSAGE)" }
    $row = $d[0]
    foreach ($seg in ($Path -split '\.' | Where-Object { $_ })) {
        $row = $row.$seg
        if ($row -is [array]) {
            if ($row.Count -eq 0) { return '(no nested rows)' }
            $row = $row[0]
        }
    }
    return ($row.PSObject.Properties.Name -join ',')
}

<#
    DATA as an order-insensitive multiset of rows, for Mode 'Set'.

    Each row is re-serialised compactly and the list is sorted, so two responses
    carrying the same rows in a different order compare equal.
#>
function Get-DataRowSet {
    param([string]$Body)
    try { $o = (Get-JsonTail $Body) | ConvertFrom-Json } catch { return '(unparseable)' }
    $d = $o.DATA
    if ($d -isnot [array]) { return "(not an array) $($o.STATUS) $($o.MESSAGE) $($o.DATA)" }
    return (($d | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }) | Sort-Object) -join "`n"
}

<#
    Mode 'Bytes'  - responses must be byte-identical.
    Mode 'Set'    - DATA must hold the same rows, in any order. For the reads
                    whose PHP query carries no ORDER BY, where row order is
                    engine-determined and genuinely differs between MySQL and
                    PostgreSQL. Asserts every value of every row; only the
                    sequence is excused. See "Known divergences" in the README.
    Mode 'Keys'   - the ordered JSON key list of DATA[0] must agree, for reads
                    whose row sets cannot be made identical across the two
                    databases (get_ledgers and friends read whole tables with no
                    Status or date filter to scope them). Pair it with a
                    zero-row 'Bytes' case, which asserts the envelope exactly.
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
        [ValidateSet('Bytes','Status','Json','Keys','Set')][string]$Mode = 'Bytes',
        [string]$KeyPath = ''
    )

    $php  = Invoke-Endpoint -Url $PhpUrl  -Body $Body -Method $Method
    $next = Invoke-Endpoint -Url $NextUrl -Body $Body -Method $Method

    if ($Mode -eq 'Bytes') {
        $same = ($php.Body -ceq $next.Body) -and ($php.Status -eq $next.Status)
    } elseif ($Mode -eq 'Json') {
        $same = ((Get-JsonTail $php.Body) -ceq (Get-JsonTail $next.Body)) -and ($php.Status -eq $next.Status)
    } elseif ($Mode -eq 'Keys') {
        $phpKeys  = Get-DataKeys -Body $php.Body  -Path $KeyPath
        $nextKeys = Get-DataKeys -Body $next.Body -Path $KeyPath
        $same = ($phpKeys -ceq $nextKeys) -and ($php.Status -eq $next.Status)
    } elseif ($Mode -eq 'Set') {
        $same = ((Get-DataRowSet $php.Body) -ceq (Get-DataRowSet $next.Body)) -and ($php.Status -eq $next.Status)
    } else {
        $same = ((Get-Status $php.Body) -ceq (Get-Status $next.Body)) -and ($php.Status -eq $next.Status)
    }

    if ($same) {
        $script:Pass++
        Write-Host "PASS  $Name" -ForegroundColor Green
        if ($Mode -eq 'Bytes') {
            Write-Host "      $($php.Body)" -ForegroundColor DarkGray
        } elseif ($Mode -eq 'Keys') {
            Write-Host "      same keys: $(Get-DataKeys -Body $php.Body -Path $KeyPath)" -ForegroundColor DarkGray
        } elseif ($Mode -eq 'Set') {
            Write-Host "      same rows, order not asserted (no ORDER BY in the PHP)" -ForegroundColor DarkGray
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

# ===========================================================================
# 93-118. The POS billing loop.
#
# Different comparison problems from the sync loop, and each needs its own
# answer:
#
#   - Four reads have no Status or date filter at all, so the two databases can
#     never hold the same rows. Asserted twice: a zero-row case for the exact
#     envelope, and Mode 'Keys' for the column list on real data.
#   - The date-window reads are scoped to the year 2099, which no production
#     row can fall into, so both servers see only these fixtures.
#   - The writes read live state to pick their next number, so the series has
#     to be equalised before every single call. See Reset-WriteSeries.
# ===========================================================================

$PosUser  = 'ZZPOSUSR'
$PosCat   = 'ZZPOSCAT'
$PosInv   = 'ZZPOSINV-000000001'
$PosBill  = 'ZZPBT'      # the read fixtures
$PosWBill = 'ZZWBT'      # insert_orderbybilltype
$PosCBill = 'ZZCBT'      # insert_ordercancelbybilltype
$PosSBill = 'ZZSBT'      # insert_salebybilltypewithpdc

function Set-SettingsKey {
    param([string]$Key, [string]$Value)
    & $Mysql -u root fireflydb -e "INSERT INTO settings_common (``key``,``value``) VALUES ('$Key','$Value') ON DUPLICATE KEY UPDATE ``value``='$Value';" 2>&1 | Out-Null
    Invoke-Psql -Quiet "INSERT INTO settings_common (`"key`",`"value`") VALUES ('$Key','$Value') ON CONFLICT (`"key`") DO UPDATE SET `"value`" = EXCLUDED.`"value`";"
}

function Remove-SettingsKey {
    param([string]$Key)
    & $Mysql -u root fireflydb -e "DELETE FROM settings_common WHERE ``key``='$Key';" 2>&1 | Out-Null
    Invoke-Psql -Quiet "DELETE FROM settings_common WHERE `"key`" = '$Key';"
}

<#
    Row capture for the stored-state assertions.

    Both return headerless, tab-separated text so the two can be compared
    directly. They exist because a stored-row check cannot be done by printing
    each side in turn: the write cases have to reset the series between the PHP
    run and the Next run, and that reset clears BOTH databases -- so MySQL's
    rows are already gone by the time the Next run finishes. Capture each side
    immediately after its own run, then compare the two strings.
#>
function Get-MysqlRows {
    param([string]$Sql)
    $out = & $Mysql -u root fireflydb -N -B -e $Sql 2>&1
    return (($out | Where-Object { $_ -ne '' }) -join "`n")
}

function Get-PgRows {
    param([string]$Sql)
    $env:PGPASSWORD = 'firefly_dev_pw'
    $tmp = Join-Path $env:TEMP ("ffapi_" + [guid]::NewGuid().ToString('N') + ".sql")
    Set-Content -Path $tmp -Value $Sql -Encoding utf8
    try {
        $out = & $Psql -U firefly_app -d fireflydb_test -h localhost -t -A -F "`t" -v ON_ERROR_STOP=1 -f $tmp 2>&1
        return (($out | Where-Object { $_ -ne '' }) -join "`n")
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Assert-SameRows {
    param([string]$Name, [string]$Mysql, [string]$Postgres)
    if ($Mysql -ceq $Postgres) {
        $script:Pass++
        Write-Host "PASS  $Name" -ForegroundColor Green
        foreach ($line in ($Mysql -split "`n")) { Write-Host "      $line" -ForegroundColor DarkGray }
    } else {
        $script:Fail++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      MYSQL $($Mysql -replace "`n", ' | ')" -ForegroundColor Yellow
        Write-Host "      PG    $($Postgres -replace "`n", ' | ')" -ForegroundColor Cyan
    }
}

# A single value out of PostgreSQL, unaligned and untitled. Invoke-Psql prints a
# formatted table, which is right for the eyeball comparisons but useless when
# the value has to be compared in code.
function Get-PgScalar {
    param([string]$Sql)
    $env:PGPASSWORD = 'firefly_dev_pw'
    $tmp = Join-Path $env:TEMP ("ffapi_" + [guid]::NewGuid().ToString('N') + ".sql")
    Set-Content -Path $tmp -Value $Sql -Encoding utf8
    try {
        $out = & $Psql -U firefly_app -d fireflydb_test -h localhost -t -A -v ON_ERROR_STOP=1 -f $tmp 2>&1
        return ($out | Where-Object { $_ -ne '' } | Select-Object -First 1)
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Reset-PosRows {
    $sql = @'
DELETE FROM ordercanceldetails WHERE OrderCancelMasterId LIKE 'ZZPOS%' OR OrderCancelMasterId LIKE 'ZZCBT-%';
DELETE FROM ordercancelmaster  WHERE OrderCancelMasterId LIKE 'ZZPOS%' OR BillTypeId LIKE 'ZZ%';
DELETE FROM orderdetails       WHERE ordermstr_id LIKE 'ZZPOS%' OR ordermstr_id LIKE 'ZZWBT-%';
DELETE FROM ordermaster        WHERE OrderMasterId LIKE 'ZZPOS%' OR BillTypeId LIKE 'ZZ%';
DELETE FROM pdcdetails         WHERE ReferenceId LIKE 'ZZPOS%' OR ReferenceId LIKE 'ZZSBT-%';
DELETE FROM salesdetails       WHERE SaleMasterId LIKE 'ZZPOS%' OR SaleMasterId LIKE 'ZZSBT-%';
DELETE FROM salemaster         WHERE SaleMasterId LIKE 'ZZPOS%' OR BillTypeId LIKE 'ZZ%';
DELETE FROM warehousestock     WHERE InventoryDetailsId LIKE 'ZZPOS%';
DELETE FROM product            WHERE InventoryDetailsId LIKE 'ZZPOS%';
DELETE FROM category           WHERE InventoryGroupId LIKE 'ZZPOS%';
DELETE FROM billtype           WHERE BillTypeId LIKE 'ZZ%';
DELETE FROM ledger             WHERE LedgerId LIKE 'ZZBANK%';
'@
    Invoke-MysqlFile ($sql -replace '`user`', '`user`')
    Invoke-Psql -Quiet ($sql -replace '(?m)WHERE (\w+)', 'WHERE "$1"' -replace '(?m)OR (\w+) LIKE', 'OR "$1" LIKE')
    & $Mysql -u root fireflydb -e "DELETE FROM ``user`` WHERE UserId = '$PosUser';" 2>&1 | Out-Null
    Invoke-Psql -Quiet "DELETE FROM `"user`" WHERE `"UserId`" = '$PosUser';"
}

<#
    Seeds the POS read fixtures into both databases, dated 2099.

    Four orders, chosen so every branch of the cancellation maths is exercised:

      ZZPOSOM-A  lines, no cancellations        -> CancelStatus 'NONE'
      ZZPOSOM-B  one line partly cancelled      -> 'PARTIAL'
      ZZPOSOM-C  its only line fully cancelled  -> 'FULL', and dropped from the
                 two list endpoints by their EXISTS filter
      ZZPOSOM-D  no order lines at all          -> the zero-row COALESCE branch,
                 which is where MySQL prints 0.00000000 and an untyped
                 PostgreSQL literal would print 0

    Three sales, covering all three FIND_IN_SET haystack shapes: a comma-joined
    pair, an empty string, and NULL. ZZPOSOM-A is billed by the first of them,
    so the "not yet billed" filter has something to exclude -- which is why the
    orders live on 2099-07-01 and that sale on 2099-07-02.

    ZZPOSSM-3 has PaidAmount 0 so get_allsaleswithoutpaidamount returns exactly
    one row while get_allsales returns three.
#>
function Seed-PosRows {
    $sql = @"
INSERT INTO ``user`` (UserId,OrganizationCode,Name,UserName,Password,Phone,DefSOBillType,DefSOCBillType,DefSIBillType,DefRVBillType,DefPVBillType,DefPOBillType,DefSRBillType,DefJVBillType,SaleTaxIncDiscount,DefCashLedger,IsAdmin,RoutId,UseOnlyRoutLedgers,DefSaleRate,DefWarehouseId,DefCardBank)
VALUES ('$PosUser','ZZ01','ZZ Pos','ZZ Pos User','x','','','','','','','','','',0,'',0,'',0,'','','');

INSERT INTO category (OrganizationCode,InventoryGroupId,GroupName,ParentGroup,ImagePath,Colour)
VALUES ('ZZ01','$PosCat','ZZ Pos Cat','','zzcat.jpg','#fff');

-- LedgerType 'B' so get_bankdetails has a row to shape-check against.
-- fireflydb_test holds no real bank ledgers, and the key list is all that
-- case asserts.
INSERT INTO ledger (led_id,OrganizationCode,CentreCode,LedgerId,LedgerType,LedgerName,RegionalName,Address,Email,Phone,UserName,mypassword,noofseats,seatstaken,CurrentBalance,LedgerCode,CustomCode,RoutId,TINNumber,IsActive)
VALUES (970301,'ZZ01','ZZ01','ZZBANK01','B','ZZ Pos Bank','','','','','','',0,0,0,'ZZBLC','ZZBCC','','',1);

INSERT INTO product (OrganizationCode,UnitId,UnitName,UnitShortName,ProductName,ImagePath,InventoryDetailsId,InventoryGroupId,MRP,MOP,MLOP,PurchaseRate,AvgRate,LastPurchaseRate,SaleRate,isVeg,Description,CurrentStock,OrderLimit,TaxId,AddTaxId,AddTaxId1,Barcode,CustomBarcode,Code,HSNCode,Size,Colour,ProductRegionalName,UnitRegionalName,StockMaster)
VALUES ('ZZ01','ZZU','Piece','Pc','ZZ Pos Product','','$PosInv','$PosCat','100.00','90.00','85.00','70.00','72.00','71.00','99.00',1,'pos',0,0,'ZZNOTAX','ZZNOTAX','ZZNOTAX','ZZB','ZZCB','ZZC','ZZH','M','red','','',0);

INSERT INTO ordermaster (AUTOID,OrganizationCode,BillTypeId,OrderMasterId,OrderNumber,OrderDate,PartyDetails,LedgerId,NoofChair,Status,CreatedByUser,CreatedTimeStamp,TotalAmount,Description,PosMode)
VALUES (970001,'ZZ01','$PosBill','ZZPOSOM-A','ZZPOSON-A','2099-07-01 10:00:00','ZZ party','ZZLED01',2,'N','$PosUser','2099-07-01 10:00:00',300,'','counter'),
       (970002,'ZZ01','$PosBill','ZZPOSOM-B','ZZPOSON-B','2099-07-01 11:00:00','ZZ party','ZZLED01',0,'N','$PosUser','2099-07-01 11:00:00',300,'','parcel'),
       (970003,'ZZ01','$PosBill','ZZPOSOM-C','ZZPOSON-C','2099-07-01 12:00:00','ZZ party','ZZLED01',0,'N','$PosUser','2099-07-01 12:00:00',100,'',NULL),
       (970004,'ZZ01','$PosBill','ZZPOSOM-D','ZZPOSON-D','2099-07-01 13:00:00','ZZ party','ZZLED01',0,'N','$PosUser','2099-07-01 13:00:00',0,'',NULL);

INSERT INTO orderdetails (orderdtl_id,ordermstr_id,InventoryDetailsId,UnitId,Quantity,Rate,TotalAmount,Description,CreatedByUser,CreatedTimeStamp)
VALUES (970101,'ZZPOSOM-A','$PosInv','ZZU',3,100,300,'ZZ line A','$PosUser','2099-07-01 10:00:00'),
       (970102,'ZZPOSOM-B','$PosInv','ZZU',3,100,300,'ZZ line B','$PosUser','2099-07-01 11:00:00'),
       (970103,'ZZPOSOM-C','$PosInv','ZZU',1,100,100,'ZZ line C','$PosUser','2099-07-01 12:00:00');

INSERT INTO ordercancelmaster (AUTOID,OrganizationCode,BillTypeId,OrderCancelMasterId,OrderCancelNumber,OrderCancelDate,OrderMasterId,PartyDetails,LedgerId,Status,CreatedByUser,CreatedTimeStamp,TotalAmount,Description)
VALUES (970005,'ZZ01','$PosBill','ZZPOSOC-1','ZZPOSOCN-1','2099-07-01 14:00:00','ZZPOSOM-B','ZZ party','ZZLED01','N','$PosUser','2099-07-01 14:00:00',200,'');

INSERT INTO ordercanceldetails (OrderCancelDetailsId,OrderCancelMasterId,OrderDetailsId,InventoryDetailsId,UnitId,Quantity,Rate,TotalAmount,Description,CreatedByUser,CreatedTimeStamp)
VALUES (970201,'ZZPOSOC-1',970102,'$PosInv','ZZU',1,100,100,'ZZ cancel B','$PosUser','2099-07-01 14:00:00'),
       (970202,'ZZPOSOC-1',970103,'$PosInv','ZZU',1,100,100,'ZZ cancel C','$PosUser','2099-07-01 14:00:00');

INSERT INTO salemaster (AUTOID,OrganizationCode,BillTypeId,OrderMasterId,LedgerId,PartyDetails,VoucherDate,Status,GrossAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,DiscountPercentage,DiscountAmount,RoundOffAmount,TotalAmount,PaidAmount,CreatedByUser,CreatedTimeStamp,SaleMasterId,VoucherNumber,Description,PosMode,IsOut)
VALUES (970006,'ZZ01','$PosBill','ZZPOSOM-A,ZZPOSOM-X','ZZLED01','ZZ party','2099-07-02 09:00:00','N',300,'ZZTAX',300,0,0,0,0,0,300,300,'$PosUser','2099-07-02 09:00:00','ZZPOSSM-1','ZZPOSVN-1','ZZ merged bill','counter',0),
       (970007,'ZZ01','$PosBill','','ZZLED01','ZZ party','2099-07-02 10:00:00','N',100,'ZZTAX',100,0,0,0,0,0,100,100,'$PosUser','2099-07-02 10:00:00','ZZPOSSM-2','ZZPOSVN-2','ZZ blank orderid','parcel',1),
       (970008,'ZZ01','$PosBill',NULL,'ZZLED01','ZZ party','2099-07-02 11:00:00','N',50,'ZZTAX',50,0,0,0,0,0,50,0,'$PosUser','2099-07-02 11:00:00','ZZPOSSM-3','ZZPOSVN-3','ZZ unpaid',NULL,0);

INSERT INTO salesdetails (SaleMasterId,InventoryDetailsId,UnitId,Quantity,Rate,GrossAmount,DiscountPercentage,DiscountAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,TotalAmount,CreatedByUser,CreatedTimeStamp,Description,AddTaxId,AddTaxPercentage,AddTaxAmount,AddTaxId1,AddTaxPercentage1,AddTaxAmount1)
VALUES ('ZZPOSSM-1','$PosInv','ZZU',3,100,300,0,0,'ZZTAX',300,0,0,300,'$PosUser','2099-07-02 09:00:00','ZZ sale line','ZZAT',0,0,'ZZAT1',0,0);
"@
    Invoke-MysqlFile $sql
    # MySQL's backticked `user` becomes PostgreSQL's quoted "user" first, so the
    # column-list rewrite below only has to cope with one quoting style.
    $pg = $sql -replace '`user`', '"user"'
    $pg = [regex]::Replace($pg, '(?m)^INSERT INTO ("?\w+"?) \(([^)]*)\)', {
        param($m)
        $cols = ($m.Groups[2].Value -split ',' | ForEach-Object { '"' + $_.Trim() + '"' }) -join ','
        "INSERT INTO $($m.Groups[1].Value) ($cols)"
    })
    Invoke-Psql -Quiet $pg
}

<#
    Puts a write endpoint's number series into a known, identical state.

    MaxId is derived from billtype.StartNumber and MAX(AUTOID) over live rows,
    so without this the two servers mint different ids and voucher numbers and
    every write case fails for an uninteresting reason. Deleting all ZZ masters
    makes MAX(AUTOID) NULL on both sides, which collapses MaxId to StartNumber
    alone. Must run before EVERY write case, not once per section.
#>
function Reset-WriteSeries {
    param([string]$BillTypeId, [int]$Start, [string]$Prefix = '', [string]$Suffix = '')
    $sql = @"
DELETE FROM orderdetails       WHERE ordermstr_id        LIKE '$BillTypeId-%';
DELETE FROM ordercanceldetails WHERE OrderCancelMasterId LIKE '$BillTypeId-%';
DELETE FROM salesdetails       WHERE SaleMasterId        LIKE '$BillTypeId-%';
DELETE FROM pdcdetails         WHERE ReferenceId         LIKE '$BillTypeId-%';
DELETE FROM ordermaster        WHERE BillTypeId = '$BillTypeId';
DELETE FROM ordercancelmaster  WHERE BillTypeId = '$BillTypeId';
DELETE FROM salemaster         WHERE BillTypeId = '$BillTypeId';
DELETE FROM billtype           WHERE BillTypeId = '$BillTypeId';
INSERT INTO billtype (OrganizationCode,BillTypeId,BillTypeName,StartNumber,Prefix,Suffix,VoucherType,TaxType,CreatedByUser)
VALUES ('ZZ01','$BillTypeId','ZZ Write BT',$Start,'$Prefix','$Suffix','SO','','$PosUser');
"@
    Invoke-MysqlFile $sql
    $pg = ($sql -replace '(?m)WHERE (\w+)', 'WHERE "$1"')
    $pg = [regex]::Replace($pg, '(?m)^INSERT INTO (\w+) \(([^)]*)\)', {
        param($m)
        $cols = ($m.Groups[2].Value -split ',' | ForEach-Object { '"' + $_.Trim() + '"' }) -join ','
        "INSERT INTO $($m.Groups[1].Value) ($cols)"
    })
    Invoke-Psql -Quiet $pg
}

Reset-PosRows
Seed-PosRows

# --- 93-100. Reads with no filter: zero-row envelope, then key shape ----------
#
# The zero-row cases are the interesting half. DATA is the *string* "EMPTY" and
# STATUS is ERROR -- unlike the sync loop's reads, where an empty result is
# DATA: null with STATUS SUCCESS.
Compare-Case -Name '93. get_ledgers (key shape on live data)' -Body @{ api = 'get_ledgers' } -Mode 'Keys'
Compare-Case -Name '94. get_ledgersbyname (no match -> "EMPTY")' -Body @{ api = 'get_ledgersbyname'; Searchstring = 'ZZNOSUCHLEDGER'; UserId = 'ZZNOBODY'; RoutId = '' }
Compare-Case -Name '95. get_ledgersbyname (key shape, blank search)' -Body @{ api = 'get_ledgersbyname'; Searchstring = ''; UserId = 'ZZNOBODY'; RoutId = '' } -Mode 'Keys'
Compare-Case -Name '96. get_ledgersbyname (RoutId branch)' -Body @{ api = 'get_ledgersbyname'; Searchstring = 'ZZNOSUCHLEDGER'; UserId = 'ZZNOBODY'; RoutId = 'ZZR' }
Compare-Case -Name '97. get_bankdetails (key shape)' -Body @{ api = 'get_bankdetails'; UserId = 'ZZNOBODY' } -Mode 'Keys'
Compare-Case -Name '98. get_userviewprivileges (no match -> "DATA NOT FOUND !!")' -Body @{ api = 'get_userviewprivileges'; UserId = 'ZZNOBODY'; ViewName = 'ZZNOVIEW' }
Compare-Case -Name '99. get_stock (no rows -> [] and the generic error)' -Body @{ api = 'get_stock'; OrganizationCode = 'ZZNOSUCHORG'; WarehouseId = '' }
Compare-Case -Name '100. get_product_with_category_withstock (no rows -> [])' -Body @{ api = 'get_product_with_category_withstock'; OrganizationCode = 'ZZNOSUCHORG'; WarehouseId = '' }

# --- 101-105. The catalogue, on the seeded ZZ01 category ----------------------
#
# 102/103 are byte-comparable because the fixture is identical on both sides,
# and they are what proves the COALESCE scale fix: the product joins no
# taxdetails row and has no warehousestock, so TaxPercentage and Stock take
# their NULL branch. MySQL prints "0.000"/"0.00000000" there; an untyped
# PostgreSQL zero literal would print "0".
Compare-Case -Name '101. get_organization (image URLs from settings)' -Body @{ api = 'get_organization' }
Compare-Case -Name '102. get_product_with_category_withstock (no WarehouseId)' -Body @{ api = 'get_product_with_category_withstock'; OrganizationCode = 'ZZ01'; WarehouseId = '' }
Compare-Case -Name '103. ... with WarehouseId (drops UnitShortName)' -Body @{ api = 'get_product_with_category_withstock'; OrganizationCode = 'ZZ01'; WarehouseId = 'ZZWH' }
Compare-Case -Name '104. ... product key shape, no WarehouseId' -Body @{ api = 'get_product_with_category_withstock'; OrganizationCode = 'ZZ01'; WarehouseId = '' } -Mode 'Keys' -KeyPath 'products'
Compare-Case -Name '105. ... product key shape, WarehouseId' -Body @{ api = 'get_product_with_category_withstock'; OrganizationCode = 'ZZ01'; WarehouseId = 'ZZWH' } -Mode 'Keys' -KeyPath 'products'

# --- 106-108. The image base URL -------------------------------------------
#
# Both stacks resolve to http://localhost:8090 today for DIFFERENT reasons --
# MySQL has the settings row, PostgreSQL falls back to the hardcoded default --
# so a broken parser would still pass. Pinning a non-default host WITH an
# explicit port exercises the whole parse_url path.
$origApiUrl = (& $Mysql -u root fireflydb -N -B -e "SELECT ``value`` FROM settings_common WHERE ``key``='firefly_api_url';" 2>$null | Select-Object -First 1)
try {
    Set-SettingsKey -Key 'firefly_api_url' -Value 'https://zz.example.test:9443/ffapi/firefly_api.php'
    Compare-Case -Name '106. get_organization (custom host and port)' -Body @{ api = 'get_organization' }

    # parse_url yields no scheme+host, and PHP then returns '' rather than the
    # fallback -- so every path becomes a bare /ffapi/Org_Image/.
    Set-SettingsKey -Key 'firefly_api_url' -Value 'not a url'
    Compare-Case -Name '107. get_organization (unparseable URL -> site-relative)' -Body @{ api = 'get_organization' }

    Remove-SettingsKey -Key 'firefly_api_url'
    Compare-Case -Name '108. get_organization (setting absent -> fallback)' -Body @{ api = 'get_organization' }
} finally {
    if ($origApiUrl) { Set-SettingsKey -Key 'firefly_api_url' -Value $origApiUrl }
    else             { Remove-SettingsKey -Key 'firefly_api_url' }
}

# --- 109-116. The 2099 window: order and sale reads --------------------------
$W = @{ FromDate = '2099-01-01'; TillDate = '2099-12-31' }

# 'Set' rather than 'Bytes': this query has no ORDER BY, unlike its _test
# siblings, so the two engines return the same rows in a different sequence.
Compare-Case -Name '109. get_allnoncommitedordermaster (no ORDER BY)' -Body @{ api = 'get_allnoncommitedordermaster'; BillTypeId = $PosBill; FromDate = $W.FromDate; TillDate = $W.TillDate } -Mode 'Set'
Compare-Case -Name '110. get_allnoncommitedordermaster_test (cancel maths)' -Body @{ api = 'get_allnoncommitedordermaster_test'; BillTypeId = $PosBill; FromDate = $W.FromDate; TillDate = $W.TillDate }
Compare-Case -Name '111. get_allnoncommitedordermaster_test2 (all billtypes)' -Body @{ api = 'get_allnoncommitedordermaster_test2'; FromDate = $W.FromDate; TillDate = $W.TillDate }
Compare-Case -Name '112. get_ordermasterbynumber' -Body @{ api = 'get_ordermasterbynumber'; BillTypeId = $PosBill; OrderNumber = 'ZZPOSON-B' }
Compare-Case -Name '113. get_ordermasterbynumber_test (PARTIAL)' -Body @{ api = 'get_ordermasterbynumber_test'; BillTypeId = $PosBill; OrderNumber = 'ZZPOSON-B' }
Compare-Case -Name '114. get_ordermasterbynumber_test (FULL)' -Body @{ api = 'get_ordermasterbynumber_test'; BillTypeId = $PosBill; OrderNumber = 'ZZPOSON-C' }
# The one case that reaches the zero-row COALESCE branch on all four computed
# columns: an order with no lines at all, which the list endpoints filter out.
Compare-Case -Name '115. get_ordermasterbynumber_test (no lines -> 0.00000000 / 0.0000000000000000)' -Body @{ api = 'get_ordermasterbynumber_test'; BillTypeId = $PosBill; OrderNumber = 'ZZPOSON-D' }
Compare-Case -Name '116. get_ordermasterbynumber (unknown number -> "EMPTY")' -Body @{ api = 'get_ordermasterbynumber'; BillTypeId = $PosBill; OrderNumber = 'ZZNOSUCH' }

Compare-Case -Name '117. get_allorderDetailsByMasterId' -Body @{ api = 'get_allorderDetailsByMasterId'; OrderMasterId = 'ZZPOSOM-B' }
Compare-Case -Name '118. get_allorderDetailsByMasterId_test (net of cancellations)' -Body @{ api = 'get_allorderDetailsByMasterId_test'; OrderMasterId = 'ZZPOSOM-B' }
# Every line cancelled, so the HAVING/outer-WHERE filter empties the result.
Compare-Case -Name '119. get_allorderDetailsByMasterId_test (fully cancelled -> [])' -Body @{ api = 'get_allorderDetailsByMasterId_test'; OrderMasterId = 'ZZPOSOM-C' }
Compare-Case -Name '120. get_allorderDetailsByMasterId (no lines -> [])' -Body @{ api = 'get_allorderDetailsByMasterId'; OrderMasterId = 'ZZPOSOM-D' }

# Also no ORDER BY. 122 and 123 return a single row each, so they stay 'Bytes'.
Compare-Case -Name '121. get_allsales (PosMode + IsOut, no ORDER BY)' -Body @{ api = 'get_allsales'; FromDate = $W.FromDate; TillDate = $W.TillDate } -Mode 'Set'
Compare-Case -Name '122. get_allsaleswithoutpaidamount (PaidAmount = 0 only)' -Body @{ api = 'get_allsaleswithoutpaidamount'; FromDate = $W.FromDate; TillDate = $W.TillDate }
Compare-Case -Name '123. get_salemasterbyNumber' -Body @{ api = 'get_salemasterbyNumber'; BillTypeId = $PosBill; VoucherNumber = 'ZZPOSVN-1' }
Compare-Case -Name '124. get_allsaleDetailsByMasterId' -Body @{ api = 'get_allsaleDetailsByMasterId'; SaleMasterId = 'ZZPOSSM-1' }
Compare-Case -Name '125. get_allsaleDetailsByMasterId (no lines -> [])' -Body @{ api = 'get_allsaleDetailsByMasterId'; SaleMasterId = 'ZZPOSSM-3' }

# --- 126+. The writes --------------------------------------------------------
#
# All three open with SELECT ... FROM organization LIMIT 1, unordered. Its
# OrganizationCode is stored on every row they write and its
# UseBackSlashAsInvSeparator decides whether voucher numbers use '-' or '/',
# which IS on the wire. If the two databases disagree there, every comparison
# below is meaningless -- so say so plainly rather than emit a wall of diffs.
$myOrg = (& $Mysql -u root fireflydb -N -B -e "SELECT CONCAT(OrganizationCode,'/',UseBackSlashAsInvSeparator) FROM organization LIMIT 1;" 2>$null | Select-Object -First 1)
$pgOrg = Get-PgScalar "SELECT `"OrganizationCode`" || '/' || `"UseBackSlashAsInvSeparator`" FROM organization LIMIT 1;"

if ($myOrg -ne $pgOrg) {
    $script:Fail++
    Write-Host "FAIL  126-140. write cases SKIPPED -- organization LIMIT 1 differs" -ForegroundColor Red
    Write-Host "      mysql: $myOrg    postgres: $pgOrg" -ForegroundColor Yellow
    Write-Host "      Both writes stamp OrganizationCode onto every row and take the" -ForegroundColor Yellow
    Write-Host "      voucher separator from UseBackSlashAsInvSeparator, so give" -ForegroundColor Yellow
    Write-Host "      fireflydb_test a matching organization row and re-run." -ForegroundColor Yellow
} else {
    $orderDetails = '[{"InventoryDetailsId":"' + $PosInv + '","Quantity":"2","Rate":"100","DetailsTotalAmount":"200","Description":"ZZ line"}]'

    function New-OrderBody {
        # $Details is deliberately untyped: PowerShell coerces $null to '' for a
        # [string] parameter, so a typed default would silently send an empty
        # payload and every case below would exercise the no-lines path instead.
        param([string]$MasterId = '', [string]$Chair = '2', [string]$PosMode = 'counter', $Details = $null)
        if ($null -eq $Details) { $Details = $orderDetails }
        return @{
            api = 'insert_orderbybilltype'; OrderMasterId = $MasterId
            OrderDate = '2099-07-05 09:00:00'; LedgerId = 'ZZLED01'; PartyDetails = 'ZZ party'
            NoofChair = $Chair; CreatedByUser = $PosUser; TotalAmount = '200.00'
            BillTypeId = $PosWBill; Description = ''; CreatedTimeStamp = '2099-07-05 09:00:00'
            PosMode = $PosMode; OrderDetails = $Details
        }
    }

    Reset-WriteSeries -BillTypeId $PosWBill -Start 500 -Prefix 'KOT' -Suffix '26'
    Compare-Case -Name '126. insert_orderbybilltype (INSERT -> id + voucherNumber)' -Body (New-OrderBody)
    # The response says nothing about the lines, so check them directly --
    # including UnitId, which the endpoint looks up from product rather than
    # taking from the payload.
    $myOrdDet = Get-MysqlRows "SELECT ordermstr_id,InventoryDetailsId,UnitId,Quantity,Rate,TotalAmount,Description FROM orderdetails WHERE ordermstr_id LIKE '$PosWBill-%' ORDER BY orderdtl_id;"
    $pgOrdDet = Get-PgRows "SELECT `"ordermstr_id`",`"InventoryDetailsId`",`"UnitId`",`"Quantity`",`"Rate`",`"TotalAmount`",`"Description`" FROM orderdetails WHERE `"ordermstr_id`" LIKE '$PosWBill-%' ORDER BY `"orderdtl_id`";"
    Assert-SameRows -Name '126a. stored orderdetails (UnitId resolved from product)' -Mysql $myOrdDet -Postgres $pgOrdDet

    # The UPDATE path answers id="" and voucherNumber="": both are only assigned
    # inside the INSERT branch (firefly_api.php 7783).
    # The UPDATE path, plus what it leaves behind. Each side's rows are captured
    # right after its own run, because the reset in between clears both.
    $updBody   = New-OrderBody -MasterId "$PosWBill-0000000500" -Chair '4' -PosMode ''
    $myOrderQ  = "SELECT AUTOID,OrderMasterId,OrderNumber,NoofChair,Status,TotalAmount,PosMode FROM ordermaster WHERE BillTypeId='$PosWBill';"
    $pgOrderQ  = "SELECT `"AUTOID`",`"OrderMasterId`",`"OrderNumber`",`"NoofChair`",`"Status`",`"TotalAmount`",`"PosMode`" FROM ordermaster WHERE `"BillTypeId`" = '$PosWBill';"

    Reset-WriteSeries -BillTypeId $PosWBill -Start 500 -Prefix 'KOT' -Suffix '26'
    Invoke-Endpoint -Url $PhpUrl -Body (New-OrderBody) | Out-Null
    $phpUpd   = Invoke-Endpoint -Url $PhpUrl -Body $updBody
    $myStored = Get-MysqlRows $myOrderQ

    Reset-WriteSeries -BillTypeId $PosWBill -Start 500 -Prefix 'KOT' -Suffix '26'
    Invoke-Endpoint -Url $NextUrl -Body (New-OrderBody) | Out-Null
    $nextUpd  = Invoke-Endpoint -Url $NextUrl -Body $updBody
    $pgStored = Get-PgRows $pgOrderQ

    if ($phpUpd.Body -ceq $nextUpd.Body) {
        $script:Pass++; Write-Host "PASS  127. insert_orderbybilltype (UPDATE -> empty id/voucherNumber)" -ForegroundColor Green
        Write-Host "      $($phpUpd.Body)" -ForegroundColor DarkGray
    } else {
        $script:Fail++; Write-Host "FAIL  127. insert_orderbybilltype (UPDATE)" -ForegroundColor Red
        Write-Host "      PHP  $($phpUpd.Body)" -ForegroundColor Yellow
        Write-Host "      NEXT $($nextUpd.Body)" -ForegroundColor Cyan
    }
    # PosMode='' must PRESERVE 'counter' via COALESCE(NULLIF(...)); NoofChair 4.
    Assert-SameRows -Name "128. stored ordermaster after the UPDATE (PosMode preserved)" -Mysql $myStored -Postgres $pgStored

    # int(11) via mysqlInt: MySQL ROUNDS, half away from zero -- 2.5 -> 3.
    Reset-WriteSeries -BillTypeId $PosWBill -Start 500 -Prefix 'KOT' -Suffix '26'
    Compare-Case -Name '129. insert_orderbybilltype (NoofChair "2.5")' -Body (New-OrderBody -Chair '2.5')
    $myChair = Get-MysqlRows "SELECT NoofChair FROM ordermaster WHERE BillTypeId='$PosWBill';"
    $pgChair = Get-PgRows "SELECT `"NoofChair`" FROM ordermaster WHERE `"BillTypeId`" = '$PosWBill';"
    Assert-SameRows -Name '129a. stored NoofChair must be 3 on both' -Mysql $myChair -Postgres $pgChair

    # A missing OrderDate hits a NOT NULL column: both fail, each with its own
    # driver's wording, and the whole transaction rolls back.
    Reset-WriteSeries -BillTypeId $PosWBill -Start 500 -Prefix 'KOT' -Suffix '26'
    $noDate = New-OrderBody; $noDate.Remove('OrderDate')
    Compare-Case -Name '130. insert_orderbybilltype (missing OrderDate -> rollback)' -Body $noDate

    # --- insert_ordercancelbybilltype ---------------------------------------
    $cancelDetails = '[{"InventoryDetailsId":"' + $PosInv + '","OrderDetailsId":970102,"Quantity":"1","Rate":"100","DetailsTotalAmount":"100","Description":"ZZ cancel"}]'

    function New-CancelBody {
        # Untyped $Details -- see New-OrderBody.
        param([string]$MasterId = '', $Details = $null)
        if ($null -eq $Details) { $Details = $cancelDetails }
        return @{
            api = 'insert_ordercancelbybilltype'; OrderCancelMasterId = $MasterId
            OrderMasterId = 'ZZPOSOM-B'; OrderCancelDate = '2099-07-06 09:00:00'
            LedgerId = 'ZZLED01'; PartyDetails = 'ZZ party'; CreatedByUser = $PosUser
            TotalAmount = '100.00'; BillTypeId = $PosCBill; Description = ''
            CreatedTimeStamp = '2099-07-06 09:00:00'; OrderCancelDetails = $Details
        }
    }

    # StartNumber 0 must become 1 -- this endpoint's empty() rule, unlike the
    # sale insert's is_null.
    Reset-WriteSeries -BillTypeId $PosCBill -Start 0
    Compare-Case -Name '131. insert_ordercancelbybilltype (StartNumber 0 -> 1)' -Body (New-CancelBody)

    Reset-WriteSeries -BillTypeId $PosCBill -Start 1
    Invoke-Endpoint -Url $PhpUrl -Body (New-CancelBody) | Out-Null
    $phpSecond = Invoke-Endpoint -Url $PhpUrl -Body (New-CancelBody)
    Reset-WriteSeries -BillTypeId $PosCBill -Start 1
    Invoke-Endpoint -Url $NextUrl -Body (New-CancelBody) | Out-Null
    $nextSecond = Invoke-Endpoint -Url $NextUrl -Body (New-CancelBody)
    if ($phpSecond.Body -ceq $nextSecond.Body) {
        $script:Pass++; Write-Host "PASS  132. insert_ordercancelbybilltype (id collision -> MAX(AUTOID)+1)" -ForegroundColor Green
        Write-Host "      $($phpSecond.Body)" -ForegroundColor DarkGray
    } else {
        $script:Fail++; Write-Host "FAIL  132. insert_ordercancelbybilltype (id collision)" -ForegroundColor Red
        Write-Host "      PHP  $($phpSecond.Body)" -ForegroundColor Yellow
        Write-Host "      NEXT $($nextSecond.Body)" -ForegroundColor Cyan
    }

    # OrderDetailsId omitted: PHP defaults it to '' and MySQL coerces that to 0
    # in the int column. mysqlInt reproduces it.
    Reset-WriteSeries -BillTypeId $PosCBill -Start 1
    $noDetailId = '[{"InventoryDetailsId":"' + $PosInv + '","Quantity":"1","Rate":"100","DetailsTotalAmount":"100","Description":"ZZ"}]'
    Compare-Case -Name '133. insert_ordercancelbybilltype (OrderDetailsId omitted)' -Body (New-CancelBody -Details $noDetailId)
    # Both sides ran against the same series with no reset between, so a single
    # capture of each is enough. OrderDetailsId must be 0 -- PHP defaults it to
    # '' and MySQL coerces that in the int column -- and UnitId must have been
    # looked up from product because the payload omitted it.
    $myCancelDet = Get-MysqlRows "SELECT OrderDetailsId,UnitId,Quantity FROM ordercanceldetails WHERE OrderCancelMasterId LIKE '$PosCBill-%';"
    $pgCancelDet = Get-PgRows "SELECT `"OrderDetailsId`",`"UnitId`",`"Quantity`" FROM ordercanceldetails WHERE `"OrderCancelMasterId`" LIKE '$PosCBill-%';"
    Assert-SameRows -Name '133a. stored ordercanceldetails (OrderDetailsId 0, UnitId from product)' -Mysql $myCancelDet -Postgres $pgCancelDet

    # The only one of the three whose app-level error text is identical on both
    # stacks, because the message is thrown by the handler, not the driver.
    Reset-WriteSeries -BillTypeId $PosCBill -Start 1
    Compare-Case -Name '134. insert_ordercancelbybilltype (malformed JSON)' -Body (New-CancelBody -Details 'not json')

    # --- insert_salebybilltypewithpdc ---------------------------------------
    $saleDetails = '[{"InventoryDetailsId":"' + $PosInv + '","Rate":"100","Quantity":"2","DetailsGrossAmount":"200","DetailsTaxId":"ZZTAX","DetailsTaxableAmount":"200","DetailsTaxPercentage":"0","DetailsTaxAmount":"0","DetailsAddTaxId":"","DetailsAddTaxPercentage":"0","DetailsAddTaxAmount":"0","DetailsAddTaxId1":"","DetailsAddTaxPercentage1":"0","DetailsAddTaxAmount1":"0","DetailsDiscountPercentage":"0","DetailsDiscountAmount":"0","DetailsTotalAmount":"200","DetailsDescription":"ZZ sale line"}]'
    # Verbatim from logs\api_2026-07-31.log: the ERP sends one all-blank element
    # on every sale, cheque or not. This is what makes ChequeDate '0000-00-00'.
    $pdcBlank = '[{"BankLedgerId":"","Amount":"","PaymentMode":"","ChequeNumber":"","ChequeDate":""}]'
    $pdcReal  = '[{"BankLedgerId":"ZZBANK","Amount":"150.50","PaymentMode":"PC","ChequeNumber":"ZZCHQ9","ChequeDate":"2099-08-15"}]'

    function New-SaleBody {
        param([string]$MasterId = '', [string]$Orders = 'ZZPOSOM-D', [string]$RoundOff = '0.00',
              [string]$Idem = '', $Pdc = $null)   # untyped -- see New-OrderBody
        if ($null -eq $Pdc) { $Pdc = $pdcBlank }
        return @{
            api = 'insert_salebybilltypewithpdc'; SaleMasterId = $MasterId
            VoucherDate = '2099-07-07 09:00:00'; LedgerId = 'ZZLED01'; PartyDetails = 'ZZ party'
            CreatedByUser = $PosUser; OrderMasterId = $Orders
            GrossAmount = '200'; TaxId = 'ZZTAX'; TaxableAmount = '200'; TaxPercentage = '0'
            TaxAmount = '0'; DiscountPercentage = '0'; DiscountAmount = '0'
            TotalAmount = '200'; PaidAmount = '200'; BillTypeId = $PosSBill; Description = ''
            RoundOffAmount = $RoundOff; CreatedTimeStamp = '2099-07-07 09:00:00'; PosMode = 'counter'
            SaleDetails = $saleDetails; PdcDetails = $Pdc; IdempotencyKey = $Idem
        }
    }

    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Compare-Case -Name '135. insert_salebybilltypewithpdc (INSERT)' -Body (New-SaleBody)
    # 22 columns per line, every one of them bound from a differently-named
    # payload key (Rate -> Rate, but DetailsGrossAmount -> GrossAmount and so
    # on), which is exactly where a transcription slip would hide.
    $mySaleDet = Get-MysqlRows "SELECT InventoryDetailsId,UnitId,Quantity,Rate,GrossAmount,TaxId,TaxableAmount,TaxPercentage,TaxAmount,AddTaxId,AddTaxPercentage,AddTaxAmount,AddTaxId1,AddTaxPercentage1,AddTaxAmount1,DiscountPercentage,DiscountAmount,TotalAmount,Description FROM salesdetails WHERE SaleMasterId LIKE '$PosSBill-%' ORDER BY SaleDetailsId;"
    $pgSaleDet = Get-PgRows "SELECT `"InventoryDetailsId`",`"UnitId`",`"Quantity`",`"Rate`",`"GrossAmount`",`"TaxId`",`"TaxableAmount`",`"TaxPercentage`",`"TaxAmount`",`"AddTaxId`",`"AddTaxPercentage`",`"AddTaxAmount`",`"AddTaxId1`",`"AddTaxPercentage1`",`"AddTaxAmount1`",`"DiscountPercentage`",`"DiscountAmount`",`"TotalAmount`",`"Description`" FROM salesdetails WHERE `"SaleMasterId`" LIKE '$PosSBill-%' ORDER BY `"SaleDetailsId`";"
    Assert-SameRows -Name '135a. stored salesdetails (all 19 value columns)' -Mysql $mySaleDet -Postgres $pgSaleDet

    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Compare-Case -Name '136. ... RoundOffAmount "" on INSERT -> 0.00' -Body (New-SaleBody -RoundOff '')

    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Compare-Case -Name '137. ... with IdempotencyKey' -Body (New-SaleBody -Idem 'ZZIDEM-1')

    # Layer 2 of the idempotency guard: the replay must return the SAME id with
    # a fourth key, "duplicate":true, and must not mint a second invoice.
    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Invoke-Endpoint -Url $PhpUrl -Body (New-SaleBody -Idem 'ZZIDEM-1') | Out-Null
    $phpDup = Invoke-Endpoint -Url $PhpUrl -Body (New-SaleBody -Idem 'ZZIDEM-1')
    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Invoke-Endpoint -Url $NextUrl -Body (New-SaleBody -Idem 'ZZIDEM-1') | Out-Null
    $nextDup = Invoke-Endpoint -Url $NextUrl -Body (New-SaleBody -Idem 'ZZIDEM-1')
    if ($phpDup.Body -ceq $nextDup.Body) {
        $script:Pass++; Write-Host 'PASS  138. ... replayed IdempotencyKey -> "duplicate":true' -ForegroundColor Green
        Write-Host "      $($phpDup.Body)" -ForegroundColor DarkGray
    } else {
        $script:Fail++; Write-Host 'FAIL  138. ... replayed IdempotencyKey' -ForegroundColor Red
        Write-Host "      PHP  $($phpDup.Body)" -ForegroundColor Yellow
        Write-Host "      NEXT $($nextDup.Body)" -ForegroundColor Cyan
    }

    # Same guard reached the other way: no key, but the orders are already billed.
    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Invoke-Endpoint -Url $PhpUrl -Body (New-SaleBody) | Out-Null
    $phpDup2 = Invoke-Endpoint -Url $PhpUrl -Body (New-SaleBody)
    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Invoke-Endpoint -Url $NextUrl -Body (New-SaleBody) | Out-Null
    $nextDup2 = Invoke-Endpoint -Url $NextUrl -Body (New-SaleBody)
    if ($phpDup2.Body -ceq $nextDup2.Body) {
        $script:Pass++; Write-Host 'PASS  139. ... replayed OrderMasterId -> "duplicate":true' -ForegroundColor Green
        Write-Host "      $($phpDup2.Body)" -ForegroundColor DarkGray
    } else {
        $script:Fail++; Write-Host 'FAIL  139. ... replayed OrderMasterId' -ForegroundColor Red
        Write-Host "      PHP  $($phpDup2.Body)" -ForegroundColor Yellow
        Write-Host "      NEXT $($nextDup2.Body)" -ForegroundColor Cyan
    }

    <#
        140-141. The UPDATE path, and the cheque rows it rewrites.

        Both scenarios run in one pass per host so each side's rows can be
        captured before the reset that precedes the other host's run.

        141 is the case the pdcdetails.ChequeDate decision exists for. The ERP
        posts ChequeDate="" on every sale; non-strict MySQL coerces that into
        its DATE column as '0000-00-00', which PostgreSQL's date type cannot
        represent at all -- so the column is varchar(10) here and mysqlDate()
        reproduces the coercion. Both sides must store [0000-00-00], alongside a
        real cheque date that must survive unchanged.

        Both cheques go in ONE payload on purpose: the UPDATE path deletes
        pdcdetails by ReferenceId before rewriting them, so sending them in two
        calls would leave only the second.

        AUTOID and the ids derived from it (PDCDetailsId, PDCNumber) are NOT
        compared. They come from MAX(AUTOID)+1 over every pdcdetails row sharing
        that PaymentMode, and live MySQL holds 31 legacy rows with a blank mode
        where fireflydb_test holds none -- a data difference, not a behavioural
        one. What IS compared is PaymentMode, Amount, Type, ChequeDate and
        Status, bracketed so an empty string is visible.
    #>
    $bothCheques = '[' +
        '{"BankLedgerId":"","Amount":"","PaymentMode":"","ChequeNumber":"","ChequeDate":""},' +
        '{"BankLedgerId":"ZZBANK01","Amount":"150.50","PaymentMode":"PC","ChequeNumber":"ZZCHQ9","ChequeDate":"2099-08-15"}' +
        ']'
    $mySaleQ = "SELECT SaleMasterId,VoucherNumber,RoundOffAmount,Status,PosMode FROM salemaster WHERE BillTypeId='$PosSBill';"
    $pgSaleQ = "SELECT `"SaleMasterId`",`"VoucherNumber`",`"RoundOffAmount`",`"Status`",`"PosMode`" FROM salemaster WHERE `"BillTypeId`" = '$PosSBill';"
    $myPdcQ  = "SELECT CONCAT('[',PaymentMode,']'),Amount,Type,CONCAT('[',CAST(ChequeDate AS CHAR),']'),CONCAT('[',ChequeNumber,']'),Status FROM pdcdetails WHERE ReferenceId LIKE '$PosSBill-%' ORDER BY PaymentMode;"
    $pgPdcQ  = "SELECT '['||`"PaymentMode`"||']',`"Amount`",`"Type`",'['||`"ChequeDate`"||']','['||`"ChequeNumber`"||']',`"Status`" FROM pdcdetails WHERE `"ReferenceId`" LIKE '$PosSBill-%' ORDER BY `"PaymentMode`";"

    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Invoke-Endpoint -Url $PhpUrl -Body (New-SaleBody -RoundOff '1.25' -Pdc $bothCheques) | Out-Null
    $phpSaleUpd = Invoke-Endpoint -Url $PhpUrl -Body (New-SaleBody -MasterId "$PosSBill-0000000700" -RoundOff '' -Pdc $bothCheques)
    $mySaleRows = Get-MysqlRows $mySaleQ
    $myPdcRows  = Get-MysqlRows $myPdcQ

    Reset-WriteSeries -BillTypeId $PosSBill -Start 700 -Prefix '26-27KPY'
    Invoke-Endpoint -Url $NextUrl -Body (New-SaleBody -RoundOff '1.25' -Pdc $bothCheques) | Out-Null
    $nextSaleUpd = Invoke-Endpoint -Url $NextUrl -Body (New-SaleBody -MasterId "$PosSBill-0000000700" -RoundOff '' -Pdc $bothCheques)
    $pgSaleRows = Get-PgRows $pgSaleQ
    $pgPdcRows  = Get-PgRows $pgPdcQ

    if ($phpSaleUpd.Body -ceq $nextSaleUpd.Body) {
        $script:Pass++; Write-Host 'PASS  140. ... UPDATE path' -ForegroundColor Green
        Write-Host "      $($phpSaleUpd.Body)" -ForegroundColor DarkGray
    } else {
        $script:Fail++; Write-Host 'FAIL  140. ... UPDATE path' -ForegroundColor Red
        Write-Host "      PHP  $($phpSaleUpd.Body)" -ForegroundColor Yellow
        Write-Host "      NEXT $($nextSaleUpd.Body)" -ForegroundColor Cyan
    }
    # RoundOffAmount was omitted on the update, so 1.25 must have survived.
    Assert-SameRows -Name '140a. stored salemaster (RoundOffAmount preserved as 1.25)' -Mysql $mySaleRows -Postgres $pgSaleRows
    Assert-SameRows -Name '141. stored pdcdetails (ChequeDate 0000-00-00 and 2099-08-15)' -Mysql $myPdcRows -Postgres $pgPdcRows

    <#
        142. Blank date into a datetime column. KNOWN DIVERGENCE, not asserted.

        insert_ordercancelbybilltype is the only one of the three writes that
        defaults its date parameter to '' rather than leaving it null
        (firefly_api.php 7848). Non-strict MySQL coerces that into the datetime
        column as '0000-00-00 00:00:00' and reports SUCCESS; PostgreSQL rejects
        it, so the port answers ERROR.

        Same shape as the ChequeDate problem and deliberately NOT solved the same
        way. There, all 32 live pdcdetails rows hold the zero date, because the
        ERP sends a blank on every sale -- the zero value IS the normal case, so
        the column had to change type. Here, measured across every datetime
        column of the POS tables, zero production rows hold it: the ERP always
        sends OrderCancelDate, and only a malformed call gets here. Retyping
        every timestamp(0) column in all 42 tables to reproduce a value that
        exists nowhere would be a large change to make the port worse.

        Erroring is also the better behaviour -- '0000-00-00 00:00:00' is a
        corrupt date MySQL invented -- but it IS a behaviour change, so it is
        recorded rather than hidden. See README "Known divergences".
    #>
    Reset-WriteSeries -BillTypeId $PosCBill -Start 1
    Write-Host "`n--- 142. Blank OrderCancelDate into a datetime column (known divergence, informational) ---" -ForegroundColor Magenta
    Write-Host '      MySQL stores 0000-00-00 00:00:00 and reports SUCCESS; PostgreSQL rejects the write' -ForegroundColor DarkGray
    $blankDate = New-CancelBody
    $blankDate.OrderCancelDate = ''
    $phpBlank  = Invoke-Endpoint -Url $PhpUrl  -Body $blankDate
    $nextBlank = Invoke-Endpoint -Url $NextUrl -Body $blankDate
    Write-Host "          PHP  $($phpBlank.Body)"  -ForegroundColor Yellow
    Write-Host "          NEXT $($nextBlank.Body)" -ForegroundColor Cyan

    Reset-WriteSeries -BillTypeId $PosWBill -Start 1
    Reset-WriteSeries -BillTypeId $PosCBill -Start 1
    Reset-WriteSeries -BillTypeId $PosSBill -Start 1
}

Reset-PosRows

# ===========================================================================
# 143-162. Authentication and the credential endpoints.
#
# The master-data section ended with Reset-MasterRows and the organization was
# cleared even earlier, so all three fixtures have to be rebuilt here:
# customer_login joins ledger to organization, and login needs the user.
#
# The seeds are run through Compare-Case rather than seeded directly, which
# costs nothing and guarantees both databases hold identical rows before any
# auth assertion runs.
# ===========================================================================

Reset-MasterRows
Reset-TestRows

Write-Host "`n=== login / customer_login parity ===`n" -ForegroundColor White

Compare-Case -Name '143. seed organization for the auth fixtures' -Body (New-OrgBody)
Compare-Case -Name '144. seed user for the auth fixtures'         -Body (New-UserBody)
Compare-Case -Name '145. seed ledger for the auth fixtures'       -Body (New-LedgerBody)

# The success case also asserts the two SQL literals: CurrencySymbol is U+0930
# DEVANAGARI LETTER RA, which both stacks must emit escaped as र, and
# SubCurrencySymbol is a bare 'p'. Password comes back in the clear on both.
Compare-Case -Name '146. login (valid credentials)' -Body @{
    api = 'login'; UserName = 'zzuser'; Password = 'zzsecret'
}
Compare-Case -Name '147. login (wrong password -> the EMPTY sentinel)' -Body @{
    api = 'login'; UserName = 'zzuser'; Password = 'wrongpassword'
}
Compare-Case -Name '148. login (unknown user)' -Body @{
    api = 'login'; UserName = 'zznosuchuser'; Password = 'x'
}
# Both fields missing bind null, and `= NULL` matches nothing on either engine,
# so this is the sentinel envelope rather than an error.
Compare-Case -Name '149. login (no credentials posted at all)' -Body @{ api = 'login' }

# The payload key is Password, not mypassword -- the PHP binds $_POST['Password']
# against the l.mypassword column.
Compare-Case -Name '150. customer_login (valid credentials)' -Body @{
    api = 'customer_login'; UserName = 'zzledgeruser'; Password = 'zzledgersecret'
}
Compare-Case -Name '151. customer_login (wrong password)' -Body @{
    api = 'customer_login'; UserName = 'zzledgeruser'; Password = 'wrongpassword'
}

# IsActive=1 is part of the WHERE, so a deactivated customer gets the same
# generic message as a bad password -- no separate "account disabled" path.
& $Mysql -u root fireflydb -e "UPDATE ledger SET IsActive=0 WHERE LedgerId='$TestLedger';" 2>&1 | Out-Null
Invoke-Psql -Quiet "UPDATE ledger SET `"IsActive`" = 0 WHERE `"LedgerId`" = '$TestLedger';"
Compare-Case -Name '152. customer_login (IsActive=0 is refused like a bad password)' -Body @{
    api = 'customer_login'; UserName = 'zzledgeruser'; Password = 'zzledgersecret'
}
& $Mysql -u root fireflydb -e "UPDATE ledger SET IsActive=1 WHERE LedgerId='$TestLedger';" 2>&1 | Out-Null
Invoke-Psql -Quiet "UPDATE ledger SET `"IsActive`" = 1 WHERE `"LedgerId`" = '$TestLedger';"

Write-Host "`n=== privilege reads / uniqueness probes ===`n" -ForegroundColor White

# 'Set' rather than 'Bytes': neither PHP query carries an ORDER BY, so the two
# engines are free to return the seeded rows in a different sequence.
Compare-Case -Name '153. get_userprivileges (seeded user)' -Body @{
    api = 'get_userprivileges'; UserId = $TestUser
} -Mode 'Set'
Compare-Case -Name '154. get_userprivileges (unknown user -> "DATA NOT FOUND !!")' -Body @{
    api = 'get_userprivileges'; UserId = 'ZZNOSUCHUSER'
}

Compare-Case -Name '155. get_userprivileges_with_properties (nested Properties object)' -Body @{
    api = 'get_userprivileges_with_properties'; UserId = $TestUser
} -Mode 'Set'
# Zero rows returns null rather than the 'EMPTY' string, so no branch runs in the
# case block and the file-level defaults survive: ERROR / Something Went Wrong!!!
# / DATA null. None of the four envelopes in src/lib/read.ts produces that.
Compare-Case -Name '156. get_userprivileges_with_properties (unknown user -> DATA null, STATUS ERROR)' -Body @{
    api = 'get_userprivileges_with_properties'; UserId = 'ZZNOSUCHUSER'
}
# The isset() guard: DATA carries the *string* "UserId is required" and the case
# still calls that SUCCESS, because a non-empty string is not the EMPTY sentinel.
Compare-Case -Name '157. get_userprivileges_with_properties (UserId omitted -> SUCCESS + a string in DATA)' -Body @{
    api = 'get_userprivileges_with_properties'
}

# Both probes answer with the *string* "true"/"false" and always report SUCCESS;
# their 'No DATA found!!' branch is unreachable.
Compare-Case -Name '158. check_username (taken)' -Body @{
    api = 'check_username'; UserName = 'zzledgeruser'
}
Compare-Case -Name '159. check_username (free)' -Body @{
    api = 'check_username'; UserName = 'zznosuchledgeruser'
}
# Excludes the ledger being edited, so its own username reads as free.
Compare-Case -Name '160. check_usernamewithledger (own username -> free)' -Body @{
    api = 'check_usernamewithledger'; UserName = 'zzledgeruser'; LedgerId = $TestLedger
}
Compare-Case -Name '161. check_usernamewithledger (another ledger holds it -> taken)' -Body @{
    api = 'check_usernamewithledger'; UserName = 'zzledgeruser'; LedgerId = 'ZZ01-ZZLG-0000000099'
}

Write-Host "`n=== change_ledgerusernameandpassword ===`n" -ForegroundColor White

# Payload key mypassword here, unlike customer_login's Password.
Compare-Case -Name '162. change_ledgerusernameandpassword' -Body @{
    api = 'change_ledgerusernameandpassword'; LedgerId = $TestLedger
    UserName = 'zzledgeruser2'; mypassword = 'zzledgersecret2'
}
Write-Host "--- 163. Stored ledger credentials after the change ---" -ForegroundColor Magenta
& $Mysql -u root fireflydb -e "SELECT LedgerId, UserName, mypassword FROM ledger WHERE LedgerId='$TestLedger';"
Invoke-Psql "SELECT `"LedgerId`", `"UserName`", `"mypassword`" FROM ledger WHERE `"LedgerId`" = '$TestLedger';"

# A LedgerId matching nothing updates no rows and still reports success: the PHP
# never looks at the affected count.
Compare-Case -Name '164. change_ledgerusernameandpassword (LedgerId matches nothing)' -Body @{
    api = 'change_ledgerusernameandpassword'; LedgerId = 'ZZNOSUCHLEDGER'
    UserName = 'x'; mypassword = 'y'
}

<#
    165. Collation on the auth path. KNOWN DIVERGENCE, not asserted.

    user.UserName, user.Password, ledger.UserName and ledger.mypassword are all
    utf8mb4_unicode_ci in MySQL: case-insensitive and PAD SPACE. So 'ZZUSER' and
    'zzsecret   ' authenticate today. PostgreSQL's = is exact and rejects both.

    This is the loudest behaviour change in the batch, because the failure mode
    is a user who simply cannot log in. Recorded rather than reproduced -- see
    README "Known divergences" for the ICU collation that would restore it.
#>
Write-Host "`n--- 165. Case-insensitive credentials (known divergence, informational) ---" -ForegroundColor Magenta
Write-Host '      MySQL authenticates a wrong-case username; PostgreSQL does not' -ForegroundColor DarkGray
$upperUser = @{ api = 'login'; UserName = 'ZZUSER'; Password = 'zzsecret' }
$phpUpper  = Invoke-Endpoint -Url $PhpUrl  -Body $upperUser
$nextUpper = Invoke-Endpoint -Url $NextUrl -Body $upperUser
Write-Host "      login with UserName='ZZUSER' (stored as 'zzuser')" -ForegroundColor DarkGray
Write-Host "          PHP  $(Get-Status $phpUpper.Body)  $($phpUpper.Body)"  -ForegroundColor Yellow
Write-Host "          NEXT $(Get-Status $nextUpper.Body)  $($nextUpper.Body)" -ForegroundColor Cyan

$padPassword = @{ api = 'login'; UserName = 'zzuser'; Password = 'zzsecret   ' }
$phpPad  = Invoke-Endpoint -Url $PhpUrl  -Body $padPassword
$nextPad = Invoke-Endpoint -Url $NextUrl -Body $padPassword
Write-Host "      login with a trailing-space password" -ForegroundColor DarkGray
Write-Host "          PHP  $(Get-Status $phpPad.Body)"  -ForegroundColor Yellow
Write-Host "          NEXT $(Get-Status $nextPad.Body)" -ForegroundColor Cyan

# Note what this does and does not measure. It counts accounts whose usernames
# collide case-insensitively -- pairs that MySQL cannot tell apart and
# PostgreSQL can. Zero means the port introduces no ambiguity. It says nothing
# about the actual lockout risk, which is a user *typing* the wrong case, and
# which no query against the server can see.
Write-Host "      live MySQL accounts whose usernames collide case-insensitively:" -ForegroundColor DarkGray
& $Mysql -u root fireflydb -e "SELECT COUNT(*) AS colliding_pairs FROM ``user`` u JOIN ``user`` v ON u.UserName = v.UserName AND BINARY u.UserName <> BINARY v.UserName;"

Reset-MasterRows
Reset-TestRows

Write-Host "`n=== $script:Pass passed, $script:Fail failed ===`n" -ForegroundColor White
if ($script:Fail -gt 0) { exit 1 }
