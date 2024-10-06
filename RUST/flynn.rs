use std::fs;
use std::io::{self, BufRead, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};
use tokio::time::interval;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use serde_json::{json, Value};
use reqwest;
use futures_util::{SinkExt, StreamExt};
use rand::Rng;

struct AppState {
    socket: Option<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>>,
    ping_interval: Option<tokio::task::JoinHandle<()>>,
    countdown_interval: Option<tokio::task::JoinHandle<()>>,
    potential_points: f64,
    countdown: String,
    points_total: i64,
    points_today: i64,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let app_state = Arc::new(Mutex::new(AppState {
        socket: None,
        ping_interval: None,
        countdown_interval: None,
        potential_points: 0.0,
        countdown: "Calculating...".to_string(),
        points_total: 0,
        points_today: 0,
    }));

    let local_storage = get_local_storage().await?;
    let user_id = local_storage.get("userId").and_then(|v| v.as_str());

    if let Some(user_id) = user_id {
        println!("Menu:\n1. Logout\n2. Start Running Node");
        print!("Choose an option: ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().lock().read_line(&mut input)?;

        match input.trim() {
            "1" => {
                fs::remove_file("localStorage.json")?;
                println!("Logged out successfully.");
            },
            "2" => {
                start_countdown_and_points(Arc::clone(&app_state)).await?;
                connect_websocket(user_id.to_string(), Arc::clone(&app_state)).await?;
            },
            _ => println!("Invalid option. Exiting..."),
        }
    } else {
        println!("User ID not found. Would you like to:\n1. Login to your account\n2. Enter User ID manually");
        print!("Choose an option: ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().lock().read_line(&mut input)?;

        match input.trim() {
            "1" => get_user_id(Arc::clone(&app_state)).await?,
            "2" => {
                print!("Please enter your user ID: ");
                io::stdout().flush()?;
                let mut user_id = String::new();
                io::stdin().lock().read_line(&mut user_id)?;
                set_local_storage(json!({"userId": user_id.trim()})).await?;
                start_countdown_and_points(Arc::clone(&app_state)).await?;
                connect_websocket(user_id.trim().to_string(), Arc::clone(&app_state)).await?;
            },
            _ => println!("Invalid option. Exiting..."),
        }
    }

    Ok(())
}

async fn get_local_storage() -> Result<Value, Box<dyn std::error::Error>> {
    match fs::read_to_string("localStorage.json") {
        Ok(data) => Ok(serde_json::from_str(&data)?),
        Err(_) => Ok(json!({})),
    }
}

async fn set_local_storage(data: Value) -> Result<(), Box<dyn std::error::Error>> {
    let mut current_data = get_local_storage().await?;
    for (key, value) in data.as_object().unwrap() {
        current_data[key] = value.clone();
    }
    fs::write("localStorage.json", serde_json::to_string(&current_data)?)?;
    Ok(())
}

async fn connect_websocket(user_id: String, app_state: Arc<Mutex<AppState>>) -> Result<(), Box<dyn std::error::Error>> {
    let version = "v0.2";
    let url = "wss://secure.ws.teneo.pro";
    let ws_url = format!("{}/websocket?userId={}&version={}", url, user_id, version);

    let (ws_stream, _) = connect_async(&ws_url).await?;
    println!("WebSocket connected at {}", SystemTime::now().duration_since(SystemTime::UNIX_EPOCH)?.as_secs());

    let (mut write, mut read) = ws_stream.split();

    let mut app_state = app_state.lock().unwrap();
    app_state.socket = Some(ws_stream);
    drop(app_state);

    start_pinging(Arc::clone(&app_state)).await?;

    tokio::spawn(async move {
        while let Some(message) = read.next().await {
            if let Ok(message) = message {
                if let Ok(data) = serde_json::from_str::<Value>(&message.to_string()) {
                    println!("Received message from WebSocket: {:?}", data);
                    if let (Some(points_total), Some(points_today)) = (data["pointsTotal"].as_i64(), data["pointsToday"].as_i64()) {
                        let last_updated = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH)?.as_secs();
                        set_local_storage(json!({
                            "lastUpdated": last_updated,
                            "pointsTotal": points_total,
                            "pointsToday": points_today,
                        })).await?;
                        let mut app_state = app_state.lock().unwrap();
                        app_state.points_total = points_total;
                        app_state.points_today = points_today;
                    }
                }
            }
        }
        Ok::<(), Box<dyn std::error::Error>>(())
    });

    Ok(())
}

async fn start_pinging(app_state: Arc<Mutex<AppState>>) -> Result<(), Box<dyn std::error::Error>> {
    let mut interval = interval(Duration::from_secs(10));
    let ping_task = tokio::spawn(async move {
        loop {
            interval.tick().await;
            let mut app_state = app_state.lock().unwrap();
            if let Some(ref mut socket) = app_state.socket {
                socket.send(Message::Text(json!({"type": "PING"}).to_string())).await?;
                let last_ping_date = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH)?.as_secs();
                set_local_storage(json!({"lastPingDate": last_ping_date})).await?;
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), Box<dyn std::error::Error>>(())
    });

    let mut app_state = app_state.lock().unwrap();
    app_state.ping_interval = Some(ping_task);

    Ok(())
}

async fn start_countdown_and_points(app_state: Arc<Mutex<AppState>>) -> Result<(), Box<dyn std::error::Error>> {
    let countdown_task = tokio::spawn(async move {
        let mut interval = interval(Duration::from_secs(1));
        loop {
            interval.tick().await;
            update_countdown_and_points(Arc::clone(&app_state)).await?;
        }
        #[allow(unreachable_code)]
        Ok::<(), Box<dyn std::error::Error>>(())
    });

    let mut app_state = app_state.lock().unwrap();
    app_state.countdown_interval = Some(countdown_task);

    Ok(())
}

async fn update_countdown_and_points(app_state: Arc<Mutex<AppState>>) -> Result<(), Box<dyn std::error::Error>> {
    let local_storage = get_local_storage().await?;
    if let Some(last_updated) = local_storage.get("lastUpdated").and_then(|v| v.as_i64()) {
        let next_heartbeat = last_updated + 15 * 60;
        let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH)?.as_secs() as i64;
        let diff = next_heartbeat - now;

        let mut app_state = app_state.lock().unwrap();
        if diff > 0 {
            let minutes = diff / 60;
            let seconds = diff % 60;
            app_state.countdown = format!("{}m {}s", minutes, seconds);

            let max_points = 25.0;
            let time_elapsed = (now - last_updated) as f64;
            let time_elapsed_minutes = time_elapsed / 60.0;
            let mut new_points = (time_elapsed_minutes / 15.0 * max_points).min(max_points);
            new_points = (new_points * 100.0).round() / 100.0;

            if rand::thread_rng().gen::<f64>() < 0.1 {
                let bonus = rand::thread_rng().gen::<f64>() * 2.0;
                new_points = (new_points + bonus).min(max_points);
                new_points = (new_points * 100.0).round() / 100.0;
            }

            app_state.potential_points = new_points;
        } else {
            app_state.countdown = "Calculating...".to_string();
            app_state.potential_points = 25.0;
        }
    } else {
        let mut app_state = app_state.lock().unwrap();
        app_state.countdown = "Calculating...".to_string();
        app_state.potential_points = 0.0;
    }

    set_local_storage(json!({
        "potentialPoints": app_state.lock().unwrap().potential_points,
        "countdown": app_state.lock().unwrap().countdown,
    })).await?;

    Ok(())
}

async fn get_user_id(app_state: Arc<Mutex<AppState>>) -> Result<(), Box<dyn std::error::Error>> {
    let login_url = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password";
    let authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    let apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    print!("Email: ");
    io::stdout().flush()?;
    let mut email = String::new();
    io::stdin().lock().read_line(&mut email)?;

    print!("Password: ");
    io::stdout().flush()?;
    let mut password = String::new();
    io::stdin().lock().read_line(&mut password)?;

    let client = reqwest::Client::new();
    let response = client.post(login_url)
        .header("Authorization", authorization)
        .header("apikey", apikey)
        .json(&json!({
            "email": email.trim(),
            "password": password.trim()
        }))
        .send()
        .await?;

    let data: Value = response.json().await?;
    let user_id = data["user"]["id"].as_str().unwrap();
    println!("User ID: {}", user_id);

    let profile_url = format!("https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.{}", user_id);
    let profile_response = client.get(&profile_url)
        .header("Authorization", authorization)
        .header("apikey", apikey)
        .send()
        .await?;

    let profile_data: Value = profile_response.json().await?;
    println!("Profile Data: {:?}", profile_data);

    set_local_storage(json!({"userId": user_id})).await?;
    start_countdown_and_points(Arc::clone(&app_state)).await?;
    connect_websocket(user_id.to_string(), Arc::clone(&app_state)).await?;

    Ok(())
}

