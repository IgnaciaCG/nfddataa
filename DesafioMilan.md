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

  * Exportación de la **solución productiva** (formato `.zip`, managed o unmanaged).
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
  # **3. Requerimientos Funcionales y No Funcionales**

  ## **3.1 Funcionales**

  * Respaldar diariamente Power Platform y SharePoint.
  * Almacenar los respaldos de forma segura en Azure.
  * Permitir restaurar la solución en menos de 6 horas (RTO).
  * Garantizar pérdida máxima de 24 horas de datos (RPO).

  ## **3.2 No Funcionales**

  * Usar únicamente servicios Azure dentro del límite mensual de USD $60.
  * Minimizar uso de recursos costosos como máquinas virtuales.
  * Controlar accesos usando mecanismos IAM de Azure (Entra ID + RBAC).
  * Mantener evidencia de ejecución mediante logs.

  ---

  # **4. Arquitectura Propuesta del Sistema de Respaldo**

  La solución fue diseñada bajo los principios de simplicidad, economía y seguridad.

  ## **4.1 Componentes**

  ### **A. Microsoft Entra ID (Azure AD)**

  * Identity & Access Management del sistema.
  * Creación de una **Identidad de Servicio** o **Managed Identity** asociada al Automation Account.
  * Asignación de roles RBAC mínimos necesarios:

    * **Power Platform Admin / Environment Maker** (solo en ambiente a respaldar).
    * **SharePoint Administrator** (solo en sitio específico).
    * **Storage Blob Data Contributor** (solo para contenedor de backups).

  ### **B. Azure Automation Account**

  * Orquestador del proceso de respaldo.
  * Contendrá dos **Runbooks (PowerShell)**:

    * `Backup-PowerPlatform.ps1`
    * `Backup-SharePoint.ps1`
  * Programación diaria a las 02:00 AM.
  * Uso preferente de **Managed Identity** para autenticación segura.

  ### **C. Azure Storage Account**

  * Tipo: **StorageV2 Standard LRS**
  * Access Tier: **Cool** (reduce costos).
  * Contenedores:

    * `pp-backup` → Soluciones, apps, Dataverse.
    * `sp-backup` → Bibliotecas/archivos SharePoint.
    * `logs` → Registros de ejecución y auditoría.

  ### **D. HDD Físico (Contingencia)**

  * Copia semanal desde Storage Account usando **AzCopy**.
  * Medio físico provisto por el jefe.
  * Se define dentro del **Plan de Contingencia**, no como parte del sistema principal.

  ---

  # **5. Flujo de Respaldo**

  ## **5.1 Flujo Power Platform**

  1. El Runbook `Backup-PowerPlatform.ps1` inicia por programación.
  2. La identidad del Automation Account se autentica vía Managed Identity.
  3. Se ejecuta la exportación de la solución productiva:

    * `pac solution export –environment … –path solution_YYYYMMDD.zip`
  4. Si corresponde, se exportan tablas relevantes de Dataverse en formato CSV/JSON.
  5. Los archivos se suben al contenedor `pp-backup`.
  6. Se registra la ejecución en `logs`.

  ## **5.2 Flujo SharePoint**

  1. El Runbook `Backup-SharePoint.ps1` llama a MS Graph o PnP.PowerShell.
  2. Descarga la biblioteca SharePoint o sus cambios del día.
  3. Genera un archivo comprimido `sp_docs_YYYYMMDD.zip`.
  4. Sube el respaldo al contenedor `sp-backup`.
  5. Guarda logs en `logs`.

  ## **5.3 Copia Física Semanal**

  1. Un administrador ejecuta manualmente:

    ```
    azcopy sync "https://storageaccount/pp-backup" "E:\Backups\PP" --recursive
    ```
  2. Repite para SharePoint.
  3. Guarda el disco en ubicación física segura.

  ---

  # **6. IAM – Gestión de Identidades y Accesos**

  Aunque IAM es un término general, en Azure se implementa con:

  ### **6.1 Entra ID**

  * Crea identidades (usuarios, grupos, aplicaciones).
  * Emite tokens de autenticación.

  ### **6.2 Azure RBAC**

  Roles propuestos:

  | Recurso                    | Rol                           | Asignado a                     |
  | -------------------------- | ----------------------------- | ------------------------------ |
  | Storage Account            | Storage Blob Data Contributor | Identidad de servicio          |
  | Automation Account         | Contributor                   | Admin técnica                 |
  | Power Platform Environment | Environment Admin o Maker     | Identidad de servicio          |
  | SharePoint Site            | Site Admin                    | Identidad de servicio          |
  | Storage Account (lectura)  | Storage Blob Data Reader      | Persona autorizada a restaurar |

  El objetivo es que **nadie excepto las identidades definidas** pueda manipular los respaldos.

  ---

  # **7. Cadencia y Justificación (RPO/RTO)**

  ## **7.1 Cadencia diaria (02:00 AM)**

  * Permite cumplir **RPO = 24 horas**.
  * Evita alto uso de APIs durante horarios laborales.
  * Minimiza costos (menos llamadas API, menos cargas).

  ## **7.2 Justificación**

  * La solución no requiere cambios múltiples por hora.
  * La documentación en SharePoint se modifica menos frecuentemente.
  * La restauración diaria mantiene el proceso simple y barato.

  ## **7.3 RTO = 6 horas**

  Factores que permiten cumplirlo:

  * Restauración de solución Power Apps toma minutos.
  * Restauración de SharePoint es directa (repositorio de archivos).
  * Scripts de recuperación documentados.
  * Todo está en Storage Account de rápido acceso.

  ---

  # **8. Plan de Contingencia**

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

  # **9. Costos Estimados**

  | Servicio                            | Costo estimado mensual |
  | ----------------------------------- | ---------------------- |
  | Storage Account (Cool, <50 GB)      | USD $1–3              |
  | Azure Automation (runbooks ligeros) | USD $0.50–2           |
  | Data Transfer Out                   | ~USD $1–3             |
  | Logs/Monitoring                     | USD $0–1              |

  **Total estimado:** USD $6–10 por mes
  → **Muy por debajo del límite de USD $60**, incluso con crecimiento de datos.

  ---

  # **10. Conclusiones**

  La arquitectura propuesta:

  * **Cumple integralmente** con los requisitos técnicos entregados.
  * Respeta el **presupuesto Azure** con amplio margen.
  * Asegura restauración dentro de los tiempos definidos (RTO 6h).
  * Minimiza pérdida de datos gracias a respaldos diarios (RPO 24h).
  * Implementa una solución **sin servicios de terceros** y totalmente administrable.
  * Usa servicios nativos de Azure y M365, manteniendo la complejidad muy baja.
  * Incluye una estrategia racional de copia física para contingencias extremas.

  En conclusión, este sistema es **simple, robusto, económico y seguro**, ajustándose plenamente al desafío asignado.