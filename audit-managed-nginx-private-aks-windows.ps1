param()

$ErrorActionPreference = 'Stop'

# Required target list format for each entry:
# SubscriptionId, ResourceGroup, ClusterName
$Targets = @(
    # @{ SubscriptionId = "00000000-0000-0000-0000-000000000000"; ResourceGroup = "rg-example"; ClusterName = "aks-private-example" }
    @{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "ai-obs-sre-demo"; ClusterName = "aiosre-aks-demo" }
    @{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "rg-aks-ingress-compare-aue"; ClusterName = "aksnonginx" }
    @{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "rg-aks-ingress-compare-aue"; ClusterName = "akspublicnginx" }
    @{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "rg-aks-ingress-compare-aue"; ClusterName = "akspvtnginx" }
    @{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "rg-aks-ingress-compare-aue"; ClusterName = "akspvtnginxpriv" }
    @{ SubscriptionId = "ba43c91f-2d76-4000-a7ad-24750cab54c3"; ResourceGroup = "rg-aks-ingress-compare-aue"; ClusterName = "akspvtnon-nginx" }
)

if (-not $Targets -or $Targets.Count -eq 0) {
    Write-Host "No AKS targets configured. Populate `$Targets and re-run."
    exit 1
}

$outputCsv = "managed_nginx_private_aks_audit_windows_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")
$rows = New-Object System.Collections.Generic.List[object]

function Invoke-Cli {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Args
    )

    $output = & $Exe @Args 2>$null
    $exitCode = $LASTEXITCODE

    [PSCustomObject]@{
        Success = ($exitCode -eq 0)
        Output = ($output -join "`n")
        ExitCode = $exitCode
    }
}

function Get-LowerText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return $Text.Trim().ToLowerInvariant()
}

function Add-Row {
    param(
        [string]$SubscriptionName,
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$ClusterName,
        [string]$ArmAppRoutingEnabled,
        [string]$K8sApiReachable,
        [string]$K8sManagedNginxObserved,
        [string]$ManagedIngressNamespaces,
        [string]$K8sOssNginxObserved,
        [string]$OssNginxIngressNamespaces
    )

    $rows.Add([PSCustomObject]@{
        subscription_name             = $SubscriptionName
        subscription_id               = $SubscriptionId
        resource_group                = $ResourceGroup
        cluster_name                  = $ClusterName
        arm_app_routing_enabled       = $ArmAppRoutingEnabled
        k8s_api_reachable             = $K8sApiReachable
        k8s_managed_nginx_observed    = $K8sManagedNginxObserved
        managed_ingress_namespaces    = $ManagedIngressNamespaces
        k8s_oss_nginx_observed        = $K8sOssNginxObserved
        oss_nginx_ingress_namespaces  = $OssNginxIngressNamespaces
    })
}

Write-Host "Starting private AKS namespace audit across target list..."

foreach ($target in $Targets) {
    $subId = [string]$target.SubscriptionId
    $clusterRg = [string]$target.ResourceGroup
    $clusterName = [string]$target.ClusterName

    if ([string]::IsNullOrWhiteSpace($subId) -or [string]::IsNullOrWhiteSpace($clusterRg) -or [string]::IsNullOrWhiteSpace($clusterName)) {
        Write-Host "Skipping malformed target entry."
        continue
    }

    $subInfo = Invoke-Cli -Exe "az" -Args @("account", "show", "--subscription", $subId, "--query", "name", "-o", "tsv")
    $subName = if ($subInfo.Success -and -not [string]::IsNullOrWhiteSpace($subInfo.Output)) { $subInfo.Output.Trim() } else { $subId }

    Write-Host "Processing target: $subName ($subId) / $clusterRg / $clusterName"

    $setSub = Invoke-Cli -Exe "az" -Args @("account", "set", "--subscription", $subId)
    if (-not $setSub.Success) {
        Add-Row -SubscriptionName $subName -SubscriptionId $subId -ResourceGroup $clusterRg -ClusterName $clusterName -ArmAppRoutingEnabled "unknown" -K8sApiReachable "no" -K8sManagedNginxObserved "unknown" -ManagedIngressNamespaces "NOT_IDENTIFIABLE_SUBSCRIPTION_ACCESS_ERROR" -K8sOssNginxObserved "unknown" -OssNginxIngressNamespaces "NOT_IDENTIFIABLE_SUBSCRIPTION_ACCESS_ERROR"
        continue
    }

    $isPrivateRes = Invoke-Cli -Exe "az" -Args @("aks", "show", "--resource-group", $clusterRg, "--name", $clusterName, "--query", "apiServerAccessProfile.enablePrivateCluster", "-o", "tsv")
    $isPrivate = Get-LowerText -Text $isPrivateRes.Output
    if ($isPrivate -ne "true") {
        Add-Row -SubscriptionName $subName -SubscriptionId $subId -ResourceGroup $clusterRg -ClusterName $clusterName -ArmAppRoutingEnabled "no" -K8sApiReachable "no" -K8sManagedNginxObserved "unknown" -ManagedIngressNamespaces "SKIPPED_NON_PRIVATE_CLUSTER" -K8sOssNginxObserved "unknown" -OssNginxIngressNamespaces "SKIPPED_NON_PRIVATE_CLUSTER"
        continue
    }

    $armAppRoutingEnabled = "unknown"
    $k8sApiReachable = "unknown"
    $k8sManagedNginxObserved = "unknown"
    $managedIngressNamespaces = ""
    $k8sOssNginxObserved = "unknown"
    $ossIngressNamespaces = ""

    $armRes = Invoke-Cli -Exe "az" -Args @("aks", "show", "--resource-group", $clusterRg, "--name", $clusterName, "--query", "ingressProfile.webAppRouting.enabled", "-o", "tsv")
    if ($armRes.Success) {
        switch (Get-LowerText -Text $armRes.Output) {
            "true" { $armAppRoutingEnabled = "yes" }
            "false" { $armAppRoutingEnabled = "no" }
            "null" { $armAppRoutingEnabled = "no" }
            "" { $armAppRoutingEnabled = "no" }
            default { $armAppRoutingEnabled = "unknown" }
        }
    }

    $credRes = Invoke-Cli -Exe "az" -Args @("aks", "get-credentials", "--resource-group", $clusterRg, "--name", $clusterName, "--overwrite-existing")
    if (-not $credRes.Success) {
        $k8sApiReachable = "no"
        $k8sManagedNginxObserved = "unknown"
        $managedIngressNamespaces = "NOT_IDENTIFIABLE_K8S_API_UNREACHABLE_OR_ACCESS_DENIED"
        $k8sOssNginxObserved = "unknown"
        $ossIngressNamespaces = "NOT_IDENTIFIABLE_K8S_API_UNREACHABLE_OR_ACCESS_DENIED"

        Add-Row -SubscriptionName $subName -SubscriptionId $subId -ResourceGroup $clusterRg -ClusterName $clusterName -ArmAppRoutingEnabled $armAppRoutingEnabled -K8sApiReachable $k8sApiReachable -K8sManagedNginxObserved $k8sManagedNginxObserved -ManagedIngressNamespaces $managedIngressNamespaces -K8sOssNginxObserved $k8sOssNginxObserved -OssNginxIngressNamespaces $ossIngressNamespaces
        continue
    }

    $nsRes = Invoke-Cli -Exe "kubectl" -Args @("get", "ns", "--request-timeout=10s")
    if (-not $nsRes.Success) {
        $k8sApiReachable = "no"
        $k8sManagedNginxObserved = "unknown"
        $managedIngressNamespaces = "NOT_IDENTIFIABLE_CLUSTER_PRIVATE_OR_UNREACHABLE"
        $k8sOssNginxObserved = "unknown"
        $ossIngressNamespaces = "NOT_IDENTIFIABLE_CLUSTER_PRIVATE_OR_UNREACHABLE"

        Add-Row -SubscriptionName $subName -SubscriptionId $subId -ResourceGroup $clusterRg -ClusterName $clusterName -ArmAppRoutingEnabled $armAppRoutingEnabled -K8sApiReachable $k8sApiReachable -K8sManagedNginxObserved $k8sManagedNginxObserved -ManagedIngressNamespaces $managedIngressNamespaces -K8sOssNginxObserved $k8sOssNginxObserved -OssNginxIngressNamespaces $ossIngressNamespaces
        continue
    }

    $k8sApiReachable = "yes"

    $ingressList = @()
    $ingRes = Invoke-Cli -Exe "kubectl" -Args @("get", "ingress", "-A", "-o", "json")
    if ($ingRes.Success -and -not [string]::IsNullOrWhiteSpace($ingRes.Output)) {
        try {
            $ingressJson = $ingRes.Output | ConvertFrom-Json
            if ($ingressJson.items) { $ingressList = @($ingressJson.items) }
        }
        catch {
            $ingressList = @()
        }
    }

    $managedClasses = @()
    $managedRes = Invoke-Cli -Exe "kubectl" -Args @("get", "nginxingresscontroller.approuting.kubernetes.azure.com", "-o", "json")
    if ($managedRes.Success -and -not [string]::IsNullOrWhiteSpace($managedRes.Output)) {
        try {
            $managedJson = $managedRes.Output | ConvertFrom-Json
            if ($managedJson.items) {
                foreach ($item in $managedJson.items) {
                    $className = [string]$item.spec.ingressClassName
                    if (-not [string]::IsNullOrWhiteSpace($className)) {
                        $managedClasses += $className
                    }
                }
            }
        }
        catch {
            $managedClasses = @()
        }
    }

    $managedClasses = $managedClasses | Sort-Object -Unique

    if ($managedClasses.Count -gt 0) {
        $k8sManagedNginxObserved = "yes"
        $managedNamespaces = New-Object System.Collections.Generic.HashSet[string]

        foreach ($ing in $ingressList) {
            $ns = [string]$ing.metadata.namespace
            $specClass = [string]$ing.spec.ingressClassName
            $annClass = ""
            if ($ing.metadata.annotations -and $ing.metadata.annotations.'kubernetes.io/ingress.class') {
                $annClass = [string]$ing.metadata.annotations.'kubernetes.io/ingress.class'
            }

            foreach ($className in $managedClasses) {
                if (($specClass -eq $className) -or ($annClass -eq $className)) {
                    if (-not [string]::IsNullOrWhiteSpace($ns)) { [void]$managedNamespaces.Add($ns) }
                    break
                }
            }
        }

        if ($managedNamespaces.Count -gt 0) {
            $managedIngressNamespaces = (($managedNamespaces | Sort-Object) -join ';')
        }
        else {
            $managedIngressNamespaces = "NONE_USING_MANAGED_CLASS"
        }
    }
    else {
        $k8sManagedNginxObserved = "no"
        $managedIngressNamespaces = "N/A"
    }

    $ossClasses = @()
    $ingClassRes = Invoke-Cli -Exe "kubectl" -Args @("get", "ingressclass", "-o", "json")
    if ($ingClassRes.Success -and -not [string]::IsNullOrWhiteSpace($ingClassRes.Output)) {
        try {
            $ingClassJson = $ingClassRes.Output | ConvertFrom-Json
            if ($ingClassJson.items) {
                foreach ($item in $ingClassJson.items) {
                    if ([string]$item.spec.controller -eq "k8s.io/ingress-nginx") {
                        $className = [string]$item.metadata.name
                        if (-not [string]::IsNullOrWhiteSpace($className)) {
                            $ossClasses += $className
                        }
                    }
                }
            }
        }
        catch {
            $ossClasses = @()
        }
    }

    $ossClasses = $ossClasses | Sort-Object -Unique

    $ossControllerPresent = $false
    $ossDepRes = Invoke-Cli -Exe "kubectl" -Args @("get", "deploy", "-A", "-l", "app.kubernetes.io/name=ingress-nginx", "-o", "json")
    if ($ossDepRes.Success -and -not [string]::IsNullOrWhiteSpace($ossDepRes.Output)) {
        try {
            $depJson = $ossDepRes.Output | ConvertFrom-Json
            if ($depJson.items -and $depJson.items.Count -gt 0) { $ossControllerPresent = $true }
        }
        catch {
            $ossControllerPresent = $false
        }
    }

    if (-not $ossControllerPresent) {
        $ossPodRes = Invoke-Cli -Exe "kubectl" -Args @("get", "pods", "-A", "-l", "app.kubernetes.io/name=ingress-nginx", "-o", "json")
        if ($ossPodRes.Success -and -not [string]::IsNullOrWhiteSpace($ossPodRes.Output)) {
            try {
                $podJson = $ossPodRes.Output | ConvertFrom-Json
                if ($podJson.items -and $podJson.items.Count -gt 0) { $ossControllerPresent = $true }
            }
            catch {
                $ossControllerPresent = $false
            }
        }
    }

    if ($ossClasses.Count -gt 0 -or $ossControllerPresent) {
        $k8sOssNginxObserved = "yes"
        $ossNamespaces = New-Object System.Collections.Generic.HashSet[string]

        if ($ossClasses.Count -gt 0) {
            foreach ($ing in $ingressList) {
                $ns = [string]$ing.metadata.namespace
                $specClass = [string]$ing.spec.ingressClassName
                $annClass = ""
                if ($ing.metadata.annotations -and $ing.metadata.annotations.'kubernetes.io/ingress.class') {
                    $annClass = [string]$ing.metadata.annotations.'kubernetes.io/ingress.class'
                }

                foreach ($className in $ossClasses) {
                    if (($specClass -eq $className) -or ($annClass -eq $className)) {
                        if (-not [string]::IsNullOrWhiteSpace($ns)) { [void]$ossNamespaces.Add($ns) }
                        break
                    }
                }
            }
        }

        if ($ossNamespaces.Count -gt 0) {
            $ossIngressNamespaces = (($ossNamespaces | Sort-Object) -join ';')
        }
        else {
            $ossIngressNamespaces = "NONE_USING_OSS_CLASS"
        }
    }
    else {
        $k8sOssNginxObserved = "no"
        $ossIngressNamespaces = "N/A"
    }

    Add-Row -SubscriptionName $subName -SubscriptionId $subId -ResourceGroup $clusterRg -ClusterName $clusterName -ArmAppRoutingEnabled $armAppRoutingEnabled -K8sApiReachable $k8sApiReachable -K8sManagedNginxObserved $k8sManagedNginxObserved -ManagedIngressNamespaces $managedIngressNamespaces -K8sOssNginxObserved $k8sOssNginxObserved -OssNginxIngressNamespaces $ossIngressNamespaces
}

$rows | Export-Csv -Path $outputCsv -NoTypeInformation

Write-Host "Private AKS audit completed. CSV file: $outputCsv"
Write-Host ""
Write-Host "========== BEGIN AUDIT CSV =========="
Get-Content -Path $outputCsv
Write-Host "=========== END AUDIT CSV ==========="

try {
    Write-Host ""
    Write-Host "Formatted preview:"
    $rows | Select-Object -First 50 | Format-Table -AutoSize
}
catch {
    Write-Host "Preview unavailable, but CSV has been generated."
}
