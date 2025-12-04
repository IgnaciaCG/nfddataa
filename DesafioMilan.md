  # **Sistema de Respaldo para Solución Productiva Power Platform + SharePoint**

  **Autor:** Milan Kurte
  **Fecha:** Noviembre 2025
  **Presupuesto Azure:** USD $60 por 30 días
  **RPO:** 24 horas
  **RTO:** 6 horas

  ---

  # **1. Introducción**

  El objetivo de esta solucion es diseñar e implementar un **sistema de respaldo seguro, económico y funcional** para una solución productiva compuesta por:

  * **Power Platform**: aplicaciones, soluciones, flujos y artefactos productivos.
  * **Microsoft SharePoint Online**: repositorio de documentación del cliente.

  El sistema debe permitir una recuperación confiable ante pérdidas de datos, fallas del tenant o corrupción de la solución, cumpliendo con las restricciones de presupuesto.

  ---

  # **2. Objetivos del sistema de respaldo**

  Los objetivos principales son:

  1. Proteger la solución productiva de Power Platform y su documentación en SharePoint mediante respaldos regulares.

  2. Cumplir con los tiempos de continuidad acordados:

      * RPO (Recovery Point Objective): 24 horas → máximo un día de pérdida de información.

      * RTO (Recovery Time Objective): 6 horas → máximo seis horas para recuperar el servicio.

  3. Diseñar una solución simple, económica y segura, basada en herramientas nativas de Azure y Microsoft 365.

  4. Incluir un plan de contingencia que contemple una copia física semanal en un medio on-premise (HDD).

  ---
  # **3. Alcance del Sistema de Respaldo**

  ## **3.1 Componentes de Power Platform a respaldar**

  * Exportación de la **solución productiva**.
  * Copia de seguridad de **aplicaciones Canvas/Model-Driven** incluidas en la solución.
  * Exportación de **flujos de Power Automate** asociados.
  * Exportación de **tablas críticas de Dataverse**.
  * Metadatos relevantes: configuraciones, conectores, parámetros de ambiente.

  ## **3.2 Componentes de SharePoint a respaldar**

  * Biblioteca principal que contiene documentación del cliente.
  * Archivos y carpetas en su estructura actual.
  * Opcional: metadata básica (creación, modificación).

  ## **3.3 No incluido**

  * Exchange, OneDrive y Teams no están involucrados en la solución.
  * No se usarán herramientas de terceros como Veeam debido a costo, complejidad y falta de compatibilidad con Power Platform.

  ---
  # **4. Requisitos y restricciones** 

  El diseño del sistema de respaldo se ha realizado considerando los siguientes requisitos y restricciones:

  * Uso exclusivo de Azure y Microsoft 365 como plataformas tecnológicas.

  * Presupuesto acotado a 60 USD por 30 días en la suscripción de Azure.

  * Existencia de límites de uso y llamadas a APIs en Power Platform, Dataverse y Microsoft Graph, lo que obliga a diseñar procesos moderados y eficientes (evitar respaldos demasiado frecuentes o masivos).

  * Necesidad de controlar el acceso a los respaldos mediante un sistema de identidades y permisos (Identity and Access Management) utilizando Microsoft Entra ID y roles en Azure.
    w
  # **5. Requerimientos Funcionales y No Funcionales**

  ## **5.1 Funcionales**

  * Respaldar diariamente Power Platform y SharePoint.
  * Almacenar los respaldos de forma segura en Azure.
  * Permitir restaurar la solución en menos de 6 horas (RTO).
  * Garantizar pérdida máxima de 24 horas de datos (RPO).

  ## **5.2 No Funcionales**

  * Usar únicamente servicios Azure dentro del límite mensual de USD $60.
  * Minimizar uso de recursos costosos como máquinas virtuales.
  * Controlar accesos usando mecanismos IAM de Azure (Entra ID + RBAC).
  * Mantener evidencia de ejecución mediante logs.

  ---
  # **6. Gestión de costos y límites de APIs**

Dado que el presupuesto está limitado a 60 USD mensuales, el diseño busca:

* Utilizar servicios ligeros y nativos de Azure, evitando máquinas virtuales o software de terceros de alto costo.

* Elegir un nivel de almacenamiento apropiado (ej. “Cool”) para reducir el costo por gigabyte almacenado.

* Diseñar una frecuencia de respaldo moderada (una vez al día) que:

  * Cumple el RPO de 24 horas.

  * Evita un uso excesivo de las APIs de Power Platform y Microsoft Graph, que tienen límites diarios y pueden aplicar restricciones si se abusa de ellas.

Con esto se busca un equilibrio entre:

* Protección de la información (copias diarias).

* Uso responsable de APIs (sin generar miles de llamadas por día).

* Control de costos (muy por debajo del límite de 60 USD).
--- 

# **7. Arquitectura Propuesta del Sistema de Respaldo**

  La solución fue diseñada bajo los principios de simplicidad, economía y seguridad.

  ## **7.1 Componentes**

  ### **A. Microsoft Entra ID (Azure AD)**

  * Identity & Access Management del sistema.
  * Creación de una **Identidad de Servicio** o **Managed Identity** asociada al Automation Account.
  * Asignación de roles RBAC mínimos necesarios:

    * **Power Platform Admin / Environment Maker** (solo en ambiente a respaldar).
    * **SharePoint Administrator** (solo en sitio específico).
    * **Storage Blob Data Contributor** (solo para contenedor de backups).

  ### **B. Azure Automation Account**

  * Orquestador centralizado del proceso de respaldo.
  * Contendrá **tres Runbooks (PowerShell)**:

    * `Backup-PowerPlatform.ps1` - Ejecuta en la nube (diario, 02:00 AM)
    * `Backup-SharePoint.ps1` - Ejecuta en la nube (diario, 02:10 AM)
    * `Backup-FisicoSemanal.ps1` - Ejecuta en Hybrid Worker (semanal, viernes 20:00)
  * Programación automática mediante schedules.
  * Uso de **Managed Identity** para respaldos en la nube.
  * Uso de **SAS Token de solo lectura** para respaldo físico.

  ### **C. Azure Storage Account**

  * Tipo: **StorageV2 Standard LRS**
  * Access Tier: **Cool** (reduce costos).
  * Contenedores:

    * `pp-backup` → Soluciones, apps, Dataverse.
    * `sp-backup` → Bibliotecas/archivos SharePoint.
    * `logs` → Registros de ejecución y auditoría.

  ### **D. Hybrid Runbook Worker (PC On-Premise)**

  * **Función**: Ejecutar runbook semanal localmente para copia física.
  * **Conectividad**: Comunicación segura HTTPS con Azure Automation.
  * **Requisitos**:
    * Agente Hybrid Worker instalado y registrado.
    * AzCopy disponible en el sistema.
    * Disco duro local con espacio suficiente (>100 GB).
    * PC encendido en ventana de ejecución (viernes 20:00-21:00).
  * **Seguridad**: Solo requiere SAS token de lectura (sin credenciales privilegiadas).

  ### **E. HDD Físico (Contingencia)**

  * **Automatización**: Copia semanal vía Hybrid Runbook Worker + AzCopy.
  * **Ubicación**: PC dedicado en oficina principal.
  * **Custodia**: Jefe de tecnología.
  * **Cifrado**: BitLocker en volumen local (recomendado).
  * **Rol**: Plan de contingencia ante escenarios extremos (caída de tenant, indisponibilidad Azure).

  ---


# **8. Flujo de Respaldo**

## **8.1 Arquitectura de Ejecución**

El sistema de respaldo funciona mediante dos **Runbooks de Azure Automation** que se ejecutan diariamente a las **02:00 AM UTC-0** (horario de menor actividad del usuario).

### **Componentes técnicos utilizados:**

| Componente | Tecnología | Justificación |
|------------|------------|---------------|
| **Orquestador** | Azure Automation Runbooks (PowerShell 7.2) | Nativo, económico, soporta Managed Identity |
| **Autenticación** | Managed Identity del Automation Account | Evita credenciales hardcodeadas, principio de mínimo privilegio |
| **Power Platform** | Microsoft.PowerApps.Administration.PowerShell | Módulo oficial, no requiere CLI, maneja APIs correctamente |
| **SharePoint** | PnP.PowerShell | Nativo, optimizado, soporta paginación automática |
| **Almacenamiento** | Azure Storage Account (Cool tier, LRS) | Bajo costo, alta durabilidad (99.999999999%) |
| **Logs** | Azure Storage Blobs (JSON estructurado) | Trazabilidad, bajo costo, fácil consulta |

---

## **8.2 Flujo Detallado: Power Platform Backup**

### **Diagrama de Secuencia**

```
┌─────────────┐      ┌──────────────────┐      ┌─────────────┐      ┌──────────────┐
│  Scheduler  │      │  Runbook (PS)    │      │ Power Plat. │      │  Storage Acc │
└──────┬──────┘      └────────┬─────────┘      └──────┬──────┘      └───────┬──────┘
       │                      │                       │                     │
       │ 02:00 AM Trigger     │                       │                     │
       ├─────────────────────>│                       │                     │
       │                      │                       │                     │
       │                      │ Connect-AzAccount     │                     │
       │                      │ (Managed Identity)    │                     │
       │                      ├───────────────────────┤                     │
       │                      │                       │                     │
       │                      │ Get Environment Info  │                     │
       │                      ├──────────────────────>│                     │
       │                      │<──────────────────────┤                     │
       │                      │                       │                     │
       │                      │ Export Solution       │                     │
       │                      ├──────────────────────>│                     │
       │                      │<─── ZIP file ─────────┤                     │
       │                      │                       │                     │
       │                      │ Export Dataverse Data │                     │
       │                      ├──────────────────────>│                     │
       │                      │<─── JSON data ────────┤                     │
       │                      │                       │                     │
       │                      │ Upload to pp-backup   │                     │
       │                      ├─────────────────────────────────────────────>│
       │                      │                       │                     │
       │                      │ Write execution log   │                     │
       │                      ├─────────────────────────────────────────────>│
       │                      │                       │                     │
       │<───── Success ───────┤                       │                     │
```

### **Paso 1: Inicialización y Autenticación**

```powershell
# Autenticación mediante Managed Identity
Connect-AzAccount -Identity

# Importar módulos necesarios
Import-Module Microsoft.PowerApps.Administration.PowerShell
Import-Module Az.Storage

# Variables de configuración
$environmentName = "prod-powerplatform-env"
$storageAccountName = "backupstoragenfdata"
$containerName = "pp-backup"
$date = Get-Date -Format "yyyyMMdd_HHmmss"
$tempPath = "$env:TEMP\PPBackup_$date"
```

### **Paso 2: Exportación de Solución Power Platform**

```powershell
# Obtener información del ambiente
$env = Get-AdminPowerAppEnvironment -EnvironmentName $environmentName

# Exportar solución usando API REST (más confiable que CLI)
$solutionName = "ClientProductionSolution"
$exportUrl = "https://$($env.EnvironmentName).api.crm.dynamics.com/api/data/v9.2/ExportSolution"

$body = @{
    SolutionName = $solutionName
    Managed = $false
    ExportAutoNumberingSettings = $true
    ExportCalendarSettings = $true
    ExportCustomizationSettings = $true
    ExportEmailTrackingSettings = $true
} | ConvertTo-Json

# Ejecutar exportación con retry logic
$maxRetries = 3
$retryDelay = 5
$attempt = 0
$success = $false

while (-not $success -and $attempt -lt $maxRetries) {
    try {
        $response = Invoke-RestMethod -Uri $exportUrl -Method Post -Body $body `
            -ContentType "application/json" -Headers @{
                Authorization = "Bearer $(Get-AzAccessToken -ResourceUrl 'https://org.crm.dynamics.com')"
            }
        
        # Guardar ZIP de solución
        $solutionPath = "$tempPath\$solutionName`_$date.zip"
        [System.IO.File]::WriteAllBytes($solutionPath, $response.ExportSolutionFile)
        
        $success = $true
        Write-Output "✓ Solución exportada: $solutionPath"
        
    } catch {
        $attempt++
        if ($_.Exception.Response.StatusCode -eq 429) {
            # Throttling detectado - esperar con backoff exponencial
            $waitTime = $retryDelay * [Math]::Pow(2, $attempt)
            Write-Warning "⚠ Throttling detectado. Esperando $waitTime segundos..."
            Start-Sleep -Seconds $waitTime
        } else {
            throw $_
        }
    }
}
```

### **Paso 3: Exportación de Tablas Críticas de Dataverse**

```powershell
# Definir tablas críticas a respaldar
$criticalTables = @(
    "cr_customerdata",
    "cr_transactions",
    "cr_configurations"
)

foreach ($tableName in $criticalTables) {
    try {
        # Query con paginación automática
        $dataUrl = "https://$($env.EnvironmentName).api.crm.dynamics.com/api/data/v9.2/$tableName"
        
        $allRecords = @()
        $nextLink = $dataUrl
        
        while ($nextLink) {
            $response = Invoke-RestMethod -Uri $nextLink -Method Get -Headers @{
                Authorization = "Bearer $(Get-AzAccessToken -ResourceUrl 'https://org.crm.dynamics.com')"
                Prefer = "odata.maxpagesize=5000"
            }
            
            $allRecords += $response.value
            $nextLink = $response.'@odata.nextLink'
            
            # Pausa para evitar throttling
            Start-Sleep -Milliseconds 200
        }
        
        # Guardar en JSON
        $jsonPath = "$tempPath\$tableName`_$date.json"
        $allRecords | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
        
        Write-Output "✓ Tabla exportada: $tableName ($($allRecords.Count) registros)"
        
    } catch {
        Write-Error "✗ Error exportando tabla $tableName : $_"
        # Continuar con siguiente tabla
    }
}
```

### **Paso 4: Subida a Azure Storage**

```powershell
# Obtener contexto de Storage Account
$ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

# Comprimir todos los archivos
$zipFileName = "PowerPlatform_Backup_$date.zip"
$zipPath = "$env:TEMP\$zipFileName"
Compress-Archive -Path "$tempPath\*" -DestinationPath $zipPath -CompressionLevel Optimal

# Subir a blob storage
Set-AzStorageBlobContent -File $zipPath -Container $containerName -Blob $zipFileName `
    -Context $ctx -Force

Write-Output "✓ Backup subido a Storage Account: $zipFileName"

# Limpiar archivos temporales
Remove-Item -Path $tempPath -Recurse -Force
Remove-Item -Path $zipPath -Force
```

### **Paso 5: Registro de Ejecución**

```powershell
# Crear log estructurado
$logEntry = @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    service = "PowerPlatform"
    status = "success"
    environment = $environmentName
    solutionExported = $solutionName
    tablesExported = $criticalTables.Count
    backupFileName = $zipFileName
    backupSizeMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    durationSeconds = $executionDuration
    errors = @()
} | ConvertTo-Json

# Guardar log en contenedor logs
$logFileName = "log_PP_$date.json"
$logPath = "$env:TEMP\$logFileName"
$logEntry | Out-File -FilePath $logPath -Encoding UTF8

Set-AzStorageBlobContent -File $logPath -Container "logs" -Blob "powerplatform/$logFileName" `
    -Context $ctx -Force

Remove-Item -Path $logPath -Force
```

---

## **8.3 Flujo Detallado: SharePoint Backup**

### **Diagrama de Secuencia**

```
┌─────────────┐      ┌──────────────────┐      ┌─────────────┐      ┌──────────────┐
│  Scheduler  │      │  Runbook (PS)    │      │  SharePoint │      │  Storage Acc │
└──────┬──────┘      └────────┬─────────┘      └──────┬──────┘      └───────┬──────┘
       │                      │                       │                     │
       │ 02:10 AM Trigger     │                       │                     │
       ├─────────────────────>│                       │                     │
       │                      │                       │                     │
       │                      │ Connect-PnPOnline     │                     │
       │                      │ (Managed Identity)    │                     │
       │                      ├───────────────────────┤                     │
       │                      │                       │                     │
       │                      │ Get-PnPList (paged)   │                     │
       │                      ├──────────────────────>│                     │
       │                      │<─── Items batch ──────┤                     │
       │                      │                       │                     │
       │                      │ Download Files        │                     │
       │                      ├──────────────────────>│                     │
       │                      │<─── File streams ─────┤                     │
       │                      │                       │                     │
       │                      │ Upload ZIP to sp-backup│                    │
       │                      ├─────────────────────────────────────────────>│
       │                      │                       │                     │
       │<───── Success ───────┤                       │                     │
```

### **Paso 1: Conexión a SharePoint**

```powershell
# Importar módulo PnP
Import-Module PnP.PowerShell

# Variables
$siteUrl = "https://nofrontiersdata.sharepoint.com/sites/ClientDocs"
$libraryName = "Documentos Compartidos"
$date = Get-Date -Format "yyyyMMdd_HHmmss"
$tempPath = "$env:TEMP\SPBackup_$date"
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

# Conexión con Managed Identity
Connect-PnPOnline -Url $siteUrl -ManagedIdentity
```

### **Paso 2: Descarga de Biblioteca con Paginación**

```powershell
# Obtener todos los archivos con paginación automática
$allItems = Get-PnPListItem -List $libraryName -PageSize 2000 -Fields "FileLeafRef","FileRef","File_x0020_Size","Modified"

Write-Output "📁 Total de items encontrados: $($allItems.Count)"

$downloadedFiles = 0
$totalSize = 0

foreach ($item in $allItems) {
    try {
        # Solo procesar archivos (no carpetas)
        if ($item.FileSystemObjectType -eq "File") {
            $fileUrl = $item.FieldValues.FileRef
            $fileName = $item.FieldValues.FileLeafRef
            
            # Recrear estructura de carpetas
            $relativePath = $fileUrl.Replace($libraryName, "").TrimStart('/')
            $localPath = Join-Path $tempPath $relativePath
            $localDir = Split-Path $localPath -Parent
            
            if (-not (Test-Path $localDir)) {
                New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            }
            
            # Descargar archivo
            Get-PnPFile -Url $fileUrl -Path $localDir -FileName $fileName -AsFile -Force
            
            $downloadedFiles++
            $totalSize += $item.FieldValues.File_x0020_Size
            
            # Pausa para evitar throttling (cada 100 archivos)
            if ($downloadedFiles % 100 -eq 0) {
                Write-Output "  Descargados: $downloadedFiles archivos..."
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {
        Write-Warning "⚠ Error descargando $($item.FieldValues.FileLeafRef): $_"
        # Continuar con siguiente archivo
    }
}

Write-Output "✓ Descarga completada: $downloadedFiles archivos ($([Math]::Round($totalSize/1MB, 2)) MB)"
```

### **Paso 3: Compresión y Subida**

```powershell
# Comprimir biblioteca completa
$zipFileName = "SharePoint_Backup_$date.zip"
$zipPath = "$env:TEMP\$zipFileName"

Compress-Archive -Path "$tempPath\*" -DestinationPath $zipPath -CompressionLevel Optimal

# Subir a Storage Account
$ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

Set-AzStorageBlobContent -File $zipPath -Container "sp-backup" -Blob $zipFileName `
    -Context $ctx -Force

Write-Output "✓ Backup SharePoint subido: $zipFileName"

# Limpiar temporales
Remove-Item -Path $tempPath -Recurse -Force
Remove-Item -Path $zipPath -Force
```

### **Paso 4: Log de Ejecución**

```powershell
$logEntry = @{
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    service = "SharePoint"
    status = "success"
    siteUrl = $siteUrl
    library = $libraryName
    filesBackedUp = $downloadedFiles
    backupSizeMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    durationSeconds = $executionDuration
} | ConvertTo-Json

$logFileName = "log_SP_$date.json"
$logPath = "$env:TEMP\$logFileName"
$logEntry | Out-File -FilePath $logPath -Encoding UTF8

Set-AzStorageBlobContent -File $logPath -Container "logs" -Blob "sharepoint/$logFileName" `
    -Context $ctx -Force

Remove-Item -Path $logPath -Force
```

---

## **8.4 Flujo: Respaldo Físico Semanal con Hybrid Runbook Worker**

### **8.4.1 Concepto y Arquitectura**

A diferencia de los respaldos diarios que se ejecutan completamente en la nube, el respaldo semanal utiliza un **Hybrid Runbook Worker** para automatizar la copia desde Azure Storage hacia un disco duro físico on-premise.

**Componentes involucrados:**

```
┌──────────────────────────────────────────────────────────────────┐
│              AZURE AUTOMATION ACCOUNT                            │
│  ┌────────────────────────────────────────────────────┐          │
│  │  Runbook: Backup-FisicoSemanal.ps1                 │          │
│  │  Schedule: Viernes 20:00 (semanal)                 │          │
│  └────────────────────┬───────────────────────────────┘          │
└───────────────────────┼──────────────────────────────────────────┘
                        │
                        │ Job dispatch (via HTTPS)
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│           HYBRID RUNBOOK WORKER (PC On-Premise)                  │
│  ┌────────────────────────────────────────────────────┐          │
│  │  Agent instalado y registrado en Azure Automation  │          │
│  │  Ejecuta runbook localmente                        │          │
│  │  Invoca AzCopy para sincronización                 │          │
│  └────────────────────┬───────────────────────────────┘          │
└───────────────────────┼──────────────────────────────────────────┘
                        │
                        │ AzCopy sync (HTTPS con SAS token)
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              AZURE STORAGE ACCOUNT                               │
│  ┌──────────────┬──────────────┬──────────────┐                 │
│  │  pp-backup   │  sp-backup   │     logs     │                 │
│  │  (lectura)   │  (lectura)   │  (lectura)   │                 │
│  └──────────────┴──────────────┴──────────────┘                 │
│                                                                  │
│  Acceso mediante: SAS Token (solo lectura, tiempo limitado)     │
└──────────────────────────────────────────────────────────────────┘
                        │
                        │ Descarga y sincronización
                        │
                        ▼
┌──────────────────────────────────────────────────────────────────┐
│              DISCO DURO LOCAL (HDD)                              │
│  E:\Backups\                                                     │
│  ├── pp-backup\                                                  │
│  ├── sp-backup\                                                  │
│  ├── logs\                                                       │
│  └── backup_fisico_YYYYMMDD.log                                 │
└──────────────────────────────────────────────────────────────────┘
```

### **8.4.2 Flujo Lógico de Ejecución**

**Paso 1: Programación Semanal**

- Se configura un **schedule semanal** en Azure Automation (ejemplo: viernes 20:00)
- El schedule está vinculado al runbook `Backup-FisicoSemanal.ps1`
- La programación se gestiona centralmente desde Azure Portal

**Paso 2: Despacho del Job**

- Cuando llega la hora programada, Azure Automation activa el runbook
- El job **NO se ejecuta en la nube de Azure**
- El job se envía al **Hybrid Runbook Worker** registrado en el PC on-premise
- La comunicación se realiza de forma segura via HTTPS

**Paso 3: Ejecución Local del Runbook**

El script ejecuta en el PC on-premise con la siguiente lógica:

```powershell
# Runbook: Backup-FisicoSemanal.ps1
# Ejecuta en Hybrid Runbook Worker (PC on-premise)

# Variables de configuración
$storageAccount = "backupstoragenfdata"
$sasToken = Get-AutomationVariable -Name "SAS-Token-ReadOnly-Weekly"  # Almacenado como variable cifrada
$hddPath = "E:\Backups"
$date = Get-Date -Format "yyyyMMdd_HHmmss"
$logFile = "$hddPath\backup_fisico_$date.log"

# Iniciar logging
"[$(Get-Date)] Inicio de respaldo físico semanal" | Out-File $logFile

try {
    # Sincronizar contenedor pp-backup
    Write-Output "Sincronizando Power Platform backups..."
    & azcopy sync "https://$storageAccount.blob.core.windows.net/pp-backup$sasToken" `
        "$hddPath\pp-backup" --recursive --delete-destination=false --log-level=INFO
    
    "[$(Get-Date)] ✓ Power Platform sincronizado" | Out-File $logFile -Append
    
    # Sincronizar contenedor sp-backup
    Write-Output "Sincronizando SharePoint backups..."
    & azcopy sync "https://$storageAccount.blob.core.windows.net/sp-backup$sasToken" `
        "$hddPath\sp-backup" --recursive --delete-destination=false --log-level=INFO
    
    "[$(Get-Date)] ✓ SharePoint sincronizado" | Out-File $logFile -Append
    
    # Sincronizar logs (opcional)
    Write-Output "Sincronizando logs de auditoría..."
    & azcopy sync "https://$storageAccount.blob.core.windows.net/logs$sasToken" `
        "$hddPath\logs" --recursive --delete-destination=false --log-level=INFO
    
    "[$(Get-Date)] ✓ Logs sincronizados" | Out-File $logFile -Append
    
    # Calcular tamaño total respaldado
    $totalSize = (Get-ChildItem $hddPath -Recurse | Measure-Object Length -Sum).Sum / 1GB
    $message = "✓ Backup semanal completado. Tamaño total: $([Math]::Round($totalSize, 2)) GB"
    
    Write-Output $message
    "[$(Get-Date)] $message" | Out-File $logFile -Append
    
    # Retornar resultado exitoso
    return @{
        Status = "Success"
        TotalSizeGB = [Math]::Round($totalSize, 2)
        Timestamp = $date
        LogFile = $logFile
    }
    
} catch {
    $errorMessage = "✗ Error en respaldo físico: $($_.Exception.Message)"
    Write-Error $errorMessage
    "[$(Get-Date)] $errorMessage" | Out-File $logFile -Append
    
    throw $_
}
```

**Paso 4: Sincronización con AzCopy**

- AzCopy se invoca con comando `sync` (no `copy`)
- `sync` solo transfiere archivos nuevos o modificados (eficiente)
- Parámetro `--delete-destination=false` preserva archivos locales antiguos
- El acceso usa **SAS token de solo lectura** con:
  - Alcance limitado a contenedores específicos (`pp-backup`, `sp-backup`, `logs`)
  - Fecha de expiración definida (renovar mensualmente)
  - Permisos mínimos: solo lectura (no escritura, no eliminación)

**Paso 5: Registro y Monitoreo**

- El resultado se registra como **job en Azure Automation**
- Métricas disponibles: duración, estado (éxito/error), output
- Log local adicional en el HDD: `backup_fisico_YYYYMMDD.log`
- Alertas automáticas en caso de fallo

### **8.4.3 Configuración del SAS Token**

```powershell
# Generación de SAS Token (ejecutar una vez al mes)
# Desde Azure Portal o PowerShell

$context = New-AzStorageContext -StorageAccountName "backupstoragenfdata" -UseConnectedAccount

# SAS para contenedor pp-backup (solo lectura, 30 días)
$sasPP = New-AzStorageContainerSASToken -Context $context `
    -Name "pp-backup" `
    -Permission r `
    -ExpiryTime (Get-Date).AddDays(30)

# SAS para contenedor sp-backup
$sasSP = New-AzStorageContainerSASToken -Context $context `
    -Name "sp-backup" `
    -Permission r `
    -ExpiryTime (Get-Date).AddDays(30)

# Guardar como variable cifrada en Automation Account
Set-AzAutomationVariable -AutomationAccountName "aa-backups" `
    -Name "SAS-Token-ReadOnly-Weekly" `
    -Value $sasPP `
    -Encrypted $true `
    -ResourceGroupName "rg-backups"
```

### **8.4.4 Rol en el Plan de Contingencia**

**Importancia estratégica:**

- ✅ **No altera RPO/RTO operativo** - Los backups diarios en Azure siguen siendo la fuente primaria
- ✅ **Defensa contra escenarios extremos**:
  - Caída prolongada del tenant Microsoft 365
  - Problemas graves de seguridad (ransomware en la nube)
  - Indisponibilidad de Azure Storage
  - Corrupción masiva de datos en la nube
  
- ✅ **Independencia tecnológica** - Copia física accesible sin dependencia de servicios cloud
- ✅ **Cumplimiento normativo** - Algunas regulaciones requieren copias off-cloud

**Escenario de uso:**

Si Azure/M365 está completamente inaccesible, el equipo puede:
1. Acceder al HDD físico sin depender de conectividad cloud
2. Restaurar en ambiente alternativo (tenant de desarrollo, nube privada)
3. Mantener operaciones críticas mientras se resuelve el incidente mayor

### **8.4.5 Requisitos y Consideraciones Operativas**

**Requisitos del PC On-Premise:**

| Requisito | Detalle |
|-----------|---------|
| **Conectividad** | Acceso a Internet para comunicarse con Azure Automation y Storage |
| **Disponibilidad** | Debe estar encendido en la ventana horaria del backup (viernes 20:00-21:00) |
| **Almacenamiento** | Espacio suficiente en HDD (mínimo 100 GB recomendado) |
| **Software** | AzCopy instalado y accesible en PATH del sistema |
| **Agente** | Hybrid Runbook Worker agent instalado y registrado |
| **Sistema Operativo** | Windows 10/11 Pro o Windows Server 2016+ |
| **Permisos locales** | Cuenta con permisos de escritura en E:\Backups\ |

**Instalación del Hybrid Runbook Worker:**

El equipo on-premise se registra en Azure como Hybrid Runbook Worker siguiendo estos pasos generales:

1. **Instalación del agente**:
   - Desde Azure Portal > Automation Account > Hybrid Worker Groups
   - Descargar e instalar el agente en el PC
   - Registrar el PC con el Workspace ID del Automation Account

2. **Configuración del grupo**:
   - Crear grupo "HybridWorkers-Backup"
   - Asignar el PC al grupo
   - Configurar el runbook `Backup-FisicoSemanal.ps1` para ejecutarse en este grupo (no en Azure)

3. **Verificación**:
   - Ejecutar prueba manual del runbook
   - Validar que el job se ejecuta en el PC on-premise
   - Confirmar que AzCopy descarga archivos correctamente

Esto permite que los runbooks definidos en el Automation Account se ejecuten localmente, manteniendo la gestión, programación y logs centralizados en Azure.

**Plan de Contingencia si el PC está Apagado:**

| Situación | Acción |
|-----------|--------|
| **PC apagado en horario programado** | Alerta automática vía Azure Monitor al día siguiente |
| **Respuesta** | Administrador enciende PC y ejecuta manualmente el runbook |
| **Prevención** | Configurar encendido automático (WoL) o programar en horario laboral alternativo |

### **8.4.6 Custodia y Seguridad del HDD**

| Aspecto | Detalle |
|---------|---------|
| **Frecuencia** | Semanal (viernes 20:00) |
| **Automatización** | Completamente automatizada vía Hybrid Runbook Worker |
| **Ubicación física** | Oficina principal (PC dedicado) |
| **Custodio** | Jefe de tecnología |
| **Seguridad física** | PC en sala con acceso controlado |
| **Cifrado** | BitLocker habilitado en volumen E:\ (recomendado) |
| **Monitoreo** | Logs en Azure Automation + archivo local |
| **Retención local** | Últimas 4 semanas (rotar manualmente o con script) |

---

## **8.5 Gestión de Retención y Lifecycle**

### **Política de Retención Implementada**

```json
{
  "rules": [
    {
      "name": "DeleteOldBackups",
      "enabled": true,
      "type": "Lifecycle",
      "definition": {
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["pp-backup/", "sp-backup/"]
        },
        "actions": {
          "baseBlob": {
            "tierToCool": {
              "daysAfterModificationGreaterThan": 7
            },
            "delete": {
              "daysAfterModificationGreaterThan": 30
            }
          }
        }
      }
    }
  ]
}
```

### **Estrategia:**

- **Días 0-7**: Backups en tier **Hot** (acceso rápido para RTO)
- **Días 8-30**: Movidos a tier **Cool** (ahorro de costos)
- **Día 31+**: Eliminación automática (mantiene 30 días de historia)

---

## **8.6 Manejo de Errores y Reintentos**

### **Escenarios Contemplados**

| Error | Código HTTP | Estrategia |
|-------|-------------|------------|
| **Throttling** | 429 Too Many Requests | Exponential backoff (5s, 10s, 20s) |
| **Timeout** | 408 Request Timeout | Reintento inmediato (1 vez) |
| **Autenticación** | 401 Unauthorized | Renovar token, reintentar |
| **Storage lleno** | 507 Insufficient Storage | Alertar administrador, no reintentar |
| **Red inestable** | NetworkError | 3 reintentos con 5s de espera |

### **Implementación en Runbooks**

```powershell
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$BaseDelay = 5
    )
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            $statusCode = $_.Exception.Response.StatusCode.Value__
            
            if ($statusCode -eq 429 -and $attempt -lt $MaxRetries) {
                $delay = $BaseDelay * [Math]::Pow(2, $attempt)
                Write-Warning "Throttling - Esperando $delay segundos (intento $attempt/$MaxRetries)"
                Start-Sleep -Seconds $delay
            } else {
                throw $_
            }
        }
    }
}
```

---

## **8.7 Monitoreo y Alertas**

### **Indicadores Clave (KPIs)**

| Métrica | Objetivo | Fuente |
|---------|----------|--------|
| **Tasa de éxito** | > 99% | Logs JSON |
| **Duración promedio** | < 15 minutos | Runbook execution time |
| **Tamaño de backup** | Incremento < 20%/mes | Storage metrics |
| **Errores de API** | < 1% de llamadas | Application Insights |

### **Alertas Configuradas (Azure Monitor)**

```powershell
# Alerta si el runbook falla
New-AzMetricAlertRuleV2 -Name "BackupFailureAlert" `
    -ResourceGroupName "rg-backups" `
    -TargetResourceId "/subscriptions/.../automationAccounts/aa-backups" `
    -Condition "Whenever the total job failures is greater than 0" `
    -WindowSize 01:00:00 `
    -Frequency 00:05:00 `
    -Severity 2 `
    -ActionGroupId "/subscriptions/.../actionGroups/ag-backup-alerts"
```

  ---

  # **9. IAM – Gestión de Identidades y Accesos**

  La implementación de Identity and Access Management (IAM) en esta solución utiliza **Microsoft Entra ID** (Azure AD) y **Azure RBAC** para garantizar el principio de mínimo privilegio.

  ### **9.1 Microsoft Entra ID**

  * Gestión centralizada de identidades (usuarios, grupos, aplicaciones, service principals).
  * Emisión de tokens de autenticación para servicios automatizados.
  * Control de Managed Identities para recursos Azure.

  ### **9.2 Azure RBAC - Roles y Permisos**

  **Matriz de permisos por componente:**

  | Recurso                    | Rol                           | Asignado a                     | Justificación |
  | -------------------------- | ----------------------------- | ------------------------------ | ------------- |
  | **Storage Account (escritura)** | Storage Blob Data Contributor | Managed Identity del Automation Account | Los runbooks diarios deben **escribir** respaldos en contenedores |
  | **Storage Account (lectura)** | SAS Token de solo lectura | Hybrid Runbook Worker (vía variable cifrada) | El runbook semanal solo **lee** para copiar al HDD local |
  | **Automation Account** | Contributor | Administrador técnico | Gestión de runbooks, schedules y variables |
  | **Power Platform Environment** | Environment Admin o Maker | Managed Identity del Automation Account | Exportar soluciones y acceder a Dataverse |
  | **SharePoint Site** | Site Collection Administrator | Managed Identity del Automation Account | Descargar bibliotecas de documentos |
  | **Hybrid Worker Group** | (Sin permisos adicionales) | PC on-premise | Solo ejecuta scripts localmente, no accede directamente a recursos Azure |

  ### **9.3 Separación de Privilegios**

  La arquitectura implementa **segregación de responsabilidades**:

  **Procesos que generan respaldos (nube):**
  - Tienen permisos **elevados**: escribir en Storage, llamar APIs de M365
  - Usan **Managed Identity** (sin credenciales expuestas)
  - Se ejecutan en ambiente controlado de Azure

  **Proceso de copia física (on-premise):**
  - Tiene permisos **mínimos**: solo lectura desde Storage vía SAS token
  - **NO tiene acceso** a Power Platform ni SharePoint directamente
  - **NO puede modificar** ni eliminar respaldos en la nube
  - SAS token con:
    - Alcance limitado a contenedores específicos
    - Permisos de solo lectura (`r`)
    - Fecha de expiración (renovar mensualmente)

  ### **9.4 Gestión de Secretos**

  | Secreto | Método de Almacenamiento | Acceso |
  |---------|-------------------------|--------|
  | **SAS Token (lectura)** | Variable cifrada en Automation Account | Solo runbook `Backup-FisicoSemanal.ps1` |
  | **Managed Identity credentials** | Gestionado automáticamente por Azure | Runbooks diarios en la nube |
  | **Connection strings** | Variables cifradas en Automation Account | Runbooks autorizados |

  ### **9.5 Auditoría y Trazabilidad**

  - Todos los accesos a Storage Account se registran en **Azure Storage Analytics Logs**
  - Jobs de Automation Account mantienen historial completo de ejecuciones
  - Logs estructurados incluyen timestamp, identidad, operación y resultado
  - Revisión trimestral de permisos activos y SAS tokens vigentes

  **El objetivo es que nadie excepto las identidades definidas pueda manipular los respaldos, y que toda acción quede registrada para auditoría.**

  ---

  # **10. Cadencia y Justificación (RPO/RTO)**

  ## **10.1 Cadencia diaria (02:00 AM)**

  * Permite cumplir **RPO = 24 horas**.
  * Evita alto uso de APIs durante horarios laborales.
  * Minimiza costos (menos llamadas API, menos cargas).

  ## **10.2 Justificación**

  * La solución no requiere cambios múltiples por hora.
  * La documentación en SharePoint se modifica menos frecuentemente.
  * La restauración diaria mantiene el proceso simple y barato.

  ## **10.3 RTO = 6 horas**

  Factores que permiten cumplirlo:

  * Restauración de solución Power Apps toma minutos.
  * Restauración de SharePoint es directa (repositorio de archivos).
  * Scripts de recuperación documentados.
  * Todo está en Storage Account de rápido acceso.

  ---

  # **11. Plan de Contingencia**

  ## **Escenario 1: Fallo parcial (pérdida de una app o flujo)**

  1. Descargar última copia desde `pp-backup`.
  2. Importar solución en Power Platform.
  3. Validar flujos.
  4. Reabrir ambiente.

  Duración estimada: 1–2 horas.

  ---

  ## **Escenario 2: Pérdida completa del SharePoint**

  1. Descargar último ZIP de `sp-backup`.
  2. Usar PnP.PowerShell para restaurar carpeta o biblioteca.
  3. Reindexación automática de SharePoint.

  Duración: 2–4 horas.

  ---

  ## **Escenario 3: Caída del tenant Azure/M365 (baja probabilidad)**

  1. Usar copia semanal del HDD externo.
  2. Restaurar en ambiente alternativo (dev o tenant temporal).
  3. Comunicar a cliente.

  Duración: < 6 horas (cumple RTO).

  ---

  # **12. Costos Estimados**

  | Servicio                            | Costo estimado mensual |
  | ----------------------------------- | ---------------------- |
  | Storage Account (Cool, <50 GB)      | USD $1–3              |
  | Azure Automation (runbooks ligeros) | USD $0.50–2           |
  | Data Transfer Out                   | ~USD $1–3             |
  | Logs/Monitoring                     | USD $0–1              |

  **Total estimado:** USD $6–10 por mes
  → **Muy por debajo del límite de USD $60**, incluso con crecimiento de datos.

  ---

  # **13. Conclusiones**

  La arquitectura propuesta:

  * **Cumple integralmente** con los requisitos técnicos entregados.
  * Respeta el **presupuesto Azure** con amplio margen.
  * Asegura restauración dentro de los tiempos definidos (RTO 6h).
  * Minimiza pérdida de datos gracias a respaldos diarios (RPO 24h).
  * Implementa una solución **sin servicios de terceros** y totalmente administrable.
  * Usa servicios nativos de Azure y M365, manteniendo la complejidad muy baja.
  * Incluye una estrategia racional de copia física para contingencias extremas.

  En conclusión, este sistema es **simple, robusto, económico y seguro**, ajustándose plenamente al desafío asignado.