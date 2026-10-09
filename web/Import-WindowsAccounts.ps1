[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PanelUrl,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$AccountName = "Windows - $env:USERNAME"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$panelUri = [Uri]$PanelUrl
if ($panelUri.Scheme -ne 'https') { throw 'PanelUrl must use HTTPS.' }
$PanelUrl = $PanelUrl.TrimEnd('/') + '/'
$headers = @{ 'X-AI-Ping' = '1'; Origin = $panelUri.GetLeftPart([UriPartial]::Authority) }
if (-not $Credential) { $Credential = $Host.UI.PromptForCredential('AI Ping', 'Panel login', 'ai-ping', '') }
if (-not $Credential) { throw 'Login cancelled.' }
$login = @{ username = $Credential.UserName; password = $Credential.GetNetworkCredential().Password } | ConvertTo-Json
$null = Invoke-RestMethod -Method Post -Uri ($PanelUrl + 'api/login') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($login)) -SessionVariable panelSession

try {
    foreach ($provider in @('claude', 'codex')) {
        $relativePath = if ($provider -eq 'claude') { '.claude\.credentials.json' } else { '.codex\auth.json' }
        $authPath = Join-Path $env:USERPROFILE $relativePath
        if (-not (Test-Path -LiteralPath $authPath)) { Write-Warning "$provider authorization file not found."; continue }
        $source = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($provider -eq 'claude') {
            $tokens = $source.claudeAiOauth
            if (-not $tokens.accessToken) { Write-Warning 'No Claude subscription token found.'; continue }
            $kept = @{ accessToken = $tokens.accessToken }
            if ($null -ne $tokens.scopes) { $kept.scopes = @($tokens.scopes) }
            if ($null -ne $tokens.expiresAt) { $kept.expiresAt = $tokens.expiresAt }
            $authorization = @{ claudeAiOauth = $kept }
        } else {
            $tokens = $source.tokens
            if (-not $tokens.access_token) { Write-Warning 'No Codex subscription token found.'; continue }
            $kept = @{ access_token = $tokens.access_token }
            if ($tokens.account_id) { $kept.account_id = $tokens.account_id }
            if ($tokens.id_token) { $kept.id_token = $tokens.id_token }
            $authorization = @{ tokens = $kept }
        }
        # Only subscription access fields are sent. API keys and refresh tokens are omitted.
        $body = @{ provider = $provider; name = "$AccountName - $provider"; authorization = $authorization } | ConvertTo-Json -Depth 10
        $result = Invoke-RestMethod -Method Post -Uri ($PanelUrl + 'api/accounts/import') -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -WebSession $panelSession
        Write-Output ("Imported: " + $result.account.name)
    }
} finally {
    $null = Invoke-RestMethod -Method Post -Uri ($PanelUrl + 'api/logout') -Headers $headers -ContentType 'application/json' -Body '{}' -WebSession $panelSession
}
