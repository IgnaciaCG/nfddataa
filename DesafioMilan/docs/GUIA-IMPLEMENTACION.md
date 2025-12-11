# 🚀 Guía de Implementación - Sistema de Respaldo Híbrido

## Power Platform (Runbooks) + SharePoint (Microsoft 365 Backup)

**Autor:** Milan Kurte
**Fecha:** Diciembre 2025
**Tiempo Total Estimado:** 1.5-2 horas
**Presupuesto:** $60/mes disponibles (usar $3.72-$7.54/mes)
**Arquitectura:** Híbrida (Nativa M365 para SharePoint + Custom para Power Platform)

---

## 📋 Tabla de Contenidos

1. [Pre-requisitos](#pre-requisitos)
2. [Fase 0: Crear Service Principal para Power Platform](#fase-0-service-principal)
3. [Fase 1: Configurar Infraestructura Azure](#fase-1-infraestructura-azure)
4. [Fase 1.5: Habilitar Microsoft 365 Backup (SharePoint)](#fase-15-sharepoint-m365-backup)
5. [Fase 2: Configurar Automation Account](#fase-2-automation-account)
6. [Fase 3: Importar Runbooks](#fase-3-importar-runbooks)
7. [Fase 4: Pruebas Manuales](#fase-4-pruebas-manuales)
8. [Fase 5: Configurar Schedules](#fase-5-schedules)
9. [Troubleshooting](#troubleshooting)

---

## ✅ Pre-requisitos

Antes de empezar, verifica que tienes:

### Accesos

- [X] Cuenta `milan.kurte@nfddata.com` con permisos de:
  - [X] **Power Platform Environment Maker** (environment con dev02)
  - [X] **SharePoint Administrator** (para habilitar M365 Backup vía Admin Center)
- [X] Cuenta `milan.kurte@nofrontiersdata.com` con:
  - [X] **Contributor o Owner** en suscripción Azure ($60)

### Software Instalado

- [X] PowerShell 7.x ([Descargar](https://github.com/PowerShell/PowerShell/releases))
- [X] Módulos PowerShell (instalar durante el proceso)

### Información Necesaria

- [X] Nombre de tu Power Platform environment (donde está dev02)
- [X] Confirmar que tienes solución "dev02" en ese environment
- [X] URL completa del site SharePoint: `https://nfddata.sharepoint.com/sites/data`

### Estrategia de Implementación

**SharePoint:** Microsoft 365 Backup (servicio nativo, zero-code)

- Backup continuo cada hora (RPO < 1 hora)
- Restauración vía UI en < 5 minutos
- Sin costo adicional (incluido en licencias M365)

**Power Platform:** Azure Automation Runbooks (PowerShell custom)

- Backup diario 02:00 AM (RPO 24 horas)
- Restauración mediante runbook (RTO 15-30 min)
- Costo: $3.72-$7.54/mes según configuración

---

## 🔐 FASE 0: Crear Service Principal para Power Platform

**Duración:** 10 minutos
**Dónde:** Tenant nfddata.com (origen de datos)
**Cuenta:** milan.kurte@nfddata.com
**Propósito:** Autenticación cross-tenant para exportar soluciones Power Platform

**💡 NOTA:** SharePoint NO necesita Service Principal. Usa Microsoft 365 Backup (configurado en Fase 1.5).

### Paso 0.1: Crear App Registration (Azure Portal)

**Abre el navegador:**

1. Ve a: https://portal.azure.com
2. **Cambiar al tenant nfddata.com** (esquina superior derecha, click en tu perfil)
3. Navega a: **Microsoft Entra ID** → **App registrations**
4. Click en **New registration**

**Configurar la aplicación:**

5. **Name:** `BackupAutomation-ServicePrincipal`
6. **Supported account types:** Selecciona **"Accounts in this organizational directory only (Single tenant)"**
7. **Redirect URI:** Dejar vacío
8. Click **Register**

**⚠️ IMPORTANTE - Guardar credenciales:**

Una vez creada, verás la pantalla Overview. **Copia y guarda:**

```
Application (client) ID: xxx...
Directory (tenant) ID: xxx...
```

**⏸️ CHECKPOINT:** ¿Tienes el Application ID y Tenant ID copiados?

- ✅ Sí → Continúa
- ❌ No → Están en la página "Overview" de tu app

---

### Paso 0.2: Crear Client Secret

**En la misma página de tu app:**

1. Menú izquierdo → **Certificates & secrets**
2. Tab **Client secrets** → Click **New client secret**
3. **Description:** `BackupAutomation-Secret`
4. **Expires:** Selecciona **12 months**
5. Click **Add**

**⚠️ CRÍTICO - Copiar secreto AHORA:**

6. **Copia el VALUE** (no el Secret ID) - solo se muestra una vez
7. Guárdalo en un lugar seguro (Notepad, etc.)

```
Client Secret Value: xxx...
```

**⏸️ CHECKPOINT:** ¿Guardaste el Client Secret?

- ✅ Sí → Continúa (no podrás verlo de nuevo)
- ❌ No → DETENTE y cópialo ahora antes de salir de la página

---

### Paso 0.3: Configurar Permisos Power Platform API

**En la misma página de tu app:**

1. Menú izquierdo → **API permissions**
2. Click **Add a permission**
3. Selecciona **Dynamics CRM** (API de Power Platform/Dataverse)
4. Click **Application permissions** (no Delegated)
5. Buscar y marcar:
   - ✅ `user_impersonation` (permite acceso a Dataverse en nombre de usuario)
6. Click **Add permissions**

**⏸️ CHECKPOINT:** ¿Se agregó el permiso?

- ✅ Sí → Continúa
- ❌ No → Vuelve a intentar desde paso 2

**💡 NOTA:** NO necesitamos permisos SharePoint. SharePoint usa Microsoft 365 Backup (servicio nativo sin autenticación custom).

---

### Paso 0.4: Otorgar Admin Consent para Power Platform

**En la misma pantalla de API permissions:**

1. Click en el botón grande **"Grant admin consent for [nfddata]"**
2. En el diálogo de confirmación → Click **Yes**
3. Espera 5 segundos - verás marca verde ✓

**⏸️ CHECKPOINT:** ¿Dice "Granted for [tenant]" con marca verde?

- ✅ Sí → Power Platform configurado ✅
- ❌ No → Pregúntame qué ves

```
⏸️ PAUSA - Ahora configuraremos Power Platform con PowerShell
```

---

### Paso 0.5: Instalar Módulo de Power Platform

**Abre PowerShell 7:**

```powershell
# Instalar módulo de Power Platform
Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force
```

**⏸️ CHECKPOINT:** ¿Se instaló sin errores?

- ✅ Sí → Continúa
- ❌ No → Copia el error y pregúntame

---

### Paso 0.6: Obtener Environment Name

```powershell
# Conectar a Power Platform
Add-PowerAppsAccount
# Usar: milan.kurte@nfddata.com

# Listar tus environments
Get-AdminPowerAppEnvironment | Select-Object EnvironmentName, DisplayName
```

**Salida esperada:**

```
EnvironmentName                              DisplayName
---------------                              -----------
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx        Dev-02 Environment
```

**Copia el EnvironmentName** (el GUID largo) del environment que contiene tu solución Dev-02.

**⏸️ CHECKPOINT:** ¿Identificaste el environment correcto?

- ✅ Sí → Copia el EnvironmentName
- ❌ No → Pregúntame cómo identificarlo

---

### Paso 0.7: Asignar Permisos Power Platform

```powershell
# REEMPLAZA estos valores con los tuyos
$appId = "7fc4ef96-8566-4adb-a579-2030dbf71c35"
$environmentName = "295e50db-257c-ea96-882c-67404a3847ec"

# Conectar a Azure AD para obtener Service Principal
Install-Module -Name Az.Accounts -Scope CurrentUser -Force
Connect-AzAccount
# Usar: milan.kurte@nfddata.com (tenant nfddata.com)

# Obtener el Object ID del Service Principal
$sp = Get-AzADServicePrincipal -ApplicationId $appId
$spObjectId = $sp.Id

Write-Host "Service Principal Object ID: $spObjectId" -ForegroundColor Cyan

# Asignar permisos en Power Platform
Set-AdminPowerAppEnvironmentRoleAssignment `
    -PrincipalType "ServicePrincipal" `
    -PrincipalObjectId $spObjectId `
    -RoleName "Environment Maker" `
    -EnvironmentName $environmentName

Write-Host "✓ Permisos configurados en Power Platform" -ForegroundColor Green
```

**⏸️ CHECKPOINT:** ¿Se asignó el rol sin errores?

- ✅ Sí → Continúa
- ❌ No → Copia el error completo y pregúntame

---

### Paso 0.8: Guardar Credenciales en Archivo

```powershell
# Crear carpeta config si no existe
New-Item -ItemType Directory -Path "c:\Users\milan\OneDrive\Documentos\NFDData\nfddataa\DesafioMilan\config" -Force

# Guardar credenciales (TEMPORAL - eliminar después de Fase 2)
@{
    ApplicationId = "TU-APPLICATION-ID"
    TenantId = "TU-TENANT-ID"
    SecretValue = "TU-CLIENT-SECRET"
    EnvironmentName = "TU-ENVIRONMENT-NAME"
    CreatedDate = Get-Date
} | ConvertTo-Json | Out-File "c:\Users\milan\OneDrive\Documentos\NFDData\nfddataa\DesafioMilan\config\service_principal_credentials.json"

Write-Host "`n✅ Credenciales guardadas en: .\config\service_principal_credentials.json" -ForegroundColor Green
Write-Host "⚠️  ELIMINAR este archivo después de configurar Azure Automation (Fase 2)" -ForegroundColor Yellow
```

**⏸️ CHECKPOINT:** ¿Se creó el archivo JSON?

- ✅ Sí → FASE 0 COMPLETA ✅
- ❌ No → Verifica la ruta o pregúntame

---

### 📋 Resumen Fase 0

Debes tener guardados:

- ✅ Application (client) ID
- ✅ Directory (tenant) ID (nfddata.com)
- ✅ Client Secret Value
- ✅ Environment Name de Power Platform
- ✅ Admin consent otorgado (Dynamics CRM API)
- ✅ Permisos Environment Maker configurados

**Archivo generado:** `.\config\service_principal_credentials.json`

**⚠️ NOTA:** Este archivo contiene el secreto. Eliminarlo después de completar la Fase 2.

**💡 SharePoint:** NO necesita configuración adicional aquí. Lo configuraremos en Fase 1.5 con Microsoft 365 Backup.

---

## 🏭️ FASE 1: Configurar Infraestructura Azure

**Duración:** 10-15 minutos
**Dónde:** Tenant nofrontiersdata.com (destino de backups)
**Cuenta:** milan.kurte@nofrontiersdata.com
**Propósito:** Crear Storage Account para backups de Power Platform únicamente

**💡 NOTA:** SharePoint NO usa Azure Storage. Usa Microsoft 365 Backup (nativo en cloud de Microsoft).

### Paso 1.1: Conectar a Azure (Tenant con los $60)

```powershell
# Conectar a Azure con la cuenta que tiene los $60
Connect-AzAccount
# Usar: milan.kurte@nofrontiersdata.com

# Verificar tenant y suscripción
$context = Get-AzContext
Write-Host "Cuenta: $($context.Account.Id)" -ForegroundColor Cyan
Write-Host "Suscripción: $($context.Subscription.Name)" -ForegroundColor Cyan
Write-Host "Tenant: $($context.Tenant.Id)" -ForegroundColor Cyan
```

**⏸️ CHECKPOINT:** ¿Estás conectado con milan.kurte@nofrontiersdata.com?

- ✅ Sí → Continúa
- ❌ No → Desconectar con `Disconnect-AzAccount` y volver a conectar

---

### Paso 1.2: Ejecutar Script de Setup Azure

```powershell
# Navegar a carpeta de scripts
cd c:\Users\milan\OneDrive\Documentos\NFDData\nfddataa\DesafioMilan\scripts

# Ejecutar Fase 1
.\01-Setup-Azure.ps1
```

**El script hará:**

1. Crear Resource Group: `rg-backups-nfd`
2. Crear Storage Account con nombre aleatorio (ej: `backupnfd1234`)
3. Crear **2 contenedores:**
   - `pp-backup` → Backups de Power Platform (soluciones + Dataverse)
   - `logs` → Logs de ejecución de runbooks
4. Configurar lifecycle policy:
   - Días 0-7: Hot tier (acceso rápido)
   - Días 8-30: Cool tier (ahorro de costos)
   - Día 31+: Eliminación automática

**💡 NOTA:** NO se crea contenedor `sp-backup`. SharePoint usa Microsoft 365 Backup (cloud nativo).

**Tiempo estimado:** 5-10 minutos

**⏸️ CHECKPOINT:** ¿El script terminó sin errores?

- ✅ Sí → Verifica que se creó el archivo `.\config\storage_account_name.txt`
- ❌ No → Copia el error completo y pregúntame

---

### Paso 1.3: Verificar en Azure Portal

1. Abre https://portal.azure.com
2. Busca el Resource Group: `rg-backups-nfd`
3. Debes ver:
   - ✅ Storage Account (nombre como `backupnfd1234`)
   - ✅ Automation Account: `aa-backups` (creado en Fase 2)
4. Dentro del Storage Account, verifica contenedores:
   - ✅ `pp-backup` (backups Power Platform)
   - ✅ `logs` (logs de runbooks)

**💡 IMPORTANTE:** NO debe existir contenedor `sp-backup` (SharePoint usa M365 Backup).

**⏸️ CHECKPOINT:** ¿Ves los 2 contenedores correctos?

- ✅ Sí → FASE 1 COMPLETA ✅
- ❌ No → Pregúntame qué ves

---

## 📦 FASE 1.5: Habilitar Microsoft 365 Backup (SharePoint)

**Duración:** 5-10 minutos
**Dónde:** SharePoint Admin Center (nfddata.com)
**Cuenta:** milan.kurte@nfddata.com
**Propósito:** Habilitar backup nativo para SharePoint (zero-code, sin costo adicional)

### Paso 1.5.1: Acceder a SharePoint Admin Center

1. Abre https://admin.microsoft.com/sharepoint
2. Iniciar sesión con: `milan.kurte@nfddata.com`
3. Navega a: **Settings** (menú izquierdo)

**⏸️ CHECKPOINT:** ¿Ves el menú de Settings?

- ✅ Sí → Continúa
- ❌ No → Verifica que tienes rol SharePoint Administrator

---

### Paso 1.5.2: Habilitar Microsoft 365 Backup

**Opción A: Si Microsoft 365 Backup está disponible en tu tenant:**

1. En Settings → Buscar sección **Microsoft 365 Backup**
2. Click en **Manage Microsoft 365 Backup**
3. Toggle **Enable** para el site: `/sites/data`
4. Seleccionar biblioteca: **Documents**
5. Configurar retención: **30 días** (default)
6. Click **Save**

**⏸️ CHECKPOINT:** ¿Se habilitó Microsoft 365 Backup?

- ✅ Sí → Continúa al Paso 1.5.3
- ❌ No disponible → Continúa con Opción B (Versioning como fallback)

---

**Opción B: Si M365 Backup NO está disponible - Usar Versioning:**

**💡 NOTA:** Si Microsoft 365 Backup no está disponible en tu tenant, usa Versioning como alternativa básica:

1. Abre: https://nfddata.sharepoint.com/sites/data
2. Navega a biblioteca **Documents**
3. Click en ⚙️ **Settings** → **Library settings**
4. Click en **Versioning settings**
5. Configurar:
   - **Create major versions:** Yes
   - **Keep the following number of major versions:** **50**
6. Click **OK**

**Características de Versioning:**

- ✅ Preserva 50 versiones anteriores de cada archivo
- ✅ Recuperación manual: Click derecho → Version History → Restore
- ⚠️ RPO: Depende de frecuencia de edición (no automático)
- ⚠️ RTO: < 10 minutos (manual por archivo)

**⏸️ CHECKPOINT:** ¿Configuraste versioning?

- ✅ Sí → FASE 1.5 COMPLETA ✅
- ❌ No → Pregúntame el error

---

### Paso 1.5.3: Validar Backup de SharePoint

**Prueba rápida:**

1. Abre: https://nfddata.sharepoint.com/sites/data
2. Sube un archivo de prueba: `test_backup.txt`
3. Elimínalo (Seleccionar → Delete)
4. Click en **Recycle Bin** (barra lateral izquierda)
5. Selecciona el archivo → Click **Restore**
6. Verifica que el archivo regresó a Documents

**⏸️ CHECKPOINT:** ¿El archivo se restauró correctamente?

- ✅ Sí → SharePoint Backup configurado ✅
- ❌ No → Pregúntame qué pasó

**📋 Resumen Fase 1.5:**

- ✅ Microsoft 365 Backup habilitado (o Versioning como fallback)
- ✅ Retención: 30 días (M365 Backup) o 50 versiones (Versioning)
- ✅ Restauración validada con prueba
- ✅ **RPO:** < 1 hora (M365 Backup) o variable (Versioning)
- ✅ **RTO:** < 5 minutos (M365 Backup) o < 10 min (Versioning)

**💰 Costo:** $0 (incluido en licencias Microsoft 365)

---

## ⚙️ FASE 2: Configurar Automation Account

**Duración:** 10-15 minutos
**Dónde:** Azure (nofrontiersdata.com)
**Propósito:** Configurar runbooks para Power Platform únicamente

**💡 NOTA:** SharePoint NO necesita configuración aquí (usa M365 Backup configurado en Fase 1.5).

### Paso 2.1: Preparar Información

Ten a mano de la Fase 0:

- Application ID (Service Principal)
- Tenant ID (nfddata.com)
- Client Secret
- Environment Name de Power Platform

### Paso 2.2: Ejecutar Script de Setup Automation

```powershell
# Asegúrate de estar en la carpeta scripts
cd c:\Users\milan\OneDrive\Documentos\NFDData\nfddataa\DesafioMilan\scripts

# Ejecutar Fase 2
.\02-Setup-Automation.ps1
```

**El script te preguntará:**

```
Service Principal - Application ID: [pegar de Fase 0]
Service Principal - Tenant ID (nfddata.com): [pegar de Fase 0]
Power Platform - Environment Name: [tu environment ID]
Power Platform - Solution Name (ej: dev02): dev02
```

**💡 NOTA:** Ya NO pedirá información de SharePoint (eliminado en arquitectura híbrida).

**Luego pedirá:**

```
Service Principal - Client Secret: [pegar - no se verá al escribir]
```

**⏸️ CHECKPOINT:** ¿El script terminó sin errores?

- ✅ Sí → Continúa
- ❌ No → Pregúntame el error específico

---

### Paso 2.3: Verificar Variables en Azure Portal

1. Azure Portal → Automation Accounts → `aa-backups`
2. Click en **Variables** (menú izquierdo)
3. Debes ver **4-5 variables:**

   - StorageAccountName
   - PP-ServicePrincipal-AppId
   - PP-ServicePrincipal-TenantId
   - PP-EnvironmentName
   - PP-SolutionName
4. Click en **Credentials**
5. Debes ver: `PP-ServicePrincipal`

**💡 NOTA:** Ya NO hay variables de SharePoint (SP-SiteUrl, SP-LibraryName). SharePoint usa M365 Backup.

**⏸️ CHECKPOINT:** ¿Ves todas las variables y el credential?

- ✅ Sí → FASE 2 COMPLETA ✅
- ❌ No → Pregúntame qué falta

---

## 📦 FASE 3: Importar Runbooks

**Duración:** 5-10 minutos
**Propósito:** Importar runbooks de Power Platform únicamente

**💡 NOTA:** Ya NO importamos runbook de SharePoint (usa M365 Backup nativo).

### Paso 3.1: Instalar Módulos en Automation Account

**IMPORTANTE:** Los runbooks necesitan módulos de PowerShell. Instálalos desde Azure Portal:

1. Azure Portal → Automation Account → **Modules**
2. Click **Browse Gallery**
3. Buscar e instalar (en este orden):

   **Módulo 1:** `Az.Accounts`

   - Click → Import → Wait hasta "Succeeded"

   **Módulo 2:** `Az.Storage`

   - Click → Import → Wait hasta "Succeeded"

   **Módulo 3:** `Microsoft.PowerApps.Administration.PowerShell`

   - Click → Import → Wait hasta "Succeeded"

**⚠️ IMPORTANTE:** Espera que cada módulo diga "Succeeded" antes de importar el siguiente.

**Tiempo total:** ~10-15 minutos

**💡 NOTA:** Ya NO instalamos módulo `PnP.PowerShell` (era para SharePoint).

**⏸️ CHECKPOINT:** ¿Los 3 módulos están en estado "Succeeded"?

- ✅ Sí → Continúa
- ❌ No → Espera o pregúntame si hay errores

---

### Paso 3.2: Importar Runbooks

```powershell
# Ejecutar Fase 3
cd c:\Users\milan\OneDrive\Documentos\NFDData\nfddataa\DesafioMilan\scripts
.\03-Import-Runbooks.ps1
```

**El script importará:**

1. **Backup-PowerPlatform** (diario 02:00 AM)
2. **Restore-PowerPlatform** (bajo demanda)
3. **Backup-FisicoSemanal** (semanal domingo 02:00 AM - opcional)

**💡 NOTA:** Ya NO se importa `Backup-SharePoint` (eliminado en arquitectura híbrida).

**⏸️ CHECKPOINT:** ¿Los 2-3 runbooks se importaron sin errores?

- ✅ Sí → FASE 3 COMPLETA ✅
- ❌ No → Pregúntame el error

---

## 🧪 FASE 4: Pruebas Manuales

**Duración:** 15-20 minutos
**IMPORTANTE:** No programar schedules hasta validar que funciona

### Paso 4.1: Verificar Configuración de Microsoft 365 Backup (SharePoint)

**SharePoint usa Microsoft 365 Backup (configurado en Fase 1.5) - no requiere prueba manual de runbook.**

1. Microsoft 365 Admin Center → **Setup** → **Data backup**
2. Click en **SharePoint sites**
3. Verificar:
   - Estado: **Protection on**
   - Sitios incluidos: Tu sitio principal
   - Último snapshot: Fecha/hora reciente

**⏸️ CHECKPOINT:** ¿El estado es "Protection on"?

- ✅ Sí → SharePoint backup está activo ✅
- ❌ No → Revisa Fase 1.5 para completar configuración

**Costo:** $0 (incluido en licencia E3/E5)

---

### Paso 4.2: Probar Runbook de Power Platform

**NOTA:** Este runbook depende de las APIs de Power Platform.

[5/5] Guardando log...
  ✓ Log guardado

✓ Backup completado exitosamente

```

**⏸️ CHECKPOINT:** ¿El runbook terminó con "✓ Backup completado exitosamente"?

- ✅ Sí → Continúa con Paso 4.3
- ❌ No → Copia el error completo y pregúntame

---

**NOTA:** Este runbook depende de las APIs de Power Platform.

1. Azure Portal → Automation Account → **Runbooks**
2. Click en: `Backup-PowerPlatform`
3. Click en **Start**
4. Click **OK**
5. Espera y revisa el output

**Si hay errores relacionados con conexión a Power Platform:**

El runbook tiene secciones marcadas con `# TODO:` que necesitan completarse con código real de las APIs. Esto es normal y lo haremos juntos en esta fase.

**⏸️ CHECKPOINT:** ¿Qué resultado obtuviste?

- ✅ Éxito completo → Perfecto, continúa
- ⚠️ Errores de conexión → Normal, pregúntame para completar el código
- ❌ Otros errores → Copia el error y pregúntame

---

### Paso 4.3: Validar Logs

1. Storage Account → Container: `logs`
2. Debes ver carpeta:
   - `powerplatform/` (con archivos log_PP_*.json)

**NOTA:** SharePoint no genera logs aquí (usa Microsoft 365 Backup nativo).

**⏸️ CHECKPOINT:** ¿Ves los archivos de log de Power Platform?

- ✅ Sí → FASE 4 COMPLETA ✅
- ❌ No → Revisemos el runbook de Power Platform

---

## ⏰ FASE 5: Configurar Schedules (OPCIONAL)

**⚠️ Solo hacer cuando las pruebas manuales funcionen al 100%**

### Paso 5.1: Ejecutar Script de Schedules

```powershell
cd c:\Users\milan\OneDrive\Documentos\NFDData\nfddataa\DesafioMilan\scripts
.\04-Configure-Schedules.ps1
```

**Creará:**

- Backup-PowerPlatform: Diario 02:00 AM
- Backup-FisicoSemanal: Domingo 02:00 AM (requiere Hybrid Worker)

**NOTA:** SharePoint no requiere schedule (Microsoft 365 Backup funciona automáticamente con RPO < 1 hora).

**⏸️ CHECKPOINT:** ¿Se crearon los 2 schedules?

- ✅ Sí → IMPLEMENTACIÓN COMPLETA ✅
- ❌ No → Pregúntame el error

---

## 🎉 Checklist Final

- [ ] Service Principal creado y configurado (solo Power Platform)
- [ ] Storage Account con 2 contenedores (pp-backup, logs)
- [ ] Microsoft 365 Backup configurado para SharePoint
- [ ] Automation Account con variables y credentials
- [ ] Módulos PowerShell instalados (3 módulos)
- [ ] Runbooks importados (2-3 runbooks)
- [ ] SharePoint protegido con M365 Backup (estado "Protection on")
- [ ] Prueba manual de Power Platform exitosa
- [ ] Logs generados correctamente en container logs
- [ ] (Opcional) Schedules configurados (2 schedules)

---

## 🐛 Troubleshooting

### Error: "Connect-AzAccount: No subscriptions found"

**Causa:** No tienes acceso a ninguna suscripción Azure.

**Solución:**

```powershell
# Verificar que estás en el tenant correcto
Get-AzContext

# Si es incorrecto, desconectar y reconectar
Disconnect-AzAccount
Connect-AzAccount -TenantId "tenant-id-correcto"
```

---

### Error: "Application with identifier '...' was not found"

**Causa:** El Service Principal no existe en el tenant correcto.

**Solución:** Verifica que creaste el App Registration en **nfddata.com**, no en nofrontiersdata.com.

---

### Error: "Failed to import module PnP.PowerShell"

**NOTA:** Este módulo YA NO se usa en la arquitectura híbrida (SharePoint usa M365 Backup).

**Si ves este error:** Ignóralo - el módulo no es necesario.

---

### Error al ejecutar runbook: "Get-AutomationVariable: Variable 'X' not found"

**Causa:** Falta una variable de configuración.

**Solución:**

1. Azure Portal → Automation Account → Variables
2. Verificar que existe la variable mencionada
3. Si no existe, crearla manualmente:
   - Name: [nombre de la variable]
   - Type: String
   - Value: [valor correcto]
   - Encrypted: No (excepto secretos)

---

---

### Error: "Access denied" al conectar a Power Platform

**Causa:** El Service Principal no tiene permisos o falta admin consent.

**Solución:**

1. Verificar admin consent en Azure Portal (Fase 0.6)
2. Verificar permisos en API permissions (Dynamics CRM API)
3. Esperar 5-10 minutos (propagación de permisos)

**NOTA:** SharePoint no usa Service Principal (M365 Backup es nativo).

---

### Runbook queda en "Running" indefinidamente

**Causa:** Puede estar esperando input o en loop infinito.

**Solución:**

1. Click en **Stop** para detener el job
2. Revisar el output hasta donde llegó
3. Pregúntame con el último mensaje que viste

---

## 📞 Cuándo Preguntarme

**Pregunta en cualquiera de estos casos:**

1. ❌ Algún comando falla con error
2. ⚠️ Un CHECKPOINT no se cumple
3. 🤔 No entiendes algún paso
4. 📝 Necesitas ayuda con valores específicos (environment names, etc.)
5. 🐛 Los runbooks no funcionan como esperado
6. 💰 Quieres verificar que los costos están bien

**Cómo preguntar:**

- Copia el error COMPLETO (no resumas)
- Dime en qué fase y paso estás
- Si es error de runbook, copia el output completo del job

---

## 📊 Próximos Pasos Después de Implementar

1. **Monitoreo (primera semana):**

   - Revisar jobs diarios en Azure Portal (Power Platform)
   - Verificar snapshots en Microsoft 365 Backup (SharePoint)
   - Validar logs en Storage Account
2. **Optimización (después de validar):**

   - Agregar más soluciones de Power Platform al backup
   - Configurar Hybrid Worker para backup físico
   - Ajustar políticas de retención en M365 Backup
3. **Documentar procedimiento de restauración:**

   - Cómo descargar un backup de Power Platform
   - Cómo importar solución en Power Platform
   - Cómo restaurar desde Microsoft 365 Backup (SharePoint)

---

## 🎯 Estimación de Tiempo Total

| Fase                         | Tiempo                 | Dificultad |
| ---------------------------- | ---------------------- | ---------- |
| Fase 0: Service Principal    | 10 min                 | 🟢 Fácil  |
| Fase 1: Azure Infrastructure | 10 min                 | 🟢 Fácil  |
| Fase 1.5: M365 Backup        | 10 min                 | 🟢 Fácil  |
| Fase 2: Automation Account   | 15 min                 | 🟡 Media   |
| Fase 3: Importar Runbooks    | 20 min                 | 🟡 Media   |
| Fase 4: Pruebas              | 20 min                 | 🟡 Media   |
| Fase 5: Schedules            | 5 min                  | 🟢 Fácil  |
| **TOTAL**              | **~1.5-2 horas** |            |

**⚠️ Tiempo real puede variar según errores y troubleshooting**
**¿Listo para empezar? Comienza por la Fase 0 y ve paso a paso.**

**Recuerda:** No tengas miedo de preguntar en CUALQUIER punto. ¡Estoy aquí para ayudarte! 😊
