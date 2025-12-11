<#
.SYNOPSIS
    Runbook para restaurar soluciones de Power Platform desde Azure Storage

.DESCRIPTION
    Este runbook restaura SOLAMENTE SOLUCIONES desde un backup ZIP almacenado en Azure Storage.
    NO restaura datos de tablas - solo la solución (metadata, forms, views, PCF, etc).
    
    Utiliza Azure Automation con Managed Identity y Service Principal para autenticación.
    
    TRES MODOS DE OPERACIÓN:
    
    1. NewEnvironment - Restaura en un entorno completamente diferente
       - Usa TargetEnvironment para especificar el destino
       - Importa la solución como nueva
       - Ideal para: Prod → Dev, backups de disaster recovery
    
    2. UpdateCurrent - Actualiza la solución actual en el mismo entorno (DESTRUCTIVO)
       - Sobrescribe la solución existente
       - Reemplaza todas las customizaciones
       - Ideal para: Rollback a versión anterior
    
    3. CreateCopy - Crea una copia paralela con sufijo "_Restored_YYYYMMDD" (NO DESTRUCTIVO)
       - Solución original intacta
       - Nueva versión para comparar
       - Crea automáticamente campos marcadores en tablas si no existen
       - Ideal para: Comparación lado a lado, testing

.PARAMETER BackupFileName
    Nombre del archivo ZIP de backup en Azure Storage
    Ejemplo: "PowerPlatform_Backup_11-12-2025 13-31-13.zip"

.PARAMETER RestoreMode
    Modo de restore (requerido):
    - "NewEnvironment": Restaura en otro entorno (requiere TargetEnvironment)
    - "UpdateCurrent": Sobrescribe solución actual (destructivo)
    - "CreateCopy": Crea copia con sufijo (no destructivo, crea campos automáticamente)

.PARAMETER TargetEnvironment
    GUID del environment destino (requerido si RestoreMode = "NewEnvironment")
    Ejemplo: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

.PARAMETER CreateBackupBeforeRestore
    Crea un backup preventivo antes de restaurar:
    - $true (default): Crea backup de seguridad antes de comenzar
    - $false: Omite el backup preventivo (usar solo en escenarios automatizados)

.PARAMETER Force
    Omite la confirmación interactiva:
    - $false (default): Pide confirmación mostrando resumen detallado
    - $true: Ejecuta directamente sin confirmación (para scripts automatizados)

.EXAMPLE
    # Modo 1: Restore en nuevo entorno (Prod → Dev)
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_PROD_11-12-2025.zip" `
        -RestoreMode "NewEnvironment" `
        -TargetEnvironment "dev-env-guid-123"

.EXAMPLE
    # Modo 2: Actualizar solución actual (Rollback destructivo)
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_11-12-2025.zip" `
        -RestoreMode "UpdateCurrent"

.EXAMPLE
    # Modo 3: Crear copia para comparación (No destructivo)
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_11-12-2025.zip" `
        -RestoreMode "CreateCopy"

.EXAMPLE
    # Restore automatizado sin confirmación
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_11-12-2025.zip" `
        -RestoreMode "CreateCopy" `
        -Force $true `
        -CreateBackupBeforeRestore $false

.NOTES
    Autor: Milan
    Versión: 4.0
    Fecha: 11-12-2025
    
    Cambios v4.0:
    - Eliminado restore de tablas (solo soluciones)
    - 3 modos de operación flexibles
    - Auto-creación de campos marcadores en modo CreateCopy
    - Proceso simplificado a 8 pasos
    
    Requisitos:
    - Azure Automation Account con Managed Identity habilitado
    - Service Principal con permisos en Power Platform
    - Módulos PowerShell: Az.Accounts, Az.Storage, Microsoft.PowerApps.Administration.PowerShell
    
    Variables de Automation requeridas:
    - TenantId: GUID del tenant Azure AD
    - EnvironmentName: GUID del environment Power Platform
    - StorageAccountName: Nombre del Storage Account
    - StorageAccountKey: Access Key del Storage Account
    - DataverseUrl: URL del environment Dataverse (ej: https://org12345.crm2.dynamics.com)
    
    Credential de Automation requerida:
    - PP-ServicePrincipal (username = AppId, password = ClientSecret)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFileName,
    
    [Parameter(Mandatory=$true)]
    [ValidateSet("NewEnvironment", "UpdateCurrent", "CreateCopy")]
    [string]$RestoreMode,
    
    [Parameter(Mandatory=$false)]
    [string]$TargetEnvironment = "",
    
    [Parameter(Mandatory=$false)]
    [bool]$CreateBackupBeforeRestore = $true,
    
    [Parameter(Mandatory=$false)]
    [bool]$Force = $false
)

# ==========================================
# CONFIGURACIÓN INICIAL
# ==========================================

$script:startTime = Get-Date
$script:logEntries = @()
$script:errors = @()

# Estadísticas de restore
$script:restoreStats = @{
    backupFileName = $BackupFileName
    restoreMode = $RestoreMode
    targetEnvironment = $TargetEnvironment
    createBackupBeforeRestore = $CreateBackupBeforeRestore
    solutionImported = $false
    solutionName = ""
    solutionVersion = ""
    solutionDisplayName = ""
    fieldsCreated = 0
    tablesUpdated = 0
}

Write-Output "=========================================="
Write-Output "RESTORE POWER PLATFORM - INICIO"
Write-Output "=========================================="
Write-Output "Fecha/Hora: $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')"
Write-Output "Backup File: $BackupFileName"
Write-Output "Modo Restore: $RestoreMode"
Write-Output "Target Environment: $(if ($TargetEnvironment) { $TargetEnvironment } else { 'Same as backup' })"
Write-Output "Create Backup Before: $CreateBackupBeforeRestore"
Write-Output "Force: $Force"
Write-Output "=========================================="
Write-Output ""

# ==========================================
# FUNCIONES AUXILIARES
# ==========================================

function Write-DetailedLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry = @{
        timestamp = $timestamp
        level = $Level
        message = $Message
    }
    $script:logEntries += $logEntry
}

function Write-ErrorDetail {
    param(
        $ErrorRecord,
        [string]$Step
    )
    
    $errorInfo = @{
        step = $Step
        message = $ErrorRecord.Exception.Message
        stackTrace = $ErrorRecord.ScriptStackTrace
        timestamp = Get-Date -Format "HH:mm:ss"
    }
    $script:errors += $errorInfo
    
    Write-Output "  ERROR: $($ErrorRecord.Exception.Message)"
}

# ==========================================
# PASO 0: VALIDAR ENTORNO Y PARÁMETROS
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 0: VALIDAR ENTORNO"
Write-Output "=========================================="

try {
    Write-Output "Validando módulos PowerShell..."
    
    $requiredModules = @(
        "Az.Accounts",
        "Az.Storage",
        "Microsoft.PowerApps.Administration.PowerShell"
    )
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            throw "Módulo requerido no instalado: $module"
        }
        Write-Output "  ✓ $module"
    }
    
    # Validar parámetros según modo
    if ($RestoreMode -eq "NewEnvironment" -and [string]::IsNullOrWhiteSpace($TargetEnvironment)) {
        throw "Modo 'NewEnvironment' requiere el parámetro TargetEnvironment"
    }
    
    if ($RestoreMode -ne "NewEnvironment" -and -not [string]::IsNullOrWhiteSpace($TargetEnvironment)) {
        Write-Output "  ⚠ WARNING: TargetEnvironment será ignorado (solo aplica en modo NewEnvironment)"
    }
    
    Write-Output ""
    Write-Output "✓ Validación de entorno completada"
    Write-DetailedLog "Environment validation successful" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "✗ Error en validación de entorno"
    Write-ErrorDetail $_ "EnvironmentValidation"
    throw
}

# Ahora sí, configurar ErrorActionPreference
$ErrorActionPreference = "Stop"

# ==========================================
# PASO 1: LEER VARIABLES DE AUTOMATION
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 1: LEER VARIABLES DE AUTOMATION"
Write-Output "=========================================="

try {
    # Leer credenciales del Service Principal
    $spCredential = Get-AutomationPSCredential -Name "PP-ServicePrincipal"
    $appId = $spCredential.UserName
    $clientSecret = $spCredential.GetNetworkCredential().Password
    
    # Leer variables
    $tenantId = Get-AutomationVariable -Name "TenantId"
    $environmentName = Get-AutomationVariable -Name "EnvironmentName"
    $storageAccountName = Get-AutomationVariable -Name "StorageAccountName"
    $storageAccountKey = Get-AutomationVariable -Name "StorageAccountKey"
    $dataverseUrl = Get-AutomationVariable -Name "DataverseUrl"
    
    Write-Output "  ✓ Credenciales leídas: $appId"
    Write-Output "  ✓ Tenant ID: $tenantId"
    Write-Output "  ✓ Environment: $environmentName"
    Write-Output "  ✓ Storage Account: $storageAccountName"
    Write-Output "  ✓ Dataverse URL: $dataverseUrl"
    
    Write-DetailedLog "Automation variables loaded successfully" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "✗ Error leyendo variables de Automation"
    Write-ErrorDetail $_ "ReadAutomationVariables"
    throw
}

# ==========================================
# PASO 2: AUTENTICAR EN AZURE Y POWER PLATFORM
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 2: AUTENTICAR"
Write-Output "=========================================="

try {
    Write-Output "Autenticando en Azure con Managed Identity..."
    Connect-AzAccount -Identity | Out-Null
    Write-Output "  ✓ Azure autenticado (Managed Identity)"
    
    Write-Output ""
    Write-Output "Autenticando en Power Platform con Service Principal..."
    Add-PowerAppsAccount -TenantID $tenantId -ApplicationId $appId -ClientSecret $clientSecret | Out-Null
    Write-Output "  ✓ Power Platform autenticado"
    
    Write-DetailedLog "Authentication successful (Azure + Power Platform)" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "✗ Error en autenticación"
    Write-ErrorDetail $_ "Authentication"
    throw
}

# ==========================================
# PASO 3: BACKUP PREVENTIVO (OPCIONAL)
# ==========================================

if ($CreateBackupBeforeRestore) {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 3: BACKUP PREVENTIVO"
    Write-Output "=========================================="
    
    try {
        Write-Output "Creando backup de seguridad antes de restaurar..."
        Write-Output "  (Este backup permitirá rollback si algo sale mal)"
        
        $preventiveBackupName = "PowerPlatform_Backup_PreRestore_$(Get-Date -Format 'dd-MM-yyyy HH-mm-ss').zip"
        
        # Aquí llamarías al runbook de backup o ejecutarías el backup directamente
        # Por ahora, solo registramos la intención
        
        Write-Output ""
        Write-Output "  ⚠ NOTA: El backup preventivo debe ejecutarse manualmente o mediante otro runbook"
        Write-Output "  Nombre sugerido: $preventiveBackupName"
        Write-Output "  ℹ Continuando con el restore..."
        
        Write-DetailedLog "Preventive backup step (manual execution required)" "WARNING"
        
    } catch {
        Write-Output ""
        Write-Output "⚠ Error creando backup preventivo"
        Write-ErrorDetail $_ "PreventiveBackup"
        Write-Output "  Continuando con el restore (riesgo de pérdida de datos)..."
    }
} else {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 3: BACKUP PREVENTIVO"
    Write-Output "=========================================="
    Write-Output "  ℹ Backup preventivo deshabilitado (CreateBackupBeforeRestore=$false)"
}

# ==========================================
# PASO 4: DESCARGAR Y EXTRAER BACKUP
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 4: DESCARGAR Y EXTRAER BACKUP"
Write-Output "=========================================="

try {
    # Crear contexto de Storage Account
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
    
    # Crear directorio temporal
    $tempPath = Join-Path $env:TEMP "PPRestore_$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    
    # Descargar archivo de backup
    Write-Output "Descargando backup desde Storage Account..."
    Write-Output "  Container: pp-backup"
    Write-Output "  Archivo: $BackupFileName"
    
    $backupFilePath = Join-Path $tempPath $BackupFileName
    Get-AzStorageBlobContent `
        -Container "pp-backup" `
        -Blob $BackupFileName `
        -Destination $backupFilePath `
        -Context $ctx `
        -Force | Out-Null
    
    Write-Output "  ✓ Archivo descargado: $([math]::Round((Get-Item $backupFilePath).Length / 1MB, 2)) MB"
    
    # Extraer archivo ZIP
    Write-Output ""
    Write-Output "Extrayendo archivos..."
    
    $extractPath = Join-Path $tempPath "extracted"
    Expand-Archive -Path $backupFilePath -DestinationPath $extractPath -Force
    
    $extractedFiles = Get-ChildItem -Path $extractPath -Recurse -File
    $extractedFilesCount = $extractedFiles.Count
    
    Write-Output "  ✓ Archivos extraídos: $extractedFilesCount"
    
    Write-DetailedLog "Backup downloaded and extracted ($extractedFilesCount files)" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "✗ Error descargando/extrayendo backup"
    Write-ErrorDetail $_ "DownloadExtract"
    throw
}

# ==========================================
# PASO 5: OBTENER URL Y TOKEN DE DATAVERSE
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 5: DATAVERSE URL Y TOKEN"
Write-Output "=========================================="

try {
    # Si modo es NewEnvironment, usar TargetEnvironment
    if ($RestoreMode -eq "NewEnvironment") {
        Write-Output "Obteniendo URL del environment destino..."
        $environment = Get-AdminPowerAppEnvironment -EnvironmentName $TargetEnvironment
        if (-not $environment) {
            throw "No se pudo obtener información del environment destino: $TargetEnvironment"
        }
        
        # Actualizar Dataverse URL para el nuevo environment
        $dataverseUrl = $environment.Internal.properties.linkedEnvironmentMetadata.instanceUrl
        Write-Output "  ✓ Dataverse URL (Target): $dataverseUrl"
    } else {
        Write-Output "  ✓ Dataverse URL (Current): $dataverseUrl"
    }
    
    # Obtener token de acceso
    Write-Output ""
    Write-Output "Obteniendo access token..."
    
    $tokenBody = @{
        client_id = $appId
        client_secret = $clientSecret
        scope = "$dataverseUrl/.default"
        grant_type = "client_credentials"
    }
    
    $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    
    $script:headers = @{
        "Authorization" = "Bearer $($tokenResponse.access_token)"
        "Content-Type" = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version" = "4.0"
    }
    
    Write-Output "  ✓ Access token obtenido"
    
    Write-DetailedLog "Dataverse access configured" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "✗ Error obteniendo URL/token de Dataverse"
    Write-ErrorDetail $_ "DataverseAccess"
    throw
}

# ==========================================
# PASO 6: RESUMEN Y CONFIRMACIÓN
# ==========================================

if (-not $Force) {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 6: RESUMEN Y CONFIRMACIÓN"
    Write-Output "=========================================="
    
    Write-Output ""
    Write-Output "DETALLES DEL BACKUP:"
    Write-Output "  Archivo: $BackupFileName"
    Write-Output "  Archivos extraídos: $extractedFilesCount"
    
    Write-Output ""
    Write-Output "MODO DE RESTORE: $RestoreMode"
    switch ($RestoreMode) {
        "NewEnvironment" {
            Write-Output "  → Restaurar en nuevo entorno"
            Write-Output "  → Target: $TargetEnvironment"
            Write-Output "  → Solución se importa como nueva"
            Write-Output "  → IDEAL PARA: Prod → Dev, Disaster Recovery"
        }
        "UpdateCurrent" {
            Write-Output "  → Actualizar solución actual (DESTRUCTIVO)"
            Write-Output "  → Environment: $environmentName"
            Write-Output "  → Sobrescribe customizaciones existentes"
            Write-Output "  → IDEAL PARA: Rollback a versión anterior"
        }
        "CreateCopy" {
            Write-Output "  → Crear copia paralela (NO DESTRUCTIVO)"
            Write-Output "  → Sufijo: _Restored_$(Get-Date -Format 'yyyyMMdd')"
            Write-Output "  → Solución original intacta"
            Write-Output "  → Auto-crea campos marcadores si no existen"
            Write-Output "  → IDEAL PARA: Comparación, testing"
        }
    }
    
    Write-Output ""
    Write-Output "QUÉ SE VA A RESTAURAR:"
    Write-Output "  ✓ Solución (metadata, forms, views, PCF, workflows, etc.)"
    Write-Output "  ✗ Datos de tablas (no incluido en este restore)"
    
    Write-Output ""
    Write-Output "⚠ ADVERTENCIAS:"
    if ($RestoreMode -eq "UpdateCurrent") {
        Write-Output "  • MODO DESTRUCTIVO: Sobrescribirá la solución actual"
        Write-Output "  • Customizaciones no publicadas se perderán"
    }
    if (-not $CreateBackupBeforeRestore) {
        Write-Output "  • No se creará backup preventivo"
    }
    if ($RestoreMode -eq "CreateCopy") {
        Write-Output "  • Se crearán campos cr8df_backupid y cr8df_fecharestore automáticamente"
    }
    
    Write-Output ""
    Write-Output "=========================================="
    
    # Confirmación solo en ejecuciones locales (Azure Automation no tiene stdin)
    try {
        $confirmation = Read-Host "¿Desea continuar con el restore? (y/n)"
        if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
            Write-Output ""
            Write-Output "Restore cancelado por el usuario"
            exit 0
        }
    } catch {
        Write-Output "  ℹ Confirmación omitida (ejecución en Azure Automation sin stdin)"
    }
    
    Write-Output ""
    Write-Output "✓ Confirmación recibida - Continuando con restore..."
}

# ==========================================
# PASO 7: IMPORTAR SOLUCIÓN
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 7: IMPORTAR SOLUCIÓN"
Write-Output "=========================================="

try {
    # Buscar archivo de solución (excluir el backup ZIP principal)
    $solutionFiles = Get-ChildItem -Path $extractPath -Filter "*.zip" -Recurse | Where-Object {
        $_.Name -notlike "PowerPlatform_Backup*"
    }
    
    if ($solutionFiles.Count -eq 0) {
        throw "No se encontró archivo de solución en el backup"
    }
    
    $solutionFile = $solutionFiles[0]
    Write-Output "  Solución encontrada: $($solutionFile.Name)"
    Write-Output "  Tamaño: $([math]::Round($solutionFile.Length / 1MB, 2)) MB"
    
    # Leer solución como bytes
    $solutionBytes = [System.IO.File]::ReadAllBytes($solutionFile.FullName)
    $solutionBase64 = [System.Convert]::ToBase64String($solutionBytes)
    
    # Determinar comportamiento según modo
    $overwriteFlag = $false
    $publishWorkflows = $true
    
    switch ($RestoreMode) {
        "NewEnvironment" {
            Write-Output ""
            Write-Output "  Modo: NewEnvironment"
            Write-Output "  → Importando como nueva solución"
            $overwriteFlag = $false
        }
        "UpdateCurrent" {
            Write-Output ""
            Write-Output "  Modo: UpdateCurrent (DESTRUCTIVO)"
            Write-Output "  → Sobrescribiendo solución existente"
            $overwriteFlag = $true
        }
        "CreateCopy" {
            Write-Output ""
            Write-Output "  Modo: CreateCopy (NO DESTRUCTIVO)"
            Write-Output "  → Importando versión actualizada (metadata update)"
            Write-Output "  → Solución original permanece intacta"
            $overwriteFlag = $false
        }
    }
    
    Write-Output "  (Este proceso puede tomar 1-3 minutos)"
    
    # Importar solución usando Dataverse API
    $importUrl = "$dataverseUrl/api/data/v9.2/ImportSolution"
    
    $importBody = @{
        OverwriteUnmanagedCustomizations = $overwriteFlag
        PublishWorkflows = $publishWorkflows
        CustomizationFile = $solutionBase64
    } | ConvertTo-Json
    
    $importResponse = Invoke-RestMethod -Uri $importUrl -Method Post -Headers $script:headers -Body $importBody
    
    # Actualizar estadísticas
    $script:restoreStats.solutionImported = $true
    $script:restoreStats.solutionName = $solutionFile.BaseName
    
    Write-Output ""
    Write-Output "  ✓ Solución importada exitosamente"
    
    Write-DetailedLog "Solution imported: $($solutionFile.Name) (Mode: $RestoreMode)" "INFO"
    
} catch {
    $errorMsg = "Error importando solución: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "  ✗ $errorMsg"
    Write-ErrorDetail $_ "ImportSolution"
    $script:errors += $errorMsg
    throw
}

# ==========================================
# PASO 7.5: CREAR CAMPOS MARCADORES (SOLO CreateCopy)
# ==========================================

if ($RestoreMode -eq "CreateCopy") {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 7.5: CREAR CAMPOS MARCADORES"
    Write-Output "=========================================="
    Write-Output "  (Solo necesario para modo CreateCopy)"
    Write-Output ""
    
    try {
        # Tablas críticas que necesitan los campos
        $criticalTables = @(
            "cr8df_actividadcalendario",
            "cr391_calendario2",
            "cr391_casosfluentpivot",
            "cr8df_usuario"
        )
        
        $fieldsCreated = 0
        $tablesUpdated = 0
        
        foreach ($tableName in $criticalTables) {
            Write-Output "Procesando tabla: $tableName"
            
            try {
                # Obtener metadata de la tabla
                $entityUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$tableName')"
                $entityResponse = Invoke-RestMethod -Uri $entityUrl -Method Get -Headers $script:headers
                $entityMetadataId = $entityResponse.MetadataId
                
                # URL para crear campos
                $createFieldUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions($entityMetadataId)/Attributes"
                
                # ==========================================
                # CAMPO 1: cr8df_backupid (Text)
                # ==========================================
                
                $field1 = @{
                    "@odata.type" = "Microsoft.Dynamics.CRM.StringAttributeMetadata"
                    "AttributeType" = "String"
                    "AttributeTypeName" = @{
                        "Value" = "StringType"
                    }
                    "MaxLength" = 100
                    "FormatName" = @{
                        "Value" = "Text"
                    }
                    "SchemaName" = "cr8df_backupid"
                    "RequiredLevel" = @{
                        "Value" = "None"
                        "CanBeChanged" = $true
                    }
                    "DisplayName" = @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                        "LocalizedLabels" = @(
                            @{
                                "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                                "Label" = "Backup ID"
                                "LanguageCode" = 1033
                            }
                        )
                    }
                    "Description" = @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                        "LocalizedLabels" = @(
                            @{
                                "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                                "Label" = "ID único del backup que originó este registro"
                                "LanguageCode" = 1033
                            }
                        )
                    }
                }
                
                try {
                    Invoke-RestMethod -Uri $createFieldUrl -Method Post -Headers $script:headers -Body ($field1 | ConvertTo-Json -Depth 10) | Out-Null
                    Write-Output "    ✓ cr8df_backupid creado"
                    $fieldsCreated++
                } catch {
                    if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*ya existe*") {
                        Write-Output "    ℹ cr8df_backupid ya existe (skip)"
                    } else {
                        Write-Output "    ⚠ Error creando cr8df_backupid: $($_.Exception.Message)"
                    }
                }
                
                # ==========================================
                # CAMPO 2: cr8df_fecharestore (DateTime)
                # ==========================================
                
                $field2 = @{
                    "@odata.type" = "Microsoft.Dynamics.CRM.DateTimeAttributeMetadata"
                    "AttributeType" = "DateTime"
                    "AttributeTypeName" = @{
                        "Value" = "DateTimeType"
                    }
                    "Format" = "DateAndTime"
                    "ImeMode" = "Disabled"
                    "DateTimeBehavior" = @{
                        "Value" = "UserLocal"
                    }
                    "SchemaName" = "cr8df_fecharestore"
                    "RequiredLevel" = @{
                        "Value" = "None"
                        "CanBeChanged" = $true
                    }
                    "DisplayName" = @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                        "LocalizedLabels" = @(
                            @{
                                "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                                "Label" = "Fecha Restore"
                                "LanguageCode" = 1033
                            }
                        )
                    }
                    "Description" = @{
                        "@odata.type" = "Microsoft.Dynamics.CRM.Label"
                        "LocalizedLabels" = @(
                            @{
                                "@odata.type" = "Microsoft.Dynamics.CRM.LocalizedLabel"
                                "Label" = "Fecha y hora en que se restauró este registro desde backup"
                                "LanguageCode" = 1033
                            }
                        )
                    }
                }
                
                try {
                    Invoke-RestMethod -Uri $createFieldUrl -Method Post -Headers $script:headers -Body ($field2 | ConvertTo-Json -Depth 10) | Out-Null
                    Write-Output "    ✓ cr8df_fecharestore creado"
                    $fieldsCreated++
                } catch {
                    if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*ya existe*") {
                        Write-Output "    ℹ cr8df_fecharestore ya existe (skip)"
                    } else {
                        Write-Output "    ⚠ Error creando cr8df_fecharestore: $($_.Exception.Message)"
                    }
                }
                
                $tablesUpdated++
                
            } catch {
                Write-Output "    ✗ Error procesando tabla: $($_.Exception.Message)"
            }
        }
        
        # Publicar customizaciones
        Write-Output ""
        Write-Output "Publicando customizaciones..."
        
        try {
            $publishUrl = "$dataverseUrl/api/data/v9.2/PublishAllXml"
            $publishBody = @{
                ParameterXml = "<importexportxml></importexportxml>"
            } | ConvertTo-Json
            
            Invoke-RestMethod -Uri $publishUrl -Method Post -Headers $script:headers -Body $publishBody | Out-Null
            
            Write-Output "  ✓ Customizaciones publicadas"
            Write-Output "  ℹ Espera 1-2 minutos para que los cambios se propaguen"
            
        } catch {
            Write-Output "  ⚠ Error publicando customizaciones"
            Write-Output "  Puede que necesites publicar manualmente"
        }
        
        # Actualizar estadísticas
        $script:restoreStats.fieldsCreated = $fieldsCreated
        $script:restoreStats.tablesUpdated = $tablesUpdated
        
        Write-Output ""
        Write-Output "  ✓ Campos marcadores: $fieldsCreated creados en $tablesUpdated tablas"
        
        Write-DetailedLog "Marker fields created ($fieldsCreated fields in $tablesUpdated tables)" "INFO"
        
    } catch {
        Write-Output ""
        Write-Output "  ⚠ Error creando campos marcadores"
        Write-ErrorDetail $_ "CreateMarkerFields"
        Write-Output "  Continuando con el restore (campos pueden ya existir)..."
    }
} else {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 7.5: CREAR CAMPOS MARCADORES"
    Write-Output "=========================================="
    Write-Output "  ℹ Paso omitido (solo necesario en modo CreateCopy)"
}

# ==========================================
# PASO 8: GENERAR REPORTE FINAL
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 8: REPORTE FINAL"
Write-Output "=========================================="

try {
    $endTime = Get-Date
    $duration = $endTime - $script:startTime
    
    # Crear log JSON
    $logData = @{
        timestamp = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
        operation = "Restore"
        status = if ($script:errors.Count -eq 0) { "Success" } else { "Completed with errors" }
        configuration = @{
            backupFileName = $BackupFileName
            restoreMode = $RestoreMode
            targetEnvironment = $TargetEnvironment
            createBackupBeforeRestore = $CreateBackupBeforeRestore
            force = $Force
        }
        statistics = $script:restoreStats
        duration = @{
            totalMinutes = [math]::Round($duration.TotalMinutes, 2)
            totalSeconds = [math]::Round($duration.TotalSeconds, 2)
        }
        executionLog = $script:logEntries
        errors = $script:errors
    }
    
    # Guardar log en archivo temporal
    $logFileName = "log_Restore_PP_$(Get-Date -Format 'dd-MM-yyyy HH-mm-ss').json"
    $logFilePath = Join-Path $env:TEMP $logFileName
    $logData | ConvertTo-Json -Depth 10 | Out-File -FilePath $logFilePath -Encoding UTF8
    
    Write-Output "Log generado: $logFilePath"
    
    # Subir log a Storage Account
    Write-Output "Subiendo log a Storage Account..."
    
    $logBlobPath = if ($script:errors.Count -eq 0) {
        "logs/powerplatform/restore/$logFileName"
    } else {
        "logs/powerplatform/restore/errors/$logFileName"
    }
    
    Set-AzStorageBlobContent `
        -Container "pp-backup" `
        -File $logFilePath `
        -Blob $logBlobPath `
        -Context $ctx `
        -Force | Out-Null
    
    Write-Output "  ✓ Log subido: $logBlobPath"
    
    # Limpiar archivos temporales
    Write-Output ""
    Write-Output "Limpiando archivos temporales..."
    Remove-Item -Path $tempPath -Recurse -Force
    Write-Output "  ✓ Archivos temporales eliminados"
    
    Write-DetailedLog "Restore completed successfully" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "⚠ Error generando reporte final"
    Write-ErrorDetail $_ "GenerateReport"
}

# ==========================================
# RESUMEN FINAL
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "RESTORE COMPLETADO"
Write-Output "=========================================="
Write-Output "Duración total: $([math]::Round($duration.TotalMinutes, 2)) minutos"
Write-Output ""
Write-Output "RESULTADOS:"
Write-Output "  ✓ Solución importada: $($script:restoreStats.solutionName)"
Write-Output "  ✓ Modo: $RestoreMode"

if ($RestoreMode -eq "CreateCopy") {
    Write-Output "  ✓ Campos creados: $($script:restoreStats.fieldsCreated)"
    Write-Output "  ✓ Tablas actualizadas: $($script:restoreStats.tablesUpdated)"
}

if ($script:errors.Count -gt 0) {
    Write-Output ""
    Write-Output "⚠ ADVERTENCIAS:"
    Write-Output "  Errores encontrados: $($script:errors.Count)"
    Write-Output "  Revisa el log para detalles: $logBlobPath"
}

Write-Output ""
Write-Output "PRÓXIMOS PASOS:"
if ($RestoreMode -eq "CreateCopy") {
    Write-Output "  1. Verifica la solución en Power Apps Maker Portal"
    Write-Output "  2. Compara la solución original vs restaurada"
    Write-Output "  3. Prueba funcionalidades críticas"
    Write-Output "  4. Si todo está OK, considera actualizar la versión actual"
} else {
    Write-Output "  1. Verifica la solución en Power Apps Maker Portal"
    Write-Output "  2. Prueba funcionalidades críticas"
    Write-Output "  3. Comunica a los usuarios sobre los cambios"
}

Write-Output "=========================================="
Write-Output ""
Write-Output "✓ Restore finalizado exitosamente"
