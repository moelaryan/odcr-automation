# ODCR logic via the ARM REST API using the managed-identity token (no Az modules).
$script:Api = '2024-07-01'
$script:CapacityPattern = 'SkuNotAvailable|CapacityRestriction|Capacity|Overconstrained|Allocation|NotAvailable'

function Get-OdcrConfig {
    # Multi-region: ODCR_LOCATIONS (comma/space/semicolon separated) drives the region set.
    # Falls back to the single ODCR_LOCATION for backward compatibility.
    $locs = @()
    if ($env:ODCR_LOCATIONS) {
        $locs = $env:ODCR_LOCATIONS -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() }
    }
    elseif ($env:ODCR_LOCATION) {
        $locs = @($env:ODCR_LOCATION.Trim().ToLower())
    }
    [pscustomobject]@{
        Sub       = $env:ODCR_SUBSCRIPTION_ID
        Rg        = $env:ODCR_RG
        Group     = $env:ODCR_GROUP
        Name      = $env:ODCR_NAME
        Locations = $locs
        Sku       = $env:ODCR_SKU
        Mode      = if ($env:ODCR_MODE) { $env:ODCR_MODE.Trim().ToLower() } else { 'parallel' }
    }
}

function Get-OdcrRegionResource {
    # Per-region CRG + reservation names (a CRG is single-region, so each region is isolated).
    param([string]$Location)
    $c = Get-OdcrConfig
    [pscustomobject]@{
        Group = "$($c.Group)-$Location"
        Name  = "$($c.Name)-$Location"
    }
}

function Get-OdcrToken {
    # Managed-identity ARM token from the Functions identity endpoint (local sidecar).
    $r = Invoke-RestMethod -Method Get -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } `
        -Uri "$($env:IDENTITY_ENDPOINT)?resource=https://management.azure.com/&api-version=2019-08-01"
    $r.access_token
}

function Invoke-OdcrArm {
    param([string]$Method, [string]$Path, $Body)
    $p = @{
        Method             = $Method
        Uri                = "https://management.azure.com$Path"
        Headers            = @{ Authorization = "Bearer $(Get-OdcrToken)"; 'Content-Type' = 'application/json' }
        SkipHttpErrorCheck = $true
    }
    if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10) }
    Invoke-WebRequest @p
}

function Wait-OdcrOperation {
    # Polls an async ARM operation to completion. Returns @{ ok = <bool>; error = <string> }.
    param($Response)
    $asyncUrl = $Response.Headers['Azure-AsyncOperation']
    if ($asyncUrl -is [array]) { $asyncUrl = $asyncUrl[0] }
    if (-not $asyncUrl) {
        if ($Response.StatusCode -ge 400) { return @{ ok = $false; error = "$($Response.Content)" } }
        return @{ ok = $true }
    }
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $op = Invoke-RestMethod -Method Get -Uri $asyncUrl -Headers @{ Authorization = "Bearer $(Get-OdcrToken)" }
        switch ($op.status) {
            'Succeeded' { return @{ ok = $true } }
            'Failed'    { return @{ ok = $false; error = ($op.error | ConvertTo-Json -Depth 6) } }
            'Canceled'  { return @{ ok = $false; error = 'Canceled' } }
        }
    }
    @{ ok = $false; error = 'operation timed out' }
}

function Get-OdcrReservationRegion {
    param([string]$Location)
    $c = Get-OdcrConfig
    $rn = Get-OdcrRegionResource -Location $Location
    $path = "/subscriptions/$($c.Sub)/resourceGroups/$($c.Rg)/providers/Microsoft.Compute/capacityReservationGroups/$($rn.Group)/capacityReservations/$($rn.Name)?api-version=$script:Api"
    $r = Invoke-OdcrArm -Method Get -Path $path
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 400) { throw "TERMINAL: $($r.Content)" }
    $r.Content | ConvertFrom-Json
}

function Invoke-OdcrProvisionRegion {
    <#
      Idempotent, REGIONAL. Tries to reach TargetCapacity in one region; if the full
      amount isn't available it secures the largest partial it can and tops up on later
      ticks. Capacity shortfalls are retryable; other failures throw. Returns a per-region
      record with status FULFILLED | PARTIAL | CAPACITY_UNAVAILABLE.
    #>
    param([string]$Location, [int]$TargetCapacity = 1)
    $c = Get-OdcrConfig
    $rn = Get-OdcrRegionResource -Location $Location
    $base = "/subscriptions/$($c.Sub)/resourceGroups/$($c.Rg)/providers/Microsoft.Compute/capacityReservationGroups/$($rn.Group)"
    $grpPath = "$base`?api-version=$script:Api"
    $resPath = "$base/capacityReservations/$($rn.Name)?api-version=$script:Api"

    # Ensure the regional group (idempotent PUT; no zones).
    $g = Invoke-OdcrArm -Method Put -Path $grpPath -Body @{ location = $Location }
    if ($g.StatusCode -ge 400) { throw "TERMINAL: [$Location] group create failed: $($g.Content)" }

    $existing = Get-OdcrReservationRegion -Location $Location
    $current = if ($existing -and $existing.properties.provisioningState -eq 'Succeeded') { [int]$existing.sku.capacity } else { 0 }
    if ($current -ge $TargetCapacity) {
        return [pscustomobject]@{ region = $Location; status = 'FULFILLED'; reserved = $current; target = $TargetCapacity; retryable = $false }
    }

    # Try full target, then a ~20% chunk, then +1, to grab partial capacity.
    $step = [Math]::Max(1, [int][Math]::Ceiling($TargetCapacity * 0.2))
    $tryList = @($TargetCapacity)
    if (($current + $step) -lt $TargetCapacity) { $tryList += ($current + $step) }
    if (($current + 1) -lt $TargetCapacity)     { $tryList += ($current + 1) }

    foreach ($want in $tryList) {
        $put = Invoke-OdcrArm -Method Put -Path $resPath -Body @{ location = $Location; sku = @{ name = $c.Sku; capacity = $want } }
        $res = Wait-OdcrOperation -Response $put
        if ($res.ok) {
            $st = if ($want -ge $TargetCapacity) { 'FULFILLED' } else { 'PARTIAL' }
            Write-Host "ODCR [$Location] $st reserved=$want target=$TargetCapacity (regional)."
            return [pscustomobject]@{ region = $Location; status = $st; reserved = $want; target = $TargetCapacity; retryable = ($st -eq 'PARTIAL') }
        }
        if ($res.error -notmatch $script:CapacityPattern) { throw "TERMINAL: [$Location] $($res.error)" }
        # capacity shortfall for this size -> try a smaller one
    }

    if ($current -gt 0) {
        return [pscustomobject]@{ region = $Location; status = 'PARTIAL'; reserved = $current; target = $TargetCapacity; retryable = $true }
    }
    Write-Warning "ODCR [$Location] capacity unavailable (will retry): none secured."
    [pscustomobject]@{ region = $Location; status = 'CAPACITY_UNAVAILABLE'; reserved = 0; target = $TargetCapacity; retryable = $true }
}

function Invoke-OdcrTeardownRegion {
    <# Deletes one region's reservation ONLY if it exists; leaves the group for reuse. #>
    param([string]$Location)
    $c = Get-OdcrConfig
    $rn = Get-OdcrRegionResource -Location $Location
    if (-not (Get-OdcrReservationRegion -Location $Location)) {
        Write-Host "[$Location] No reservation to tear down; skipping."
        return [pscustomobject]@{ region = $Location; status = 'NOTHING_TO_DO' }
    }
    $resPath = "/subscriptions/$($c.Sub)/resourceGroups/$($c.Rg)/providers/Microsoft.Compute/capacityReservationGroups/$($rn.Group)/capacityReservations/$($rn.Name)?api-version=$script:Api"
    $del = Invoke-OdcrArm -Method Delete -Path $resPath
    if ($del.StatusCode -ge 400 -and $del.StatusCode -ne 404) { throw "TERMINAL: [$Location] delete failed: $($del.Content)" }
    Write-Host "[$Location] Deleted reservation '$($rn.Name)'."
    [pscustomobject]@{ region = $Location; status = 'TORN_DOWN' }
}

function Get-OdcrStatusRegion {
    param([string]$Location)
    $r = Get-OdcrReservationRegion -Location $Location
    if (-not $r) { return [pscustomobject]@{ region = $Location; exists = $false; state = $null; sku = $null; capacity = 0 } }
    [pscustomobject]@{
        region   = $Location
        exists   = $true
        state    = $r.properties.provisioningState
        sku      = $r.sku.name
        capacity = [int]$r.sku.capacity
    }
}

function Get-OdcrTargetForRegion {
    # Resolves a region's target instance count. ODCR_TARGET_CAPACITY may be either a plain
    # integer (applies to all regions) or a per-region map, e.g. "eastus:20,westus2:10,default:5".
    # A non-zero Override (e.g. from the HTTP ?capacity=) wins for all regions.
    param([string]$Location, [int]$Override = 0)
    if ($Override -gt 0) { return $Override }
    $raw = $env:ODCR_TARGET_CAPACITY
    if (-not $raw) { return 1 }
    if ($raw -notmatch ':') { return [int]$raw }
    $map = @{}
    foreach ($pair in ($raw -split '[,;]+')) {
        $kv = $pair -split ':', 2
        if ($kv.Count -eq 2 -and $kv[0].Trim()) { $map[$kv[0].Trim().ToLower()] = [int]$kv[1].Trim() }
    }
    if ($map.ContainsKey($Location)) { return $map[$Location] }
    if ($map.ContainsKey('default')) { return $map['default'] }
    return 0  # region not listed and no default -> skip it
}

function Get-OdcrRollup {
    # Overall status across ACTIVE regions using each region's own target.
    param($Regions)
    $active = @($Regions | Where-Object { $_.status -ne 'SKIPPED' })
    $total = $active.Count
    $fulfilled = @($active | Where-Object { $_.reserved -ge $_.target }).Count
    $anyReserved = @($active | Where-Object { $_.reserved -gt 0 }).Count
    if ($total -gt 0 -and $fulfilled -eq $total) { return 'FULFILLED' }
    if ($anyReserved -gt 0) { return 'PARTIAL' }
    'FAILED'
}

function Invoke-OdcrProvision {
    <#
      PARALLEL mode (default): provisions/keeps an ODCR in EVERY configured region so the
      customer has simultaneous multi-region capacity. FALLBACK mode: stops at the first
      region that reaches FULFILLED. Returns a rollup with per-region detail.
    #>
    param([int]$TargetCapacity = 0)  # 0 => resolve each region's target from ODCR_TARGET_CAPACITY
    $c = Get-OdcrConfig
    $results = @()
    foreach ($loc in $c.Locations) {
        $t = Get-OdcrTargetForRegion -Location $loc -Override $TargetCapacity
        if ($t -le 0) {
            $results += [pscustomobject]@{ region = $loc; status = 'SKIPPED'; reserved = 0; target = 0; retryable = $false }
            continue
        }
        try { $r = Invoke-OdcrProvisionRegion -Location $loc -TargetCapacity $t }
        catch { $r = [pscustomobject]@{ region = $loc; status = 'ERROR'; reserved = 0; target = $t; retryable = $false; error = "$($_.Exception.Message)" } }
        $results += $r
        if ($c.Mode -eq 'fallback' -and $r.status -eq 'FULFILLED') { break }
    }
    $overall = Get-OdcrRollup -Regions $results
    $active = @($results | Where-Object { $_.status -ne 'SKIPPED' })
    [pscustomobject]@{
        mode             = $c.Mode
        overall          = $overall
        totalRegions     = $active.Count
        fulfilledRegions = @($active | Where-Object { $_.reserved -ge $_.target }).Count
        retryable        = [bool](@($results | Where-Object { $_.retryable }).Count)
        regions          = $results
    }
}

function Invoke-OdcrTeardown {
    <# Tears down the reservation in every configured region. #>
    $c = Get-OdcrConfig
    $results = @()
    foreach ($loc in $c.Locations) {
        try { $results += Invoke-OdcrTeardownRegion -Location $loc }
        catch { $results += [pscustomobject]@{ region = $loc; status = 'ERROR'; error = "$($_.Exception.Message)" } }
    }
    [pscustomobject]@{ regions = $results }
}

function Get-OdcrStatus {
    $c = Get-OdcrConfig
    $regions = @()
    foreach ($loc in $c.Locations) { $regions += Get-OdcrStatusRegion -Location $loc }
    [pscustomobject]@{ totalRegions = @($c.Locations).Count; regions = $regions }
}

Export-ModuleMember -Function Invoke-OdcrProvision, Invoke-OdcrTeardown, Get-OdcrStatus, Get-OdcrConfig, `
    Invoke-OdcrProvisionRegion, Invoke-OdcrTeardownRegion, Get-OdcrStatusRegion, Get-OdcrRegionResource, Get-OdcrTargetForRegion
