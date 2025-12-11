<#
.SYNOPSIS
    Backup de Power Platform con detección automática de PCF controls

.DESCRIPTION
    Detecta automáticamente las soluciones PCF usadas y las exporta junto a la solución principal
#>

param(
    [string]$SolutionName = "miApp",
    [int]$RetentionDays = 180
)

$ErrorActionPreference = "Stop"

try {
    Write-Output "======================================"
    Write-Output "Power Platform Backup con Auto-PCF"
    Write-Output "======================================"
    Write-Output "Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    
    # Paso 1: Conectar a Azure
    Write-Output "`n[1/7] Conectando a Azure..."
    Connect-AzAccount -Identity
    Write-Output "  ✓ Conectado con Managed Identity"
    
    # Paso 2: Obtener variables
    Write-Output "`n[2/7] Obteniendo configuración..."
    
    $tenantId = Get-AutomationVariable -Name 'PP-TenantId'
    $appId = Get-AutomationVariable -Name 'PP-AppId'
    $environmentId = Get-AutomationVariable -Name 'PP-EnvironmentId'
    $dataverseUrl = Get-AutomationVariable -Name 'PP-DataverseUrl'
    $storageAccount = Get-AutomationVariable -Name 'PP-StorageAccount'
    $resourceGroup = Get-AutomationVariable -Name 'PP-ResourceGroup'
    $containerName = Get-AutomationVariable -Name 'PP-ContainerName'
    
    $clientSecret = Get-AutomationPSCredential -Name 'PP-ServicePrincipal'
    $clientSecretPlain = $clientSecret.GetNetworkCredential().Password
    
    Write-Output "  Environment: $environmentId"
    Write-Output "  Dataverse URL: $dataverseUrl"
    
    # Paso 3: Autenticar Power Platform
    Write-Output "`n[3/7] Autenticando Power Platform..."
    
    Add-PowerAppsAccount -TenantID $tenantId -ApplicationId $appId -ClientSecret $clientSecretPlain
    Write-Output "  ✓ Autenticado"
    
    # Paso 3a: Obtener token Dataverse para detección PCF
    Write-Output "`n[3a] Detectando PCF controls automáticamente..."
    
    $tokenBody = @{
        client_id = $appId
        client_secret = $clientSecretPlain
        scope = "$dataverseUrl/.default"
        grant_type = "client_credentials"
    }
    
    $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $accessToken = $tokenResponse.access_token
    
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type" = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version" = "4.0"
    }
    
    # Buscar solución principal
    $solutionQuery = "$dataverseUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$SolutionName'&`$select=solutionid"
    $mainSolution = (Invoke-RestMethod -Uri $solutionQuery -Method Get -Headers $headers).value[0]
    
    if (-not $mainSolution) {
        Write-Output "  ✗ Solución '$SolutionName' no encontrada"
        throw "Solución no encontrada"
    }
    
    # Buscar componentes PCF (type 66)
    $componentsUrl = "$dataverseUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $($mainSolution.solutionid) and componenttype eq 66&`$select=objectid"
    $pcfComponents = (Invoke-RestMethod -Uri $componentsUrl -Method Get -Headers $headers).value
    
    Write-Output "  ℹ PCF controls en '$SolutionName': $($pcfComponents.Count)"
    
    # Buscar soluciones origen de cada PCF (solo unmanaged/exportables)
    $pcfSolutionNames = @()
    
    if ($pcfComponents.Count -gt 0) {
        foreach ($pcf in $pcfComponents) {
            $pcfSolQuery = "$dataverseUrl/api/data/v9.2/solutioncomponents?`$filter=objectid eq $($pcf.objectid) and componenttype eq 66&`$expand=solutionid(`$select=uniquename,ismanaged)"
            
            try {
                $pcfSolData = (Invoke-RestMethod -Uri $pcfSolQuery -Method Get -Headers $headers).value
                
                foreach ($item in $pcfSolData) {
                    if ($item.solutionid -and $item.solutionid.uniquename -ne $SolutionName -and -not $item.solutionid.ismanaged) {
                        if ($pcfSolutionNames -notcontains $item.solutionid.uniquename) {
                            $pcfSolutionNames += $item.solutionid.uniquename
                            Write-Output "  ✓ PCF detectado: $($item.solutionid.uniquename)"
                        }
                    }
                }
            } catch {
                # Ignorar PCF sin solución origen exportable
            }
        }
    }
    
    # Construir array de soluciones a exportar
    $solutionsToExport = @($SolutionName) + $pcfSolutionNames
    
    Write-Output "  ℹ Total soluciones a exportar: $($solutionsToExport.Count)"
    if ($pcfSolutionNames.Count -gt 0) {
        Write-Output "  ℹ PCF solutions: $($pcfSolutionNames -join ', ')"
    }
    
    # Paso 4: Exportar soluciones
    Write-Output "`n[4/7] Exportando soluciones..."
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tempPath = "$env:TEMP\PowerPlatform_$timestamp"
    New-Item -ItemType Directory -Path $tempPath | Out-Null
    
    foreach ($solName in $solutionsToExport) {
        Write-Output "  • Exportando: $solName"
        
        try {
            $exportPath = "$tempPath\$solName.zip"
            
            Export-CdsSolution -SolutionName $solName `
                -EnvironmentUrl $dataverseUrl `
                -Managed $false `
                -OutputPath $exportPath
            
            $fileSize = (Get-Item $exportPath).Length / 1MB
            Write-Output "    ✓ Exportado: $([Math]::Round($fileSize, 2)) MB"
        } catch {
            Write-Output "    ⚠ Advertencia exportando '$solName': $($_.Exception.Message)"
        }
    }
    
    # Paso 5: Exportar tablas
    Write-Output "`n[5/7] Exportando datos de tablas..."
    
    $tables = @(
        @{Name="accounts"; Schema="name,accountnumber,emailaddress1"},
        @{Name="contacts"; Schema="fullname,emailaddress1,mobilephone"},
        @{Name="leads"; Schema="fullname,companyname,emailaddress1"},
        @{Name="opportunities"; Schema="name,estimatedvalue,closeprobability"}
    )
    
    foreach ($table in $tables) {
        try {
            $tableUrl = "$dataverseUrl/api/data/v9.2/$($table.Name)?`$select=$($table.Schema)&`$top=5000"
            $records = Invoke-RestMethod -Uri $tableUrl -Method Get -Headers $headers
            
            $jsonPath = "$tempPath\$($table.Name).json"
            $records.value | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
            
            Write-Output "  ✓ $($table.Name): $($records.value.Count) registros"
        } catch {
            Write-Output "  ⚠ Error con $($table.Name): $($_.Exception.Message)"
        }
    }
    
    # Paso 6: Comprimir y subir
    Write-Output "`n[6/7] Comprimiendo backup..."
    
    $zipPath = "$env:TEMP\PowerPlatform_Backup_$timestamp.zip"
    Compress-Archive -Path "$tempPath\*" -DestinationPath $zipPath -Force
    
    $zipSize = (Get-Item $zipPath).Length / 1MB
    Write-Output "  ✓ Archivo: $([Math]::Round($zipSize, 2)) MB"
    
    Write-Output "`n[6a] Subiendo a Azure Storage..."
    
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
    
    $blobName = "pp-backup/PowerPlatform_Backup_$timestamp.zip"
    Set-AzStorageBlobContent -File $zipPath `
        -Container $containerName `
        -Blob $blobName `
        -Context $storageContext `
        -Force | Out-Null
    
    Write-Output "  ✓ Subido a: $blobName"
    
    # Paso 7: Log
    Write-Output "`n[7/7] Guardando log..."
    
    $logContent = @{
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        solutions = $solutionsToExport
        pcfSolutions = $pcfSolutionNames
        tables = $tables.Count
        backupFile = "PowerPlatform_Backup_$timestamp.zip"
        backupSizeMB = [Math]::Round($zipSize, 2)
        retentionDays = $RetentionDays
        autoDetectedPCF = $pcfSolutionNames.Count
    }
    
    $logJson = $logContent | ConvertTo-Json -Depth 10
    $logPath = "$env:TEMP\backup_log_$timestamp.json"
    $logJson | Out-File -FilePath $logPath -Encoding UTF8
    
    Set-AzStorageBlobContent -File $logPath `
        -Container $containerName `
        -Blob "logs/powerplatform/backup_log_$timestamp.json" `
        -Context $storageContext `
        -Force | Out-Null
    
    Write-Output "  ✓ Log guardado"
    
    # Limpiar
    Remove-Item -Path $tempPath -Recurse -Force
    Remove-Item -Path $zipPath -Force
    Remove-Item -Path $logPath -Force
    
    Write-Output "`n======================================"
    Write-Output "✅ BACKUP COMPLETADO"
    Write-Output "======================================"
    Write-Output "Soluciones: $($solutionsToExport.Count) (principal + $($pcfSolutionNames.Count) PCF)"
    Write-Output "Tamaño: $([Math]::Round($zipSize, 2)) MB"
    Write-Output "Ubicación: $blobName"
    Write-Output "======================================"
    
} catch {
    Write-Output "`n✗ ERROR: $($_.Exception.Message)"
    Write-Output "Línea: $($_.InvocationInfo.ScriptLineNumber)"
    throw
}
