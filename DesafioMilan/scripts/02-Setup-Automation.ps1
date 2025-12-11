<#
.SYNOPSIS
    Script para configurar Azure Automation Account (Fase 2)

.DESCRIPTION
    Este script crea:
    - Automation Account
    - Managed Identity
    - Roles RBAC
    - Variables de configuración
    - Credentials del Service Principal

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.0
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 2: Setup Automation Account" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables
$resourceGroupName = "rg-backups-nfd"
$location = "EastUS"
$automationAccountName = "aa-backups-nfd"

# Leer storage account name
$storageAccountName = Get-Content "..\config\storage_account_name.txt" -ErrorAction Stop

Write-Host "`nStorage Account detectado: $storageAccountName" -ForegroundColor Cyan

# ==========================================
# 1. CREAR AUTOMATION ACCOUNT
# ==========================================

Write-Host "`n[1/4] Creando Automation Account..." -ForegroundColor Yellow

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

Write-Host "`n[2/4] Configurando permisos RBAC..." -ForegroundColor Yellow

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
# 3. CONFIGURAR VARIABLES
# ==========================================

Write-Host "`n[3/4] Creando variables de configuración..." -ForegroundColor Yellow

# Pedir información al usuario
Write-Host "`nIngresa la siguiente información:" -ForegroundColor Cyan

$ppAppId = Read-Host "Service Principal - Application ID"
$ppTenantId = Read-Host "Service Principal - Tenant ID (nfddata.com)"
$ppEnvironmentName = Read-Host "Power Platform - Environment Name"
$ppSolutionName = Read-Host "Power Platform - Solution Name"

# Obtener Storage Account Key (necesario para que runbooks accedan a blobs)
Write-Host "`nObteniendo Storage Account Key..." -ForegroundColor Cyan
$storageKey = (Get-AzStorageAccountKey `
    -ResourceGroupName $resourceGroupName `
    -Name $storageAccountName)[0].Value

# Crear variables (solo Power Platform)
$variables = @{
    "StorageAccountName" = $storageAccountName
    "PP-ServicePrincipal-AppId" = $ppAppId
    "PP-ServicePrincipal-TenantId" = $ppTenantId
    "PP-EnvironmentName" = $ppEnvironmentName
    "PP-SolutionName" = $ppSolutionName
}

# Crear variable ENCRIPTADA para Storage Key
Write-Host "Creando variable encriptada para Storage Account Key..." -ForegroundColor Cyan
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

# ==========================================
# 4. CREAR CREDENTIAL
# ==========================================

Write-Host "`n[4/4] Configurando credential del Service Principal..." -ForegroundColor Yellow

$clientSecret = Read-Host "Service Principal - Client Secret" -AsSecureString

try {
    $credential = New-Object System.Management.Automation.PSCredential($ppAppId, $clientSecret)
    
    New-AzAutomationCredential `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "PP-ServicePrincipal" `
        -Value $credential | Out-Null
    
    Write-Host "  ✓ Credential creado: PP-ServicePrincipal" -ForegroundColor Green
    
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
Write-Host "Automation Account: $automationAccountName" -ForegroundColor White
Write-Host "Managed Identity: Habilitada" -ForegroundColor White
Write-Host "Variables configuradas: $($variables.Count + 1) (incluye StorageAccountKey)" -ForegroundColor White
Write-Host "Credentials configurados: 1" -ForegroundColor White
Write-Host "`nPróximo paso: .\03-Import-Runbooks.ps1" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Cyan
