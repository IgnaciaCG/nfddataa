# 🚀 Guía de Implementación - Sistema de Respaldo Híbrido

## Power Platform (Runbooks) + SharePoint (Microsoft 365 Backup)

**Versión:** 1.0 - Genérica
**Fecha:** Diciembre 2025
**Tiempo Total Estimado:** 1.5-2 horas
**Arquitectura:** Híbrida (Nativa M365 para SharePoint + Custom para Power Platform)

---

## 📋 Tabla de Contenidos

1. [Pre-requisitos](#pre-requisitos)
2. [Fase 0: Crear Service Principal para Power Platform](#fase-0-service-principal)
3. [Fase 1: Configurar Infraestructura Azure](#fase-1-infraestructura-azure)
4. [Fase 1.5: Configurar Backup de SharePoint](#fase-15-sharepoint-backup)
5. [Fase 2: Configurar Automation Account](#fase-2-automation-account)
6. [Fase 3: Importar Runbooks](#fase-3-importar-runbooks)
7. [Fase 4: Pruebas Manuales](#fase-4-pruebas-manuales)
8. [Fase 5: Configurar Schedules](#fase-5-schedules)
9. [Troubleshooting](#troubleshooting)

---

## ✅ Pre-requisitos

Antes de empezar, verifica que tienes:

### Accesos Necesarios

- **Tenant Microsoft 365** con:
  - Power Platform environment(s) que quieres respaldar
  - SharePoint site(s) que quieres proteger
  - Usuario con permisos de **Environment Maker** en Power Platform
  - Usuario con permisos de **SharePoint Administrator**
  
- **Suscripción Azure** con:
  - Permisos de **Contributor** o **Owner**
  - Presupuesto disponible: ~$5-10/mes (dependiendo de tamaño de datos)

### Software Instalado

- PowerShell 7.x ([Descargar](https://github.com/PowerShell/PowerShell/releases))
- Módulos PowerShell (se instalarán durante el proceso)

### Información que Necesitarás

- Nombre de tu Power Platform environment
- Nombre de la solución a respaldar
- URL de tu SharePoint site (ejemplo: `https://tuempresa.sharepoint.com/sites/tusitio`)
- Tenant ID de tu organización

### Arquitectura de la Solución

**SharePoint:** Microsoft 365 Backup (servicio nativo)
- Backup continuo cada hora (RPO < 1 hora)
- Restauración vía UI en < 5 minutos
- Costo: $0 si tienes M365 Backup, o usar Versioning como alternativa gratuita

**Power Platform:** Azure Automation Runbooks (PowerShell custom)
- Backup diario 02:00 AM (RPO 24 horas)
- Restauración mediante runbook (RTO 15-30 min)
- Costo: $3-8/mes según configuración

---

## 🔐 FASE 0: Crear Service Principal para Power Platform

**Duración:** 10 minutos  
**Propósito:** Autenticación para exportar soluciones Power Platform

### Paso 0.1: Crear App Registration

1. Ve a: https://portal.azure.com
2. Asegúrate de estar en el **tenant correcto** (esquina superior derecha)
3. Navega a: **Microsoft Entra ID** → **App registrations**
4. Click en **New registration**
5. Configurar:
   - **Name:** `BackupAutomation-ServicePrincipal`
   - **Supported account types:** Single tenant
   - **Redirect URI:** Dejar vacío
6. Click **Register**

**Guardar credenciales:**

Copia y guarda en un lugar seguro:
- Application (client) ID: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
- Directory (tenant) ID: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

---

### Paso 0.2: Crear Client Secret

1. En tu app → **Certificates & secrets**
2. Tab **Client secrets** → Click **New client secret**
3. **Description:** `BackupAutomation-Secret`
4. **Expires:** 12 months
5. Click **Add**
6. **⚠️ CRÍTICO:** Copia el **VALUE** inmediatamente (solo se muestra una vez)

---

### Paso 0.3: Configurar Permisos API

1. En tu app → **API permissions**
2. Click **Add a permission**
3. Selecciona **Dynamics CRM**
4. Click **Application permissions**
5. Marca: `user_impersonation`
6. Click **Add permissions**

---

### Paso 0.4: Otorgar Admin Consent

1. En API permissions → Click **"Grant admin consent for [tu organización]"**
2. Click **Yes**
3. Espera marca verde ✓

---

### Paso 0.5: Obtener Environment Name

```powershell
# Instalar módulo
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force

# Conectar
Add-PowerAppsAccount

# Listar environments
Get-AdminPowerAppEnvironment | Select-Object EnvironmentName, DisplayName
```

Copia el **EnvironmentName** (GUID) del environment que quieres respaldar.

---

### Paso 0.6: Asignar Permisos en Power Platform

```powershell
# Conectar a Azure
Install-Module -Name Az.Accounts -Scope CurrentUser -Force
Connect-AzAccount

# Reemplaza con tus valores
$appId = "TU-APPLICATION-ID"
$environmentName = "TU-ENVIRONMENT-ID"

# Obtener Object ID
$sp = Get-AzADServicePrincipal -ApplicationId $appId
$spObjectId = $sp.Id

# Asignar rol
Set-AdminPowerAppEnvironmentRoleAssignment `
    -PrincipalType "ServicePrincipal" `
    -PrincipalObjectId $spObjectId `
    -RoleName "Environment Maker" `
    -EnvironmentName $environmentName
```

---

### Paso 0.7: Guardar Credenciales (Temporal)

```powershell
# Crear carpeta
New-Item -ItemType Directory -Path ".\DesafioBackup\config" -Force

# Guardar (ELIMINAR después de Fase 2)
@{
    ApplicationId = "TU-APPLICATION-ID"
    TenantId = "TU-TENANT-ID"
    SecretValue = "TU-CLIENT-SECRET"
    EnvironmentName = "TU-ENVIRONMENT-NAME"
    CreatedDate = Get-Date
} | ConvertTo-Json | Out-File ".\DesafioBackup\config\service_principal_credentials.json"
```

**⏸️ CHECKPOINT Fase 0:** Debes tener guardados Application ID, Tenant ID, Client Secret y Environment Name.

---

## 🏭 FASE 1: Configurar Infraestructura Azure

**Duración:** 10-15 minutos  
**Propósito:** Crear Storage Account para backups de Power Platform

### Paso 1.1: Conectar a Azure

```powershell
Connect-AzAccount

# Verificar conexión
$context = Get-AzContext
Write-Host "Cuenta: $($context.Account.Id)"
Write-Host "Suscripción: $($context.Subscription.Name)"
```

---

### Paso 1.2: Descargar Scripts de GitHub

```powershell
# Opción 1: Clonar repositorio (si tienes Git)
git clone https://github.com/IgnaciaCG/nfddataa.git
cd nfddataa\DesafioMilan\scripts

# Opción 2: Descargar manualmente
# Ve a: https://github.com/IgnaciaCG/nfddataa/tree/main/DesafioMilan
# Descarga la carpeta 'scripts' completa
```

---

### Paso 1.3: Ejecutar Script de Setup Azure

```powershell
# Navegar a carpeta de scripts
cd .\DesafioBackup\scripts

# Ejecutar
.\01-Setup-Azure.ps1
```

**El script creará:**
- Resource Group: `rg-backups-nfd`
- Storage Account (nombre aleatorio: `backupnfd####`)
- 2 contenedores: `pp-backup`, `logs`
- Lifecycle policy (retención 30 días)

**⏸️ CHECKPOINT Fase 1:** Verifica en Azure Portal que existen el Resource Group y Storage Account con 2 contenedores.

---

## 📦 FASE 1.5: Configurar Backup de SharePoint

**Duración:** 5-10 minutos  
**Propósito:** Proteger SharePoint con backup nativo

### Opción A: Microsoft 365 Backup (Recomendado)

**Si tu organización tiene licencias M365 Backup:**

1. Ve a: https://admin.microsoft.com/sharepoint
2. **Settings** → **Microsoft 365 Backup**
3. Click **Manage Microsoft 365 Backup**
4. Habilitar para tu site
5. Configurar retención: 30 días

**Características:**
- RPO: < 1 hora
- RTO: < 5 minutos
- Costo: Incluido en licencia (si tienes M365 Backup)

---

### Opción B: Versioning (Alternativa Gratuita)

**Si M365 Backup no está disponible:**

1. Abre tu SharePoint site
2. Biblioteca **Documents** → **⚙️ Settings** → **Library settings**
3. **Versioning settings**
4. Configurar:
   - Create major versions: **Yes**
   - Número de versiones: **50**
5. Click **OK**

**Características:**
- Retención: 50 versiones
- Recuperación: Manual (click derecho → Version History)
- Costo: $0 (gratis)

---

### Validar Configuración

**Prueba rápida:**
1. Sube un archivo de prueba
2. Elimínalo
3. Recycle Bin → Restore
4. Verifica que regresó

**⏸️ CHECKPOINT Fase 1.5:** SharePoint configurado con M365 Backup o Versioning.

---

## ⚙️ FASE 2: Configurar Automation Account

**Duración:** 10-15 minutos  
**Propósito:** Configurar runbooks para Power Platform

### Paso 2.1: Ejecutar Script

```powershell
.\02-Setup-Automation.ps1
```

**El script te preguntará:**
- Service Principal - Application ID
- Service Principal - Tenant ID
- Power Platform - Environment Name
- Power Platform - Solution Name
- Service Principal - Client Secret (no se verá al escribir)

---

### Paso 2.2: Verificar en Azure Portal

1. Azure Portal → Automation Accounts → `aa-backups-nfd`
2. **Variables** → Debes ver 5 variables
3. **Credentials** → Debes ver `PP-ServicePrincipal`

**⏸️ CHECKPOINT Fase 2:** Automation Account creado con variables y credentials.

---

## 📦 FASE 3: Importar Runbooks

**Duración:** 15-20 minutos  
**Propósito:** Cargar scripts de backup

### Paso 3.1: Instalar Módulos PowerShell

**En Azure Portal:**
1. Automation Account → **Modules** → **Browse Gallery**
2. Instalar en orden (espera que cada uno termine):
   - `Az.Accounts`
   - `Az.Storage`
   - `Microsoft.PowerApps.Administration.PowerShell`

**Tiempo:** ~15 minutos

---

### Paso 3.2: Importar Runbooks

```powershell
.\03-Import-Runbooks.ps1
```

**Importará:**
- Backup-PowerPlatform (backup diario)
- Backup-FisicoSemanal (backup semanal a HDD - opcional)

**⏸️ CHECKPOINT Fase 3:** Los 2 runbooks están importados y publicados.

---

## 🧪 FASE 4: Pruebas Manuales

**Duración:** 15-20 minutos  
**IMPORTANTE:** No programar schedules hasta validar

### Paso 4.1: Verificar SharePoint

**Si usas M365 Backup:**
1. Microsoft 365 Admin Center → **Data backup**
2. Verificar estado: **Protection on**

**Si usas Versioning:**
1. Edita un archivo en SharePoint
2. Click derecho → **Version History**
3. Verifica que hay múltiples versiones

---

### Paso 4.2: Probar Runbook de Power Platform

1. Azure Portal → Automation Account → **Runbooks**
2. Click en `Backup-PowerPlatform`
3. Click **Start**
4. Espera y revisa output

**Resultado esperado:**
```
✓ Backup completado exitosamente
```

---

### Paso 4.3: Validar Logs

1. Storage Account → Container `logs`
2. Carpeta `powerplatform/`
3. Debes ver archivos: `log_PP_*.json`

**⏸️ CHECKPOINT Fase 4:** Pruebas exitosas, logs generados.

---

## ⏰ FASE 5: Configurar Schedules

**⚠️ Solo si las pruebas manuales funcionaron**

### Ejecutar Script

```powershell
.\04-Configure-Schedules.ps1
```

**Creará:**
- Backup-PowerPlatform: Diario 02:00 AM
- Backup-FisicoSemanal: Domingo 02:00 AM (opcional)

**⏸️ CHECKPOINT Fase 5:** Schedules configurados.

---

## 🎉 Checklist Final

- [ ] Service Principal creado
- [ ] Storage Account con 2 contenedores
- [ ] SharePoint configurado (M365 Backup o Versioning)
- [ ] Automation Account con variables
- [ ] Módulos PowerShell instalados
- [ ] Runbooks importados
- [ ] Pruebas manuales exitosas
- [ ] Logs generados
- [ ] Schedules configurados (opcional)

---

## 🐛 Troubleshooting Común

### Error: "Connect-AzAccount: No subscriptions found"

**Solución:**
```powershell
Disconnect-AzAccount
Connect-AzAccount -TenantId "tu-tenant-id"
```

---

### Error: "Application with identifier '...' was not found"

**Causa:** Service Principal creado en tenant incorrecto.

**Solución:** Verifica que usaste el tenant correcto en Fase 0.

---

### Error: Variable no encontrada en runbook

**Solución:**
1. Azure Portal → Automation Account → **Variables**
2. Crear manualmente la variable faltante

---

### Runbook queda en "Running" indefinidamente

**Solución:**
1. Click **Stop**
2. Revisar output hasta donde llegó
3. Verificar permisos del Service Principal

---

## 📞 Soporte

**Pregunta en GitHub Issues si:**
- Algún comando falla con error
- Un CHECKPOINT no se cumple
- Necesitas ayuda con valores específicos
- Los runbooks no funcionan

**Cómo reportar:**
- Copia el error COMPLETO
- Indica en qué fase y paso estás
- Incluye el output del runbook si aplica

---

## 📊 Costos Estimados

| Componente | Costo/Mes |
|-----------|-----------|
| Azure Storage (50GB) | ~$1.00 |
| Automation Account (10 jobs/día) | ~$2.00 |
| Runbooks (500 min/mes) | ~$0.50 |
| M365 Backup SharePoint | $0 (incluido) o usar Versioning |
| **TOTAL** | **~$3.50/mes** |

---

## 🎯 Próximos Pasos

1. **Monitoreo (primera semana):**
   - Revisar jobs diarios
   - Validar logs
   - Verificar snapshots SharePoint

2. **Optimización:**
   - Agregar más environments
   - Ajustar retención
   - Configurar alertas

3. **Documentar restauración:**
   - Procedimiento para Power Platform
   - Procedimiento para SharePoint

---

## 📚 Recursos Adicionales

- [Documentación Azure Automation](https://learn.microsoft.com/azure/automation/)
- [Microsoft 365 Backup](https://learn.microsoft.com/microsoft-365/backup/)
- [Power Platform API](https://learn.microsoft.com/power-platform/admin/powershell-getting-started)
- [Repositorio GitHub](https://github.com/IgnaciaCG/nfddataa)

---

**¿Listo para empezar? Comienza por la Fase 0 y avanza paso a paso.**

**Recuerda:** Esta guía está diseñada para ser autocontenida. Sigue cada paso cuidadosamente y verifica los CHECKPOINTs. 🚀
