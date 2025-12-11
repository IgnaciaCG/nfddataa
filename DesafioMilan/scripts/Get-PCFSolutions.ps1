<#
.SYNOPSIS
    Script para identificar automáticamente PCF controls usados en miApp

.DESCRIPTION
    Detecta los PCF controls que usa tu solución y encuentra sus soluciones origen
#>

param(
    [string]$DataverseUrl = "https://org35482f4d.crm2.dynamics.com",
    [string]$TenantId = "344457f2-bd03-46c6-9974-97bffb8f626a",
    [string]$AppId = "7fc4ef96-8566-4adb-a579-2030dbf71c35",
    [string]$SolutionName = "miApp"
)

$ErrorActionPreference = "Stop"

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "Detección Automática de PCF Controls" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Leer Client Secret
$clientSecret = Read-Host "Client Secret del Service Principal" -AsSecureString
$clientSecretPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecret)
)

# Obtener token
Write-Host "`n[1/4] Obteniendo token de Dataverse..." -ForegroundColor Yellow

$tokenBody = @{
    client_id = $AppId
    client_secret = $clientSecretPlain
    scope = "$DataverseUrl/.default"
    grant_type = "client_credentials"
}

$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
$accessToken = $tokenResponse.access_token

Write-Host "  ✓ Token obtenido" -ForegroundColor Green

$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type" = "application/json"
    "OData-MaxVersion" = "4.0"
    "OData-Version" = "4.0"
}

# Paso 1: Obtener solución miApp
Write-Host "`n[2/4] Buscando solución '$SolutionName'..." -ForegroundColor Yellow

$solutionQuery = "$DataverseUrl/api/data/v9.2/solutions?`$filter=uniquename eq '$SolutionName'&`$select=solutionid,friendlyname,version"
$solution = (Invoke-RestMethod -Uri $solutionQuery -Method Get -Headers $headers).value[0]

if (-not $solution) {
    Write-Host "  ✗ Solución no encontrada" -ForegroundColor Red
    exit 1
}

Write-Host "  ✓ Solución encontrada: $($solution.friendlyname) v$($solution.version)" -ForegroundColor Green

# Paso 2: Obtener componentes de la solución (incluyendo referencias a PCF)
Write-Host "`n[3/4] Analizando componentes de la solución..." -ForegroundColor Yellow

$componentsUrl = "$DataverseUrl/api/data/v9.2/solutioncomponents?`$filter=_solutionid_value eq $($solution.solutionid)&`$select=componenttype,objectid"
$components = (Invoke-RestMethod -Uri $componentsUrl -Method Get -Headers $headers).value

Write-Host "  ✓ Componentes encontrados: $($components.Count)" -ForegroundColor Green

# Filtrar custom controls (type 66)
$customControls = $components | Where-Object { $_.componenttype -eq 66 }

if ($customControls.Count -eq 0) {
    Write-Host "`n⚠ No se encontraron PCF controls en la solución '$SolutionName'" -ForegroundColor Yellow
    Write-Host "  Nota: Los PCF pueden estar como dependencias no incluidas" -ForegroundColor Gray
    exit 0
}

Write-Host "  ✓ PCF Controls detectados: $($customControls.Count)" -ForegroundColor Cyan

# Paso 3: Buscar soluciones origen de cada PCF
Write-Host "`n[4/4] Identificando soluciones origen de los PCF..." -ForegroundColor Yellow

$pcfSolutions = @{}

foreach ($control in $customControls) {
    # Buscar en qué solución está cada PCF
    $pcfSolutionQuery = "$DataverseUrl/api/data/v9.2/solutioncomponents?`$filter=objectid eq $($control.objectid) and componenttype eq 66&`$expand=solutionid(`$select=uniquename,friendlyname,version,ismanaged)"
    
    try {
        $pcfSolutionData = (Invoke-RestMethod -Uri $pcfSolutionQuery -Method Get -Headers $headers).value
        
        foreach ($item in $pcfSolutionData) {
            if ($item.solutionid -and $item.solutionid.uniquename -ne $SolutionName) {
                $solName = $item.solutionid.uniquename
                
                if (-not $pcfSolutions.ContainsKey($solName)) {
                    $pcfSolutions[$solName] = @{
                        uniquename = $item.solutionid.uniquename
                        friendlyname = $item.solutionid.friendlyname
                        version = $item.solutionid.version
                        ismanaged = $item.solutionid.ismanaged
                        pcfCount = 1
                    }
                } else {
                    $pcfSolutions[$solName].pcfCount++
                }
            }
        }
    } catch {
        Write-Warning "  ⚠ Error procesando PCF: $($_.Exception.Message)"
    }
}

# Mostrar resultados
Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "RESUMEN DE PCF CONTROLS" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan

if ($pcfSolutions.Count -eq 0) {
    Write-Host "`n⚠ Los PCF controls no están en soluciones separadas" -ForegroundColor Yellow
    Write-Host "  Posibles causas:" -ForegroundColor Gray
    Write-Host "  1. PCF controls importados directamente (sin solución)" -ForegroundColor Gray
    Write-Host "  2. PCF controls en soluciones managed de Microsoft" -ForegroundColor Gray
    Write-Host "`n💡 SOLUCIÓN ALTERNATIVA:" -ForegroundColor Cyan
    Write-Host "  Los PCF deberán reinstalarse manualmente desde AppSource en restore" -ForegroundColor White
} else {
    Write-Host ""
    foreach ($sol in $pcfSolutions.Values) {
        Write-Host "📦 Solución: $($sol.friendlyname)" -ForegroundColor Yellow
        Write-Host "  Unique Name: $($sol.uniquename)" -ForegroundColor White
        Write-Host "  Versión: $($sol.version)" -ForegroundColor Gray
        Write-Host "  Tipo: $(if ($sol.ismanaged) { 'Managed (NO EXPORTABLE)' } else { 'Unmanaged (EXPORTABLE)' })" -ForegroundColor $(if ($sol.ismanaged) { 'Red' } else { 'Green' })
        Write-Host "  PCF Controls: $($sol.pcfCount)" -ForegroundColor Cyan
        Write-Host ""
    }
    
    # Filtrar solo las unmanaged (exportables)
    $exportableSolutions = $pcfSolutions.Values | Where-Object { -not $_.ismanaged }
    
    if ($exportableSolutions.Count -gt 0) {
        Write-Host "=====================================" -ForegroundColor Cyan
        Write-Host "✅ CÓDIGO PARA RUNBOOK (Automático)" -ForegroundColor Green
        Write-Host "=====================================" -ForegroundColor Cyan
        
        Write-Host "`nReemplaza esta línea en Backup-PowerPlatform.ps1:" -ForegroundColor Yellow
        Write-Host "  `$solutionName = Get-AutomationVariable -Name 'PP-SolutionName'" -ForegroundColor Gray
        
        Write-Host "`nPor este código:" -ForegroundColor Yellow
        
        $solutionArray = @($SolutionName) + ($exportableSolutions | ForEach-Object { $_.uniquename })
        
        Write-Host ""
        Write-Host "# Soluciones a exportar (principal + PCF dependencies)" -ForegroundColor Green
        Write-Host "`$solutionsToExport = @(" -ForegroundColor Green
        foreach ($sol in $solutionArray) {
            Write-Host "    `"$sol`"," -ForegroundColor Green
        }
        Write-Host ")" -ForegroundColor Green
        Write-Host ""
        
        Write-Host "Luego cambia el loop de exportación para iterar sobre `$solutionsToExport" -ForegroundColor Cyan
    } else {
        Write-Host "=====================================" -ForegroundColor Cyan
        Write-Host "⚠ NO HAY SOLUCIONES EXPORTABLES" -ForegroundColor Yellow
        Write-Host "=====================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Todas las soluciones PCF son 'Managed' (no exportables)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "💡 SOLUCIÓN:" -ForegroundColor Cyan
        Write-Host "  1. Documenta las soluciones managed en un archivo de configuración" -ForegroundColor White
        Write-Host "  2. En restore, reinstala desde AppSource o soluciones originales" -ForegroundColor White
        Write-Host ""
        Write-Host "Soluciones managed detectadas:" -ForegroundColor Gray
        foreach ($sol in ($pcfSolutions.Values | Where-Object { $_.ismanaged })) {
            Write-Host "  - $($sol.friendlyname) v$($sol.version)" -ForegroundColor Gray
        }
    }
}

Write-Host "`n=====================================" -ForegroundColor Cyan
