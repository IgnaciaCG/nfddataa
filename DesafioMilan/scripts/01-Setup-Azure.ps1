<#
.SYNOPSIS
    Script para configurar infraestructura Azure (Fase 1)

.DESCRIPTION
    Este script crea:
    - Resource Group
    - Storage Account con ZRS
    - Contenedores (pp-backup, logs)
    - Lifecycle policies
    - Se usan Variables + Credentials directamente

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.5 (sin Key Vault)
#>

[CmdletBinding()]
param()

# ==========================================
# CONFIGURACIÓN CENTRALIZADA
# ==========================================

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 1: Setup Azure Infrastructure" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables centralizadas (fácil de modificar para otros proyectos)
$resourceGroupName = "rg-backups-nfd"
$location = "EastUS"
$storageAccountName = "backupnfd$(Get-Random -Minimum 1000 -Maximum 9999)"

# ==========================================
# 1. CONECTAR A AZURE
# ==========================================

Write-Host "`n[1/4] Conectando a Azure..." -ForegroundColor Yellow

try {
    Connect-AzAccount -ErrorAction Stop
    $context = Get-AzContext
    Write-Host "  ✓ Conectado como: $($context.Account.Id)" -ForegroundColor Green
    Write-Host "  ✓ Suscripción: $($context.Subscription.Name)" -ForegroundColor Green
} catch {
    Write-Error "Error conectando a Azure. Verifica tus credenciales."
    exit 1
}

# ==========================================
# 2. CREAR RESOURCE GROUP
# ==========================================

Write-Host "`n[2/4] Creando Resource Group..." -ForegroundColor Yellow

try {
    $rg = New-AzResourceGroup -Name $resourceGroupName -Location $location -Force
    Write-Host "  ✓ Resource Group creado: $resourceGroupName" -ForegroundColor Green
    Write-Host "  ✓ Ubicación: $location" -ForegroundColor Green
} catch {
    Write-Error "Error creando Resource Group: $_"
    exit 1
}

# ==========================================
# 3. CREAR STORAGE ACCOUNT
# ==========================================

Write-Host "`n[3/4] Creando Storage Account..." -ForegroundColor Yellow

try {
    $storageAccount = New-AzStorageAccount `
        -ResourceGroupName $resourceGroupName `
        -Name $storageAccountName `
        -Location $location `
        -SkuName "Standard_ZRS" `
        -Kind "StorageV2" `
        -AccessTier "Cool" `
        -AllowBlobPublicAccess $false `
        -MinimumTlsVersion "TLS1_2" `
        -EnableHttpsTrafficOnly $true
    
    Write-Host "  ✓ Storage Account creado: $storageAccountName" -ForegroundColor Green
    Write-Host "  ✓ SKU: Standard_ZRS (3 Availability Zones)" -ForegroundColor Green
    Write-Host "  ✓ Access Tier: Cool" -ForegroundColor Green
    
    # Guardar nombre para uso futuro
    $storageAccountName | Out-File -FilePath "..\config\storage_account_name.txt" -Force
    
} catch {
    Write-Error "Error creando Storage Account: $_"
    exit 1
}

# ==========================================
# 4. CREAR CONTENEDORES Y LIFECYCLE POLICY
# ==========================================

Write-Host "`n[4/4] Creando contenedores y lifecycle policy..." -ForegroundColor Yellow

try {
    $ctx = $storageAccount.Context
    # Contenedores para Power Platform y logs
    $containers = @("pp-backup", "logs")
    
    foreach ($containerName in $containers) {
        try {
            New-AzStorageContainer -Name $containerName -Context $ctx -Permission Off | Out-Null
            Write-Host "  ✓ Contenedor creado: $containerName" -ForegroundColor Green
        } catch {
            Write-Warning "  ⚠ Contenedor $containerName ya existe o error: $_"
        }
    }
    
} catch {
    Write-Error "Error creando contenedores: $_"
    exit 1
}

# Configurar lifecycle policy (dentro del mismo paso 4)

try {
    # Crear policy usando objetos PowerShell (método correcto para Az module)
    # Retención de 6 meses: 7 días Hot, días 8-60 Cool, >60 días Cold, eliminar a 180 días
    
    # Crear acción para mover a Cool tier
    $actionCool = Add-AzStorageAccountManagementPolicyAction `
        -BaseBlobAction TierToCool `
        -DaysAfterModificationGreaterThan 7
    
    # Agregar acción para mover a Cold tier
    $actionCold = Add-AzStorageAccountManagementPolicyAction `
        -InputObject $actionCool `
        -BaseBlobAction TierToCold `
        -DaysAfterModificationGreaterThan 60
    
    # Agregar acción para eliminar
    $actionDelete = Add-AzStorageAccountManagementPolicyAction `
        -InputObject $actionCold `
        -BaseBlobAction Delete `
        -DaysAfterModificationGreaterThan 180
    
    # Crear filtro para aplicar solo a pp-backup/
    $filter = New-AzStorageAccountManagementPolicyFilter `
        -PrefixMatch "pp-backup/" `
        -BlobType blockBlob
    
    # Crear regla con acciones y filtros
    $rule = New-AzStorageAccountManagementPolicyRule `
        -Name "BackupRetentionPolicy" `
        -Action $actionDelete `
        -Filter $filter
    
    # Aplicar política al Storage Account
    $policy = Set-AzStorageAccountManagementPolicy `
        -ResourceGroupName $resourceGroupName `
        -StorageAccountName $storageAccountName `
        -Rule $rule
    
    Write-Host "  ✓ Lifecycle policy configurada (6 meses):" -ForegroundColor Green
    Write-Host "    - Días 0-7: Hot tier" -ForegroundColor Cyan
    Write-Host "    - Días 8-60: Cool tier" -ForegroundColor Cyan
    Write-Host "    - Días 61-180: Cold tier" -ForegroundColor Cyan
    Write-Host "    - Día 181+: Eliminación automática" -ForegroundColor Cyan
    
    # Verificar que se aplicó correctamente
    Write-Host "`n  ℹ Verificando configuración..." -ForegroundColor Yellow
    $verifyPolicy = Get-AzStorageAccountManagementPolicy `
        -ResourceGroupName $resourceGroupName `
        -StorageAccountName $storageAccountName `
        -ErrorAction Stop
    
    if ($verifyPolicy) {
        Write-Host "  ✓ Verificación exitosa: Política activa en Storage Account" -ForegroundColor Green
    }
    
} catch {
    Write-Host "  ✗ Error configurando lifecycle policy" -ForegroundColor Red
    Write-Host "  Detalle: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Línea: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "`n  📋 SOLUCIÓN MANUAL:" -ForegroundColor Yellow
    Write-Host "  1. Azure Portal → Storage Account: $storageAccountName" -ForegroundColor White
    Write-Host "  2. Data management → Lifecycle management → Add rule" -ForegroundColor White
    Write-Host "  3. Configurar:" -ForegroundColor White
    Write-Host "     - Move to cool: 7 days" -ForegroundColor Cyan
    Write-Host "     - Move to cold: 60 days" -ForegroundColor Cyan
    Write-Host "     - Delete: 180 days" -ForegroundColor Cyan
    Write-Host "     - Blob prefix: pp-backup/" -ForegroundColor Cyan
    Write-Host "`n  ⚠ Continuando sin lifecycle policy (puedes agregarlo después)..." -ForegroundColor Yellow
}

# ==========================================
# RESUMEN
# ==========================================

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "✓ FASE 1 COMPLETADA" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "RECURSOS CREADOS:" -ForegroundColor Yellow
Write-Host "  Resource Group:   $resourceGroupName" -ForegroundColor White
Write-Host "  Storage Account:  $storageAccountName" -ForegroundColor White
Write-Host "  Ubicación:        $location" -ForegroundColor White
Write-Host "  Contenedores:     pp-backup, logs" -ForegroundColor White
Write-Host "  Lifecycle Policy: 180 días (Hot→Cool→Cold→Delete)" -ForegroundColor White
Write-Host ""
Write-Host "MÉTODO DE SEGURIDAD:" -ForegroundColor Yellow
Write-Host "  ✓ Variables + Credentials (Automation Account)" -ForegroundColor Cyan
Write-Host "  ℹ Key Vault NO necesario" -ForegroundColor Gray
Write-Host ""
Write-Host "ARCHIVOS DE CONFIGURACIÓN:" -ForegroundColor Yellow
Write-Host "  ..\config\storage_account_name.txt" -ForegroundColor Cyan
Write-Host ""
Write-Host "PRÓXIMO PASO:" -ForegroundColor Magenta
Write-Host "  .\02-Setup-Automation.ps1" -ForegroundColor White
Write-Host "  (Creará Variables + Credentials)" -ForegroundColor Cyan
Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
