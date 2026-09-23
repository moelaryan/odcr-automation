using namespace System.Net
param($Request, $TriggerMetadata)

# Optional override: ?capacity=N forces the same target for every region. Omit it to use
# the per-region ODCR_TARGET_CAPACITY map. 0 = resolve per-region.
$override = 0
if ($Request.Query.capacity)    { $override = [int]$Request.Query.capacity }
elseif ($Request.Body.capacity) { $override = [int]$Request.Body.capacity }

# Optional bounded retry for live demos; the real ~3-hour retry is the timer schedule.
$retryMinutes = 0
if ($Request.Query.retryMinutes) { $retryMinutes = [int]$Request.Query.retryMinutes }

try {
    $deadline = (Get-Date).AddMinutes($retryMinutes)
    do {
        $result = Invoke-OdcrProvision -TargetCapacity $override
        if ($result.overall -eq 'FULFILLED') { break }
        if (-not $result.retryable) { break }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 20
    } while ($true)

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($result | ConvertTo-Json -Depth 5)
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
    })
}
