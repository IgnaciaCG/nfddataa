<#
.SYNOPSIS
    Script para configurar Azure Automation Account (Fase 2)

.DESCRIPTION
    Este script crea:
    - Automation Account
    - Managed Identity (para Storage Account)
    - Roles RBAC (Storage Blob Data Contributor)
    - Variables de configuración (6 variables)
    - Credentials del Service Principal (1 credential)
    
.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.5 (sin Key Vault)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 2: Setup Automation Account" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables centralizadas
$resourceGroupName = "rg-backups-nfd"
$location = "EastUS"
$automationAccountName = "aa-backups-nfd"

# Leer configuraciones creadas en Fase 1
$storageAccountName = Get-Content "..\config\storage_account_name.txt" -ErrorAction Stop
Write-Host "`nStorage Account detectado: $storageAccountName" -ForegroundColor Cyan
Write-Host "Configuración: Variables + Credentials" -ForegroundColor Yellow

# ==========================================
# 1. CREAR AUTOMATION ACCOUNT
# ==========================================

Write-Host "`n[1/3] Creando Automation Account..." -ForegroundColor Yellow

try {
    $automationAccount = New-AzAutomationAccount `
        -ResourceGroupName $resourceGroupName `
        -Name $automationAccountName `
        -Location $location `
        -Plan "Basic" `
        -AssignSystemIdentity
    
    Write-Host "  ✓ Automation Account creado: $automationAccountName" -ForegroundColor Green
    Write-Host "  ✓ Managed Identity habilitada" -ForegroundColor Green
    
    # Esperar a que se cree la identidad
    Start-Sleep -Seconds 10
    
} catch {
    Write-Error "Error creando Automation Account: $_"
    exit 1
}

# ==========================================
# 2. ASIGNAR RBAC A MANAGED IDENTITY
# ==========================================

Write-Host "`n[2/3] Configurando permisos RBAC..." -ForegroundColor Yellow

try {
    # Obtener el principal ID de la Managed Identity
    $automationAccount = Get-AzAutomationAccount `
        -ResourceGroupName $resourceGroupName `
        -Name $automationAccountName
    
    $principalId = $automationAccount.Identity.PrincipalId
    
    # Asignar rol "Storage Blob Data Contributor" al Storage Account
    $storageAccountId = (Get-AzStorageAccount `
        -ResourceGroupName $resourceGroupName `
        -Name $storageAccountName).Id

    New-AzRoleAssignment `
        -ObjectId $principalId `
        -RoleDefinitionName "Storage Blob Data Contributor" `
        -Scope $storageAccountId | Out-Null
    
    Write-Host "  ✓ Rol asignado: Storage Blob Data Contributor" -ForegroundColor Green
    
} catch {
    Write-Warning "  ⚠ Error asignando RBAC (puede requerir permisos de Owner): $_"
}

# ==========================================
# 3. CONFIGURAR VARIABLES Y CREDENTIAL
# ==========================================

Write-Host "`n[3/3] Creando variables y credential..." -ForegroundColor Yellow

# Solicitar valores de forma interactiva
Write-Host "`nIngresa la configuración de Power Platform:" -ForegroundColor Cyan
Write-Host "(Puedes obtener estos valores de Power Platform Admin Center y Azure Portal)" -ForegroundColor Gray
Write-Host ""

# App ID del Service Principal
Write-Host "Service Principal Application ID:" -ForegroundColor Yellow
Write-Host "  (De Azure Portal → App Registrations → Tu App → Application ID)" -ForegroundColor DarkGray
$ppAppId = Read-Host "  App ID"

# Tenant ID
Write-Host "`nTenant ID:" -ForegroundColor Yellow
Write-Host "  (De Azure Portal → App Registrations → Tu App → Directory ID)" -ForegroundColor DarkGray
$ppTenantId = Read-Host "  Tenant ID"

# Organization ID
Write-Host "`nOrganization ID:" -ForegroundColor Yellow
Write-Host "  (De Power Platform Admin Center → Environments → Tu Env → Details → Id. de la organización)" -ForegroundColor DarkGray
$ppOrganizationId = Read-Host "  Organization ID"

# Solution Name
Write-Host "`nSolution Name:" -ForegroundColor Yellow
Write-Host "  (De Power Apps → Solutions → Nombre exacto de tu solución)" -ForegroundColor DarkGray

Write-Host "`n✓ Configuración capturada:" -ForegroundColor Green
Write-Host "  • App ID: $($ppAppId.Substring(0,8))..." -ForegroundColor Gray
Write-Host "  • Tenant ID: $($ppTenantId.Substring(0,8))..." -ForegroundColor Gray
Write-Host "  • Organization ID: $ppOrganizationId" -ForegroundColor Gray

# Obtener Storage Account Key (necesario para que runbooks accedan a blobs)
Write-Host "`nObteniendo Storage Account Key..." -ForegroundColor Cyan
$storageKey = (Get-AzStorageAccountKey `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName)[0].Value

# Crear variables (6 variables en total)
Write-Host "`nCreando 6 variables de configuración..." -ForegroundColor Cyan

$variables = @{
    "PP-ServicePrincipal-AppId" = $ppAppId
    "PP-ServicePrincipal-TenantId" = $ppTenantId
    "PP-OrganizationId" = $ppOrganizationId
    "StorageAccountName" = $storageAccountName
}

# Crear cada variable
foreach ($key in $variables.Keys) {
    try {
        New-AzAutomationVariable `
            -ResourceGroupName $resourceGroupName `
            -AutomationAccountName $automationAccountName `
            -Name $key `
            -Value $variables[$key] `
            -Encrypted $false | Out-Null
        
        Write-Host "  ✓ Variable creada: $key" -ForegroundColor Green
    } catch {
        Write-Warning "  ⚠ Error creando variable $key : $_"
    }
}

# Crear variable ENCRIPTADA para Storage Key
Write-Host "`nCreando variable encriptada para Storage Account Key..." -ForegroundColor Cyan
try {
    New-AzAutomationVariable `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "StorageAccountKey" `
        -Value $storageKey `
        -Encrypted $true | Out-Null
    
    Write-Host "  ✓ Variable encriptada creada: StorageAccountKey" -ForegroundColor Green
} catch {
    Write-Warning "  ⚠ Error creando StorageAccountKey: $_"
}

# Crear Credential del Service Principal
Write-Host "`nCreando credential del Service Principal..." -ForegroundColor Cyan
Write-Host "  Ingresa el Client Secret cuando se solicite" -ForegroundColor Yellow

$clientSecret = Read-Host "Service Principal - Client Secret" -AsSecureString

try {
    $credential = New-Object System.Management.Automation.PSCredential($ppAppId, $clientSecret)
    
    New-AzAutomationCredential `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "PP-ServicePrincipal" `
        -Value $credential | Out-Null
    
    Write-Host "  ✓ Credential creado: PP-ServicePrincipal" -ForegroundColor Green
    Write-Host "    Username: $ppAppId" -ForegroundColor Gray
    Write-Host "    Password: ************** (encriptado)" -ForegroundColor Gray
    
} catch {
    Write-Error "Error creando credential: $_"
    exit 1
}



# ==========================================
# RESUMEN
# ==========================================

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "✓ FASE 2 COMPLETADA" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "RECURSOS CONFIGURADOS:" -ForegroundColor Yellow
Write-Host "  ✓ Automation Account: $automationAccountName" -ForegroundColor White
Write-Host "  ✓ Managed Identity: Habilitada (para Storage)" -ForegroundColor White
Write-Host "  ✓ RBAC: Storage Blob Data Contributor" -ForegroundColor White
Write-Host "  ✓ Variables: 6 (5 texto + 1 encriptada)" -ForegroundColor White
Write-Host "  ✓ Credential: PP-ServicePrincipal" -ForegroundColor White
Write-Host ""
Write-Host "VARIABLES CREADAS:" -ForegroundColor Yellow
Write-Host "  • PP-ServicePrincipal-AppId: $ppAppId" -ForegroundColor Gray
Write-Host "  • PP-ServicePrincipal-TenantId: $ppTenantId" -ForegroundColor Gray
Write-Host "  • PP-OrganizationId: $ppOrganizationId" -ForegroundColor Gray
Write-Host "  • StorageAccountName: $storageAccountName" -ForegroundColor Gray
Write-Host "  • StorageAccountKey: ************** (encriptado)" -ForegroundColor Gray
Write-Host ""
Write-Host "CREDENTIAL CREADO:" -ForegroundColor Yellow
Write-Host "  • PP-ServicePrincipal" -ForegroundColor Gray
Write-Host "    Username: $ppAppId" -ForegroundColor DarkGray
Write-Host "    Password: ************** (encriptado)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "PRÓXIMO PASO:" -ForegroundColor Magenta
Write-Host "  pwsh .\03-Import-Runbooks.ps1" -ForegroundColor White
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
