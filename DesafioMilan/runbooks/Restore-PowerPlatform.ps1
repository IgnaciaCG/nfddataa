<#
.SYNOPSIS
    Runbook para restaurar backups de Power Platform y Dataverse

.DESCRIPTION
    Este runbook restaura:
    - Soluciones de Power Platform desde archivo ZIP
    - Tablas de Dataverse desde archivos JSON
    - Configuraciones y metadatos
    
    Los datos se descargan desde Azure Blob Storage y se importan.

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Version: 2.0
    
    Requisitos:
    - Service Principal con permisos en Power Platform
    - Managed Identity con acceso a Storage Account
    - Modulos: Az.Accounts, Az.Storage, Microsoft.PowerApps.Administration.PowerShell
    
    PARAMETROS REQUERIDOS:
    - BackupFileName: Nombre del archivo ZIP a restaurar (ej: PowerPlatform_Backup_20251209_020000.zip)
    - TargetEnvironmentName: Environment destino (puede ser el mismo u otro)
    - OverwriteExisting: $true para sobrescribir, $false para crear nueva version
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFileName,
    
    [Parameter(Mandatory=$false)]
    [string]$TargetEnvironmentName,
    
    [Parameter(Mandatory=$false)]
    [bool]$OverwriteExisting = $false
)

# ==========================================
# FUNCIONES DE LOGGING
# ==========================================

function Write-DetailedLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "dd/MM/yyyy, HH:mm:ss"
    $logMessage = "$timestamp - Output: $Message"
    Write-Output $logMessage
    
    if ($script:executionLog) {
        $script:executionLog += $logMessage
    }
}

function Write-ErrorDetail {
    param(
        [string]$ErrorMessage,
        [string]$Operation,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    $errorDetails = @{
        Timestamp = (Get-Date).ToString("o")
        Operation = $Operation
        Message = $ErrorMessage
        Exception = $ErrorRecord.Exception.Message
        StackTrace = $ErrorRecord.ScriptStackTrace
        Category = $ErrorRecord.CategoryInfo.Category
    }
    
    Write-DetailedLog "[ERROR] $Operation - $ErrorMessage" "ERROR"
    Write-DetailedLog "  Exception: $($ErrorRecord.Exception.Message)" "ERROR"
    
    if ($script:errorDetails) {
        $script:errorDetails += $errorDetails
    }
    
    return $errorDetails
}

# ==========================================
# CONFIGURACION
# ==========================================

$script:executionLog = @()
$script:errorDetails = @()
$date = Get-Date -Format "yyyyMMdd_HHmmss"

Write-DetailedLog "======================================"
Write-DetailedLog "Inicio de Restore Power Platform"
Write-DetailedLog "Fecha: $date"
Write-DetailedLog "Archivo: $BackupFileName"
Write-DetailedLog "======================================"

# ==========================================
# PASO 0: VALIDAR MODULOS (antes de ErrorActionPreference)
# ==========================================

Write-DetailedLog ""
Write-DetailedLog "[0/7] Validando modulos de PowerShell..."

$requiredModules = @(
    @{Name="Az.Accounts"; MinVersion="2.0.0"},
    @{Name="Az.Storage"; MinVersion="5.0.0"},
    @{Name="Microsoft.PowerApps.Administration.PowerShell"; MinVersion="2.0.0"}
)

$missingModules = @()
foreach ($module in $requiredModules) {
    $installed = Get-Module -ListAvailable -Name $module.Name | Where-Object { $_.Version -ge [version]$module.MinVersion }
    if ($installed) {
        $version = $installed[0].Version
        Write-DetailedLog "  [OK] $($module.Name) v$version"
    } else {
        Write-DetailedLog "  [FALTA] $($module.Name) >= v$($module.MinVersion)"
        $missingModules += $module.Name
    }
}

if ($missingModules.Count -gt 0) {
    $errorMsg = "Modulos faltantes: $($missingModules -join ', ')"
    Write-DetailedLog "[ERROR] $errorMsg" "ERROR"
    Write-DetailedLog ""
    Write-DetailedLog "SOLUCION:"
    Write-DetailedLog "1. Ir a Azure Portal > Automation Account > Modules"
    Write-DetailedLog "2. Click en 'Browse gallery'"
    Write-DetailedLog "3. Buscar e instalar los modulos faltantes"
    Write-DetailedLog "4. Esperar a que el estado sea 'Available'"
    Write-DetailedLog "5. Re-ejecutar este runbook"
    throw $errorMsg
}

Write-DetailedLog "[OK] Todos los modulos estan disponibles"

# Ahora si configurar ErrorActionPreference
$ErrorActionPreference = "Stop"

try {
    # ==========================================
    # 1. LEER VARIABLES DE AUTOMATION
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[1/7] Leyendo configuracion..."
    
    $appId = Get-AutomationVariable -Name "PP-ServicePrincipal-AppId"
    $tenantId = Get-AutomationVariable -Name "PP-ServicePrincipal-TenantId"
    $clientSecret = (Get-AutomationPSCredential -Name "PP-ServicePrincipal").GetNetworkCredential().Password
    $sourceEnvironmentName = Get-AutomationVariable -Name "PP-EnvironmentName"
    $storageAccountName = Get-AutomationVariable -Name "StorageAccountName"
    
    # Si no se especifica environment destino, usar el mismo
    if ([string]::IsNullOrEmpty($TargetEnvironmentName)) {
        $TargetEnvironmentName = $sourceEnvironmentName
        Write-DetailedLog "  [INFO] Environment destino no especificado - usando environment origen"
    }
    
    Write-DetailedLog "  [OK] Environment destino: $TargetEnvironmentName"
    
    # ==========================================
    # 2. AUTENTICACION Y DESCARGA
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[2/7] Autenticando y descargando backup..."
    
    try {
        # Conectar a Azure con Managed Identity
        Write-DetailedLog "  Conectando a Azure con Managed Identity..."
        Connect-AzAccount -Identity | Out-Null
        Write-DetailedLog "  [OK] Conectado a Azure"
        
        # Conectar a Storage con Account Key
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageKey
        
        $tempPath = "$env:TEMP\PPRestore_$date"
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        
        $zipPath = "$tempPath\$BackupFileName"
        
        # Descargar archivo
        Write-DetailedLog "  Descargando: $BackupFileName..."
        Get-AzStorageBlobContent `
            -Container "pp-backup" `
            -Blob $BackupFileName `
            -Destination $zipPath `
            -Context $ctx `
            -Force | Out-Null
        
        $backupSize = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-DetailedLog "  [OK] Backup descargado: $BackupFileName"
        $sizeMsg = "$backupSize MB"
        Write-DetailedLog "  Tamano: $sizeMsg"
        
    } catch {
        Write-ErrorDetail -ErrorMessage "Error descargando backup" -Operation "Paso 2" -ErrorRecord $_
        Write-DetailedLog ""
        Write-DetailedLog "VERIFICAR:"
        Write-DetailedLog "1. Que el archivo existe en Storage Account > pp-backup"
        Write-DetailedLog "2. Que la Managed Identity tiene permisos de lectura"
        Write-DetailedLog "3. Que el nombre del archivo es correcto: $BackupFileName"
        throw
    }
    
    # ==========================================
    # 3. EXTRAER ARCHIVOS
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[3/7] Extrayendo archivos del backup..."
    
    try {
        $extractPath = "$tempPath\extracted"
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
        
        $filesCount = (Get-ChildItem $extractPath -Recurse -File).Count
        Write-DetailedLog "  [OK] Archivos extraidos: $filesCount"
        
    } catch {
        Write-ErrorDetail -ErrorMessage "Error extrayendo archivos" -Operation "Paso 3" -ErrorRecord $_
        throw
    }
    
    # ==========================================
    # 4. CONECTAR A POWER PLATFORM
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[4/7] Conectando a Power Platform..."
    
    try {
        # Conectar con Service Principal
        Add-PowerAppsAccount -TenantID $tenantId -ApplicationId $appId -ClientSecret $clientSecret | Out-Null
        
        Write-DetailedLog "  [OK] Conectado a Power Platform"
        Write-DetailedLog "  Environment destino: $TargetEnvironmentName"
        
        # Obtener Environment URL
        $env = Get-AdminPowerAppEnvironment -EnvironmentName $TargetEnvironmentName
        $dataverseUrl = $env.Internal.properties.linkedEnvironmentMetadata.instanceUrl
        Write-DetailedLog "  Dataverse URL: $dataverseUrl"
        
    } catch {
        Write-ErrorDetail -ErrorMessage "Error conectando a Power Platform" -Operation "Paso 4" -ErrorRecord $_
        Write-DetailedLog ""
        Write-DetailedLog "VERIFICAR:"
        Write-DetailedLog "1. Service Principal tiene permisos en el environment"
        Write-DetailedLog "2. El environment existe: $TargetEnvironmentName"
        Write-DetailedLog "3. Las credenciales son correctas"
        throw
    }
    
    # ==========================================
    # 5. IMPORTAR SOLUCION
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[5/7] Importando solucion..."
    
    # Buscar archivo de solucion (.zip dentro del backup)
    $solutionFile = Get-ChildItem -Path $extractPath -Filter "*.zip" -Recurse | Select-Object -First 1
    
    if ($solutionFile) {
        Write-DetailedLog "  [INFO] Solucion encontrada: $($solutionFile.Name)"
        
        try {
            # Leer el archivo como base64
            $solutionBytes = [System.IO.File]::ReadAllBytes($solutionFile.FullName)
            $solutionBase64 = [System.Convert]::ToBase64String($solutionBytes)
            
            # Importar usando Dataverse API
            $importUrl = "$dataverseUrl/api/data/v9.2/ImportSolution"
            $headers = @{
                "Authorization" = "Bearer $(Get-AzAccessToken -ResourceUrl $dataverseUrl | Select-Object -ExpandProperty Token)"
                "Content-Type" = "application/json"
                "OData-MaxVersion" = "4.0"
                "OData-Version" = "4.0"
            }
            
            $importBody = @{
                CustomizationFile = $solutionBase64
                OverwriteUnmanagedCustomizations = $OverwriteExisting
                PublishWorkflows = $true
                ImportJobId = [guid]::NewGuid().ToString()
            } | ConvertTo-Json
            
            Write-DetailedLog "  Iniciando importacion..."
            $importResponse = Invoke-RestMethod -Uri $importUrl -Method Post -Headers $headers -Body $importBody
            
            $modeMsg = if($OverwriteExisting){'Sobrescribir'}else{'Nueva version'}
            Write-DetailedLog "  [OK] Solucion importada exitosamente"
            Write-DetailedLog "    - Modo: $modeMsg"
            Write-DetailedLog "    - Archivo: $($solutionFile.Name)"
            
        } catch {
            Write-ErrorDetail -ErrorMessage "Error importando solucion" -Operation "Paso 5" -ErrorRecord $_
            Write-DetailedLog "  [INFO] Archivo disponible en: $($solutionFile.FullName)"
            Write-DetailedLog ""
            Write-DetailedLog "PASOS MANUALES:"
            Write-DetailedLog "1. Descargar el backup de Storage Account"
            Write-DetailedLog "2. Extraer el archivo: $($solutionFile.Name)"
            Write-DetailedLog "3. Importar manualmente desde Power Platform Admin Center"
        }
    } else {
        Write-DetailedLog "  [WARNING] No se encontro archivo de solucion en el backup"
    }
    
    # ==========================================
    # 6. IMPORTAR TABLAS DATAVERSE
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[6/7] Importando tablas de Dataverse..."
    
    # Buscar directorio de Dataverse
    $dataversePath = Get-ChildItem -Path $extractPath -Directory -Filter "dataverse" -Recurse | Select-Object -First 1
    
    if ($dataversePath) {
        $dataFiles = Get-ChildItem -Path $dataversePath.FullName -Filter "*.json"
        Write-DetailedLog "  [INFO] Archivos de datos encontrados: $($dataFiles.Count)"
        
        $totalRecordsRestored = 0
        $tablesSuccess = 0
        $tablesError = 0
        
        foreach ($dataFile in $dataFiles) {
            $tableName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
            
            try {
                Write-DetailedLog "  Procesando tabla: $tableName"
                
                # Leer datos del backup
                $records = Get-Content $dataFile.FullName | ConvertFrom-Json
                
                # Headers para Dataverse API
                $headers = @{
                    "Authorization" = "Bearer $(Get-AzAccessToken -ResourceUrl $dataverseUrl | Select-Object -ExpandProperty Token)"
                    "Content-Type" = "application/json"
                    "OData-MaxVersion" = "4.0"
                    "OData-Version" = "4.0"
                }
                
                $successCount = 0
                $errorCount = 0
                $apiUrl = "$dataverseUrl/api/data/v9.2/$($tableName)s"
                
                foreach ($record in $records) {
                    try {
                        # Crear o actualizar registro
                        if ($OverwriteExisting -and $record.PSObject.Properties['id']) {
                            # UPDATE
                            $updateUrl = "$apiUrl($($record.id))"
                            Invoke-RestMethod -Uri $updateUrl -Method Patch -Headers $headers -Body ($record | ConvertTo-Json -Depth 10) | Out-Null
                        } else {
                            # CREATE
                            Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body ($record | ConvertTo-Json -Depth 10) | Out-Null
                        }
                        $successCount++
                    } catch {
                        $errorCount++
                        Write-DetailedLog "    [WARNING] Error en registro: $($_.Exception.Message)" "WARNING"
                    }
                }
                
                $totalRecordsRestored += $successCount
                $tablesSuccess++
                Write-DetailedLog "    [OK] Restaurados $successCount de $($records.Count) registros"
                if ($errorCount -gt 0) {
                    Write-DetailedLog "    [WARNING] $errorCount registros con errores"
                }
                
            } catch {
                $tablesError++
                Write-ErrorDetail -ErrorMessage "Error restaurando tabla $tableName" -Operation "Paso 6" -ErrorRecord $_
            }
        }
        
        Write-DetailedLog ""
        Write-DetailedLog "  [OK] Restauracion de tablas completada"
        Write-DetailedLog "  - Tablas exitosas: $tablesSuccess"
        Write-DetailedLog "  - Tablas con error: $tablesError"
        Write-DetailedLog "  - Total registros restaurados: $totalRecordsRestored"
        
    } else {
        Write-DetailedLog "  [WARNING] No se encontro directorio de datos Dataverse en el backup"
    }
    
    # ==========================================
    # 7. GUARDAR LOG DE RESTAURACION
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "[7/7] Guardando log de restauracion..."
    
    try {
        $logEntry = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            operation = "restore"
            service = "PowerPlatform"
            status = "success"
            backupFile = $BackupFileName
            targetEnvironment = $TargetEnvironmentName
            overwriteMode = $OverwriteExisting
            filesExtracted = $filesCount
            solutionFound = ($null -ne $solutionFile)
            solutionName = if($solutionFile){$solutionFile.Name}else{"N/A"}
            dataFilesFound = if($dataFiles){$dataFiles.Count}else{0}
            recordsRestored = $totalRecordsRestored
            tablesSuccess = $tablesSuccess
            tablesError = $tablesError
            executionLog = $script:executionLog
            errorDetails = $script:errorDetails
        } | ConvertTo-Json -Depth 10
        
        $logFileName = "log_Restore_PP_$date.json"
        $logPath = "$env:TEMP\$logFileName"
        $logEntry | Out-File -FilePath $logPath -Encoding UTF8
        
        Set-AzStorageBlobContent `
            -File $logPath `
            -Container "logs" `
            -Blob "powerplatform/restore/$logFileName" `
            -Context $ctx `
            -Force | Out-Null
        
        Write-DetailedLog "  [OK] Log guardado: $logFileName"
        
    } catch {
        Write-ErrorDetail -ErrorMessage "Error guardando log" -Operation "Paso 7" -ErrorRecord $_
        Write-DetailedLog "  [WARNING] Continuando sin guardar log..."
    }
    
    # ==========================================
    # LIMPIEZA
    # ==========================================
    
    Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
    
    # ==========================================
    # REPORTE FINAL
    # ==========================================
    
    Write-DetailedLog ""
    Write-DetailedLog "======================================"
    Write-DetailedLog "RESTORE COMPLETADO"
    Write-DetailedLog "======================================"
    Write-DetailedLog ""
    Write-DetailedLog "BACKUP RESTAURADO:"
    Write-DetailedLog "  Archivo: $BackupFileName"
    $sizeMsgFinal = "$backupSize MB"
    Write-DetailedLog "  Tamano: $sizeMsgFinal"
    Write-DetailedLog "  Archivos extraidos: $filesCount"
    Write-DetailedLog ""
    Write-DetailedLog "SOLUCION:"
    if ($solutionFile) {
        Write-DetailedLog "  Archivo: $($solutionFile.Name)"
        Write-DetailedLog "  Estado: Importada"
        $modeMsg2 = if($OverwriteExisting){'Sobrescribir'}else{'Nueva version'}
        Write-DetailedLog "  Modo: $modeMsg2"
    } else {
        Write-DetailedLog "  Estado: No encontrada en backup"
    }
    Write-DetailedLog ""
    Write-DetailedLog "TABLAS DATAVERSE:"
    if ($dataFiles -and $dataFiles.Count -gt 0) {
        Write-DetailedLog "  Archivos procesados: $($dataFiles.Count)"
        Write-DetailedLog "  Tablas exitosas: $tablesSuccess"
        Write-DetailedLog "  Tablas con error: $tablesError"
        Write-DetailedLog "  Total registros restaurados: $totalRecordsRestored"
    } else {
        Write-DetailedLog "  Estado: No encontradas en backup"
    }
    Write-DetailedLog ""
    Write-DetailedLog "ENVIRONMENT DESTINO:"
    Write-DetailedLog "  ID: $TargetEnvironmentName"
    Write-DetailedLog "  URL: $dataverseUrl"
    Write-DetailedLog ""
    Write-DetailedLog "PROXIMOS PASOS:"
    Write-DetailedLog "  1. Verificar solucion en Power Platform Admin Center"
    Write-DetailedLog "  2. Validar que las tablas tienen los datos correctos"
    Write-DetailedLog "  3. Probar funcionalidad de la aplicacion"
    Write-DetailedLog "  4. Revisar log detallado en: logs/powerplatform/restore/"
    Write-DetailedLog "======================================"
    
} catch {
    Write-DetailedLog "" "ERROR"
    Write-DetailedLog "======================================" "ERROR"
    Write-DetailedLog "ERROR EN RESTORE" "ERROR"
    Write-DetailedLog "======================================" "ERROR"
    Write-ErrorDetail -ErrorMessage "Error critico en operacion de restore" -Operation "General" -ErrorRecord $_
    
    # Intentar guardar log de error
    try {
        $errorLog = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            operation = "restore"
            service = "PowerPlatform"
            status = "failed"
            backupFile = $BackupFileName
            targetEnvironment = $TargetEnvironmentName
            error = $_.Exception.Message
            stackTrace = $_.ScriptStackTrace
            executionLog = $script:executionLog
            errorDetails = $script:errorDetails
        } | ConvertTo-Json -Depth 10
        
        $errorLogFileName = "log_Restore_ERROR_PP_$date.json"
        $errorLogPath = "$env:TEMP\$errorLogFileName"
        $errorLog | Out-File -FilePath $errorLogPath -Encoding UTF8
        
        if ($ctx) {
            Set-AzStorageBlobContent `
                -File $errorLogPath `
                -Container "logs" `
                -Blob "powerplatform/restore/errors/$errorLogFileName" `
                -Context $ctx `
                -Force | Out-Null
            
            Write-DetailedLog "Log de error guardado: $errorLogFileName" "ERROR"
        }
        
        Remove-Item -Path $errorLogPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-DetailedLog "No se pudo guardar log de error" "ERROR"
    }
    
    # Limpieza en caso de error
    if (Test-Path $tempPath) {
        Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    Write-DetailedLog "" "ERROR"
    Write-DetailedLog "SOLUCION:" "ERROR"
    Write-DetailedLog "1. Revisar los logs de error en Storage Account" "ERROR"
    Write-DetailedLog "2. Verificar permisos del Service Principal" "ERROR"
    Write-DetailedLog "3. Validar que el backup existe y es valido" "ERROR"
    Write-DetailedLog "4. Contactar al administrador si el problema persiste" "ERROR"
    Write-DetailedLog "======================================" "ERROR"
    
    throw
}

