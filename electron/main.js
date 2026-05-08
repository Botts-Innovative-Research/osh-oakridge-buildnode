const { app, BrowserWindow, dialog, Menu, Tray } = require('electron');
const path = require('path');
const express = require('express');

// Disable all background throttling before app is ready
app.commandLine.appendSwitch('disable-background-timer-throttling');
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');

let mainWindow = null;
let tray = null;
let servePort = null;

function getWebPath() {
    return app.isPackaged
        ? path.join(process.resourcesPath, 'web')
        : path.join(__dirname, '../web/oscar-viewer/web');
}

function startServer(callback) {
    const server = express();
    const webPath = getWebPath();

    server.use(express.static(webPath));
    server.get('*', (_req, res) =>
        res.sendFile(path.join(webPath, '404.html'), err => {
            if (err) res.sendFile(path.join(webPath, 'index.html'));
        })
    );

    // Fixed port keeps localStorage stable across restarts (origin must not change)
    const listener = server.listen(38282, '127.0.0.1', () => {
        servePort = listener.address().port;
        callback();
    });
}

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1920,
        height: 1080,
        minWidth: 1280,
        minHeight: 720,
        title: 'OSCAR',
        icon: path.join(__dirname, 'assets', 'icon.ico'),
        show: false,
        autoHideMenuBar: true,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true,
            webSecurity: false, // allows cross-origin API calls to the OSH-Node server
        },
    });

    Menu.setApplicationMenu(null);
    mainWindow.loadURL(`http://localhost:${servePort}/`);
    mainWindow.once('ready-to-show', () => {
        mainWindow.show();
        mainWindow.maximize();
    });

    // Ctrl+R / F5 — reload after first-time node configuration
    mainWindow.webContents.on('before-input-event', (_event, input) => {
        if (input.type === 'keyDown' &&
            (input.key === 'F5' || (input.control && input.key.toLowerCase() === 'r'))) {
            mainWindow.webContents.reload();
        }
    });

    mainWindow.on('close', event => {
        event.preventDefault();
        const choice = dialog.showMessageBoxSync(mainWindow, {
            type: 'warning',
            buttons: ['Cancel', 'Exit OSCAR'],
            defaultId: 0,
            cancelId: 0,
            title: 'Exit OSCAR?',
            message: 'Active radiation monitoring will stop.',
            detail: 'Are you sure you want to exit OSCAR?',
        });
        if (choice === 1) {
            mainWindow = null;
            app.exit(0);
        }
    });
}

function createTray() {
    tray = new Tray(path.join(__dirname, 'assets', 'tray-icon.png'));
    tray.setToolTip('OSCAR — Radiation Detection');
    tray.setContextMenu(Menu.buildFromTemplate([
        {
            label: 'Show OSCAR',
            click: () => { mainWindow?.show(); mainWindow?.focus(); },
        },
        {
            label: 'Reload',
            click: () => mainWindow?.webContents.reload(),
        },
        { type: 'separator' },
        {
            label: 'Exit OSCAR',
            click: () => {
                const choice = dialog.showMessageBoxSync({
                    type: 'warning',
                    buttons: ['Cancel', 'Exit OSCAR'],
                    defaultId: 0,
                    cancelId: 0,
                    title: 'Exit OSCAR?',
                    message: 'Active radiation monitoring will stop.',
                    detail: 'Are you sure you want to exit OSCAR?',
                });
                if (choice === 1) app.exit(0);
            },
        },
    ]));
    tray.on('double-click', () => { mainWindow?.show(); mainWindow?.focus(); });
}

app.whenReady().then(() => {
    // Register autostart on Windows login (packaged builds only)
    if (app.isPackaged && process.platform === 'win32') {
        app.setLoginItemSettings({ openAtLogin: true, path: app.getPath('exe') });
    }

    // Intercept OSH-Node 401 challenges and supply saved node credentials automatically
    app.on('login', (event, _webContents, _details, authInfo, callback) => {
        event.preventDefault();
        mainWindow?.webContents
            .executeJavaScript(`localStorage.getItem('osh_nodes')`)
            .then(raw => {
                const nodes = JSON.parse(raw || '[]');
                const node = nodes.find(n =>
                    n.address === authInfo.host ||
                    String(n.port) === String(authInfo.port)
                );
                callback(node?.auth?.username ?? '', node?.auth?.password ?? '');
            })
            .catch(() => callback('', ''));
    });

    startServer(() => {
        createWindow();
        createTray();
    });
});

// Keep the process alive via tray — do not quit when the window is closed
app.on('window-all-closed', () => {});
