# **Sistema de Respaldo Power Platform + SharePoint**

**Autor:** Milan Kurte
**Proyecto:** Desafío de Arquitectura NFD Data
**Fecha:** Diciembre 2025

---

## **Visión General del Sistema**

Sistema de respaldo automatizado de **3 capas** para proteger soluciones productivas de Power Platform y SharePoint Online:

1. **M365 / Power Platform + SharePoint** → Plataformas productivas
2. **Azure** → Orquestación y almacenamiento de respaldos diarios
3. **On-premise (HDD)** → Copia física semanal **automatizada** via Hybrid Runbook Worker

### **Características Principales**

- **Automatización 100%** - Sin intervención manual (diaria o semanal)
- **RPO: 24 horas** - Pérdida máxima de un día de datos
- **RTO: 6 horas** - Recuperación en menos de media jornada laboral
- **Costo: $4-8/mes** - 7-13% del presupuesto disponible ($60/mes)
- **Ahorro: $960/año** - Vs. proceso manual tradicional

---

## **Arquitectura de Componentes**

### **Capa 1: Plataformas M365**

#### **Power Platform**

- Ambiente productivo con aplicaciones Canvas/Model-Driven
- Flujos de Power Automate
- Soluciones completas empaquetadas
- Tablas críticas de Dataverse

#### **SharePoint Online**

- Biblioteca de documentación del cliente
- Estructura de carpetas y archivos
- Metadata básica (creación, modificación)

---

### **Capa 2: Azure (Orquestación y Almacenamiento)**

#### **Microsoft Entra ID (Azure AD)**

- **Función:** Identity & Access Management (IAM)
- **Managed Identity:** Autenticación segura para runbooks en la nube
- **SAS Tokens:** Acceso de solo lectura para Hybrid Worker
- **RBAC:** Control granular de permisos (mínimo privilegio)

#### **Azure Automation Account**

- **Función:** Orquestador central de procesos automatizados
- **Runbooks:**
  - `Backup-PowerPlatform.ps1` → Diario 02:00 AM (nube)
  - `Backup-SharePoint.ps1` → Diario 02:10 AM (nube)
  - `Backup-FisicoSemanal.ps1` → Semanal domingo 02:00 AM (Hybrid Worker)
- **Schedules:** Programación automática sin intervención humana
- **Jobs:** Trazabilidad completa de ejecuciones

#### **Azure Storage Account**

- **Tipo:** StorageV2 Standard LRS
- **Tier:** Cool (optimizado para costos)
- **Contenedores:**
  - `pp-backup` → Soluciones, apps, datos Dataverse
  - `sp-backup` → Bibliotecas SharePoint comprimidas
  - `logs` → Logs estructurados en JSON
- **Retención:** 30 días con Lifecycle Management
- **Seguridad:** Cifrado en tránsito y en reposo

---

### **Capa 3: On-Premise (Contingencia Automatizada)**

#### **Hybrid Runbook Worker**

- **Función:** Agente que ejecuta runbooks localmente desde Azure Automation
- **Ubicación:** PC dedicado en oficina principal
- **Conectividad:** HTTPS seguro con Azure Automation
- **Costo:** $0 (incluido en Azure Automation)
- **Beneficios:**
  - Elimina intervención manual semanal
  - Logs centralizados en Azure Portal
  - Ejecución garantizada por schedule
  - Sin riesgo de olvido humano

#### **HDD Físico Local**

- **Capacidad:** Mínimo 100 GB
- **Actualización:** Semanal automática (viernes 20:00)
- **Herramienta:** AzCopy con SAS token de solo lectura
- **Custodia:** Jefe de Tecnología
- **Cifrado:** BitLocker recomendado

---

## **Flujos de Respaldo**

### **Flujo Diario en la Nube (02:00 AM)**

![Texto alternativo de la imagen](nfddataa\Milan\images\FlujoDiarioNube.png)

```
┌─────────────────────────────────────────────────────────┐
│  AZURE AUTOMATION - Schedule Diario 02:00 AM           │
└────────────────────┬────────────────────────────────────┘
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ Runbook PP      │     │ Runbook SP      │
│ (Managed ID)    │     │ (Managed ID)    │
└────────┬────────┘     └────────┬────────┘
         │                       │
         ▼                       ▼
┌─────────────────┐     ┌─────────────────┐
│ Power Platform  │     │ SharePoint      │
│ - Export Sol.   │     │ - Download Lib  │
│ - Export Data   │     │ - Compress      │
└────────┬────────┘     └────────┬────────┘
         │                       │
         └───────────┬───────────┘
                     ▼
         ┌─────────────────────┐
         │  AZURE STORAGE      │
         │  - pp-backup/       │
         │  - sp-backup/       │
         │  - logs/            │
         └─────────────────────┘
```

**Pasos:**

1. Schedule automático dispara runbook a las 02:00 AM
2. Managed Identity autentica con Power Platform y SharePoint
3. Exportación de soluciones, flujos y datos críticos
4. Descarga de biblioteca SharePoint con paginación
5. Compresión optimizada de archivos
6. Subida a Azure Storage Account
7. Generación de logs estructurados en JSON
8. Cumple **RPO de 24 horas**

---

## Plataformas y tecnologías involucradas

* **Power Platform (M365)**
  * Ambiente donde está la app principal, solución, flujos y (posible) Dataverse.
* **SharePoint Online (M365)**
  * Sitio / biblioteca con la documentación de la solución.
* **Microsoft Entra ID (Azure AD)**
  * Manejo de identidades y permisos (IAM).
  * Identidad técnica / managed identity para ejecutar los respaldos.
  * Roles para controlar quién puede leer/escribir respaldos.
* **Azure Automation**
  * Servicio que ejecuta **runbooks** programados (scripts) todos los días.
  * Se encarga de:
    * Conectarse a Power Platform para exportar la solución y datos críticos.
    * Conectarse a SharePoint para respaldar la documentación.
* **Azure Storage Account (Blob Storage, tier Cool)**
  * “Bodega” en la nube donde se guardan los archivos de respaldo:
    * Respaldos de Power Platform (solutions, CSV/JSON de datos).
    * Respaldos de SharePoint (zips de bibliotecas).
    * Logs de ejecución.
* **On-premise HDD (copia física semanal)**
  * Disco físico proporcionado por tu jefe.
  * Recibe una copia semanal del contenido del Storage Account usando una herramienta tipo **AzCopy** desde un PC admin.

*(Opcional si decides usarlo)*

* **Microsoft 365 Backup**
  * Servicio nativo de Microsoft para backup/restore rápido de SharePoint.
  * Se podría usar como capa específica para SharePoint, complementando lo que ya haces en Azure.

---

## Flujo diario (capa principal en Azure)

1. **02:00 AM aprox.** → Azure Automation dispara el runbook de respaldo.
2. La **identidad técnica** se autentica vía Entra ID con permisos limitados.
3. El runbook:
   * Exporta la **solución de Power Platform** (y datos críticos si aplica).
   * Extrae y empaqueta la **biblioteca de SharePoint** relevante.
4. Los archivos generados se guardan en la  **Storage Account** :
   * Contenedor `pp-backup` para Power Platform.
   * Contenedor `sp-backup` para SharePoint.
5. Se escriben **logs** en un contenedor `logs` para tener evidencia de que el respaldo corrió bien.
6. Con esto, siempre hay un respaldo con una antigüedad máxima de 24 h →  **cumple RPO** .

---

## **Flujo Semanal On-Premise (Viernes 20:00) - AUTOMATIZADO**

```
┌─────────────────────────────────────────────────────────┐
│  AZURE AUTOMATION - Schedule Semanal Viernes 02:00 AM   │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ Job dispatch via HTTPS
                     ▼
┌─────────────────────────────────────────────────────────┐
│  HYBRID RUNBOOK WORKER (PC On-Premise)                  │
│  - Agent instalado en PC local                         │
│  - Ejecuta Backup-FisicoSemanal.ps1                    │
└────────────────────┬────────────────────────────────────┘
                     │
                     │ AzCopy sync (SAS token read-only)
                     ▼
         ┌─────────────────────┐
         │  AZURE STORAGE      │
         │  - pp-backup/       │
         │  - sp-backup/       │
         │  - logs/            │
         └─────────┬───────────┘
                   │
                   │ Sincronización
                   ▼
         ┌─────────────────────┐
         │  HDD LOCAL          │
         │              │
         └─────────────────────┘
```

**Pasos (100% Automatizados):**

1. Schedule semanal activa runbook a las 20:00 viernes
2. Azure Automation envía job al Hybrid Worker
3. Runbook se ejecuta localmente en PC on-premise
4. AzCopy sincroniza contenedores usando SAS token
5. Solo descarga archivos nuevos/modificados (eficiente)
6. Genera log local: `backup_fisico_YYYYMMDD.log`
7. Job completo visible en Azure Portal
8. **Cero intervención humana**

**Ventajas vs. Manual:**

- **Manual:** Requiere 1h/semana → $80/mes de costo humano
- **Automatizado:** $0 de costo humano, sin olvidos
- Logs centralizados en Azure
- Alertas automáticas si falla
- Ejecución garantizada por schedule

---

## **Tecnologías y Módulos**

### **PowerShell Modules**

- `Microsoft.PowerApps.Administration.PowerShell` → Administración Power Platform
- `PnP.PowerShell` → Gestión SharePoint Online
- `Az.Storage` → Operaciones Azure Storage
- `Az.Automation` → Gestión de Automation Account

### **Herramientas**

- **AzCopy** → Sincronización eficiente de blobs
- **PowerShell 7.2** → Runtime de runbooks
- **Git** → Control de versiones de scripts

### **APIs Utilizadas**

- Power Platform REST API (Dataverse)
- Microsoft Graph API (SharePoint)
- Azure Storage REST API

---

## **Seguridad e IAM**

### **Principio de Mínimo Privilegio**

| Componente                          | Identidad          | Permisos                                                    | Alcance                                              |
| ----------------------------------- | ------------------ | ----------------------------------------------------------- | ---------------------------------------------------- |
| **Runbooks diarios (nube)**   | Managed Identity   | Power Platform Admin, SharePoint Admin, Storage Contributor | Solo ambiente productivo y contenedores específicos |
| **Runbook semanal (on-prem)** | SAS Token          | Read-only                                                   | Solo contenedores pp-backup, sp-backup, logs         |
| **Administrador técnico**    | Usuario Entra ID   | Automation Contributor                                      | Gestión de runbooks y schedules                     |
| **Restauración**             | Usuario autorizado | Storage Blob Data Reader                                    | Solo lectura para recovery                           |

### **Gestión de Secretos**

- **SAS Tokens:** Variables cifradas en Automation Account
- **Renovación:** Mensual (30 días de vigencia)
- **Auditoría:** Logs de acceso en Storage Analytics

---

## **Costos y Presupuesto**

| Servicio              | Detalle                               | Costo Mensual |
| --------------------- | ------------------------------------- | ------------- |
| Azure Storage Account | Cool tier, ~50GB, 30 días retención | $1.50 - $3.00 |
| Azure Automation      | 3 runbooks, ~650 min/mes              | $1.30 - $2.00 |
| Hybrid Runbook Worker | Agente gratuito                       | $0.00         |
| Data Transfer Out     | ~50GB/mes descarga semanal            | $1.00 - $2.00 |
| Logs & Monitoring     | Application Insights básico          | $0.50 - $1.00 |

**TOTAL:** $4.30 - $8.00/mes (7-13% del presupuesto de $60/mes)
**AHORRO vs. Manual:** $80/mes ($960/año)

---

## **Recuperación ante Desastres**

### **Escenario 1: Pérdida Parcial (RTO: 1-2h)**

- Descargar último backup desde Azure Storage
- Importar solución en Power Platform
- Validar flujos y conexiones
- **Fuente:** Backup diario en Azure

### **Escenario 2: Pérdida Total SharePoint (RTO: 2-4h)**

- Descargar ZIP de sp-backup
- Restaurar biblioteca con PnP.PowerShell
- Verificar estructura y permisos
- **Fuente:** Backup diario en Azure

### **Escenario 3: Caída del Tenant M365 (RTO: 4-6h)**

- Acceder al HDD local (última copia semanal)
- Provisionar ambiente alternativo
- Restaurar desde backup físico
- **Fuente:** Backup semanal automatizado on-premise

---

## **Monitoreo y Alertas**

### **Alertas Configuradas**

- Fallo de runbook diario
- Fallo de Hybrid Worker
- Exceso de presupuesto (>80% de $60)
- Errores de API throttling

---

## **Documentación Técnica**

### **Archivos en este repositorio**

- `DesafioMilan.md` → Informe técnico completo con código
- `InformeEjecutivo_SistemaRespaldo.md` → Informe ejecutivo para stakeholders
- `README.md` → Este archivo (visión general)

### **Scripts (en desarrollo)**

- `Backup-PowerPlatform.ps1` → Runbook diario PP
- `Backup-SharePoint.ps1` → Runbook diario SP
- `Backup-FisicoSemanal.ps1` → Runbook Hybrid Worker
- `Restore-PowerPlatform.ps1` → Script de restauración PP
- `Restore-SharePoint.ps1` → Script de restauración SP

---

## **Requisitos para Implementación**

### **Azure**

- Suscripción Azure activa
- Resource Group creado
- Storage Account aprovisionado
- Automation Account configurado

### **PC On-Premise (Hybrid Worker)**

- Windows 10/11 Pro o Windows Server 2016+
- Conexión a Internet estable
- Espacio en disco: 100 GB mínimo
- AzCopy instalado
- Hybrid Worker agent registrado
- **Disponibilidad:** Encendido viernes 20:00-21:00

### **Permisos M365**

- Power Platform Administrator
- SharePoint Administrator
- Global Reader (para auditoría)

---

## **Próximos Pasos**

### **Fase 1: Preparación (Semana 1)**

- [X] Diseño de arquitectura
- [ ] Aprovisionamiento de recursos Azure
- [ ] Creación de Managed Identity
- [ ] Asignación de permisos RBAC

### **Fase 2: Desarrollo (Semanas 2-3)**

- [ ] Desarrollo runbooks Power Platform y SharePoint
- [ ] Desarrollo runbook Hybrid Worker
- [ ] Configuración de schedules
- [ ] Implementación de logs estructurados

### **Fase 3: Pruebas (Semana 4)**

- [ ] Instalación Hybrid Worker en PC
- [ ] Pruebas de respaldo en ambiente dev
- [ ] Simulacro de restauración completa
- [ ] Validación RPO/RTO

### **Fase 4: Producción (Semana 5)**

- [ ] Migración a ambiente productivo
- [ ] Monitoreo intensivo (2 semanas)
- [ ] Ajustes basados en métricas
