<#
.SYNOPSIS
    Runbook GENÉRICO para respaldo completo AUTOMÁTICO de Power Platform y Dataverse

.DESCRIPTION
    Este runbook exporta AUTOMÁTICAMENTE cualquier environment SIN PARÁMETROS:
    - TODAS las soluciones unmanaged (auto-detectadas)
    - TODAS las tablas custom (auto-detectadas por IsCustomEntity)
    - Tablas relacionadas (N:1, 1:N - auto-detectadas)
    - Configuración del environment (JSON)
    - Fórmulas eliminadas automáticamente (compatibilidad cross-environment)
    
    100% GENÉRICO - Funciona con CUALQUIER tenant/environment/solución
    sin necesidad de hardcodear nombres, prefijos o parámetros.
    
    EJECUCIÓN AUTOMÁTICA - Sin intervención manual requerida.

.EXAMPLE
    # Ejecutar backup automático (sin parámetros)
    Start-AzAutomationRunbook -Name "Backup-PowerPlatform"
    
    # Programar backup diario
    New-AzAutomationSchedule -AutomationAccountName "AA-PowerPlatform" `
        -Name "Daily-Backup" -StartTime "02:00" -DayInterval 1
    
    Register-AzAutomationScheduledRunbook -RunbookName "Backup-PowerPlatform" `
        -ScheduleName "Daily-Backup"

.NOTES
    Requisitos:
    - Service Principal con permisos en Power Platform
    - Managed Identity con acceso a Storage Account
    - Módulos: Az.Storage, Microsoft.PowerApps.Administration.PowerShell
    - Variables de Automation:
        * PP-OrganizationId (requerido)
        * StorageAccountName (requerido)
        * PP-DataverseUrl (opcional - auto-detect si no existe)
    
    Configuración:
    - IncludeSystemTables: $false (modificar en código si se necesita)
    - CustomPrefixes: @() (vacío = solo IsCustomEntity - 100% genérico)
    
    Versión: 5.0 (100% automático - sin parámetros)
    Fecha: 18 de diciembre de 2025
#>

# ==========================================
# CONFIGURACIÓN INICIAL
# ==========================================

# Configuración de backup (sin parámetros - 100% automático)
$IncludeSystemTables = $false  # Cambiar a $true si se necesitan tablas del sistema
$CustomPrefixes = @()  # Vacío = detectar TODAS las tablas custom (IsCustomEntity)

$ErrorActionPreference = "Continue"
$VerbosePreference = "Continue"
$WarningPreference = "Continue"

$date = Get-Date -Format "dd-MM-yyyy HH-mm-ss"
$tempPath = "$env:TEMP\PowerPlatform_$date"

# Variables de tracking para logs
$script:executionLog = @()
$script:errorDetails = @()

function Write-DetailedLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"  # INFO, SUCCESS, WARNING, ERROR
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Write-Output $logEntry
    Write-Verbose $logEntry
    
    $script:executionLog += @{
        timestamp = $timestamp
        level = $Level
        message = $Message
    }
}

function Write-ErrorDetail {
    param(
        [string]$Step,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )
    
    # Validar que ErrorRecord no sea null
    if (-not $ErrorRecord) {
        Write-DetailedLog "Write-ErrorDetail llamado sin ErrorRecord en paso: $Step" "WARNING"
        return
    }
    
    $errorInfo = @{
        step = $Step
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        message = $ErrorRecord.Exception.Message
        type = $ErrorRecord.Exception.GetType().FullName
        line = $ErrorRecord.InvocationInfo.ScriptLineNumber
        command = $ErrorRecord.InvocationInfo.Line.Trim()
        stackTrace = $ErrorRecord.ScriptStackTrace
        httpStatus = $null
        httpResponse = $null
    }
    
    # Intentar extraer detalles HTTP si es error de API
    if ($ErrorRecord.Exception.Response) {
        try {
            $errorInfo.httpStatus = $ErrorRecord.Exception.Response.StatusCode.value__
            $errorInfo.httpResponse = $ErrorRecord.Exception.Response.StatusDescription
        } catch {
            # Ignorar si no hay detalles HTTP
        }
    }
    
    $script:errorDetails += $errorInfo
    
    Write-DetailedLog "ERROR en $Step" "ERROR"
    Write-DetailedLog "  Mensaje: $($errorInfo.message)" "ERROR"
    Write-DetailedLog "  Tipo: $($errorInfo.type)" "ERROR"
    Write-DetailedLog "  Línea: $($errorInfo.line)" "ERROR"
    if ($errorInfo.httpStatus) {
        Write-DetailedLog "  HTTP Status: $($errorInfo.httpStatus)" "ERROR"
    }
}

Write-Output "======================================"
Write-Output "Inicio de Backup Power Platform"
Write-Output "Fecha: $date"
Write-Output "======================================"


# ==========================================
# PASO 0: VALIDAR ENTORNO
# ==========================================

Write-Output "`n 0/6 Validando entorno de ejecución..."
Write-DetailedLog "PASO 0: Validación de prerequisitos" "INFO"

try {
    # Validar módulos requeridos
    Write-Output "  [0a] Validando módulos de PowerShell..."
    Write-DetailedLog "Verificando módulos requeridos" "INFO"
    
    $requiredModules = @(
        "Az.Accounts",
        "Az.Storage",
        "Microsoft.PowerApps.Administration.PowerShell"
    )
    
    $missingModules = @()
    
    foreach ($moduleName in $requiredModules) {
        Write-Output "    Verificando: $moduleName"
        $module = Get-Module -ListAvailable -Name $moduleName -ErrorAction SilentlyContinue
        
        if ($module) {
            Write-Output "       Disponible: v$($module.Version)"
            Write-DetailedLog "  Módulo $moduleName disponible: v$($module.Version)" "SUCCESS"
        } else {
            Write-Output "       NO ENCONTRADO: $moduleName"
            Write-DetailedLog "  Módulo $moduleName NO ENCONTRADO" "ERROR"
            $missingModules += $moduleName
        }
    }
    
    if ($missingModules.Count -gt 0) {
        Write-Output ""
        Write-Output "  MÓDULOS FALTANTES:"
        foreach ($missing in $missingModules) {
            Write-Output "    - $missing"
        }
        Write-Output ""
        Write-Output "  SOLUCIÓN:"
        Write-Output "    1. Ve a: Azure Portal → Automation Account → Modules"
        Write-Output "    2. Click 'Browse gallery'"
        Write-Output "    3. Importa cada módulo faltante"
        Write-Output "    4. Espera a que Status = 'Available'"
        Write-Output ""
        throw "Módulos requeridos no están disponibles. Importa los módulos antes de ejecutar."
    }
    
    Write-Output "  Todos los módulos requeridos están disponibles"
    Write-DetailedLog "Validación de módulos completada" "SUCCESS"
    
    # Validar contexto de Automation
    Write-Output ""
    Write-Output "  [0b] Validando contexto de Azure Automation..."
    Write-DetailedLog "Validando contexto de ejecución" "INFO"
    
    if ($env:AUTOMATION_ASSET_ACCOUNTID) {
        Write-Output "    Ejecutando en Azure Automation Account"
        Write-Output "      Account ID: $env:AUTOMATION_ASSET_ACCOUNTID"
        Write-DetailedLog "  Contexto: Azure Automation (Account ID: $env:AUTOMATION_ASSET_ACCOUNTID)" "SUCCESS"
    } else {
        Write-Output "    NO ejecutando en Azure Automation (test local?)"
        Write-DetailedLog "  Contexto: Ejecución local/manual" "WARNING"
    }
    
    Write-Output ""
    Write-Output "  Validación de entorno completada"
    Write-DetailedLog "Prerequisitos validados exitosamente" "SUCCESS"
    
  } catch {
    Write-ErrorDetail "Paso 0 - Validación de Entorno" $_
    Write-Output ""
    Write-Output "FALLO EN VALIDACIÓN DE ENTORNO"
    Write-Output "  No se puede continuar sin los módulos requeridos"
    Write-Output ""
    throw
  }
  
  # Ahora SÍ activar ErrorActionPreference = Stop
  $ErrorActionPreference = "Stop"
Write-DetailedLog "ErrorActionPreference establecido en 'Stop'" "INFO"

try {
    # ==========================================
    # 1. LEER VARIABLES DE AUTOMATION
    # ==========================================
    
    Write-Output "`n[1/6] Leyendo configuración..."
    Write-DetailedLog "PASO 1: Leyendo variables de Automation Account" "INFO"
    
    try {
        # Leer Credential
        Write-DetailedLog "Obteniendo credential: PP-ServicePrincipal" "INFO"
        Write-Output "    Leyendo: PP-ServicePrincipal (Credential)"
        
        $credential = Get-AutomationPSCredential -Name "PP-ServicePrincipal" -ErrorAction Stop
        
        if (-not $credential) {
            throw "Credential PP-ServicePrincipal no existe o es null"
        }
        
        $appId = $credential.UserName
        $clientSecret = $credential.GetNetworkCredential().Password
        
        if ([string]::IsNullOrEmpty($clientSecret)) {
            throw "Client Secret en PP-ServicePrincipal está vacío"
        }
        
        Write-Output "      Obtenido: (${clientSecret.Length} caracteres)"
        Write-DetailedLog "  Client Secret obtenido (${clientSecret.Length} chars)" "SUCCESS"
        
        # Leer TenantId
        Write-DetailedLog "Obteniendo variable: PP-ServicePrincipal-TenantId" "INFO"
        $tenantId = Get-AutomationVariable -Name "PP-ServicePrincipal-TenantId" -ErrorAction Stop
        Write-DetailedLog "  TenantId obtenido: $($tenantId.Substring(0,8))..." "SUCCESS"
        
        # Leer Organization ID
        Write-DetailedLog "Obteniendo variable: PP-OrganizationId" "INFO"
        $organizationId = Get-AutomationVariable -Name "PP-OrganizationId" -ErrorAction Stop
        Write-DetailedLog "  Organization ID: $organizationId" "SUCCESS"
        
        # Leer Dataverse URL (OPCIONAL - si no existe, se usa Discovery Service)
        Write-DetailedLog "Obteniendo variable: PP-DataverseUrl (opcional)" "INFO"
        $dataverseUrl = Get-AutomationVariable -Name "PP-DataverseUrl" -ErrorAction SilentlyContinue
        if ($dataverseUrl) {
            Write-DetailedLog "  Dataverse URL: $dataverseUrl" "SUCCESS"
        } else {
            Write-DetailedLog "  ⚠ Dataverse URL no configurada, usando Discovery Service" "WARNING"
        }
        
        # Leer Storage Account Name
        Write-DetailedLog "Obteniendo variable: StorageAccountName" "INFO"
        $storageAccountName = Get-AutomationVariable -Name "StorageAccountName" -ErrorAction Stop
        Write-DetailedLog "  Storage Account: $storageAccountName" "SUCCESS"
        
        Write-Output "  Variables cargadas exitosamente"
        Write-Output "    - Tenant: $($tenantId.Substring(0,8))..."
        Write-Output "    - App ID: $($appId.Substring(0,8))..."
        Write-Output "    - Organization ID: $organizationId"
        Write-Output "    - Storage: $storageAccountName"
        if ($dataverseUrl) {
            Write-Output "    - Dataverse URL: $dataverseUrl (configurado)"
        } else {
            Write-Output "    - Dataverse URL: (auto-detectar via Discovery Service)"
        }
        
        Write-Output ""
        Write-Output "  🤖 MODO: Backup automático completo (sin parámetros)"
        Write-Output "    - Todas las soluciones custom → auto-detect"
        Write-Output "    - Todas las tablas custom → auto-detect (IsCustomEntity)"
        Write-Output "    - Tablas relacionadas → auto-detect (N:1, 1:N)"
        Write-Output "    - Tablas del sistema → $(if ($IncludeSystemTables) { 'Incluidas' } else { 'Excluidas' })"
        Write-Output "    - Fórmulas → Eliminadas automáticamente"
        
    } catch {
        Write-ErrorDetail "Paso 1 - Leer Variables" $_
        Write-Output ""
        Write-Output "[PASO 1 ERROR] No se pudieron leer variables de Automation"
        Write-Output "Variable problemática: $($_.Exception.ItemName)"
        Write-Output ""
        Write-Output "Posibles causas:"
        Write-Output "  1. Variable no existe en Automation Account"
        Write-Output "  2. Nombre de variable incorrecto (case-sensitive)"
        Write-Output "  3. Credential no configurado"
        Write-Output ""
        throw
    }
    
    # ==========================================
    # 2. CONECTAR A POWER PLATFORM Y AZURE
    # ==========================================
    
    Write-Output "`n[2/6] Conectando a Azure y Power Platform..."
    Write-DetailedLog "PASO 2: Autenticación en servicios cloud" "INFO"
    
    try {
        # Conectar a Azure con Managed Identity (requerido para Get-AzAccessToken)
        Write-Output "  [2a] Autenticando con Managed Identity..."
        Write-DetailedLog "Conectando a Azure con Managed Identity" "INFO"
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Output "    Conectado a Azure con Managed Identity"
        
        # Convertir Client Secret a SecureString
        $securePassword = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($appId, $securePassword)
        
        # Conectar a Power Platform con Service Principal
        Write-Output "  [2b] Conectando a Power Platform..."
        Add-PowerAppsAccount -TenantID $tenantId -ApplicationId $appId -ClientSecret $clientSecret
        
        Write-Output "  Conectado a Power Platform"
        Write-Output "    - Tenant: $tenantId"
        Write-Output "    - App ID: $appId"
        Write-Output "    - Organization ID: $organizationId"
    } catch {
        Write-Output "[PASO 2 ERROR] Fallo en conexión a Azure/Power Platform"
        Write-Output "Detalle: $($_.Exception.Message)"
        Write-Output "Tenant ID: $tenantId"
        Write-Output "App ID: $appId"
        Write-Output "Posibles causas:"
        Write-Output "  1. Managed Identity no habilitada en Automation Account"
        Write-Output "  2. Service Principal sin permisos en Power Platform"
        Write-Output "  3. Client Secret incorrecto o expirado"
        Write-Output "  4. Tenant ID incorrecto"
        throw
    }
    
    # ==========================================
    # 3. EXPORTAR SOLUCIONES (AUTO-DETECT)
    # ==========================================
    
    Write-Output "`n[3/6] Exportando soluciones custom (auto-detección)..."
    Write-DetailedLog "PASO 3: Exportar soluciones de Power Platform" "INFO"
    
    try {
        Write-DetailedLog "Creando directorio temporal: $tempPath" "INFO"
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        Write-DetailedLog "  ✓ Directorio temporal creado" "SUCCESS"
        
        # Obtener Dataverse URL dinámicamente desde Power Platform API
        Write-Output "  Obteniendo información del environment..."
        
        try {
            # ESTRATEGIA 1: Discovery Service (100% automático - método preferido)
            Write-Output "  [3a] Intentando obtener Dataverse URL via Discovery Service..."
            
            try {
                # Obtener token para Discovery Service
                $discoveryTokenBody = @{
                    client_id = $appId
                    client_secret = $clientSecret
                    scope = "https://globaldisco.crm.dynamics.com/.default"
                    grant_type = "client_credentials"
                }
                $discoveryTokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
                
                Write-DetailedLog "Solicitando token para Discovery Service" "INFO"
                Write-DetailedLog "  Scope: globaldisco.crm.dynamics.com/.default" "INFO"
                
                $discoveryTokenResponse = Invoke-RestMethod -Uri $discoveryTokenUrl -Method Post -Body $discoveryTokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                
                Write-DetailedLog "  Token de Discovery Service obtenido" "SUCCESS"
                
                # Consultar Discovery Service para listar todas las orgs
                $discoveryHeaders = @{
                    "Authorization" = "Bearer $($discoveryTokenResponse.access_token)"
                    "Accept" = "application/json"
                }
                
                $discoveryUrl = "https://globaldisco.crm.dynamics.com/api/discovery/v2.0/Instances"
                
                Write-DetailedLog "Consultando Discovery Service: $discoveryUrl" "INFO"
                
                $instances = Invoke-RestMethod -Uri $discoveryUrl -Method Get -Headers $discoveryHeaders -ErrorAction Stop
                
                # Buscar environment por Organization ID
                $instance = $instances.value | Where-Object { $_.Id -eq $organizationId }
                
                if ($instance) {
                    $dataverseUrl = $instance.Url
                    Write-Output "    ✓ Dataverse URL obtenida via Discovery Service (automático)"
                    Write-Output "      Environment: $($instance.FriendlyName)"
                    Write-Output "      URL: $dataverseUrl"
                    Write-Output "      Región: $($instance.Region)"
                    Write-DetailedLog "  Dataverse URL: $dataverseUrl (Discovery Service)" "SUCCESS"
                } else {
                    Write-Output "    ⚠ Organization ID $organizationId no encontrado en Discovery Service"
                    Write-Output "      (Verifica el ID en Power Platform Admin Center → Details → Id. de la organización)"
                    Write-Output "      Environments disponibles: $($instances.value.Count)"
                    Write-Output "      Environments encontrados:"
                    foreach ($env in $instances.value) {
                        Write-Output "        - $($env.FriendlyName) (ID: $($env.Id))"
                    }
                    throw "Organization ID no encontrado en Discovery Service"
                }
                
            } catch {
                Write-Output "    ⚠ Discovery Service no disponible: $($_.Exception.Message)"
                Write-DetailedLog "Discovery Service falló, intentando fallback" "WARNING"
                
                # ESTRATEGIA 2: Power Platform Management API (fallback)
                Write-Output "  [3b] Intentando Power Platform Management API (fallback)..."
                
                $ppTokenBody = @{
                    client_id = $appId
                    client_secret = $clientSecret
                    scope = "https://service.powerapps.com/.default"
                    grant_type = "client_credentials"
                }
                $ppTokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
                
                try {
                    Write-DetailedLog "Solicitando token para Power Platform Management API" "INFO"
                    Write-DetailedLog "  Scope: service.powerapps.com/.default" "INFO"
                    
                    $ppTokenResponse = Invoke-RestMethod -Uri $ppTokenUrl -Method Post -Body $ppTokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                    $ppToken = $ppTokenResponse.access_token
                    
                    Write-DetailedLog "  Token de Power Platform API obtenido" "SUCCESS"
                    
                    $ppApiUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$organizationId`?api-version=2020-10-01"
                    $ppHeaders = @{
                        "Authorization" = "Bearer $ppToken"
                        "Accept" = "application/json"
                    }
                    
                    Write-DetailedLog "Consultando: $ppApiUrl" "INFO"
                    
                    $envInfo = Invoke-RestMethod -Uri $ppApiUrl -Method Get -Headers $ppHeaders -ErrorAction Stop
                    $dataverseUrlFromApi = $envInfo.properties.linkedEnvironmentMetadata.instanceUrl
                    
                    if (-not [string]::IsNullOrEmpty($dataverseUrlFromApi)) {
                        $dataverseUrl = $dataverseUrlFromApi
                        Write-Output "    ✓ Dataverse URL obtenida via Power Platform API (fallback)"
                        Write-Output "      URL: $dataverseUrl"
                        Write-DetailedLog "  Dataverse URL: $dataverseUrl (Power Platform API)" "SUCCESS"
                    } else {
                        throw "API no devolvió instanceUrl en response"
                    }
                    
                } catch {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    Write-Output "    ✗ Power Platform API también falló:"
                    Write-Output "      HTTP Status: $statusCode"
                    Write-Output "      Mensaje: $($_.Exception.Message)"
                    
                    if ($statusCode -eq 403) {
                        Write-Output "      CAUSA: Service Principal necesita permisos de API"
                    }
                    
                    throw
                }
            }
            
        } catch {
            # ESTRATEGIA 3: Variable PP-DataverseUrl (último recurso)
            Write-Output "  [3c] Usando variable PP-DataverseUrl (último recurso)..."
            Write-Output "  URL de variable: $dataverseUrl"
            Write-DetailedLog "  Usando URL de variable de Automation (fallback manual)" "WARNING"
        }
        
        Write-Output "  Dataverse URL final: $dataverseUrl"
        
        # Obtener token de acceso para Dataverse usando Service Principal
        Write-Output "  [3a] Obteniendo token de acceso para Dataverse..."
        Write-DetailedLog "Obteniendo token de acceso para Dataverse API" "INFO"
        Write-DetailedLog "  Scope: $dataverseUrl/.default" "INFO"
        
        # Construir el cuerpo de la solicitud OAuth2
        $tokenBody = @{
            client_id = $appId
            client_secret = $clientSecret
            scope = "$dataverseUrl/.default"
            grant_type = "client_credentials"
        }
        
        $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
        $accessToken = $tokenResponse.access_token
        
        Write-Output "    Token obtenido exitosamente"
        
        # Headers para API de Dataverse
        $headers = @{
            "Authorization" = "Bearer $accessToken"
            "Content-Type" = "application/json"
            "OData-MaxVersion" = "4.0"
            "OData-Version" = "4.0"
            "Accept" = "application/json"
        }
        
        # Paso 1: AUTO-DETECTAR TODAS LAS SOLUCIONES CUSTOM
        Write-Output "  [3b] Auto-detectando TODAS las soluciones custom del environment..."
        Write-DetailedLog "Auto-detección de soluciones custom" "INFO"
        
        # Obtener todas las soluciones unmanaged (custom) excluyendo Default y System
        $allSolutionsQuery = "$dataverseUrl/api/data/v9.2/solutions?`$filter=ismanaged eq false and uniquename ne 'Default' and uniquename ne 'Active'&`$select=solutionid,uniquename,friendlyname,version,publisherid&`$orderby=createdon desc"
        
        Write-DetailedLog "Consultando: $allSolutionsQuery" "INFO"
        $allSolutionsResponse = Invoke-RestMethod -Uri $allSolutionsQuery -Method Get -Headers $headers
        
        # Filtrar soluciones del sistema
        $customSolutions = $allSolutionsResponse.value | Where-Object {
            $_.uniquename -notlike "System*" -and
            $_.uniquename -notlike "msdyn_*" -and
            $_.uniquename -notlike "mspp_*" -and
            $_.uniquename -ne "Basic" -and
            $_.uniquename -ne "DefaultSolution" -and
            $_.friendlyname -notlike "*Default Solution*" -and  # Filtrar "Common Data Services Default Solution" y similares
            $_.uniquename -notlike "Cr*"  # Filtrar soluciones generadas automáticamente con prefijo Cr (Common Runtime)
        }
        
        if ($customSolutions.Count -eq 0) {
            Write-Output "    ⚠ No se encontraron soluciones custom en el environment"
            Write-Output "      Solo hay soluciones del sistema (Default, System*, etc.)"
            Write-DetailedLog "No hay soluciones custom para exportar" "WARNING"
            $solutionsToExport = @()
        } else {
            Write-Output "    ✓ Soluciones custom encontradas: $($customSolutions.Count)"
            Write-DetailedLog "Soluciones custom detectadas: $($customSolutions.Count)" "SUCCESS"
            
            $solutionsToExport = @()
            
            foreach ($sol in $customSolutions) {
                $solutionsToExport += $sol.uniquename
                Write-Output "      • $($sol.friendlyname) ($($sol.uniquename)) - v$($sol.version)"
                Write-DetailedLog "  Solución: $($sol.uniquename) v$($sol.version)" "INFO"
            }
        }
        
        # Reporte adicional: Analizar componentes en todas las soluciones
        $script:pcfControlsInSolution = @()
        $script:totalComponentsCount = 0
        
        try {
            Write-Output "    [INFO] Analizando componentes del environment..."
            
            # Obtener todos los custom controls (componenttype=66)
            $customControlsUrl = "$dataverseUrl/api/data/v9.2/customcontrols?`$select=name,version"
            $customControlsResponse = Invoke-RestMethod -Uri $customControlsUrl -Method Get -Headers $headers -ErrorAction SilentlyContinue
            
            if ($customControlsResponse.value.Count -gt 0) {
                Write-Output "      • Custom Controls (PCF): $($customControlsResponse.value.Count)"
                foreach ($ctrl in $customControlsResponse.value) {
                    $script:pcfControlsInSolution += "$($ctrl.name) (v$($ctrl.version))"
                }
            }
            
            # Contar componentes totales en todas las soluciones custom
            foreach ($sol in $customSolutions) {
                $componentsUrl = "$dataverseUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $($sol.solutionid)&`$select=componenttype"
                $components = Invoke-RestMethod -Uri $componentsUrl -Method Get -Headers $headers -ErrorAction SilentlyContinue
                $script:totalComponentsCount += $components.value.Count
            }
            
            Write-Output "      • Componentes totales en soluciones: $script:totalComponentsCount"
            
        } catch {
            Write-Output "    [INFO] No se pudo obtener detalle completo de componentes"
        }
        
        # Paso 2: Exportar todas las soluciones (principal + PCF)
        Write-Output "  [3c] Exportando soluciones (esto puede tardar 1-3 minutos)..."
        Write-Output "    Total soluciones a exportar: $($solutionsToExport.Count)"
        $exportApiUrl = "$dataverseUrl/api/data/v9.2/ExportSolution"
        
        $exportedCount = 0
        
        foreach ($solToExport in $solutionsToExport) {
            Write-Output "    • Exportando: $solToExport"
            Write-DetailedLog "Exportando solución: $solToExport" "INFO"
            
            try {
                Write-DetailedLog "  Construyendo payload ExportSolution para $solToExport" "INFO"
                $exportBody = @{
                    SolutionName = $solToExport
                    Managed = $false  # ← CAMBIADO: Exportar como UNMANAGED para compatibilidad con restore
                    ExportAutoNumberingSettings = $false
                    ExportCalendarSettings = $false
                    ExportCustomizationSettings = $false
                    ExportEmailTrackingSettings = $false
                    ExportGeneralSettings = $false
                    ExportMarketingSettings = $false
                    ExportOutlookSynchronizationSettings = $false
                    ExportRelationshipRoles = $false
                    ExportIsvConfig = $false
                    ExportSales = $false
                    ExportExternalApplications = $false
                } | ConvertTo-Json
                
                $exportResponse = Invoke-RestMethod -Uri $exportApiUrl -Method Post -Headers $headers -Body $exportBody
                $solutionZipBase64 = $exportResponse.ExportSolutionFile
                
                if ([string]::IsNullOrEmpty($solutionZipBase64)) {
                    Write-Output "      Sin datos para '$solToExport'"
                    continue
                }
                
                # Decodificar y guardar temporalmente
                $solutionPath = "$tempPath\$solToExport.zip"
                $solutionBytes = [System.Convert]::FromBase64String($solutionZipBase64)
                [System.IO.File]::WriteAllBytes($solutionPath, $solutionBytes)
                
                $solSize = [Math]::Round((Get-Item $solutionPath).Length / 1MB, 2)
                Write-Output "      Exportado: $solSize MB"
                
                # WORKAROUND AUTOMÁTICO: Eliminar fórmulas para compatibilidad cross-environment
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $testZip = [System.IO.Compression.ZipFile]::OpenRead($solutionPath)
                    $hasFormulas = ($testZip.Entries | Where-Object { $_.FullName -like "Formulas/*" }).Count -gt 0
                    $formulasCount = ($testZip.Entries | Where-Object { $_.FullName -like "Formulas/*" }).Count
                    $testZip.Dispose()
                    
                    # Variable para indicar si necesitamos procesar esta solución
                    $needsProcessing = $false
                    $processingReason = ""
                    
                    if ($hasFormulas) {
                        $needsProcessing = $true
                        $processingReason = "⚠ Detectadas $formulasCount fórmulas - aplicando workaround..."
                    } elseif ($script:formulaFieldsToExclude.Count -gt 0) {
                        # Incluso si esta solución no tiene Formulas/, puede tener referencias a campos de fórmula
                        $needsProcessing = $true
                        $processingReason = "⚠ Limpiando referencias a campos de fórmula removidos..."
                    }
                    
                    if ($needsProcessing) {
                        Write-Output "      $processingReason"
                        
                        # Extraer ZIP completo
                        $tempExtractDir = "$tempPath\${solToExport}_extract"
                        [System.IO.Compression.ZipFile]::ExtractToDirectory($solutionPath, $tempExtractDir)
                        
                        # 1. Eliminar carpeta Formulas/ (si existe)
                        $formulasPath = Join-Path $tempExtractDir "Formulas"
                        if (Test-Path $formulasPath) {
                            Remove-Item $formulasPath -Recurse -Force
                        }
                        
                        # 2. Limpiar customizations.xml para eliminar referencias a fórmulas
                        $customizationsXmlPath = Join-Path $tempExtractDir "customizations.xml"
                        
                        # Inicializar array si esta es la primera solución con fórmulas
                        if (-not $script:formulaFieldsToExclude) {
                            $script:formulaFieldsToExclude = @()
                        }
                        
                        if (Test-Path $customizationsXmlPath) {
                            [xml]$customXml = Get-Content $customizationsXmlPath -Raw
                            
                            # PASO 2A: Identificar todos los atributos de fórmula (solo si esta solución tiene Formulas/)
                            if ($hasFormulas) {
                                $formulaAttributes = $customXml.SelectNodes("//attribute[FormulaDefinitionFileName]")
                                $removedCount = 0
                                
                                foreach ($attr in $formulaAttributes) {
                                    # Guardar el nombre del campo (LogicalName) para filtrar datos después
                                    $fieldLogicalName = $attr.SelectSingleNode("LogicalName")
                                    if ($fieldLogicalName -and $fieldLogicalName.InnerText) {
                                        if ($script:formulaFieldsToExclude -notcontains $fieldLogicalName.InnerText) {
                                            $script:formulaFieldsToExclude += $fieldLogicalName.InnerText
                                        }
                                    }
                                    
                                    # Eliminar el nodo completo del atributo de fórmula
                                    $attr.ParentNode.RemoveChild($attr) | Out-Null
                                    $removedCount++
                                }
                                
                                if ($removedCount -gt 0) {
                                    Write-Output "        → Eliminados $removedCount campos de fórmula: $($script:formulaFieldsToExclude -join ', ')"
                                }
                            }
                            
                            # PASO 2B: Limpiar referencias en vistas (SavedQueries) - para TODAS las soluciones
                            if ($script:formulaFieldsToExclude.Count -gt 0) {
                                $cleanedReferences = 0
                                
                                foreach ($fieldName in $script:formulaFieldsToExclude) {
                                    # 1. Eliminar celdas en layoutxml de vistas
                                    $cellNodes = $customXml.SelectNodes("//savedquery//layoutxml//cell[@name='$fieldName']")
                                    foreach ($cell in $cellNodes) {
                                        $cell.ParentNode.RemoveChild($cell) | Out-Null
                                        $cleanedReferences++
                                    }
                                    
                                    # 2. Eliminar atributos en fetchxml de vistas
                                    $attrNodes = $customXml.SelectNodes("//savedquery//fetch//attribute[@name='$fieldName']")
                                    foreach ($attrNode in $attrNodes) {
                                        $attrNode.ParentNode.RemoveChild($attrNode) | Out-Null
                                        $cleanedReferences++
                                    }
                                    
                                    # 3. Eliminar referencias en color
                                    $colorNodes = $customXml.SelectNodes("//savedquery//layoutxml//color[text()='$fieldName']")
                                    foreach ($colorNode in $colorNodes) {
                                        $colorNode.ParentNode.RemoveChild($colorNode) | Out-Null
                                        $cleanedReferences++
                                    }
                                    
                                    # 4. Eliminar referencias en parámetros de PCF controls
                                    $pcfParamNodes = $customXml.SelectNodes("//savedquery//layoutxml//controlDescription//parameters//*[text()='$fieldName']")
                                    foreach ($pcfParam in $pcfParamNodes) {
                                        $pcfParam.ParentNode.RemoveChild($pcfParam) | Out-Null
                                        $cleanedReferences++
                                    }
                                    
                                    # 5. Eliminar referencias en columnwidths
                                    $colWidthNodes = $customXml.SelectNodes("//savedquery//columnwidths/column[@name='$fieldName']")
                                    foreach ($colWidth in $colWidthNodes) {
                                        $colWidth.ParentNode.RemoveChild($colWidth) | Out-Null
                                        $cleanedReferences++
                                    }
                                    
                                    # 6. Eliminar de filtros (filter conditions)
                                    $filterNodes = $customXml.SelectNodes("//savedquery//fetch//filter/condition[@attribute='$fieldName']")
                                    foreach ($filterNode in $filterNodes) {
                                        $filterNode.ParentNode.RemoveChild($filterNode) | Out-Null
                                        $cleanedReferences++
                                    }
                                    
                                    # 7. Eliminar de order (ordenamiento)
                                    $orderNodes = $customXml.SelectNodes("//savedquery//fetch//order[@attribute='$fieldName']")
                                    foreach ($orderNode in $orderNodes) {
                                        $orderNode.ParentNode.RemoveChild($orderNode) | Out-Null
                                        $cleanedReferences++
                                    }
                                }
                                
                                if ($cleanedReferences -gt 0) {
                                    # Guardar XML modificado
                                    $customXml.Save($customizationsXmlPath)
                                    Write-Output "        → Limpiadas $cleanedReferences referencias en vistas y queries"
                                }
                            }
                        }
                        
                        # 3. Re-comprimir sin fórmulas
                        Remove-Item $solutionPath -Force
                        [System.IO.Compression.ZipFile]::CreateFromDirectory($tempExtractDir, $solutionPath)
                        
                        # Limpiar directorio temporal
                        Remove-Item $tempExtractDir -Recurse -Force
                        
                        $newSize = [Math]::Round((Get-Item $solutionPath).Length / 1MB, 2)
                        Write-Output "      ✓ Procesamiento completado (compatibilidad cross-environment)"
                        if ($hasFormulas) {
                            Write-Output "        Tamaño: $solSize MB → $newSize MB"
                        }
                    }
                } catch {
                    Write-Output "      ⚠ No se pudo procesar fórmulas: $($_.Exception.Message)"
                    Write-Output "        Continuando con solución original..."
                }
                
                $exportedCount++
                
            } catch {
                Write-Output "      Error: $($_.Exception.Message)"
            }
        }
        
        Write-Output "  Soluciones exportadas: $exportedCount de $($solutionsToExport.Count)"
        Write-DetailedLog "Exportación de soluciones completada: $exportedCount exportadas" "SUCCESS"
        
    } catch {
        Write-Output "[PASO 3 ERROR] Fallo al exportar soluciones"
        Write-Output "Detalle: $($_.Exception.Message)"
        Write-Output "Organization ID: $organizationId"
        Write-Output "Dataverse URL: $dataverseUrl"
        Write-Output "Posibles causas:"
        Write-Output "  1. No hay soluciones custom en el environment"
        Write-Output "  2. Service Principal sin rol 'System Administrator' en Dataverse"
        Write-Output "  3. Token de acceso expirado o inválido"
        Write-Output "  4. Environment no tiene Dataverse habilitado"
        throw
    }
    
    # ==========================================
    # 4. EXPORTAR DATOS (TABLAS CRÍTICAS)
    # ==========================================
    
    Write-Output "`n[4/6] Exportando datos de tablas críticas..."
    Write-DetailedLog "PASO 4: Exportar datos de tablas Dataverse" "INFO"
    
    try {
        Write-Output "  Dataverse URL: $dataverseUrl"
        
        # LISTA DE EXCLUSIÓN MÍNIMA: Solo tablas core del sistema sin datos de negocio
        # 
        # ESTRATEGIA DE BACKUP:
        #   ✅ BACKUP COMPLETO: Exportar TODO (incluye appaction*, aiplugin*, agent*, etc.)
        #   🚫 RESTORE INTELIGENTE: Filtro automático en Restore-PowerPlatform.ps1
        # 
        # Las 32 tablas system-managed (appaction*, aiplugin*, agent*) se EXPORTAN
        # pero el runbook de restore las FILTRA automáticamente (no intenta importarlas)
        # 
        $systemTablesToExclude = @(
            # Core system tables (no contienen datos de negocio)
            'activityparty',           # Gestionada automáticamente (relaciones de actividades)
            'activitypointer',         # Tabla virtual base de todas las actividades
            'asyncoperation',          # Jobs y procesos del sistema
            'bulkdeletefailure',       # Logs de operaciones de eliminación masiva
            'duplicaterecord',         # Sistema de detección de duplicados
            'principalobjectattributeaccess',  # Control de acceso a nivel de campo
            'syncerror',               # Errores de sincronización del sistema
            'processsession',          # Sesiones de workflows/procesos
            'workflowlog',             # Logs de workflows
            'plugintracelog',          # Logs de plugins
            'organizationstatistic',   # Estadísticas del sistema
            'systemuser',              # Usuarios del sistema (mejor gestionar via AAD)
            'team',                    # Equipos (mejor gestionar via UI)
            'businessunit',            # Unidades de negocio (estructura org)
            'organization'             # Configuración de la organización
        )
        
        # NOTA: Las siguientes tablas SE EXPORTAN en el backup (para auditoría completa)
        # pero el runbook Restore-PowerPlatform.ps1 las FILTRA automáticamente:
        #   - appaction* (Command Bar - 5 tablas, ~5,300 registros)
        #   - aicopilot (AI Copilot - 2 registros)
        #   - aiplugin* (AI Plugins - 15 tablas)
        #   - agent* (Agent System - 8 tablas)
        #   - aiskillconfig, allowedmcpclient
        # Total: 32 tablas adicionales en backup, 0 en restore (filtradas automáticamente)
        
        Write-Output "  ⚠ Tablas del sistema excluidas: $($systemTablesToExclude.Count)"
        Write-DetailedLog "Tablas del sistema que serán excluidas del backup: $($systemTablesToExclude -join ', ')" "INFO"
        
        # AUTO-DETECTAR TODAS LAS TABLAS CUSTOM
        Write-Output "  [4a] Auto-detectando TODAS las tablas custom del environment..."
        Write-DetailedLog "Auto-detección de tablas custom" "INFO"
        
        # Obtener todas las tablas del environment
        $allTablesMetadata = "$dataverseUrl/api/data/v9.2/EntityDefinitions?`$select=LogicalName,EntitySetName,IsCustomEntity,IsCustomizable&`$filter=IsCustomEntity eq true or IsCustomizable/Value eq true"
        
        Write-DetailedLog "Consultando metadata de tablas: $allTablesMetadata" "INFO"
        $allTablesResponse = Invoke-RestMethod -Uri $allTablesMetadata -Method Get -Headers $headers
        
        # ESTRATEGIA DE DETECCIÓN GENÉRICA
        if ($CustomPrefixes.Count -gt 0) {
            # Si hay prefijos especificados, filtrar por prefijos + IsCustomEntity
            Write-Output "    Estrategia: Prefijos ($($CustomPrefixes -join ', ')) + IsCustomEntity"
            
            $customTablesByPrefix = $allTablesResponse.value | Where-Object {
                $tableName = $_.LogicalName
                $matchesPrefix = $false
                foreach ($prefix in $CustomPrefixes) {
                    if ($tableName -like "$prefix*") {
                        $matchesPrefix = $true
                        break
                    }
                }
                $matchesPrefix
            }
            
            $customTablesByFlag = $allTablesResponse.value | Where-Object { $_.IsCustomEntity -eq $true }
            
            # Combinar ambos criterios (unión)
            $allCustomTables = @()
            $allCustomTables += $customTablesByPrefix
            $allCustomTables += $customTablesByFlag
            $allCustomTables = $allCustomTables | Select-Object -Unique -Property LogicalName, EntitySetName, IsCustomEntity
            
        } else {
            # Sin prefijos = SOLO IsCustomEntity (100% genérico)
            Write-Output "    Estrategia: Solo IsCustomEntity (genérico para cualquier tenant)"
            
            $allCustomTables = $allTablesResponse.value | Where-Object { 
                $_.IsCustomEntity -eq $true 
            }
        }
        
        # Excluir solo tablas en la lista de exclusión (sin wildcards)
        # Permitir exportar appaction*, aiplugin*, etc. - se manejan errores en restore
        $criticalTables = $allCustomTables | Where-Object {
            $systemTablesToExclude -notcontains $_.LogicalName
        } | Select-Object -ExpandProperty LogicalName
        
        Write-Output "    ✓ Tablas custom encontradas: $($criticalTables.Count)"
        Write-DetailedLog "Tablas custom detectadas: $($criticalTables.Count)" "SUCCESS"
        
        foreach ($table in $criticalTables) {
            Write-Output "      • $table"
        }
        
        # Agregar tablas del sistema si se solicitó
        if ($IncludeSystemTables) {
            Write-Output ""
            Write-Output "  [4a.1] Agregando tablas del sistema esenciales (parámetro IncludeSystemTables=true)..."
            
            $essentialSystemTables = @("account", "contact", "appointment", "task", "email")
            foreach ($sysTable in $essentialSystemTables) {
                if ($criticalTables -notcontains $sysTable) {
                    $criticalTables += $sysTable
                    Write-Output "      • $sysTable (sistema)"
                }
            }
            
            Write-DetailedLog "Tablas del sistema agregadas: $($essentialSystemTables.Count)" "INFO"
        }
        
        Write-Output ""
        Write-Output "  [4b] Detectando relaciones y obteniendo EntitySetNames..."
        
        # Mapa de LogicalName → EntitySetName (necesario para queries OData)
        $tableNameMap = @{}
        
        # Obtener EntitySetName para cada tabla crítica
        foreach ($table in $criticalTables) {
            try {
                $metadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$table')?`$select=LogicalName,EntitySetName"
                $entityDef = Invoke-RestMethod -Uri $metadataUrl -Method Get -Headers $headers -ErrorAction Stop
                $tableNameMap[$table] = $entityDef.EntitySetName
                Write-Output "    • $table → $($entityDef.EntitySetName)"
            } catch {
                # Fallback: asumir plural con 's' si falla
                $tableNameMap[$table] = "${table}s"
                Write-Output "    • $table → ${table}s (fallback)"
            }
        }
        
        $allTablesToExport = @($criticalTables)
        $relatedTablesFound = @()
        
        foreach ($table in $criticalTables) {
            try {
                # === RELACIONES N:1 (Many-to-One) - Tablas padre ===
                # Obtener tablas que las críticas REFERENCIAN (lookups en tablas críticas)
                $n1Url = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$table')/ManyToOneRelationships?`$select=ReferencedEntity,ReferencingEntity"
                
                $n1Relationships = Invoke-RestMethod -Uri $n1Url -Method Get -Headers $headers -ErrorAction SilentlyContinue
                
                foreach ($rel in $n1Relationships.value) {
                    $relatedTable = $rel.ReferencedEntity
                    
                    # FILTRADO MEJORADO: Excluir tablas del sistema
                    if ($relatedTable -and 
                        $relatedTable -notlike 'system*' -and
                        $systemTablesToExclude -notcontains $relatedTable -and
                        $allTablesToExport -notcontains $relatedTable) {
                        
                        # Obtener EntitySetName para la tabla relacionada
                        try {
                            $relMetadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$relatedTable')?`$select=LogicalName,EntitySetName"
                            $relEntityDef = Invoke-RestMethod -Uri $relMetadataUrl -Method Get -Headers $headers -ErrorAction Stop
                            $tableNameMap[$relatedTable] = $relEntityDef.EntitySetName
                        } catch {
                            # Fallback
                            $tableNameMap[$relatedTable] = "${relatedTable}s"
                        }
                        
                        $allTablesToExport += $relatedTable
                        $relatedTablesFound += $relatedTable
                        Write-Output "    ↳ N:1 - $table → $relatedTable (parent)"
                    }
                }
                
                # === RELACIONES 1:N (One-to-Many) - Tablas hijo ===
                # Obtener tablas que REFERENCIAN a las críticas (lookups a tablas críticas)
                $1nUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$table')/OneToManyRelationships?`$select=ReferencedEntity,ReferencingEntity"
                
                $1nRelationships = Invoke-RestMethod -Uri $1nUrl -Method Get -Headers $headers -ErrorAction SilentlyContinue
                
                foreach ($rel in $1nRelationships.value) {
                    $relatedTable = $rel.ReferencingEntity
                    
                    # FILTRADO MEJORADO: Excluir tablas del sistema
                    if ($relatedTable -and 
                        $relatedTable -notlike 'system*' -and
                        $systemTablesToExclude -notcontains $relatedTable -and
                        $allTablesToExport -notcontains $relatedTable) {
                        
                        # Obtener EntitySetName para la tabla relacionada
                        try {
                            $relMetadataUrl = "$dataverseUrl/api/data/v9.2/EntityDefinitions(LogicalName='$relatedTable')?`$select=LogicalName,EntitySetName"
                            $relEntityDef = Invoke-RestMethod -Uri $relMetadataUrl -Method Get -Headers $headers -ErrorAction Stop
                            $tableNameMap[$relatedTable] = $relEntityDef.EntitySetName
                        } catch {
                            # Fallback
                            $tableNameMap[$relatedTable] = "${relatedTable}s"
                        }
                        
                        $allTablesToExport += $relatedTable
                        $relatedTablesFound += $relatedTable
                        Write-Output "    ↳ 1:N - $table ← $relatedTable (child)"
                    }
                }
            } catch {
                # Ignorar errores de metadata (tabla puede no tener relaciones)
            }
        }
        
        $relacionesCount = $relatedTablesFound.Count
        $criticasCount = $criticalTables.Count
        $totalTablasCount = $allTablesToExport.Count
        
        Write-Output "  [INFO] Relaciones encontradas: $relacionesCount"
        Write-Output "  [INFO] Total tablas a exportar: $totalTablasCount"
        Write-Output "    - Tablas criticas: $criticasCount"
        Write-Output "    - Tablas relacionadas: $relacionesCount"
        Write-Output "    - Tablas del sistema excluidas: $($systemTablesToExclude.Count)"
        
        Write-DetailedLog "Detección completada: $totalTablasCount tablas, $($systemTablesToExclude.Count) excluidas" "SUCCESS"
        
        Write-Output "  [4b] Exportando datos de tablas..."
        
        $dataversePath = "$tempPath\dataverse"
        New-Item -ItemType Directory -Path $dataversePath -Force | Out-Null
        
        $exportedCount = 0
        $errorCount = 0
        $totalRecords = 0
        
        foreach ($logicalName in $allTablesToExport) {
            try {
                # Obtener EntitySetName del mapa (para query OData)
                $entitySetName = $tableNameMap[$logicalName]
                if (-not $entitySetName) {
                    $entitySetName = "${logicalName}s"  # Fallback
                }
                
                Write-Output "    • Procesando: $logicalName ($entitySetName)"
                Write-DetailedLog "Exportando tabla: $logicalName → $entitySetName" "INFO"
                
                # Construir URL de API Web de Dataverse (usar EntitySetName - plural)
                $apiUrl = "$dataverseUrl/api/data/v9.2/$entitySetName`?`$select=*"
                
                # Hacer request con autenticación usando el mismo token de Dataverse
                $headers = @{
                    "Authorization" = "Bearer $accessToken"
                    "OData-MaxVersion" = "4.0"
                    "OData-Version" = "4.0"
                }
                
                $response = Invoke-RestMethod -Uri $apiUrl -Method Get -Headers $headers
                
                # Filtrar campos de fórmula de los datos antes de guardar
                $cleanedRecords = @()
                foreach ($record in $response.value) {
                    $cleanRecord = @{}
                    foreach ($prop in $record.PSObject.Properties) {
                        # Excluir campos de fórmula identificados previamente
                        if ($prop.Name -notin $script:formulaFieldsToExclude) {
                            $cleanRecord[$prop.Name] = $prop.Value
                        }
                    }
                    $cleanedRecords += $cleanRecord
                }
                
                # Guardar con LogicalName para consistencia
                $cleanedRecords | ConvertTo-Json -Depth 10 | Out-File "$dataversePath\$logicalName.json" -Encoding UTF8
                
                $recordCount = $response.value.Count
                $totalRecords += $recordCount
                Write-Output "      Exportada: $recordCount registros"
                $exportedCount++
            } catch {
                Write-Warning "      Error exportando $logicalName"
                Write-Warning "      Detalle: $($_.Exception.Message)"
                Write-Warning "      API URL: $apiUrl"
                $errorCount++
            }
        }
        
        Write-Output "  Tablas procesadas: $exportedCount de $($allTablesToExport.Count) exitosas, $errorCount errores"
        Write-Output "  Total registros exportados: $totalRecords"
        
        if ($errorCount -eq $allTablesToExport.Count) {
            throw "Todas las tablas fallaron. Verificar permisos y nombres de tablas."
        }
    } catch {
        Write-Output "[PASO 4 ERROR] Fallo al exportar tablas Dataverse"
        Write-Output "Detalle: $($_.Exception.Message)"
        Write-Output "Dataverse URL: $dataverseUrl"
        Write-Output "Posibles causas:"
        Write-Output "  1. Nombres de tablas incorrectos (verificar plural: tabla -> tablas)"
        Write-Output "  2. Service Principal sin permisos en Dataverse"
        Write-Output "  3. Token de acceso inválido"
        Write-Output "  4. Environment no tiene Dataverse habilitado"
        throw
    }
    
    Write-Output "  Exportación de Dataverse completada"
    
    # ==========================================
    # 4.5. EXPORTAR CONFIGURACIÓN DEL ENVIRONMENT
    # ==========================================
    
    Write-Output "`n[4.5/6] Exportando configuración del environment..."
    Write-DetailedLog "PASO 4.5: Exportar metadata del environment" "INFO"
    
    try {
        # Construir objeto de configuración
        $envConfig = @{
            BackupMetadata = @{
                Date = $date
                BackupId = [guid]::NewGuid().ToString()
                OrganizationId = $organizationId
                DataverseUrl = $dataverseUrl
                Version = "5.0"
            }
            Solutions = @()
            Tables = @{
                Custom = @()
                System = @()
            }
            Components = @{
                PCFControls = $script:pcfControlsInSolution
                TotalComponents = $script:totalComponentsCount
            }
            Parameters = @{
                IncludeSystemTables = $IncludeSystemTables
                CustomPrefixes = $CustomPrefixes
            }
            Statistics = @{
                SolutionsExported = $solutionsToExport.Count
                TablesExported = $allTablesToExport.Count
                RecordsExported = $totalRecords
                FormulasRemoved = $script:formulaFieldsToExclude.Count
            }
        }
        
        # Agregar info de soluciones
        if ($customSolutions) {
            foreach ($sol in $customSolutions) {
                $envConfig.Solutions += @{
                    UniqueName = $sol.uniquename
                    FriendlyName = $sol.friendlyname
                    Version = $sol.version
                    SolutionId = $sol.solutionid
                }
            }
        }
        
        # Agregar info de tablas (distinguir custom vs system)
        $systemTablesList = @("account", "contact", "appointment", "task", "email", "phonecall", "letter", "fax", "recurringappointmentmaster", "socialactivity")
        
        foreach ($table in $criticalTables) {
            if ($systemTablesList -contains $table) {
                $envConfig.Tables.System += $table
            } else {
                $envConfig.Tables.Custom += $table
            }
        }
        
        # Agregar info de fórmulas eliminadas
        if ($script:formulaFieldsToExclude.Count -gt 0) {
            $envConfig.FormulasRemoved = @{
                Count = $script:formulaFieldsToExclude.Count
                Fields = $script:formulaFieldsToExclude
                Note = "Estas fórmulas deben recrearse manualmente después del restore"
            }
        }
        
        # Guardar a JSON
        $configPath = "$tempPath\environment-config.json"
        $envConfig | ConvertTo-Json -Depth 10 | Out-File $configPath -Encoding UTF8
        
        Write-Output "  ✓ Configuración exportada: environment-config.json"
        Write-Output "    - Soluciones: $($envConfig.Solutions.Count)"
        Write-Output "    - Tablas custom: $($envConfig.Tables.Custom.Count)"
        Write-Output "    - Tablas sistema: $($envConfig.Tables.System.Count)"
        Write-Output "    - Componentes: $($envConfig.Components.TotalComponents)"
        
        Write-DetailedLog "Environment config exportado exitosamente" "SUCCESS"
        
    } catch {
        Write-Output "  ⚠ No se pudo exportar configuración (no crítico): $($_.Exception.Message)"
        Write-DetailedLog "Error exportando environment config: $($_.Exception.Message)" "WARNING"
    }
    
    # ==========================================
    # 5. COMPRIMIR Y SUBIR A STORAGE
    # ==========================================
    
    Write-Output "`n[5/6] Comprimiendo y subiendo a Azure Storage..."
    
    try {
        $zipFileName = "PowerPlatform_Backup_$date.zip"
        $zipPath = "$env:TEMP\$zipFileName"
        
        # Comprimir
        Write-DetailedLog "Comprimiendo archivos del backup" "INFO"
        Write-DetailedLog "  Origen: $tempPath" "INFO"
        Write-DetailedLog "  Destino: $zipPath" "INFO"
        
        Compress-Archive -Path "$tempPath\*" -DestinationPath $zipPath -CompressionLevel Optimal
        $backupSize = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        
        Write-DetailedLog "  Backup comprimido: $backupSize MB" "SUCCESS"
        Write-Output "  Backup comprimido: $backupSize MB"
        
        # Obtener Storage Account Key desde Automation Variables
        $storageKey = Get-AutomationVariable -Name "StorageAccountKey"
        
        # Conectar a Storage con Account Key
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageKey
        Write-Output "  Conectado a Storage Account: $storageAccountName"
        
        # Subir a blob
        Write-DetailedLog "Subiendo backup a Azure Storage"
        Write-DetailedLog "  Storage Account: $storageAccountName"
        Write-DetailedLog "  Container: pp-backup"
        Write-DetailedLog "  Blob: $zipFileName"
        Write-DetailedLog "  Tamaño: $backupSize MB"
        
        Set-AzStorageBlobContent `
            -File $zipPath `
            -Container "pp-backup" `
            -Blob $zipFileName `
            -Context $ctx `
            -BlobType Block `
            -Force | Out-Null
        
        Write-DetailedLog "  Backup subido exitosamente" "SUCCESS"
        
        $sizeMsg = "$backupSize MB"
        Write-Output "  Backup subido: $zipFileName"
        Write-Output "    - Tamano: $sizeMsg"
        Write-Output "    - Container: pp-backup"
        Write-Output "    - Blob: $zipFileName"
    } catch {
        Write-Output "[PASO 5 ERROR] Fallo al subir backup a Storage"
        Write-Output "Detalle: $($_.Exception.Message)"
        Write-Output "Storage Account: $storageAccountName"
        Write-Output "Archivo: $zipFileName"
        Write-Output "Posibles causas:"
        Write-Output "  1. StorageAccountKey variable no configurada"
        Write-Output "  2. Container 'pp-backup' no existe"
        Write-Output "  3. Sin permisos de escritura en Storage Account"
        Write-Output "  4. Error al comprimir archivos temporales"
        throw
    }
    
    # ==========================================
    # 6. GUARDAR LOG
    # ==========================================
    
    Write-Output "`n[6/6] Guardando log de auditoría..."
    
    try {
        $logEntry = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            service = "PowerPlatform"
            status = "success"
            backupVersion = "5.0"
            environment = $organizationId
            solutionsExported = $solutionsToExport
            solutionsCount = $solutionsToExport.Count
            tablesCustom = $criticalTables
            tablesRelated = $relatedTablesFound
            totalTablesExported = $allTablesToExport.Count
            totalRecords = $totalRecords
            backupFile = $zipFileName
            backupSizeMB = $backupSize
            parameters = @{
                IncludeSystemTables = $IncludeSystemTables
                CustomPrefixes = $CustomPrefixes
            }
            formulasRemoved = $script:formulaFieldsToExclude.Count
            errors = @()
        } | ConvertTo-Json
        
        $logFileName = "log_PP_$date.json"
        $logPath = "$env:TEMP\$logFileName"
        $logEntry | Out-File -FilePath $logPath -Encoding UTF8
        
        Set-AzStorageBlobContent `
            -File $logPath `
            -Container "logs" `
            -Blob "powerplatform/$logFileName" `
            -Context $ctx `
            -Force | Out-Null
        
        Write-Output "  Log guardado en: logs/powerplatform/$logFileName"
    } catch {
        Write-Warning "[PASO 6 WARNING] No se pudo guardar log (backup completado, pero sin log)"
        Write-Warning "Detalle: $($_.Exception.Message)"
    }
    
    # ==========================================
    # LIMPIEZA
    # ==========================================
    
    Write-Output "`n[LIMPIEZA] Eliminando archivos temporales..."
    Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $logPath -Force -ErrorAction SilentlyContinue
    Write-Output "  Archivos temporales eliminados"
    
    Write-Output "`n======================================"
    Write-Output "BACKUP COMPLETADO EXITOSAMENTE"
    Write-Output "======================================"
    Write-Output ""
    Write-Output "✅ BACKUP AUTOMÁTICO COMPLETO (v5.0)"
    Write-Output ""
    Write-Output "SOLUCIONES EXPORTADAS (AUTO-DETECTADAS):"
    
    if ($solutionsToExport.Count -gt 0) {
        Write-Output "  Total: $($solutionsToExport.Count) soluciones custom"
        foreach ($sol in $customSolutions) {
            Write-Output "    • $($sol.friendlyname) ($($sol.uniquename)) - v$($sol.version)"
        }
    } else {
        Write-Output "  ⚠ Ninguna solución custom encontrada"
    }
    
    # Mostrar PCF controls
    if ($script:pcfControlsInSolution -and $script:pcfControlsInSolution.Count -gt 0) {
        Write-Output ""
        Write-Output "PCF CONTROLS DETECTADOS:"
        foreach ($pcf in $script:pcfControlsInSolution) {
            Write-Output "    • $pcf"
        }
    }
    
    Write-Output ""
    Write-Output "TABLAS EXPORTADAS (AUTO-DETECTADAS):"
    Write-Output "  Tablas custom: $($criticalTables.Count)"
    
    $customTablesForDisplay = $criticalTables | Select-Object -First 10
    foreach ($table in $customTablesForDisplay) {
        Write-Output "    • $table"
    }
    
    if ($criticalTables.Count -gt 10) {
        Write-Output "    ... y $($criticalTables.Count - 10) más"
    }
    
    if ($relatedTablesFound.Count -gt 0) {
        Write-Output ""
        Write-Output "  Tablas relacionadas: $($relatedTablesFound.Count)"
        $relatedForDisplay = $relatedTablesFound | Select-Object -First 5
        foreach ($table in $relatedForDisplay) {
            Write-Output "    ↳ $table"
        }
        if ($relatedTablesFound.Count -gt 5) {
            Write-Output "    ↳ ... y $($relatedTablesFound.Count - 5) más"
        }
    }
    
    $totalTablas = $allTablesToExport.Count
    $criticas = $criticalTables.Count
    $relacionadas = if ($relatedTablesFound) { $relatedTablesFound.Count } else { 0 }
    
    Write-Output ""
    Write-Output "  📊 ESTADÍSTICAS:"
    Write-Output "    - Total tablas: $totalTablas ($criticas custom + $relacionadas relacionadas)"
    Write-Output "    - Total registros: $totalRecords"
    Write-Output "    - Componentes: $script:totalComponentsCount"
    
    if ($script:formulaFieldsToExclude.Count -gt 0) {
        Write-Output "    - Fórmulas eliminadas: $($script:formulaFieldsToExclude.Count) (compatibilidad cross-environment)"
    }
    
    Write-Output ""
    Write-Output "ARCHIVO DE BACKUP:"
    Write-Output "  Nombre: $zipFileName"
    Write-Output "  Tamaño: $backupSize MB"
    Write-Output "  Ubicación: pp-backup/$zipFileName"
    Write-Output "  Contenido:"
    Write-Output "    - $($solutionsToExport.Count) archivo(s) .zip de soluciones"
    Write-Output "    - $totalTablas archivo(s) .json de datos"
    Write-Output "    - 1 archivo environment-config.json (metadata)"
    Write-Output ""
    Write-Output "CONFIGURACIÓN:"
    Write-Output "  Modo: Automático (sin parámetros)"
    Write-Output "  Detección: IsCustomEntity (100% genérico)"
    Write-Output "  Tablas sistema: $(if ($IncludeSystemTables) { 'Incluidas' } else { 'Excluidas' })"
    Write-Output ""
    Write-Output "PRÓXIMOS PASOS:"
    Write-Output "  1. Verificar backup: Azure Portal → Storage Account → pp-backup"
    Write-Output "  2. Revisar logs: Storage Account → logs/powerplatform/"
    Write-Output "  3. Restaurar: Ejecutar runbook 'Restore-PowerPlatform'"
    Write-Output "  4. Ver detalles: Descargar y abrir environment-config.json"
    Write-Output "======================================"
    
} catch {
    Write-Output "`n======================================"
    Write-Output "ERROR EN BACKUP - PROCESO ABORTADO"
    Write-Output "======================================"
    Write-Output ""
    Write-Output "ERROR DETALLADO:"
    Write-Output "  Mensaje: $($_.Exception.Message)"
    Write-Output "  Línea: $($_.InvocationInfo.ScriptLineNumber)"
    Write-Output "  Comando: $($_.InvocationInfo.Line.Trim())"
    Write-Output ""
    Write-Output "STACK TRACE:"
    Write-Output "$($_.ScriptStackTrace)"
    Write-Output ""
    
    # Intentar guardar log de error en Storage
    try {
        Write-DetailedLog "Generando log de error detallado" "ERROR"
        
        $errorLogContent = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("o")
            service = "PowerPlatform"
            status = "failed"
            error = @{
                message = $_.Exception.Message
                type = $_.Exception.GetType().FullName
                line = $_.InvocationInfo.ScriptLineNumber
                command = $_.InvocationInfo.Line
                stackTrace = $_.ScriptStackTrace
            }
            executionLog = $script:executionLog
            errorDetails = $script:errorDetails
            environment = if ($organizationId) { $organizationId } else { "N/A" }
            backupMode = "Auto-detect (Generic)"
            variables = @{
                appId = if ($appId) { $appId.Substring(0,8) + "..." } else { "N/A" }
                tenantId = if ($tenantId) { $tenantId.Substring(0,8) + "..." } else { "N/A" }
                organizationId = if ($organizationId) { $organizationId } else { "N/A" }
                dataverseUrl = if ($dataverseUrl) { $dataverseUrl } else { "N/A" }
                storageAccount = if ($storageAccountName) { $storageAccountName } else { "N/A" }
                customPrefixes = if ($CustomPrefixes) { $CustomPrefixes -join ',' } else { "None (IsCustomEntity only)" }
                includeSystemTables = $IncludeSystemTables
            }
        } | ConvertTo-Json -Depth 10
        
        $errorLogFileName = "error_PP_$date.json"
        $errorLogPath = "$env:TEMP\$errorLogFileName"
        $errorLogContent | Out-File -FilePath $errorLogPath -Encoding UTF8
        
        Write-Output "Log de error generado localmente"
        Write-DetailedLog "Log de error guardado: $errorLogPath" "INFO"
        
        # Intentar subir log de error
        if ($ctx) {
            Write-Output "Subiendo log de error a Azure Storage..."
            
            Set-AzStorageBlobContent `
                -File $errorLogPath `
                -Container "logs" `
                -Blob "powerplatform/errors/$errorLogFileName" `
                -Context $ctx `
                -Force | Out-Null
            
            Write-Output "Log de error guardado en: logs/powerplatform/errors/$errorLogFileName"
            Write-DetailedLog "Log de error subido a Storage" "SUCCESS"
        } else {
            Write-Output "Storage context no disponible - log solo guardado localmente"
        }
    } catch {
        Write-Warning "No se pudo guardar log de error: $($_.Exception.Message)"
    }
    
    throw
}
