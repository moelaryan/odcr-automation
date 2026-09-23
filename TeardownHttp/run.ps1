using namespace System.Net
param($Request, $TriggerMetadata)

try {
    $result = Invoke-OdcrTeardown
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
