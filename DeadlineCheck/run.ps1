# Fires at 8am ET (window close), every day. Emits the final status the alerts match on.
param($Timer)

$s = Get-OdcrStatus

$per = foreach ($rg in $s.regions) {
    $target = Get-OdcrTargetForRegion -Location $rg.region
    $reserved = if ($rg.exists -and $rg.state -eq 'Succeeded') { [int]$rg.capacity } else { 0 }
    [pscustomobject]@{ region = $rg.region; reserved = $reserved; target = $target }
}
$active = @($per | Where-Object { $_.target -gt 0 })
$total = $active.Count
$fulfilled = @($active | Where-Object { $_.reserved -ge $_.target }).Count
$anyReserved = @($active | Where-Object { $_.reserved -gt 0 }).Count
$detail = ($active | ForEach-Object { "$($_.region.ToUpper())=$($_.reserved)/$($_.target)" }) -join ' '

if ($total -gt 0 -and $fulfilled -eq $total) {
    Write-Host "ODCR_STATUS=FULFILLED regions=$fulfilled/$total detail=[$detail]"
}
elseif ($anyReserved -gt 0) {
    Write-Warning "ODCR_STATUS=PARTIAL regions=$fulfilled/$total detail=[$detail]"
}
else {
    Write-Error "ODCR_STATUS=FAILED reserved=0 regions=$total detail=[$detail]"
}
