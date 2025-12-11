# Checklist Pre-Ejecución - Runbook Backup

## ✅ **Antes de ejecutar el runbook, verifica:**

### **1. Módulos Instalados en Automation Account**

Ve a: **Azure Portal → Automation Account → Modules**

Verifica que estos módulos estén con **Status: Available**:

- [ ] `Az.Accounts` (v2.10.0 o superior)
- [ ] `Az.Storage` (v5.0.0 o superior)
- [ ] `Microsoft.PowerApps.Administration.PowerShell` (v2.0.0 o superior)

**Si falta alguno:**
1. Click **"Browse gallery"**
2. Busca el módulo por nombre
3. Click **"Import"**
4. Espera 5-10 minutos a que Status = **"Available"**

---

### **2. Variables de Automation**

Ve a: **Azure Portal → Automation Account → Variables**

Verifica que existan estas variables:

| Nombre | Tipo | Valor Ejemplo | Descripción |
|--------|------|---------------|-------------|
| `PP-ServicePrincipal-AppId` | String | `7fc4ef96-8566-4adb-a579-2030dbf71c35` | Application ID del Service Principal |
| `PP-ServicePrincipal-TenantId` | String | `344457f2-bd03-46c6-9974-97bffb8f626a` | Tenant ID de Entra ID |
| `PP-EnvironmentName` | String | `295e50db-257c-ea96-882c-67404a3847ec` | Environment ID de Power Platform |
| `PP-SolutionName` | String | `miApp` | Unique name de la solución |
| `PP-DataverseUrl` | String | `https://org35482f4d.crm2.dynamics.com` | URL del Dataverse environment |
| `StorageAccountName` | String | `backupnfd4927` | Nombre del Storage Account |
| `StorageAccountKey` | String (encrypted) | `************` | Access Key del Storage Account |

**Cómo crear variable faltante:**
1. Click **"Add variable"**
2. Name: (nombre exacto de la tabla)
3. Type: **String**
4. Value: (el valor correspondiente)
5. Encrypted: **No** (excepto `StorageAccountKey` → **Yes**)

---

### **3. Credential de Automation**

Ve a: **Azure Portal → Automation Account → Credentials**

Verifica que exista:

- [ ] **Name:** `PP-ServicePrincipal`
  - **Username:** `7fc4ef96-8566-4adb-a579-2030dbf71c35` (Application ID)
  - **Password:** (Client Secret del Service Principal)

**Cómo crear credential:**
1. Click **"Add a credential"**
2. Name: `PP-ServicePrincipal`
3. Username: Application ID del Service Principal
4. Password: Client Secret (desde Entra ID → App registrations → Certificates & secrets)
5. Confirm password
6. Click **Create**

---

### **4. Managed Identity Habilitada**

Ve a: **Azure Portal → Automation Account → Identity**

Verifica:

- [ ] **System assigned** → Status: **On**
- [ ] **Object (principal) ID:** debe tener un GUID

**Si está Off:**
1. Click **System assigned** tab
2. Toggle Status a **On**
3. Click **Save**
4. Espera 1-2 minutos

---

### **5. Permisos en Storage Account**

Ve a: **Azure Portal → Storage Account → Access Control (IAM)**

Verifica que **Managed Identity** del Automation Account tenga:

- [ ] **Role:** Storage Blob Data Contributor

**Cómo agregar:**
1. Click **"Add role assignment"**
2. Role: **Storage Blob Data Contributor**
3. Assign access to: **Managed Identity**
4. Select: (el Automation Account)
5. Click **Save**

---

### **6. Permisos en Power Platform**

Ve a: **Power Platform Admin Center → Environments → [Tu environment] → Settings → Users + permissions → Security roles**

Verifica que Service Principal tenga:

- [ ] **Role:** System Administrator

**Cómo agregar:**
1. Click **"Add user"**
2. Search: (Application ID del Service Principal)
3. Select role: **System Administrator**
4. Click **Save**

---

### **7. API Permissions en Entra ID**

Ve a: **Azure Portal → Entra ID → App registrations → [Tu app] → API permissions**

Verifica que tenga:

- [ ] **Dynamics CRM** → `user_impersonation` (Delegated) → ✅ **Granted**
- [ ] **PowerApps Service** → `User` (Delegated) → ✅ **Granted** (opcional)

**Si falta Grant admin consent:**
1. Click **"Grant admin consent for [Tenant]"**
2. Confirma
3. Verifica que Status = **Granted**

---

### **8. Containers en Storage**

Ve a: **Azure Portal → Storage Account → Containers**

Verifica que existan:

- [ ] `pp-backup` (para backups)
- [ ] `logs` (para logs)

**Cómo crear:**
1. Click **"+ Container"**
2. Name: `pp-backup`
3. Public access level: **Private**
4. Click **Create**
5. Repite para `logs`

---

### **9. Test de Conexión (Opcional)**

Ejecuta este PowerShell local para validar credenciales:

```powershell
$appId = "7fc4ef96-8566-4adb-a579-2030dbf71c35"
$tenantId = "344457f2-bd03-46c6-9974-97bffb8f626a"
$clientSecret = "TU_CLIENT_SECRET"

# Test 1: Token Dataverse
$body = @{
    client_id = $appId
    client_secret = $clientSecret
    scope = "https://org35482f4d.crm2.dynamics.com/.default"
    grant_type = "client_credentials"
}

$response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $body

if ($response.access_token) {
    Write-Host "✓ Token obtenido exitosamente" -ForegroundColor Green
} else {
    Write-Host "✗ Error obteniendo token" -ForegroundColor Red
}
```

---

## 🚀 **Ejecutar Runbook**

Una vez validado todo:

1. **Azure Portal → Automation Account → Runbooks**
2. Click en **Backup-PowerPlatform**
3. Click **Start**
4. Espera 2-5 minutos
5. Revisa **Output** tab para ver progreso
6. Si hay error, revisa **Errors** tab y **logs/powerplatform/errors/** en Storage

---

## 📋 **Errores Comunes y Soluciones**

| Error | Causa | Solución |
|-------|-------|----------|
| Sin output | Módulo faltante | Importa `Microsoft.PowerApps.Administration.PowerShell` |
| "Variable not found" | Variable no existe | Crea la variable en Automation Account |
| "401 Unauthorized" | Token inválido | Verifica Client Secret no expirado |
| "403 Forbidden" | Sin permisos | Agrega System Administrator en Dataverse |
| "Managed Identity not found" | Identity no habilitada | Activa System Assigned en Automation Account |
| "Container not found" | Container no existe | Crea `pp-backup` y `logs` containers |

---

## ✅ **Todo OK? → Ejecuta el runbook!**
