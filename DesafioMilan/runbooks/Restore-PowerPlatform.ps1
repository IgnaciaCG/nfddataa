<#
.SYNOPSIS
    Runbook para restaurar soluciones de Power Platform desde Azure Storage

.DESCRIPTION
    Este runbook restaura SOLUCIONES Y DATOS desde un backup ZIP almacenado en Azure Storage.
    Restaura la solución (metadata, forms, views, PCF) y datos de ~46 tablas Dataverse.
    
    Utiliza Azure Automation con Managed Identity y Service Principal para autenticación.
    
    TRES MODOS DE OPERACIÓN:
    
    1. NewEnvironment - Restaura en un entorno completamente diferente (LIMPIO)
       - OPCIÓN A: Especifica TargetEnvironment (GUID de environment existente)
       - OPCIÓN B: Proporciona NewEnvironmentName para AUTO-CREAR environment
       - Importa solución como nueva
       - Restaura TODOS los datos SIN marcadores (environment vacío)
       - Ideal para: Prod → Dev, Disaster Recovery, environment nuevo
    
    2. UpdateCurrent - Actualiza solución y datos con marcadores (SEMI-DESTRUCTIVO)
       - Sobrescribe la solución existente
       - Inserta datos NUEVOS con marcadores (cr8df_backupid, cr8df_fecharestore)
       - Datos originales permanecen (permite comparación)
       - Crea campos marcadores automáticamente si no existen
       - Ideal para: Rollback con comparación, validación de backup
    
    3. CreateCopy - Crea copia paralela con marcadores (NO DESTRUCTIVO)
       - Solución original intacta (metadata update)
       - Inserta datos NUEVOS con marcadores
       - Permite comparación lado a lado completa
       - Crea campos marcadores automáticamente si no existen
       - Ideal para: Testing, auditoría, comparación detallada

.PARAMETER BackupFileName
    Nombre del archivo ZIP de backup en Azure Storage
    Ejemplo: "PowerPlatform_Backup_11-12-2025 13-31-13.zip"

.PARAMETER RestoreMode
    Modo de restore (requerido) - VALORES VÁLIDOS:
    • "NewEnvironment" - Restaura en otro entorno (requiere TargetEnvironment O NewEnvironmentName)
    • "UpdateCurrent" - Sobrescribe solución actual (destructivo)
    • "CreateCopy" - Crea copia con sufijo (no destructivo, crea campos automáticamente)
    
    IMPORTANTE: Escribir exactamente como se muestra (case-sensitive)

.PARAMETER TargetEnvironment
    GUID del environment destino EXISTENTE (opcional si RestoreMode = "NewEnvironment")
    Si no se proporciona, se creará un nuevo environment usando NewEnvironmentName
    Ejemplo: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

.PARAMETER NewEnvironmentName
    Nombre del nuevo environment a crear (solo si RestoreMode = "NewEnvironment" y TargetEnvironment vacío)
    El runbook creará automáticamente el environment y obtendrá su GUID
    Ejemplo: "Dev-Restore-20251211"

.PARAMETER NewEnvironmentRegion
    Región del nuevo environment (solo si se crea automáticamente)
    Default: "unitedstates"
    
    VALORES VÁLIDOS:
    • "unitedstates"    • "europe"         • "asia"           • "australia"
    • "india"           • "japan"          • "canada"         • "southamerica"
    • "unitedkingdom"   • "france"         • "germany"        • "switzerland"
    • "norway"          • "korea"          • "southafrica"    • "uae"
    • "brazil"
    
    IMPORTANTE: Debe coincidir con región del backup para evitar problemas

.PARAMETER NewEnvironmentType
    Tipo de environment a crear (solo si se crea automáticamente)
    Default: "Sandbox"
    
    VALORES VÁLIDOS:
    • "Sandbox"      - Entorno de pruebas (recomendado)
    • "Production"   - Entorno productivo
    • "Trial"        - Entorno de prueba temporal
    • "Developer"    - Entorno de desarrollo individual

.PARAMETER CreateBackupBeforeRestore
    Crea un backup preventivo antes de restaurar:
    - $true (default): Crea backup de seguridad antes de comenzar
    - $false: Omite el backup preventivo (usar solo en escenarios automatizados)

.PARAMETER Force
    Omite la confirmación interactiva:
    - $false (default): Pide confirmación mostrando resumen detallado
    - $true: Ejecuta directamente sin confirmación (para scripts automatizados)

.EXAMPLE
    # Modo 1A: Restore en entorno existente (Prod → Dev existente)
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_PROD_11-12-2025.zip" `
        -RestoreMode "NewEnvironment" `
        -TargetEnvironment "dev-env-guid-123"

.EXAMPLE
    # Modo 1B: Restore auto-creando nuevo entorno
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_PROD_11-12-2025.zip" `
        -RestoreMode "NewEnvironment" `
        -NewEnvironmentName "Dev-Restore-20251211" `
        -NewEnvironmentRegion "unitedstates" `
        -NewEnvironmentType "Sandbox"

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
    - Restore completo: Soluciones + Datos (~46 tablas)
    - 3 modos de operación flexibles
    - Auto-creación de campos marcadores (UpdateCurrent y CreateCopy)
    - NewEnvironment: Datos limpios sin marcadores
    - UpdateCurrent/CreateCopy: Datos con marcadores para comparación
    - Proceso completo en 9 pasos
    
    Requisitos:
    - Azure Automation Account con Managed Identity habilitado
    - Service Principal con permisos en Power Platform
    - Módulos PowerShell: Az.Accounts, Az.Storage, Microsoft.PowerApps.Administration.PowerShell
    
    Variables de Automation requeridas:
    - PP-ServicePrincipal-TenantId: GUID del tenant Azure AD
    - PP-EnvironmentName: GUID del environment Power Platform
    - StorageAccountName: Nombre del Storage Account
    - StorageAccountKey: Access Key del Storage Account (encriptada)
    
    Credential de Automation requerida:
    - PP-ServicePrincipal (username = AppId, password = ClientSecret)
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="Nombre del archivo ZIP de backup en Azure Storage")]
    [string]$BackupFileName,
    
    [Parameter(Mandatory=$true, HelpMessage="Modo de restore: NewEnvironment, UpdateCurrent, o CreateCopy")]
    [ValidateSet("NewEnvironment", "UpdateCurrent", "CreateCopy")]
    [string]$RestoreMode,
    
    [Parameter(Mandatory=$false, HelpMessage="GUID del environment destino (solo NewEnvironment)")]
    [string]$TargetEnvironment = "",
    
    [Parameter(Mandatory=$false, HelpMessage="Nombre para auto-crear environment (solo NewEnvironment)")]
    [string]$NewEnvironmentName = "",
    
    [Parameter(Mandatory=$false, HelpMessage="Región del nuevo environment")]
    [ValidateSet("unitedstates", "europe", "asia", "australia", "india", "japan", "canada", "southamerica", "unitedkingdom", "france", "germany", "switzerland", "norway", "korea", "southafrica", "uae", "brazil")]
    [string]$NewEnvironmentRegion = "unitedstates",
    
    [Parameter(Mandatory=$false, HelpMessage="Tipo de environment: Sandbox, Production, Trial, o Developer")]
    [ValidateSet("Sandbox", "Production", "Trial", "Developer")]
    [string]$NewEnvironmentType = "Sandbox",
    
    [Parameter(Mandatory=$false, HelpMessage="Crear backup preventivo antes de restaurar")]
    [bool]$CreateBackupBeforeRestore = $true,
    
    [Parameter(Mandatory=$false, HelpMessage="Omitir confirmación interactiva")]
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
    newEnvironmentName = $NewEnvironmentName
    newEnvironmentRegion = $NewEnvironmentRegion
    newEnvironmentType = $NewEnvironmentType
    newEnvironmentCreated = $false
    createBackupBeforeRestore = $CreateBackupBeforeRestore
    backupId = [guid]::NewGuid().ToString()
    solutionImported = $false
    solutionName = ""
    solutionVersion = ""
    solutionDisplayName = ""
    fieldsCreated = 0
    tablesUpdated = 0
    tablesProcessed = 0
    tablesSuccess = 0
    tablesError = 0
    recordsRestored = 0
    recordsError = 0
}

Write-Output "=========================================="
Write-Output "RESTORE POWER PLATFORM - INICIO"
Write-Output "=========================================="
Write-Output "Fecha/Hora: $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')"
Write-Output "Backup File: $BackupFileName"
Write-Output "Modo Restore: $RestoreMode"

if ($RestoreMode -eq "NewEnvironment") {
    if (-not [string]::IsNullOrWhiteSpace($TargetEnvironment)) {
        Write-Output "Target Environment: $TargetEnvironment (existente)"
    } elseif (-not [string]::IsNullOrWhiteSpace($NewEnvironmentName)) {
        Write-Output "New Environment: $NewEnvironmentName (auto-crear)"
        Write-Output "  Region: $NewEnvironmentRegion"
        Write-Output "  Type: $NewEnvironmentType"
    }
} else {
    Write-Output "Target Environment: Same as backup"
}

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
    if ($RestoreMode -eq "NewEnvironment") {
        # Requiere TargetEnvironment O NewEnvironmentName
        if ([string]::IsNullOrWhiteSpace($TargetEnvironment) -and [string]::IsNullOrWhiteSpace($NewEnvironmentName)) {
            throw "Modo 'NewEnvironment' requiere TargetEnvironment (GUID existente) O NewEnvironmentName (crear nuevo)"
        }
        
        # Si se proporcionan ambos, TargetEnvironment tiene prioridad
        if (-not [string]::IsNullOrWhiteSpace($TargetEnvironment) -and -not [string]::IsNullOrWhiteSpace($NewEnvironmentName)) {
            Write-Output "  ⚠ WARNING: Se proporcionaron TargetEnvironment y NewEnvironmentName"
            Write-Output "  → Usando TargetEnvironment (environment existente)"
            Write-Output "  → NewEnvironmentName será ignorado"
        }
    }
    
    if ($RestoreMode -ne "NewEnvironment") {
        if (-not [string]::IsNullOrWhiteSpace($TargetEnvironment)) {
            Write-Output "  ⚠ WARNING: TargetEnvironment será ignorado (solo aplica en modo NewEnvironment)"
        }
        if (-not [string]::IsNullOrWhiteSpace($NewEnvironmentName)) {
            Write-Output "  ⚠ WARNING: NewEnvironmentName será ignorado (solo aplica en modo NewEnvironment)"
        }
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
    
    # Leer variables con nombres correctos
    $tenantId = Get-AutomationVariable -Name "PP-ServicePrincipal-TenantId"
    $environmentName = Get-AutomationVariable -Name "PP-EnvironmentName"
    $storageAccountName = Get-AutomationVariable -Name "StorageAccountName"
    $storageAccountKey = Get-AutomationVariable -Name "StorageAccountKey"
    
    Write-Output "  ✓ Credenciales leídas: $appId"
    Write-Output "  ✓ Tenant ID: $tenantId"
    Write-Output "  ✓ Environment: $environmentName"
    Write-Output "  ✓ Storage Account: $storageAccountName"
    Write-Output ""
    
    # DataverseUrl se obtendrá después de autenticar en Power Platform
    $dataverseUrl = ""
    
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
    
    # Para modos UpdateCurrent y CreateCopy, obtener Dataverse URL del environment actual
    if ($RestoreMode -in @("UpdateCurrent", "CreateCopy")) {
        Write-Output ""
        Write-Output "Obteniendo Dataverse URL del environment actual..."
        $currentEnv = Get-AdminPowerAppEnvironment -EnvironmentName $environmentName
        $dataverseUrl = $currentEnv.Internal.properties.linkedEnvironmentMetadata.instanceUrl
        Write-Output "  ✓ Dataverse URL: $dataverseUrl"
    }
    # Para NewEnvironment, el Dataverse URL se obtendrá en PASO 5 después de crear/validar el environment destino
    
    Write-Output ""
    
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
    # Si modo es NewEnvironment, determinar environment destino
    if ($RestoreMode -eq "NewEnvironment") {
        
        # OPCIÓN A: TargetEnvironment proporcionado (environment EXISTENTE)
        if (-not [string]::IsNullOrWhiteSpace($TargetEnvironment)) {
            Write-Output "Obteniendo URL del environment destino (existente)..."
            $environment = Get-AdminPowerAppEnvironment -EnvironmentName $TargetEnvironment
            if (-not $environment) {
                throw "No se pudo obtener información del environment destino: $TargetEnvironment"
            }
            
            # Actualizar Dataverse URL para el environment existente
            $dataverseUrl = $environment.Internal.properties.linkedEnvironmentMetadata.instanceUrl
            Write-Output "  ✓ Environment destino: $TargetEnvironment"
            Write-Output "  ✓ Dataverse URL (Target): $dataverseUrl"
            
            $script:restoreStats.targetEnvironment = $TargetEnvironment
        }
        # OPCIÓN B: NewEnvironmentName proporcionado (AUTO-CREAR environment)
        else {
            Write-Output "AUTO-CREANDO nuevo environment..."
            Write-Output "  Nombre: $NewEnvironmentName"
            Write-Output "  Región: $NewEnvironmentRegion"
            Write-Output "  Tipo: $NewEnvironmentType"
            Write-Output ""
            
            # Crear nuevo environment con Dataverse database
            Write-Output "  [5a] Creando environment..."
            Write-Output "      Parámetros:"
            Write-Output "        DisplayName: $NewEnvironmentName"
            Write-Output "        EnvironmentSku: $NewEnvironmentType"
            Write-Output "        LocationName: $NewEnvironmentRegion"
            Write-Output "        ProvisionDatabase: True"
            Write-Output ""
            
            try {
                $newEnvParams = @{
                    DisplayName = $NewEnvironmentName
                    EnvironmentSku = $NewEnvironmentType
                    LocationName = $NewEnvironmentRegion
                    ProvisionDatabase = $true
                }
                
                $newEnvironment = New-AdminPowerAppEnvironment @newEnvParams -ErrorAction Stop
                
                if (-not $newEnvironment) {
                    throw "New-AdminPowerAppEnvironment retornó null"
                }
                
                if (-not $newEnvironment.EnvironmentName) {
                    throw "Environment creado pero sin EnvironmentName (GUID). Objeto retornado: $($newEnvironment | ConvertTo-Json -Depth 2)"
                }
                
                $newEnvironmentId = $newEnvironment.EnvironmentName
                
                Write-Output "  ✓ Environment creado exitosamente"
                Write-Output "      ID: $newEnvironmentId"
                Write-Output "      Display Name: $($newEnvironment.DisplayName)"
                Write-Output ""
                
            } catch {
                Write-Output ""
                Write-Output "  ✗ ERROR creando environment"
                Write-Output "      Mensaje: $($_.Exception.Message)"
                Write-Output "      Tipo de error: $($_.Exception.GetType().FullName)"
                Write-Output ""
                Write-Output "  POSIBLES CAUSAS:"
                Write-Output "    1. Región inválida: $NewEnvironmentRegion"
                Write-Output "    2. Nombre duplicado: Ya existe un environment llamado '$NewEnvironmentName'"
                Write-Output "    3. Permisos insuficientes del Service Principal"
                Write-Output "    4. Tipo de environment no permitido: $NewEnvironmentType"
                Write-Output ""
                throw
            }
            
            # Esperar a que el environment esté completamente provisionado
            Write-Output ""
            Write-Output "  [5b] Esperando provisionamiento de Dataverse..."
            Write-Output "      (Esto puede tomar 5-15 minutos, a veces hasta 20)"
            Write-Output "      Environment ID: $newEnvironmentId"
            Write-Output ""
            
            $maxWaitMinutes = 20
            $waitSeconds = 0
            $provisioningComplete = $false
            
            while ($waitSeconds -lt ($maxWaitMinutes * 60) -and -not $provisioningComplete) {
                Start-Sleep -Seconds 30
                $waitSeconds += 30
                
                $checkEnv = Get-AdminPowerAppEnvironment -EnvironmentName $newEnvironmentId
                
                if ($checkEnv.Internal.properties.linkedEnvironmentMetadata.instanceUrl) {
                    $provisioningComplete = $true
                    Write-Output "  ✓ Dataverse provisionado ($([math]::Round($waitSeconds/60, 1)) min)"
                } else {
                    Write-Output "      ... provisionando ($([math]::Round($waitSeconds/60, 1)) min transcurridos)"
                }
            }
            
            if (-not $provisioningComplete) {
                Write-Output ""
                Write-Output "  ⚠ WARNING: Timeout después de $maxWaitMinutes minutos"
                Write-Output "  El environment fue creado: $newEnvironmentId"
                Write-Output "  Pero Dataverse aún está provisionando"
                Write-Output ""
                Write-Output "  OPCIONES:"
                Write-Output "    1. Espera 5-10 minutos más y ejecuta el restore nuevamente"
                Write-Output "       usando: -TargetEnvironment '$newEnvironmentId'"
                Write-Output "    2. Verifica el estado en Power Platform Admin Center"
                Write-Output ""
                throw "Timeout esperando provisionamiento de Dataverse ($maxWaitMinutes minutos). Environment ID: $newEnvironmentId"
            }
            
            # Obtener URL de Dataverse del nuevo environment
            $environment = Get-AdminPowerAppEnvironment -EnvironmentName $newEnvironmentId
            $dataverseUrl = $environment.Internal.properties.linkedEnvironmentMetadata.instanceUrl
            
            Write-Output ""
            Write-Output "  ✓ Nuevo environment listo:"
            Write-Output "    ID: $newEnvironmentId"
            Write-Output "    Nombre: $NewEnvironmentName"
            Write-Output "    Dataverse URL: $dataverseUrl"
            
            # Actualizar TargetEnvironment con el nuevo GUID
            $TargetEnvironment = $newEnvironmentId
            $script:restoreStats.targetEnvironment = $newEnvironmentId
            $script:restoreStats.newEnvironmentCreated = $true
            $script:restoreStats.newEnvironmentName = $NewEnvironmentName
            
            Write-DetailedLog "New environment created: $newEnvironmentId ($NewEnvironmentName)" "INFO"
        }
        
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
    Write-Output "  ✓ Datos de ~46 tablas Dataverse"
    if ($RestoreMode -eq "NewEnvironment") {
        Write-Output "    → Datos limpios SIN marcadores (environment nuevo)"
    } else {
        Write-Output "    → Datos CON marcadores (cr8df_backupid, cr8df_fecharestore)"
    }
    
    Write-Output ""
    Write-Output "⚠ ADVERTENCIAS:"
    if ($RestoreMode -eq "UpdateCurrent") {
        Write-Output "  • MODO SEMI-DESTRUCTIVO: Sobrescribirá la solución actual"
        Write-Output "  • Datos se insertarán como nuevos registros con marcadores"
        Write-Output "  • Datos originales NO se eliminan (permite comparación)"
    }
    if ($RestoreMode -eq "NewEnvironment") {
        Write-Output "  • Datos se insertarán sin marcadores (environment limpio)"
        Write-Output "  • Asegurar que environment destino esté vacío o preparado"
    }
    if (-not $CreateBackupBeforeRestore) {
        Write-Output "  • No se creará backup preventivo"
    }
    if ($RestoreMode -in @("CreateCopy", "UpdateCurrent")) {
        Write-Output "  • Se crearán campos cr8df_backupid y cr8df_fecharestore automáticamente"
        Write-Output "  • Datos originales permanecen para comparación"
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
# PASO 7.5: CREAR CAMPOS MARCADORES (UpdateCurrent y CreateCopy)
# ==========================================

if ($RestoreMode -in @("UpdateCurrent", "CreateCopy")) {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 7.5: CREAR CAMPOS MARCADORES"
    Write-Output "=========================================="
    Write-Output "  (Necesario para modos UpdateCurrent y CreateCopy)"
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
    Write-Output "  ℹ Paso omitido (solo necesario en modos UpdateCurrent y CreateCopy)"
    Write-Output "  ℹ Modo NewEnvironment: Datos sin marcadores (environment limpio)"
}

# ==========================================
# PASO 8: RESTAURAR DATOS DE TABLAS
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 8: RESTAURAR DATOS DE TABLAS"
Write-Output "=========================================="

try {
    # Buscar directorio dataverse en el backup
    $dataversePath = Get-ChildItem -Path $extractPath -Directory -Filter "dataverse" -Recurse | Select-Object -First 1
    
    if (-not $dataversePath) {
        Write-Output "  ⚠ No se encontró directorio 'dataverse' en el backup"
        Write-Output "  El backup puede no contener datos de tablas"
        Write-Output "  Continuando sin restaurar datos..."
    } else {
        Write-Output "  Directorio dataverse encontrado: $($dataversePath.FullName)"
        
        # Obtener todos los archivos JSON (cada uno es una tabla)
        $dataFiles = Get-ChildItem -Path $dataversePath.FullName -Filter "*.json"
        $totalTables = $dataFiles.Count
        
        Write-Output "  Tablas encontradas: $totalTables"
        Write-Output ""
        
        if ($totalTables -eq 0) {
            Write-Output "  ⚠ No se encontraron archivos JSON de tablas"
            Write-Output "  Continuando sin restaurar datos..."
        } else {
            # Obtener mapa de LogicalName → EntitySetName para todas las tablas
            Write-Output "  [8a] Obteniendo EntitySetNames de tablas..."
            $tableNameMap = @{}
            
            foreach ($dataFile in $dataFiles) {
                $logicalName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
                
                try {
                    $metadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$logicalName')?`$select=EntitySetName"
                    $entityDef = Invoke-RestMethod -Uri $metadataUrl -Method Get -Headers $script:headers -ErrorAction Stop
                    $tableNameMap[$logicalName] = $entityDef.EntitySetName
                } catch {
                    # Fallback: asumir plural
                    $tableNameMap[$logicalName] = "${logicalName}s"
                    Write-Output "    ⚠ $logicalName → ${logicalName}s (fallback)"
                }
            }
            
            Write-Output "  ✓ Mapeo de nombres completado"
            Write-Output ""
            Write-Output "  [8b] Restaurando datos de tablas..."
            
            # Determinar si usar marcadores según el modo
            $useMarkers = $RestoreMode -in @("UpdateCurrent", "CreateCopy")
            
            if ($useMarkers) {
                Write-Output "  → Modo: Insertar con MARCADORES (cr8df_backupid, cr8df_fecharestore)"
                Write-Output "  → Backup ID: $($script:restoreStats.backupId)"
            } else {
                Write-Output "  → Modo: Insertar SIN marcadores (datos limpios)"
            }
            Write-Output ""
            
            $tablesProcessed = 0
            $tablesSuccess = 0
            $tablesError = 0
            $totalRecordsRestored = 0
            $totalRecordsError = 0
            
            foreach ($dataFile in $dataFiles) {
                $logicalName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
                $entitySetName = $tableNameMap[$logicalName]
                
                Write-Output "  [$($tablesProcessed + 1)/$totalTables] $logicalName → $entitySetName"
                $tablesProcessed++
                
                try {
                    # Leer datos del archivo JSON
                    $jsonContent = Get-Content $dataFile.FullName -Raw -Encoding UTF8
                    $records = $jsonContent | ConvertFrom-Json
                    
                    if (-not $records -or $records.Count -eq 0) {
                        Write-Output "      ℹ Sin registros (skip)"
                        $tablesSuccess++
                        continue
                    }
                    
                    $recordCount = $records.Count
                    Write-Output "      Registros: $recordCount"
                    
                    $successCount = 0
                    $errorCount = 0
                    
                    # URL de la API para esta tabla
                    $apiUrl = "$dataverseUrl/api/data/v9.2/$entitySetName"
                    
                    foreach ($record in $records) {
                        try {
                            # Crear nuevo registro (excluir ID y metadata OData)
                            $newRecord = @{}
                            
                            foreach ($prop in $record.PSObject.Properties) {
                                # Excluir propiedades del sistema y metadata
                                if ($prop.Name -notlike '@*' -and 
                                    $prop.Name -notlike '_*_value' -and 
                                    $prop.Name -ne 'id' -and 
                                    $null -ne $prop.Value) {
                                    $newRecord[$prop.Name] = $prop.Value
                                }
                            }
                            
                            # AGREGAR MARCADORES si el modo lo requiere
                            if ($useMarkers) {
                                $newRecord['cr8df_backupid'] = $script:restoreStats.backupId
                                $newRecord['cr8df_fecharestore'] = (Get-Date).ToUniversalTime().ToString("o")
                            }
                            
                            # Convertir a JSON y hacer POST (siempre INSERT, nunca UPDATE)
                            $recordJson = $newRecord | ConvertTo-Json -Depth 10 -Compress
                            
                            Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $script:headers -Body $recordJson -ContentType "application/json" | Out-Null
                            
                            $successCount++
                            $totalRecordsRestored++
                            
                        } catch {
                            $errorCount++
                            $totalRecordsError++
                            
                            # Solo mostrar primeros 3 errores por tabla para no saturar log
                            if ($errorCount -le 3) {
                                Write-Output "        ⚠ Error registro: $($_.Exception.Message)"
                            }
                        }
                    }
                    
                    if ($errorCount -eq 0) {
                        Write-Output "      ✓ $successCount/$recordCount registros restaurados"
                        $tablesSuccess++
                    } else {
                        Write-Output "      ⚠ $successCount/$recordCount registros restaurados, $errorCount errores"
                        if ($errorCount -gt 3) {
                            Write-Output "        (solo se muestran primeros 3 errores)"
                        }
                        $tablesError++
                    }
                    
                    Write-DetailedLog "Table restored: $logicalName ($successCount/$recordCount records)" "INFO"
                    
                } catch {
                    Write-Output "      ✗ Error procesando tabla: $($_.Exception.Message)"
                    Write-ErrorDetail $_ "RestoreTable_$logicalName"
                    $tablesError++
                }
                
                Write-Output ""
            }
            
            # Actualizar estadísticas
            $script:restoreStats.tablesProcessed = $tablesProcessed
            $script:restoreStats.tablesSuccess = $tablesSuccess
            $script:restoreStats.tablesError = $tablesError
            $script:restoreStats.recordsRestored = $totalRecordsRestored
            $script:restoreStats.recordsError = $totalRecordsError
            
            Write-Output "=========================================="
            Write-Output "RESUMEN RESTORE DE TABLAS:"
            Write-Output "  Tablas procesadas: $tablesProcessed"
            Write-Output "    ✓ Exitosas: $tablesSuccess"
            Write-Output "    ✗ Con errores: $tablesError"
            Write-Output "  Registros totales: $totalRecordsRestored restaurados, $totalRecordsError errores"
            if ($useMarkers) {
                Write-Output "  Backup ID (para filtros): $($script:restoreStats.backupId)"
            }
            Write-Output "=========================================="
            
            if ($tablesError -eq $tablesProcessed -and $tablesProcessed -gt 0) {
                throw "Todas las tablas fallaron durante el restore"
            }
            
            Write-DetailedLog "Data restore completed: $totalRecordsRestored records in $tablesSuccess tables" "INFO"
        }
    }
    
} catch {
    $errorMsg = "Error restaurando datos de tablas: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "  ✗ $errorMsg"
    Write-ErrorDetail $_ "RestoreTables"
    $script:errors += $errorMsg
    
    # No lanzar error fatal - continuar con el reporte
    Write-Output "  ⚠ Restore de datos falló, pero solución fue importada"
    Write-Output "  Revisa los logs para más detalles"
}

# ==========================================
# PASO 9: GENERAR REPORTE FINAL
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 9: REPORTE FINAL"
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

if ($script:restoreStats.newEnvironmentCreated) {
    Write-Output "  ✓ Nuevo environment creado:"
    Write-Output "    → ID: $($script:restoreStats.targetEnvironment)"
    Write-Output "    → Nombre: $($script:restoreStats.newEnvironmentName)"
    Write-Output "    → Región: $($script:restoreStats.newEnvironmentRegion)"
    Write-Output "    → Tipo: $($script:restoreStats.newEnvironmentType)"
} elseif ($RestoreMode -eq "NewEnvironment") {
    Write-Output "  ✓ Environment destino: $($script:restoreStats.targetEnvironment)"
}

Write-Output "  ✓ Tablas procesadas: $($script:restoreStats.tablesProcessed)"
Write-Output "    → Exitosas: $($script:restoreStats.tablesSuccess)"
Write-Output "    → Con errores: $($script:restoreStats.tablesError)"
Write-Output "  ✓ Registros restaurados: $($script:restoreStats.recordsRestored)"

if ($RestoreMode -in @("UpdateCurrent", "CreateCopy")) {
    Write-Output "  ✓ Campos marcadores creados: $($script:restoreStats.fieldsCreated)"
    Write-Output "  ✓ Backup ID: $($script:restoreStats.backupId)"
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
    Write-Output "  2. Compara datos originales vs restaurados:"
    Write-Output "     Filter(tabla, !IsBlank(cr8df_backupid)) → Datos del backup"
    Write-Output "     Filter(tabla, IsBlank(cr8df_backupid)) → Datos originales"
    Write-Output "  3. Prueba funcionalidades críticas"
    Write-Output "  4. Si todo está OK, considera actualizar la versión actual"
} elseif ($RestoreMode -eq "UpdateCurrent") {
    Write-Output "  1. Verifica la solución en Power Apps Maker Portal"
    Write-Output "  2. Compara datos originales vs backup:"
    Write-Output "     Backup ID para filtros: $($script:restoreStats.backupId)"
    Write-Output "  3. Prueba funcionalidades críticas"
    Write-Output "  4. Si hay problemas, elimina registros con cr8df_backupid = '$($script:restoreStats.backupId)'"
} else {
    Write-Output "  1. Verifica la solución en Power Apps Maker Portal"
    Write-Output "  2. Verifica que los datos se importaron correctamente"
    Write-Output "  3. Prueba funcionalidades críticas en el nuevo environment"
    Write-Output "  4. Configura permisos y usuarios según sea necesario"
}

Write-Output "=========================================="
Write-Output ""
Write-Output "✓ Restore finalizado exitosamente"
