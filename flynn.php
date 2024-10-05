<?php

require 'vendor/autoload.php';

use Ratchet\Client\WebSocket;
use Ratchet\Client\Connector;
use React\EventLoop\Loop;
use GuzzleHttp\Client;

$socket = null;
$pingInterval = null;
$countdownInterval = null;
$potentialPoints = 0;
$countdown = "Calculating...";
$pointsTotal = 0;
$pointsToday = 0;

function getLocalStorage() {
    try {
        $data = file_get_contents('localStorage.json');
        return json_decode($data, true);
    } catch (Exception $error) {
        return [];
    }
}

function setLocalStorage($data) {
    $currentData = getLocalStorage();
    $newData = array_merge($currentData, $data);
    file_put_contents('localStorage.json', json_encode($newData));
}

function connectWebSocket($userId) {
    global $socket;
    if ($socket) return;
    $version = "v0.2";
    $url = "wss://secure.ws.teneo.pro";
    $wsUrl = "{$url}/websocket?userId=" . urlencode($userId) . "&version=" . urlencode($version);

    $loop = Loop::get();
    $reactConnector = new Connector($loop);
    $reactConnector($wsUrl)->then(function(WebSocket $conn) use ($loop) {
        global $socket;
        $socket = $conn;

        $connectionTime = date('c');
        setLocalStorage(['lastUpdated' => $connectionTime]);
        echo "WebSocket connected at " . $connectionTime . "\n";
        startPinging($loop);
        startCountdownAndPoints($loop);

        $conn->on('message', function($msg) {
            $data = json_decode($msg, true);
            echo "Received message from WebSocket: " . print_r($data, true) . "\n";
            if (isset($data['pointsTotal']) && isset($data['pointsToday'])) {
                $lastUpdated = date('c');
                setLocalStorage([
                    'lastUpdated' => $lastUpdated,
                    'pointsTotal' => $data['pointsTotal'],
                    'pointsToday' => $data['pointsToday'],
                ]);
                global $pointsTotal, $pointsToday;
                $pointsTotal = $data['pointsTotal'];
                $pointsToday = $data['pointsToday'];
            }
        });

        $conn->on('close', function() {
            global $socket;
            $socket = null;
            echo "WebSocket disconnected\n";
            stopPinging();
        });
    }, function(Exception $e) {
        echo "WebSocket error: " . $e->getMessage() . "\n";
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

function startPinging($loop) {
    global $pingInterval, $socket;
    stopPinging();
    $pingInterval = $loop->addPeriodicTimer(10, function() use ($socket) {
        if ($socket) {
            $socket->send(json_encode(['type' => 'PING']));
            setLocalStorage(['lastPingDate' => date('c')]);
        }
    });
}

function stopPinging() {
    global $pingInterval;
    if ($pingInterval) {
        Loop::get()->cancelTimer($pingInterval);
        $pingInterval = null;
    }
}

function startCountdownAndPoints($loop) {
    global $countdownInterval;
    if ($countdownInterval) {
        $loop->cancelTimer($countdownInterval);
    }
    updateCountdownAndPoints();
    $countdownInterval = $loop->addPeriodicTimer(1, 'updateCountdownAndPoints');
}

function updateCountdownAndPoints() {
    global $countdown, $potentialPoints;
    $localStorage = getLocalStorage();
    $lastUpdated = $localStorage['lastUpdated'] ?? null;
    if ($lastUpdated) {
        $nextHeartbeat = new DateTime($lastUpdated);
        $nextHeartbeat->modify('+15 minutes');
        $now = new DateTime();
        $diff = $nextHeartbeat->getTimestamp() - $now->getTimestamp();

        if ($diff > 0) {
            $minutes = floor($diff / 60);
            $seconds = $diff % 60;
            $countdown = "{$minutes}m {$seconds}s";

            $maxPoints = 25;
            $timeElapsed = $now->getTimestamp() - (new DateTime($lastUpdated))->getTimestamp();
            $timeElapsedMinutes = $timeElapsed / 60;
            $newPoints = min($maxPoints, ($timeElapsedMinutes / 15) * $maxPoints);
            $newPoints = round($newPoints, 2);

            if (mt_rand() / mt_getrandmax() < 0.1) {
                $bonus = mt_rand() / mt_getrandmax() * 2;
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
}

function getUserId() {
    $loginUrl = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password";
    $authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    $apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    echo "Email: ";
    $email = trim(fgets(STDIN));
    echo "Password: ";
    $password = trim(fgets(STDIN));

    $client = new Client();
    try {
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
        $userId = $data['user']['id'];
        echo "User ID: " . $userId . "\n";

        $profileUrl = "https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.{$userId}";
        $profileResponse = $client->get($profileUrl, [
            'headers' => [
                'Authorization' => $authorization,
                'apikey' => $apikey
            ]
        ]);

        $profileData = json_decode($profileResponse->getBody(), true);
        echo "Profile Data: " . print_r($profileData, true) . "\n";
        setLocalStorage(['userId' => $userId]);
        startCountdownAndPoints(Loop::get());
        connectWebSocket($userId);
    } catch (Exception $error) {
        echo "Error: " . $error->getMessage() . "\n";
    }
}

function main() {
    $localStorageData = getLocalStorage();
    $userId = $localStorageData['userId'] ?? null;

    if (!$userId) {
        echo "Please enter your user ID: ";
        $userId = trim(fgets(STDIN));
        setLocalStorage(['userId' => $userId]);
        startCountdownAndPoints(Loop::get());
        connectWebSocket($userId);
    } else {
        echo "Menu:\n1. Logout\n2. Start Running Node\n3. Get User ID\nChoose an option: ";
        $option = trim(fgets(STDIN));
        switch ($option) {
            case '1':
                setLocalStorage([]);
                echo "Logged out successfully.\n";
                exit(0);
                break;
            case '2':
                startCountdownAndPoints(Loop::get());
                connectWebSocket($userId);
                break;
            case '3':
                getUserId();
                break;
            default:
                echo "Invalid option. Exiting...\n";
                exit(0);
        }
    }
}

main();
Loop::get()->run();

