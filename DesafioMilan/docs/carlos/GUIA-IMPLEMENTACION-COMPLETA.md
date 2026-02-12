# 🚀 Guía de Implementación - Backup Automatizado Power Platform

**Versión:** 1.5 (Variables + Credentials)  
**Fecha:** Diciembre 2025  
**Tiempo Estimado:** 45-60 minutos  
**Nivel:** Intermedio

---

## 📋 Índice

1. [¿Qué Vamos a Construir?](#qué-vamos-a-construir)
2. [Pre-requisitos](#pre-requisitos)
3. [Fase 0: Service Principal](#fase-0-service-principal)
4. [Opción A: Implementación con Scripts](#opción-a-implementación-con-scripts)
5. [Opción B: Implementación Manual (Azure Portal)](#opción-b-implementación-manual-azure-portal)
6. [Configurar para TU Tenant](#configurar-para-tu-tenant)
7. [Verificación y Pruebas](#verificación-y-pruebas)
8. [Troubleshooting](#troubleshooting)

---

## 🎯 ¿Qué Vamos a Construir?

Un sistema que automáticamente:
- ✅ Hace backup de tu solución Power Platform **todos los días a las 2 AM**
- ✅ Guarda backups en Azure Storage (redundancia multi-zona)
- ✅ Elimina backups viejos automáticamente (> 180 días)
- ✅ Genera logs de cada ejecución
- ✅ **Costo:** ~$0.60/mes

### Arquitectura

```
┌─────────────────────────────────────────┐
│   Azure Automation Account              │
│   - Lee credenciales (Variables)        │
│   - Ejecuta backup cada día 2 AM        │
└──────────────┬──────────────────────────┘
               │
               ├──→ Power Platform
               │    (exporta solución)
               │
               └──→ Azure Storage
                    (guarda .zip + logs)
```

**Componentes:**
1. **Resource Group** - Contenedor de recursos
2. **Storage Account** - Almacena backups (.zip) y logs (.json)
3. **Automation Account** - Ejecuta scripts PowerShell automáticamente
4. **Variables** - Guarda configuración (AppId, Environment, Solution)
5. **Credential** - Guarda Client Secret encriptado
6. **Runbooks** - Scripts que hacen el backup
7. **Schedules** - Programación automática (diario 2 AM)

---

## ✅ Pre-requisitos

### 1. Accesos Necesarios

**Azure:**
- [ ] Cuenta Azure con rol **Contributor** o **Owner**
- [ ] Presupuesto: ~$0.60/mes

**Power Platform:**
- [ ] Acceso a Power Platform Admin Center
- [ ] Permisos de **System Administrator** en tu environment

### 2. Software (Solo para Scripts)

Si usas scripts automatizados:

**macOS:**
```bash
# PowerShell 7
brew install --cask powershell

# Verificar
pwsh --version  # Debe ser 7.x
```

**Windows:**
```powershell
# Descargar e instalar PowerShell 7
# https://github.com/PowerShell/PowerShell/releases

# Verificar
pwsh --version
```

**Módulos PowerShell** (se instalan automáticamente):
```powershell
# Ejecutar UNA vez
Install-Module Az.Accounts, Az.Resources, Az.Storage, Az.Automation -Scope CurrentUser -Force
Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force
```

### 3. Información que Necesitarás

Prepara esta información antes de empezar:

| Dato | Dónde Encontrarlo |
|------|-------------------|
| **Organization ID** | Power Platform Admin Center → Environments → [Tu Env] → Details → Id. de la organización |
| **Solution Name** | Power Apps → Solutions → [Nombre de tu solución] |
| **Región Azure** | Elige la más cercana (EastUS, WestEurope, etc.) |

---

## 🔐 FASE 0: Crear Service Principal

**¿Qué es?** Una "cuenta de servicio" que permite al script autenticarse en Power Platform.

**Duración:** 10 minutos

---

### Paso 0.1: Crear App Registration

1. Ve a: https://portal.azure.com
2. **Microsoft Entra ID** → **App registrations** → **+ New registration**

3. Configurar:
   ```
   Name: BackupAutomation-ServicePrincipal
   Supported account types: Accounts in this organizational directory only
   Redirect URI: (dejar vacío)
   ```

4. Click **Register**

5. **⚠️ IMPORTANTE - Guardar estos valores:**
   ```
   Application (client) ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Directory (tenant) ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

---

### Paso 0.2: Crear Client Secret

1. En tu app → **Certificates & secrets**
2. **Client secrets** → **+ New client secret**
3. Description: `BackupAutomation-Secret`
4. Expires: **12 months** (o más largo)
5. Click **Add**

6. **⚠️ CRÍTICO - Copiar el VALUE inmediatamente:**
   ```
   Value: abc123...xyz (se muestra UNA sola vez)
   ```

**Guarda estos 3 valores en un lugar seguro:**
- Application ID
- Tenant ID  
- Client Secret Value

---

### Paso 0.3: Dar Permisos API

1. En tu app → **API permissions**
2. **+ Add a permission** → **Dynamics CRM**
3. **Delegated permissions** → Marcar `user_impersonation`
4. **Add permissions**
5. Click **Grant admin consent for [tu organización]** → **Yes**

---

### Paso 0.4: Asignar a Power Platform

**Opción A: Automático (recomendado)**
El script 02-Setup-Automation.ps1 lo hará automáticamente.

**Opción B: Manual**

1. Power Platform Admin Center: https://admin.powerplatform.microsoft.com
2. **Environments** → Selecciona tu environment
3. **Settings** → **Users + permissions** → **Application users**
4. **+ New app user**
5. **+ Add an app** → Buscar tu Application ID → Seleccionar
6. **Business unit:** (default)
7. **Security roles:** Marcar **System Administrator**
8. Click **Create**

**✅ CHECKPOINT:** Tienes 3 valores guardados (AppId, TenantId, ClientSecret)

---

## 🚀 Opción A: Implementación con Scripts

**Ventajas:**
- ✅ Rápido (10 minutos)
- ✅ Automatizado
- ✅ Menos errores

**Pre-requisito:** PowerShell 7 instalado

---

### Script 01: Crear Infraestructura Azure

**¿Qué hace?**
- Crea Resource Group
- Crea Storage Account con 2 contenedores (pp-backup, logs)
- Configura lifecycle policy (elimina backups > 180 días)

**Ejecución:**

```powershell
# 1. Conectar a Azure
Connect-AzAccount

# 2. Navegar a carpeta scripts
cd /ruta/a/DesafioMilan/scripts

# 3. Ejecutar script
pwsh ./01-Setup-Azure.ps1
```

**¿Qué valores usa?**
```
Resource Group: rg-backups-nfd
Storage Account: backupnfd#### (número aleatorio)
Región: EastUS
```

**Output esperado:**
```
✓ Resource Group creado: rg-backups-nfd
✓ Storage Account creado: backupnfd5768
✓ Contenedores: pp-backup, logs
✓ Lifecycle policy: 180 días
```

**Duración:** 3-5 minutos

---

### Script 02: Configurar Automation Account

**¿Qué hace?**
- Crea Automation Account con Managed Identity
- Configura permisos RBAC para Storage
- Crea 6 Variables de configuración
- Crea 1 Credential encriptado

**⚠️ PREPARACIÓN:** Ten a mano estos valores antes de ejecutar:

| Valor | Dónde Obtenerlo |
|-------|-----------------|
| **Application ID** | Azure Portal → App Registrations → Tu App → Application (client) ID |
| **Tenant ID** | Azure Portal → App Registrations → Tu App → Directory (tenant) ID |
| **Organization ID** | Power Platform Admin Center → Environments → Tu Env → Details → Id. de la organización |
| **Solution Name** | Power Apps → Solutions → Nombre exacto de tu solución |
| **Client Secret** | El VALUE que copiaste en el Paso 0.2 |

**Ejecución:**

```powershell
pwsh ./02-Setup-Automation.ps1
```

**El script te solicitará (INTERACTIVO):**

```
Service Principal Application ID:
  App ID: 7fc4ef96-8566-4adb-a579-2030dbf71c35

Tenant ID:
  Tenant ID: 344457f2-bd03-46c6-9974-97bffb8f626a

Organization ID:
  Organization ID: 5531fe7d-a3c5-f011-8729-6045bd3b6fec

Solution Name:
  Solution Name: miApp

Service Principal - Client Secret: ****************
```

**Output esperado:**
```
✓ Automation Account creado: aa-backups-nfd
✓ Managed Identity habilitada
✓ Variables creadas: 6
✓ Credential creado: PP-ServicePrincipal
```

**Duración:** 5-8 minutos

---

### Script 03: Importar Runbooks + Módulos

**¿Qué hace?**
- **Instala automáticamente 3 módulos PowerShell** (en background)
- Importa 3 runbooks (scripts de backup)
- Los publica (los hace ejecutables)

**Ejecución:**

```powershell
pwsh ./03-Import-Runbooks.ps1
```

**Output esperado:**
```
[0/3] Instalando módulos de PowerShell...
  ✓ Módulo importado: Az.Accounts (instalando en background...)
  ✓ Módulo importado: Az.Storage (instalando en background...)
  ✓ Módulo importado: Microsoft.PowerApps.Administration.PowerShell (instalando...)

[1/3] Importando: Backup-PowerPlatform...
  ✓ Runbook importado y publicado: Backup-PowerPlatform

[2/3] Importando: Restore-PowerPlatform...
  ✓ Runbook importado y publicado: Restore-PowerPlatform

[3/3] Importando: Backup-FisicoSemanal...
  ✓ Runbook importado y publicado: Backup-FisicoSemanal

⚠ ESPERAR INSTALACIÓN DE MÓDULOS:
  1. Azure Portal → Automation Account → Modules
  2. Verificar que los 3 módulos tengan Status = 'Available'
  3. Tiempo estimado: 15-20 minutos total
```

**⚠️ IMPORTANTE:** Los módulos se instalan en **background**. Debes esperar 15-20 minutos antes de ejecutar los runbooks.

**Verificar instalación de módulos:**

1. Azure Portal → Automation Account `aa-backups-nfd`
2. **Modules** → Verificar Status de cada módulo:

| Módulo | Status Esperado | Tiempo |
|--------|-----------------|--------|
| `Az.Accounts` | Available (verde) | ~5 min |
| `Az.Storage` | Available (verde) | ~8 min |
| `Microsoft.PowerApps.Administration.PowerShell` | Available (verde) | ~10 min |

**Si algún módulo falla (Status = Failed):**
1. Eliminar el módulo
2. **Browse from gallery** → Buscar el módulo
3. Re-importar manualmente

**Duración:** 2 min (script) + 15-20 min (esperar módulos)

---

### Script 04: Configurar Schedules

**¿Qué hace?**
- Programa backup diario a las 2:00 AM
- Programa backup semanal (opcional, requiere Hybrid Worker)

**Ejecución:**

```powershell
pwsh ./04-Configure-Schedules.ps1
```

**Output esperado:**
```
✓ Schedule creado: Daily-PowerPlatform-02AM
✓ Schedule vinculado a runbook Backup-PowerPlatform
```

**Duración:** 2 minutos

**✅ COMPLETADO con Scripts - Ir a [Verificación](#verificación-y-pruebas)**

---

## 🖱️ Opción B: Implementación Manual (Azure Portal)

**Ventajas:**
- ✅ No requiere PowerShell
- ✅ Control visual total
- ✅ Aprende Azure Portal

**Desventaja:** Más lento (~45 minutos)

---

### Paso B1: Crear Resource Group

1. Azure Portal: https://portal.azure.com
2. **Resource groups** → **+ Create**
3. Configurar:
   ```
   Resource group: rg-backups-nfd (o el nombre que prefieras)
   Region: East US (o la más cercana a ti)
   ```
4. **Review + create** → **Create**

---

### Paso B2: Crear Storage Account

1. **Storage accounts** → **+ Create**
2. **Basics:**
   ```
   Resource group: rg-backups-nfd
   Storage account name: backupnfd1234 (debe ser único globalmente)
   Region: East US (misma que Resource Group)
   Performance: Standard
   Redundancy: Zone-redundant storage (ZRS)
   ```
3. **Advanced:**
   ```
   Access tier: Cool
   ```
4. **Review + create** → **Create**

---

### Paso B3: Crear Contenedores

1. Storage Account creado → **Data storage** → **Containers**
2. **+ Container:**
   ```
   Name: pp-backup
   Public access level: Private
   ```
3. Crear otro:
   ```
   Name: logs
   Public access level: Private
   ```

---

### Paso B4: Configurar Lifecycle Policy

1. Storage Account → **Data management** → **Lifecycle management**
2. **+ Add rule**
3. **Details:**
   ```
   Rule name: DeleteOldBackups
   Rule scope: Limit blobs with filters
   Blob type: Block blobs
   Blob subtype: Base blobs
   ```
4. **Base blobs:**
   ```
   Last modified: more than 180 days ago
   Then: Delete the blob
   ```
5. **Filter set:**
   ```
   Blob prefix: pp-backup/
   ```
6. **Add**

---

### Paso B5: Crear Automation Account

1. **Automation Accounts** → **+ Create**
2. Configurar:
   ```
   Resource group: rg-backups-nfd
   Automation account name: aa-backups-nfd
   Region: East US (misma región)
   ```
3. **Review + create** → **Create**

---

### Paso B6: Habilitar Managed Identity

1. Automation Account → **Account settings** → **Identity**
2. **System assigned:**
   ```
   Status: On
   ```
3. **Save**
4. **Copiar Object (principal) ID** para siguiente paso

---

### Paso B7: Asignar Permisos RBAC

1. Storage Account → **Access Control (IAM)**
2. **+ Add** → **Add role assignment**
3. **Role:** `Storage Blob Data Contributor`
4. **Next** → **Assign access to:** `Managed identity`
5. **+ Select members** → **Automation Accounts** → Seleccionar `aa-backups-nfd`
6. **Review + assign**

---

### Paso B8: Crear Variables

1. Automation Account → **Shared Resources** → **Variables**
2. Crear **6 variables** (Click **+ Add variable** para cada una):

| Name | Value | Encrypted |
|------|-------|-----------|
| `PP-ServicePrincipal-AppId` | [Tu Application ID] | No |
| `PP-ServicePrincipal-TenantId` | [Tu Tenant ID] | No |
| `PP-OrganizationId` | [ID de la organización] | No |
| `PP-SolutionName` | [Tu Solution Name] | No |
| `StorageAccountName` | `backupnfd1234` | No |
| `StorageAccountKey` | [Ir a Storage → Access keys → key1] | **Yes** |

---

### Paso B9: Crear Credential

1. Automation Account → **Shared Resources** → **Credentials**
2. **+ Add credential**
3. Configurar:
   ```
   Name: PP-ServicePrincipal
   User name: [Tu Application ID]
   Password: [Tu Client Secret del Paso 0.2]
   Confirm password: [Repetir]
   ```
4. **Create**

---

### Paso B10: Instalar Módulos

1. Automation Account → **Shared Resources** → **Modules**
2. **Browse from gallery**
3. Buscar e instalar **UNO POR UNO** (esperar que Status = Available):

- `Az.Accounts`
- `Az.Storage`
- `Microsoft.PowerApps.Administration.PowerShell`

**Duración:** ~20 minutos

---

### Paso B11: Importar Runbooks

**⚠️ Necesitas los archivos de los runbooks.** Descargar de: https://github.com/IgnaciaCG/nfddataa

Para cada runbook:

1. Automation Account → **Process Automation** → **Runbooks**
2. **+ Create a runbook**
3. **Name:** `Backup-PowerPlatform` (primer runbook)
4. **Runbook type:** `PowerShell`
5. **Runtime version:** `7.2`
6. **Create**
7. Copiar contenido del archivo `Backup-PowerPlatform.ps1`
8. Pegar en el editor
9. **Save** → **Publish**

**Repetir para:**
- `Restore-PowerPlatform.ps1`
- `Backup-FisicoSemanal.ps1`

---

### Paso B12: Crear Schedule

1. Automation Account → **Shared Resources** → **Schedules**
2. **+ Add a schedule**
3. Configurar:
   ```
   Name: Daily-PowerPlatform-02AM
   Starts: [Mañana a las 02:00]
   Time zone: [Tu zona horaria]
   Recurrence: Recurring
   Recur every: 1 Day
   ```
4. **Create**

---

### Paso B13: Vincular Schedule a Runbook

1. Automation Account → **Runbooks** → `Backup-PowerPlatform`
2. **Resources** → **Schedules**
3. **+ Add schedule** → **Link a schedule to your runbook**
4. Seleccionar: `Daily-PowerPlatform-02AM`
5. **OK**

**✅ COMPLETADO con Azure Portal**

---

## ⚙️ Verificar Configuración

### Si usaste Scripts:

El Script 02 te solicitó los valores de forma **interactiva**. No hay nada que modificar en el código.

**Verificar que ingresaste correctamente:**

1. Azure Portal → Automation Account `aa-backups-nfd`
2. **Variables** → Verificar valores:
   - `PP-ServicePrincipal-AppId`: ✓
   - `PP-ServicePrincipal-TenantId`: ✓
   - `PP-OrganizationId`: ✓ (Id. de la organización del environment)
   - `PP-SolutionName`: ✓ (case-sensitive)

**Si un valor está incorrecto:**

```powershell
# Actualizar variable específica
Set-AzAutomationVariable `
    -ResourceGroupName "rg-backups-nfd" `
    -AutomationAccountName "aa-backups-nfd" `
    -Name "PP-OrganizationId" `
    -Value "TU-ORGANIZATION-ID-CORRECTO"
```

### Si usaste Azure Portal:

**Verificar Variables:**

1. Automation Account → **Variables**
2. Verificar que tengan TUS valores:
   - `PP-ServicePrincipal-AppId`: ✓
   - `PP-ServicePrincipal-TenantId`: ✓
   - `PP-OrganizationId`: ✓ (Id. de la organización del environment)
   - `PP-SolutionName`: ✓ (tu solución)
   - `StorageAccountName`: ✓ (tu storage)
   - `StorageAccountKey`: ✓ (encriptada)

**Verificar Credential:**

1. Automation Account → **Credentials** → `PP-ServicePrincipal`
2. Username debe ser tu Application ID
3. Password debe ser tu Client Secret

---

## 🧪 Verificación y Pruebas

### Checklist Rápido

**Infraestructura:**
- [ ] Resource Group `rg-backups-nfd` existe
- [ ] Storage Account con 2 contenedores: `pp-backup`, `logs`
- [ ] Lifecycle policy configurada (180 días)

**Automation Account:**
- [ ] Automation Account con Managed Identity habilitada
- [ ] 6 Variables creadas con valores correctos
- [ ] 1 Credential `PP-ServicePrincipal` creado
- [ ] 3 Módulos instalados (Status: Available)
- [ ] 3 Runbooks publicados (Status: Published)
- [ ] 1 Schedule vinculado a `Backup-PowerPlatform`

**Permisos:**
- [ ] Managed Identity tiene rol "Storage Blob Data Contributor"
- [ ] Service Principal es "Application user" en Power Platform

---

### Prueba Manual (RECOMENDADO)

**⚠️ IMPORTANTE:** Probar ANTES de esperar la primera ejecución automática.

1. Azure Portal → Automation Account → **Runbooks** → `Backup-PowerPlatform`
2. Click **Start**
3. Esperar 5-10 minutos
4. Monitorear output en tiempo real

**Output esperado:**
```
[1/6] Cargando configuración desde Automation Account...
  ✓ Configuración cargada exitosamente
  
[2/6] Conectando a Dataverse...
  ✓ Conexión exitosa
  
[3/6] Exportando solución...
  ✓ Export completado
  
[4/6] Subiendo a Storage Account...
  ✓ Archivo subido: miApp_2025-12-17_020000.zip
  
[5/6] Registrando logs...
  ✓ Log registrado
  
[6/6] Limpieza...
✓ BACKUP COMPLETADO EXITOSAMENTE
```

---

### Verificar Archivos Generados

1. Azure Portal → Storage Account → **Containers** → `pp-backup`
2. Debes ver archivo:
   ```
   miApp_2025-12-17_020000.zip (2-5 MB)
   ```

3. Container → `logs` → Carpeta `powerplatform/`
4. Debes ver archivo:
   ```
   log_PP_2025-12-17_020000.json
   ```

**Contenido del log (ejemplo):**
```json
{
  "SolutionName": "miApp",
  "BackupDate": "2025-12-17T02:00:00Z",
  "Status": "Success",
  "FileSize": 2457600,
  "Duration": "00:01:23"
}
```

---

### Verificar Schedule Futuro

1. Automation Account → **Jobs**
2. Ver último job: Status = **Completed** (verde)
3. **Schedules** → `Daily-PowerPlatform-02AM`
4. Verificar: Next run = Mañana 02:00 AM

---

## 🐛 Troubleshooting

### Error: "Variable not found"

**Síntoma:**
```
Cannot find variable: PP-SolutionName
```

**Solución:**
1. Automation Account → **Variables**
2. Verificar que la variable existe
3. Verificar que el nombre es exacto (case-sensitive)
4. Si falta, crear manualmente

---

### Error: "Cannot find module 'Az.Accounts'"

**Síntoma:**
```
The term 'Connect-AzAccount' is not recognized
```

**Solución:**
1. Automation Account → **Modules**
2. Verificar Status de `Az.Accounts`
3. Si está "Failed", eliminar y re-importar
4. Si no existe, importar desde Browse gallery

---

### Error: "Insufficient permissions to export solution"

**Síntoma:**
```
Access denied. User does not have permissions.
```

**Solución:**
1. Power Platform Admin Center
2. Environments → Tu environment → **Application users**
3. Buscar tu Service Principal (por Application ID)
4. Verificar rol: **System Administrator**
5. Si no está, agregar como nuevo application user (Paso 0.4)

---

### Error: "Storage blob upload failed - Forbidden"

**Síntoma:**
```
Operation returned an invalid status code 'Forbidden'
```

**Solución:**
1. Storage Account → **Access Control (IAM)**
2. Verificar que `aa-backups-nfd` (Managed Identity) tiene rol "Storage Blob Data Contributor"
3. Si no está, agregar role assignment (Paso B7)

---

### Backup ejecuta pero archivo .zip no aparece

**Causas posibles:**
1. **Storage Account Key incorrecta:** Automation Variables → `StorageAccountKey` → Verificar valor
2. **Organization ID incorrecto:** Variables → `PP-OrganizationId` → Verificar ID (Id. de la organización, NO Environment ID)
3. **Solution Name incorrecto:** Variables → `PP-SolutionName` → Verificar nombre exacto (case-sensitive)

**Solución:**
1. Ir a Automation Account → **Jobs** → Ver último job
2. Leer output completo para identificar error exacto
3. Corregir variable correspondiente
4. Re-ejecutar manualmente

---

### Schedule no ejecuta automáticamente

**Verificar:**
1. Automation Account → **Schedules** → `Daily-PowerPlatform-02AM`
2. Status: **Enabled** (no Disabled)
3. Next run: Debe mostrar fecha/hora futura
4. Linked runbooks: Debe listar `Backup-PowerPlatform`

**Si todo está correcto:**
- Esperar hasta la hora programada
- Verificar en **Jobs** después de esa hora

---

## 📊 Modificar para Múltiples Soluciones

Si tienes varias soluciones para respaldar:

### Opción 1: Un Runbook por Solución (Recomendado)

1. **Duplicar Variables:**
   - `PP-OrganizationId-Prod`
   - `PP-SolutionName-Prod`

2. **Modificar Runbook:**
   - Crear copia: `Backup-PowerPlatform-Prod`
   - Editar línea que lee variables para usar las nuevas

3. **Crear Schedule Separado:**
   - `Daily-Backup-Prod-02AM`
   - Vincular al runbook correspondiente

### Opción 2: Runbook con Parámetros

Modificar `Backup-PowerPlatform.ps1` para recibir parámetros:

```powershell
param(
    [string]$EnvironmentName,
    [string]$SolutionName
)
```

Crear schedules con parámetros diferentes.

---

## 📈 Monitoreo y Mantenimiento

### Revisar Jobs Diarios

**Frecuencia:** Semanal (primeras 2 semanas), luego mensual

1. Automation Account → **Jobs**
2. Filtrar por: `Backup-PowerPlatform`
3. Verificar: Últimos 7 días todos **Completed** (verde)

### Revisar Espacio en Storage

**Frecuencia:** Mensual

1. Storage Account → **Monitoring** → **Metrics**
2. Metric: `Used capacity`
3. Verificar crecimiento mensual
4. Si > 100 GB, considerar reducir retención (< 180 días)

### Renovar Client Secret

**Frecuencia:** Antes de expiración (configuraste 12 meses en Paso 0.2)

**2 semanas antes de expirar:**

1. Azure Portal → App registration → **Certificates & secrets**
2. Crear nuevo Client Secret
3. Copiar nuevo Value
4. Automation Account → **Credentials** → `PP-ServicePrincipal` → **Edit**
5. Password: [Nuevo Client Secret]
6. **Save**
7. Eliminar Client Secret viejo después de validar

---

## 🎯 Costos Detallados

| Recurso | Config | Costo/Mes (USD) |
|---------|--------|-----------------|
| **Storage Account** | 50GB, Cool tier, ZRS | $0.60 |
| **Automation Account** | < 500 min/mes | $0.00 (gratis) |
| **Runbook Executions** | 31 jobs/mes | $0.00 (gratis) |
| **Data Transfer** | < 5GB outbound | $0.00 (gratis) |
| **Managed Identity** | System-assigned | $0.00 (incluido) |
| **TOTAL** | | **~$0.60/mes** |

**Costos variables:**
- Storage crece con tamaño de solución
- Si ejecutas > 500 min/mes: $0.002/min adicional
- Lifecycle policy controla crecimiento (elimina > 180 días)

---

## 📚 Recursos Adicionales

**Documentación Oficial:**
- [Azure Automation](https://learn.microsoft.com/azure/automation/)
- [Azure Storage](https://learn.microsoft.com/azure/storage/)
- [Power Platform API](https://learn.microsoft.com/power-platform/admin/powershell-getting-started)

**Repositorio GitHub:**
- [Código fuente y actualizaciones](https://github.com/IgnaciaCG/nfddataa)

**Soporte:**
- [Reportar problemas](https://github.com/IgnaciaCG/nfddataa/issues)

---

## ✅ Checklist Final

Antes de dar por terminado:

**Configuración Básica:**
- [ ] Service Principal creado con 3 valores guardados
- [ ] Resource Group creado
- [ ] Storage Account con 2 contenedores
- [ ] Lifecycle policy activa
- [ ] Automation Account con Managed Identity
- [ ] 6 Variables con TUS valores
- [ ] 1 Credential con TU Client Secret
- [ ] 3 Módulos instalados (Status: Available)
- [ ] 3 Runbooks publicados

**Pruebas:**
- [ ] Prueba manual ejecutada exitosamente
- [ ] Archivo .zip generado en pp-backup
- [ ] Archivo .json generado en logs
- [ ] Job Status: Completed (verde)
- [ ] Schedule programado para mañana 2 AM

**Monitoreo:**
- [ ] Primer backup automático completado exitosamente
- [ ] Documentado: Fecha de expiración Client Secret

---

## 🎉 ¡Felicitaciones!

Has implementado exitosamente un sistema de backup automatizado para Power Platform.

**Características de tu sistema:**
- ✅ Backup diario automático (2 AM)
- ✅ Almacenamiento redundante (multi-zona)
- ✅ Retención controlada (180 días)
- ✅ Logs de auditoría
- ✅ Costo optimizado (~$0.60/mes)
- ✅ Genérico (funciona en cualquier tenant/solución)

**Próximos pasos recomendados:**
1. Esperar primera ejecución automática mañana
2. Validar que todo funciona sin errores
3. Documentar tu configuración específica
4. Configurar alertas (opcional)
5. Considerar agregar más environments/soluciones

---

**Autor:** Milan Kurte  
**Versión:** 1.5 (Variables + Credentials)  
**Última actualización:** 17 diciembre 2025

**¿Preguntas o problemas?**  
Abre un issue: https://github.com/IgnaciaCG/nfddataa/issues
