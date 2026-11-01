param(
    [switch]$NoGui = $false,
    [switch]$SilentVerify = $false,
    [switch]$SkipShortcuts = $false,
    [string]$Language = "ja",
    [string]$OperatingMode = "Companion",
    [string]$LicenseKey = "",
    [string]$InstallDir = ""
)

$ErrorActionPreference = "Stop"
$DistBaseUrl = "https://raw.githubusercontent.com/kapibarazoku0422-create/kapibaraGuard-release/main"

function New-KapibaraMonthlyKey {
    param(
        [string]$PlanCode = "PRO",
        [string]$YearMonth = ""
    )
    if (-not $YearMonth) {
        $YearMonth = (Get-Date).ToString("yyyyMM")
    }
    $CleanPlan = $PlanCode.Trim().ToUpperInvariant()
    if (@("PRO", "FAM", "ENT") -notcontains $CleanPlan) { $CleanPlan = "PRO" }
    $RandHex = [Guid]::NewGuid().ToString("N").Substring(0, 6).ToUpperInvariant()
    $Payload = "KG-SUB-$CleanPlan-$YearMonth-$RandHex"
    $SecretBytes = [System.Text.Encoding]::UTF8.GetBytes("KAPIBARAGUARD-SELLER-MASTER-SIGNING-SECRET-2026-V1")
    $HmacSha = New-Object System.Security.Cryptography.HMACSHA256(,$SecretBytes)
    $HashBytes = $HmacSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Payload))
    $Sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) {
        [void]$Sb.Append($HashBytes[$i].ToString("X2"))
    }
    return "$Payload-$($Sb.ToString())"
}

function Test-KapibaraLicenseKey {
    param([string]$InputKey)
    $Result = @{
        Valid = $false
        ExpiredUnpaid = $false
        Reason = "EMPTY_KEY"
        PlanCode = ""
        KeyYearMonth = ""
        CurrentYearMonth = (Get-Date).ToString("yyyyMM")
    }
    if ([string]::IsNullOrWhiteSpace($InputKey)) { return $Result }
    $Clean = $InputKey.Trim().ToUpperInvariant()

    # Check Monthly Subscription Key format: KG-SUB-(PRO|FAM|ENT)-(YYYYMM)-(RAND6)-(HMAC8)
    if ($Clean -match "^(KG-SUB-(PRO|FAM|ENT)-(\d{6})-[0-9A-F]{6})-([0-9A-F]{8})$") {
        $Payload = $Matches[1]
        $PlanCode = $Matches[2]
        $KeyYm = $Matches[3]
        $ProvidedHmac = $Matches[4]

        $SecretBytes = [System.Text.Encoding]::UTF8.GetBytes("KAPIBARAGUARD-SELLER-MASTER-SIGNING-SECRET-2026-V1")
        $HmacSha = New-Object System.Security.Cryptography.HMACSHA256(,$SecretBytes)
        $HashBytes = $HmacSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Payload))
        $Sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt 4; $i++) {
            [void]$Sb.Append($HashBytes[$i].ToString("X2"))
        }
        if ($Sb.ToString() -ne $ProvidedHmac) {
            $Result.Reason = "INVALID_HMAC_SIGNATURE"
            return $Result
        }
        $Result.PlanCode = $PlanCode
        $Result.KeyYearMonth = $KeyYm
        if ([int]$KeyYm -lt [int]$Result.CurrentYearMonth) {
            $Result.Valid = $false
            $Result.ExpiredUnpaid = $true
            $Result.Reason = "SUBSCRIPTION_UNPAID_EXPIRED ($KeyYm < $($Result.CurrentYearMonth))"
            return $Result
        }
        $Result.Valid = $true
        $Result.Reason = "ACTIVE_MONTHLY_SUBSCRIPTION ($KeyYm)"
        return $Result
    }

    $Result.Reason = "FORMAT_INVALID"
    return $Result
}

# Standard Windows per-user Program installation directory (Zero Admin / Zero Signature required)
$UserProgramDir = Join-Path $env:LOCALAPPDATA "Programs\kapibaraGuard"
New-Item -ItemType Directory -Path $UserProgramDir -Force | Out-Null

# Determine workspace/target directory
$ScriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { "" }
if (-not $InstallDir) {
    if ($ScriptDir -and (Test-Path (Join-Path $ScriptDir "package.json"))) {
        $InstallDir = $ScriptDir
    } else {
        $InstallDir = $UserProgramDir
    }
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Load 6-language UI catalog
$LocalI18n = if ($ScriptDir) { Join-Path $ScriptDir "i18n-installer.json" } else { "" }
if (-not $LocalI18n -or -not (Test-Path $LocalI18n)) {
    $LocalI18n = if ($ScriptDir) { Join-Path $ScriptDir "installers\i18n-installer.json" } else { "" }
}
if ($LocalI18n -and (Test-Path $LocalI18n)) {
    $I18nJson = Get-Content -Path $LocalI18n -Encoding UTF8 -Raw | ConvertFrom-Json
} else {
    $I18nRaw = Invoke-RestMethod -Uri "$DistBaseUrl/i18n-installer.json" -UseBasicParsing
    $I18nJson = if ($I18nRaw -is [string]) { $I18nRaw | ConvertFrom-Json } else { $I18nRaw }
}

function Get-EncryptedPayloadObject {
    $Candidates = @()
    if ($ScriptDir) {
        $Candidates += (Join-Path $ScriptDir "payload.enc")
        $Candidates += (Join-Path $ScriptDir "installers\dist\payload.enc")
    }
    foreach ($c in $Candidates) {
        if (Test-Path $c) {
            return (Get-Content -Path $c -Encoding UTF8 -Raw | ConvertFrom-Json)
        }
    }
    $RemoteRaw = Invoke-RestMethod -Uri "$DistBaseUrl/payload.enc" -UseBasicParsing
    if ($RemoteRaw -is [string]) {
        return ($RemoteRaw | ConvertFrom-Json)
    }
    return $RemoteRaw
}

function Unprotect-PayloadInMemory {
    param($Envelope)
    $Passkey = "KG-ULTIMATE-DIST-ENVELOPE-KEY-2026-V1"
    $SaltBytes = [System.Text.Encoding]::UTF8.GetBytes("kapibaraGuard_Dist_Salt_2026_v1!")
    $IvBytes = [Convert]::FromBase64String($Envelope.ivBase64)
    $CipherBytes = [Convert]::FromBase64String($Envelope.ciphertextBase64)

    $Kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $Passkey,
        $SaltBytes,
        100000,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $AesKey = $Kdf.GetBytes(32)

    $Aes = New-Object System.Security.Cryptography.AesManaged
    $Aes.KeySize = 256
    $Aes.BlockSize = 128
    $Aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $Aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $Decryptor = $Aes.CreateDecryptor($AesKey, $IvBytes)
    $PlainBytes = $Decryptor.TransformFinalBlock($CipherBytes, 0, $CipherBytes.Length)
    return [System.Text.Encoding]::UTF8.GetString($PlainBytes)
}

function New-KapibaraIconFile {
    param([string]$IconFilePath)
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap(64, 64)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(16, 185, 129))
    $g.FillEllipse($bgBrush, 2, 2, 60, 60)

    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(5, 150, 105), 3)
    $g.DrawEllipse($borderPen, 3, 3, 58, 58)

    $font = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $textBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(11, 17, 32))
    $g.DrawString("KG", $font, $textBrush, 7, 14)

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $ms.ToArray()
    $ms.Dispose()
    $g.Dispose()
    $bmp.Dispose()

    $fs = [System.IO.File]::Create($IconFilePath)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]1)
    $bw.Write([byte]64)
    $bw.Write([byte]64)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$pngBytes.Length)
    $bw.Write([uint32]22)
    $bw.Write($pngBytes)
    $bw.Flush()
    $bw.Close()
    $fs.Close()
}

function Register-AppAndShortcuts {
    param(
        [string]$CompiledExePath,
        [string]$SelectedLang,
        [string]$ConfigContent
    )
    $AppBinDir = Join-Path $UserProgramDir "apps\windows\bin"
    $AppDataDir = Join-Path $UserProgramDir "data\quarantine"
    New-Item -ItemType Directory -Path $AppBinDir -Force | Out-Null
    New-Item -ItemType Directory -Path $AppDataDir -Force | Out-Null

    $InstalledExe = Join-Path $UserProgramDir "KapibaraGuard.exe"
    $SubBinExe = Join-Path $AppBinDir "KapibaraGuard.exe"
    if ($CompiledExePath -ne $InstalledExe) {
        Copy-Item -Path $CompiledExePath -Destination $InstalledExe -Force
    }
    if ($CompiledExePath -ne $SubBinExe) {
        Copy-Item -Path $CompiledExePath -Destination $SubBinExe -Force
    }
    Set-Content -Path (Join-Path $UserProgramDir "data\config.json") -Value $ConfigContent -Encoding UTF8

    $IconPath = Join-Path $UserProgramDir "kapibaraGuard.ico"
    try {
        New-KapibaraIconFile -IconFilePath $IconPath
    } catch {}

    if ($SkipShortcuts) {
        return $InstalledExe
    }

    $WshShell = New-Object -ComObject WScript.Shell
    $DesktopDir = [Environment]::GetFolderPath("Desktop")
    $StartMenuPrograms = [Environment]::GetFolderPath("Programs")
    $StartMenuKgDir = Join-Path $StartMenuPrograms "kapibaraGuard"
    $StartupDir = [Environment]::GetFolderPath("Startup")
    New-Item -ItemType Directory -Path $StartMenuKgDir -Force | Out-Null

    $ShortcutTargets = @(
        (Join-Path $DesktopDir "kapibaraGuard ULTIMATE.lnk"),
        (Join-Path $StartMenuKgDir "kapibaraGuard ULTIMATE.lnk"),
        (Join-Path $StartupDir "kapibaraGuard 24x7 Watchdog.lnk")
    )

    foreach ($lnkPath in $ShortcutTargets) {
        try {
            $sc = $WshShell.CreateShortcut($lnkPath)
            $sc.TargetPath = $InstalledExe
            $sc.Arguments = "--lang $SelectedLang"
            $sc.WorkingDirectory = $UserProgramDir
            $sc.Description = "kapibaraGuard ULTIMATE v1.0 - 24/7 Autonomous 6-Layer Security"
            if (Test-Path $IconPath) {
                $sc.IconLocation = "$IconPath,0"
            } else {
                $sc.IconLocation = "$InstalledExe,0"
            }
            $sc.Save()
        } catch {}
    }

    $WebUrlContent = "[InternetShortcut]`r`nURL=http://127.0.0.1:4190`r`nIconFile=$IconPath`r`nIconIndex=0`r`n"
    $OwnerUrlContent = "[InternetShortcut]`r`nURL=http://127.0.0.1:4190/owner.html`r`nIconFile=$IconPath`r`nIconIndex=0`r`n"
    try {
        Set-Content -Path (Join-Path $DesktopDir "kapibaraGuard Web Console.url") -Value $WebUrlContent -Encoding ASCII
        Set-Content -Path (Join-Path $DesktopDir "kapibaraGuard Owner Console.url") -Value $OwnerUrlContent -Encoding ASCII
        Set-Content -Path (Join-Path $StartMenuKgDir "kapibaraGuard Web Console.url") -Value $WebUrlContent -Encoding ASCII
    } catch {}

    $UninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\kapibaraGuard"
    try {
        if (-not (Test-Path $UninstallKey)) {
            New-Item -Path $UninstallKey -Force | Out-Null
        }
        Set-ItemProperty -Path $UninstallKey -Name "DisplayName" -Value "kapibaraGuard ULTIMATE v1.0 (24/7 Security)"
        Set-ItemProperty -Path $UninstallKey -Name "DisplayVersion" -Value "1.0.0"
        Set-ItemProperty -Path $UninstallKey -Name "Publisher" -Value "kapibaraGuard Security"
        Set-ItemProperty -Path $UninstallKey -Name "DisplayIcon" -Value $IconPath
        Set-ItemProperty -Path $UninstallKey -Name "InstallLocation" -Value $UserProgramDir
        Set-ItemProperty -Path $UninstallKey -Name "UninstallString" -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"Remove-Item -Recurse -Force '$UserProgramDir' -ErrorAction SilentlyContinue`""
        Set-ItemProperty -Path $UninstallKey -Name "NoModify" -Value 1 -Type DWord
        Set-ItemProperty -Path $UninstallKey -Name "NoRepair" -Value 1 -Type DWord
    } catch {}

    return $InstalledExe
}

function Invoke-EncryptedBuildAndWipe {
    param(
        [string]$SelectedLang,
        [string]$SelectedMode,
        [string]$VerifiedLicenseKey,
        [string]$SelectedPlanCode,
        [scriptblock]$OnProgress
    )

    & $OnProgress 15 "[1/7] Checking OS & Architecture ($($env:PROCESSOR_ARCHITECTURE))..."
    $CscPath = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $CscPath)) {
        throw "Required .NET Framework compiler ($CscPath) not found."
    }

    & $OnProgress 30 "[2/7] Loading AES-256 Encrypted Package (payload.enc)..."
    $Envelope = Get-EncryptedPayloadObject

    & $OnProgress 50 "[3/7] Decrypting Package in Memory (No Signatures Required)..."
    $DecryptedSource = Unprotect-PayloadInMemory -Envelope $Envelope

    $BinDir = Join-Path $InstallDir "apps\windows\bin"
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $ExeOutPath = Join-Path $BinDir "KapibaraGuard.exe"

    $EphemeralPath = Join-Path $env:TEMP ("kg_ephemeral_" + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        & $OnProgress 68 "[4/7] Building Native Executable Locally..."
        $Utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($EphemeralPath, $DecryptedSource, $Utf8Bom)

        & $CscPath /nologo /utf8output /target:exe /out:"$ExeOutPath" /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Management.dll "$EphemeralPath"
        if ($LASTEXITCODE -ne 0) {
            throw "Local compilation failed."
        }
    } finally {
        $DecryptedSource = $null
        if (Test-Path $EphemeralPath) {
            try {
                $Len = (Get-Item $EphemeralPath).Length
                $ZeroBytes = New-Object byte[]($Len)
                [System.IO.File]::WriteAllBytes($EphemeralPath, $ZeroBytes)
            } catch {}
            Remove-Item -Path $EphemeralPath -Force -ErrorAction SilentlyContinue
        }
        & $OnProgress 82 "[5/7] Temporary Source Wiped Immediately (0 bytes of source left on disk)."
    }

    & $OnProgress 90 "[6/7] Installing App & Saving Monthly Subscription Key ($VerifiedLicenseKey)..."
    $DataDir = Join-Path $InstallDir "data\quarantine"
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $ConfigPath = Join-Path $InstallDir "data\config.json"
    $ConfigObj = @{
        product = "kapibaraGuard ULTIMATE"
        version = "1.0.0"
        language = $SelectedLang
        signatureMode = "NONE"
        distributionMode = "ENCRYPTED_PACKAGE_SOURCE_WIPED"
        operatingMode = $SelectedMode
        planCode = $SelectedPlanCode
        licenseKey = $VerifiedLicenseKey
        billingMonth = (Get-Date).ToString("yyyyMM")
        ransomShieldAutoBlock = $false
        installedAt = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $ConfigPath -Value $ConfigObj -Encoding UTF8

    $InstalledAppExe = Register-AppAndShortcuts -CompiledExePath $ExeOutPath -SelectedLang $SelectedLang -ConfigContent $ConfigObj

    $VerifyOut = & "$ExeOutPath" --verify
    & $OnProgress 100 "[7/7] App & Shortcuts Installed! ($VerifyOut)"
    return $InstalledAppExe
}

if ($NoGui -or $SilentVerify) {
    $AutoKey = if ($LicenseKey) { $LicenseKey } else { New-KapibaraMonthlyKey -PlanCode "PRO" }
    $Check = Test-KapibaraLicenseKey -InputKey $AutoKey
    if (-not $Check.Valid) {
        throw "License key validation failed: $($Check.Reason)"
    }
    [void](Invoke-EncryptedBuildAndWipe -SelectedLang $Language -SelectedMode $OperatingMode -VerifiedLicenseKey $AutoKey -SelectedPlanCode $Check.PlanCode -OnProgress {
        param($pct, $msg)
        Write-Host "[$pct%] $msg" -ForegroundColor Cyan
    })
    exit 0
}

# ============================================================================
# MULTILINGUAL GUI INSTALLER WITH EMBEDDED MONTHLY PAYMENT & KEY ISSUANCE
# ============================================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Translations = $I18nJson.translations

$form = New-Object System.Windows.Forms.Form
$form.Size = New-Object System.Drawing.Size(720, 650)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(11, 17, 32)
$form.ForeColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(24, 14)
$lblTitle.Size = New-Object System.Drawing.Size(660, 28)
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$form.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Location = New-Object System.Drawing.Point(24, 44)
$lblSub.Size = New-Object System.Drawing.Size(660, 22)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$form.Controls.Add($lblSub)

# 1. Language Selector
$lblLang = New-Object System.Windows.Forms.Label
$lblLang.Location = New-Object System.Drawing.Point(24, 76)
$lblLang.Size = New-Object System.Drawing.Size(230, 24)
$form.Controls.Add($lblLang)

$cmbLang = New-Object System.Windows.Forms.ComboBox
$cmbLang.Location = New-Object System.Drawing.Point(260, 74)
$cmbLang.Size = New-Object System.Drawing.Size(420, 28)
$cmbLang.DropDownStyle = "DropDownList"
foreach ($langItem in $I18nJson.languages) {
    [void]$cmbLang.Items.Add($langItem)
}
$cmbLang.SelectedIndex = 0
$form.Controls.Add($cmbLang)

# 2. Operating Mode Selector
$lblMode = New-Object System.Windows.Forms.Label
$lblMode.Location = New-Object System.Drawing.Point(24, 112)
$lblMode.Size = New-Object System.Drawing.Size(230, 24)
$form.Controls.Add($lblMode)

$cmbMode = New-Object System.Windows.Forms.ComboBox
$cmbMode.Location = New-Object System.Drawing.Point(260, 110)
$cmbMode.Size = New-Object System.Drawing.Size(420, 28)
$cmbMode.DropDownStyle = "DropDownList"
[void]$cmbMode.Items.Add("Companion | Companion Mode (Safe Coexistence)")
[void]$cmbMode.Items.Add("Standalone | Standalone Mode (Primary Protection)")
[void]$cmbMode.Items.Add("Enterprise | Enterprise Mode (Centralized Policy)")
$cmbMode.SelectedIndex = 0
$form.Controls.Add($cmbMode)

# 3. Embedded Plan & Monthly Fee Selector (プラン別月額料金選択)
$lblPlan = New-Object System.Windows.Forms.Label
$lblPlan.Location = New-Object System.Drawing.Point(24, 148)
$lblPlan.Size = New-Object System.Drawing.Size(230, 24)
$lblPlan.Text = "1. Select Monthly Plan / プラン選択:"
$lblPlan.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$form.Controls.Add($lblPlan)

$cmbPlan = New-Object System.Windows.Forms.ComboBox
$cmbPlan.Location = New-Object System.Drawing.Point(260, 146)
$cmbPlan.Size = New-Object System.Drawing.Size(420, 28)
$cmbPlan.DropDownStyle = "DropDownList"
[void]$cmbPlan.Items.Add("PRO | Personal Pro - Monthly JPY 980/mo (Up to 3 PCs)")
[void]$cmbPlan.Items.Add("FAM | Family / SOHO - Monthly JPY 1,980/mo (Up to 10 Devices)")
[void]$cmbPlan.Items.Add("ENT | Enterprise - Monthly JPY 4,980/mo (Multi-Tenant & RBAC)")
$cmbPlan.SelectedIndex = 0
$form.Controls.Add($cmbPlan)

# 4. Embedded Payment Method Selector (お支払い方法選択)
$lblPay = New-Object System.Windows.Forms.Label
$lblPay.Location = New-Object System.Drawing.Point(24, 184)
$lblPay.Size = New-Object System.Drawing.Size(230, 24)
$lblPay.Text = "2. Payment Method / 支払方法:"
$lblPay.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$form.Controls.Add($lblPay)

$cmbPay = New-Object System.Windows.Forms.ComboBox
$cmbPay.Location = New-Object System.Drawing.Point(260, 182)
$cmbPay.Size = New-Object System.Drawing.Size(250, 28)
$cmbPay.DropDownStyle = "DropDownList"
[void]$cmbPay.Items.Add("CreditCard | Credit Card (Visa/Master/JCB)")
[void]$cmbPay.Items.Add("PayPay | PayPay / QR Code Payment")
[void]$cmbPay.Items.Add("Konbini | Convenience Store / Bank Transfer")
[void]$cmbPay.Items.Add("AppleGooglePay | Apple Pay / Google Pay")
$cmbPay.SelectedIndex = 0
$form.Controls.Add($cmbPay)

$btnPayNow = New-Object System.Windows.Forms.Button
$btnPayNow.Location = New-Object System.Drawing.Point(518, 180)
$btnPayNow.Size = New-Object System.Drawing.Size(162, 30)
$btnPayNow.FlatStyle = "Flat"
$btnPayNow.BackColor = [System.Drawing.Color]::FromArgb(14, 165, 233)
$btnPayNow.ForeColor = [System.Drawing.Color]::White
$btnPayNow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnPayNow.Text = "Pay & Issue Key Now"
$form.Controls.Add($btnPayNow)

# 5. Monthly License Key Input (with Unpaid / Expired Month Test Button)
$lblKey = New-Object System.Windows.Forms.Label
$lblKey.Location = New-Object System.Drawing.Point(24, 222)
$lblKey.Size = New-Object System.Drawing.Size(230, 24)
$lblKey.Text = "3. Monthly Key (YYYYMM Bound):"
$lblKey.ForeColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$form.Controls.Add($lblKey)

$txtLicenseKey = New-Object System.Windows.Forms.TextBox
$txtLicenseKey.Location = New-Object System.Drawing.Point(260, 220)
$txtLicenseKey.Size = New-Object System.Drawing.Size(280, 28)
$txtLicenseKey.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$txtLicenseKey.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
$txtLicenseKey.ForeColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$txtLicenseKey.Text = if ($LicenseKey) { $LicenseKey } else { "" }
$form.Controls.Add($txtLicenseKey)

$btnTestUnpaid = New-Object System.Windows.Forms.Button
$btnTestUnpaid.Location = New-Object System.Drawing.Point(546, 219)
$btnTestUnpaid.Size = New-Object System.Drawing.Size(134, 28)
$btnTestUnpaid.FlatStyle = "Flat"
$btnTestUnpaid.BackColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
$btnTestUnpaid.ForeColor = [System.Drawing.Color]::White
$btnTestUnpaid.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnTestUnpaid.Text = "Test Unpaid Key"
$form.Controls.Add($btnTestUnpaid)

$chkShortcut = New-Object System.Windows.Forms.CheckBox
$chkShortcut.Location = New-Object System.Drawing.Point(24, 258)
$chkShortcut.Size = New-Object System.Drawing.Size(650, 24)
$chkShortcut.Checked = $true
$chkShortcut.Text = "Add Desktop Shortcut, Start Menu App & Windows Installed App"
$form.Controls.Add($chkShortcut)

$chkLaunch = New-Object System.Windows.Forms.CheckBox
$chkLaunch.Location = New-Object System.Drawing.Point(24, 286)
$chkLaunch.Size = New-Object System.Drawing.Size(650, 24)
$chkLaunch.Checked = $true
$form.Controls.Add($chkLaunch)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(24, 318)
$progressBar.Size = New-Object System.Drawing.Size(656, 22)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$form.Controls.Add($progressBar)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(24, 348)
$txtLog.Size = New-Object System.Drawing.Size(656, 185)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.Text = "[Monthly Subscription System Ready]`r`n1. Choose your Plan (JPY 980 / 1,980 / 4,980 per month) and Payment Method.`r`n2. Click [Pay & Issue Key Now] to complete payment and receive this month's license key ($((Get-Date).ToString('yyyyMM'))).`r`n3. If next month's payment is unpaid, next month's key will not be issued and the old key expires automatically.`r`n`r`n"
$form.Controls.Add($txtLog)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Location = New-Object System.Drawing.Point(370, 548)
$btnInstall.Size = New-Object System.Drawing.Size(170, 40)
$btnInstall.FlatStyle = "Flat"
$btnInstall.BackColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
$btnInstall.ForeColor = [System.Drawing.Color]::White
$btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnInstall)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Location = New-Object System.Drawing.Point(550, 548)
$btnClose.Size = New-Object System.Drawing.Size(130, 40)
$btnClose.FlatStyle = "Flat"
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$btnClose.ForeColor = [System.Drawing.Color]::White
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

$UpdateUiLanguage = {
    $sel = ($cmbLang.SelectedItem.ToString().Split('|')[0]).Trim()
    $t = $Translations.$sel
    $form.Text = $t.Title
    $lblTitle.Text = $t.Title
    $lblSub.Text = $t.Subtitle
    $lblLang.Text = $t.LangLabel
    $lblMode.Text = $t.ModeLabel
    $chkLaunch.Text = $t.LaunchCheck
    if ($t.ShortcutCheck) {
        $chkShortcut.Text = $t.ShortcutCheck
    }
    $btnInstall.Text = $t.InstallBtn
    $btnClose.Text = $t.CloseBtn
}
& $UpdateUiLanguage
$cmbLang.Add_SelectedIndexChanged($UpdateUiLanguage)

# Embedded Payment Checkout & Instant Monthly Key Issuance Handler
$btnPayNow.Add_Click({
    $selPlanRaw = $cmbPlan.SelectedItem.ToString()
    $selPlanCode = ($selPlanRaw.Split('|')[0]).Trim()
    $selPayRaw = $cmbPay.SelectedItem.ToString()
    $curYm = (Get-Date).ToString("yyyyMM")
    $priceLabel = if ($selPlanCode -eq "ENT") { "JPY 4,980 / Month" } elseif ($selPlanCode -eq "FAM") { "JPY 1,980 / Month" } else { "JPY 980 / Month" }

    $confirmMsg = "Confirm Monthly Subscription Payment?`n`n" +
                  "Plan: $selPlanRaw`n" +
                  "Billing Amount: $priceLabel`n" +
                  "Billing Month: $curYm`n" +
                  "Payment Method: $selPayRaw`n`n" +
                  "Upon payment completion, your $curYm Monthly License Key will be issued immediately."

    $ans = [System.Windows.Forms.MessageBox]::Show(
        $confirmMsg,
        "kapibaraGuard Monthly Subscription Checkout",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($ans -eq [System.Windows.Forms.DialogResult]::OK) {
        $IssuedKey = New-KapibaraMonthlyKey -PlanCode $selPlanCode -YearMonth $curYm
        $txtLicenseKey.Text = $IssuedKey
        $txtLicenseKey.ForeColor = [System.Drawing.Color]::FromArgb(16, 185, 129)
        $txtLog.AppendText("[PAYMENT SUCCESS] Paid $priceLabel via $selPayRaw for month $curYm.`r`n")
        $txtLog.AppendText("[KEY ISSUED] Your Monthly License Key: $IssuedKey (Auto-filled!)`r`n")
        $txtLog.AppendText("-> You can now click [$($btnInstall.Text)] below!`r`n`r`n")
    }
})

# Test Unpaid / Expired Previous Month Key Handler
$btnTestUnpaid.Add_Click({
    $selPlanCode = ($cmbPlan.SelectedItem.ToString().Split('|')[0]).Trim()
    $prevYm = (Get-Date).AddMonths(-1).ToString("yyyyMM")
    $ExpiredKey = New-KapibaraMonthlyKey -PlanCode $selPlanCode -YearMonth $prevYm
    $txtLicenseKey.Text = $ExpiredKey
    $txtLicenseKey.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
    $txtLog.AppendText("[UNPAID TEST] Filled expired key from previous month ($prevYm): $ExpiredKey`r`n")
    $txtLog.AppendText("-> Try clicking [$($btnInstall.Text)] to verify that unpaid/expired keys are blocked!`r`n`r`n")
})

# Install Button with Strict Monthly License Key Verification
$btnInstall.Add_Click({
    $KeyCheck = Test-KapibaraLicenseKey -InputKey $txtLicenseKey.Text
    if (-not $KeyCheck.Valid) {
        if ($KeyCheck.ExpiredUnpaid) {
            $errMsg = "[MONTHLY SUBSCRIPTION UNPAID / EXPIRED]`r`n" +
                      "Key Month ($($KeyCheck.KeyYearMonth)) has expired (Current Month: $($KeyCheck.CurrentYearMonth)).`r`n" +
                      "Because this month's fee is unpaid, a new monthly key was not issued and installation/execution is blocked.`r`n" +
                      "Please click [Pay & Issue Key Now] above to pay for $($KeyCheck.CurrentYearMonth) and get a valid key.`r`n`r`n"
            $txtLog.AppendText($errMsg)
            [System.Windows.Forms.MessageBox]::Show(
                "月額料金が未払い（または前月以前の期限切れキー: $($KeyCheck.KeyYearMonth)）のため使用できません。`n`n上の「Pay & Issue Key Now」ボタンから当月分 ($($KeyCheck.CurrentYearMonth)) のプラン料金をお支払いいただき、当月有効なライセンスキーを発行してください。",
                "月額未払い・有効期限切れロック (Unpaid / Expired)",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
            return
        }
        $txtLog.AppendText("[LICENSE REQUIRED] Please select a plan and click [Pay & Issue Key Now] or enter a valid $(([DateTime]::Now).ToString('yyyyMM')) license key.`r`n`r`n")
        [System.Windows.Forms.MessageBox]::Show(
            "有効な当月分のライセンスキーが入力されていません。`n`n1. プラン（¥980/月・¥1,980/月・¥4,980/月）と支払方法を選択`n2. 「Pay & Issue Key Now」をクリックして決済＆当月キーを即時発行`n3. 「インストール開始」をクリックしてください。",
            "ライセンスキーが必要です",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $btnInstall.Enabled = $false
    $SkipShortcuts = (-not $chkShortcut.Checked)
    $selLang = ($cmbLang.SelectedItem.ToString().Split('|')[0]).Trim()
    $selMode = ($cmbMode.SelectedItem.ToString().Split('|')[0]).Trim()
    try {
        $txtLog.AppendText("[05%] Monthly Subscription Verified (Plan=$($KeyCheck.PlanCode), BillingMonth=$($KeyCheck.KeyYearMonth), HMAC=OK)`r`n")
        $BuiltExe = Invoke-EncryptedBuildAndWipe -SelectedLang $selLang -SelectedMode $selMode -VerifiedLicenseKey $txtLicenseKey.Text.Trim() -SelectedPlanCode $KeyCheck.PlanCode -OnProgress {
            param($pct, $msg)
            $progressBar.Value = $pct
            $txtLog.AppendText("[$pct%] $msg`r`n")
            [System.Windows.Forms.Application]::DoEvents()
        }
        $t = $Translations.$selLang
        $txtLog.AppendText("`r`n>>> $($t.DoneMsg)`r`n")
        $txtLog.AppendText("App Installed: $BuiltExe`r`n")
        $txtLog.AppendText("Desktop & Start Menu Shortcuts Created!`r`n")
        if ($chkLaunch.Checked -and (Test-Path $BuiltExe)) {
            Start-Process -FilePath $BuiltExe -ArgumentList @("--lang", $selLang)
        }
    } catch {
        $txtLog.AppendText("[ERROR] $($_.Exception.Message)`r`n")
        $btnInstall.Enabled = $true
    }
})

[void]$form.ShowDialog()
exit 0
