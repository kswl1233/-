param(
    [string]$DefaultUrl = "http://10.255.0.19/",
    [string]$TaskName = "CampusNetAutoLogin",
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

function S {
    param([string]$Hex)

    $chars = @()
    foreach ($part in ($Hex -split "\s+")) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }
        $chars += [char]([Convert]::ToInt32($part, 16))
    }
    return -join $chars
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 120,
        [int]$H = 26
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
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

function Inspect-PortalPage {
    param([string]$Url)

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15
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

            if ([string]::IsNullOrWhiteSpace($optionText)) {
                continue
            }

            $options += [pscustomobject]@{
                Text = $optionText
                Value = $optionValue
            }
        }

        $selects += [pscustomobject]@{
            Name = $name
            Options = $options
        }
    }

    $carrierMatch = [regex]::Match($html, "(?is)carrier\s*=\s*'([^']+)'")
    if ($carrierMatch.Success) {
        try {
            $carrierJson = [System.Net.WebUtility]::HtmlDecode($carrierMatch.Groups[1].Value)
            $carrierData = $carrierJson | ConvertFrom-Json
            if ($carrierData.PSObject.Properties.Name -contains "yys" -and $carrierData.yys.data) {
                $carrierOptions = @()
                foreach ($item in $carrierData.yys.data) {
                    $carrierOptions += [pscustomobject]@{
                        Text = [string]$item.name
                        Value = [string]$item.suffix
                    }
                }

                if ($carrierOptions.Count -gt 0) {
                    $selects += [pscustomobject]@{
                        Name = ""
                        Options = $carrierOptions
                    }
                }
            }
        }
        catch {
        }
    }

    $usernameField = Select-DefaultField -Fields $inputs -Pattern "(?i)user|account|login|name|uid|DDDDD|username"
    $passwordInput = $inputs | Where-Object { $_.Type -and ([string]$_.Type).ToLowerInvariant() -eq "password" } | Select-Object -First 1
    if ($null -ne $passwordInput) {
        $passwordField = [string]$passwordInput.Name
    }
    else {
        $passwordField = Select-DefaultField -Fields $inputs -Pattern "(?i)pass|pwd|PPPPP|password|upass"
    }

    $operatorSelect = $selects | Where-Object { [string]$_.Name -match "(?i)operator|carrier|isp|service|domain|net|yys|select|DDDDD" } | Select-Object -First 1
    if ($null -eq $operatorSelect) {
        $operatorSelect = $selects | Select-Object -First 1
    }

    [pscustomobject]@{
        UsernameField = $usernameField
        PasswordField = $passwordField
        OperatorField = if ($null -ne $operatorSelect) { [string]$operatorSelect.Name } else { "" }
        OperatorOptions = if ($null -ne $operatorSelect) { @($operatorSelect.Options) } else { @() }
    }
}

function ConvertFrom-ProtectedString {
    param([string]$ProtectedText)

    if ([string]::IsNullOrWhiteSpace($ProtectedText)) {
        return ""
    }

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

function Register-AutoLoginTask {
    param(
        [string]$LoginScript,
        [string]$ConfigPath
    )

    $powershellExe = (Get-Command powershell.exe).Source
    $arguments = "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$LoginScript`" -ConfigPath `"$ConfigPath`""
    $action = New-ScheduledTaskAction -Execute $powershellExe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    try {
        $trigger.Delay = "PT5S"
    }
    catch {
    }

    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}

function New-OperatorItem {
    param(
        [string]$Text,
        [string]$Value
    )

    [pscustomobject]@{
        Text = $Text
        Value = $Value
    }
}

function Normalize-OperatorSuffix {
    param([string]$Value)

    switch ($Value) {
        "@dx" { return "@aust" }
        "@lt" { return "@unicom" }
        default { return $Value }
    }
}

function Select-OperatorValue {
    param([string]$Value)

    $Value = Normalize-OperatorSuffix -Value $Value
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    for ($i = 0; $i -lt $cmbOperator.Items.Count; $i++) {
        if ([string]$cmbOperator.Items[$i].Value -eq $Value) {
            $cmbOperator.SelectedIndex = $i
            return
        }
    }
}

$installDir = Join-Path $env:LOCALAPPDATA "CampusNetAutoLogin"
$configPath = Join-Path $installDir "campus-net-config.json"
$installedLoginScript = Join-Path $installDir "campus-net-login.ps1"
$sourceLoginScript = Join-Path $PSScriptRoot "campus-net-login.ps1"
$logPath = Join-Path $installDir "login.log"
$existingConfig = $null

if (Test-Path -LiteralPath $configPath) {
    try {
        $existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $existingConfig = $null
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = S "6821 56ED 7F51 81EA 52A8 767B 5F55"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(760, 590)
$form.MinimumSize = New-Object System.Drawing.Size(720, 560)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)
$form.BackColor = [System.Drawing.Color]::White

$title = New-Object System.Windows.Forms.Label
$title.Text = S "5B89 5FBD 7406 5DE5 5927 5B66 6821 56ED 7F51 81EA 52A8 767B 5F55"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 18, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(28, 79, 130)
$title.Location = New-Object System.Drawing.Point(32, 24)
$title.Size = New-Object System.Drawing.Size(680, 42)
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = S "586B 5B66 53F7 3001 5BC6 7801 3001 51FA 53E3 FF0C 70B9 51FB 4FDD 5B58 5C31 53EF 4EE5 5F00 673A 81EA 52A8 767B 5F55"
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$subtitle.Location = New-Object System.Drawing.Point(34, 66)
$subtitle.Size = New-Object System.Drawing.Size(680, 28)
$form.Controls.Add($subtitle)

$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Location = New-Object System.Drawing.Point(32, 112)
$mainPanel.Size = New-Object System.Drawing.Size(680, 225)
$mainPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($mainPanel)

$lblUrl = New-Label -Text (S "767B 5F55 7F51 5740") -X 24 -Y 24 -W 110
$txtUrl = New-Object System.Windows.Forms.TextBox
$txtUrl.Location = New-Object System.Drawing.Point(150, 24)
$txtUrl.Size = New-Object System.Drawing.Size(470, 28)
$txtUrl.Text = if ($existingConfig -and $existingConfig.Url) { [string]$existingConfig.Url } else { $DefaultUrl }

$lblAccount = New-Label -Text (S "5B66 53F7 002F 5DE5 53F7") -X 24 -Y 68 -W 110
$txtAccount = New-Object System.Windows.Forms.TextBox
$txtAccount.Location = New-Object System.Drawing.Point(150, 68)
$txtAccount.Size = New-Object System.Drawing.Size(470, 28)
$txtAccount.Text = if ($existingConfig -and $existingConfig.Username) { [string]$existingConfig.Username } else { "" }

$lblPassword = New-Label -Text (S "5BC6 7801") -X 24 -Y 112 -W 110
$txtPassword = New-Object System.Windows.Forms.TextBox
$txtPassword.Location = New-Object System.Drawing.Point(150, 112)
$txtPassword.Size = New-Object System.Drawing.Size(470, 28)
$txtPassword.UseSystemPasswordChar = $true

$lblOperator = New-Label -Text (S "9009 62E9 51FA 53E3") -X 24 -Y 156 -W 110
$cmbOperator = New-Object System.Windows.Forms.ComboBox
$cmbOperator.Location = New-Object System.Drawing.Point(150, 156)
$cmbOperator.Size = New-Object System.Drawing.Size(470, 30)
$cmbOperator.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbOperator.DisplayMember = "Text"
$cmbOperator.ValueMember = "Value"
[void]$cmbOperator.Items.Add((New-OperatorItem -Text (S "5B66 751F 7535 4FE1 51FA 53E3") -Value "@aust"))
[void]$cmbOperator.Items.Add((New-OperatorItem -Text (S "5B66 751F 8054 901A 51FA 53E3") -Value "@unicom"))
[void]$cmbOperator.Items.Add((New-OperatorItem -Text (S "5B66 751F 79FB 52A8 51FA 53E3") -Value "@cmcc"))
[void]$cmbOperator.Items.Add((New-OperatorItem -Text (S "6559 804C 5DE5 51FA 53E3") -Value "@jzg"))
$cmbOperator.SelectedIndex = 0

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = S "5F00 673A 002F 767B 5F55 540E 81EA 52A8 8FD0 884C"
$chkAuto.Location = New-Object System.Drawing.Point(150, 193)
$chkAuto.Size = New-Object System.Drawing.Size(300, 28)
$chkAuto.Checked = $true

$mainPanel.Controls.AddRange(@($lblUrl, $txtUrl, $lblAccount, $txtAccount, $lblPassword, $txtPassword, $lblOperator, $cmbOperator, $chkAuto))

$btnDetect = New-Object System.Windows.Forms.Button
$btnDetect.Text = S "8BFB 53D6 7F51 9875 767B 5F55 9879"
$btnDetect.Location = New-Object System.Drawing.Point(32, 354)
$btnDetect.Size = New-Object System.Drawing.Size(154, 38)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = S "4FDD 5B58 5E76 5F00 542F 81EA 52A8 767B 5F55"
$btnSave.Location = New-Object System.Drawing.Point(202, 354)
$btnSave.Size = New-Object System.Drawing.Size(190, 38)
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(54, 102, 154)
$btnSave.ForeColor = [System.Drawing.Color]::White
$btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = S "6D4B 8BD5 767B 5F55"
$btnTest.Location = New-Object System.Drawing.Point(408, 354)
$btnTest.Size = New-Object System.Drawing.Size(124, 38)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = S "5220 9664 81EA 52A8 767B 5F55"
$btnDelete.Location = New-Object System.Drawing.Point(548, 354)
$btnDelete.Size = New-Object System.Drawing.Size(164, 38)

$form.Controls.AddRange(@($btnDetect, $btnSave, $btnTest, $btnDelete))

$chkAdvanced = New-Object System.Windows.Forms.CheckBox
$chkAdvanced.Text = S "9AD8 7EA7 8BBE 7F6E"
$chkAdvanced.Location = New-Object System.Drawing.Point(36, 406)
$chkAdvanced.Size = New-Object System.Drawing.Size(160, 28)
$form.Controls.Add($chkAdvanced)

$advancedPanel = New-Object System.Windows.Forms.Panel
$advancedPanel.Location = New-Object System.Drawing.Point(32, 438)
$advancedPanel.Size = New-Object System.Drawing.Size(680, 72)
$advancedPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$advancedPanel.Visible = $false
$form.Controls.Add($advancedPanel)

$txtUserField = New-Object System.Windows.Forms.TextBox
$txtPassField = New-Object System.Windows.Forms.TextBox
$txtOperatorField = New-Object System.Windows.Forms.TextBox
$txtOperatorValue = New-Object System.Windows.Forms.TextBox
$txtUsernameTemplate = New-Object System.Windows.Forms.TextBox

$txtUserField.Location = New-Object System.Drawing.Point(110, 10)
$txtUserField.Size = New-Object System.Drawing.Size(100, 24)
$txtPassField.Location = New-Object System.Drawing.Point(300, 10)
$txtPassField.Size = New-Object System.Drawing.Size(100, 24)
$txtOperatorField.Location = New-Object System.Drawing.Point(510, 10)
$txtOperatorField.Size = New-Object System.Drawing.Size(130, 24)
$txtOperatorValue.Location = New-Object System.Drawing.Point(110, 42)
$txtOperatorValue.Size = New-Object System.Drawing.Size(180, 24)
$txtUsernameTemplate.Location = New-Object System.Drawing.Point(430, 42)
$txtUsernameTemplate.Size = New-Object System.Drawing.Size(210, 24)

$advancedPanel.Controls.AddRange(@(
    (New-Label -Text "Account field" -X 14 -Y 8 -W 95 -H 24),
    $txtUserField,
    (New-Label -Text "Password field" -X 220 -Y 8 -W 78 -H 24),
    $txtPassField,
    (New-Label -Text "Operator field" -X 410 -Y 8 -W 96 -H 24),
    $txtOperatorField,
    (New-Label -Text "Operator value" -X 14 -Y 40 -W 95 -H 24),
    $txtOperatorValue,
    (New-Label -Text "Account format" -X 320 -Y 40 -W 106 -H 24),
    $txtUsernameTemplate
))

$txtUserField.Text = if ($existingConfig -and $existingConfig.UsernameField) { [string]$existingConfig.UsernameField } else { "" }
$txtPassField.Text = if ($existingConfig -and $existingConfig.PasswordField) { [string]$existingConfig.PasswordField } else { "" }
$txtOperatorField.Text = if ($existingConfig -and $existingConfig.OperatorField) { [string]$existingConfig.OperatorField } else { "" }
$txtOperatorValue.Text = if ($existingConfig -and $existingConfig.OperatorValue) { [string]$existingConfig.OperatorValue } else { "" }
$txtUsernameTemplate.Text = if ($existingConfig -and $existingConfig.UsernameTemplate) { [string]$existingConfig.UsernameTemplate } else { "{username}" }

if ($txtUsernameTemplate.Text -match "\{username\}(@[A-Za-z0-9_.-]+)") {
    Select-OperatorValue -Value $Matches[1]
}
elseif ($existingConfig -and $existingConfig.OperatorValue) {
    Select-OperatorValue -Value ([string]$existingConfig.OperatorValue)
}

$status = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(34, 520)
$status.Size = New-Object System.Drawing.Size(510, 26)
$status.ForeColor = [System.Drawing.Color]::FromArgb(62, 100, 72)
$status.Text = S "51C6 5907 5C31 7EEA"
$form.Controls.Add($status)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = S "6253 5F00 65E5 5FD7"
$btnLog.Location = New-Object System.Drawing.Point(588, 516)
$btnLog.Size = New-Object System.Drawing.Size(124, 32)
$form.Controls.Add($btnLog)

function Set-Status {
    param(
        [string]$Message,
        [bool]$IsError = $false
    )

    $status.Text = $Message
    if ($IsError) {
        $status.ForeColor = [System.Drawing.Color]::FromArgb(150, 45, 45)
    }
    else {
        $status.ForeColor = [System.Drawing.Color]::FromArgb(62, 100, 72)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Apply-DetectedPortalInfo {
    param($Info)

    if (-not [string]::IsNullOrWhiteSpace($Info.UsernameField)) {
        $txtUserField.Text = [string]$Info.UsernameField
    }
    if (-not [string]::IsNullOrWhiteSpace($Info.PasswordField)) {
        $txtPassField.Text = [string]$Info.PasswordField
    }
    if (-not [string]::IsNullOrWhiteSpace($Info.OperatorField)) {
        $txtOperatorField.Text = [string]$Info.OperatorField
    }

    if ($Info.OperatorOptions.Count -gt 0) {
        $cmbOperator.Items.Clear()
        foreach ($option in $Info.OperatorOptions) {
            [void]$cmbOperator.Items.Add((New-OperatorItem -Text ([string]$option.Text) -Value (Normalize-OperatorSuffix -Value ([string]$option.Value))))
        }
        $cmbOperator.SelectedIndex = 0
        $txtOperatorValue.Text = [string]$cmbOperator.SelectedItem.Value
    }
}

function Save-CurrentConfig {
    param([bool]$RegisterTask)

    if ([string]::IsNullOrWhiteSpace($txtUrl.Text)) {
        throw "Login URL is required."
    }
    if ([string]::IsNullOrWhiteSpace($txtAccount.Text)) {
        throw "Account is required."
    }
    if ([string]::IsNullOrWhiteSpace($txtPassword.Text) -and -not ($existingConfig -and $existingConfig.Password)) {
        throw "Password is required."
    }
    if ([string]::IsNullOrWhiteSpace($txtUserField.Text) -or [string]::IsNullOrWhiteSpace($txtPassField.Text)) {
        try {
            $info = Inspect-PortalPage -Url $txtUrl.Text
            Apply-DetectedPortalInfo -Info $info
        }
        catch {
        }
    }
    if ([string]::IsNullOrWhiteSpace($txtUserField.Text)) {
        $txtUserField.Text = "DDDDD"
    }
    if ([string]::IsNullOrWhiteSpace($txtPassField.Text)) {
        $txtPassField.Text = "upass"
    }

    if ($cmbOperator.SelectedItem) {
        $selectedOperatorValue = Normalize-OperatorSuffix -Value ([string]$cmbOperator.SelectedItem.Value)
        $txtOperatorValue.Text = $selectedOperatorValue
        if ($selectedOperatorValue.StartsWith("@") -and [string]::IsNullOrWhiteSpace($txtOperatorField.Text)) {
            $txtUsernameTemplate.Text = "{username}$selectedOperatorValue"
        }
    }

    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    if (-not (Test-Path -LiteralPath $sourceLoginScript)) {
        throw "campus-net-login.ps1 was not found next to the GUI script."
    }
    Copy-Item -LiteralPath $sourceLoginScript -Destination $installedLoginScript -Force

    if ([string]::IsNullOrWhiteSpace($txtPassword.Text)) {
        $protectedPassword = [string]$existingConfig.Password
    }
    else {
        $securePassword = ConvertTo-SecureString $txtPassword.Text -AsPlainText -Force
        $protectedPassword = ConvertFrom-SecureString $securePassword
    }

    $config = [ordered]@{
        Url = $txtUrl.Text.Trim()
        Username = $txtAccount.Text.Trim()
        Password = $protectedPassword
        UsernameField = $txtUserField.Text.Trim()
        PasswordField = $txtPassField.Text.Trim()
        OperatorField = $txtOperatorField.Text.Trim()
        OperatorValue = $txtOperatorValue.Text.Trim()
        UsernameTemplate = if ([string]::IsNullOrWhiteSpace($txtUsernameTemplate.Text)) { "{username}" } else { $txtUsernameTemplate.Text.Trim() }
        ExtraFields = @{}
        AuthMode = "DrCOM"
        AutoIncludeHiddenFields = $true
        CheckUrl = "http://www.msftconnecttest.com/connecttest.txt"
        CheckExpectedText = "Microsoft Connect Test"
    }

    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8

    if ($RegisterTask) {
        Register-AutoLoginTask -LoginScript $installedLoginScript -ConfigPath $configPath
    }

    $script:existingConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$cmbOperator.Add_SelectedIndexChanged({
    if ($cmbOperator.SelectedItem) {
        $txtOperatorValue.Text = [string]$cmbOperator.SelectedItem.Value
    }
})

$chkAdvanced.Add_CheckedChanged({
    $advancedPanel.Visible = $chkAdvanced.Checked
})

$btnDetect.Add_Click({
    try {
        Set-Status -Message (S "6B63 5728 8BFB 53D6 7F51 9875 767B 5F55 9879 2026")
        $info = Inspect-PortalPage -Url $txtUrl.Text
        Apply-DetectedPortalInfo -Info $info
        Set-Status -Message (S "5DF2 8BFB 53D6 9875 9762 5B57 6BB5")
    }
    catch {
        Set-Status -Message $_.Exception.Message -IsError $true
    }
})

$btnSave.Add_Click({
    try {
        Set-Status -Message (S "6B63 5728 4FDD 5B58 914D 7F6E 2026")
        Save-CurrentConfig -RegisterTask $chkAuto.Checked
        Set-Status -Message (S "4FDD 5B58 6210 529F")
        [System.Windows.Forms.MessageBox]::Show((S "5DF2 4FDD 5B58 FF0C 4E0B 6B21 767B 5F55 0057 0069 006E 0064 006F 0077 0073 540E 4F1A 81EA 52A8 767B 5F55 6821 56ED 7F51 3002"), (S "4FDD 5B58 6210 529F"), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-Status -Message $_.Exception.Message -IsError $true
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnTest.Add_Click({
    try {
        Set-Status -Message (S "6B63 5728 4FDD 5B58 5E76 6D4B 8BD5 767B 5F55 2026")
        Save-CurrentConfig -RegisterTask $chkAuto.Checked
        $powershellExe = (Get-Command powershell.exe).Source
        & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $installedLoginScript -ConfigPath $configPath -MaxAttempts 1
        if ($LASTEXITCODE -eq 0) {
            Set-Status -Message (S "6D4B 8BD5 5B8C 6210 FF0C 5DF2 786E 8BA4 7F51 7EDC 53EF 7528")
        }
        else {
            Set-Status -Message (S "6D4B 8BD5 5B8C 6210 FF0C 4F46 672A 786E 8BA4 8054 7F51 FF0C 8BF7 6253 5F00 65E5 5FD7") -IsError $true
        }
    }
    catch {
        Set-Status -Message $_.Exception.Message -IsError $true
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnDelete.Add_Click({
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Set-Status -Message (S "5DF2 5220 9664 81EA 52A8 767B 5F55 4EFB 52A1")
    }
    catch {
        Set-Status -Message $_.Exception.Message -IsError $true
    }
})

$btnLog.Add_Click({
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    if (-not (Test-Path -LiteralPath $logPath)) {
        Set-Content -LiteralPath $logPath -Value "" -Encoding UTF8
    }
    Start-Process notepad.exe -ArgumentList "`"$logPath`""
})

if ($SelfTest) {
    Write-Host "GUI self-test OK"
    exit 0
}

[void]$form.ShowDialog()
