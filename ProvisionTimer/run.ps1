# Fires every 5 min across the 5-8am ET window, every day (TZ=America/New_York).
# Each tick idempotently tops up EVERY configured region; the schedule provides the ~3h retry.
param($Timer)

# Per-region targets are resolved inside the module from ODCR_TARGET_CAPACITY.
$result = Invoke-OdcrProvision

foreach ($r in $result.regions) {
    Write-Host "ProvisionTimer: [$($r.region)] $($r.status) reserved=$($r.reserved)/$($r.target)."
}

switch ($result.overall) {
    'FULFILLED' { Write-Host "ProvisionTimer: ALL FULFILLED ($($result.fulfilledRegions)/$($result.totalRegions) regions) mode=$($result.mode)." }
    'PARTIAL'   { Write-Warning "ProvisionTimer: PARTIAL ($($result.fulfilledRegions)/$($result.totalRegions) regions fulfilled), will keep topping up." }
    'FAILED'    { Write-Warning "ProvisionTimer: none secured yet across $($result.totalRegions) regions, will retry next tick." }
    default     { Write-Host "ProvisionTimer: overall=$($result.overall)." }
}
