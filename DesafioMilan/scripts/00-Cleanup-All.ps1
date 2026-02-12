# 🧹 Script de Limpieza - Empezar desde Cero

<#
.SYNOPSIS
    Elimina todos los recursos de Azure para empezar setup desde cero

.DESCRIPTION
    Este script elimina:
    - Resource Group completo (incluye Storage Account y Automation Account)
    - Archivos de configuración locales
    
    Después de ejecutar esto, puedes ejecutar 01-04 desde cero.

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.5 (sin Key Vault)
#>

param(
    [switch]$Force  # No pedir confirmación
)

$ErrorActionPreference = "Continue"

Write-Host "=========================================" -ForegroundColor Red
Write-Host "🧹 LIMPIEZA COMPLETA DE RECURSOS" -ForegroundColor Red
Write-Host "=========================================" -ForegroundColor Red
Write-Host ""

# Variables (deben coincidir con los scripts de setup)
$resourceGroupName = "rg-backups-nfd"

# ==========================================
# CONFIRMACIÓN
# ==========================================

if (-not $Force) {
    Write-Host "⚠️  ADVERTENCIA: Esto eliminará TODOS los recursos:" -ForegroundColor Yellow
    Write-Host "  - Resource Group: $resourceGroupName" -ForegroundColor Yellow
    Write-Host "  - Storage Account con todos los backups" -ForegroundColor Yellow
    Write-Host "  - Automation Account con runbooks, variables y schedules" -ForegroundColor Yellow
    Write-Host ""
    
    $confirmation = Read-Host "¿Estás seguro? Escribe 'SI' para confirmar"
    
    if ($confirmation -ne "SI") {
        Write-Host ""
        Write-Host "❌ Operación cancelada" -ForegroundColor Red
        exit
    }
}

Write-Host ""

# ==========================================
# 1. ELIMINAR RESOURCE GROUP
# ==========================================

Write-Host "[1/2] Eliminando Resource Group..." -ForegroundColor Yellow

try {
    $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
    
    if ($rg) {
        Write-Host "  Eliminando: $resourceGroupName" -ForegroundColor Cyan
        Write-Host "  ⏳ Esto puede tomar 2-5 minutos..." -ForegroundColor Cyan
        
        Remove-AzResourceGroup -Name $resourceGroupName -Force -ErrorAction Stop | Out-Null
        
        Write-Host "  ✓ Resource Group eliminado" -ForegroundColor Green
    } else {
        Write-Host "  ℹ Resource Group no existe (ya limpio)" -ForegroundColor Cyan
    }
    
} catch {
    Write-Host "  ⚠ Error eliminando Resource Group: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ==========================================
# 2. LIMPIAR ARCHIVOS DE CONFIGURACIÓN
# ==========================================

Write-Host "`n[2/2] Limpiando archivos de configuración locales..." -ForegroundColor Yellow

$configFiles = @(
    "..\config\storage_account_name.txt"
)

foreach ($file in $configFiles) {
    if (Test-Path $file) {
        Remove-Item $file -Force
        Write-Host "  ✓ Eliminado: $file" -ForegroundColor Green
    }
}

# ==========================================
# RESUMEN
# ==========================================

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "✓ LIMPIEZA COMPLETADA" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "RECURSOS ELIMINADOS:" -ForegroundColor Yellow
Write-Host "  ✓ Resource Group: $resourceGroupName" -ForegroundColor Green
Write-Host "  ✓ Storage Account (con backups)" -ForegroundColor Green
Write-Host "  ✓ Automation Account (con runbooks y variables)" -ForegroundColor Green
Write-Host "  ✓ Archivos de configuración locales" -ForegroundColor Green
Write-Host ""
Write-Host "PRÓXIMOS PASOS:" -ForegroundColor Magenta
Write-Host "  1. Verifica en Azure Portal que todo fue eliminado" -ForegroundColor White
Write-Host "  2. Ejecuta setup desde cero:" -ForegroundColor White
Write-Host "     .\01-Setup-Azure.ps1" -ForegroundColor Cyan
Write-Host "     .\02-Setup-Automation.ps1" -ForegroundColor Cyan
Write-Host "     .\03-Import-Runbooks.ps1" -ForegroundColor Cyan
Write-Host "     .\04-Configure-Schedules.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
