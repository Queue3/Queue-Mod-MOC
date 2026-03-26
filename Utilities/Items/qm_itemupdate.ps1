$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $ScriptDir

function Get-TopLevelJsonObjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText
    )

    $results = New-Object System.Collections.Generic.List[string]

    $startArray = $JsonText.IndexOf('[')
    if ($startArray -lt 0) {
        return $results
    }

    $inString = $false
    $escape = $false
    $depth = 0
    $objStart = -1

    for ($i = $startArray + 1; $i -lt $JsonText.Length; $i++) {
        $ch = $JsonText[$i]

        if ($escape) {
            $escape = $false
            continue
        }

        if ($ch -eq '\') {
            if ($inString) {
                $escape = $true
            }
            continue
        }

        if ($ch -eq '"') {
            $inString = -not $inString
            continue
        }

        if ($inString) {
            continue
        }

        if ($ch -eq '{') {
            if ($depth -eq 0) {
                $objStart = $i
            }
            $depth++
            continue
        }

        if ($ch -eq '}') {
            $depth--
            if ($depth -eq 0 -and $objStart -ge 0) {
                $results.Add($JsonText.Substring($objStart, $i - $objStart + 1)) | Out-Null
                $objStart = -1
            }
            continue
        }
    }

    return $results
}

function Format-OneDecimal {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Number
    )

    return $Number.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Update-ShopWeightsBlock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlockText
    )

    try {
        $obj = $BlockText | ConvertFrom-Json
    }
    catch {
        return $null
    }

    if ($null -eq $obj.ItemGenerationData) { return $null }
    if ($null -eq $obj.ItemGenerationData.ShopWeights) { return $null }

    $weights = @($obj.ItemGenerationData.ShopWeights)
    if ($weights.Count -lt 4) { return $null }

    $firstValue  = [double]$weights[0]
    $secondValue = [double]$weights[1]
    $thirdValue  = [double]$weights[2]
    $fourthValue = [double]$weights[3]

    if ($fourthValue -le 0) { return $null }
    if ($firstValue -ge 0) { return $null }

    $sourceValue = $null

    if ($secondValue -gt 0) {
        $sourceValue = $secondValue
    }
    elseif ($thirdValue -gt 0) {
        $sourceValue = $thirdValue
    }
    else {
        return $null
    }

    $newFirstValue = [double]$sourceValue / 10.0
    $newFirstText = Format-OneDecimal -Number $newFirstValue

    $pattern = '(?s)"ShopWeights"(\s*):(\s*)\[(?<inside>.*?)\]'

    $updated = [regex]::Replace(
        $BlockText,
        $pattern,
        {
            param($m)

            $inside = $m.Groups['inside'].Value
            $numberPattern = '^(?<lead>\s*)(?<first>-?\d+(?:\.\d+)?)(?<rest>\s*,.*)$'
            $numberMatch = [regex]::Match(
                $inside,
                $numberPattern,
                [System.Text.RegularExpressions.RegexOptions]::Singleline
            )

            if (-not $numberMatch.Success) {
                return $m.Value
            }

            $newInside =
                $numberMatch.Groups['lead'].Value +
                $newFirstText +
                $numberMatch.Groups['rest'].Value

            return '"ShopWeights"' + $m.Groups[1].Value + ':' + $m.Groups[2].Value + '[' + $newInside + ']'
        },
        1
    )

    if ($updated -eq $BlockText) {
        return $null
    }

    return $updated
}

$sourceFiles = Get-ChildItem -LiteralPath $ScriptDir -Filter '*.json' -File

foreach ($sourceFile in $sourceFiles) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name)
    $outputDir = Join-Path $ScriptDir $baseName
    $outputFile = Join-Path $outputDir ("qm_" + $sourceFile.Name)

    Write-Host "Processing $($sourceFile.Name)..."

    $raw = Get-Content -LiteralPath $sourceFile.FullName -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Host "  Skipped empty file."
        continue
    }

    $blocks = Get-TopLevelJsonObjects -JsonText $raw
    $changedBlocks = New-Object System.Collections.Generic.List[string]

    foreach ($block in $blocks) {
        $updatedBlock = Update-ShopWeightsBlock -BlockText $block
        if ($null -ne $updatedBlock) {
            $changedBlocks.Add($updatedBlock) | Out-Null
        }
    }

    if (-not (Test-Path -LiteralPath $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory | Out-Null
    }

    if ($changedBlocks.Count -eq 0) {
        Set-Content -LiteralPath $outputFile -Value "[]" -Encoding UTF8
        Write-Host "  No matching blocks. Wrote empty array."
        continue
    }

    $finalLines = New-Object System.Collections.Generic.List[string]
    $finalLines.Add('[') | Out-Null

    for ($i = 0; $i -lt $changedBlocks.Count; $i++) {
        $blockLines = $changedBlocks[$i] -split "`r?`n"

        for ($j = 0; $j -lt $blockLines.Count; $j++) {
            if ($j -eq 0) {
                $finalLines.Add("  $($blockLines[$j])") | Out-Null
            }
            else {
                $finalLines.Add($blockLines[$j]) | Out-Null
            }
        }

        if ($i -lt ($changedBlocks.Count - 1)) {
            $lastIndex = $finalLines.Count - 1
            $finalLines[$lastIndex] = $finalLines[$lastIndex] + ','
        }
    }

    $finalLines.Add(']') | Out-Null

    $finalText = $finalLines -join "`r`n"
    Set-Content -LiteralPath $outputFile -Value $finalText -Encoding UTF8

    Write-Host "  Wrote $($changedBlocks.Count) changed block(s)."
}

Write-Host ""
Write-Host "Done."
Pause