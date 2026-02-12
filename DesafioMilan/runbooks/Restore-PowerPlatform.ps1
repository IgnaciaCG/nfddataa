<#
.SYNOPSIS
    Restaura soluciones y datos de Power Platform en un nuevo environment

.DESCRIPTION
    Restaura soluciones (metadata, forms, views, PCF) y DATOS completos desde un backup ZIP.
    Utiliza Azure Automation con Managed Identity y Service Principal.
    
    CARACTERÍSTICAS:
    - Auto-crea environment con Dataverse
    - Importa solución completa
    - Restaura todos los datos de las tablas
    - Auto-fix de campos inválidos
    - Filtrado inteligente de tablas system-managed
    - Manejo de timeouts con retry
    
    CASOS DE USO:
    - Prod → Dev (clonar environment)
    - Disaster Recovery
    - Testing de actualizaciones
    - Migración entre tenants

.PARAMETER BackupFileName
    Nombre del archivo ZIP de backup en Azure Storage
    Ejemplo: "PowerPlatform_Backup_19-12-2025 18-05-12.zip"

.PARAMETER RestoreMode
    Modo de restore (solo "NewEnvironment" soportado)

.PARAMETER NewEnvironmentName
    Nombre del nuevo environment a crear
    Ejemplo: "Dev-Restore-20251211"

.PARAMETER ExistingEnvironmentId
    GUID de environment existente para continuar restore
    Útil si el provisionamiento excedió timeout

.PARAMETER NewEnvironmentRegion
    Región del nuevo environment. Default: "southamerica"
    Opciones: unitedstates, europe, asia, southamerica, etc.

.PARAMETER NewEnvironmentType
    Tipo de environment. Default: "Sandbox"
    Opciones: Sandbox, Production, Trial, Developer

.PARAMETER Force
    Omite confirmación interactiva (para automatización)

.EXAMPLE
    # Restore en environment existente
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_19-12-2025.zip" `
        -RestoreMode "NewEnvironment" `
        -ExistingEnvironmentId "d0d4c85a-09f2-f011-89f6-00224836e4e5"

.EXAMPLE
    # Restore auto-creando nuevo environment
    .\Restore-PowerPlatform.ps1 `
        -BackupFileName "PowerPlatform_Backup_19-12-2025.zip" `
        -RestoreMode "NewEnvironment" `
        -NewEnvironmentName "Dev-Restore" `
        -NewEnvironmentRegion "southamerica"

.NOTES
    Autor: Milan
    Versión: 6.16
    Fecha: 15-01-2026
    
    Cambios recientes v6.16:
    - Auto-fix iterativo de campos inválidos (hasta 10 intentos)
    - Detección mejorada de errores non-restorable (read-only, duplicados, virtual entities)
    - 158 tablas system-managed filtradas automáticamente
    - 99.7% tasa de éxito en restauración
    
    Requisitos:
    - Azure Automation Account con Managed Identity
    - Service Principal con Power Platform Admin
    - Módulos: Az.Accounts, Az.Storage, Microsoft.PowerApps.Administration.PowerShell
    
    Variables de Automation:
    - PP-ServicePrincipal-TenantId
    - StorageAccountName
    
    Credential de Automation:
    - PP-ServicePrincipal (AppId + ClientSecret)
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$BackupFileName,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("NewEnvironment")]
    [string]$RestoreMode = "NewEnvironment",
    
    [Parameter(Mandatory=$false)]
    [string]$NewEnvironmentName = "",
    
    [Parameter(Mandatory=$false)]
    [string]$ExistingEnvironmentId = "",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("unitedstates", "europe", "asia", "australia", "southamerica", "unitedkingdom", "canada", "india", "japan", "france", "germany")]
    [string]$NewEnvironmentRegion = "southamerica",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("Sandbox", "Production", "Trial", "Developer")]
    [string]$NewEnvironmentType = "Sandbox",
    
    [Parameter(Mandatory=$false)]
    [bool]$Force = $false
)

# CONFIGURACIÓN INICIAL
$script:startTime = Get-Date
$script:logEntries = @()
$script:errors = @()

# Estadísticas de restore
$script:restoreStats = @{
    backupFileName = $BackupFileName
    restoreMode = $RestoreMode
    newEnvironmentName = $NewEnvironmentName
    newEnvironmentId = ""
    newEnvironmentRegion = $NewEnvironmentRegion
    newEnvironmentType = $NewEnvironmentType
    newEnvironmentCreated = $false
    backupId = [guid]::NewGuid().ToString()
    solutionImported = $false
    solutionName = ""
    solutionVersion = ""
    solutionDisplayName = ""
    tablesProcessed = 0
    tablesSuccess = 0
    tablesError = 0
    recordsRestored = 0
    recordsError = 0
}

# Re-autenticación automática
$script:lastAuthTime = Get-Date
$script:authTokenLifetimeMinutes = 60
$lockFile = Join-Path $env:TEMP "restore-powerplatform.lock"

if (Test-Path $lockFile) {
    $lockContent = Get-Content $lockFile -Raw | ConvertFrom-Json
    $lockTime = [DateTime]::Parse($lockContent.StartTime)
    $elapsedMinutes = ((Get-Date) - $lockTime).TotalMinutes
    
    # Si el lock tiene más de 2 horas, asumimos que es stale y lo eliminamos
    if ($elapsedMinutes -gt 120) {
        Write-Output "Lock file antiguo detectado (${elapsedMinutes} minutos) - eliminando..."
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "ERROR: Hay otra ejecución de restore en curso"
        Write-Output "   Iniciada: $($lockContent.StartTime)"
        Write-Output "   PID: $($lockContent.ProcessId)"
        Write-Output "   Backup: $($lockContent.BackupFile)"
        Write-Output ""
        Write-Output "Si esta ejecución está bloqueada, elimina manualmente el lock:"
        Write-Output "   Remove-Item '$lockFile' -Force"
        throw "Restore ya está ejecutándose - abortando para evitar conflictos"
    }
}

# Crear lock file
$lockData = @{
    StartTime = (Get-Date -Format 'dd-MM-yyyy HH:mm:ss')
    ProcessId = $PID
    BackupFile = $BackupFileName
    RestoreMode = $RestoreMode
} | ConvertTo-Json

Set-Content -Path $lockFile -Value $lockData -Force

Write-Output "🔒 Lock file creado: $lockFile"
Write-Output ""

Write-Output "=========================================="
Write-Output "RESTORE POWER PLATFORM - INICIO"
Write-Output "=========================================="
Write-Output "Fecha/Hora: $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')"
Write-Output "Backup File: $BackupFileName"
Write-Output "Modo Restore: $RestoreMode"

if ($RestoreMode -eq "NewEnvironment") {
    if (-not [string]::IsNullOrWhiteSpace($NewEnvironmentName)) {
        Write-Output "New Environment: $NewEnvironmentName (auto-crear)"
        Write-Output "  Region: $NewEnvironmentRegion"
        Write-Output "  Type: $NewEnvironmentType"
    }
} else {
    Write-Output "Target Environment: Same as backup"
}

Write-Output "Force: $Force"
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
    
    # Limpiar lock file en caso de error
    $lockFile = Join-Path $env:TEMP "restore-powerplatform.lock"
    if (Test-Path $lockFile) {
        Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
    }
    
    $errorInfo = @{
        step = $Step
        message = $ErrorRecord.Exception.Message
        stackTrace = $ErrorRecord.ScriptStackTrace
        timestamp = Get-Date -Format "HH:mm:ss"
    }
    $script:errors += $errorInfo
    
    Write-Output "  ERROR: $($ErrorRecord.Exception.Message)"
}

function Add-ServicePrincipalToEnvironment {
    <#
    .SYNOPSIS
        Agrega el Service Principal como Application User al environment con roles de System Admin
    
    .DESCRIPTION
        Esta función es CRÍTICA para que el Service Principal pueda acceder a Dataverse
        después de crear o conectarse a un environment. Sin esto, el SP no tiene permisos.
        
        Usa múltiples métodos para garantizar que funcione:
        1. Power Platform Admin API (BAP API) - Con asignación automática de roles
        2. PowerApps cmdlet como fallback
        3. Instrucciones manuales si todo falla
    
    .PARAMETER EnvironmentId
        GUID del environment donde agregar el Service Principal
    
    .PARAMETER AppId
        Application ID del Service Principal a agregar
    
    .PARAMETER TenantId
        Tenant ID para autenticación
    
    .PARAMETER ClientSecret
        Client Secret del Service Principal
    
    .OUTPUTS
        Boolean - True si se agregó exitosamente, False si falló
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvironmentId,
        
        [Parameter(Mandatory=$true)]
        [string]$AppId,
        
        [Parameter(Mandatory=$false)]
        [string]$TenantId,
        
        [Parameter(Mandatory=$false)]
        [string]$ClientSecret
    )
    
    Write-Host "    Agregando Service Principal como Application User..."
    Write-Host "      Environment: $EnvironmentId"
    Write-Host "      App ID: $AppId"
    Write-Host ""
    
    $success = $false
    
    # MÉTODO 1: Power Platform Admin API (BAP API) - EL MÁS COMPLETO
    if (-not [string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($ClientSecret)) {
        Write-Host "      Método 1: Power Platform Admin API (con asignación de roles)..."
        
        try {
            # Obtener token para BAP API
            $tokenBody = @{
                client_id = $AppId
                client_secret = $ClientSecret
                scope = "https://service.powerapps.com/.default"
                grant_type = "client_credentials"
            }
            
            $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
            $bapToken = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30 -ErrorAction Stop
            
            $bapHeaders = @{
                "Authorization" = "Bearer $($bapToken.access_token)"
                "Content-Type" = "application/json"
            }
            
            # Paso 1: Verificar si el Application User ya existe
            $checkUserUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId/applicationUsers?api-version=2023-06-01"
            
            try {
                $existingUsers = Invoke-RestMethod -Uri $checkUserUrl -Headers $bapHeaders -Method Get -TimeoutSec 30 -ErrorAction Stop
                
                $existingUser = $existingUsers.value | Where-Object { $_.properties.applicationId -eq $AppId }
                
                if ($existingUser) {
                    Write-Host "        Application User ya existe"
                    Write-Host "        User ID: $($existingUser.name)"
                    $success = $true
                } else {
                    Write-Host "      Application User no existe, creando..."
                    
                    # Paso 2: Crear Application User con rol System Administrator
                    $createUserUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId/applicationUsers?api-version=2023-06-01"
                    
                    $userBody = @{
                        properties = @{
                            applicationId = $AppId
                            securityRoles = @(
                                @{
                                    name = "System Administrator"
                                }
                            )
                        }
                    } | ConvertTo-Json -Depth 10
                    
                    try {
                        $newUser = Invoke-RestMethod -Uri $createUserUrl -Headers $bapHeaders -Method Post -Body $userBody -TimeoutSec 30 -ErrorAction Stop
                        
                        Write-Host "        Application User creado exitosamente vía BAP API"
                        Write-Host "        User ID: $($newUser.name)"
                        Write-Host "        Role asignado: System Administrator"
                        Write-Host ""
                        $success = $true
                        
                    } catch {
                        $errorDetails = ""
                        if ($_.ErrorDetails.Message) {
                            try {
                                $errorObj = $_.ErrorDetails.Message | ConvertFrom-Json
                                $errorDetails = $errorObj.error.message
                            } catch {
                                $errorDetails = $_.ErrorDetails.Message
                            }
                        } else {
                            $errorDetails = $_.Exception.Message
                        }
                        
                        Write-Host "        Error creando Application User vía BAP API"
                        Write-Host "        Error: $errorDetails"
                        
                        # Si el error es de permisos, es posible que el SP no tenga permisos de admin
                        if ($errorDetails -like "*403*" -or $errorDetails -like "*Forbidden*" -or $errorDetails -like "*Unauthorized*") {
                            Write-Host "        Causa probable: Service Principal sin permisos de Power Platform Admin"
                        }
                    }
                }
                
            } catch {
                Write-Host "        No se pudo verificar/crear Application User vía BAP API"
                Write-Host "        Error: $($_.Exception.Message)"
            }
            
        } catch {
            Write-Host "        Error obteniendo token BAP API"
            Write-Host "        Error: $($_.Exception.Message)"
        }
    } else {
        Write-Host "        Método 1 omitido (TenantId o ClientSecret no proporcionados)"
    }
    
    # MÉTODO 2: PowerApps cmdlet (fallback)
    if (-not $success) {
        Write-Host ""
        Write-Host "      Método 2: PowerApps cmdlet (fallback)..."
        
        $cmdletAvailable = Get-Command -Name "New-PowerAppManagementApp" -ErrorAction SilentlyContinue
        
        if ($cmdletAvailable) {
            try {
                New-PowerAppManagementApp `
                    -EnvironmentName $EnvironmentId `
                    -ApplicationId $AppId `
                    -ErrorAction Stop | Out-Null
                
                Write-Host "        Application User agregado vía cmdlet"
                Write-Host "        IMPORTANTE: Debes asignar el rol manualmente en Power Platform Admin Center"
                Write-Host ""
                $success = $true
                
            } catch {
                Write-Host "       Cmdlet falló: $($_.Exception.Message)"
            }
        } else {
            Write-Host "       Cmdlet New-PowerAppManagementApp no disponible"
        }
    }
    
    # MÉTODO 3: Instrucciones manuales
    if (-not $success) {
        Write-Host ""
        Write-Host "      ═══════════════════════════════════════════════════"
        Write-Host "       TODOS LOS MÉTODOS AUTOMÁTICOS FALLARON"
        Write-Host "      ═══════════════════════════════════════════════════"
        Write-Host ""
        Write-Host "      ACCIÓN MANUAL REQUERIDA (5 minutos):"
        Write-Host ""
        Write-Host "      1. Ve a: https://admin.powerplatform.microsoft.com"
        Write-Host "      2. Environments → Busca el environment"
        Write-Host "      3. Settings → Users + permissions → Application users"
        Write-Host "      4. Click: + New app user"
        Write-Host "      5. Buscar app: $AppId"
        Write-Host "      6. Click: Add"
        Write-Host "      7. Seleccionar app → Edit security roles"
        Write-Host "      8. Marcar: System Administrator"
        Write-Host "      9. Click: Save"
        Write-Host "      10. Esperar 2-5 minutos para propagación"
        Write-Host ""
        Write-Host "      Después, re-ejecuta el restore con:"
        Write-Host "        -ExistingEnvironmentId '$EnvironmentId'"
        Write-Host ""
        Write-Host "      ═══════════════════════════════════════════════════"
        Write-Host ""
    }
    
    return $success
}

function Get-DataverseUrl {
    <#
    .SYNOPSIS
        Obtiene la URL de Dataverse de un environment de Power Platform
    
    .DESCRIPTION
        Función auxiliar que intenta obtener la URL de Dataverse usando 3 estrategias:
        1. Discovery Service (Microsoft oficial - más confiable)
        2. API REST de Power Platform (fallback)
        3. Variable de Automation PP-DataverseUrl (fallback manual)
    
    .PARAMETER EnvironmentId
        GUID del environment de Power Platform
    
    .PARAMETER TenantId
        GUID del tenant Azure AD
    
    .PARAMETER AppId
        Application ID del Service Principal
    
    .PARAMETER ClientSecret
        Client Secret del Service Principal
    
    .OUTPUTS
        String con la URL de Dataverse (ej: https://orgXXXXX.crm.dynamics.com)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvironmentId,
        
        [Parameter(Mandatory=$true)]
        [string]$TenantId,
        
        [Parameter(Mandatory=$true)]
        [string]$AppId,
        
        [Parameter(Mandatory=$true)]
        [string]$ClientSecret
    )
    
    Write-Host "  Obteniendo Dataverse URL para environment: $EnvironmentId"
    Write-Host ""
    
    # ESTRATEGIA 1: Discovery Service (oficial de Microsoft - MÁS CONFIABLE)
    try {
        Write-Host "  Discovery Service..."
        
        # Obtener token OAuth para Discovery Service
        # IMPORTANTE: El scope correcto es https://disco.crm.dynamics.com/.default
        $tokenParams = @{
            Method = 'POST'
            Uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
            Headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
            Body = @{
                client_id = $AppId
                client_secret = $ClientSecret
                scope = 'https://disco.crm.dynamics.com/.default'
                grant_type = 'client_credentials'
            }
        }
        
        $tokenResponse = Invoke-RestMethod @tokenParams -ErrorAction Stop
        
        # Consultar Discovery Service para obtener todas las instances del tenant
        $discoveryHeaders = @{
            'Authorization' = "Bearer $($tokenResponse.access_token)"
            'Accept' = 'application/json'
            'OData-MaxVersion' = '4.0'
            'OData-Version' = '4.0'
        }
        
        $discoveryUrl = "https://globaldisco.crm.dynamics.com/api/discovery/v2.0/Instances"
        $instancesResponse = Invoke-RestMethod -Uri $discoveryUrl -Headers $discoveryHeaders -Method Get -ErrorAction Stop
        
        # Buscar environment específico por ID (GUID)
        $targetInstance = $instancesResponse.value | Where-Object { $_.Id -eq $EnvironmentId }
        
        if ($targetInstance -and -not [string]::IsNullOrWhiteSpace($targetInstance.Url)) {
            Write-Host "      URL obtenida via Discovery Service"
            Write-Host "      Environment: $($targetInstance.FriendlyName)"
            Write-Host "      Región: $($targetInstance.Region)"
            Write-Host "      State: $($targetInstance.State)"
            Write-Host "      URL: $($targetInstance.Url)"
            return $targetInstance.Url
        } else {
            throw "Environment '$EnvironmentId' no encontrado en Discovery Service"
        }
        
    } catch {
        Write-Host "      Discovery Service falló: $($_.Exception.Message)"
    }
    
    # ESTRATEGIA 2: API REST de Power Platform
    try {
        Write-Host "    API REST de Power Platform..."
        
        # Obtener token OAuth
        $tokenParams = @{
            Method = 'POST'
            Uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
            Headers = @{ 'Content-Type' = 'application/x-www-form-urlencoded' }
            Body = @{
                client_id = $AppId
                client_secret = $ClientSecret
                scope = 'https://api.bap.microsoft.com/.default'
                grant_type = 'client_credentials'
            }
        }
        
        $tokenResponse = Invoke-RestMethod @tokenParams -ErrorAction Stop
        
        # Consultar environment via API REST
        $apiHeaders = @{
            'Authorization' = "Bearer $($tokenResponse.access_token)"
            'Content-Type' = 'application/json'
        }
        
        $apiUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId`?api-version=2023-06-01"
        $envResponse = Invoke-RestMethod -Uri $apiUrl -Headers $apiHeaders -Method Get -ErrorAction Stop
        
        # Extraer Dataverse URL
        $dataverseUrl = $envResponse.properties.linkedEnvironmentMetadata.instanceUrl
        
        if (-not [string]::IsNullOrWhiteSpace($dataverseUrl)) {
            Write-Host "    URL obtenida via API REST"
            Write-Host "    Environment: $($envResponse.properties.displayName)"
            return $dataverseUrl
        } else {
            throw "URL de Dataverse vacía en respuesta de API"
        }
        
    } catch {
        Write-Host "    API REST falló: $($_.Exception.Message)"
    }
    
    # ESTRATEGIA 3: Variable de Automation por Environment (fallback manual específico)
    try {
        Write-Host "    Variable de Automation por environment..."
        
        # Intentar variable específica para este environment primero
        $envVarName = "PP-DataverseUrl-$EnvironmentId"
        $envSpecificUrl = Get-AutomationVariable -Name $envVarName -ErrorAction SilentlyContinue
        
        if (-not [string]::IsNullOrWhiteSpace($envSpecificUrl)) {
            Write-Host "    URL obtenida de variable específica: $envVarName"
            Write-Host "    URL: $envSpecificUrl"
            return $envSpecificUrl
        }
        
        # Si no hay variable específica, intentar variable genérica
        $fallbackUrl = Get-AutomationVariable -Name "PP-DataverseUrl" -ErrorAction SilentlyContinue
        
        if (-not [string]::IsNullOrWhiteSpace($fallbackUrl)) {
            Write-Host "    URL obtenida de variable genérica PP-DataverseUrl"
            Write-Host "      ADVERTENCIA: Esta URL fue configurada manualmente"
            Write-Host "       Verifica que corresponda al environment correcto: $EnvironmentId"
            return $fallbackUrl
        }
        
        Write-Host "    No hay variables de Automation configuradas"
        
    } catch {
        Write-Host "    Error accediendo variables de Automation: $($_.Exception.Message)"
    }
    
    # Si todas las estrategias fallaron
    Write-Host ""
    Write-Host "  ══════════════════════════════════════════════════════════"
    Write-Host "  ERROR: No se pudo obtener Dataverse URL"
    Write-Host "  ══════════════════════════════════════════════════════════"
    Write-Host ""
    Write-Host "  SOLUCIÓN: Configurar variable de Automation"
    Write-Host "    1. Obtener URL manualmente de Power Platform Admin Center"
    Write-Host "    2. Crear variable: PP-DataverseUrl-$EnvironmentId"
    Write-Host "    3. Re-ejecutar el restore"
    Write-Host ""
    
    throw "No se pudo obtener Dataverse URL para environment: $EnvironmentId"
}

# ==========================================
# PASO 0: VALIDAR ENTORNO
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 0: VALIDAR ENTORNO"
Write-Output "=========================================="

try {
    Write-Output "Validando módulos PowerShell..."
    $requiredModules = @("Az.Accounts", "Az.Storage", "Microsoft.PowerApps.Administration.PowerShell")
    
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            throw "Módulo requerido no instalado: $module"
        }
        Write-Output "  $module"
    }
    
    Write-Output ""
    Write-Output "Validando parámetros para modo NewEnvironment..."
    
    $hasNewEnvName = -not [string]::IsNullOrWhiteSpace($NewEnvironmentName)
    $hasExistingEnvId = -not [string]::IsNullOrWhiteSpace($ExistingEnvironmentId)
    
    if (-not $hasNewEnvName -and -not $hasExistingEnvId) {
        throw "Requiere NewEnvironmentName (crear) O ExistingEnvironmentId (continuar)"
    }
    
    if ($hasNewEnvName -and $hasExistingEnvId) {
        throw "Parámetros mutuamente exclusivos: NewEnvironmentName O ExistingEnvironmentId"
    }
    
    if ($hasNewEnvName) {
        Write-Output "  Modo: Crear nuevo environment '$NewEnvironmentName'"
    } else {
        Write-Output "  Modo: Continuar restore en environment existente '$ExistingEnvironmentId'"
    }
    
    # Validar GUID si se proporciona ExistingEnvironmentId
    if ($hasExistingEnvId) {
        try {
            [System.Guid]::Parse($ExistingEnvironmentId) | Out-Null
            Write-Output "  GUID válido: $ExistingEnvironmentId"
        } catch {
            throw "ExistingEnvironmentId debe ser GUID válido"
        }
    }
    
    Write-Output ""
   
    
} catch {
    Write-Output ""
    Write-Output "Error en validación de entorno"
    Write-ErrorDetail $_ "EnvironmentValidation"
    throw
}

$ErrorActionPreference = "Stop"

# PASO 1: LEER VARIABLES
Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 1: LEER VARIABLES DE AUTOMATION"
Write-Output "=========================================="

try {
    $spCredential = Get-AutomationPSCredential -Name "PP-ServicePrincipal"
    $appId = $spCredential.UserName
    $clientSecret = $spCredential.GetNetworkCredential().Password
    
    $tenantId = Get-AutomationVariable -Name "PP-ServicePrincipal-TenantId"
    $storageAccountName = Get-AutomationVariable -Name "StorageAccountName"
    $storageAccountKey = Get-AutomationVariable -Name "StorageAccountKey"
    
    # Guardar para token refresh
    $script:appId = $appId
    $script:clientSecret = $clientSecret
    $script:tenantId = $tenantId
    
    Write-Output "  OK Service Principal: $appId"
    Write-Output "  OK Tenant ID: $tenantId"
    Write-Output "  OK Storage Account: $storageAccountName"
    Write-Output ""
    
} catch {
    Write-Output ""
    Write-Output 'Error leyendo variables de Automation'
    Write-ErrorDetail $_ "ReadAutomationVariables"
    throw
}

# PASO 2: AUTENTICAR
Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 2: AUTENTICAR"
Write-Output "=========================================="

try {
    Connect-AzAccount -Identity | Out-Null
    Write-Output "Azure autenticado (Managed Identity)"
    
    try {
        Add-PowerAppsAccount -TenantID $tenantId -ApplicationId $appId -ClientSecret $clientSecret -ErrorAction Stop | Out-Null
        $script:lastAuthTime = Get-Date
        
        Get-AdminPowerAppEnvironment -ErrorAction Stop | Select-Object -First 1 | Out-Null
        Write-Output "Power Platform autenticado"
        
    } catch {
        if ($_.Exception.Message -match "Forbidden|does not have permission") {
            throw "Service Principal sin permisos de administrador (requiere Dynamics 365 Administrator + Power Platform Administrator)"
        }
        
        # Fallback: OAuth manual
        $tokenBody = @{
            grant_type = "client_credentials"
            client_id = $appId
            client_secret = $clientSecret
            scope = "https://service.powerapps.com/.default"
        }
        
        $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        
        if (-not $tokenResponse.access_token) {
            throw "No se pudo obtener token de autenticación"
        }
        
        $script:powerAppsToken = $tokenResponse.access_token
        Write-Output "Power Platform autenticado (OAuth manual)"
    }
    
} catch {
    Write-Output ""
    Write-Output "Error en autenticación"
    Write-ErrorDetail $_ "Authentication"
    throw
}

# PASO 3: DESCARGAR Y EXTRAER BACKUP
Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 3: DESCARGAR Y EXTRAER BACKUP"
Write-Output "=========================================="

try {
    $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
    
    $tempPath = Join-Path $env:TEMP "PPRestore_$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    
    Write-Output "Descargando: $BackupFileName"
    
    $backupFilePath = Join-Path $tempPath $BackupFileName
    Get-AzStorageBlobContent `
        -Container "pp-backup" `
        -Blob $BackupFileName `
        -Destination $backupFilePath `
        -Context $ctx `
        -Force | Out-Null
    
    $fileSize = [math]::Round((Get-Item $backupFilePath).Length / 1MB, 2)
    Write-Output "  Descargado: $fileSize MB"
    
    $extractPath = Join-Path $tempPath "extracted"
    Expand-Archive -Path $backupFilePath -DestinationPath $extractPath -Force
    
    $extractedFiles = Get-ChildItem -Path $extractPath -Recurse -File
    Write-Output "  Extraídos: $($extractedFiles.Count) archivos"
    
    # Leer metadata
    $envConfigPath = Join-Path $extractPath "environment-config.json"
    $script:backupMetadata = $null
    
    if (Test-Path $envConfigPath) {
        try {
            $script:backupMetadata = Get-Content $envConfigPath -Raw | ConvertFrom-Json
            
            Write-Output ""
            Write-Output "Metadata del backup:"
            Write-Output "  Version: $($script:backupMetadata.BackupMetadata.Version)"
            Write-Output "  Fecha: $($script:backupMetadata.BackupMetadata.Date)"
            Write-Output "  Soluciones: $($script:backupMetadata.Solutions.Count)"
            Write-Output "  Tablas custom: $($script:backupMetadata.Tables.Custom.Count)"
            Write-Output "  Registros: $($script:backupMetadata.Statistics.RecordsExported)"
            
            if ($script:backupMetadata.FormulasRemoved.Count -gt 0) {
                Write-Output "    Fórmulas removidas: $($script:backupMetadata.FormulasRemoved.Count) (recrear manualmente)"
            }
            
        } catch {
            Write-Output "    No se pudo leer metadata: $($_.Exception.Message)"
        }
    }
    
} catch {
    Write-Output ""
    Write-Output "Error descargando/extrayendo backup"
    Write-ErrorDetail $_ "DownloadExtract"
    throw
}

# PASO 4: ENVIRONMENT Y DATAVERSE URL
Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 4: ENVIRONMENT Y DATAVERSE URL"
Write-Output "=========================================="

try {
    $targetEnvironmentId = ""
    
    if (-not [string]::IsNullOrWhiteSpace($ExistingEnvironmentId)) {
        Write-Output "Validando environment existente: $ExistingEnvironmentId"
        $targetEnvironmentId = $ExistingEnvironmentId
        
        try {
            $existingEnv = $null
            $dataverseUrl = $null
            
            # MÉTODO 1: Discovery Service
            try {
                $discoveryTokenBody = @{
                    client_id = $appId
                    client_secret = $clientSecret
                    scope = "https://disco.crm.dynamics.com/.default"
                    grant_type = "client_credentials"
                }
                
                $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
                $discoveryTokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $discoveryTokenBody -ContentType "application/x-www-form-urlencoded"
                
                $discoveryHeaders = @{
                    "Authorization" = "Bearer $($discoveryTokenResponse.access_token)"
                    "Accept" = "application/json"
                    "OData-MaxVersion" = "4.0"
                    "OData-Version" = "4.0"
                }
                
                $discoveryUrl = "https://globaldisco.crm.dynamics.com/api/discovery/v2.0/Instances"
                $instancesResponse = Invoke-RestMethod -Uri $discoveryUrl -Headers $discoveryHeaders -Method Get
                
                $targetInstance = $instancesResponse.value | Where-Object { $_.Id -eq $targetEnvironmentId }
                
                if ($targetInstance) {
                    $dataverseUrl = $targetInstance.Url
                    
                    $existingEnv = [PSCustomObject]@{
                        DisplayName = $targetInstance.FriendlyName
                        EnvironmentName = $targetInstance.Id
                        Location = $targetInstance.Region
                        EnvironmentType = $targetInstance.Type
                        DataverseUrl = $dataverseUrl
                        State = $targetInstance.State
                        Version = $targetInstance.Version
                    }
                    
                    Write-Output "    Environment: $($existingEnv.DisplayName) ($dataverseUrl)"
                } else {
                    throw "Environment no encontrado"
                }
                
            } catch {
                $existingEnv = $null
                $dataverseUrl = $null
            }
            
            # MÉTODO 2: BAP API (Fallback)
            if ([string]::IsNullOrWhiteSpace($dataverseUrl)) {
                try {
                    $bapTokenBody = @{
                        client_id = $appId
                        client_secret = $clientSecret
                        scope = "https://service.powerapps.com/.default"
                        grant_type = "client_credentials"
                    }
                    
                    $bapTokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $bapTokenBody -ContentType "application/x-www-form-urlencoded"
                    
                    $bapHeaders = @{
                        "Authorization" = "Bearer $($bapTokenResponse.access_token)"
                        "Content-Type" = "application/json"
                    }
                    
                    $envApiUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments/$targetEnvironmentId`?api-version=2023-06-01"
                    $envInfo = Invoke-RestMethod -Uri $envApiUrl -Headers $bapHeaders -Method Get
                    
                    if ($envInfo.properties.linkedEnvironmentMetadata.instanceUrl) {
                        $dataverseUrl = $envInfo.properties.linkedEnvironmentMetadata.instanceUrl
                        
                        $existingEnv = [PSCustomObject]@{
                            DisplayName = $envInfo.properties.displayName
                            EnvironmentName = $targetEnvironmentId
                            Location = $envInfo.location
                            EnvironmentType = $envInfo.properties.environmentSku
                            DataverseUrl = $dataverseUrl
                        }
                        
                        Write-Output "    Environment (BAP): $($existingEnv.DisplayName)"
                    } else {
                        throw "BAP API no devolvió URL"
                    }
                    
                } catch {
                    $existingEnv = $null
                    $dataverseUrl = $null
                }
            }
            
            if (-not $existingEnv -or [string]::IsNullOrWhiteSpace($dataverseUrl)) {
                throw "Environment '$targetEnvironmentId' no existe o no es accesible"
            }
            
        } catch {
            $validationError = $_.Exception.Message
            Write-Output ""
            Write-Output "  ERROR: $validationError"
            Write-Output ""
            
            # Intentar agregar Service Principal si es problema de permisos
            if ($validationError -like "*403*" -or $validationError -like "*Forbidden*" -or $validationError -like "*not a member*") {
                Write-Output "  Intentando agregar Service Principal..."
                
                $permissionsAdded = Add-ServicePrincipalToEnvironment `
                    -EnvironmentId $targetEnvironmentId `
                    -AppId $appId `
                    -TenantId $tenantId `
                    -ClientSecret $clientSecret
                
                if ($permissionsAdded) {
                    Write-Output "    Service Principal agregado. Esperando propagación (30s)..."
                    Start-Sleep -Seconds 30
                    
                    try {
                        $dataverseUrl = Get-DataverseUrl -EnvironmentId $targetEnvironmentId -TenantId $tenantId -AppId $appId -ClientSecret $clientSecret
                        
                        if (-not [string]::IsNullOrWhiteSpace($dataverseUrl)) {
                            Write-Output "    Environment ahora accesible"
                            
                            $existingEnv = [PSCustomObject]@{
                                DisplayName = "Environment-$targetEnvironmentId"
                                EnvironmentName = $targetEnvironmentId
                                DataverseUrl = $dataverseUrl
                            }
                        } else {
                            throw "Permisos agregados pero no propagados. Espera 5 min y re-ejecuta con: -ExistingEnvironmentId '$targetEnvironmentId'"
                        }
                    } catch {
                        throw "Permisos agregados pero no propagados. Espera 5 min y re-ejecuta con: -ExistingEnvironmentId '$targetEnvironmentId'"
                    }
                } else {
                    Write-Output ""
                    Write-Output "  SOLUCIÓN: Agregar Service Principal manualmente"
                    Write-Output "    1. https://admin.powerplatform.microsoft.com"
                    Write-Output "    2. Environments → $targetEnvironmentId → Settings"
                    Write-Output "    3. Application users → + New app user"
                    Write-Output "    4. Buscar AppId: $appId"
                    Write-Output "    5. Role: System Administrator"
                    Write-Output "    6. Esperar 5 min y re-ejecutar con: -ExistingEnvironmentId '$targetEnvironmentId'"
                    Write-Output ""
                    throw "Service Principal sin permisos"
                }
            } else {
                Write-Output "  Verifica que el Environment ID es correcto: $targetEnvironmentId"
                Write-Output "  https://admin.powerplatform.microsoft.com"
                throw
            }
        }
        
        $script:restoreStats.newEnvironmentCreated = $false
        $script:restoreStats.newEnvironmentId = $targetEnvironmentId
        $script:restoreStats.newEnvironmentName = if ($existingEnv.DisplayName) { $existingEnv.DisplayName } else { "Environment-$targetEnvironmentId" }
        
    } else {
        # Crear nuevo environment
        Write-Output "Creando nuevo environment: $NewEnvironmentName ($NewEnvironmentRegion)"
        
        try {
            $newEnvParams = @{
                DisplayName = $NewEnvironmentName
                EnvironmentSku = $NewEnvironmentType
                LocationName = $NewEnvironmentRegion
                ProvisionDatabase = $true
            }
            
            $newEnvironment = New-AdminPowerAppEnvironment @newEnvParams -ErrorAction Stop
            
            if (-not $newEnvironment -or -not $newEnvironment.EnvironmentName) {
                throw "Environment creado pero sin ID válido"
            }
            
            $targetEnvironmentId = $newEnvironment.EnvironmentName
            Write-Output "    Environment creado: $targetEnvironmentId"
            
        } catch {
            Write-Output ""
            Write-Output "  ERROR: No se pudo crear el environment"
            Write-Output "  $($_.Exception.Message)"
            
            if ($_.Exception.Message -match "403|Forbidden|does not have permission") {
                Write-Output ""
                Write-Output "  SOLUCIÓN: Crear environment manualmente"
                Write-Output "    1. https://admin.powerplatform.microsoft.com → Environments → + New"
                Write-Output "    2. Configurar: Name=$NewEnvironmentName, Region=$NewEnvironmentRegion, Dataverse=YES"
                Write-Output "    3. Copiar Environment ID y re-ejecutar con: -ExistingEnvironmentId '<GUID>'"
                Write-Output ""
                Write-Output "  CAUSAS: Service Principal requiere roles Azure AD (Power Platform Administrator)"
                Write-Output "          y permisos API en App Registration (Dynamics CRM, PowerApps Service)"
            } else {
                Write-Output "  Causas posibles: Región inválida, nombre duplicado, límite alcanzado"
            }
            
            throw
        }
        
        # Esperar provisionamiento de Dataverse
        Write-Output "  Esperando provisionamiento de Dataverse..."
        
        $maxWaitMinutes = 20
        $waitSeconds = 0
        $provisioningComplete = $false
        
        while ($waitSeconds -lt ($maxWaitMinutes * 60) -and -not $provisioningComplete) {
            Start-Sleep -Seconds 30
            $waitSeconds += 30
            
            $checkEnv = Get-AdminPowerAppEnvironment -EnvironmentName $targetEnvironmentId
            
            if ($checkEnv.Internal.properties.linkedEnvironmentMetadata.instanceUrl) {
                $provisioningComplete = $true
                Write-Output "  Dataverse listo ($([math]::Round($waitSeconds/60, 1)) min)"
            } else {
                Write-Output "    ... $([math]::Round($waitSeconds/60, 1)) min"
            }
        }
        
        if (-not $provisioningComplete) {
            Write-Output ""
            Write-Output "  TIMEOUT: Dataverse aún provisionando después de $maxWaitMinutes min"
            Write-Output "  Environment ID: $targetEnvironmentId"
            Write-Output ""
            Write-Output "  Para continuar cuando esté listo, ejecutar:"
            Write-Output "    .\Restore-PowerPlatform.ps1 -BackupFileName '$BackupFileName' \"
            Write-Output "      -RestoreMode 'NewEnvironment' -ExistingEnvironmentId '$targetEnvironmentId'"
            Write-Output ""
            
            Write-DetailedLog "Timeout waiting for Dataverse. Environment: $targetEnvironmentId" "WARNING"
            throw "Timeout esperando Dataverse. Usa -ExistingEnvironmentId '$targetEnvironmentId' para continuar."
        }
        
        $script:restoreStats.newEnvironmentCreated = $true
        $script:restoreStats.newEnvironmentId = $targetEnvironmentId
        $script:restoreStats.newEnvironmentName = $NewEnvironmentName
        
        Write-DetailedLog "New environment created: $targetEnvironmentId ($NewEnvironmentName)" "INFO"
        
        # Agregar Service Principal
        Write-Output ""
        Write-Output "  Configurando permisos del Service Principal..."
        
        $appUserAdded = Add-ServicePrincipalToEnvironment `
            -EnvironmentId $targetEnvironmentId `
            -AppId $appId `
            -TenantId $tenantId `
            -ClientSecret $clientSecret
        
        if (-not $appUserAdded) {
            Write-Output ""
            Write-Output "    No se pudo agregar Service Principal automáticamente"
            Write-Output "    1. https://admin.powerplatform.microsoft.com → $targetEnvironmentId"
            Write-Output "    2. Settings → Application users → + New app user"
            Write-Output "    3. Buscar AppId: $appId → Role: System Administrator"
            Write-Output ""
            
            if (-not $Force) {
                throw "Service Principal sin permisos. Configura manualmente y re-ejecuta con -ExistingEnvironmentId '$targetEnvironmentId'"
            } else {
                Write-Output "    -Force detectado, continuando (puede fallar con error 403)"
            }
        } else {
            Write-Output "    Service Principal configurado"
        }
    }
    
    # Obtener Dataverse URL
    $dataverseUrl = Get-DataverseUrl -EnvironmentId $targetEnvironmentId -TenantId $tenantId -AppId $appId -ClientSecret $clientSecret
    
    Write-Output ""
    Write-Output "Environment configurado:"
    Write-Output "  ID: $targetEnvironmentId"
    Write-Output "  Nombre: $($script:restoreStats.newEnvironmentName)"
    Write-Output "  URL: $dataverseUrl"
    
    if ([string]::IsNullOrWhiteSpace($dataverseUrl)) {
        throw "No se pudo determinar la URL de Dataverse para: $targetEnvironmentId"
    }
    
    # Obtener token de acceso
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
    
    $script:tokenObtainedAt = Get-Date
    $script:tokenLifetimeSeconds = 7200
    $script:tokenRefreshThresholdSeconds = 3000
    
    Write-Output "    Token obtenido (válido 2h)"
    
    Write-DetailedLog "Dataverse access configured" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "Error configurando acceso a Dataverse"
    Write-ErrorDetail $_ "DataverseAccess"
    throw
}

# ==========================================
# FUNCIÓN: VERIFICAR Y REFRESCAR TOKEN
# ==========================================

function Test-AndRefreshToken {
    <#
    .SYNOPSIS
    Verifica si el token está próximo a expirar y lo refresca automáticamente
    
    .DESCRIPTION
    Los tokens de Azure AD tienen un lifetime de 2 horas. Esta función verifica
    el tiempo transcurrido desde la última obtención del token y lo refresca
    automáticamente cuando han pasado más de 1 hora (50% del lifetime).
    
    .PARAMETER DataverseUrl
    URL base del Dataverse para el scope del token
    
    .EXAMPLE
    Test-AndRefreshToken -DataverseUrl $dataverseUrl
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DataverseUrl
    )
    
    $elapsedSeconds = ((Get-Date) - $script:tokenObtainedAt).TotalSeconds
    $elapsedMinutes = [Math]::Floor($elapsedSeconds / 60)
    
    # Verificar si necesitamos refrescar (después de 50 minutos = 3000 segundos)
    # Token expira a las 2 horas, refrescamos a los 50 min para tener margen
    if ($elapsedSeconds -gt 3000) {
        Write-Output "        TOKEN PRÓXIMO A EXPIRAR ($elapsedMinutes min)"
        Write-Output "        Renovando token de autenticación..."
        
        try {
            # Re-autenticar con Dataverse (usar variables correctas)
            # Obtener tenant ID y credenciales del script scope (ya se leyeron en PASO 1)
            $refreshTenantId = $script:tenantId
            $refreshAppId = $script:appId
            $refreshClientSecret = $script:clientSecret
            
            # Si no están en script scope, intentar leerlas de nuevo
            if ([string]::IsNullOrEmpty($refreshTenantId)) {
                $refreshTenantId = Get-AutomationVariable -Name 'PP-ServicePrincipal-TenantId'
            }
            if ([string]::IsNullOrEmpty($refreshAppId) -or [string]::IsNullOrEmpty($refreshClientSecret)) {
                $spCredential = Get-AutomationPSCredential -Name "PP-ServicePrincipal"
                $refreshAppId = $spCredential.UserName
                $refreshClientSecret = $spCredential.GetNetworkCredential().Password
            }
            
            $tokenBody = @{
                client_id = $refreshAppId
                client_secret = $refreshClientSecret
                scope = "$DataverseUrl/.default"
                grant_type = "client_credentials"
            }
            
            $tokenUrl = "https://login.microsoftonline.com/$refreshTenantId/oauth2/v2.0/token"
            $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
            
            # Actualizar header con nuevo token
            $script:headers["Authorization"] = "Bearer $($tokenResponse.access_token)"
            
            # Actualizar tiempo de obtención
            $script:tokenObtainedAt = Get-Date
            
            Write-Output "     Token renovado exitosamente"
            Write-Output "   Válido por otras 2 horas"
            Write-Output ""
            
            Write-DetailedLog "Token refreshed successfully after $elapsedMinutes minutes" "INFO"
            
        } catch {
            Write-Output "     ERROR al renovar token"
            Write-ErrorDetail $_ "TokenRefresh"
            throw "No se pudo renovar el token - la ejecución debe abortarse"
        }
    }
}

# ==========================================
# FUNCIÓN: Invoke-DataverseBatchRequest
# ==========================================

function Invoke-DataverseBatchRequest {
    <#
    .SYNOPSIS
    Ejecuta múltiples operaciones CREATE en Dataverse usando Batch API
    
    .DESCRIPTION
    Agrupa múltiples operaciones POST en un solo batch request para reducir
    latencia de red y mejorar throughput. Procesa hasta 100 registros por batch
    (límite recomendado para balance entre performance y confiabilidad).
    
    Formato: multipart/mixed según especificación OData Batch
    https://docs.microsoft.com/en-us/power-apps/developer/data-platform/webapi/execute-batch-operations-using-web-api
    
    .PARAMETER DataverseUrl
    URL base del Dataverse (ej: https://org123.crm2.dynamics.com)
    
    .PARAMETER Headers
    Hashtable con headers HTTP (debe incluir Authorization Bearer token)
    
    .PARAMETER EntitySetName
    Nombre del entity set en la API (ej: contacts, accounts)
    
    .PARAMETER Records
    Array de hashtables con los datos de cada registro a crear
    
    .PARAMETER BatchSize
    Número máximo de operaciones por batch (default: 100, máximo seguro: 1000)
    
    .PARAMETER ContinueOnError
    Si es $true, el batch continúa aunque algunos registros fallen (default: $true)
    Si es $false, el batch completo falla si cualquier operación falla
    
    .EXAMPLE
    $result = Invoke-DataverseBatchRequest `
        -DataverseUrl "https://org123.crm2.dynamics.com" `
        -Headers $headers `
        -EntitySetName "contacts" `
        -Records $recordsArray `
        -BatchSize 100
    
    .OUTPUTS
    Hashtable con:
    - Total: número total de registros procesados
    - Success: número de registros creados exitosamente
    - Errors: número de registros con errores
    - ErrorDetails: array con detalles de errores (máximo 5)
    #>
    
    param(
        [Parameter(Mandatory=$true)]
        [string]$DataverseUrl,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true)]
        [string]$EntitySetName,
        
        [Parameter(Mandatory=$true)]
        [array]$Records,
        
        [Parameter(Mandatory=$false)]
        [int]$BatchSize = 100,
        
        [Parameter(Mandatory=$false)]
        [bool]$ContinueOnError = $true
    )
    
    # Validar parámetros
    if ($Records.Count -eq 0) {
        return @{
            Total = 0
            Success = 0
            Errors = 0
            ErrorDetails = @()
        }
    }
    
    # Limitar batch size a 1000 (límite hard de Dataverse)
    if ($BatchSize -gt 1000) {
        $BatchSize = 1000
    }
    
    $results = @{
        Total = $Records.Count
        Success = 0
        Errors = 0
        ErrorDetails = @()
    }
    
    # Procesar en batches
    $batchCount = [Math]::Ceiling($Records.Count / $BatchSize)
    
    for ($batchIndex = 0; $batchIndex -lt $batchCount; $batchIndex++) {
        $startIdx = $batchIndex * $BatchSize
        $endIdx = [Math]::Min(($batchIndex + 1) * $BatchSize - 1, $Records.Count - 1)
        $currentBatch = $Records[$startIdx..$endIdx]
        
        # Generar IDs únicos para batch y changeset
        $batchId = "batch_" + [Guid]::NewGuid().ToString()
        $changesetId = "changeset_" + [Guid]::NewGuid().ToString()
        
        # Construir body del batch request (formato multipart/mixed)
        $batchBody = "--$batchId`r`n"
        $batchBody += "Content-Type: multipart/mixed; boundary=$changesetId`r`n`r`n"
        
        # Agregar cada operación al changeset
        $contentId = 1
        foreach ($record in $currentBatch) {
            $recordJson = $record | ConvertTo-Json -Depth 10 -Compress
            
            $batchBody += "--$changesetId`r`n"
            $batchBody += "Content-Type: application/http`r`n"
            $batchBody += "Content-Transfer-Encoding: binary`r`n"
            $batchBody += "Content-ID: $contentId`r`n`r`n"
            
            $batchBody += "POST $DataverseUrl/api/data/v9.2/$EntitySetName HTTP/1.1`r`n"
            $batchBody += "Content-Type: application/json`r`n`r`n"
            $batchBody += "$recordJson`r`n"
            
            $contentId++
        }
        
        # Cerrar changeset y batch
        $batchBody += "--$changesetId--`r`n"
        $batchBody += "--$batchId--"
        
        # Ejecutar batch request
        try {
            # Preparar headers específicos para batch
            $batchHeaders = $Headers.Clone()
            $batchHeaders["Content-Type"] = "multipart/mixed; boundary=$batchId"
            $batchHeaders["OData-Version"] = "4.0"
            $batchHeaders["OData-MaxVersion"] = "4.0"
            
            # Agregar header para continuar en error si está configurado
            if ($ContinueOnError) {
                $batchHeaders["Prefer"] = "odata.continue-on-error"
            }
            
            # Ejecutar request
            $response = Invoke-RestMethod `
                -Uri "$DataverseUrl/api/data/v9.2/`$batch" `
                -Method Post `
                -Headers $batchHeaders `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($batchBody)) `
                -ContentType "multipart/mixed; boundary=$batchId"
            
            # Parsear respuesta multipart
            # Contar respuestas exitosas (HTTP 2xx)
            $responseText = $response | Out-String
            $successMatches = [regex]::Matches($responseText, "HTTP/1\.\d+ (20[0-9]|201|204)")
            $successCount = $successMatches.Count
            
            # Contar errores (HTTP 4xx/5xx)
            $errorMatches = [regex]::Matches($responseText, "HTTP/1\.\d+ ([45][0-9]{2})")
            $errorCount = $errorMatches.Count
            
            # Si no pudimos parsear, asumir que todos fueron exitosos
            if ($successCount -eq 0 -and $errorCount -eq 0) {
                $successCount = $currentBatch.Count
            }
            
            $results.Success += $successCount
            $results.Errors += $errorCount
            
            # Capturar mensajes de error (máximo 5 para no saturar logs)
            if ($errorCount -gt 0 -and $results.ErrorDetails.Count -lt 5) {
                $errorDetailMatches = [regex]::Matches($responseText, '"message":\s*"([^"]+)"')
                foreach ($match in $errorDetailMatches) {
                    if ($results.ErrorDetails.Count -lt 5) {
                        $results.ErrorDetails += $match.Groups[1].Value
                    }
                }
            }
            
        } catch {
            # Si el batch completo falló
            $results.Errors += $currentBatch.Count
            
            if ($results.ErrorDetails.Count -lt 5) {
                $errorMsg = "Batch $($batchIndex + 1)/$batchCount falló: $($_.Exception.Message)"
                $results.ErrorDetails += $errorMsg
            }
        }
    }
    
    return $results
}

# ==========================================
# FUNCIÓN: Restore-FileAttachments
# ==========================================

function Restore-FileAttachments {
    <#
    .SYNOPSIS
    Restaura registros de fileattachment usando la API especial de File Upload
    
    .DESCRIPTION
    La tabla fileattachment NO soporta CREATE directo via Web API.
    Requiere usar InitializeFileBlocksUploadRequest + UploadBlockRequest + CommitFileBlocksUploadRequest
    
    Esta función implementa el flujo completo:
    1. InitializeFileBlocksUpload - Obtener upload token
    2. UploadBlock - Subir contenido en chunks
    3. CommitFileBlocksUpload - Finalizar y crear registro
    
    .PARAMETER DataverseUrl
    URL del Dataverse
    
    .PARAMETER Headers
    Headers de autenticación
    
    .PARAMETER Records
    Array de registros de fileattachment a restaurar
    
    .OUTPUTS
    Hashtable con estadísticas: Total, Success, Errors, ErrorDetails
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$DataverseUrl,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$Headers,
        
        [Parameter(Mandatory=$true)]
        [array]$Records
    )
    
    $result = @{
        Total = $Records.Count
        Success = 0
        Errors = 0
        ErrorDetails = @()
    }
    
    Write-Verbose "Restaurando $($Records.Count) file attachments usando File Upload API..."
    
    foreach ($record in $Records) {
        try {
            # PASO 1: Extraer metadatos del registro
            $fileName = $record.filename
            $mimeType = if ($record.mimetype) { $record.mimetype } else { "application/octet-stream" }
            $fileSize = if ($record.filesize) { $record.filesize } else { 0 }
            $body = $record.body  # Base64 encoded content
            $regardingObjectId = $record.'regardingobjectid@odata.bind'
            
            # Validar campos requeridos
            if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($body)) {
                throw "Registro inválido: falta filename o body"
            }
            
            # PASO 2: Initialize File Blocks Upload
            $initializeUrl = "$DataverseUrl/api/data/v9.2/InitializeFileBlocksUpload"
            $initializeBody = @{
                Target = @{
                    "@odata.type" = "Microsoft.Dynamics.CRM.fileattachment"
                    filename = $fileName
                }
            } | ConvertTo-Json -Depth 5
            
            $initResponse = Invoke-RestMethod -Uri $initializeUrl -Method Post -Headers $Headers -Body $initializeBody -ContentType "application/json"
            $fileBlockId = $initResponse.FileContinuationToken
            
            # PASO 3: Upload Block (contenido en base64)
            $uploadUrl = "$DataverseUrl/api/data/v9.2/UploadBlock"
            $uploadBody = @{
                BlockId = $fileBlockId
                BlockData = $body  # Ya viene en base64 del backup
            } | ConvertTo-Json -Depth 5
            
            Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $Headers -Body $uploadBody -ContentType "application/json" | Out-Null
            
            # PASO 4: Commit File Blocks Upload (crear registro final)
            $commitUrl = "$DataverseUrl/api/data/v9.2/CommitFileBlocksUpload"
            $commitBody = @{
                Target = @{
                    "@odata.type" = "Microsoft.Dynamics.CRM.fileattachment"
                    fileattachmentid = [guid]::NewGuid().ToString()
                    filename = $fileName
                    mimetype = $mimeType
                    filesize = $fileSize
                }
                BlockList = @($fileBlockId)
                FileContinuationToken = $fileBlockId
            }
            
            # Agregar regarding object si existe
            if (-not [string]::IsNullOrWhiteSpace($regardingObjectId)) {
                $commitBody.Target['regardingobjectid@odata.bind'] = $regardingObjectId
            }
            
            $commitBodyJson = $commitBody | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri $commitUrl -Method Post -Headers $Headers -Body $commitBodyJson -ContentType "application/json" | Out-Null
            
            $result.Success++
            
        } catch {
            $result.Errors++
            $errorMsg = $_.Exception.Message
            $result.ErrorDetails += "File: $fileName - Error: $errorMsg"
            
            # Limitar detalles a primeros 10 errores
            if ($result.ErrorDetails.Count -le 10) {
                Write-Verbose "Error restaurando $fileName : $errorMsg"
            }
        }
    }
    
    return $result
}

# ==========================================
# PASO 5: RESUMEN Y CONFIRMACIÓN

if (-not $Force) {
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "PASO 5: RESUMEN Y CONFIRMACIÓN"
    Write-Output "=========================================="
    
    Write-Output ""
    Write-Output "Backup: $BackupFileName"
    Write-Output "Modo: NewEnvironment"
    
    if (-not [string]::IsNullOrWhiteSpace($ExistingEnvironmentId)) {
        Write-Output "Environment: $ExistingEnvironmentId ($($script:restoreStats.newEnvironmentName))"
    } else {
        Write-Output "Crear environment: $NewEnvironmentName ($NewEnvironmentRegion)"
    }
    
    Write-Output ""
    Write-Output "Se restaurará:"
    Write-Output "  - Soluciones completas"
    Write-Output "  - Datos de tablas Dataverse"
    Write-Output ""
    
    try {
        $confirmation = Read-Host "¿Continuar? (y/n)"
        if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
            Write-Output "Restore cancelado"
            exit 0
        }
    } catch {
        Write-Output "Confirmación omitida (Azure Automation)"
    }
}

# PASO 6: VERIFICAR Y CREAR PUBLISHERS

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 6: VERIFICAR PUBLISHERS"
Write-Output "=========================================="

try {
    $solutionFiles = Get-ChildItem -Path $extractPath -Filter "*.zip" -Recurse | Where-Object {
        $_.Name -notlike "PowerPlatform_Backup*"
    }
    
    if ($solutionFiles.Count -eq 0) {
        Write-Output "  No se encontraron soluciones - saltando verificación de publishers"
    } else {
        Write-Output "  Analizando publishers en $($solutionFiles.Count) soluciones..."
        
        # Cargar assembly para leer ZIPs
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        $publishersToCreate = @{}
        
        foreach ($solFile in $solutionFiles) {
            try {
                # Abrir ZIP y leer solution.xml
                $zip = [System.IO.Compression.ZipFile]::OpenRead($solFile.FullName)
                $solutionEntry = $zip.Entries | Where-Object { $_.Name -eq "solution.xml" }
                
                if ($solutionEntry) {
                    $stream = $solutionEntry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $solutionXmlContent = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                    
                    # Parse XML
                    [xml]$solutionXml = $solutionXmlContent
                    
                    # Extraer info del publisher
                    $publisherNode = $solutionXml.ImportExportXml.SolutionManifest.Publisher
                    if ($publisherNode) {
                        $publisherUniqueName = $publisherNode.UniqueName
                        $publisherFriendlyName = $publisherNode.LocalizedNames.LocalizedName[0].description
                        $customizationPrefix = $publisherNode.CustomizationPrefix
                        $optionValuePrefix = $publisherNode.CustomizationOptionValuePrefix
                        
                        # Agregar a lista si no existe ya
                        if (-not $publishersToCreate.ContainsKey($publisherUniqueName)) {
                            $publishersToCreate[$publisherUniqueName] = @{
                                UniqueName = $publisherUniqueName
                                FriendlyName = $publisherFriendlyName
                                Prefix = $customizationPrefix
                                OptionValuePrefix = $optionValuePrefix
                            }
                        }
                    }
                }
                
                $zip.Dispose()
            } catch {
                Write-Output "     No se pudo leer publisher de $($solFile.Name): $($_.Exception.Message)"
            }
        }
        
        if ($publishersToCreate.Count -eq 0) {
            Write-Output "  No se encontraron publishers para crear"
        } else {
            Write-Output ""
            Write-Output "  Publishers únicos encontrados: $($publishersToCreate.Count)"
            foreach ($pub in $publishersToCreate.Values) {
                Write-Output "    • $($pub.FriendlyName) ($($pub.UniqueName)) - Prefix: $($pub.Prefix)"
            }
            Write-Output ""
            
            # Verificar cuáles publishers ya existen en el environment
            Write-Output "  Verificando publishers existentes en el environment..."
            
            foreach ($pub in $publishersToCreate.Values) {
                try {
                    # Verificar si el publisher existe
                    $publisherCheckUrl = "$dataverseUrl/api/data/v9.2/publishers?`$filter=uniquename eq '$($pub.UniqueName)'&`$select=publisherid,uniquename,friendlyname"
                    $existingPublisher = Invoke-RestMethod -Uri $publisherCheckUrl -Method Get -Headers $script:headers
                    
                    if ($existingPublisher.value.Count -gt 0) {
                        Write-Output "      Publisher '$($pub.UniqueName)' ya existe"
                    } else {
                        # Crear publisher
                        Write-Output "      Creando publisher '$($pub.UniqueName)'..."
                        
                        $publisherData = @{
                            uniquename = $pub.UniqueName
                            friendlyname = $pub.FriendlyName
                            customizationprefix = $pub.Prefix
                            customizationoptionvalueprefix = [int]$pub.OptionValuePrefix
                        }
                        
                        $publisherJson = $publisherData | ConvertTo-Json -Depth 10
                        $createPublisherUrl = "$dataverseUrl/api/data/v9.2/publishers"
                        
                        $createResponse = Invoke-RestMethod -Uri $createPublisherUrl -Method Post -Headers $script:headers -Body $publisherJson
                        
                        Write-Output "         Publisher creado exitosamente"
                    }
                } catch {
                    Write-Output "       Error verificando/creando publisher '$($pub.UniqueName)': $($_.Exception.Message)"
                    # No abortar - continuar con otros publishers
                }
            }
        }
    }
    
    Write-Output ""
    Write-Output "    Verificación de publishers completada"
    
} catch {
    Write-Output ""
    Write-Output "     Error en verificación de publishers:"
    Write-Output "     $($_.Exception.Message)"
    Write-Output "  Continuando con importación de soluciones..."
}

# PASO 7: IMPORTAR SOLUCIONES

Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 7: IMPORTAR SOLUCIONES"
Write-Output "=========================================="

try {
    $solutionFiles = Get-ChildItem -Path $extractPath -Filter "*.zip" -Recurse | Where-Object {
        $_.Name -notlike "PowerPlatform_Backup*"
    }
    
    if ($solutionFiles.Count -eq 0) {
        throw "No se encontraron soluciones en el backup"
    }
    
    Write-Output "Soluciones encontradas: $($solutionFiles.Count)"
    
    # Filtrar soluciones del sistema
    $systemSolutions = @("Cr61a87", "Default", "Active", "Basic", "DefaultSolution", "msdyn_", "mspp_", "System")
    
    $validSolutionFiles = $solutionFiles | Where-Object {
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        $isSystemSolution = $false
        
        foreach ($sysSol in $systemSolutions) {
            if ($fileName -eq $sysSol -or $fileName -like "$sysSol*") {
                $isSystemSolution = $true
                break
            }
        }
        
        -not $isSystemSolution
    }
    
    if ($validSolutionFiles.Count -eq 0) {
        throw "No se encontraron soluciones custom válidas"
    }
    
    Write-Output "Soluciones custom: $($validSolutionFiles.Count)"
    
    # Filtrar soluciones independientes (sin sufijos)
    $independentSolutions = $validSolutionFiles | Where-Object {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        $name -notlike "*_Restored_*" -and 
        $name -notlike "*clone*" -and 
        $name -notlike "*copy*"
    }
    
    Write-Output "Soluciones a importar: $($independentSolutions.Count)"
    
    if ($independentSolutions.Count -gt 0) {
        Write-Output ""
        Write-Output "Analizando soluciones..."
        
        $dataverseDataPath = Join-Path $extractPath "dataverse"
        $dataFiles = @()
        if (Test-Path $dataverseDataPath) {
            $dataFiles = Get-ChildItem -Path $dataverseDataPath -Filter "*.json" -File
        }
        
        $solutionInfo = @()
        $solutionComponents = @{}
        
        foreach ($sol in $independentSolutions) {
            $solName = [System.IO.Path]::GetFileNameWithoutExtension($sol.Name)
            $customTableCount = 0
            $totalDataSize = 0
            $prefix = ""
            $solutionUniqueName = ""
            $rootComponents = @()
            $requiredComponents = @()
            
            # Leer metadata de la solución
            $solZipPath = $sol.FullName
            try {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $zip = [System.IO.Compression.ZipFile]::OpenRead($solZipPath)
                $solutionXmlEntry = $zip.Entries | Where-Object { $_.Name -eq 'solution.xml' } | Select-Object -First 1
                
                if ($solutionXmlEntry) {
                    $stream = $solutionXmlEntry.Open()
                    $reader = [System.IO.StreamReader]::new($stream)
                    $xmlContent = $reader.ReadToEnd()
                    $reader.Close()
                    $stream.Close()
                    
                    if ($xmlContent -match '<UniqueName>([^<]+)</UniqueName>') {
                        $solutionUniqueName = $matches[1]
                    }
                    
                    # Extraer CustomizationPrefix con regex
                    if ($xmlContent -match '<CustomizationPrefix>([^<]+)</CustomizationPrefix>') {
                        $prefix = $matches[1]
                    }
                    
                    # Extraer RootComponents (lo que esta solución PROVEE)
                    # Formato: <RootComponent type="66" schemaName="cr8df_BeverControls.ScheduleBoardView" behavior="0" />
                    # Nota: Los atributos pueden estar en cualquier orden
                    $rootComponentLines = [regex]::Matches($xmlContent, '<RootComponent[^>]+/>')
                    foreach ($componentMatch in $rootComponentLines) {
                        $componentTag = $componentMatch.Value
                        
                        # Extraer schemaName y type independientemente del orden
                        $schemaName = ""
                        $componentType = ""
                        
                        if ($componentTag -match 'schemaName="([^"]+)"') {
                            $schemaName = $matches[1]
                        }
                        if ($componentTag -match 'type="([^"]+)"') {
                            $componentType = $matches[1]
                        }
                        
                        if ($schemaName) {
                            $rootComponents += @{
                                SchemaName = $schemaName
                                Type = $componentType
                            }
                        }
                    }
                    
                    # Extraer Required components (lo que esta solución NECESITA)
                    # Formato: <Required type="66" schemaName="cr8df_BeverControls.ScheduleBoardView" ... solution="Active" />
                    # Los atributos pueden estar en cualquier orden
                    $requiredLines = [regex]::Matches($xmlContent, '<Required[^>]+/>')
                    foreach ($reqMatch in $requiredLines) {
                        $reqTag = $reqMatch.Value
                        
                        # Extraer atributos independientemente del orden
                        $schemaName = ""
                        $componentType = ""
                        $sourceSolution = ""
                        
                        if ($reqTag -match 'schemaName="([^"]+)"') {
                            $schemaName = $matches[1]
                        }
                        if ($reqTag -match 'type="([^"]+)"') {
                            $componentType = $matches[1]
                        }
                        if ($reqTag -match 'solution="([^"]+)"') {
                            $sourceSolution = $matches[1]
                        }
                        
                        # Filtrar componentes del sistema (Microsoft)
                        if ($schemaName -and 
                            -not $schemaName.StartsWith("msdyn_") -and
                            -not $schemaName.StartsWith("mspp_") -and
                            -not $schemaName.StartsWith("Microsoft.") -and
                            -not $schemaName.Contains("/Images/") -and
                            $sourceSolution -ne "System") {
                            
                            $requiredComponents += @{
                                SchemaName = $schemaName
                                Type = $componentType
                                SourceSolution = $sourceSolution
                            }
                        }
                    }
                }
                $zip.Dispose()
            } catch {
                Write-Output "         Error leyendo metadata de $solName : $($_.Exception.Message)"
            }
            
            # Contar tablas custom que usan este prefix
            foreach ($dataFile in $dataFiles) {
                $tableName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
                
                if ($dataFile.Length -gt 100) {
                    $totalDataSize += $dataFile.Length
                    
                    if (-not [string]::IsNullOrWhiteSpace($prefix) -and $tableName.StartsWith("${prefix}_")) {
                        $customTableCount++
                    }
                }
            }
            
            $zipSizeKB = [math]::Round($sol.Length / 1024, 2)
            
            $solutionInfo += [PSCustomObject]@{
                File = $sol
                Name = $solName
                UniqueName = $solutionUniqueName
                Prefix = $prefix
                CustomTables = $customTableCount
                DataSizeMB = [math]::Round($totalDataSize / 1MB, 2)
                ZipSizeKB = $zipSizeKB
                RootComponents = $rootComponents
                RequiredComponents = $requiredComponents
                DependsOn = @()  # Se llenará en el siguiente paso
            }
            
            # Guardar RootComponents indexados por UniqueName
            if ($solutionUniqueName) {
                $solutionComponents[$solutionUniqueName] = $rootComponents
            }
            
            # Debug: Mostrar componentes extraídos
            if ($rootComponents.Count -gt 0) {
                Write-Output "      DEBUG: $solName provee $($rootComponents.Count) componentes"
            }
            if ($requiredComponents.Count -gt 0) {
                Write-Output "      DEBUG: $solName requiere $($requiredComponents.Count) componentes"
            }
        }
        
        # PASO 1B: Segunda pasada - Determinar dependencias por análisis de componentes
        Write-Output "    [Fase 2/3] Analizando dependencias entre soluciones..."
        
        foreach ($sol in $solutionInfo) {
            $dependsOnSolutions = @()
            
            # Debug: Mostrar lo que esta solución requiere
            if ($sol.RequiredComponents.Count -gt 0) {
                Write-Output "      DEBUG: $($sol.Name) busca dependencias para $($sol.RequiredComponents.Count) componentes requeridos"
            }
            
            # Para cada componente que esta solución REQUIERE
            foreach ($requiredComp in $sol.RequiredComponents) {
                $requiredSchemaName = $requiredComp.SchemaName
                
                # Buscar qué solución PROVEE este componente
                foreach ($otherSol in $solutionInfo) {
                    # No puede depender de sí misma
                    if ($otherSol.UniqueName -eq $sol.UniqueName) {
                        continue
                    }
                    
                    # Verificar si esta otra solución provee el componente requerido
                    $providesComponent = $false
                    foreach ($rootComp in $otherSol.RootComponents) {
                        if ($rootComp.SchemaName -eq $requiredSchemaName) {
                            $providesComponent = $true
                            Write-Output "          Encontrado: '$requiredSchemaName' provisto por $($otherSol.Name)"
                            break
                        }
                    }
                    
                    if ($providesComponent) {
                        # Encontramos la solución que provee este componente
                        if ($dependsOnSolutions -notcontains $otherSol.UniqueName) {
                            $dependsOnSolutions += $otherSol.UniqueName
                        }
                    }
                }
            }
            
            # Actualizar dependencias
            $sol.DependsOn = $dependsOnSolutions
            
            # Log de dependencias encontradas
            $depsStr = if ($dependsOnSolutions.Count -gt 0) { "→ Depende de: $($dependsOnSolutions -join ', ')" } else { "(sin dependencias)" }
            Write-Output "      • $($sol.Name): $($sol.CustomTables) tablas, $($sol.ZipSizeKB) KB - $depsStr"
        }
        
        Write-Output ""
        Write-Output "    Construyendo grafo de dependencias..."
        Write-Output "    [Fase 3/3] Ordenamiento topológico..."
        
        # PASO 2: Crear mapa de UniqueName → SolutionInfo
        $solutionMap = @{}
        foreach ($sol in $solutionInfo) {
            if ($sol.UniqueName) {
                $solutionMap[$sol.UniqueName] = $sol
            }
            # También indexar por Name (fileName) como fallback
            $solutionMap[$sol.Name] = $sol
        }
        
        # PASO 3: TOPOLOGICAL SORT - Ordenar por dependencias
        $orderedSolutions = @()
        $visited = @{}
        $visiting = @{}
        
        function Visit-Solution($sol) {
            if ($visited.ContainsKey($sol.Name)) {
                return
            }
            
            if ($visiting.ContainsKey($sol.Name)) {
                Write-Output "       Dependencia circular detectada en $($sol.Name)"
                return
            }
            
            $visiting[$sol.Name] = $true
            
            # Visitar dependencias primero (recursivo)
            foreach ($depName in $sol.DependsOn) {
                $depSolution = $solutionMap[$depName]
                if ($depSolution) {
                    Visit-Solution $depSolution
                }
            }
            
            $visiting.Remove($sol.Name)
            $visited[$sol.Name] = $true
            
            # Agregar al final (después de sus dependencias)
            $script:orderedSolutions += $sol
        }
        
        # Aplicar topological sort
        foreach ($sol in $solutionInfo) {
            Visit-Solution $sol
        }
        
        $solutionsToImport = $orderedSolutions
        
        Write-Output ""
        Write-Output "    ORDEN DE IMPORTACIÓN (respetando dependencias):"
        $importOrder = 1
        foreach ($sol in $solutionsToImport) {
            $depsInfo = if ($sol.DependsOn.Count -gt 0) { " (depende de: $($sol.DependsOn -join ', '))" } else { "" }
            Write-Output "    $importOrder. $($sol.Name)$depsInfo"
            $importOrder++
        }
        Write-Output "    Orden calculado mediante análisis de dependencias (topological sort)"
        
    } else {
        Write-Output "    No hay soluciones independientes para importar"
        Write-Output "     Solo se encontraron soluciones del sistema o con sufijos _Restored_/clone"
        throw "No hay soluciones válidas para importar"
    }
    
    if ($solutionsToImport.Count -eq 0) {
        throw "No se pudo determinar soluciones a importar"
    }
    
    Write-Output ""
    Write-Output "    Total de soluciones a importar: $($solutionsToImport.Count)"
    Write-Output ""
    
    # ==========================================
    # LOOP: IMPORTAR TODAS LAS SOLUCIONES
    # ==========================================
    
    $solutionImportResults = @()
    $currentSolutionIndex = 0
    
    foreach ($solutionToImport in $solutionsToImport) {
        $currentSolutionIndex++
        $solutionFile = $solutionToImport.File
        
        Write-Output ""
        Write-Output "=========================================="
        Write-Output "IMPORTANDO SOLUCIÓN $currentSolutionIndex de $($solutionsToImport.Count)"
        Write-Output "=========================================="
        Write-Output "Nombre: $($solutionToImport.Name)"
        Write-Output "Tamaño: $($solutionToImport.DataSizeMB) MB"
        Write-Output "Tablas custom: $($solutionToImport.CustomTables)"
        Write-Output "Prefix: $($solutionToImport.Prefix)"
        Write-Output ""
    
    # Leer metadata de la solución desde el backup
    $metadataPath = Join-Path $extractPath "solution_metadata.json"
    $solutionMetadata = $null
    $existingSolutionIsManaged = $null
    $solutionUniqueName = $null
    
    # Intentar leer desde solution_metadata.json primero
    if (Test-Path $metadataPath) {
        try {
            $metadataContent = Get-Content $metadataPath -Raw | ConvertFrom-Json
            $solutionUniqueName = $metadataContent.uniquename
            Write-Output "  Nombre único de solución (desde metadata): $solutionUniqueName"
        } catch {
            Write-Output "  No se pudo leer solution_metadata.json"
        }
    }
    
    # Si no hay metadata JSON, extraer del ZIP de la solución
    if ([string]::IsNullOrWhiteSpace($solutionUniqueName)) {
        Write-Output ""
        Write-Output "  Extrayendo metadata del ZIP de solución..."
        
        try {
            # Cargar el ZIP de la solución
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $solutionZip = [System.IO.Compression.ZipFile]::OpenRead($solutionFile.FullName)
            
            # Buscar solution.xml dentro del ZIP
            $solutionXmlEntry = $solutionZip.Entries | Where-Object { $_.Name -eq "solution.xml" } | Select-Object -First 1
            
            if ($solutionXmlEntry) {
                $stream = $solutionXmlEntry.Open()
                $reader = New-Object System.IO.StreamReader($stream)
                $solutionXmlContent = $reader.ReadToEnd()
                $reader.Close()
                $stream.Close()
                
                # Parsear XML para obtener UniqueName y metadata adicional
                [xml]$solutionXml = $solutionXmlContent
                $solutionUniqueName = $solutionXml.ImportExportXml.SolutionManifest.UniqueName
                
                Write-Output "  Nombre único extraído del ZIP: $solutionUniqueName"
                
                # LOG ADICIONAL: Verificar metadata que puede causar conflictos
                $solutionVersion = $solutionXml.ImportExportXml.SolutionManifest.Version
                $solutionManaged = $solutionXml.ImportExportXml.SolutionManifest.Managed
                $publisherPrefix = $solutionXml.ImportExportXml.SolutionManifest.Publisher.CustomizationPrefix
                
                Write-Output "  Versión: $solutionVersion"
                Write-Output "  Managed: $solutionManaged (0=Unmanaged, 1=Managed)"
                Write-Output "  Publisher Prefix: $publisherPrefix"
                
                # Advertencia si hay descripción de "clone" o "upgrade"
                $solutionDescription = $solutionXml.ImportExportXml.SolutionManifest.Descriptions.Description.description
                if ($solutionDescription -match "clone|upgrade|copy") {
                    Write-Output ""
                    Write-Output "  ⚠ ADVERTENCIA: La solución contiene metadata de clone/upgrade"
                    Write-Output "    Descripción: $solutionDescription"
                    Write-Output "    Esto puede causar conflictos al importar"
                    Write-Output ""
                }
            } else {
                Write-Output "  No se encontró solution.xml en el ZIP"
            }
            
            $solutionZip.Dispose()
            
        } catch {
            Write-Output "  Error extrayendo metadata del ZIP: $($_.Exception.Message)"
        }
    }
    
    # Verificar si la solución ya existe en el environment target
    if (-not [string]::IsNullOrWhiteSpace($solutionUniqueName)) {
        Write-Output ""
        Write-Output "  Verificando si la solución ya existe en el environment..."
        
        $checkUrl = "$dataverseUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$solutionUniqueName'`&`$select=solutionid,uniquename,friendlyname,ismanaged,version"
        
        try {
            $existingSolution = Invoke-RestMethod -Uri $checkUrl -Headers $script:headers -Method Get
            
            if ($existingSolution.value -and $existingSolution.value.Count -gt 0) {
                $existingSolutionIsManaged = $existingSolution.value[0].ismanaged
                $existingVersion = $existingSolution.value[0].version
                
                Write-Output "  Solución YA EXISTE en el environment"
                Write-Output "    Versión actual: $existingVersion"
                Write-Output "    Tipo actual: $(if ($existingSolutionIsManaged) { 'Managed (Administrada)' } else { 'Unmanaged (No administrada)' })"
                
                # LOG DETALLADO: Mostrar valor exacto de ismanaged
                Write-Output ""
                Write-Output "    DEBUG - Valor raw de ismanaged:"
                Write-Output "    Valor: '$existingSolutionIsManaged'"
                Write-Output "    Tipo: $($existingSolutionIsManaged.GetType().Name)"
                Write-Output "    Es `$true: $($existingSolutionIsManaged -eq $true)"
                Write-Output "    Es `$false: $($existingSolutionIsManaged -eq $false)"
            } else {
                Write-Output "  Solución NO existe - será nueva instalación"
            }
        } catch {
            Write-Output "  No se pudo verificar solución existente: $($_.Exception.Message)"
        }
    } else {
        Write-Output ""
        Write-Output "  No se pudo determinar el nombre de la solución"
        Write-Output "    La importación continuará sin verificación previa"
    }
    
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
            Write-Output "  -> Importando como nueva solución"
            $overwriteFlag = $false
        }
        "UpdateCurrent" {
            Write-Output ""
            Write-Output "  Modo: UpdateCurrent (DESTRUCTIVO)"
            Write-Output "  -> Sobrescribiendo solución existente"
            $overwriteFlag = $true
        }
        "CreateCopy" {
            Write-Output ""
            Write-Output "  Modo: CreateCopy (NO DESTRUCTIVO)"
            Write-Output "  -> Creando NUEVA solución con sufijo '_Restored'"
            Write-Output "  -> Solución original permanece intacta"
            $overwriteFlag = $false
            
            # PASO ESPECIAL: Modificar UniqueName de la solución para crear copia
            Write-Output ""
            Write-Output "  [CreateCopy] Preparando solución con nuevo UniqueName..."
            
            try {
                # 1. Crear directorio temporal para modificar ZIP
                $tempModifyPath = Join-Path $env:TEMP "ModifySolution_$(Get-Date -Format 'yyyyMMddHHmmss')"
                New-Item -ItemType Directory -Path $tempModifyPath -Force | Out-Null
                
                # 2. Extraer ZIP de solución
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($solutionFile.FullName, $tempModifyPath)
                
                # 3. Leer solution.xml
                $solutionXmlPath = Join-Path $tempModifyPath "solution.xml"
                [xml]$solutionXmlContent = Get-Content $solutionXmlPath
                
                # 4. Obtener UniqueName original
                $originalUniqueName = $solutionXmlContent.ImportExportXml.SolutionManifest.UniqueName
                Write-Output "    Original UniqueName: $originalUniqueName"
                
                # 5. Generar nuevo UniqueName con sufijo
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $newUniqueName = "${originalUniqueName}_Restored_${timestamp}"
                Write-Output "    Nuevo UniqueName: $newUniqueName"
                
                # 6. Modificar UniqueName en XML
                $solutionXmlContent.ImportExportXml.SolutionManifest.UniqueName = $newUniqueName
                
                # 7. Modificar LocalizedNames para reflejar que es una copia
                $localizedNames = $solutionXmlContent.ImportExportXml.SolutionManifest.LocalizedNames.LocalizedName
                if ($localizedNames) {
                    foreach ($localizedName in $localizedNames) {
                        $originalDisplayName = $localizedName.description
                        $localizedName.description = "$originalDisplayName (Restored $timestamp)"
                    }
                }
                
                # 8. Guardar solution.xml modificado
                $solutionXmlContent.Save($solutionXmlPath)
                Write-Output "    solution.xml modificado"
                
                # 9. Recomprimir como nuevo ZIP
                $modifiedZipPath = Join-Path $env:TEMP "${newUniqueName}.zip"
                if (Test-Path $modifiedZipPath) { Remove-Item $modifiedZipPath -Force }
                
                [System.IO.Compression.ZipFile]::CreateFromDirectory($tempModifyPath, $modifiedZipPath)
                Write-Output "    Solución reempaquetada: $modifiedZipPath"
                
                # 10. Actualizar referencia al archivo de solución
                $solutionFile = Get-Item $modifiedZipPath
                
                # 11. Actualizar UniqueName global para uso posterior
                $solutionUniqueName = $newUniqueName
                
                # 12. Limpiar directorio temporal de extracción
                Remove-Item $tempModifyPath -Recurse -Force
                
                Write-Output "    Solución preparada para importar como NUEVA"
                
            } catch {
                $errorMsg = "Error modificando solución para CreateCopy: $($_.Exception.Message)"
                Write-Output "    $errorMsg"
                Write-ErrorDetail $_ "ModifySolutionForCopy"
                throw "No se pudo preparar solución para CreateCopy: $errorMsg"
            }
        }
    }
    
    
    # VALIDACIÓN: Verificar integridad del ZIP antes de importar
    Write-Output ""
    Write-Output "  Validando integridad del archivo ZIP..."
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $testZip = [System.IO.Compression.ZipFile]::OpenRead($solutionFile.FullName)
        $entriesCount = $testZip.Entries.Count
        $hasFormulas = ($testZip.Entries | Where-Object { $_.FullName -like "Formulas/*" }).Count -gt 0
        $testZip.Dispose()
        
        Write-Output "    ZIP válido: $entriesCount archivos"
        
        # Verificar archivos críticos
        $testZip2 = [System.IO.Compression.ZipFile]::OpenRead($solutionFile.FullName)
        $hasSolutionXml = $testZip2.Entries | Where-Object { $_.Name -eq "solution.xml" }
        $hasCustomizationsXml = $testZip2.Entries | Where-Object { $_.Name -eq "customizations.xml" }
        $testZip2.Dispose()
        
        if (-not $hasSolutionXml) {
            throw "ZIP no contiene solution.xml (requerido)"
        }
        if (-not $hasCustomizationsXml) {
            throw "ZIP no contiene customizations.xml (requerido)"
        }
        
        Write-Output "    Archivos críticos presentes: solution.xml, customizations.xml"
        
        # WORKAROUND AUTOMÁTICO: Eliminar fórmulas para evitar error 0x80040216
        if ($hasFormulas) {
            Write-Output ""
            Write-Output "  ⚠ Detectadas Formula columns en la solución"
            Write-Output "    Las fórmulas pueden causar error 0x80040216 al importar"
            Write-Output "    Aplicando workaround automático..."
            Write-Output ""
            
            try {
                # Crear directorio temporal para modificar el ZIP
                $tempModifyDir = Join-Path $env:TEMP "SolutionFix_$([guid]::NewGuid())"
                New-Item -ItemType Directory -Path $tempModifyDir -Force | Out-Null
                
                # Extraer solución completa
                [System.IO.Compression.ZipFile]::ExtractToDirectory($solutionFile.FullName, $tempModifyDir)
                
                # 1. Eliminar carpeta Formulas/ si existe
                $formulasPath = Join-Path $tempModifyDir "Formulas"
                if (Test-Path $formulasPath) {
                    $formulasCount = (Get-ChildItem $formulasPath -File).Count
                    Remove-Item $formulasPath -Recurse -Force
                    Write-Output "    ✓ Eliminados $formulasCount archivos de fórmulas"
                }
                
                # 2. Limpiar customizations.xml para eliminar referencias a fórmulas
                $customizationsXmlPath = Join-Path $tempModifyDir "customizations.xml"
                $script:formulaFieldsToExclude = @()  # Variable global para filtrar datos después
                
                if (Test-Path $customizationsXmlPath) {
                    [xml]$customXml = Get-Content $customizationsXmlPath -Raw
                    
                    # Buscar todos los atributos con FormulaDefinitionFileName
                    $formulaAttributes = $customXml.SelectNodes("//attribute[FormulaDefinitionFileName]")
                    $removedCount = 0
                    
                    foreach ($attr in $formulaAttributes) {
                        # Guardar el nombre del campo (LogicalName) para filtrar datos después
                        $fieldLogicalName = $attr.SelectSingleNode("LogicalName")
                        if ($fieldLogicalName -and $fieldLogicalName.InnerText) {
                            $script:formulaFieldsToExclude += $fieldLogicalName.InnerText
                        }
                        
                        # Eliminar el nodo completo del atributo de fórmula
                        $attr.ParentNode.RemoveChild($attr) | Out-Null
                        $removedCount++
                    }
                    
                    if ($removedCount -gt 0) {
                        # Guardar XML modificado
                        $customXml.Save($customizationsXmlPath)
                        Write-Output "      Eliminadas $removedCount referencias en customizations.xml"
                        Write-Output "      Campos: $($script:formulaFieldsToExclude -join ', ')"
                    }
                }
                
                # 3. Re-comprimir sin las fórmulas
                $cleanZipPath = Join-Path $env:TEMP "miApp_Clean_$([guid]::NewGuid()).zip"
                [System.IO.Compression.ZipFile]::CreateFromDirectory($tempModifyDir, $cleanZipPath)
                
                # Reemplazar archivo de solución con versión limpia
                $originalSize = [math]::Round($solutionFile.Length / 1KB, 0)
                $solutionFile = Get-Item $cleanZipPath
                $newSize = [math]::Round($solutionFile.Length / 1KB, 0)
                
                Write-Output "      Solución reempaquetada sin fórmulas"
                Write-Output "      Tamaño: $originalSize KB → $newSize KB"
                Write-Output ""
                Write-Output "    NOTA: Las fórmulas se deben recrear manualmente después"
                Write-Output "          del restore en Power Apps → Tables → Columns"
                Write-Output ""
                
                # Limpiar directorio temporal
                Remove-Item $tempModifyDir -Recurse -Force
                
            } catch {
                Write-Output "      No se pudo aplicar workaround automático"
                Write-Output "      Error: $($_.Exception.Message)"
                Write-Output "      Continuando con solución original..."
                Write-Output ""
            }
        }
        
    } catch {
        Write-Output ""
        Write-Output "    ERROR: El archivo ZIP está corrupto o es inválido"
        Write-Output "    Detalle: $($_.Exception.Message)"
        Write-Output ""
        Write-Output "  SOLUCIÓN:"
        Write-Output "    1. Ejecuta el backup nuevamente desde el environment origen"
        Write-Output "    2. Verifica que el backup se completó correctamente"
        Write-Output "    3. Descarga el backup nuevamente desde Azure Storage"
        Write-Output ""
        throw "ZIP de solución corrupto o inválido"
    }
    
    # Generar ImportJobId único
    $importJobId = [guid]::NewGuid().ToString()
    
    # Re-leer el archivo de solución (puede haber sido modificado en CreateCopy)
    if ($RestoreMode -eq "CreateCopy") {
        Write-Output ""
        Write-Output "  [CreateCopy] Codificando solución modificada a Base64..."
        $solutionBytes = [System.IO.File]::ReadAllBytes($solutionFile.FullName)
        $solutionBase64 = [System.Convert]::ToBase64String($solutionBytes)
        $sizeInMB = [math]::Round($solutionBytes.Length / 1MB, 2)
        Write-Output "    Solucion codificada: $sizeInMB MB"
    }
    
    # Preparar parámetros de importación
    $importBody = @{
        OverwriteUnmanagedCustomizations = $overwriteFlag
        PublishWorkflows = $publishWorkflows
        CustomizationFile = $solutionBase64
        ImportJobId = $importJobId
    }
    
    # CRÍTICO: Si la solución ya existe, importar con el mismo tipo (managed/unmanaged)
    # Si intentamos cambiar de unmanaged a managed (o viceversa), da error 0x80048033
    # NOTA: En modo CreateCopy, la solución es NUEVA (UniqueName diferente), no aplica esta lógica
    if ($existingSolutionIsManaged -ne $null -and $RestoreMode -ne "CreateCopy") {
        # Forzar conversión a managed si la existente es managed
        # Forzar conversión a unmanaged si la existente es unmanaged
        $importBody.ConvertToManaged = $existingSolutionIsManaged
        
        Write-Output ""
        Write-Output "  Solución existente detectada como: $(if ($existingSolutionIsManaged) { 'Managed' } else { 'Unmanaged' })"
        Write-Output "  -> Importando con mismo tipo para evitar conflicto"
        
        # LOG DETALLADO: Confirmar asignación
        Write-Output ""
        Write-Output "  DEBUG - Asignación ConvertToManaged:"
        Write-Output "    Valor asignado: '$($importBody.ConvertToManaged)'"
        Write-Output "    Tipo: $($importBody.ConvertToManaged.GetType().Name)"
    } else {
        Write-Output ""
        Write-Output "  No se detectó solución existente o modo es CreateCopy (solución nueva)"
        Write-Output "  -> ConvertToManaged no será especificado (Dataverse decidirá)"
        
        if ($RestoreMode -eq "CreateCopy") {
            Write-Output ""
            Write-Output "   INFO: Modo CreateCopy"
            Write-Output "    -> SOLUCIÓN: Nueva solución con sufijo '_Restored_<timestamp>'"
            Write-Output "    -> DATOS: Nuevos registros con marcadores únicos"
            Write-Output "    -> Resultado: Solución original + Solución restaurada (coexisten)"
        }
    }
    
    $importBodyJson = $importBody | ConvertTo-Json
    
    Write-Output ""
    Write-Output "  Import Job ID: $importJobId"
    
    # LOG DETALLADO: Mostrar valor exacto de ConvertToManaged
    if ($importBody.ContainsKey('ConvertToManaged')) {
        $convertValue = $importBody['ConvertToManaged']
        Write-Output "  Convert to Managed: $convertValue (tipo: $($convertValue.GetType().Name))"
    } else {
        Write-Output "  Convert to Managed: No especificado (clave no existe en hashtable)"
    }
    
    # LOG RESUMIDO: Mostrar estructura del request (sin Base64 completo)
    Write-Output ""
    Write-Output "  Request Parameters:"
    Write-Output "    - ImportJobId: $importJobId"
    Write-Output "    - OverwriteUnmanagedCustomizations: $($importBody.OverwriteUnmanagedCustomizations)"
    Write-Output "    - PublishWorkflows: $($importBody.PublishWorkflows)"
    Write-Output "    - CustomizationFile: [Base64 - $([math]::Round($solutionBytes.Length / 1KB, 0)) KB]"
    if ($importBody.ContainsKey('ConvertToManaged')) {
        Write-Output "    - ConvertToManaged: $($importBody.ConvertToManaged)"
    }
    Write-Output ""
    
    # Importar solución usando Dataverse API
    $importUrl = "$dataverseUrl/api/data/v9.2/ImportSolution"
    
    try {
        $importResponse = Invoke-RestMethod -Uri $importUrl -Method Post -Headers $script:headers -Body $importBodyJson -ErrorAction Stop
        
        # Actualizar estadísticas
        $script:restoreStats.solutionImported = $true
        $script:restoreStats.solutionName = $solutionFile.BaseName
        
        Write-Output ""
        Write-Output "  Solución importada exitosamente"
        
        Write-DetailedLog "Solution imported: $($solutionFile.Name) (Mode: $RestoreMode)" "INFO"
        
    } catch {
        # Capturar detalle completo del error 400
        Write-Output ""
        Write-Output "  ═══════════════════════════════════════════════════"
        Write-Output "  ERROR DETALLADO AL IMPORTAR SOLUCIÓN"
        Write-Output "  ═══════════════════════════════════════════════════"
        Write-Output ""
        Write-Output "  Mensaje: $($_.Exception.Message)"
        
        # Capturar StatusCode si está disponible
        $statusCode = "N/A"
        if ($_.Exception.Response) {
            try {
                $statusCode = "$($_.Exception.Response.StatusCode.value__) - $($_.Exception.Response.StatusCode)"
            } catch {
                $statusCode = $_.Exception.Response.StatusCode
            }
        }
        Write-Output "  StatusCode: $statusCode"
        Write-Output ""
        
        # Intentar leer el response body con múltiples métodos
        $responseBody = ""
        $errorDetails = @{}
        
        if ($_.Exception.Response) {
            # Método 1: Leer el stream directamente
            try {
                $result = $_.Exception.Response.GetResponseStream()
                if ($result.CanRead) {
                    $reader = New-Object System.IO.StreamReader($result)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                }
            } catch {
                Write-Output "  [DEBUG] Método 1 falló: $($_.Exception.Message)"
            }
            
            # Método 2: Si el stream está vacío, intentar con ErrorDetails
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                try {
                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                        $responseBody = $_.ErrorDetails.Message
                    }
                } catch {
                    Write-Output "  [DEBUG] Método 2 falló: $($_.Exception.Message)"
                }
            }
            
            # Método 3: Intentar obtener desde TargetObject
            if ([string]::IsNullOrWhiteSpace($responseBody)) {
                try {
                    if ($_.TargetObject -and $_.TargetObject.Content) {
                        $responseBody = $_.TargetObject.Content
                    }
                } catch {
                    Write-Output "  [DEBUG] Método 3 falló: $($_.Exception.Message)"
                }
            }
        }
        
        # Mostrar response body si se capturó
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            Write-Output "  Response Body:"
            Write-Output "  $responseBody"
            Write-Output ""
            
            # Intentar parsear el JSON para extraer el error específico
            try {
                $errorJson = $responseBody | ConvertFrom-Json
                if ($errorJson.error) {
                    Write-Output "  ┌─ Dataverse Error Details ─────────────────────"
                    Write-Output "  │ Code: $($errorJson.error.code)"
                    Write-Output "  │ Message: $($errorJson.error.message)"
                    if ($errorJson.error.innererror) {
                        Write-Output "  │ Inner Error: $($errorJson.error.innererror.message)"
                        if ($errorJson.error.innererror.type) {
                            Write-Output "  │ Type: $($errorJson.error.innererror.type)"
                        }
                    }
                    Write-Output "  └───────────────────────────────────────────────"
                    Write-Output ""
                }
            } catch {
                Write-Output "  (Response no es JSON válido)"
            }
        } else {
            Write-Output "  Response Body: (vacío o no disponible)"
            Write-Output ""
            Write-Output "  NOTA: El error 400 sin response body puede indicar:"
            Write-Output "    - El ZIP de la solución está corrupto"
            Write-Output "    - El formato del request no es válido"
            Write-Output "    - Problema con el encoding del Base64"
            Write-Output ""
        }
        
        Write-Output ""
        Write-Output "  URL: $importUrl"
        Write-Output "  Solución: $($solutionFile.Name)"
        Write-Output "  Tamaño: $([math]::Round($solutionFile.Length / 1MB, 2)) MB"
        Write-Output "  UniqueName extraído: $solutionUniqueName"
        Write-Output "  Modo: $RestoreMode"
        Write-Output ""
        
        # Analizar el error específico y dar solución precisa
        if ($responseBody -match '0x80040216.*NullReferenceException.*AttributeService') {
            Write-Output "  ┌────────────────────────────────────────────────────┐"
            Write-Output "  │ DIAGNÓSTICO: Formula Columns incompatibles         │"
            Write-Output "  └────────────────────────────────────────────────────┘"
            Write-Output ""
            Write-Output "  CAUSA DEL ERROR:"
            Write-Output "    La solución contiene campos con fórmulas (Formula columns)"
            Write-Output "    que causan NullReferenceException al importarse."
            Write-Output ""
            
            # Detectar qué entidad tiene el problema
            if ($responseBody -match "logical name (\w+)") {
                $problematicEntity = $matches[1]
                Write-Output "  ENTIDAD AFECTADA: $problematicEntity"
                Write-Output ""
            }
            
            Write-Output "  ══════════════════════════════════════════════════════"
            Write-Output "  SOLUCIÓN 1: Re-exportar sin fórmulas (RECOMENDADO)"
            Write-Output "  ══════════════════════════════════════════════════════"
            Write-Output ""
            Write-Output "    1. Ve al environment ORIGEN (Dev-02)"
            Write-Output "    2. Power Apps → Solutions → miApp → Export"
            Write-Output "    3. Opciones avanzadas:"
            Write-Output "       ✗ DESMARCA 'Include formula definitions'"
            Write-Output "    4. Exporta la solución"
            Write-Output "    5. Ejecuta el BACKUP runbook nuevamente"
            Write-Output "    6. Re-ejecuta este RESTORE"
            Write-Output ""
            Write-Output "  ══════════════════════════════════════════════════════"
            Write-Output "  SOLUCIÓN 2: Eliminar fórmulas del backup actual"
            Write-Output "  ══════════════════════════════════════════════════════"
            Write-Output ""
            Write-Output "    1. Descarga el backup desde Azure Storage"
            Write-Output "    2. Extrae el ZIP: PowerPlatform_Backup_*.zip"
            Write-Output "    3. Dentro, extrae miApp.zip"
            Write-Output "    4. Elimina la carpeta 'Formulas/'"
            Write-Output "    5. Re-comprime miApp.zip"
            Write-Output "    6. Re-comprime PowerPlatform_Backup_*.zip"
            Write-Output "    7. Sube a Azure Storage reemplazando el existente"
            Write-Output "    8. Re-ejecuta este RESTORE"
            Write-Output ""
            Write-Output "  ══════════════════════════════════════════════════════"
            Write-Output "  SOLUCIÓN 3: Crear campos manualmente después"
            Write-Output "  ══════════════════════════════════════════════════════"
            Write-Output ""
            Write-Output "    1. Aplica Solución 1 o 2 para importar sin fórmulas"
            Write-Output "    2. Después de importar exitosamente, ve a:"
            Write-Output "       Power Apps → Dataverse → Tables → $problematicEntity"
            Write-Output "    3. Crea los campos de fórmula manualmente"
            Write-Output "    4. Configura las expresiones directamente en Power Apps"
            Write-Output ""
            Write-Output "  NOTA: Este es un problema conocido de Power Platform"
            Write-Output "        al importar Formula columns entre environments."
            Write-Output ""
            
        } else {
            Write-Output "  POSIBLES CAUSAS:"
            Write-Output "    1. La solución ya existe en el environment"
            Write-Output "    2. Dependencias faltantes (plugins, workflows, etc.)"
            Write-Output "    3. Versión de la solución incompatible"
            Write-Output "    4. Permisos insuficientes del Service Principal"
            Write-Output "    5. El ZIP de la solución está corrupto"
            Write-Output "    6. El environment no está completamente provisionado"
            Write-Output ""
        }
        
        Write-Output "  ═══════════════════════════════════════════════════"
        Write-Output ""
        
        $errorMsg = "Error importando solución: $($_.Exception.Message)"
        Write-ErrorDetail $_ "ImportSolution"
        
        # Registrar resultado de esta solución (fallida)
        $solutionImportResults += [PSCustomObject]@{
            Name = $solutionToImport.Name
            Status = "Error"
            Message = $_.Exception.Message
        }
        
        # Continuar con siguiente solución en vez de abortar todo
        Write-Output ""
        Write-Output "    Continuando con siguiente solución..."
        Write-Output ""
        continue
    }
    
    # Registrar resultado de esta solución (exitosa)
    $solutionImportResults += [PSCustomObject]@{
        Name = $solutionToImport.Name
        Status = "Exitosa"
        Message = "Importada correctamente"
    }
    
    Write-Output ""
    Write-Output "    Solución $($solutionToImport.Name) importada correctamente"
    Write-Output ""
    
    } # Fin del loop foreach de soluciones
    
    # ==========================================
    # RESUMEN DE IMPORTACIÓN DE SOLUCIONES
    # ==========================================
    
    Write-Output ""
    Write-Output "=========================================="
    Write-Output "RESUMEN DE IMPORTACIÓN DE SOLUCIONES"
    Write-Output "=========================================="
    Write-Output ""
    
    $successCount = ($solutionImportResults | Where-Object { $_.Status -eq "Exitosa" }).Count
    $errorCount = ($solutionImportResults | Where-Object { $_.Status -eq "Error" }).Count
    
    Write-Output "Total de soluciones procesadas: $($solutionImportResults.Count)"
    Write-Output "    Exitosas: $successCount"
    Write-Output "    Con errores: $errorCount"
    Write-Output ""
    
    if ($errorCount -gt 0) {
        Write-Output "Soluciones con errores:"
        foreach ($result in $solutionImportResults | Where-Object { $_.Status -eq "Error" }) {
            Write-Output "    $($result.Name): $($result.Message)"
        }
        Write-Output ""
    }
    
    if ($successCount -eq 0) {
        throw "No se pudo importar ninguna solución exitosamente"
    }
    
    Write-Output "=========================================="
    Write-Output ""

} catch {
    $errorMsg = "Error en paso de importación: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "  $errorMsg"
    Write-ErrorDetail $_ "ImportSolution"
    $script:errors += $errorMsg
    throw
}


Write-Output ""
Write-Output "=========================================="
Write-Output "PASO 8: RESTAURAR DATOS DE TABLAS"
Write-Output "=========================================="


try {
    $dataversePath = Get-ChildItem -Path $extractPath -Directory -Filter "dataverse" -Recurse | Select-Object -First 1
    
    if (-not $dataversePath) {
        Write-Output "No se encontró directorio 'dataverse' en el backup"
    } else {
        $dataFiles = Get-ChildItem -Path $dataversePath.FullName -Filter "*.json"
        $totalTables = $dataFiles.Count
        
        Write-Output "Tablas encontradas: $totalTables"
        
        if ($totalTables -eq 0) {
            Write-Output "No se encontraron archivos JSON"
        } else {
            # API CACHING: Obtener TODOS los EntitySetNames en una sola llamada batch
            Write-Output "Obteniendo EntitySetNames..."
            $tableNameMap = @{}
            
            try {
                # Una sola llamada para todas las entidades (vs 100 llamadas individuales)
                $metadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions?`$select=LogicalName,EntitySetName"
                $startTime = Get-Date
                $allEntities = Invoke-RestMethod -Uri $metadataUrl -Method Get -Headers $script:headers -ErrorAction Stop
                $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
                
                # Construir hashtable para lookup O(1)
                foreach ($entity in $allEntities.value) {
                    $tableNameMap[$entity.LogicalName] = $entity.EntitySetName
                }
                
                Write-Output "  ✓ $($allEntities.value.Count) EntitySetNames cargados en ${elapsed}ms"
                
                # Aplicar fallback para tablas no encontradas
                $notFoundCount = 0
                foreach ($dataFile in $dataFiles) {
                    $logicalName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
                    if (-not $tableNameMap.ContainsKey($logicalName)) {
                        $tableNameMap[$logicalName] = "${logicalName}s"
                        $notFoundCount++
                    }
                }
                
                if ($notFoundCount -gt 0) {
                    Write-Output "  ⚠ $notFoundCount tablas usarán convención estándar (no encontradas en metadata)"
                }
                
            } catch {
                # Fallback: Si batch falla, usar método individual
                Write-Output "    Batch lookup falló, usando método individual..."
                foreach ($dataFile in $dataFiles) {
                    $logicalName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
                    try {
                        $metadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$logicalName')?`$select=EntitySetName"
                        $entityDef = Invoke-RestMethod -Uri $metadataUrl -Method Get -Headers $script:headers -ErrorAction Stop
                        $tableNameMap[$logicalName] = $entityDef.EntitySetName
                    } catch {
                        $tableNameMap[$logicalName] = "${logicalName}s"
                    }
                }
            }
            
            # Cachear tableNameMap para posible reutilización
            $script:cachedTableNameMap = $tableNameMap
            
            Write-Output ""
            Write-Output "Restaurando datos de tablas..."
            Write-Output "Nota: Algunas tablas system-managed pueden fallar (normal)"
            Write-Output ""
            
            $useMarkers = $false
            $tablesProcessed = 0
            $tablesSuccess = 0
            $tablesError = 0
            $totalRecordsRestored = 0
            $totalRecordsError = 0
            
            # Filtro de tablas system-managed (no restaurables)
            $systemManagedTablesToSkip = @(
                # AI/Copilot
                'aicopilot', 'aiinsightcard', 'aiplugin', 'aipluginauth', 'aipluginconversationstarter',
                'aipluginconversationstartermapping', 'aipluginexternalschema', 'aipluginexternalschemaproperty',
                'aiplugingovernance', 'aiplugingovernanceext', 'aiplugininstance', 'aipluginoperation',
                'aipluginoperationparameter', 'aipluginoperationresponsetemplate', 'aiplugintitle', 'aipluginusersetting',
                'aiskillconfig', 'mainfewshot', 'makerfewshot', 'msdyn_aiconfiguration', 'msdyn_aimodel', 'msdyn_aitemplate',
                
                # Agent System
                'agent', 'agentchannel', 'agentfeeditem', 'agentgroup', 'agentgrouptmembership',
                'agentmemory', 'agentscenario', 'agenttask',
                
                # App/Command Bar
                'appaction', 'appactionmigration', 'appactionrule', 'appaction_appactionrule_classicrules',
                'appactionrule_privilege_classicrules', 'appactionrule_webresource_scripts',
                'applicationuser', 'applicationuserprofile', 'applicationuserrole', 'appmodule',
                'appmodulecomponentedge', 'appmodulecomponentnode', 'appelement', 'appentitysearchview',
                'appsetting', 'appusersetting', 'applicationroles',
                
                # Metadata
                'attribute', 'entity', 'entitykey', 'entityimageconfig', 'entityanalyticsconfig',
                'entitymap', 'relationship', 'relationshipattribute', 'attributemap', 'attributeimageconfig',
                'entityclusterconfig', 'entityrelationship',
                
                # Bot/Chatbot
                'bot', 'botcomponent', 'botcomponentcollection', 'botcomponent_aipluginoperation',
                'botcomponent_botcomponent', 'botcomponent_connectionreference', 'botcomponent_dvtablesearch',
                'botcomponent_environmentvariabledefinition', 'botcomponent_msdyn_aimodel', 'botcomponent_workflow', 'bot_botcomponent',
                
                # Catalog/Connection
                'catalog', 'catalogassignment', 'connectionreference', 'connectioninstance',
                
                # Custom API
                'customapi', 'customapirequestparameter', 'customapiresponseproperty',
                
                # Data Lake/Processing
                'datalakefolder', 'datalakefolderpermission', 'dataprocessingconfiguration',
                
                # Search/Email
                'dvtablesearch', 'dvfilesearch', 'emailserverprofile', 'mailbox',
                
                # File Attachments
                'elasticfileattachment', 'fileattachment',
                
                # Environment Variables
                'environmentvariabledefinition', 'environmentvariablevalue',
                
                # Component Version
                'componentchangesetversion', 'componentversiondatasource',
                
                # Background/Credentials
                'allowedmcpclient', 'backgroundoperation', 'certificatecredential', 'credential',
                
                # Organization Sync/Settings
                'organizationdatasyncsubscription', 'organizationdatasyncsubscriptionentity', 'organizationsetting',
                
                # Role/Privileges
                'roleeditorlayout', 'roleprivileges', 'recordfilter',
                
                # Plugin System
                'pluginassembly', 'plugintype', 'plugintypestatistic',
                'sdkmessageprocessingstep', 'sdkmessageprocessingstepimage',
                
                # Power Pages (mspp_*)
                'mspp_adplacement', 'mspp_contentsnippet', 'mspp_entityform', 'mspp_entityformmetadata',
                'mspp_entitylist', 'mspp_entitypermission', 'mspp_pagetemplate', 'mspp_pollplacement',
                'mspp_publishingstate', 'mspp_publishingstatetransitionrule', 'mspp_redirect', 'mspp_shortcut',
                'mspp_sitemarker', 'mspp_sitesetting', 'mspp_webfile', 'mspp_webform', 'mspp_webformmetadata',
                'mspp_webformstep', 'mspp_weblink', 'mspp_weblinkset', 'mspp_webpage',
                'mspp_webpageaccesscontrolrule', 'mspp_webrole', 'mspp_website', 'mspp_websiteaccess', 'mspp_webtemplate',
                'powerpagecomponent',
                
                # Solution Components
                'solutioncomponentattributeconfiguration', 'solutioncomponentbatchconfiguration',
                'solutioncomponentconfiguration', 'solutioncomponentrelationshipconfiguration',
                'msdyn_solutioncomponentsummary', 'msdyn_solutionhealthrule', 'msdyn_solutionhealthruleargument',
                'msdyn_componentlayerdatasource', 'msdyn_solutionhistory',
                
                # Virtual Entities/Datasources
                'msdyn_solutioncomponentcountdatasource', 'msdyn_solutioncomponentdatasource',
                'msdyn_analysisresult', 'msdyn_analysiscomponent',
                
                # Flow/Workflow
                'flowmachineimageversion', 'workflow',
                
                # Other System Tables
                'featurecontrolsetting', 'managedidentity', 'metadataforarchival',
                'msdyn_fileupload', 'msdyn_knowledgesearchfilter', 'msdyn_pmtemplate',
                'msdyn_location', 'msdynce_contact_msdyn_service', 'msdyn_service',
                'packagehistory', 'processstage', 'settingdefinition', 'webresource'
            )
            
            Write-Output "Filtradas $($systemManagedTablesToSkip.Count) tablas system-managed"
            Write-Output ""
            
            # PARALELIZACIÓN: Configurar procesamiento en grupos
            $parallelBatchSize = 5  # Procesar 5 tablas simultáneamente (reducir overhead de Jobs)
            Write-Output "    Modo paralelo activado: Procesando $parallelBatchSize tablas simultáneamente"
            Write-Output "    Token refresh configurado: cada 50 minutos"
            Write-Output ""
            
            # Filtrar archivos antes de agrupar
            $dataFilesToProcess = @()
            foreach ($dataFile in $dataFiles) {
                $logicalName = [System.IO.Path]::GetFileNameWithoutExtension($dataFile.Name)
                if ($systemManagedTablesToSkip -notcontains $logicalName) {
                    $fullPath = [string]$dataFile.FullName
                    $dataFilesToProcess += [PSCustomObject]@{
                        File = $fullPath
                        LogicalName = $logicalName
                        EntitySetName = $tableNameMap[$logicalName]
                    }
                } else {
                    $skippedKnownTables += $logicalName
                }
            }
            
            Write-Output "Tablas a procesar: $($dataFilesToProcess.Count)"
            
            # Agrupar en batches para paralelización
            $tableGroups = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $dataFilesToProcess.Count; $i += $parallelBatchSize) {
                $endIndex = [Math]::Min($i + $parallelBatchSize - 1, $dataFilesToProcess.Count - 1)
                [void]$tableGroups.Add($dataFilesToProcess[$i..$endIndex])
            }
            
            Write-Output "Procesando en $($tableGroups.Count) lotes de $parallelBatchSize tablas"
            Write-Output ""
            
            # Procesar cada grupo
            foreach ($groupIndex in 0..($tableGroups.Count - 1)) {
                $group = $tableGroups[$groupIndex]
                Write-Output "Lote $($groupIndex + 1)/$($tableGroups.Count) [$($group.Count) tablas]..."
                
                # Crear jobs para cada tabla
                $jobs = @()
                foreach ($tableInfo in $group) {
                    if (-not $tableInfo -or -not $tableInfo.File) { continue }
                    
                    $filePath = [string]$tableInfo.File
                    $logicalName = [string]$tableInfo.LogicalName
                    $entitySetName = [string]$tableInfo.EntitySetName
                    
                    if ([string]::IsNullOrWhiteSpace($filePath)) { continue }
                    
                    # Clonar variables para job
                    $localHeaders = $script:headers.Clone()
                    $localUseMarkers = $useMarkers
                    $localBackupId = $script:restoreStats.backupId
                    $localFormulaFields = $script:formulaFieldsToExclude
                    $localNonRestorableTables = $knownNonRestorableTables
                    $localDataverseUrl = $dataverseUrl
                    
                    $job = Start-Job -ScriptBlock {
                        param($dataFile, $logicalName, $entitySetName, $dataverseUrl, $headers, $useMarkers, $backupId, $formulaFieldsToExclude, $knownNonRestorableTables)
                        
                        if ([string]::IsNullOrWhiteSpace($dataFile)) {
                            return @{
                                LogicalName = $logicalName; EntitySetName = $entitySetName
                                Success = $false; RecordsTotal = 0; RecordsSuccess = 0; RecordsError = 0
                                ErrorMessages = @("dataFile es NULL"); IsEmpty = $false
                                IsKnownNonRestorable = $false; UsedBatchAPI = $false
                            }
                        }
                        
                        try {
                            $result = @{
                                LogicalName = $logicalName; EntitySetName = $entitySetName
                                Success = $false; RecordsTotal = 0; RecordsSuccess = 0; RecordsError = 0
                                ErrorMessages = @(); IsEmpty = $false
                                IsKnownNonRestorable = $false; UsedBatchAPI = $false
                            }
                            
                            # CASO ESPECIAL: fileattachment usa File Upload API
                            if ($logicalName -eq 'fileattachment') {
                                $records = Get-Content $dataFile -Raw | ConvertFrom-Json
                                if ($records.Count -eq 0) {
                                    $result.IsEmpty = $true; $result.Success = $true
                                    return $result
                                }
                                
                                $result.RecordsTotal = $records.Count
                                
                                foreach ($record in $records) {
                                    try {
                                        $fileName = $record.filename
                                        $body = $record.body
                                        if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($body)) {
                                            throw "Falta filename o body"
                                        }
                                        
                                        # Initialize
                                        $initUrl = "$dataverseUrl/api/data/v9.2/InitializeFileBlocksUpload"
                                        $initBody = @{ Target = @{ "@odata.type" = "Microsoft.Dynamics.CRM.fileattachment"; filename = $fileName } } | ConvertTo-Json -Depth 5
                                        $initResponse = Invoke-RestMethod -Uri $initUrl -Method Post -Headers $headers -Body $initBody -ContentType "application/json"
                                        $fileBlockId = $initResponse.FileContinuationToken
                                        
                                        # Upload
                                        $uploadUrl = "$dataverseUrl/api/data/v9.2/UploadBlock"
                                        $uploadBody = @{ BlockId = $fileBlockId; BlockData = $body } | ConvertTo-Json -Depth 5
                                        Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $headers -Body $uploadBody -ContentType "application/json" | Out-Null
                                        
                                        # Commit
                                        $commitUrl = "$dataverseUrl/api/data/v9.2/CommitFileBlocksUpload"
                                        $commitBody = @{
                                            Target = @{
                                                "@odata.type" = "Microsoft.Dynamics.CRM.fileattachment"
                                                fileattachmentid = [guid]::NewGuid().ToString()
                                                filename = $fileName
                                                mimetype = if ($record.mimetype) { $record.mimetype } else { "application/octet-stream" }
                                            }
                                            BlockList = @($fileBlockId)
                                            FileContinuationToken = $fileBlockId
                                        }
                                        if ($record.'regardingobjectid@odata.bind') {
                                            $commitBody.Target['regardingobjectid@odata.bind'] = $record.'regardingobjectid@odata.bind'
                                        }
                                        Invoke-RestMethod -Uri $commitUrl -Method Post -Headers $headers -Body ($commitBody | ConvertTo-Json -Depth 5) -ContentType "application/json" | Out-Null
                                        
                                        $result.RecordsSuccess++
                                    } catch {
                                        $result.RecordsError++
                                        if ($result.ErrorMessages.Count -lt 3) {
                                            $result.ErrorMessages += "File Upload: $($_.Exception.Message)"
                                        }
                                    }
                                }
                                
                                $result.Success = ($result.RecordsError -eq 0)
                                return $result
                            }
                            
                            # Leer registros
                            $records = Get-Content $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
                            if (-not $records -or $records.Count -eq 0) {
                                $result.IsEmpty = $true; $result.Success = $true
                                return $result
                            }
                            
                            $result.RecordsTotal = $records.Count
                            
                            # Decidir: Batch API (>=10 registros) vs Serial (<10 registros)
                            $knownVirtualEntities = @('msdyn_solutionhistory', 'msdyn_analysisresult', 'msdyn_analysiscomponent')
                            $isVirtualEntity = $knownVirtualEntities -contains $logicalName
                            $useBatchAPI = ($records.Count -ge 10) -and (-not $isVirtualEntity)
                            
                            if ($useBatchAPI) {
                                # BATCH API
                                $result.UsedBatchAPI = $true
                                
                                # Preparar registros limpios
                                $cleanRecords = @()
                                foreach ($record in $records) {
                                    $newRecord = @{}
                                    foreach ($prop in $record.PSObject.Properties) {
                                        if ($prop.Name -notlike '@*' -and $prop.Name -notlike '_*_value' -and 
                                            $prop.Name -ne 'id' -and $prop.Name -notin $formulaFieldsToExclude -and 
                                            $null -ne $prop.Value) {
                                            $value = $prop.Value
                                            if ($value -is [bool]) { $value = $value.ToString().ToLower() }
                                            $newRecord[$prop.Name] = $value
                                        }
                                    }
                                    if ($useMarkers) {
                                        $newRecord['cr8df_backupid'] = $backupId
                                        $newRecord['cr8df_fecharestore'] = (Get-Date).ToUniversalTime().ToString("o")
                                    }
                                    $cleanRecords += $newRecord
                                }
                                
                                try {
                                    # Procesar en batches de 100
                                    $batchSize = 100
                                    $batchCount = [Math]::Ceiling($cleanRecords.Count / $batchSize)
                                    
                                    for ($batchIndex = 0; $batchIndex -lt $batchCount; $batchIndex++) {
                                        $startIdx = $batchIndex * $batchSize
                                        $endIdx = [Math]::Min(($batchIndex + 1) * $batchSize - 1, $cleanRecords.Count - 1)
                                        $currentBatch = $cleanRecords[$startIdx..$endIdx]
                                        
                                        # IDs únicos
                                        $batchId = "batch_" + [Guid]::NewGuid().ToString()
                                        $changesetId = "changeset_" + [Guid]::NewGuid().ToString()
                                        
                                        # Construir body multipart
                                        $batchBody = "--$batchId`r`n"
                                        $batchBody += "Content-Type: multipart/mixed; boundary=$changesetId`r`n`r`n"
                                        
                                        $contentId = 1
                                        foreach ($rec in $currentBatch) {
                                            $recJson = $rec | ConvertTo-Json -Depth 10 -Compress
                                            $batchBody += "--$changesetId`r`n"
                                            $batchBody += "Content-Type: application/http`r`n"
                                            $batchBody += "Content-Transfer-Encoding: binary`r`n"
                                            $batchBody += "Content-ID: $contentId`r`n`r`n"
                                            $batchBody += "POST $dataverseUrl/api/data/v9.2/$entitySetName HTTP/1.1`r`n"
                                            $batchBody += "Content-Type: application/json`r`n`r`n"
                                            $batchBody += "$recJson`r`n"
                                            $contentId++
                                        }
                                        
                                        $batchBody += "--$changesetId--`r`n"
                                        $batchBody += "--$batchId--"
                                        
                                        # Headers
                                        $batchHeaders = $headers.Clone()
                                        $batchHeaders["Content-Type"] = "multipart/mixed; boundary=$batchId"
                                        $batchHeaders["OData-Version"] = "4.0"
                                        $batchHeaders["OData-MaxVersion"] = "4.0"
                                        $batchHeaders["Prefer"] = "odata.continue-on-error"
                                        
                                        # Ejecutar
                                        $response = Invoke-RestMethod `
                                            -Uri "$dataverseUrl/api/data/v9.2/`$batch" `
                                            -Method Post `
                                            -Headers $batchHeaders `
                                            -Body ([System.Text.Encoding]::UTF8.GetBytes($batchBody)) `
                                            -ContentType "multipart/mixed; boundary=$batchId"
                                        
                                        # Parsear respuesta
                                        $responseText = $response | Out-String
                                        $successMatches = [regex]::Matches($responseText, "HTTP/1\.\d+ (20[0-9]|201|204)")
                                        $errorMatches = [regex]::Matches($responseText, "HTTP/1\.\d+ ([45][0-9]{2})")
                                        
                                        $successCount = if ($successMatches.Count -eq 0 -and $errorMatches.Count -eq 0) { $currentBatch.Count } else { $successMatches.Count }
                                        $errorCount = $errorMatches.Count
                                        
                                        $result.RecordsSuccess += $successCount
                                        $result.RecordsError += $errorCount
                                        
                                        # Procesar errores
                                        if ($errorCount -gt 0) {
                                            $errorDetailMatches = [regex]::Matches($responseText, '"message":\s*"([^"]+)"')
                                            foreach ($match in $errorDetailMatches) {
                                                $errorMessage = $match.Groups[1].Value
                                                $isNonRestorable = ($errorMessage -like "*does not support entities*" -or
                                                                    $errorMessage -like "*Virtual Entity*" -or
                                                                    $errorMessage -like "*duplicate*" -or
                                                                    $errorMessage -like "*already exists*")
                                                
                                                if ($isNonRestorable) {
                                                    $result.RecordsError--
                                                    if ($result.ErrorMessages.Count -lt 3) {
                                                        $result.ErrorMessages += "[SKIP] Non-restorable"
                                                    }
                                                } else {
                                                    if ($result.ErrorMessages.Count -lt 3) {
                                                        $result.ErrorMessages += $errorMessage
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    
                                } catch {
                                    # v6.5: Opción D Mejorada - Detectar errores de lookup/dictionary en ErrorDetails JSON
                                    $batchErrorMsg = $_.Exception.Message
                                    $batchErrorDetails = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { "" }
                                    
                                    if ($batchErrorDetails -like "*dictionary*" -or
                                        $batchErrorDetails -like "*0x80040224*" -or
                                        $batchErrorMsg -like "*key was not present in the dictionary*" -or
                                        $batchErrorMsg -like "*dictionary*") {
                                        
                                        # Fallback: Intentar Serial mode en lugar de marcar todo como error
                                        $result.ErrorMessages += "[INFO] Batch API failed (lookup/field mismatch), retrying Serial mode..."
                                        $result.UsedBatchAPI = $false  # Cambiar indicador
                                        
                                        # Procesar en Serial mode (registro por registro)
                                        $apiUrl = "$dataverseUrl/api/data/v9.2/$entitySetName"
                                        
                                        foreach ($record in $records) {
                                            try {
                                                $newRecord = @{}
                                                
                                                foreach ($prop in $record.PSObject.Properties) {
                                                    if ($prop.Name -notlike '@*' -and 
                                                        $prop.Name -notlike '_*_value' -and 
                                                        $prop.Name -ne 'id' -and 
                                                        $prop.Name -notin $formulaFieldsToExclude -and 
                                                        $null -ne $prop.Value) {
                                                        
                                                        $value = $prop.Value
                                                        if ($value -is [bool]) {
                                                            $value = $value.ToString().ToLower()
                                                        }
                                                        
                                                        $newRecord[$prop.Name] = $value
                                                    }
                                                }
                                                
                                                if ($useMarkers) {
                                                    $newRecord['cr8df_backupid'] = $backupId
                                                    $newRecord['cr8df_fecharestore'] = (Get-Date).ToUniversalTime().ToString("o")
                                                }
                                                
                                                $recordJson = $newRecord | ConvertTo-Json -Depth 10 -Compress
                                                Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $recordJson -ContentType "application/json" | Out-Null
                                                
                                                $result.RecordsSuccess++
                                                
                                            } catch {
                                                # v6.9.4: ACTUALIZADO - Aplicar MISMA lógica que Serial mode principal
                                                $serialErrorMsg = $_.Exception.Message
                                                
                                                # Capturar mensaje completo desde ErrorDetails
                                                $serialErrorDetails = ""
                                                $serialFullErrorJson = $null
                                                
                                                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                                                    try {
                                                        $serialFullErrorJson = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                                                        if ($serialFullErrorJson.error -and $serialFullErrorJson.error.message) {
                                                            $serialErrorDetails = $serialFullErrorJson.error.message
                                                        } else {
                                                            $serialErrorDetails = $_.ErrorDetails.Message
                                                        }
                                                    } catch {
                                                        $serialErrorDetails = $_.ErrorDetails.Message
                                                    }
                                                } else {
                                                    $serialErrorDetails = $serialErrorMsg
                                                }
                                                
                                                # Detectar campo inválido y retry
                                                $isFallbackInvalidFieldError = $false
                                                $fallbackInvalidFieldName = $null
                                                
                                                if ($serialErrorDetails -like "*Invalid property*was found in entity*" -or
                                                    $serialErrorDetails -like "*property*does not exist on type*") {
                                                    $isFallbackInvalidFieldError = $true
                                                    
                                                    if ($serialErrorDetails -match "Invalid property '([^']+)'" -or
                                                        $serialErrorDetails -match "property '([^']+)'") {
                                                        $fallbackInvalidFieldName = $matches[1]
                                                    }
                                                }
                                                
                                                # Retry sin campo inválido
                                                if ($isFallbackInvalidFieldError -and $fallbackInvalidFieldName) {
                                                    try {
                                                        $fallbackCleanRecord = @{}
                                                        foreach ($prop in $record.PSObject.Properties) {
                                                            if ($prop.Name -notlike '@*' -and 
                                                                $prop.Name -notlike '_*_value' -and 
                                                                $prop.Name -ne 'id' -and
                                                                $prop.Name -ne $fallbackInvalidFieldName -and
                                                                $prop.Name -notin $formulaFieldsToExclude -and 
                                                                $null -ne $prop.Value) {
                                                                
                                                                $value = $prop.Value
                                                                if ($value -is [bool]) {
                                                                    $value = $value.ToString().ToLower()
                                                                }
                                                                
                                                                $fallbackCleanRecord[$prop.Name] = $value
                                                            }
                                                        }
                                                        
                                                        if ($useMarkers) {
                                                            $fallbackCleanRecord['cr8df_backupid'] = $backupId
                                                            $fallbackCleanRecord['cr8df_fecharestore'] = (Get-Date).ToUniversalTime().ToString("o")
                                                        }
                                                        
                                                        $fallbackCleanJson = $fallbackCleanRecord | ConvertTo-Json -Depth 10 -Compress
                                                        Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $fallbackCleanJson -ContentType "application/json" | Out-Null
                                                        
                                                        $result.RecordsSuccess++
                                                        if ($result.ErrorMessages.Count -lt 3) {
                                                            $result.ErrorMessages += "[FIXED] Removido campo inválido: $fallbackInvalidFieldName"
                                                        }
                                                        continue
                                                        
                                                    } catch {
                                                        # Retry también falló, continuar con error normal
                                                    }
                                                }
                                                
                                                # Detección non-restorable
                                                $isNonRestorableError = $false
                                                
                                                if ($tableName -ne 'contact') {
                                                    if ($serialErrorDetails -like "*does not support entities of type*" -or
                                                        $serialErrorDetails -like "*MessageProcessorCache returned MessageProcessor.Empty*") {
                                                        $isNonRestorableError = $true
                                                    }
                                                }
                                                
                                                if ($serialErrorDetails -like "*Virtual Entity*") {
                                                    $isNonRestorableError = $true
                                                }
                                                
                                                if ($serialErrorDetails -like "*duplicate*" -or
                                                    $serialErrorDetails -like "*already exists*" -or
                                                    $serialErrorDetails -like "*0x80040333*" -or
                                                    $serialErrorDetails -like "*0x80040237*") {
                                                    $isNonRestorableError = $true
                                                }
                                                
                                                if (-not $isNonRestorableError) {
                                                    $result.RecordsError++
                                                    if ($result.ErrorMessages.Count -lt 3) {
                                                        $errorShort = if ($serialErrorDetails.Length -gt 200) { $serialErrorDetails.Substring(0, 200) + "..." } else { $serialErrorDetails }
                                                        if ($errorShort) {
                                                            $result.ErrorMessages += $errorShort
                                                        } else {
                                                            $result.ErrorMessages += $serialErrorMsg
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        
                                    } else {
                                        # Error diferente de "dictionary", marcar todos como error
                                        $result.RecordsError = $records.Count
                                        if ($result.ErrorMessages.Count -lt 3) {
                                            $result.ErrorMessages += "Batch API error: $batchErrorMsg"
                                        }
                                    }
                                }
                                
                            } else {
                                # SERIAL mode (tablas <10 registros)
                                $apiUrl = "$dataverseUrl/api/data/v9.2/$entitySetName"
                            
                            foreach ($record in $records) {
                                try {
                                    $newRecord = @{}
                                    foreach ($prop in $record.PSObject.Properties) {
                                        if ($prop.Name -notlike '@*' -and $prop.Name -notlike '_*_value' -and 
                                            $prop.Name -ne 'id' -and $prop.Name -notin $formulaFieldsToExclude -and 
                                            $null -ne $prop.Value) {
                                            $value = $prop.Value
                                            if ($value -is [bool]) { $value = $value.ToString().ToLower() }
                                            $newRecord[$prop.Name] = $value
                                        }
                                    }
                                    
                                    if ($useMarkers) {
                                        $newRecord['cr8df_backupid'] = $backupId
                                        $newRecord['cr8df_fecharestore'] = (Get-Date).ToUniversalTime().ToString("o")
                                    }
                                    
                                    $recordJson = $newRecord | ConvertTo-Json -Depth 10 -Compress
                                    
                                    Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $recordJson -ContentType "application/json" | Out-Null
                                    
                                    $result.RecordsSuccess++
                                    
                                } catch {
                                    # AUTO-FIX: Remover campos inválidos iterativamente
                                    $attemptNumber = 0
                                    $maxAttempts = 10
                                    $invalidFieldsRemoved = @()
                                    $recordSuccess = $false
                                    $currentErrorDetails = ""
                                    
                                    # Capturar primer error
                                    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                                        try {
                                            $fullErrorJson = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                                            if ($fullErrorJson.error -and $fullErrorJson.error.message) {
                                                $currentErrorDetails = $fullErrorJson.error.message
                                            } else {
                                                $currentErrorDetails = $_.ErrorDetails.Message
                                            }
                                        } catch {
                                            $currentErrorDetails = $_.ErrorDetails.Message
                                        }
                                    } else {
                                        $currentErrorDetails = $_.Exception.Message
                                    }
                                    
                                    while ($attemptNumber -lt $maxAttempts -and -not $recordSuccess) {
                                        $attemptNumber++
                                        
                                        $invalidFieldName = $null
                                        if ($currentErrorDetails -like "*Invalid property*" -or $currentErrorDetails -like "*property*does not exist*") {
                                            if ($currentErrorDetails -match "property '([^']+)'") {
                                                $invalidFieldName = $matches[1]
                                            }
                                        }
                                        
                                        if (-not $invalidFieldName) { break }
                                        $invalidFieldsRemoved += $invalidFieldName
                                        
                                        try {
                                            $cleanRecord = @{}
                                            foreach ($prop in $record.PSObject.Properties) {
                                                if ($prop.Name -notlike '@*' -and $prop.Name -notlike '_*_value' -and 
                                                    $prop.Name -ne 'id' -and $prop.Name -notin $invalidFieldsRemoved -and
                                                    $prop.Name -notin $formulaFieldsToExclude -and $null -ne $prop.Value) {
                                                    $value = $prop.Value
                                                    if ($value -is [bool]) { $value = $value.ToString().ToLower() }
                                                    $cleanRecord[$prop.Name] = $value
                                                }
                                            }
                                            
                                            if ($useMarkers) {
                                                $cleanRecord['cr8df_backupid'] = $backupId
                                                $cleanRecord['cr8df_fecharestore'] = (Get-Date).ToUniversalTime().ToString("o")
                                            }
                                            
                                            $cleanJson = $cleanRecord | ConvertTo-Json -Depth 10 -Compress
                                            Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $cleanJson -ContentType "application/json" | Out-Null
                                            
                                            $recordSuccess = $true
                                            $result.RecordsSuccess++
                                            if ($result.ErrorMessages.Count -lt 3) {
                                                $result.ErrorMessages += "[FIXED] Campos removidos: $($invalidFieldsRemoved -join ', ')"
                                            }
                                            
                                        } catch {
                                            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                                                try {
                                                    $retryErrorJson = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                                                    $currentErrorDetails = if ($retryErrorJson.error.message) { $retryErrorJson.error.message } else { $_.ErrorDetails.Message }
                                                } catch {
                                                    $currentErrorDetails = $_.ErrorDetails.Message
                                                }
                                            } else {
                                                $currentErrorDetails = $_.Exception.Message
                                            }
                                        }
                                    }
                                    
                                    if ($recordSuccess) { continue }
                                    $errorDetails = $currentErrorDetails
                                    
                                    # Detectar errores non-restorable
                                    $isNonRestorableError = ($errorDetails -like "*does not support entities*" -or
                                                             $errorDetails -like "*Virtual Entity*" -or
                                                             $errorDetails -like "*duplicate*" -or
                                                             $errorDetails -like "*already exists*" -or
                                                             $errorDetails -like "*read-only*" -or
                                                             $errorDetails -like "*Precondition Failed*" -or
                                                             $errorDetails -like "*unique constraint*")
                                    
                                    if ($isNonRestorableError) {
                                        if ($result.ErrorMessages.Count -lt 3) {
                                            $result.ErrorMessages += "[SKIP] Non-restorable"
                                        }
                                    } else {
                                        $result.RecordsError++
                                        if ($result.ErrorMessages.Count -lt 3) {
                                            $errorShort = if ($errorDetails.Length -gt 200) { $errorDetails.Substring(0, 200) + "..." } else { $errorDetails }
                                            $result.ErrorMessages += if ($errorShort) { $errorShort } else { $errorMsg }
                                        }
                                    }
                                }
                            }
                            }
                            
                            # Determinar si la tabla es conocida como no-restaurable
                            if ($knownNonRestorableTables -contains $logicalName -and $result.RecordsSuccess -eq 0) {
                                $result.IsKnownNonRestorable = $true
                            }
                            
                            $result.Success = $true
                            return $result
                            
                        } catch {
                            $result.ErrorMessages += "Error procesando tabla: $($_.Exception.Message)"
                            return $result
                        }
                    } -ArgumentList $filePath, $logicalName, $entitySetName, $localDataverseUrl, $localHeaders, $localUseMarkers, $localBackupId, $localFormulaFields, $localNonRestorableTables
                    
                    $jobs += [PSCustomObject]@{
                        Job = $job
                        LogicalName = $logicalName
                    }
                }
                
                # Esperar jobs (timeout 5min)
                $jobs.Job | Wait-Job -Timeout 300 | Out-Null
                
                foreach ($jobInfo in $jobs) {
                    $tablesProcessed++
                    $result = Receive-Job -Job $jobInfo.Job
                    Remove-Job -Job $jobInfo.Job
                    
                    $strategyIndicator = if ($result.UsedBatchAPI) { "[BATCH]" } else { "[SERIAL]" }
                    Write-Output "    [$tablesProcessed/$totalTablesToProcess] $strategyIndicator $($result.LogicalName)"
                    
                    if ($result.IsEmpty) {
                        Write-Output "        Sin registros"
                        $tablesSuccess++
                    } elseif ($result.Success) {
                        Write-Output "        Registros: $($result.RecordsTotal)"
                        
                        foreach ($errorMsg in $result.ErrorMessages) {
                            Write-Output "          Error: $errorMsg"
                        }
                        
                        if ($result.RecordsError -eq 0) {
                            Write-Output "          $($result.RecordsSuccess)/$($result.RecordsTotal)"
                            $tablesSuccess++
                        } else {
                            if ($result.IsKnownNonRestorable) {
                                Write-Output "           0/$($result.RecordsTotal) (tabla específica del environment)"
                                $skippedKnownTables += $result.LogicalName
                            } else {
                                Write-Output "           $($result.RecordsSuccess)/$($result.RecordsTotal), $($result.RecordsError) errores"
                            }
                            $tablesError++
                        }
                        
                        $totalRecordsRestored += $result.RecordsSuccess
                        $totalRecordsError += $result.RecordsError
                    } else {
                        Write-Output "          Error: $($result.ErrorMessages[0])"
                        $tablesError++
                    }
                }
                
                Write-Output ""
                
                # Verificar token cada 15 grupos (~75 tablas)
                if ((($groupIndex + 1) % 15) -eq 0 -and ($groupIndex + 1) -lt $tableGroups.Count) {
                    $elapsedMinutes = [Math]::Floor(((Get-Date) - $script:tokenObtainedAt).TotalMinutes)
                    Write-Output "  Checkpoint: $elapsedMinutes min transcurridos"
                    if ($elapsedMinutes -ge 50) {
                        Write-Output "  Refrescando token..."
                        Test-AndRefreshToken -DataverseUrl $dataverseUrl
                    }
                    Write-Output ""
                }
            }
            
            # Actualizar estadísticas
            $script:restoreStats.tablesProcessed = $tablesProcessed
            $script:restoreStats.tablesSuccess = $tablesSuccess
            $script:restoreStats.tablesError = $tablesError
            $script:restoreStats.recordsRestored = $totalRecordsRestored
            $script:restoreStats.recordsError = $totalRecordsError
            
            Write-Output ""
            Write-Output "Restore de datos completado"
            
            if ($tablesError -eq $tablesProcessed -and $tablesProcessed -gt 0) {
                throw "Todas las tablas fallaron durante el restore"
            }
            
            Write-DetailedLog "Data restore completed: $totalRecordsRestored records in $tablesSuccess tables" "INFO"
        }
    }
    
} catch {
    $errorMsg = "Error restaurando datos: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "  $errorMsg"
    Write-ErrorDetail $_ "RestoreTables"
    $script:errors += $errorMsg
    Write-Output "  Solución importada, pero restore de datos falló"
}


# ==========================================
# REPORTE FINAL
# ==========================================

Write-Output ""
Write-Output "=========================================="
Write-Output "RESTORE COMPLETADO"
Write-Output "=========================================="

try {
    $endTime = Get-Date
    $duration = $endTime - $script:startTime
    
    # Resumen de operación
    Write-Output "Duración: $([math]::Round($duration.TotalMinutes, 2)) min"
    Write-Output "Solución: $($script:restoreStats.solutionName)"
    
    if ($script:restoreStats.newEnvironmentCreated) {
        Write-Output "Environment: $($script:restoreStats.newEnvironmentName) ($($script:restoreStats.newEnvironmentRegion))"
    }
    
    Write-Output ""
    Write-Output "Resultados:"
    Write-Output "  Tablas: $($script:restoreStats.tablesSuccess)/$($script:restoreStats.tablesProcessed) exitosas"
    Write-Output "  Registros: $($script:restoreStats.recordsRestored)"
    
    if ($script:markerTablesRestored -gt 0) {
        Write-Output "  Marcadores: $($script:markerTablesRestored) tablas restauradas"
    }
    if ($script:filteredTablesRestored -gt 0) {
        Write-Output "  Filtradas: $($script:filteredTablesRestored) tablas restauradas"
    }
    
    if ($script:errors.Count -gt 0) {
        Write-Output ""
        Write-Output "   Errores: $($script:errors.Count)"
    }
    
    # Generar y subir log
    Write-Output ""
    $logData = @{
        timestamp = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
        operation = "Restore"
        status = if ($script:errors.Count -eq 0) { "Success" } else { "Completed with errors" }
        configuration = @{
            backupFileName = $BackupFileName
            restoreMode = $RestoreMode
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
    
    $logFileName = "log_Restore_PP_$(Get-Date -Format 'dd-MM-yyyy HH-mm-ss').json"
    $logFilePath = Join-Path $env:TEMP $logFileName
    $logData | ConvertTo-Json -Depth 10 | Out-File -FilePath $logFilePath -Encoding UTF8
    
    $logBlobPath = if ($script:errors.Count -eq 0) {
        "logs/powerplatform/restore/$logFileName"
    } else {
        "logs/powerplatform/restore/errors/$logFileName"
    }
    
    Set-AzStorageBlobContent -Container "pp-backup" -File $logFilePath -Blob $logBlobPath -Context $ctx -Force | Out-Null
    Write-Output "Log: $logBlobPath"
    
    # Checklist de fórmulas
    if ($script:backupMetadata -and $script:backupMetadata.FormulasRemoved.Count -gt 0) {
        Write-Output ""
        Write-Output "   ACCIÓN REQUERIDA: Recrear $($script:backupMetadata.FormulasRemoved.Count) fórmulas manualmente"
        Write-Output "Campos:"
        foreach ($formulaField in $script:backupMetadata.FormulasRemoved.Fields) {
            Write-Output "  - $formulaField"
        }
        Write-Output "Proceso: Power Apps → Solutions → Campo → Cambiar tipo a 'Formula'"
    }
    
    # Próximos pasos
    Write-Output ""
    Write-Output "PRÓXIMOS PASOS:"
    if ($RestoreMode -eq "NewEnvironment") {
        Write-Output "  1. Verificar solución en Power Apps Maker Portal"
        Write-Output "  2. Probar funcionalidades críticas"
        Write-Output "  3. Verificar flujos de Power Automate"
        Write-Output "  4. Configurar conexiones y permisos"
        if ($script:backupMetadata -and $script:backupMetadata.FormulasRemoved.Count -gt 0) {
            Write-Output "  5. Recrear $($script:backupMetadata.FormulasRemoved.Count) fórmulas manualmente"
        }
    } else {
        Write-Output "  Modo ${RestoreMode}: Solo metadata importada, sin datos"
        Write-Output "  Para restaurar datos: -RestoreMode 'NewEnvironment'"
    }
    
    Write-Output "=========================================="
    
    Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-DetailedLog "Restore completed successfully" "INFO"
    
} catch {
    Write-Output ""
    Write-Output "Error generando reporte final"
    Write-ErrorDetail $_ "GenerateReport"
}

$lockFile = Join-Path $env:TEMP "restore-powerplatform.lock"
Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
Write-Output "Restore finalizado exitosamente"