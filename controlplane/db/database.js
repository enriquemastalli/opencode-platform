const sqlite3 = require('sqlite3').verbose();
const path = require('path');
const fs = require('fs');

// The DB file location based on context specs
const dbDir = '/srv/opencode';
const devDbDir = path.resolve(__dirname, '..', '..', 'dev_data');
let dbPath;

// Fallback to local dev directory if we are not running as root/in production location
if (fs.existsSync(dbDir) && process.env.NODE_ENV === 'production') {
    dbPath = path.join(dbDir, 'controlplane.db');
} else {
    if (!fs.existsSync(devDbDir)) {
        fs.mkdirSync(devDbDir, { recursive: true });
    }
    dbPath = path.join(devDbDir, 'controlplane.db');
}

console.log(`Using database at: ${dbPath}`);

const db = new sqlite3.Database(dbPath, (err) => {
    if (err) {
        console.error('Error opening database', err.message);
    } else {
        console.log('Connected to the SQLite database.');
        initDb();
    }
});

function initDb() {
    db.serialize(() => {
        // Configuration table
        db.run(`CREATE TABLE IF NOT EXISTS config (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )`);

        // Workspaces table
        db.run(`CREATE TABLE IF NOT EXISTS workspaces (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            branch TEXT NOT NULL,
            status TEXT DEFAULT 'STOPPED',
            pid INTEGER,
            port INTEGER
        )`);

        // Insert default status if not exists
        db.get(`SELECT value FROM config WHERE key = 'status'`, (err, row) => {
            if (err) {
                console.error('Error querying config', err);
            } else if (!row) {
                db.run(`INSERT INTO config (key, value) VALUES ('status', 'UNCONFIGURED')`);
            }
        });
    });
}

function getConfig(key) {
    return new Promise((resolve, reject) => {
        db.get(`SELECT value FROM config WHERE key = ?`, [key], (err, row) => {
            if (err) reject(err);
            else resolve(row ? row.value : null);
        });
    });
}

function setConfig(key, value) {
    return new Promise((resolve, reject) => {
        db.run(`INSERT INTO config (key, value) VALUES (?, ?) 
                ON CONFLICT(key) DO UPDATE SET value=excluded.value`, 
                [key, value], (err) => {
            if (err) reject(err);
            else resolve();
        });
    });
}

module.exports = {
    db,
    getConfig,
    setConfig
};