<?php

require 'vendor/autoload.php'; // Assuming you are using Composer for dependencies
use React\Socket\Connector;
use React\EventLoop\Factory;
use React\Filesystem\Filesystem;
use React\Filesystem\FilesystemInterface;
use React\Filesystem\Node\FileInterface;
use React\Filesystem\Node\DirectoryInterface;
use React\Promise\Promise;

$cl = [
    'gr' => "\033[32m",
    'gb' => "\033[4m",
    'br' => "\033[34m",
    'st' => "\033[9m",
    'yl' => "\033[33m",
    'rt' => "\033[0m"
];

$socket = null;
$pingInterval = null;
$countdownInterval = null;
$potentialPoints = 0;
$countdown = "Calculating...";
$pointsTotal = 0;
$pointsToday = 0;
$reconnectAttempts = 0;
$maxReconnectAttempts = 5;
$maxReconnectInterval = 5 * 60; // 5 minutes in seconds
$CoderMarkPrinted = false;

function CoderMark() {
    global $CoderMarkPrinted, $cl;
    if (!$CoderMarkPrinted) {
        echo "
╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃{$cl['gr']}
┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮{$cl['br']}
┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯{$cl['rt']}
╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
\n{$cl['gb']}Teneo Node Cli {$cl['gr']}v1.1.0 {$cl['rt']}{$cl['gb']}{$cl['br']}dev_build{$cl['rt']}
        ";
        $CoderMarkPrinted = true;
    }
}

function readFileAsync($filename) {
    return new Promise(function ($resolve, $reject) use ($filename) {
        if (file_exists($filename)) {
            $data = file_get_contents($filename);
            $resolve(json_decode($data, true));
        } else {
            $resolve([]);
        }
    });
}

function writeFileAsync($filename, $data) {
    return new Promise(function ($resolve) use ($filename, $data) {
        file_put_contents($filename, json_encode($data));
        $resolve();
    });
}

function getLocalStorage() {
    return readFileAsync('localStorage.json');
}

function setLocalStorage($data) {
    return getLocalStorage()->then(function ($currentData) use ($data) {
        $newData = array_merge($currentData, $data);
        return writeFileAsync('localStorage.json', $newData);
    });
}

function getUserIdFromFile() {
    return readFileAsync('UserId.json')->then(function ($data) {
        return $data['userId'] ?? null;
    });
}

function setUserIdToFile($userId) {
    return writeFileAsync('UserId.json', ['userId' => $userId]);
}

function getAccountData() {
    return readFileAsync('DataAccount.json');
}

function setAccountData($email, $password, $access_token, $refresh_token, $personalCode) {
    $accountData = [
        'email' => $email,
        'password' => $password,
        'access_token' => $access_token,
        'refresh_token' => $refresh_token,
        'personalCode' => $personalCode
    ];
    return writeFileAsync('DataAccount.json', $accountData);
}

function getReconnectDelay($attempt) {
    global $maxReconnectInterval;
    $baseDelay = 5; // 5 seconds
    $additionalDelay = $attempt * 5; // Additional 5 seconds for each attempt
    return min($baseDelay + $additionalDelay, $maxReconnectInterval);
}

function connectWebSocket($userId) {
    global $socket, $reconnectAttempts, $countdown, $pointsTotal, $pointsToday;

    if ($socket) return;

    $version = "v0.2";
    $url = "wss://secure.ws.teneo.pro";
    $wsUrl = "{$url}/websocket?userId=" . urlencode($userId) . "&version=" . urlencode($version);
    $socket = new WebSocket($wsUrl);

    $socket->on('open', function () use (&$reconnectAttempts) {
        $reconnectAttempts = 0;
        $connectionTime = (new DateTime())->format(DateTime::ISO8601);
        setLocalStorage(['lastUpdated' => $connectionTime]);
        echo "WebSocket connected at " . $connectionTime . "\n";
        startPinging();
        startCountdownAndPoints();
    });

    $socket->on('message', function ($data) use (&$pointsTotal, &$pointsToday) {
        $data = json_decode($data, true);
        echo "Received message from WebSocket: " . json_encode($data) . "\n";
        if (isset($data['pointsTotal']) && isset($data['pointsToday'])) {
            $lastUpdated = (new DateTime())->format(DateTime::ISO8601);
            setLocalStorage([
                'lastUpdated' => $lastUpdated,
                'pointsTotal' => $data['pointsTotal'],
                'pointsToday' => $data['pointsToday'],
            ]);
            $pointsTotal = $data['pointsTotal'];
            $pointsToday = $data['pointsToday'];
        }
    });

    $socket->on('close', function ($event) {
        global $socket, $reconnectAttempts, $maxReconnectInterval;
        $socket = null;
        echo "WebSocket disconnected\n";
        stopPinging();
        if (!$event->wasClean) {
            $reconnectAttempts++;
            $delay = getReconnectDelay($reconnectAttempts);
            if ($delay < $maxReconnectInterval) {
                sleep($delay);
                reconnectWebSocket();
            } else {
                echo "Max reconnect interval reached. Giving up.\n";
            }
        }
    });

    $socket->on('error', function ($error) {
        echo "WebSocket error: " . $error . "\n";
    });
}

function disconnectWebSocket() {
    global $socket;
    if ($socket) {
        $socket->close();
        $socket = null;
        stopPinging();
    }
}

function startPinging() {
    global $pingInterval, $socket;
    stopPinging();
    $pingInterval = setInterval(function () use ($socket) {
        if ($socket && $socket->readyState === WebSocket::OPEN) {
            $socket->send(json_encode(['type' => 'PING']));
            setLocalStorage(['lastPingDate' => (new DateTime())->format(DateTime::ISO8601)]);
        }
    }, 10000);
}

function stopPinging() {
    global $pingInterval;
    if ($pingInterval) {
        clearInterval($pingInterval);
        $pingInterval = null;
    }
}

function startCountdownAndPoints() {
    global $countdownInterval;
    clearInterval($countdownInterval);
    updateCountdownAndPoints();
    $countdownInterval = setInterval('updateCountdownAndPoints', 1000);
}

function updateCountdownAndPoints() {
    global $countdown, $potentialPoints;
    getLocalStorage()->then(function ($localStorage) use (&$countdown, &$potentialPoints) {
        if (isset($localStorage['lastUpdated'])) {
            $nextHeartbeat = new DateTime($localStorage['lastUpdated']);
            $nextHeartbeat->modify('+15 minutes');
            $now = new DateTime();
            $diff = $nextHeartbeat->getTimestamp() - $now->getTimestamp();

            if ($diff > 0) {
                $minutes = floor($diff / 60);
                $seconds = $diff % 60;
                $countdown = "{$minutes}m {$seconds}s";

                $maxPoints = 25;
                $timeElapsed = $now->getTimestamp() - (new DateTime($localStorage['lastUpdated']))->getTimestamp();
                $timeElapsedMinutes = $timeElapsed / 60;
                $newPoints = min($maxPoints, ($timeElapsedMinutes / 15) * $maxPoints);
                $newPoints = round($newPoints, 2);

                if (mt_rand(0, 9) < 1) {
                    $bonus = mt_rand(0, 2);
                    $newPoints = min($maxPoints, $newPoints + $bonus);
                    $newPoints = round($newPoints, 2);
                }

                $potentialPoints = $newPoints;
            } else {
                $countdown = "Calculating...";
                $potentialPoints = 25;
            }
        } else {
            $countdown = "Calculating...";
            $potentialPoints = 0;
        }
        setLocalStorage(['potentialPoints' => $potentialPoints, 'countdown' => $countdown]);
    });
}

function getUserId() {
    global $cl;
    $loginUrl = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password";
    $authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    $apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    getAccountData()->then(function ($accountData) use ($loginUrl, $authorization, $apikey, $cl) {
        $email = $accountData['email'] ?? readline("\nEmail: ");
        $password = $accountData['password'] ?? readline($cl['rt'] . "Password: " . $cl['st'] . $cl['br'] . "");

        $client = new \GuzzleHttp\Client();
        $response = $client->post($loginUrl, [
            'json' => [
                'email' => $email,
                'password' => $password
            ],
            'headers' => [
                'Authorization' => $authorization,
                'apikey' => $apikey
            ]
        ]);

        $data = json_decode($response->getBody(), true);
        $access_token = $data['access_token'];
        $refresh_token = $data['refresh_token'];
        echo 'Access_Token: ' . $access_token . "\n";
        echo 'Refresh_Token: ' . $refresh_token . "\n";

        $AuthUserUrl = "https://node-community-api.teneo.pro/auth/v1/user";
        $AuthResponse = $client->get($AuthUserUrl, [
            'headers' => [
                'Authorization' => "Bearer {$access_token}",
                'apikey' => $apikey
            ]
        ]);

        $userId = json_decode($AuthResponse->getBody(), true)['id'];
        echo 'User ID: ' . $userId . "\n";

        $profileUrl = "https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq.{$userId}";
        $profileResponse = $client->get($profileUrl, [
            'headers' => [
                'Authorization' => "Bearer {$access_token}",
                'apikey' => $apikey
            ]
        ]);
        $personalCode = json_decode($profileResponse->getBody(), true)[0]['personal_code'] ?? null;
        echo "Personal Code: " . $cl['rt'] . $personalCode . "\n";
        setUserIdToFile($userId);
        setAccountData($email, $password, $access_token, $refresh_token, $personalCode);
        startCountdownAndPoints();
        connectWebSocket($userId);
        echo $cl['gr'] . "Data has been saved in the DataAccount.json file...\n" . $cl['rt'];
        CoderMark();
    });
}

function reconnectWebSocket() {
    getUserIdFromFile()->then(function ($userId) {
        if ($userId) {
            connectWebSocket($userId);
        }
    });
}

function autoLogin() {
    getAccountData()->then(function ($accountData) {
        if (!empty($accountData['email']) && !empty($accountData['password'])) {
            getUserId();
            echo $cl['yl'] . "\nAutomatic Login has been Successfully Executed..\n" . $cl['rt'];
        }
    });
}

function main() {
    getLocalStorage()->then(function ($localStorageData) {
        getUserIdFromFile()->then(function ($userId) {
            global $cl;
            if (!$userId) {
                $option = readline("\nUser ID not found. Would you like to:\n" . $cl['gr'] . "\n1. Login to your account\n2. Enter User ID manually\n" . $cl['rt'] . "\nChoose an option: ");
                switch ($option) {
                    case '1':
                        getUserId();
                        break;
                    case '2':
                        $inputUserId = readline('Please enter your user ID: ');
                        setUserIdToFile($inputUserId);
                        startCountdownAndPoints();
                        connectWebSocket($inputUserId);
                        break;
                    default:
                        echo 'Invalid option. Exiting...' . "\n";
                        exit(0);
                }
            } else {
                $option = readline("\nMenu:\n" . $cl['gr'] . "\n1. Logout\n2. Start Running Node\n" . $cl['rt'] . "\nChoose an option: ");
                switch ($option) {
                    case '1':
                        unlink('UserId.json');
                        unlink('localStorage.json');
                        unlink('DataAccount.json');
                        echo $cl['yl'] . "\nLogged out successfully." . "\n";
                        exit(0);
                    case '2':
                        echo "\n";
                        CoderMark();
                        echo $cl['gr'] . "Initiates a connection to the node...\n" . $cl['rt'];
                        startCountdownAndPoints();
                        connectWebSocket($userId);
                        break;
                    default:
                        echo $cl['yl'] . "Invalid option. Exiting..." . "\n";
                        exit(0);
                }
            }
        });
    });
}

main();
setInterval('autoLogin', 1800);

