param(
    [string]$DefaultUrl = "http://10.255.0.19/",
    [string]$TaskName = "CampusNetAutoLogin"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )

    if ([string]::IsNullOrWhiteSpace($Default)) {
        return (Read-Host $Prompt)
    }

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    return $value
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

function Remove-HtmlTags {
    param([string]$Text)

    $textWithoutTags = [regex]::Replace($Text, "(?is)<[^>]+>", "")
    return [System.Net.WebUtility]::HtmlDecode($textWithoutTags).Trim()
}

function Inspect-PortalPage {
    param([string]$Url)

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
    }
    catch {
        Write-Host "Could not read login page: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    $html = [string]$response.Content
    $inputs = @()
    foreach ($match in [regex]::Matches($html, "(?is)<input\b[^>]*>")) {
        $tag = $match.Value
        $name = Get-Attr -Tag $tag -Name "name"
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $inputs += [pscustomobject]@{
            Name = $name
            Type = (Get-Attr -Tag $tag -Name "type")
            Value = (Get-Attr -Tag $tag -Name "value")
        }
    }

    $selects = @()
    foreach ($match in [regex]::Matches($html, "(?is)<select\b[^>]*>.*?</select>")) {
        $block = $match.Value
        $name = Get-Attr -Tag $block -Name "name"
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $options = @()
        foreach ($optionMatch in [regex]::Matches($block, "(?is)<option\b[^>]*>(.*?)</option>")) {
            $optionTag = $optionMatch.Value
            $optionValue = Get-Attr -Tag $optionTag -Name "value"
            $optionText = Remove-HtmlTags -Text $optionMatch.Groups[1].Value
            if ($null -eq $optionValue) {
                $optionValue = $optionText
            }

            $options += [pscustomobject]@{
                Value = $optionValue
                Text = $optionText
            }
        }

        $selects += [pscustomobject]@{
            Name = $name
            Options = $options
        }
    }

    [pscustomobject]@{
        Inputs = $inputs
        Selects = $selects
    }
}

function Select-DefaultField {
    param(
        [object[]]$Fields,
        [string]$Pattern
    )

    foreach ($field in $Fields) {
        if ([string]$field.Name -match $Pattern) {
            return [string]$field.Name
        }
    }

    return ""
}

Write-Host ""
Write-Host "Campus network auto login - first setup" -ForegroundColor Cyan
Write-Host "The password will be encrypted for the current Windows user."
Write-Host ""

$url = Read-WithDefault -Prompt "Login URL" -Default $DefaultUrl
$inspection = Inspect-PortalPage -Url $url

$defaultUsernameField = ""
$defaultPasswordField = ""
$defaultOperatorField = ""
$operatorOptions = @()

if ($null -ne $inspection) {
    if ($inspection.Inputs.Count -gt 0) {
        Write-Host ""
        Write-Host "Detected input fields:" -ForegroundColor Cyan
        $inspection.Inputs | Format-Table Name, Type, Value -AutoSize
    }

    if ($inspection.Selects.Count -gt 0) {
        Write-Host ""
        Write-Host "Detected select fields:" -ForegroundColor Cyan
        foreach ($select in $inspection.Selects) {
            Write-Host "select name=$($select.Name)"
            $index = 1
            foreach ($option in $select.Options) {
                Write-Host ("  {0}. value='{1}' text='{2}'" -f $index, $option.Value, $option.Text)
                $index++
            }
        }
    }

    $defaultUsernameField = Select-DefaultField -Fields $inspection.Inputs -Pattern "(?i)user|account|login|name|uid|DDDDD|username"
    $passwordInput = $inspection.Inputs | Where-Object { $_.Type -and ([string]$_.Type).ToLowerInvariant() -eq "password" } | Select-Object -First 1
    if ($null -ne $passwordInput) {
        $defaultPasswordField = [string]$passwordInput.Name
    }
    else {
        $defaultPasswordField = Select-DefaultField -Fields $inspection.Inputs -Pattern "(?i)pass|pwd|PPPPP|password"
    }

    $operatorSelect = $inspection.Selects | Where-Object { [string]$_.Name -match "(?i)operator|carrier|isp|service|domain|net|yys" } | Select-Object -First 1
    if ($null -eq $operatorSelect) {
        $operatorSelect = $inspection.Selects | Select-Object -First 1
    }

    if ($null -ne $operatorSelect) {
        $defaultOperatorField = [string]$operatorSelect.Name
        $operatorOptions = @($operatorSelect.Options)
    }
}

Write-Host ""
$username = Read-Host "Account"
$securePassword = Read-Host "Password" -AsSecureString
$protectedPassword = ConvertFrom-SecureString $securePassword

$usernameField = Read-WithDefault -Prompt "Account field name" -Default $defaultUsernameField
$passwordField = Read-WithDefault -Prompt "Password field name" -Default $defaultPasswordField

if ([string]::IsNullOrWhiteSpace($usernameField) -or [string]::IsNullOrWhiteSpace($passwordField)) {
    throw "Account field or password field is empty. Fill in the correct form field name."
}

$operatorField = Read-WithDefault -Prompt "Operator field name; press Enter if none" -Default $defaultOperatorField
$operatorValue = ""
if (-not [string]::IsNullOrWhiteSpace($operatorField)) {
    if ($operatorOptions.Count -gt 0) {
        Write-Host ""
        Write-Host "For the operator, enter an option number or the raw value:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $operatorOptions.Count; $i++) {
            Write-Host ("  {0}. value='{1}' text='{2}'" -f ($i + 1), $operatorOptions[$i].Value, $operatorOptions[$i].Text)
        }
    }

    $operatorInput = Read-Host "Operator value/number"
    $selectedNumber = 0
    if ([int]::TryParse($operatorInput, [ref]$selectedNumber) -and $selectedNumber -ge 1 -and $selectedNumber -le $operatorOptions.Count) {
        $operatorValue = [string]$operatorOptions[$selectedNumber - 1].Value
    }
    else {
        $operatorValue = $operatorInput
    }
}

$usernameTemplate = Read-WithDefault -Prompt "Submitted account format, for example {username}@cmcc" -Default "{username}"

$installDir = Join-Path $env:LOCALAPPDATA "CampusNetAutoLogin"
New-Item -ItemType Directory -Force -Path $installDir | Out-Null

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$loginSource = Join-Path $scriptDir "campus-net-login.ps1"
$loginDest = Join-Path $installDir "campus-net-login.ps1"
$configPath = Join-Path $installDir "campus-net-config.json"

if (-not (Test-Path -LiteralPath $loginSource)) {
    throw "Login script was not found: $loginSource"
}

Copy-Item -LiteralPath $loginSource -Destination $loginDest -Force

$config = [ordered]@{
    Url = $url
    Username = $username
    Password = $protectedPassword
    UsernameField = $usernameField
    PasswordField = $passwordField
    OperatorField = $operatorField
    OperatorValue = $operatorValue
    UsernameTemplate = $usernameTemplate
    ExtraFields = @{}
    AuthMode = "DrCOM"
    AutoIncludeHiddenFields = $true
    CheckUrl = "http://www.msftconnecttest.com/connecttest.txt"
    CheckExpectedText = "Microsoft Connect Test"
}

$config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

$powershellExe = (Get-Command powershell.exe).Source
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$loginDest`" -ConfigPath `"$configPath`""
$action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn
try {
    $trigger.Delay = "PT30S"
}
catch {
    Write-Host "This system does not support task trigger delay. The task will run right after logon." -ForegroundColor Yellow
}

$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "Config file: $configPath"
Write-Host "Scheduled task: $TaskName"
Write-Host "Log file: $(Join-Path $installDir "login.log")"
Write-Host ""
Write-Host "Running one login test now..."
& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $loginDest -ConfigPath $configPath -MaxAttempts 1
Write-Host "Test finished. If internet is still unavailable, check the log and adjust the field names."
