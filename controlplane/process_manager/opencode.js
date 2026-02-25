const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

let opencodeProcess = null;
let opencodePort = 8080; // default OpenCode Web port

function spawnOpenCode() {
    return new Promise((resolve, reject) => {
        if (opencodeProcess && !opencodeProcess.killed) {
            console.log('OpenCode is already running.');
            return resolve(true);
        }

        console.log('Spawning OpenCode Web process...');
        
        // Load env variables
        const envPath = process.env.NODE_ENV === 'production' 
            ? '/etc/opencode/opencode.env' 
            : path.join(__dirname, '..', '..', '.env');
        
        let customEnv = {};
        if (fs.existsSync(envPath)) {
            const envData = fs.readFileSync(envPath, 'utf8');
            envData.split('\n').forEach(line => {
                const parts = line.split('=');
                if (parts.length === 2) {
                    customEnv[parts[0].trim()] = parts[1].trim();
                }
            });
        }

        // We run `opencode web`
        const npxCmd = process.platform === 'win32' ? 'npx.cmd' : 'npx';
        const args = ['opencode-ai', 'web', '--port', opencodePort.toString()];
        
        // When installed globally on a VPS, we can just run `opencode-ai web`. 
        // We'll use npx as fallback to run the local module in dev
        
        opencodeProcess = spawn(npxCmd, args, {
            env: { ...process.env, ...customEnv },
            stdio: 'pipe'
        });

        opencodeProcess.stdout.on('data', (data) => {
            console.log(`[OpenCode]: ${data}`);
            // Wait for it to be ready
            if (data.toString().includes(`Running OpenCode Web`)) {
                 resolve(true);
            }
        });

        opencodeProcess.stderr.on('data', (data) => {
            console.error(`[OpenCode ERROR]: ${data}`);
        });

        opencodeProcess.on('close', (code) => {
            console.log(`OpenCode process exited with code ${code}`);
            opencodeProcess = null;
        });

        opencodeProcess.on('error', (err) => {
            console.error('Failed to start OpenCode process:', err);
            reject(err);
        });
        
        // Timeout to resolve just in case
        setTimeout(() => resolve(true), 5000);
    });
}

function stopOpenCode() {
    return new Promise((resolve) => {
        if (!opencodeProcess || opencodeProcess.killed) {
            return resolve(true);
        }
        
        console.log('Stopping OpenCode Web process...');
        opencodeProcess.kill('SIGTERM');
        
        opencodeProcess.on('exit', () => {
            console.log('OpenCode Web process stopped.');
            resolve(true);
        });
        
        setTimeout(() => {
            if (opencodeProcess && !opencodeProcess.killed) {
                 opencodeProcess.kill('SIGKILL');
            }
            resolve(true);
        }, 3000);
    });
}

function getOpenCodeStatus() {
    return Promise.resolve({
        running: opencodeProcess !== null && !opencodeProcess.killed,
        pid: opencodeProcess ? opencodeProcess.pid : null,
        port: opencodePort
    });
}

module.exports = {
    spawnOpenCode,
    stopOpenCode,
    getOpenCodeStatus
};