<#
.SYNOPSIS
    Runbook para respaldo físico semanal a HDD on-premise

.DESCRIPTION
    Este runbook se ejecuta en un Hybrid Runbook Worker local y sincroniza
    backups de Power Platform desde Azure Storage hacia un disco duro físico.
    
    Usa AzCopy para transferencia eficiente.

.NOTES
    Autor: Milan Kurte
    Fecha: Diciembre 2025
    Versión: 1.0
    
    Requisitos:
    - Hybrid Runbook Worker instalado en PC local
    - AzCopy instalado y en PATH
    - SAS Token de lectura configurado
    - Espacio en disco suficiente (>50 GB para Power Platform)
#>

param()

# ==========================================
# CONFIGURACIÓN
# ==========================================

$ErrorActionPreference = "Stop"
$date = Get-Date -Format "yyyyMMdd_HHmmss"

Write-Output "======================================"
Write-Output "Inicio de Backup Físico Semanal"
Write-Output "Fecha: $date"
Write-Output "Ejecutando en: $env:COMPUTERNAME"
Write-Output "======================================"

try {
    # ==========================================
    # 1. LEER CONFIGURACIÓN
    # ==========================================
    
    Write-Output "`n[1/3] Leyendo configuración..."
    
    $storageAccount = Get-AutomationVariable -Name "StorageAccountName"
    $sasToken = Get-AutomationVariable -Name "SAS-Token-ReadOnly-Weekly"
    $hddPath = "E:\Backups"  # Ajustar según configuración local
    
    if (-not (Test-Path $hddPath)) {
        throw "Ruta de HDD no existe: $hddPath"
    }
    
    $logFile = "$hddPath\backup_fisico_$date.log"
    
    Write-Output "  ✓ Storage Account: $storageAccount"
    Write-Output "  ✓ Destino HDD: $hddPath"
    
    # ==========================================
    # 2. SINCRONIZAR POWER PLATFORM BACKUPS
    # ==========================================
    
    Write-Output "`n[2/3] Sincronizando Power Platform backups..."
    
    $sourceUrl = "https://$storageAccount.blob.core.windows.net/pp-backup$sasToken"
    $destPath = "$hddPath\pp-backup"
    
    & azcopy sync $sourceUrl $destPath --recursive --delete-destination=false --log-level=INFO
    
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  ✓ Power Platform sincronizado"
    } else {
        throw "Error sincronizando Power Platform (exit code: $LASTEXITCODE)"
    }
    
    # ==========================================
    # 3. SINCRONIZAR LOGS (OPCIONAL)
    # ==========================================
    
    Write-Output "`n[3/3] Sincronizando logs de auditoría..."
    
    $sourceUrl = "https://$storageAccount.blob.core.windows.net/logs$sasToken"
    $destPath = "$hddPath\logs"
    
    & azcopy sync $sourceUrl $destPath --recursive --delete-destination=false --log-level=INFO
    
    if ($LASTEXITCODE -eq 0) {
        Write-Output "  ✓ Logs sincronizados"
    } else {
        Write-Warning "  ⚠ Error sincronizando logs (no crítico)"
    }
    
    # ==========================================
    # RESUMEN
    # ==========================================
    
    $totalSize = (Get-ChildItem $hddPath -Recurse -ErrorAction SilentlyContinue | 
                  Measure-Object Length -Sum).Sum / 1GB
    
    $summary = @"

======================================
✓ Backup Semanal Completado
======================================
Fecha: $(Get-Date)
Tamaño Total: $([Math]::Round($totalSize, 2)) GB
Ubicación: $hddPath
Log: $logFile
======================================
"@
    
    Write-Output $summary
    $summary | Out-File -FilePath $logFile
    
    # Retornar resultado
    return @{
        Status = "Success"
        TotalSizeGB = [Math]::Round($totalSize, 2)
        Timestamp = $date
        LogFile = $logFile
    }
    
} catch {
    $errorMessage = "✗ Error en backup físico: $($_.Exception.Message)"
    Write-Error $errorMessage
    $errorMessage | Out-File -FilePath $logFile -Append -ErrorAction SilentlyContinue
    throw
}
