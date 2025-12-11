Eres un Arquitecto de software Senoir, Estoy haciendo un desafio de arquitectura, quiero que leas los requisitos primero y luego de eso leer mi Solución para el desafio, si consideras que hay mejores opciones para resolver este problema házmelo saber, de caso contrario y que mi solución este bien revisa la estructura del informe. No quiero que cambies nada por ahora.

Como voy a manejar la redundanica. Quiero dos sites dos lectura y uno con estritura

Tamaño del bloque en los blobs, los datos en su mayoría son pdf.

Revisar la posibilidad de descargar los datos directamente desde el blob.

30 en hot, 30-60 en cool, >60 cold

6 meses de backup

  "backup":{

    "retention":{

    "coolTierAfterDays":7,

    "deleteAfterDays":30

    },

Agregar credenciales Storage

Credenciales en contenedor de credenciales administradas

Debe respaldar tablas especificas, flujos de Power Automate y app

* Días 0-7: **Hot tier**
* Días 8-60: **Cool tier**
* Días 61-180: **Cold tier**
* > 180 días: **Eliminación automática**
  >

Revisar si la solucion real usa Environment Variables para hacerles backup


Opciones para habilitar URL dinámica:
OPCIÓN 1: Asignar Power Platform Administrator (NO RECOMENDADO)
Pros:

* URL dinámica funcionaría
* Portable entre environments
  Contras:
* MUY PELIGROSO: Da control total sobre TODOS los environments del tenant
* Security risk innecesario para un backup automation

**Cómo hacerlo:**

1. Power Platform Admin Center → https://admin.powerplatform.com
2. Settings → Users + permissions → Security roles
3. Buscar Service Principal: 7fc4ef96-8566-4adb-a579-2030dbf71c35
4. Asignar rol: Power Platform Administrator
5. Esperar 15-30 min propagación
