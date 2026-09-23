# SCR Demo — Reproducible Walkthrough

A ~5-minute live demo of **SCR (Scheduled Capacity Reservation)** provisioning capacity
across multiple regions in parallel. Everything here is read-safe except the optional
manual `provision`/`teardown` calls, which create/delete real reservations.

## Prerequisites

- Access to the subscription and resource group hosting the SCR function app.
- [Azure CLI](https://learn.microsoft.com/cli/azure/) (`az login` completed).
- PowerShell 7.x.

Set these once for the session (adjust to your deployment):

```powershell
$rg  = 'odcr-demo-rg'
$app = 'odcr-demo-func-34840'
$key = az functionapp keys list -g $rg -n $app --query "functionKeys.default" -o tsv
$base = "https://$app.azurewebsites.net/api"
```

## 1. Show the config (the "no redeploy" story)

```powershell
az functionapp config appsettings list -g $rg -n $app -o json |
  ConvertFrom-Json | Where-Object { $_.name -like 'ODCR_*' } |
  ForEach-Object { "{0} = {1}" -f $_.name, $_.value }
```

Point out: `ODCR_LOCATIONS` (region list), `ODCR_MODE=parallel`, and the per-region
`ODCR_TARGET_CAPACITY` map (`eastus:3,centralus:2,...`).

## 2. Show the multi-region footprint

In the portal: resource group → **Capacity Reservation Groups** → note one
`<group>-<region>` per configured region. Or via CLI:

```powershell
az capacity reservation group list -g $rg --query "[].{name:name, location:location}" -o table
```

## 3. Check current status

```powershell
Invoke-RestMethod -Method Post -Uri "$base/statushttp" -Headers @{ 'x-functions-key'=$key } |
  ConvertTo-Json -Depth 6
```

## 4. Provision live (the money shot)

Each region attempts its **own target** in parallel:

```powershell
$r = Invoke-RestMethod -Method Post -Uri "$base/provisionhttp" `
  -Headers @{ 'x-functions-key'=$key } -ContentType 'application/json'
$r.regions | Select-Object region, status, reserved, target | Format-Table -AutoSize
"overall=$($r.overall)  fulfilled=$($r.fulfilledRegions)/$($r.totalRegions)  mode=$($r.mode)"
```

**What to say:** each region shows its own `target`. `FULFILLED`/`PARTIAL` require real
capacity; in a constrained/sandbox sub you'll see `CAPACITY_UNAVAILABLE` — that's the
retry path, not a bug. In a capacity-backed sub these return `FULFILLED`.

> Optional override — force the same count everywhere for a quick test:
> `Invoke-RestMethod -Method Post -Uri "$base/provisionhttp?capacity=1" -Headers @{ 'x-functions-key'=$key }`

## 5. Show the audit trail (Application Insights)

Portal → the app's **Application Insights** → **Logs**:

```kusto
union traces, exceptions
| where message has "ODCR_STATUS" or outerMessage has "ODCR_STATUS"
| project timestamp, message, outerMessage
| order by timestamp desc
```

`DeadlineCheck` emits `ODCR_STATUS=FULFILLED|PARTIAL|FAILED` with per-region detail at
window close — this is what the alert rules match.

## 6. Show alerting

Portal → resource group → the three scheduled query rules
(`odcr-status-fulfilled` Sev3, `odcr-status-partial` Sev2, `odcr-status-failed` Sev1)
and the **`odcr-alerts-ag`** action group (email + SMS receivers).

## 7. (Optional) Release now

```powershell
Invoke-RestMethod -Method Post -Uri "$base/teardownhttp" -Headers @{ 'x-functions-key'=$key } |
  ConvertTo-Json -Depth 6
```

Deletes each region's **reservation** (releasing the cost) but leaves the reservation
**group** for reuse. Running VMs, if any, are untouched.

## Talking points / expected questions

| Question | Answer |
|----------|--------|
| Why `CAPACITY_UNAVAILABLE`? | Sandbox has no allocatable capacity for the test SKU; proves the mechanics. Real sub with quota + capacity returns `FULFILLED`. |
| One region has no capacity? | Parallel mode still secures the others; the failed one retries every 5 min for ~3 hrs. |
| Change VM counts per region? | One app setting: `ODCR_TARGET_CAPACITY=eastus:40,westus2:15,default:5`. No redeploy. |
| Any secrets? | None — managed identity + RBAC only. |
| VM still running at teardown? | Teardown releases idle reservations; a safety-check to skip in-use regions is on the roadmap. |
