# This script is designed to enable  Microsoft Defender for Containers – Container Sensor capabilities (binary drift detection, auto provisioning, etc.) across all Azure subscriptions in your tenant that have Containers plan enabled.
# The script enumerates all Azure subscriptions you have access to and performs the following checks:
# Checks whether Defender for Containers (“Containers” pricing tier) is enabled for the subscription.
# If Defender for Containers is NOT enabled, the script skips the subscription.
# If Defender for Containers is enabled, the script inspects the extensions array in the pricing configuration.
# If the ContainerSensor extension is missing or disabled, the script enables it automatically.

🛡️ Why Container Sensor?
# Get all subscriptions
$subs = az account list --query "[].id" -o tsv

foreach ($sub in $subs) {
    Write-Host "`n---- Processing subscription: $sub ----" -ForegroundColor Cyan
    az account set --subscription $sub

    try {
        # Get Containers plan
        $pricing = az security pricing show -n Containers --subscription $sub | ConvertFrom-Json
    }
    catch {
        Write-Host "Failed to read pricing for subscription ${0}: ${1}" -ForegroundColor Red
        continue
    }

    if (-not $pricing -or $pricing.pricingTier -eq $null) {
        Write-Host "Containers pricing not found in $sub. Skipping." -ForegroundColor Yellow
        continue
    }

    # Check if plan is enabled (Standard tier)
    if ($pricing.pricingTier -ne "Standard") {
        Write-Host "Containers plan is NOT enabled in $sub. Skipping." -ForegroundColor Yellow
        continue
    }

    Write-Host "Containers plan is enabled in $sub." -ForegroundColor Green

    # Find ContainerSensor extension
    $sensor = $pricing.extensions | Where-Object { $_.name -eq "ContainerSensor" }

    if ($sensor -and $sensor.isEnabled -eq "True") {
        Write-Host "ContainerSensor already enabled in $sub." -ForegroundColor Green
        continue
    }

    Write-Host "ContainerSensor is NOT enabled in $sub. Enabling..." -ForegroundColor Yellow

    try {
        az security pricing create `
            -n Containers `
            --tier Standard `
            --extensions name=ContainerSensor isEnabled=True `
            --subscription $sub | Out-Null

        Write-Host "ContainerSensor ENABLED successfully in $sub." -ForegroundColor Green
    }
    catch {
        Write-Host "Error enabling ContainerSensor in ${0}: ${1}" -ForegroundColor Red 
    }
}
