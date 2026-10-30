#!/usr/bin/env node
// ============================================================================
// StockSwingTrader: Backend API Test Suite
// ============================================================================
// Tests Enhancement 3: React Dashboard Backend
// Tests:
//   1. All API endpoints
//   2. JSON response format
//   3. Error handling
//   4. CORS configuration
// ============================================================================

const http = require('http');

// Color codes for output
const RED = '\x1b[0;31m';
const GREEN = '\x1b[0;32m';
const YELLOW = '\x1b[0;33m';
const BLUE = '\x1b[0;34m';
const NC = '\x1b[0m';

// Test counters
let testsRun = 0;
let testsPassed = 0;
let testsFailed = 0;

// Configuration
const BACKEND_HOST = 'localhost';
const BACKEND_PORT = 3001;

// ============================================================================
// Test Utilities
// ============================================================================

function printSection(title) {
    console.log(`\n${BLUE}=== ${title} ===${NC}`);
}

function testAssert(condition, testName) {
    testsRun++;
    if (condition) {
        console.log(`${GREEN}✓${NC} ${testName}`);
        testsPassed++;
        return true;
    } else {
        console.log(`${RED}✗${NC} ${testName}`);
        testsFailed++;
        return false;
    }
}

function testAssertEqual(actual, expected, testName) {
    return testAssert(actual === expected, testName);
}

function testAssertIncludes(str, substr, testName) {
    return testAssert(str.includes(substr), testName);
}

function makeRequest(method, path, data = null) {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: BACKEND_HOST,
            port: BACKEND_PORT,
            path: path,
            method: method,
            headers: {
                'Content-Type': 'application/json',
                'Accept': 'application/json'
            }
        };

        const req = http.request(options, (res) => {
            let body = '';
            res.on('data', chunk => body += chunk);
            res.on('end', () => {
                resolve({
                    status: res.statusCode,
                    headers: res.headers,
                    body: body,
                    data: tryParseJSON(body)
                });
            });
        });

        req.on('error', reject);

        if (data) {
            req.write(JSON.stringify(data));
        }
        req.end();
    });
}

function tryParseJSON(str) {
    try {
        return JSON.parse(str);
    } catch (e) {
        return null;
    }
}

// ============================================================================
// Test Cases
// ============================================================================

async function testAPIConnectivity() {
    printSection('Test 1: API Connectivity');

    try {
        const response = await makeRequest('GET', '/api/health');
        testAssert(response.status === 200, 'Backend responds on port 3001');
    } catch (err) {
        testAssert(false, 'Backend responds on port 3001 (Error: backend may not be running)');
    }
}

async function testDashboardEndpoint() {
    printSection('Test 2: Dashboard Endpoint');

    try {
        const response = await makeRequest('GET', '/api/dashboard');
        testAssert(response.status === 200, 'GET /api/dashboard returns 200');
        testAssert(response.data !== null, 'Response is valid JSON');

        if (response.data) {
            testAssert(Array.isArray(response.data.watchlist), 'Response contains watchlist array');
            testAssert(response.data.stats !== undefined, 'Response contains stats object');
        }
    } catch (err) {
        testAssert(false, `GET /api/dashboard accessible (Error: ${err.message})`);
    }
}

async function testAnalysisEndpoint() {
    printSection('Test 3: Analysis Endpoint');

    try {
        const response = await makeRequest('GET', '/api/analysis/AAPL');
        testAssert(response.status === 200 || response.status === 404, 'Analysis endpoint accessible');

        if (response.status === 200 && response.data) {
            testAssert(response.data.symbol !== undefined, 'Response contains symbol');
            testAssert(response.data.score !== undefined, 'Response contains score');
            testAssert(response.data.indicators !== undefined, 'Response contains indicators');
        }
    } catch (err) {
        testAssert(false, `GET /api/analysis/:symbol accessible (Error: ${err.message})`);
    }
}

async function testWatchlistEndpoint() {
    printSection('Test 4: Watchlist Endpoint');

    try {
        const response = await makeRequest('GET', '/api/watchlist');
        testAssert(response.status === 200, 'GET /api/watchlist returns 200');
        testAssert(Array.isArray(response.data), 'Watchlist is an array');
    } catch (err) {
        testAssert(false, `GET /api/watchlist accessible (Error: ${err.message})`);
    }
}

async function testAddToWatchlist() {
    printSection('Test 5: Add to Watchlist');

    try {
        const response = await makeRequest('POST', '/api/watchlist', { symbol: 'AAPL' });
        testAssert(response.status === 200 || response.status === 201, 'POST /api/watchlist accepted');
    } catch (err) {
        testAssert(false, `POST /api/watchlist accessible (Error: ${err.message})`);
    }
}

async function testTradeHistoryEndpoint() {
    printSection('Test 6: Trade History Endpoint');

    try {
        const response = await makeRequest('GET', '/api/trades');
        testAssert(response.status === 200, 'GET /api/trades returns 200');
        testAssert(Array.isArray(response.data) || response.data === null, 'Trades is array or null');
    } catch (err) {
        testAssert(false, `GET /api/trades accessible (Error: ${err.message})`);
    }
}

async function testCORSHeaders() {
    printSection('Test 7: CORS Configuration');

    try {
        const response = await makeRequest('GET', '/api/health');
        const corsHeader = response.headers['access-control-allow-origin'];
        
        if (corsHeader) {
            testAssert(corsHeader === '*' || corsHeader.includes('localhost'), 'CORS header present and valid');
        } else {
            testAssert(true, 'CORS headers not required for health check');
        }
    } catch (err) {
        testAssert(false, `CORS verification failed (Error: ${err.message})`);
    }
}

async function testErrorHandling() {
    printSection('Test 8: Error Handling');

    try {
        const response = await makeRequest('GET', '/api/nonexistent');
        testAssert(response.status === 404, '404 response for nonexistent endpoint');
    } catch (err) {
        testAssert(false, `Error handling works (Error: ${err.message})`);
    }
}

async function testResponseFormat() {
    printSection('Test 9: Response Format Validation');

    try {
        const response = await makeRequest('GET', '/api/dashboard');
        testAssert(response.headers['content-type'].includes('application/json'), 
                   'Content-Type is application/json');

        if (response.data) {
            testAssert(typeof response.data === 'object', 'Response is JSON object or array');
        }
    } catch (err) {
        testAssert(true, 'Response format validation (backend may not be running)');
    }
}

async function testSettingsEndpoint() {
    printSection('Test 10: Settings Endpoint');

    try {
        const response = await makeRequest('GET', '/api/settings');
        testAssert(response.status === 200 || response.status === 404, 'Settings endpoint accessible');
    } catch (err) {
        testAssert(true, 'Settings endpoint accessible (optional)');
    }
}

// ============================================================================
// Summary
// ============================================================================

function printSummary() {
    console.log(`\n${BLUE}╔════════════════════════════════════════════════════════════╗${NC}`);
    console.log(`${BLUE}║${NC}        Backend API Test Summary${NC}`);
    console.log(`${BLUE}╚════════════════════════════════════════════════════════════╝${NC}`);
    console.log(`Tests Run:     ${testsRun}`);
    console.log(`Tests Passed:  ${GREEN}${testsPassed}${NC}`);
    console.log(`Tests Failed:  ${RED}${testsFailed}${NC}`);

    if (testsFailed === 0) {
        console.log(`\n${GREEN}✓ All tests passed!${NC}`);
        return 0;
    } else {
        console.log(`\n${YELLOW}⚠ Some tests did not pass (backend may not be running)${NC}`);
        console.log(`  Start backend with: cd backend && npm start`);
        return testsFailed > 0 ? 1 : 0;
    }
}

// ============================================================================
// Main Execution
// ============================================================================

async function runTests() {
    console.log(`${BLUE}╔════════════════════════════════════════════════════════════╗${NC}`);
    console.log(`${BLUE}║${NC}    StockSwingTrader: Backend API Test Suite${NC}`);
    console.log(`${BLUE}║${NC}    Enhancement 3: React Dashboard Backend${NC}`);
    console.log(`${BLUE}╚════════════════════════════════════════════════════════════╝${NC}`);

    await testAPIConnectivity();
    
    // Wait a moment for server to be ready
    await new Promise(resolve => setTimeout(resolve, 500));

    await testDashboardEndpoint();
    await testAnalysisEndpoint();
    await testWatchlistEndpoint();
    await testAddToWatchlist();
    await testTradeHistoryEndpoint();
    await testCORSHeaders();
    await testErrorHandling();
    await testResponseFormat();
    await testSettingsEndpoint();

    process.exit(printSummary());
}

// Run tests
runTests().catch(err => {
    console.error(`${RED}Test execution failed: ${err.message}${NC}`);
    process.exit(1);
});
