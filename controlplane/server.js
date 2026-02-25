const express = require('express');
const cors = require('cors');
const path = require('path');
const fs = require('fs');
const { createProxyMiddleware } = require('http-proxy-middleware');
const { getConfig, setConfig } = require('./db/database');
const { spawnOpenCode, stopOpenCode, getOpenCodeStatus } = require('./process_manager/opencode');

// Ensure dotenv is loaded if available
require('dotenv').config({ path: path.join(__dirname, '..', '.env') });

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// API routes for the wizard
const apiRouter = express.Router();

apiRouter.get('/status', async (req, res) => {
    try {
        const status = await getConfig('status');
        res.json({ status });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

apiRouter.post('/configure', async (req, res) => {
    try {
        const payload = req.body;
        // Basic validation and saving of configuration
        // In a real scenario, this would trigger API calls to Cloudflare/GitHub
        
        await setConfig('domain', payload.domain || '');
        await setConfig('github_repo', payload.github_repo || '');
        
        // Simulating the configuration process
        await setConfig('status', 'CONFIGURING');
        
        // Simulating asynchronous work
        setTimeout(async () => {
            await setConfig('status', 'READY');
            
            // Generate /etc/opencode/setup.json
            const setupJsonPath = process.env.NODE_ENV === 'production' 
                ? '/etc/opencode/setup.json' 
                : path.join(__dirname, '..', 'dev_data', 'setup.json');
            
            try {
                fs.writeFileSync(setupJsonPath, JSON.stringify(payload, null, 2), { mode: 0o600 });
                console.log(`Saved configuration to ${setupJsonPath}`);
                
                // Start OpenCode Process
                await spawnOpenCode();
            } catch (err) {
                console.error(`Failed to write setup.json: ${err.message}`);
                await setConfig('status', 'ERROR');
            }
        }, 3000);

        res.json({ message: 'Configuration started' });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

// Restart system (to apply changes)
apiRouter.post('/restart', async (req, res) => {
    try {
        await stopOpenCode();
        await spawnOpenCode();
        res.json({ message: 'Restarted successfully' });
    } catch (err) {
        res.status(500).json({ error: err.message });
    }
});

app.use('/api', apiRouter);

// Serve the wizard frontend
app.use('/setup', express.static(path.join(__dirname, 'wizard')));

// Middleware to intercept traffic based on configuration status
app.use(async (req, res, next) => {
    // Ignore API routes and /setup path for the interception
    if (req.path.startsWith('/api') || req.path.startsWith('/setup')) {
        return next();
    }

    try {
        const status = await getConfig('status');
        
        if (status === 'UNCONFIGURED' || status === 'CONFIGURING' || status === 'ERROR') {
            return res.redirect('/setup');
        }
        
        // If READY, proxy to OpenCode web instance (default port 8080)
        if (status === 'READY') {
            // Check if OpenCode is running, if not start it
            const ocStatus = await getOpenCodeStatus();
            if (!ocStatus.running) {
                 await spawnOpenCode();
            }
            return next();
        }
    } catch (err) {
        console.error('Error checking status middleware:', err);
        return res.status(500).send('Internal Server Error');
    }
});

// Proxy to OpenCode
const opencodeProxy = createProxyMiddleware({
    target: 'http://127.0.0.1:8080', // Default opencode web port
    changeOrigin: true,
    ws: true, // proxy websockets
});

// Any route that makes it here gets proxied
app.use('/', opencodeProxy);

// Start the server
app.listen(PORT, async () => {
    console.log(`Control Plane server listening on port ${PORT}`);
    
    // Attempt to start OpenCode if READY on boot
    try {
        const status = await getConfig('status');
        if (status === 'READY') {
            console.log('System is READY. Attempting to start OpenCode...');
            await spawnOpenCode();
        }
    } catch (err) {
        console.error('Boot error:', err);
    }
});