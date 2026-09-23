param($Timer)

$result = Invoke-OdcrTeardown
foreach ($r in $result.regions) {
    Write-Host "TeardownTimer: [$($r.region)] $($r.status)"
}
