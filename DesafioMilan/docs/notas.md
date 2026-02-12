

30 en hot, 30-60 en cool, >60 cold

Agregar credenciales Storage

Credenciales en contenedor de credenciales administradas

Debe respaldar tablas especificas, flujos de Power Automate y app

* Días 0-7: **Hot tier**
* Días 8-60: **Cool tier**
* Días 61-180: **Cold tier**
* > 180 días: **Eliminación automática**

Revisar si la solucion real usa Environment Variables para hacerles backup






| Aspecto                     | Azure Automation (Actual)                                              | GitHub Actions       | Azure DevOps         |
| --------------------------- | ---------------------------------------------------------------------- | -------------------- | -------------------- |
| **Setup time**        | ✅ 30 min                                                              | ⚠️ 2-4 horas       | ⚠️ 4-8 horas       |
| **Complejidad**       | ✅ Baja                                                                | ⚠️ Media           | ❌ Alta              |
| **Costo (tu escala)** | ✅ ~$5/mes                | ✅ Gratis            | ⚠️ Gratis-$40/mes |                      |                      |
| **Auditoría**        | ⚠️ 30 días logs                                                     | ✅ Permanente (Git)  | ✅ Permanente        |
| **Aprobaciones**      | ❌ No nativo                                                           | ✅ Environments      | ✅ Release gates     |
| **CI/CD integration** | ❌ No                                                                  | ✅ Excelente         | ✅ Excelente         |
| **Curva aprendizaje** | ✅ 1 día                                                              | ⚠️ 1-2 semanas     | ❌ 2-4 semanas       |
| **Ideal para**        | ✅ Backups automáticos                                                | ✅ ALM de soluciones | ⚠️ Orgs enterprise |



5 personas aprox en el sharepoint

Máquina Virtual en Azure (100% Cloud)

Si no tienes servidores físicos y quieres todo en la nube:

Creas una VM pequeña en Azure (ej. Standard_B2s o B2ms).

Windows Server.

2 vCPUs, 4-8 GB RAM.

Costo de la VM: Aprox. $30 - $40 USD/mes (si la dejas encendida 24/7).

Truco de Ingeniero: Como son solo 10 usuarios, el backup tarda 30 minutos. Usas Azure Automation para encender la VM a las 3 AM, correr el backup, y apagarla a las 4 AM.

Costo optimizado: ~$5 USD/mes en cómputo.~$15-18 USD/mes (Cómputo + Disco OS + Blob), no $5.







1. Ejecuta el restore ahora - Debe completar exitosamente en 25-30 min
2. Una vez que funcione perfectamente, volveremos al problema de fileattachment
3. El código de File Upload API sigue en el runbook pero no se ejecutará