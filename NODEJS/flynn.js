const WebSocket = require('ws');
const { promisify } = require('util');
const fs = require('fs');
const readline = require('readline');
const axios = require('axios');

const cl = { gr: '\x1b[32m', gb: '\x1b[4m', br: '\x1b[34m', st: '\x1b[9m', yl: '\x1b[33m', rt: '\x1b[0m' };

let socket = null;
let pingInterval;
let countdownInterval;
let potentialPoints = 0;
let countdown = "Calculating...";
let pointsTotal = 0;
let pointsToday = 0;
let reconnectAttempts = 0;
const maxReconnectAttempts = 5;
const maxReconnectInterval = 5 * 60 * 1000; // 5 minutes in milliseconds
let CoderMarkPrinted = false;

function CoderMark() {
    if (!CoderMarkPrinted) {
        console.log(`
╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃${cl.gr}
┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮${cl.br}
┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯${cl.rt}
╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
\n${cl.gb}Teneo Node Cli ${cl.gr}v1.1.0 ${cl.rt}${cl.gb}${cl.br}dev_build${cl.rt}
        `);
        CoderMarkPrinted = true;
    }
}

const readFileAsync = promisify(fs.readFile);
const writeFileAsync = promisify(fs.writeFile);

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

async function getLocalStorage() {
    try {
        const data = await readFileAsync('localStorage.json', 'utf8');
        return JSON.parse(data);
    } catch (error) {
        return {};
    }
}

async function setLocalStorage(data) {
    const currentData = await getLocalStorage();
    const newData = {
        ...currentData,
        ...data
    };
    await writeFileAsync('localStorage.json', JSON.stringify(newData));
}

async function getUserIdFromFile() {
    try {
        const data = await readFileAsync('UserId.json', 'utf8');
        return JSON.parse(data).userId;
    } catch (error) {
        return null;
    }
}

async function setUserIdToFile(userId) {
    await writeFileAsync('UserId.json', JSON.stringify({
        userId
    }));
}

async function getAccountData() {
    try {
        const data = await readFileAsync('DataAccount.json', 'utf8');
        return JSON.parse(data);
    } catch (error) {
        return {};
    }
}

async function setAccountData(email, password, access_token, refresh_token, personalCode) {
    const accountData = {
        email,
        password,
        access_token,
        refresh_token,
        personalCode
    };
    await writeFileAsync('DataAccount.json', JSON.stringify(accountData));
}

function getReconnectDelay(attempt) {
    const baseDelay = 5000; // 5 seconds
    const additionalDelay = attempt * 5000; // Additional 5 seconds for each attempt
    return Math.min(baseDelay + additionalDelay, maxReconnectInterval);
}

async function connectWebSocket(userId) {
    if (socket) return;
    const version = "v0.2";
    const url = "wss://secure.ws.teneo.pro";
    const wsUrl = `${url}/websocket?userId=${encodeURIComponent(userId)}&version=${encodeURIComponent(version)}`;
    socket = new WebSocket(wsUrl);

    socket.onopen = async () => {
        reconnectAttempts = 0;
        const connectionTime = new Date().toISOString();
        await setLocalStorage({
            lastUpdated: connectionTime
        });
        console.log("WebSocket connected at", connectionTime);
        startPinging();
        startCountdownAndPoints();
    };

    socket.onmessage = async (event) => {
        const data = JSON.parse(event.data);
        console.log("Received message from WebSocket:", data);
        if (data.pointsTotal !== undefined && data.pointsToday !== undefined) {
            const lastUpdated = new Date().toISOString();
            await setLocalStorage({
                lastUpdated: lastUpdated,
                pointsTotal: data.pointsTotal,
                pointsToday: data.pointsToday,
            });
            pointsTotal = data.pointsTotal;
            pointsToday = data.pointsToday;
        }
    };

    socket.onclose = (event) => {
        socket = null;
        console.log("WebSocket disconnected");
        stopPinging();
        if (!event.wasClean) {
            reconnectAttempts++;
            const delay = getReconnectDelay(reconnectAttempts);
            if (delay < maxReconnectInterval) {
                setTimeout(() => {
                    reconnectWebSocket();
                }, delay);
            } else {
                console.log("Max reconnect interval reached. Giving up.");
            }
        }
    };

    socket.onerror = (error) => {
        console.error("WebSocket error:", error);
    };
}

function disconnectWebSocket() {
    if (socket) {
        socket.close();
        socket = null;
        stopPinging();
    }
}

function startPinging() {
    stopPinging();
    pingInterval = setInterval(async () => {
        if (socket && socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({
                type: "PING"
            }));
            await setLocalStorage({
                lastPingDate: new Date().toISOString()
            });
        }
    }, 10000);
}

function stopPinging() {
    if (pingInterval) {
        clearInterval(pingInterval);
        pingInterval = null;
    }
}

process.on('SIGINT', () => {
    console.log('Received SIGINT. Stopping pinging...');
    stopPinging();
    disconnectWebSocket();
    process.exit(0);
});

function startCountdownAndPoints() {
    clearInterval(countdownInterval);
    updateCountdownAndPoints();
    countdownInterval = setInterval(updateCountdownAndPoints, 1000);
}

async function updateCountdownAndPoints() {
    const {
        lastUpdated
    } = await getLocalStorage();
    if (lastUpdated) {
        const nextHeartbeat = new Date(lastUpdated);
        nextHeartbeat.setMinutes(nextHeartbeat.getMinutes() + 15);
        const now = new Date();
        const diff = nextHeartbeat.getTime() - now.getTime();

        if (diff > 0) {
            const minutes = Math.floor(diff / 60000);
            const seconds = Math.floor((diff % 60000) / 1000);
            countdown = `${minutes}m ${seconds}s`;

            const maxPoints = 25;
            const timeElapsed = now.getTime() - new Date(lastUpdated).getTime();
            const timeElapsedMinutes = timeElapsed / (60 * 1000);
            let newPoints = Math.min(maxPoints, (timeElapsedMinutes / 15) * maxPoints);
            newPoints = parseFloat(newPoints.toFixed(2));

            if (Math.random() < 0.1) {
                const bonus = Math.random() * 2;
                newPoints = Math.min(maxPoints, newPoints + bonus);
                newPoints = parseFloat(newPoints.toFixed(2));
            }

            potentialPoints = newPoints;
        } else {
            countdown = "Calculating...";
            potentialPoints = 25;
        }
    } else {
        countdown = "Calculating...";
        potentialPoints = 0;
    }
    await setLocalStorage({
        potentialPoints,
        countdown
    });
}

async function getUserId() {
    const loginUrl = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password";
    const authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    const apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    const accountData = await getAccountData();
    const email = accountData.email || await new Promise(resolve => rl.question(`\nEmail: ` + cl.gr, resolve));
    const password = accountData.password || await new Promise(resolve => rl.question(cl.rt + `Password: ` + cl.st + cl.br + ``, resolve));

    try {
        const response = await axios.post(loginUrl, {
            email: email,
            password: password
        }, {
            headers: {
                'Authorization': authorization,
                'apikey': apikey
            }
        });

        const access_token = response.data.access_token;
        const refresh_token = response.data.refresh_token;
        console.log('Access_Token:', access_token);
        console.log('Refresh_Token:', refresh_token);

        const AuthUserUrl = "https://node-community-api.teneo.pro/auth/v1/user";
        const AuthResponse = await axios.get(AuthUserUrl, {
            headers: {
                'Authorization': `Bearer ${access_token}`,
                'apikey': apikey
            }
        });

        const userId = AuthResponse.data.id;
        console.log('User ID:', userId);

        const profileUrl = `https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq.${userId}`;
        const profileResponse = await axios.get(profileUrl, {
            headers: {
                'Authorization': `Bearer ${access_token}`,
                'apikey': apikey
            }
        });
        const personalCode = profileResponse.data[0]?.personal_code;
        console.log(`Personal Code:` + cl.rt, personalCode);
        await setUserIdToFile(userId);
        await setAccountData(email, password, access_token, refresh_token, personalCode);
        await startCountdownAndPoints();
        await connectWebSocket(userId);
        console.clear();
        console.log(cl.gr + `Data has been saved in the DataAccount.json file...\n` + cl.rt);
        CoderMark();
    } catch (error) {
        console.error('Error:', error.response ? error.response.data : error.message);
    } finally {
        rl.close();
    }
}

async function reconnectWebSocket() {
    const userId = await getUserIdFromFile();
    if (userId) {
        await connectWebSocket(userId);
    }
}

async function autoLogin() {
    const accountData = await getAccountData();
    if (accountData.email && accountData.password) {
        await getUserId();
        console.log(cl.yl + `\nAutomatic Login has been Successfully Executed..\n` + cl.rt);
    }
}

async function main() {
    const localStorageData = await getLocalStorage();
    let userId = await getUserIdFromFile();

    if (!userId) {
        rl.question(`\nUser ID not found. Would you like to:\n` + cl.gr + `\n1. Login to your account\n2. Enter User ID manually\n` + cl.rt + `\nChoose an option: `, async (option) => {
            switch (option) {
                case '1':
                    await getUserId();
                    break;
                case '2':
                    rl.question('Please enter your user ID: ', async (inputUserId) => {
                        userId = inputUserId;
                        await setUserIdToFile(userId);
                        await startCountdownAndPoints();
                        await connectWebSocket(userId);
                        rl.close();
                    });
                    break;
                default:
                    console.log('Invalid option. Exiting...');
                    process.exit(0);
            }
        });
    } else {
        rl.question(`\nMenu:\n` + cl.gr + `\n1. Logout\n2. Start Running Node\n` + cl.rt + `\nChoose an option: `, async (option) => {
            switch (option) {
                case '1':
                    fs.unlink('UserId.json', (err) => {
                        if (err) throw err;
                    });
                    fs.unlink('localStorage.json', (err) => {
                        if (err) throw err;
                    });
                    fs.unlink('DataAccount.json', (err) => {
                        if (err) throw err;
                    });
                    console.log(cl.yl + `\nLogged out successfully.`);
                    process.exit(0);
                    break;
                case '2':
                    console.clear();
                    CoderMark();
                    console.log(cl.gr + `Initiates a connection to the node...\n` + cl.rt);
                    await startCountdownAndPoints();
                    await connectWebSocket(userId);
                    break;
                default:
                    console.log(cl.yl + `Invalid option. Exiting...`);
                    process.exit(0);
            }
        });
    }
}

main();
setInterval(autoLogin, 1800000);

