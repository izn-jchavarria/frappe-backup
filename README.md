# iZone Enterprise · Backups

Gestor por menú para automatizar los respaldos de **Frappe / ERPNext** y enviarlos a **unidades de red (CIFS/SMB)** y a **Google Drive**, con horarios propios por destino, diagnóstico integrado y edición posterior sin reinstalar.

```
  ██╗███████╗ ██████╗ ███╗   ██╗███████╗
  ██║╚══███╔╝██╔═══██╗████╗  ██║██╔════╝
  ██║  ███╔╝ ██║   ██║██╔██╗ ██║█████╗
  ██║ ███╔╝  ██║   ██║██║╚██╗██║██╔══╝
  ██║███████╗╚██████╔╝██║ ╚████║███████╗
  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
       E N T E R P R I S E  -  B A C K U P S
```

---

## Ejecución

Un solo comando descarga la última versión y abre el menú:

```bash
wget -qO frappe-backup.sh https://github.com/izn-jchavarria/frappe-backup/releases/latest/download/frappe-backup.sh && sudo bash frappe-backup.sh
```

El enlace apunta siempre a la release más reciente, así que no hay que cambiarlo al publicar versiones nuevas.

### Instalación permanente

Para dejarlo disponible como comando del sistema y volver a abrirlo cuando haga falta:

```bash
wget -qO frappe-backup.sh https://github.com/izn-jchavarria/frappe-backup/releases/latest/download/frappe-backup.sh
sudo install -m 750 frappe-backup.sh /usr/local/bin/frappe-backup.sh
sudo frappe-backup.sh
```

A partir de ahí basta con:

```bash
sudo frappe-backup.sh
```

### Actualizar a una versión nueva

```bash
wget -qO /tmp/frappe-backup.sh https://github.com/izn-jchavarria/frappe-backup/releases/latest/download/frappe-backup.sh
sudo install -m 750 /tmp/frappe-backup.sh /usr/local/bin/frappe-backup.sh
```

Los trabajos ya configurados siguen funcionando: los scripts leen su archivo de configuración en tiempo de ejecución, así que actualizar el gestor no toca lo que ya está programado.

---

## Menú

```
 1) Trabajos de respaldo      - 3 configurado(s)
 2) Cuentas de Google Drive   - 2 conectada(s)
 3) Diagnostico
 0) Salir
```

La pantalla se limpia en cada acción: solo se ve el banner y la sección en la que se está trabajando.

---

## Varios destinos a la vez

Un **trabajo** es un destino con su propio horario. Se pueden tener tantos como haga falta y conviven sin estorbarse: dos NAS distintos, dos cuentas de Google Drive, o cualquier combinación. Si dos trabajos coinciden en la hora, ambos se ejecutan; si tienen horas distintas, cada uno corre por su cuenta.

```
   1) nas-contabilidad  [red]    montado
       destino: //10.0.0.5/Contabilidad/srv-erp
       horario: 12:00 16:00  (lunes a viernes)
   2) nas-bodega        [red]    montado
       destino: //10.0.0.9/Bodega
       horario: 12:00 16:00  (lunes a viernes)
   3) drive-gerencia    [drive]  nube
       destino: izone-backups:Backups/erp
       horario: 11:00  (todos los dias)
```

Cada trabajo lleva una **etiqueta** que usted elige al crearlo (`nas-contabilidad`, `drive-gerencia`) y que se usa en el nombre de todos sus archivos, para que quien dé mantenimiento sepa de un vistazo cuál es cuál.

---

## Navegación en los asistentes

En cualquier pregunta se puede escribir **`v`** para volver al paso anterior o **`x`** para cancelar sin dejar nada configurado. Los pasos van numerados (`[3 de 10]`) y, antes de escribir nada en el sistema, aparece una pantalla de revisión:

```
   1) Etiqueta      : nas-contabilidad
   2) Servidor      : 10.0.0.5
   ...
   8) Retencion     : 30 dias
   9) Programacion  : 12:00 16:00  (lunes a viernes)

   s) Crear el trabajo con estos datos
   x) Cancelar sin crear nada

  Escriba el numero del dato que quiera corregir.
```

Al corregir un dato se vuelve directo a esta pantalla, sin repetir el resto del asistente.

---

## Trabajo hacia una Unidad de Red (CIFS)

Solo se piden cuatro datos: **dirección del servidor**, **usuario**, **contraseña** y **dominio** (`WORKGROUP` si la red no tiene Active Directory). El resto lo averigua el asistente:

1. **Servidor** — comprueba que el puerto 445 responda antes de seguir. Si no responde, explica las causas probables y ofrece corregir la dirección, continuar igual, o indicar otro puerto para casos de NAT o túnel
2. **Credenciales** — se guardan con permisos `600` y sin comillas
3. **Carpeta compartida** — le pregunta al servidor qué recursos publica y los muestra en una lista; luego lista las subcarpetas del elegido. No hay que escribir rutas `//servidor/...` a mano ni adivinar si lleva el volumen interno del NAS
4. **Prueba de conexión** — prueba SMB 3.1.1, 3.0 y 2.1 y se queda con la primera que funcione. Si ninguna conecta, traduce el código de error: `13` credenciales o permisos, `2` ruta inexistente, `112` servidor inalcanzable, `115` puerto bloqueado
5. **Qué se respalda y cuándo** — bench, sitio, adjuntos, retención y horarios

Al confirmar escribe `/etc/fstab`, monta y verifica escritura real en el destino. El respaldo se deposita como `<montaje>/<fecha>/<hora>/` y el origen local se libera solo si la copia terminó correctamente.

---

## Trabajo hacia Google Drive (rclone)

El servidor no tiene navegador y Google exige uno para autorizar, así que el trabajo se reparte:

1. **Conectar la cuenta** — el asistente muestra cómo instalar rclone en su computadora y el comando exacto a ejecutar (`rclone authorize "drive"`). Usted pega el token resultante y la cuenta queda registrada, sin pasar por el asistente interactivo de rclone
2. **Credenciales propias de Google** — opcional pero recomendado: rclone trae credenciales públicas compartidas por todos sus usuarios y, cuando ese cupo se satura, Google responde `403 Quota exceeded` y las operaciones tardan minutos. Con un ID de cliente propio eso desaparece
3. **Carpeta destino** — navegador de carpetas dentro del Drive: entrar con un número, `s` subir un nivel, `n` crear carpeta, `a` usar la actual. Al confirmar hace una prueba real de escritura
4. **Qué se respalda y cuándo** — bench, sitio, adjuntos, si se borra el respaldo local tras subirlo, retención y horarios

El respaldo se sube a `<cuenta>:<ruta>/<fecha>/<hora>/`, se borra el temporal y —opcionalmente— el respaldo local.

---

## Menú de cada trabajo

Al elegir un trabajo de la lista se puede, sin reinstalar nada:

- Ejecutar el respaldo en el momento
- Cambiar horarios y días
- Cambiar el destino (cadena de conexión, o cuenta y carpeta de Drive)
- Cambiar qué se respalda (bench, sitio, adjuntos)
- Cambiar la retención
- Ver la configuración, el cron generado y el log
- En trabajos de red: actualizar credenciales y montar en el momento
- Eliminar el trabajo, limpiando cron, `/etc/fstab` y credenciales

---

## Programación de horarios

Al crear el trabajo se escriben las **horas reales** del día, separadas por coma, y se eligen los días de una lista:

```
Horas de respaldo: 12:00,18:00

  1) Todos los dias
  2) Lunes a viernes
  3) Fin de semana (sabado y domingo)
  4) Personalizado (formato cron)
```

El gestor agrupa por minuto y genera las líneas de cron necesarias. Por ejemplo `06:30,12:00,15:00` produce:

```
0  12,15 * * *  /usr/local/bin/<host>-backup-<etiqueta>.sh >> ...
30 6     * * *  /usr/local/bin/<host>-backup-<etiqueta>.sh >> ...
```

Cada trabajo vive en su propio bloque marcado dentro del crontab de `root`, así que reprogramar uno reemplaza solo su bloque y no toca los demás.

Después, desde el menú del trabajo, los horarios se editan sin rehacer la lista:

```
  Horas configuradas:
    1) 12:00
    2) 16:00
  Dias: lunes a viernes

   1) Agregar una hora
   2) Quitar una hora
   3) Cambiar los dias
   4) Reemplazar toda la lista de horas
```

---

## Qué contiene cada respaldo

Cada ejecución genera un volcado **completo** del sitio en ese instante, no incremental. El de las 6:00 p.m. no contiene solo lo ocurrido desde el de las 7:00 a.m.: contiene todo el estado a esa hora.

Esto significa que **cada carpeta es autosuficiente**: para restaurar basta una, la que elija, sin encadenar nada. Más horarios al día no producen respaldos más pequeños, sino un punto de recuperación más cercano.

Con `--with-files` se incluyen además los archivos adjuntos (los PDF de una factura, fotos, escaneos). Sin esa opción el respaldo pesa mucho menos, pero al restaurar los adjuntos aparecen como enlaces rotos. Es la parte que más espacio consume, porque se copia completa cada vez aunque no haya cambiado.

---

## Diagnóstico

Recorre todos los trabajos, uno por pantalla:

- Montaje CIFS activo y **prueba real de escritura** en el destino
- Cuenta de rclone registrada y acceso a la carpeta destino
- Entradas de cron activas, estado del servicio y últimas líneas del log
- Entorno Frappe: bench, entorno virtual, sitio y carpeta de backups

---

## Nomenclatura

Los archivos de cada trabajo se nombran como `<hostname>-backup-<etiqueta>`, combinando el equipo y el destino. Con `hostname -s` = `aip-srv-acct` y la etiqueta `nas-contabilidad`:

| Elemento | Ruta |
|---|---|
| Script | `/usr/local/bin/aip-srv-acct-backup-nas-contabilidad.sh` |
| Configuración | `/etc/izone-backup/aip-srv-acct-backup-nas-contabilidad.conf` |
| Credenciales (solo red) | `/etc/izone-backup/aip-srv-acct-backup-nas-contabilidad.cred` |
| Log | `/var/log/izone-backup/aip-srv-acct-backup-nas-contabilidad.log` |
| Punto de montaje (solo red) | `/mnt/aip-srv-acct-backup-nas-contabilidad` |

Los scripts de respaldo **leen su `.conf` en tiempo de ejecución**: cualquier cambio hecho desde el menú aplica de inmediato sin regenerar nada.

---

## Requisitos

- Ubuntu / Debian con `systemd` y `cron`
- Acceso `root` (`sudo`)
- Un bench de Frappe/ERPNext funcional en el servidor
- Para unidad de red: recurso SMB accesible desde **el servidor** y un usuario **del servidor de archivos** con permiso de lectura y escritura sobre la carpeta compartida
- Para Google Drive: una computadora con navegador y rclone, solo la primera vez, para generar el token

Los paquetes que falten (`cifs-utils`, `rsync`, `smbclient`, `rclone`) los instala el propio gestor.

---

## Notas de operación

- En `/etc/fstab` se agrega `nofail` junto a `_netdev` para que el servidor no quede colgado en el arranque si el NAS no responde.
- Cada escritura de `/etc/fstab` deja un respaldo `/etc/fstab.bak.<fecha>` y reemplaza la línea previa del mismo punto de montaje en vez de duplicarla.
- El archivo de credenciales CIFS se guarda con permisos `600` y **sin comillas**: las comillas se interpretan de forma literal y provocan `mount error(13)`.
- En un NAS Synology la ruta CIFS **no incluye** el volumen interno (`volume1`). Si DSM muestra `/volume1/Informatica/backup-aca`, la conexión correcta es `//IP/Informatica/backup-aca`.
- El permiso debe estar a nivel de **carpeta compartida**, no solo de la subcarpeta: es la causa más común del `mount error(13)`.
- SMB viaja por el puerto **445**. El 5001 de Synology es la interfaz web DSM y no sirve para archivos compartidos.

---

<sub>iZone Enterprise · Nicaragua</sub>
