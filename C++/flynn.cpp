#include <iostream>
#include <fstream>
#include <string>
#include <chrono>
#include <thread>
#include <ctime>
#include <iomanip>
#include <random>
#include <nlohmann/json.hpp>
#include <websocketpp/config/asio_client.hpp>
#include <websocketpp/client.hpp>
#include <curl/curl.h>

using json = nlohmann::json;

websocketpp::client<websocketpp::config::asio_tls_client> client;
websocketpp::connection_hdl connection;
std::thread websocket_thread;
std::thread ping_thread;
std::thread countdown_thread;

double potential_points = 0.0;
std::string countdown = "Calculating...";
int points_total = 0;
int points_today = 0;

json get_local_storage() {
    std::ifstream file("localStorage.json");
    if (file.is_open()) {
        json data;
        file >> data;
        return data;
    }
    return json::object();
}

void set_local_storage(const json& data) {
    json current_data = get_local_storage();
    current_data.merge_patch(data);
    std::ofstream file("localStorage.json");
    file << current_data.dump(4);
}

void connect_websocket(const std::string& user_id) {
    std::string version = "v0.2";
    std::string url = "wss://secure.ws.teneo.pro";
    std::string ws_url = url + "/websocket?userId=" + user_id + "&version=" + version;

    client.set_access_channels(websocketpp::log::alevel::all);
    client.clear_access_channels(websocketpp::log::alevel::frame_payload);

    client.init_asio();

    client.set_tls_init_handler([](websocketpp::connection_hdl) {
        return websocketpp::lib::make_shared<boost::asio::ssl::context>(boost::asio::ssl::context::tlsv12);
    });

    client.set_message_handler([](websocketpp::connection_hdl, websocketpp::config::asio_client::message_type::ptr msg) {
        json data = json::parse(msg->get_payload());
        std::cout << "Received message from WebSocket: " << data.dump() << std::endl;
        if (data.contains("pointsTotal") && data.contains("pointsToday")) {
            auto now = std::chrono::system_clock::now();
            auto last_updated = std::chrono::system_clock::to_time_t(now);
            set_local_storage({
                {"lastUpdated", std::put_time(std::localtime(&last_updated), "%FT%T")},
                {"pointsTotal", data["pointsTotal"]},
                {"pointsToday", data["pointsToday"]}
            });
            points_total = data["pointsTotal"];
            points_today = data["pointsToday"];
        }
    });

    websocketpp::lib::error_code ec;
    auto con = client.get_connection(ws_url, ec);
    if (ec) {
        std::cout << "Could not create connection: " << ec.message() << std::endl;
        return;
    }

    connection = con->get_handle();
    client.connect(con);

    websocket_thread = std::thread([&]() {
        client.run();
    });
}

void disconnect_websocket() {
    if (connection.lock()) {
        client.close(connection, websocketpp::close::status::normal, "");
    }
    if (websocket_thread.joinable()) {
        websocket_thread.join();
    }
}

void start_pinging() {
    ping_thread = std::thread([]() {
        while (true) {
            std::this_thread::sleep_for(std::chrono::seconds(10));
            if (connection.lock()) {
                client.send(connection, "{\"type\":\"PING\"}", websocketpp::frame::opcode::text);
                auto now = std::chrono::system_clock::now();
                auto last_ping = std::chrono::system_clock::to_time_t(now);
                set_local_storage({{"lastPingDate", std::put_time(std::localtime(&last_ping), "%FT%T")}});
            }
        }
    });
}

void stop_pinging() {
    if (ping_thread.joinable()) {
        ping_thread.join();
    }
}

void update_countdown_and_points() {
    json local_storage = get_local_storage();
    if (local_storage.contains("lastUpdated")) {
        std::tm tm = {};
        std::istringstream ss(local_storage["lastUpdated"].get<std::string>());
        ss >> std::get_time(&tm, "%Y-%m-%dT%H:%M:%S");
        auto last_updated = std::chrono::system_clock::from_time_t(std::mktime(&tm));
        auto next_heartbeat = last_updated + std::chrono::minutes(15);
        auto now = std::chrono::system_clock::now();
        auto diff = std::chrono::duration_cast<std::chrono::seconds>(next_heartbeat - now);

        if (diff.count() > 0) {
            int minutes = diff.count() / 60;
            int seconds = diff.count() % 60;
            countdown = std::to_string(minutes) + "m " + std::to_string(seconds) + "s";

            const double max_points = 25.0;
            auto time_elapsed = std::chrono::duration_cast<std::chrono::minutes>(now - last_updated);
            double new_points = std::min(max_points, (time_elapsed.count() / 15.0) * max_points);
            new_points = std::round(new_points * 100.0) / 100.0;

            std::random_device rd;
            std::mt19937 gen(rd());
            std::uniform_real_distribution<> dis(0.0, 1.0);
            if (dis(gen) < 0.1) {
                double bonus = dis(gen) * 2.0;
                new_points = std::min(max_points, new_points + bonus);
                new_points = std::round(new_points * 100.0) / 100.0;
            }

            potential_points = new_points;
        } else {
            countdown = "Calculating...";
            potential_points = 25.0;
        }
    } else {
        countdown = "Calculating...";
        potential_points = 0.0;
    }

    set_local_storage({{"potentialPoints", potential_points}, {"countdown", countdown}});
}

void start_countdown_and_points() {
    countdown_thread = std::thread([]() {
        while (true) {
            update_countdown_and_points();
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    });
}

std::string get_user_id() {
    std::string login_url = "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password";
    std::string authorization = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";
    std::string apikey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag";

    std::string email, password;
    std::cout << "Email: ";
    std::cin >> email;
    std::cout << "Password: ";
    std::cin >> password;

    CURL *curl = curl_easy_init();
    if (curl) {
        std::string response_string;
        std::string post_fields = "email=" + email + "&password=" + password;

        curl_easy_setopt(curl, CURLOPT_URL, login_url.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post_fields.c_str());
        
        struct curl_slist *headers = NULL;
        headers = curl_slist_append(headers, ("Authorization: " + authorization).c_str());
        headers = curl_slist_append(headers, ("apikey: " + apikey).c_str());
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, +[](void *contents, size_t size, size_t nmemb, std::string *s) {
            size_t newLength = size * nmemb;
            s->append((char*)contents, newLength);
            return newLength;
        });
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_string);

        CURLcode res = curl_easy_perform(curl);
        
        if (res != CURLE_OK) {
            std::cerr << "curl_easy_perform() failed: " << curl_easy_strerror(res) << std::endl;
        } else {
            json response_json = json::parse(response_string);
            std::string user_id = response_json["user"]["id"];
            std::cout << "User ID: " << user_id << std::endl;

            std::string profile_url = "https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq." + user_id;
            
            curl_easy_setopt(curl, CURLOPT_URL, profile_url.c_str());
            curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
            
            response_string.clear();
            res = curl_easy_perform(curl);
            
            if (res != CURLE_OK) {
                std::cerr << "curl_easy_perform() failed: " << curl_easy_strerror(res) << std::endl;
            } else {
                json profile_json = json::parse(response_string);
                std::cout << "Profile Data: " << profile_json.dump() << std::endl;
            }

            set_local_storage({{"userId", user_id}});
            start_countdown_and_points();
            connect_websocket(user_id);

            curl_slist_free_all(headers);
            curl_easy_cleanup(curl);
            return user_id;
        }

        curl_slist_free_all(headers);
        curl_easy_cleanup(curl);
    }

    return "";
}

int main() {
    json local_storage = get_local_storage();
    std::string user_id = local_storage.value("userId", "");

    if (user_id.empty()) {
        std::cout << "User ID not found. Would you like to:\n1. Login to your account\n2. Enter User ID manually\nChoose an option: ";
        int option;
        std::cin >> option;

        switch (option) {
            case 1:
                user_id = get_user_id();
                break;
            case 2:
                std::cout << "Please enter your user ID: ";
                std::cin >> user_id;
                set_local_storage({{"userId", user_id}});
                start_countdown_and_points();
                connect_websocket(user_id);
                break;
            default:
                std::cout << "Invalid option. Exiting..." << std::endl;
                return 0;
        }
    } else {
        std::cout << "Menu:\n1. Logout\n2. Start Running Node\nChoose an option: ";
        int option;
        std::cin >> option;

        switch (option) {
            case 1:
                std::remove("localStorage.json");
                std::cout << "Logged out successfully." << std::endl;
                return 0;
            case 2:
                start_countdown_and_points();
                connect_websocket(user_id);
                break;
            default:
                std::cout << "Invalid option. Exiting..." << std::endl;
                return 0;
        }
    }

    // Keep the program running
    while (true) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }

    disconnect_websocket();
    stop_pinging();
    if (countdown_thread.joinable()) {
        countdown_thread.join();
    }

    return 0;
}

