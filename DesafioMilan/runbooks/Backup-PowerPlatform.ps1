<#
.SYNOPSIS
    Runbook para respaldo diario de Power Platform y Dataverse

.DESCRIPTION
    Este runbook exporta:
    - Soluciones de Power Platform (ZIP)
    - Aplicaciones Canvas/Model-Driven
    - Flujos de Power Automate
    - Tablas críticas de Dataverse (JSON)
    - Tablas relacionadas (JSON)
    
    Los datos se comprimen y suben a Azure Blob Storage.

.NOTES
    Requisitos:
    - Service Principal con permisos en Power Platform
    - Managed Identity con acceso a Storage Account
    - Módulos: Az.Storage, Microsoft.PowerApps.Administration.PowerShell
#>

param()

# ==========================================
# CONFIGURACIÓN INICIAL
# ==========================================
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
        
        # Leer Environment Name
        Write-DetailedLog "Obteniendo variable: PP-EnvironmentName" "INFO"
        $environmentName = Get-AutomationVariable -Name "PP-EnvironmentName" -ErrorAction Stop
        Write-DetailedLog "  Environment Name: $environmentName" "SUCCESS"
        
        # Leer Solution Name
        Write-DetailedLog "Obteniendo variable: PP-SolutionName" "INFO"
        $solutionName = Get-AutomationVariable -Name "PP-SolutionName" -ErrorAction Stop
        Write-DetailedLog "  Solution Name: $solutionName" "SUCCESS"
        
        # Leer Dataverse URL
        Write-DetailedLog "Obteniendo variable: PP-DataverseUrl" "INFO"
        $dataverseUrl = Get-AutomationVariable -Name "PP-DataverseUrl" -ErrorAction Stop
        Write-DetailedLog "  Dataverse URL: $dataverseUrl" "SUCCESS"
        
        # Leer Storage Account Name
        Write-DetailedLog "Obteniendo variable: StorageAccountName" "INFO"
        $storageAccountName = Get-AutomationVariable -Name "StorageAccountName" -ErrorAction Stop
        Write-DetailedLog "  Storage Account: $storageAccountName" "SUCCESS"
        
        Write-Output "  Variables cargadas exitosamente"
        Write-Output "    - Environment: $environmentName"
        Write-Output "    - Solution: $solutionName"
        Write-Output "    - Dataverse URL: $dataverseUrl"
        Write-Output "    - Storage: $storageAccountName"
        
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
        Write-Output "    - Environment: $environmentName"
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
    # 3. EXPORTAR SOLUCIÓN
    # ==========================================
    
    Write-Output "`n[3/6] Exportando solución: $solutionName..."
    Write-DetailedLog "PASO 3: Exportar soluciones de Power Platform" "INFO"
    
    try {
        Write-DetailedLog "Creando directorio temporal: $tempPath" "INFO"
        New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
        Write-DetailedLog "  ✓ Directorio temporal creado" "SUCCESS"
        
        # Obtener Dataverse URL dinámicamente desde Power Platform API
        Write-Output "  Obteniendo información del environment..."
        
        try {
            # Intentar obtener URL automáticamente con Power Platform Management API
            # Usar Service Principal (no Managed Identity) para evitar problemas cross-tenant
            Write-Output "  [3a] Intentando obtener Dataverse URL dinámicamente..."
            
            $ppTokenBody = @{
                client_id = $appId
                client_secret = $clientSecret
                scope = "https://service.powerapps.com/.default"
                grant_type = "client_credentials"
            }
            $ppTokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
            
            try {
                Write-DetailedLog "Solicitando token para Power Platform Management API" "INFO"
                Write-DetailedLog "  Token URL: $ppTokenUrl" "INFO"
                Write-DetailedLog "  Scope: service.powerapps.com/.default" "INFO"
                
                $ppTokenResponse = Invoke-RestMethod -Uri $ppTokenUrl -Method Post -Body $ppTokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                $ppToken = $ppTokenResponse.access_token
                
                Write-DetailedLog "  Token de Power Platform API obtenido" "SUCCESS"
                Write-Output "    Token de Power Platform API obtenido"
            } catch {
                $errorDetails = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                Write-Output "    ERROR obteniendo token de Power Platform API:"
                Write-Output "      HTTP Status: $($_.Exception.Response.StatusCode.value__)"
                Write-Output "      Mensaje: $($_.Exception.Message)"
                if ($errorDetails) {
                    Write-Output "      Detalles: $($errorDetails.error_description)"
                }
                Write-Output "     SOLUCIÓN: Verifica que Dynamics CRM API esté agregado en:"
                Write-Output "      Azure Portal → Entra ID → App registrations → $appId"
                Write-Output "      → API permissions → Dynamics CRM → user_impersonation"
                throw
            }
            
            $ppApiUrl = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$environmentName`?api-version=2020-10-01"
            $ppHeaders = @{
                "Authorization" = "Bearer $ppToken"
                "Accept" = "application/json"
            }
            
            Write-Output "     Consultando: $ppApiUrl"
            
            try {
                $envInfo = Invoke-RestMethod -Uri $ppApiUrl -Method Get -Headers $ppHeaders -ErrorAction Stop
                $dataverseUrlFromApi = $envInfo.properties.linkedEnvironmentMetadata.instanceUrl
                
                if (-not [string]::IsNullOrEmpty($dataverseUrlFromApi)) {
                    $dataverseUrl = $dataverseUrlFromApi
                    Write-Output "    Dataverse URL obtenida dinámicamente: $dataverseUrl"
                } else {
                    throw "API no devolvió instanceUrl en response"
                }
            } catch {
                $statusCode = $_.Exception.Response.StatusCode.value__
                Write-Output "    ✗ ERROR consultando Power Platform Management API:"
                Write-Output "      HTTP Status: $statusCode"
                Write-Output "      Mensaje: $($_.Exception.Message)"
                
                if ($statusCode -eq 401) {
                    Write-Output "     CAUSA: Falta 'Grant admin consent' para Dynamics CRM API"
                    Write-Output "      SOLUCIÓN:"
                    Write-Output "      1. Azure Portal → Entra ID → App registrations → $appId"
                    Write-Output "      2. API permissions → Click 'Grant admin consent for [tenant]'"
                } elseif ($statusCode -eq 403) {
                    Write-Output "    CAUSA: Service Principal necesita rol 'Power Platform Administrator'"
                    Write-Output "      SOLUCIÓN:"
                    Write-Output "      1. Power Platform Admin Center → https://admin.powerplatform.com"
                    Write-Output "      2. Settings → Security roles"
                    Write-Output "      3. Asignar rol 'Power Platform Administrator' a Service Principal"
                    Write-Output "      ADVERTENCIA: Este rol da acceso a TODOS los environments del tenant"
                } elseif ($statusCode -eq 404) {
                    Write-Output "    CAUSA: Environment ID incorrecto o no existe"
                    Write-Output "      Environment ID usado: $environmentName"
                } else {
                    Write-Output "    Error inesperado, contacta a soporte de Microsoft"
                }
                
                throw
            }
        } catch {
            # Fallback: usar URL de variable si API falla
            Write-Output "  Power Platform API no disponible - usando fallback"
            Write-Output "  URL de variable: $dataverseUrl"
            Write-Output "  El backup continuará normalmente con URL hardcoded"
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
        
        # Paso 1: Obtener el Solution ID y detectar PCF controls
        Write-Output "  [3b] Buscando solución y detectando PCF controls..."
        $solutionQuery = "$dataverseUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$solutionName'&`$select=solutionid,friendlyname,version"
        $solutionResponse = Invoke-RestMethod -Uri $solutionQuery -Method Get -Headers $headers
        
        if ($solutionResponse.value.Count -eq 0) {
            throw "Solución '$solutionName' no encontrada en el environment"
        }
        
        $solutionId = $solutionResponse.value[0].solutionid
        $solutionVersion = $solutionResponse.value[0].version
        Write-Output "    Solución encontrada: ID=$solutionId, Version=$solutionVersion"
        
        # Inicializar con la solución principal
        $solutionsToExport = @($solutionName)
        $pcfSolutionNames = @()
        
        # Detectar PCF controls en la solución
        try {
            Write-Output "    [DEBUG] Consultando componentes de la solución..."
            $componentsUrl = "$dataverseUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $solutionId and componenttype eq 66"
            Write-Output "    [DEBUG] URL: $componentsUrl"
            
            $pcfComponents = Invoke-RestMethod -Uri $componentsUrl -Method Get -Headers $headers
            
            Write-Output "    [DEBUG] Componentes encontrados: $($pcfComponents.value.Count)"
            
            if ($pcfComponents.value.Count -gt 0) {
                Write-Output "    • PCF controls detectados: $($pcfComponents.value.Count)"
                Write-DetailedLog "PCF controls encontrados en solución: $($pcfComponents.value.Count)" "INFO"
                
                foreach ($pcf in $pcfComponents.value) {
                    # Obtener nombre de la solución que contiene el PCF
                    $pcfSolutionId = $pcf._solutionid_value
                    Write-Output "      [DEBUG] PCF Solution ID: $pcfSolutionId"
                    
                    $pcfSolutionQuery = "$dataverseUrl/api/data/v9.2/solutions($pcfSolutionId)?`$select=uniquename,ismanaged"
                    $pcfSolution = Invoke-RestMethod -Uri $pcfSolutionQuery -Method Get -Headers $headers
                    
                    Write-Output "      [DEBUG] PCF Solution: $($pcfSolution.uniquename), IsManaged: $($pcfSolution.ismanaged)"
                    
                    if (-not $pcfSolution.ismanaged -and $pcfSolution.uniquename -ne $solutionName) {
                        $solutionsToExport += $pcfSolution.uniquename
                        $pcfSolutionNames += $pcfSolution.uniquename
                        Write-Output "      PCF solution agregada: $($pcfSolution.uniquename)"
                        Write-DetailedLog "PCF solution agregada: $($pcfSolution.uniquename)" "SUCCESS"
                    } else {
                        Write-Output "      • PCF en misma solución o managed: $($pcfSolution.uniquename)"
                    }
                }
            } else {
                Write-Output "    • No se detectaron PCF controls en esta solución"
                Write-DetailedLog "No se encontraron PCF controls (componenttype=66)" "INFO"
            }
        } catch {
            Write-Output "    Error detectando PCF (continuando con solución principal): $($_.Exception.Message)"
            Write-DetailedLog "Error en detección de PCF: $($_.Exception.Message)" "ERROR"
        }
        
        # Reporte adicional: Verificar si la solución contiene custom controls
        $script:pcfControlsInSolution = @()
        try {
            Write-Output "    [INFO] Analizando componentes de la solución..."
            
            # Obtener todos los custom controls (componenttype=66) en la solución
            $customControlsUrl = "$dataverseUrl/api/data/v9.2/customcontrols?`$select=name,version"
            $customControlsResponse = Invoke-RestMethod -Uri $customControlsUrl -Method Get -Headers $headers -ErrorAction SilentlyContinue
            
            if ($customControlsResponse.value.Count -gt 0) {
                Write-Output "    [INFO] Custom Controls detectados en el environment:"
                foreach ($ctrl in $customControlsResponse.value) {
                    $script:pcfControlsInSolution += "$($ctrl.name) (v$($ctrl.version))"
                    Write-Output "      • $($ctrl.name) - v$($ctrl.version)"
                }
            }
            
            # Resumen de componentes por tipo
            $allComponentsUrl = "$dataverseUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $solutionId&`$select=componenttype&`$top=100"
            $allComponents = Invoke-RestMethod -Uri $allComponentsUrl -Method Get -Headers $headers
            
            $componentTypes = $allComponents.value | Group-Object -Property componenttype | Select-Object Name, Count
            Write-Output "    [INFO] Resumen de componentes en la solución:"
            foreach ($type in $componentTypes) {
                $typeName = switch ($type.Name) {
                    "1" { "Entidades" }
                    "2" { "Atributos" }
                    "9" { "Option Sets" }
                    "60" { "Plug-in Assemblies" }
                    "61" { "SDK Message Steps" }
                    "66" { "Custom Controls (PCF)" }
                    "80" { "Canvas Apps" }
                    "300" { "Cloud Flows" }
                    default { "Type $($type.Name)" }
                }
                Write-Output "      - $typeName`: $($type.Count)"
            }
        } catch {
            Write-Output "    [INFO] No se pudo obtener detalle de componentes"
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
                    Managed = $true
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
                
                # Decodificar y guardar
                $solutionPath = "$tempPath\$solToExport.zip"
                $solutionBytes = [System.Convert]::FromBase64String($solutionZipBase64)
                [System.IO.File]::WriteAllBytes($solutionPath, $solutionBytes)
                
                $solSize = [Math]::Round((Get-Item $solutionPath).Length / 1MB, 2)
                Write-Output "      Exportado: $solSize MB"
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
        Write-Output "Solución: $solutionName"
        Write-Output "Dataverse URL: $dataverseUrl"
        Write-Output "Posibles causas:"
        Write-Output "  1. Solución no existe (uniquename incorrecto)"
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
        
        # Tablas críticas principales (LogicalName - singular)
        $criticalTables = @("cr8df_actividadcalendario", "cr391_calendario2", "cr391_casosfluentpivot", "cr8df_usuario")
        Write-Output "  Tablas críticas: $($criticalTables.Count)"
        
        # Detectar tablas relacionadas automáticamente
        Write-Output "  [4a] Detectando relaciones y obteniendo EntitySetNames..."
        
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
                    
                    # Filtrar tablas del sistema y duplicados
                    if ($relatedTable -and 
                        $relatedTable -notlike 'system*' -and
                        $relatedTable -ne 'organization' -and
                        $relatedTable -ne 'businessunit' -and
                        $relatedTable -ne 'owner' -and
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
                    
                    # Filtrar tablas del sistema y duplicados
                    if ($relatedTable -and 
                        $relatedTable -notlike 'system*' -and
                        $relatedTable -ne 'organization' -and
                        $relatedTable -ne 'businessunit' -and
                        $relatedTable -ne 'owner' -and
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
                
                # Guardar con LogicalName para consistencia
                $response.value | ConvertTo-Json -Depth 10 | Out-File "$dataversePath\$logicalName.json" -Encoding UTF8
                
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
            environment = $environmentName
            solution = $solutionName
            solutionsExported = $solutionsToExport
            pcfSolutionsDetected = $pcfSolutionNames
            autoDetectedPCF = $pcfSolutionNames.Count
            criticalTables = $criticalTables
            relatedTablesDetected = $relatedTablesFound
            totalTablesExported = $allTablesToExport.Count
            totalRecords = $totalRecords
            backupFile = $zipFileName
            backupSizeMB = $backupSize
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
    Write-Output "SOLUCIONES EXPORTADAS:"
    Write-Output "  Solución principal: $solutionName (v$solutionVersion)"
    
    if ($pcfSolutionNames.Count -gt 0) {
        Write-Output "  PCF solutions adicionales: $($pcfSolutionNames -join ', ')"
        $totalSol = $solutionsToExport.Count
        $pcfSol = $pcfSolutionNames.Count
        Write-Output "  Total: $totalSol soluciones ($($totalSol - $pcfSol) principal + $pcfSol PCF)"
    } else {
        Write-Output "  Total: 1 solución"
    }
    
    # Mostrar PCF controls detectados dentro de la solución
    if ($script:pcfControlsInSolution) {
        Write-Output ""
        Write-Output "PCF CONTROLS INCLUIDOS EN LA SOLUCIÓN:"
        foreach ($pcf in $script:pcfControlsInSolution) {
            Write-Output "  • $pcf"
        }
        Write-Output "  Total PCF: $($script:pcfControlsInSolution.Count)"
    }
    
    Write-Output ""
    Write-Output "TABLAS DATAVERSE EXPORTADAS:"
    Write-Output "  Tablas críticas: $($criticalTables.Count)"
    foreach ($table in $criticalTables) {
        Write-Output "    • $table"
    }
    
    if ($relatedTablesFound.Count -gt 0) {
        Write-Output "  Tablas relacionadas (auto-detectadas): $($relatedTablesFound.Count)"
        foreach ($table in $relatedTablesFound) {
            Write-Output "    ↳ $table"
        }
    }
    
    $totalTablas = $allTablesToExport.Count
    $criticas = $criticalTables.Count
    $relacionadas = $relatedTablesFound.Count
    
    Write-Output "  Total tablas: $totalTablas ($criticas críticas + $relacionadas relacionadas)"
    Write-Output "  Total registros exportados: $totalRecords"
    
    Write-Output ""
    Write-Output "ARCHIVO DE BACKUP:"
    Write-Output "  Nombre: $zipFileName"
    Write-Output "  Tamaño: $backupSize MB"
    Write-Output "  Ubicación: pp-backup/$zipFileName"
    Write-Output "  Contenido:"
    Write-Output "    - $($solutionsToExport.Count) archivo(s) .zip de soluciones"
    Write-Output "    - $totalTablas archivo(s) .json de tablas"
    Write-Output ""
    Write-Output "Extras:"
    Write-Output "  1. Verificar backup en Azure Portal → Storage Account → pp-backup"
    Write-Output "  2. Revisar logs en: Storage Account → logs/powerplatform/"
    Write-Output "  3. Para restaurar: Ejecutar runbook 'Restore-PowerPlatform'"
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
            environment = if ($environmentName) { $environmentName } else { "N/A" }
            solution = if ($solutionName) { $solutionName } else { "N/A" }
            variables = @{
                appId = if ($appId) { $appId.Substring(0,8) + "..." } else { "N/A" }
                tenantId = if ($tenantId) { $tenantId.Substring(0,8) + "..." } else { "N/A" }
                environmentName = if ($environmentName) { $environmentName } else { "N/A" }
                solutionName = if ($solutionName) { $solutionName } else { "N/A" }
                dataverseUrl = if ($dataverseUrl) { $dataverseUrl } else { "N/A" }
                storageAccount = if ($storageAccountName) { $storageAccountName } else { "N/A" }
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
