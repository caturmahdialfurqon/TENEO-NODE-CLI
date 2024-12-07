use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::time::{Duration, Instant};
use std::thread;
use std::sync::{Arc, Mutex};
use serde::{Deserialize, Serialize};
use serde_json;
use tokio::time::sleep;
use tokio::sync::mpsc;
use tokio_tungstenite::connect_async;
use futures_util::{SinkExt, StreamExt};
use std::env;

#[derive(Serialize, Deserialize)]
struct LocalStorage {
    last_updated: Option<String>,
    points_total: Option<i32>,
    points_today: Option<i32>,
    last_ping_date: Option<String>,
    potential_points: Option<f64>,
    countdown: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct UserId {
    user_id: String,
}

#[derive(Serialize, Deserialize)]
struct AccountData {
    email: String,
    password: String,
    access_token: String,
    refresh_token: String,
    personal_code: String,
}

struct AppState {
    socket: Option<tokio_tungstenite::WebSocketStream<tokio_tungstenite::tungstenite::protocol::WebSocket>>,
    ping_interval: Option<tokio::time::Interval>,
    countdown_interval: Option<tokio::time::Interval>,
    potential_points: f64,
    countdown: String,
    points_total: i32,
    points_today: i32,
    reconnect_attempts: u32,
    max_reconnect_attempts: u32,
    max_reconnect_interval: Duration,
    coder_mark_printed: bool,
}

impl AppState {
    fn new() -> Self {
        Self {
            socket: None,
            ping_interval: None,
            countdown_interval: None,
            potential_points: 0.0,
            countdown: "Calculating...".to_string(),
            points_total: 0,
            points_today: 0,
            reconnect_attempts: 0,
            max_reconnect_attempts: 5,
            max_reconnect_interval: Duration::from_secs(5 * 60),
            coder_mark_printed: false,
        }
    }

    fn coder_mark(&mut self) {
        if !self.coder_mark_printed {
            println!(
                r#"
╭━━━╮╱╱╱╱╱╱╱╱╱╱╱╱╱╭━━━┳╮
┃╭━━╯╱╱╱╱╱╱╱╱╱╱╱╱╱┃╭━━┫┃
┃╰━━┳╮╭┳━┳━━┳━━┳━╮┃╰━━┫┃╭╮╱╭┳━╮╭━╮
┃╭━━┫┃┃┃╭┫╭╮┃╭╮┃╭╮┫╭━━┫┃┃┃╱┃┃╭╮┫╭╮╮
┃┃╱╱┃╰╯┃┃┃╰╯┃╰╯┃┃┃┃┃╱╱┃╰┫╰━╯┃┃┃┃┃┃┃
╰╯╱╱╰━━┻╯╰━╮┣━━┻╯╰┻╯╱╱╰━┻━╮╭┻╯╰┻╯╰╯
╱╱╱╱╱╱╱╱╱╱╱┃┃╱╱╱╱╱╱╱╱╱╱╱╭━╯┃
╱╱╱╱╱╱╱╱╱╱╱╰╯╱╱╱╱╱╱╱╱╱╱╱╰━━╯
\nTeneo Node Cli v1.1.0 dev_build
            "#
            );
            self.coder_mark_printed = true;
        }
    }

    async fn get_local_storage() -> io::Result<LocalStorage> {
        let mut file = File::open("localStorage.json")?;
        let mut data = String::new();
        file.read_to_string(&mut data)?;
        let local_storage: LocalStorage = serde_json::from_str(&data).unwrap_or_default();
        Ok(local_storage)
    }

    async fn set_local_storage(data: &LocalStorage) -> io::Result<()> {
        let current_data = Self::get_local_storage().await.unwrap_or_default();
        let new_data = LocalStorage {
            last_updated: data.last_updated.or(current_data.last_updated),
            points_total: data.points_total.or(current_data.points_total),
            points_today: data.points_today.or(current_data.points_today),
            last_ping_date: data.last_ping_date.or(current_data.last_ping_date),
            potential_points: data.potential_points.or(current_data.potential_points),
            countdown: data.countdown.or(current_data.countdown),
        };
        let json_data = serde_json::to_string(&new_data)?;
        let mut file = File::create("localStorage.json")?;
        file.write_all(json_data.as_bytes())?;
        Ok(())
    }

    async fn get_user_id_from_file() -> io::Result<Option<String>> {
        let mut file = File::open("UserId.json")?;
        let mut data = String::new();
        file.read_to_string(&mut data)?;
        let user_id: UserId = serde_json::from_str(&data)?;
        Ok(Some(user_id.user_id))
    }

    async fn set_user_id_to_file(user_id: &str) -> io::Result<()> {
        let user_id_data = UserId {
            user_id: user_id.to_string(),
        };
        let json_data = serde_json::to_string(&user_id_data)?;
        let mut file = File::create("UserId.json")?;
        file.write_all(json_data.as_bytes())?;
        Ok(())
    }

    async fn get_account_data() -> io::Result<AccountData> {
        let mut file = File::open("DataAccount.json")?;
        let mut data = String::new();
        file.read_to_string(&mut data)?;
        let account_data: AccountData = serde_json::from_str(&data).unwrap_or_default();
        Ok(account_data)
    }

    async fn set_account_data(email: &str, password: &str, access_token: &str, refresh_token: &str, personal_code: &str) -> io::Result<()> {
        let account_data = AccountData {
            email: email.to_string(),
            password: password.to_string(),
            access_token: access_token.to_string(),
            refresh_token: refresh_token.to_string(),
            personal_code: personal_code.to_string(),
        };
        let json_data = serde_json::to_string(&account_data)?;
        let mut file = File::create("DataAccount.json")?;
        file.write_all(json_data.as_bytes())?;
        Ok(())
    }

    fn get_reconnect_delay(attempt: u32) -> Duration {
        let base_delay = Duration::from_secs(5); // 5 seconds
        let additional_delay = Duration::from_secs(attempt as u64 * 5); // Additional 5 seconds for each attempt
        std::cmp::min(base_delay + additional_delay, Duration::from_secs(5 * 60)) // 5 minutes
    }

    async fn connect_websocket(&mut self, user_id: &str) {
        if self.socket.is_some() {
            return;
        }
        let version = "v0.2";
        let url = "wss://secure.ws.teneo.pro";
        let ws_url = format!("{}?userId={}&version={}", url, user_id, version);
        let (socket, _) = connect_async(&ws_url).await.expect("Failed to connect");

        self.socket = Some(socket);
        self.reconnect_attempts = 0;
        let connection_time = chrono::Utc::now().to_rfc3339();
        self.set_local_storage(&LocalStorage {
            last_updated: Some(connection_time.clone()),
            points_total: None,
            points_today: None,
            last_ping_date: None,
            potential_points: None,
            countdown: None,
        }).await.unwrap();
        println!("WebSocket connected at {}", connection_time);
        self.start_pinging();
        self.start_countdown_and_points();

        let socket_clone = self.socket.clone().unwrap();
        tokio::spawn(async move {
            let mut socket = socket_clone;
            while let Some(message) = socket.next().await {
                match message {
                    Ok(msg) => {
                        let data: serde_json::Value = serde_json::from_str(&msg.to_string()).unwrap();
                        println!("Received message from WebSocket: {:?}", data);
                        if let (Some(points_total), Some(points_today)) = (data.get("pointsTotal"), data.get("pointsToday")) {
                            let last_updated = chrono::Utc::now().to_rfc3339();
                            self.set_local_storage(&LocalStorage {
                                last_updated: Some(last_updated.clone()),
                                points_total: Some(points_total.as_i64().unwrap() as i32),
                                points_today: Some(points_today.as_i64().unwrap() as i32),
                                last_ping_date: None,
                                potential_points: None,
                                countdown: None,
                            }).await.unwrap();
                            self.points_total = points_total.as_i64().unwrap() as i32;
                            self.points_today = points_today.as_i64().unwrap() as i32;
                        }
                    }
                    Err(e) => {
                        eprintln!("WebSocket error: {:?}", e);
                    }
                }
            }
        });

        // Handle socket close
        let socket_clone = self.socket.clone();
        tokio::spawn(async move {
            let socket = socket_clone.unwrap();
            socket.on_close().await;
            self.socket = None;
            println!("WebSocket disconnected");
            self.stop_pinging();
            if !socket.is_clean() {
                self.reconnect_attempts += 1;
                let delay = Self::get_reconnect_delay(self.reconnect_attempts);
                if delay < self.max_reconnect_interval {
                    sleep(delay).await;
                    self.reconnect_websocket().await;
                } else {
                    println!("Max reconnect interval reached. Giving up.");
                }
            }
        });
    }

    fn disconnect_websocket(&mut self) {
        if let Some(socket) = self.socket.take() {
            socket.close();
            self.stop_pinging();
        }
    }

    fn start_pinging(&mut self) {
        self.stop_pinging();
        let ping_interval = tokio::time::interval(Duration::from_secs(10));
        self.ping_interval = Some(ping_interval);
        let socket_clone = self.socket.clone();
        tokio::spawn(async move {
            let mut interval = ping_interval;
            loop {
                interval.tick().await;
                if let Some(socket) = socket_clone.clone() {
                    if socket.is_open() {
                        let ping_message = serde_json::json!({ "type": "PING" });
                        socket.send(ping_message.to_string()).await.unwrap();
                        let last_ping_date = chrono::Utc::now().to_rfc3339();
                        self.set_local_storage(&LocalStorage {
                            last_updated: None,
                            points_total: None,
                            points_today: None,
                            last_ping_date: Some(last_ping_date),
                            potential_points: None,
                            countdown: None,
                        }).await.unwrap();
                    }
                }
            }
        });
    }

    fn stop_pinging(&mut self) {
        if let Some(interval) = self.ping_interval.take() {
            interval.stop();
        }
    }

    async fn start_countdown_and_points(&mut self) {
        self.clear_countdown_interval();
        self.update_countdown_and_points().await;
        let countdown_interval = tokio::time::interval(Duration::from_secs(1));
        self.countdown_interval = Some(countdown_interval);
        let socket_clone = self.socket.clone();
        tokio::spawn(async move {
            let mut interval = countdown_interval;
            loop {
                interval.tick().await;
                self.update_countdown_and_points().await;
            }
        });
    }

    async fn update_countdown_and_points(&mut self) {
        let local_storage = Self::get_local_storage().await.unwrap();
        if let Some(last_updated) = local_storage.last_updated {
            let next_heartbeat = chrono::DateTime::parse_from_rfc3339(&last_updated).unwrap() + chrono::Duration::minutes(15);
            let now = chrono::Utc::now();
            let diff = (next_heartbeat - now).num_milliseconds();

            if diff > 0 {
                let minutes = diff / 60000;
                let seconds = (diff % 60000) / 1000;
                self.countdown = format!("{}m {}s", minutes, seconds);

                let max_points = 25.0;
                let time_elapsed = now.timestamp_millis() - chrono::DateTime::parse_from_rfc3339(&last_updated).unwrap().timestamp_millis();
                let time_elapsed_minutes = time_elapsed as f64 / (60.0 * 1000.0);
                let mut new_points = (time_elapsed_minutes / 15.0) * max_points;
                new_points = new_points.min(max_points);

                if rand::random::<f64>() < 0.1 {
                    let bonus = rand::random::<f64>() * 2.0;
                    new_points = (new_points + bonus).min(max_points);
                }

                self.potential_points = new_points;
            } else {
                self.countdown = "Calculating...".to_string();
                self.potential_points = 25.0;
            }
        } else {
            self.countdown = "Calculating...".to_string();
            self.potential_points = 0.0;
        }
        self.set_local_storage(&LocalStorage {
            last_updated: None,
            points_total: None,
            points_today: None,
            last_ping_date: None,
            potential_points: Some(self.potential_points),
            countdown: Some(self.countdown.clone()),
        }).await.unwrap();
    }

    async fn get_user_id(&mut self) {
        let login_url = "https://node-community-api.teneo.pro/auth/v1/token?grant_type=password";
        let authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
        let apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

        let account_data = Self::get_account_data().await.unwrap();
        let email = account_data.email.clone();
        let password = account_data.password.clone();

        let client = reqwest::Client::new();
        let response = client.post(login_url)
            .header("Authorization", authorization)
            .header("apikey", apikey)
            .json(&serde_json::json!({ "email": email, "password": password }))
            .send()
            .await
            .unwrap();

        let tokens: serde_json::Value = response.json().await.unwrap();
        let access_token = tokens["access_token"].as_str().unwrap();
        let refresh_token = tokens["refresh_token"].as_str().unwrap();
        println!("Access_Token: {}", access_token);
        println!("Refresh_Token: {}", refresh_token);

        let auth_user_url = "https://node-community-api.teneo.pro/auth/v1/user";
        let auth_response = client.get(auth_user_url)
            .header("Authorization", format!("Bearer {}", access_token))
            .header("apikey", apikey)
            .send()
            .await
            .unwrap();

        let user_data: serde_json::Value = auth_response.json().await.unwrap();
        let user_id = user_data["id"].as_str().unwrap();
        println!("User ID: {}", user_id);

        let profile_url = format!("https://node-community-api.teneo.pro/rest/v1/profiles?select=personal_code&id=eq.{}", user_id);
        let profile_response = client.get(&profile_url)
            .header("Authorization", format!("Bearer {}", access_token))
            .header("apikey", apikey)
            .send()
            .await
            .unwrap();

        let profile_data: serde_json::Value = profile_response.json().await.unwrap();
        let personal_code = profile_data[0]["personal_code"].as_str().unwrap();
        println!("Personal Code: {}", personal_code);
        self.set_user_id_to_file(user_id).await.unwrap();
        self.set_account_data(&email, &password, access_token, refresh_token, personal_code).await.unwrap();
        self.start_countdown_and_points().await;
        self.connect_websocket(user_id).await;
        println!("Data has been saved in the DataAccount.json file...");
        self.coder_mark();
    }

    async fn reconnect_websocket(&mut self) {
        if let Some(user_id) = self.get_user_id_from_file().await.unwrap() {
            self.connect_websocket(&user_id).await;
        }
    }

    async fn auto_login(&mut self) {
        let account_data = Self::get_account_data().await.unwrap();
        if !account_data.email.is_empty() && !account_data.password.is_empty() {
            self.get_user_id().await;
            println!("Automatic Login has been Successfully Executed..");
        }
    }

    async fn main(&mut self) {
        let local_storage_data = Self::get_local_storage().await.unwrap();
        let user_id = Self::get_user_id_from_file().await.unwrap();

        if user_id.is_none() {
            println!("User ID not found. Would you like to:");
            println!("1. Login to your account");
            println!("2. Enter User ID manually");
            let option: String = read_input().await;
            match option.as_str() {
                "1" => self.get_user_id().await,
                "2" => {
                    println!("Please enter your user ID: ");
                    let input_user_id: String = read_input().await;
                    self.set_user_id_to_file(&input_user_id).await.unwrap();
                    self.start_countdown_and_points().await;
                    self.connect_websocket(&input_user_id).await;
                }
                _ => {
                    println!("Invalid option. Exiting...");
                    std::process::exit(0);
                }
            }
        } else {
            println!("Menu:");
            println!("1. Logout");
            println!("2. Start Running Node");
            let option: String = read_input().await;
            match option.as_str() {
                "1" => {
                    fs::remove_file("UserId.json").unwrap();
                    fs::remove_file("localStorage.json").unwrap();
                    fs::remove_file("DataAccount.json").unwrap();
                    println!("Logged out successfully.");
                    std::process::exit(0);
                }
                "2" => {
                    self.clear_console();
                    self.coder_mark();
                    println!("Initiates a connection to the node...");
                    self.start_countdown_and_points().await;
                    self.connect_websocket(&user_id.unwrap()).await;
                }
                _ => {
                    println!("Invalid option. Exiting...");
                    std::process::exit(0);
                }
            }
        }
    }

    fn clear_console(&self) {
        print!("{esc}[2J{esc}[1;1H", esc = 27 as char);
    }
}

async fn read_input() -> String {
    let mut input = String::new();
    io::stdin().read_line(&mut input).unwrap();
    input.trim().to_string()
}

#[tokio::main]
async fn main() {
    let mut app_state = AppState::new();
    app_state.main().await;
    loop {
        app_state.auto_login().await;
        sleep(Duration::from_secs(1800)).await; // 30 minutes
    }
}

