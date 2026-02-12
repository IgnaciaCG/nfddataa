<#
.SYNOPSIS
    Script para configurar schedules de runbooks (Fase 4)

.DESCRIPTION
    Crea los schedules automáticos:
    - Backup-PowerPlatform: Diario 02:00 AM
    - Backup-FisicoSemanal: Domingo 02:00 AM

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.5 (sin Key Vault)
    
    Zonas horarias comunes:
    - "Eastern Standard Time" (US East)
    - "Central Standard Time" (US Central)
    - "Pacific Standard Time" (US West)
    - "SA Pacific Standard Time" (Sudamérica - Colombia, Perú, Ecuador)
    - "Argentina Standard Time" (Argentina)
    - "GMT Standard Time" (UK)
    - "Central European Standard Time" (Europa)
#>

[CmdletBinding()]
param()

# ==========================================
# CONFIGURACIÓN CENTRALIZADA
# ==========================================

$ErrorActionPreference = "Stop"

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "FASE 4: Configurar Schedules" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan

# Variables centralizadas (MODIFICA AQUÍ para tu proyecto)
$resourceGroupName = "rg-backups-nfd"        # ← Mismo que 01, 02, 03
$automationAccountName = "aa-backups-nfd"    # ← Mismo que 02, 03
$timeZone = "Eastern Standard Time"          # ← Tu zona horaria (ver lista arriba)
$backupHour = 2                               # ← Hora del backup (formato 24h: 0-23)

# ==========================================
# 1. SCHEDULE POWER PLATFORM
# ==========================================

Write-Host "`n[1/2] Creando schedule para Power Platform..." -ForegroundColor Yellow

try {
    # Usar variable configurable
    $startTime = (Get-Date).Date.AddDays(1).AddHours($backupHour)
    
    $schedulePP = New-AzAutomationSchedule `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "Daily-PowerPlatform-02AM" `
        -StartTime $startTime `
        -DayInterval 1 `
        -TimeZone $timeZone `
        -Description "Backup diario de Power Platform a las 02:00 AM"
    
    # Vincular a runbook
    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -RunbookName "Backup-PowerPlatform" `
        -ScheduleName "Daily-PowerPlatform-02AM" | Out-Null
    
    Write-Host "  ✓ Schedule creado y vinculado: Diario 02:00 AM" -ForegroundColor Green
    
} catch {
    Write-Error "  ✗ Error creando schedule Power Platform: $_"
}

# ==========================================
# 2. SCHEDULE BACKUP FÍSICO
# ==========================================

Write-Host "`n[2/2] Creando schedule para Backup Físico..." -ForegroundColor Yellow

try {
    # Obtener próximo domingo usando variable configurable
    $today = Get-Date
    $daysUntilSunday = 7 - [int]$today.DayOfWeek
    $nextSunday = $today.AddDays($daysUntilSunday).Date.AddHours($backupHour)
    
    $schedulePhysical = New-AzAutomationSchedule `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -Name "Weekly-Physical-Sunday-02AM" `
        -StartTime $nextSunday `
        -WeekInterval 1 `
        -DaysOfWeek "Sunday" `
        -TimeZone $timeZone `
        -Description "Backup semanal a HDD físico (Domingo 02:00 AM)"
    
    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $resourceGroupName `
        -AutomationAccountName $automationAccountName `
        -RunbookName "Backup-FisicoSemanal" `
        -ScheduleName "Weekly-Physical-Sunday-02AM" | Out-Null
    
    Write-Host "  ✓ Schedule creado y vinculado: Semanal Domingo 02:00 AM" -ForegroundColor Green
    Write-Host "  ⚠ NOTA: Este runbook requiere Hybrid Worker configurado" -ForegroundColor Yellow
    
} catch {
    Write-Error "  ✗ Error creando schedule Backup Físico: $_"
}

# ==========================================
# RESUMEN
# ==========================================

Write-Host "`n=====================================" -ForegroundColor Cyan
Write-Host "✓ FASE 4 COMPLETADA" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "SCHEDULES CONFIGURADOS:" -ForegroundColor Yellow
Write-Host "  Total: 2" -ForegroundColor White
Write-Host "  ✓ Power Platform: Diario $($backupHour):00 AM" -ForegroundColor Green
Write-Host "  ✓ Backup Físico: Semanal Domingo $($backupHour):00 AM" -ForegroundColor Green
Write-Host ""
Write-Host "CONFIGURACIÓN:" -ForegroundColor Yellow
Write-Host "  Zona Horaria: $timeZone" -ForegroundColor Cyan
Write-Host "  Hora de Backup: $($backupHour):00 (formato 24h)" -ForegroundColor Cyan
Write-Host ""
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
Write-Host "🎉 SETUP COMPLETO - TODO LISTO" -ForegroundColor Green
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "RECURSOS CREADOS:" -ForegroundColor Yellow
Write-Host "  ✓ Resource Group" -ForegroundColor Green
Write-Host "  ✓ Storage Account (con lifecycle policies)" -ForegroundColor Green
Write-Host "  ✓ Automation Account (con Managed Identity)" -ForegroundColor Green
Write-Host "  ✓ Variables + Credentials (6 variables + 1 credential)" -ForegroundColor Green
Write-Host "  ✓ 3 Runbooks importados y publicados" -ForegroundColor Green
Write-Host "  ✓ 2 Schedules automáticos configurados" -ForegroundColor Green
Write-Host ""
Write-Host "PRÓXIMOS PASOS (OPCIONALES):" -ForegroundColor Magenta
Write-Host "  1. Probar runbooks manualmente:" -ForegroundColor White
Write-Host "     Azure Portal → Automation Account → Runbooks → Backup-PowerPlatform → Start" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. Configurar Hybrid Worker (para backup físico):" -ForegroundColor White
Write-Host "     Necesario solo si usas Backup-FisicoSemanal" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. Configurar alertas de monitoreo:" -ForegroundColor White
Write-Host "     Azure Portal → Automation Account → Alerts → New alert rule" -ForegroundColor Cyan
Write-Host ""
Write-Host "════════════════════════════════════" -ForegroundColor Cyan
