param(
    [string]$ConfigPath = "$PSScriptRoot\campus-net-config.json",
    [int]$MaxAttempts = 30,
    [int]$DelaySeconds = 2,
    [switch]$ForceLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$appDir = Join-Path $env:LOCALAPPDATA "CampusNetAutoLogin"
$logPath = Join-Path $appDir "login.log"
New-Item -ItemType Directory -Force -Path $appDir | Out-Null

function Write-Log {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

function ConvertFrom-ProtectedString {
    param([string]$ProtectedText)

    $secure = ConvertTo-SecureString $ProtectedText
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Get-Attr {
    param(
        [string]$Tag,
        [string]$Name
    )

    $escapedName = [regex]::Escape($Name)
    $pattern = "(?i)\b$escapedName\s*=\s*(""([^""]*)""|'([^']*)'|([^\s>]+))"
    $match = [regex]::Match($Tag, $pattern)
    if (-not $match.Success) {
        return $null
    }

    foreach ($index in 2, 3, 4) {
        if ($match.Groups[$index].Success) {
            return [System.Net.WebUtility]::HtmlDecode($match.Groups[$index].Value)
        }
    }

    return $null
}

function Get-FormInfo {
    param([string]$Html)

    $formMatch = [regex]::Match($Html, "(?is)<form\b[^>]*>")
    if (-not $formMatch.Success) {
        return [pscustomobject]@{
            Action = $null
            Method = "POST"
        }
    }

    $formTag = $formMatch.Value
    $method = Get-Attr -Tag $formTag -Name "method"
    if ([string]::IsNullOrWhiteSpace($method)) {
        $method = "POST"
    }

    [pscustomobject]@{
        Action = Get-Attr -Tag $formTag -Name "action"
        Method = $method.ToUpperInvariant()
    }
}

function Resolve-ActionUrl {
    param(
        [string]$BaseUrl,
        [string]$Action
    )

    $baseUri = [Uri]$BaseUrl
    if ([string]::IsNullOrWhiteSpace($Action)) {
        return $baseUri.AbsoluteUri
    }

    $actionUri = [Uri]::new($Action, [UriKind]::RelativeOrAbsolute)
    if ($actionUri.IsAbsoluteUri) {
        return $actionUri.AbsoluteUri
    }

    return ([Uri]::new($baseUri, $actionUri)).AbsoluteUri
}

function New-QueryString {
    param([hashtable]$Data)

    $parts = @()
    foreach ($key in $Data.Keys) {
        $encodedKey = [System.Net.WebUtility]::UrlEncode([string]$key)
        $encodedValue = [System.Net.WebUtility]::UrlEncode([string]$Data[$key])
        $parts += "$encodedKey=$encodedValue"
    }

    return ($parts -join "&")
}

function Get-SubmittedUsername {
    param($Config)

    $username = [string]$Config.Username
    $template = $Config.UsernameTemplate
    if ([string]::IsNullOrWhiteSpace($template)) {
        $template = "{username}"
    }

    if ($username -like "*@*" -and $template -match "^\{username\}@") {
        return $username
    }

    return $template.Replace("{username}", $username)
}

function ConvertFrom-Jsonp {
    param([string]$Text)

    $match = [regex]::Match($Text, "(?s)^[^(]*\((.*)\)\s*;?\s*$")
    if (-not $match.Success) {
        return $null
    }

    try {
        return ($match.Groups[1].Value | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-IsDrcomConfig {
    param($Config)

    if ($Config.PSObject.Properties.Name -contains "AuthMode" -and [string]$Config.AuthMode -eq "DrCOM") {
        return $true
    }

    try {
        $uri = [Uri]$Config.Url
        return ($uri.Host -eq "10.255.0.19")
    }
    catch {
        return $false
    }
}

function Add-HiddenFields {
    param(
        [hashtable]$Body,
        [string]$Html
    )

    $inputMatches = [regex]::Matches($Html, "(?is)<input\b[^>]*>")
    foreach ($inputMatch in $inputMatches) {
        $tag = $inputMatch.Value
        $type = Get-Attr -Tag $tag -Name "type"
        if ($type -and $type.ToLowerInvariant() -ne "hidden") {
            continue
        }

        $name = Get-Attr -Tag $tag -Name "name"
        if ([string]::IsNullOrWhiteSpace($name) -or $Body.ContainsKey($name)) {
            continue
        }

        $value = Get-Attr -Tag $tag -Name "value"
        if ($null -eq $value) {
            $value = ""
        }

        $Body[$name] = $value
    }
}

function Invoke-DrcomLogin {
    param(
        $Config,
        [string]$Password
    )

    $baseUri = [Uri]$Config.Url
    $loginUri = [Uri]::new($baseUri, "/drcom/login")
    $usernameValue = Get-SubmittedUsername -Config $Config
    $callback = "dr{0}" -f (Get-Random -Minimum 100000 -Maximum 999999)

    $data = @{
        callback = $callback
        DDDDD = $usernameValue
        upass = $Password
        "0MKKey" = "123456"
        R1 = "0"
        R3 = "0"
        R6 = "0"
        para = "00"
        v6ip = ""
    }

    $requestUri = "{0}?{1}" -f $loginUri.AbsoluteUri, (New-QueryString -Data $data)
    $response = Invoke-WebRequest -Uri $requestUri -UseBasicParsing -TimeoutSec 5
    $json = ConvertFrom-Jsonp -Text ([string]$response.Content)

    if ($null -ne $json) {
        $summary = "DrCOM response"
        if ($json.PSObject.Properties.Name -contains "result") {
            $summary += " result=$($json.result)"
        }
        if ($json.PSObject.Properties.Name -contains "msg" -and -not [string]::IsNullOrWhiteSpace([string]$json.msg)) {
            $summary += " msg=$($json.msg)"
        }
        if ($json.PSObject.Properties.Name -contains "ret_code" -and -not [string]::IsNullOrWhiteSpace([string]$json.ret_code)) {
            $summary += " ret_code=$($json.ret_code)"
        }
        Write-Log $summary
        if ($json.PSObject.Properties.Name -contains "result" -and ([string]$json.result -eq "1" -or [string]$json.result -eq "ok")) {
            return $true
        }
        return $false
    }
    else {
        Write-Log "DrCOM response could not be parsed. HTTP $($response.StatusCode)."
        return $false
    }
}

function Get-RegexValue {
    param(
        [string]$Text,
        [string]$Pattern
    )

    $match = [regex]::Match($Text, $Pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return ""
}

function Get-PortalClientInfo {
    param(
        [Uri]$BaseUri,
        [string]$Html
    )

    $info = [ordered]@{
        Ip = Get-RegexValue -Text $Html -Pattern "v4ip='([^']*)'"
        Ipv6 = Get-RegexValue -Text $Html -Pattern "v6ip='([^']*)'"
        Mac = Get-RegexValue -Text $Html -Pattern "ss4=`"([^`"]*)`""
        AcIp = Get-RegexValue -Text $Html -Pattern "ss6=`"([^`"]*)`""
        AcName = ""
    }

    try {
        $statusUri = [Uri]::new($BaseUri, "/drcom/chkstatus?callback=drstatus")
        $statusResponse = Invoke-WebRequest -Uri $statusUri.AbsoluteUri -UseBasicParsing -TimeoutSec 8
        $statusJson = ConvertFrom-Jsonp -Text ([string]$statusResponse.Content)
        if ($null -ne $statusJson) {
            foreach ($pair in @(
                @("Ip", "v46ip"),
                @("Ip", "v4ip"),
                @("Ip", "ss5"),
                @("Ipv6", "v6ip"),
                @("Mac", "ss4"),
                @("Mac", "olmac"),
                @("AcIp", "ss6")
            )) {
                $target = $pair[0]
                $source = $pair[1]
                if ([string]::IsNullOrWhiteSpace([string]$info[$target]) -and
                    $statusJson.PSObject.Properties.Name -contains $source -and
                    -not [string]::IsNullOrWhiteSpace([string]$statusJson.$source)) {
                    $info[$target] = [string]$statusJson.$source
                }
            }
        }
    }
    catch {
    }

    if ([string]::IsNullOrWhiteSpace([string]$info.Ip)) {
        $hexIp = Get-RegexValue -Text $Html -Pattern "ss3=`"([0-9a-fA-F]{8})`""
        if (-not [string]::IsNullOrWhiteSpace($hexIp)) {
            $octets = @()
            for ($i = 0; $i -lt 8; $i += 2) {
                $octets += [Convert]::ToInt32($hexIp.Substring($i, 2), 16)
            }
            $info.Ip = $octets -join "."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$info.Ip)) {
        $info.Ip = "0.0.0.0"
    }
    if ([string]::IsNullOrWhiteSpace([string]$info.Mac)) {
        $info.Mac = "000000000000"
    }

    [pscustomobject]$info
}

function Invoke-EportalLogin {
    param(
        $Config,
        [string]$Password,
        [string]$Html
    )

    $baseUri = [Uri]$Config.Url
    $builder = [UriBuilder]::new($baseUri.Scheme, $baseUri.Host, 801, "/eportal/")
    $loginUri = $builder.Uri.AbsoluteUri.TrimEnd("/") + "/"
    $usernameValue = Get-SubmittedUsername -Config $Config
    $client = Get-PortalClientInfo -BaseUri $baseUri -Html $Html
    $callback = "dr{0}" -f (Get-Random -Minimum 100000 -Maximum 999999)

    $data = @{
        callback = $callback
        c = "Portal"
        a = "login"
        login_method = "0"
        user_account = $usernameValue
        user_password = $Password
        wlan_user_ip = [string]$client.Ip
        wlan_user_ipv6 = [string]$client.Ipv6
        wlan_user_mac = [string]$client.Mac
        wlan_ac_ip = [string]$client.AcIp
        wlan_ac_name = [string]$client.AcName
        jsVersion = "3.3.2"
    }

    $requestUri = "{0}?{1}" -f $loginUri, (New-QueryString -Data $data)
    $response = Invoke-WebRequest -Uri $requestUri -UseBasicParsing -TimeoutSec 15
    $json = ConvertFrom-Jsonp -Text ([string]$response.Content)

    if ($null -eq $json) {
        Write-Log "Eportal response could not be parsed. HTTP $($response.StatusCode)."
        return $false
    }

    $summary = "Eportal response"
    if ($json.PSObject.Properties.Name -contains "result") {
        $summary += " result=$($json.result)"
    }
    if ($json.PSObject.Properties.Name -contains "msg" -and -not [string]::IsNullOrWhiteSpace([string]$json.msg)) {
        $summary += " msg=$($json.msg)"
    }
    if ($json.PSObject.Properties.Name -contains "ret_code" -and -not [string]::IsNullOrWhiteSpace([string]$json.ret_code)) {
        $summary += " ret_code=$($json.ret_code)"
    }
    Write-Log $summary
    if ($json.PSObject.Properties.Name -contains "result" -and ([string]$json.result -eq "1" -or [string]$json.result -eq "ok")) {
        return $true
    }
    return $false
}

function Test-Internet {
    param($Config)

    if (Test-IsDrcomConfig -Config $Config) {
        return (Test-CampusGatewayOnline -Config $Config)
    }

    $checkUrl = $Config.CheckUrl
    if ([string]::IsNullOrWhiteSpace($checkUrl)) {
        $checkUrl = "http://www.msftconnecttest.com/connecttest.txt"
    }

    $expected = $Config.CheckExpectedText
    if ([string]::IsNullOrWhiteSpace($expected)) {
        $expected = "Microsoft Connect Test"
    }

    try {
        $response = Invoke-WebRequest -Uri $checkUrl -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -ne 200) {
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($expected)) {
            return $true
        }

        if ($response.Content -like "*$expected*") {
            return $true
        }
    }
    catch {
    }

    return (Test-CampusGatewayOnline -Config $Config)
}

function Test-CampusGatewayOnline {
    param($Config)

    try {
        $baseUri = [Uri]$Config.Url
        $statusUri = [Uri]::new($baseUri, "/drcom/chkstatus?callback=drstatus")
        $response = Invoke-WebRequest -Uri $statusUri.AbsoluteUri -UseBasicParsing -TimeoutSec 1
        $json = ConvertFrom-Jsonp -Text ([string]$response.Content)
        if ($null -eq $json) {
            return $false
        }

        $isOnline = ($json.PSObject.Properties.Name -contains "result" -and [string]$json.result -eq "1")
        $hasUser = ($json.PSObject.Properties.Name -contains "uid" -and -not [string]::IsNullOrWhiteSpace([string]$json.uid))
        return ($isOnline -and $hasUser)
    }
    catch {
        return $false
    }
}

function Invoke-CampusLogin {
    param($Config)

    $plainPassword = ConvertFrom-ProtectedString -ProtectedText $Config.Password
    if (Test-IsDrcomConfig -Config $Config) {
        return (Invoke-EportalLogin -Config $Config -Password $plainPassword -Html "")
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $loginPage = Invoke-WebRequest -Uri $Config.Url -WebSession $session -UseBasicParsing -TimeoutSec 5
    $html = [string]$loginPage.Content

    if ($html -match "Dr\.COMWebLoginID|/drcom/|authloginpath|ISP_select") {
        return (Invoke-DrcomLogin -Config $Config -Password $plainPassword)
    }

    $form = Get-FormInfo -Html $html
    $submitUrl = Resolve-ActionUrl -BaseUrl $Config.Url -Action $form.Action

    $usernameValue = Get-SubmittedUsername -Config $Config

    $body = @{}
    $body[[string]$Config.UsernameField] = $usernameValue
    $body[[string]$Config.PasswordField] = $plainPassword

    if (-not [string]::IsNullOrWhiteSpace($Config.OperatorField)) {
        $body[[string]$Config.OperatorField] = [string]$Config.OperatorValue
    }

    if ($Config.PSObject.Properties.Name -contains "ExtraFields" -and $null -ne $Config.ExtraFields) {
        foreach ($property in $Config.ExtraFields.PSObject.Properties) {
            $body[[string]$property.Name] = [string]$property.Value
        }
    }

    if ($Config.AutoIncludeHiddenFields) {
        Add-HiddenFields -Body $body -Html $html
    }

    if ($form.Method -eq "GET") {
        Invoke-WebRequest -Uri $submitUrl -Method Get -Body $body -WebSession $session -UseBasicParsing -TimeoutSec 15 | Out-Null
    }
    else {
        Invoke-WebRequest -Uri $submitUrl -Method Post -Body $body -WebSession $session -ContentType "application/x-www-form-urlencoded" -UseBasicParsing -TimeoutSec 15 | Out-Null
    }

    return $false
}

function Wait-InternetAfterLogin {
    param(
        $Config,
        [int]$TimeoutSeconds = 5,
        [int]$IntervalSeconds = 1
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds $IntervalSeconds
        if (Test-Internet -Config $Config) {
            return $true
        }
    } while ((Get-Date) -lt $deadline)

    return $false
}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Log "Started. Url=$($config.Url), MaxAttempts=$MaxAttempts"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not $ForceLogin -and (Test-Internet -Config $config)) {
            Write-Log "Internet is already available."
            exit 0
        }

        try {
            Write-Log "Attempt ${attempt}: submitting campus login."
            $loginAccepted = Invoke-CampusLogin -Config $config
            if ($loginAccepted) {
                Write-Log "Login accepted by gateway."
                exit 0
            }

            if (Wait-InternetAfterLogin -Config $config) {
                Write-Log "Login succeeded."
                exit 0
            }

            Write-Log "Attempt $attempt did not pass connectivity check."
        }
        catch {
            Write-Log "Attempt $attempt failed: $($_.Exception.Message)"
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Log "Stopped after $MaxAttempts attempts without confirmed internet access."
    exit 1
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)"
    exit 1
}
