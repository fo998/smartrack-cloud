/**
 * Node-RED - configuración del SmartRack
 * El instalador reemplaza __USUARIOS_EDITOR__ y copia este archivo
 * a ~/.node-red/settings.js  (equivale a editar settings.js como dice la guía).
 */
module.exports = {
    flowFile: 'flows.json',
    flowFilePretty: true,

    // Las credenciales del broker se guardan en flows_cred.json sin cifrar
    // (archivo con permisos 600). Así el instalador las puede escribir solo.
    credentialSecret: false,

    // Node-RED solo escucha en local; desde internet se entra por nginx
    uiHost: '127.0.0.1',
    uiPort: 1880,

    // Editor:  https://DOMINIO/admin/      API del dashboard:  https://DOMINIO/api/...
    httpAdminRoot: '/admin',
    httpNodeRoot: '/',

    // Login del editor (guía: "node-red admin hash-pw" + editar settings.js).
    // Cuenta NODERED_USUARIO + los administradores de USUARIOS_SO (claves en bcrypt)
    adminAuth: {
        type: 'credentials',
        users: [
__USUARIOS_EDITOR__
        ]
    },

    // "memory" = rápido; "disco" = sobrevive a reinicios (historial y eventos)
    contextStorage: {
        default: { module: 'memory' },
        disco: { module: 'localfilesystem', config: { flushInterval: 30 } }
    },

    functionExternalModules: false,
    exportGlobalContextKeys: false,
    diagnostics: { enabled: false, ui: false },
    runtimeState: { enabled: false, ui: false },

    logging: {
        console: { level: 'info', metrics: false, audit: false }
    },

    editorTheme: {
        page: { title: 'SmartRack · Node-RED' },
        header: { title: 'SmartRack · Node-RED' },
        projects: { enabled: false },
        tours: false
    }
};
