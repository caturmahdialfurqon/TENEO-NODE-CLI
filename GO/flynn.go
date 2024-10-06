package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"math"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

var (
	socket            *websocket.Conn
	pingTicker        *time.Ticker
	countdownTicker   *time.Ticker
	potentialPoints   float64
	countdown         string
	pointsTotal       int
	pointsToday       int
	localStorageFile  = "localStorage.json"
	reader            = bufio.NewReader(os.Stdin)
)

type LocalStorage struct {
	LastUpdated     string  `json:"lastUpdated"`
	PointsTotal     int     `json:"pointsTotal"`
	PointsToday     int     `json:"pointsToday"`
	LastPingDate    string  `json:"lastPingDate"`
	PotentialPoints float64 `json:"potentialPoints"`
	Countdown       string  `json:"countdown"`
	UserId          string  `json:"userId"`
}

func getLocalStorage() (LocalStorage, error) {
	data, err := ioutil.ReadFile(localStorageFile)
	if err != nil {
		return LocalStorage{}, err
	}
	var localStorage LocalStorage
	err = json.Unmarshal(data, &localStorage)
	return localStorage, err
}

func setLocalStorage(data LocalStorage) error {
	currentData, _ := getLocalStorage()
	newData := currentData
	if data.LastUpdated != "" {
		newData.LastUpdated = data.LastUpdated
	}
	if data.PointsTotal != 0 {
		newData.PointsTotal = data.PointsTotal
	}
	if data.PointsToday != 0 {
		newData.PointsToday = data.PointsToday
	}
	if data.LastPingDate != "" {
		newData.LastPingDate = data.LastPingDate
	}
	if data.PotentialPoints != 0 {
		newData.PotentialPoints = data.PotentialPoints
	}
	if data.Countdown != "" {
		newData.Countdown = data.Countdown
	}
	if data.UserId != "" {
		newData.UserId = data.UserId
	}
	jsonData, err := json.Marshal(newData)
	if err != nil {
		return err
	}
	return ioutil.WriteFile(localStorageFile, jsonData, 0644)
}

func connectWebSocket(userId string) error {
	if socket != nil {
		return nil
	}
	version := "v0.2"
	url := "wss://secure.ws.teneo.pro"
	wsUrl := fmt.Sprintf("%s/websocket?userId=%s&version=%s", url, userId, version)
	var err error
	socket, _, err = websocket.DefaultDialer.Dial(wsUrl, nil)
	if err != nil {
		return err
	}

	connectionTime := time.Now().UTC().Format(time.RFC3339)
	err = setLocalStorage(LocalStorage{LastUpdated: connectionTime})
	if err != nil {
		return err
	}
	fmt.Println("WebSocket connected at", connectionTime)
	startPinging()
	startCountdownAndPoints()

	go func() {
		for {
			_, message, err := socket.ReadMessage()
			if err != nil {
				fmt.Println("WebSocket read error:", err)
				return
			}
			var data map[string]interface{}
			err = json.Unmarshal(message, &data)
			if err != nil {
				fmt.Println("JSON unmarshal error:", err)
				continue
			}
			fmt.Println("Received message from WebSocket:", data)
			if pointsTotal, ok := data["pointsTotal"].(float64); ok {
				if pointsToday, ok := data["pointsToday"].(float64); ok {
					lastUpdated := time.Now().UTC().Format(time.RFC3339)
					err = setLocalStorage(LocalStorage{
						LastUpdated: lastUpdated,
						PointsTotal: int(pointsTotal),
						PointsToday: int(pointsToday),
					})
					if err != nil {
						fmt.Println("Error setting local storage:", err)
					}
				}
			}
		}
	}()

	return nil
}

func disconnectWebSocket() {
	if socket != nil {
		socket.Close()
		socket = nil
		stopPinging()
	}
}

func startPinging() {
	stopPinging()
	pingTicker = time.NewTicker(10 * time.Second)
	go func() {
		for range pingTicker.C {
			if socket != nil {
				err := socket.WriteJSON(map[string]string{"type": "PING"})
				if err != nil {
					fmt.Println("Error sending ping:", err)
					continue
				}
				err = setLocalStorage(LocalStorage{LastPingDate: time.Now().UTC().Format(time.RFC3339)})
				if err != nil {
					fmt.Println("Error setting last ping date:", err)
				}
			}
		}
	}()
}

func stopPinging() {
	if pingTicker != nil {
		pingTicker.Stop()
		pingTicker = nil
	}
}

func startCountdownAndPoints() {
	if countdownTicker != nil {
		countdownTicker.Stop()
	}
	updateCountdownAndPoints()
	countdownTicker = time.NewTicker(1 * time.Second)
	go func() {
		for range countdownTicker.C {
			updateCountdownAndPoints()
		}
	}()
}

func updateCountdownAndPoints() {
	localStorage, err := getLocalStorage()
	if err != nil {
		fmt.Println("Error getting local storage:", err)
		return
	}

	if localStorage.LastUpdated != "" {
		lastUpdated, err := time.Parse(time.RFC3339, localStorage.LastUpdated)
		if err != nil {
			fmt.Println("Error parsing last updated time:", err)
			return
		}

		nextHeartbeat := lastUpdated.Add(15 * time.Minute)
		now := time.Now().UTC()
		diff := nextHeartbeat.Sub(now)

		if diff > 0 {
			minutes := int(diff.Minutes())
			seconds := int(diff.Seconds()) % 60
			countdown = fmt.Sprintf("%dm %ds", minutes, seconds)

			maxPoints := 25.0
			timeElapsed := now.Sub(lastUpdated)
			timeElapsedMinutes := timeElapsed.Minutes()
			newPoints := math.Min(maxPoints, (timeElapsedMinutes/15)*maxPoints)
			newPoints = math.Floor(newPoints*100) / 100

			if rand.Float64() < 0.1 {
				bonus := rand.Float64() * 2
				newPoints = math.Min(maxPoints, newPoints+bonus)
				newPoints = math.Floor(newPoints*100) / 100
			}

			potentialPoints = newPoints
		} else {
			countdown = "Calculating..."
			potentialPoints = 25
		}
	} else {
		countdown = "Calculating..."
		potentialPoints = 0
	}

	err = setLocalStorage(LocalStorage{
		PotentialPoints: potentialPoints,
		Countdown:       countdown,
	})
	if err != nil {
		fmt.Println("Error setting local storage:", err)
	}
}

func getUserId() error {
	loginUrl := "https://ikknngrgxuxgjhplbpey.supabase.co/auth/v1/token?grant_type=password"
	authorization := "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"
	apikey := "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imlra25uZ3JneHV4Z2pocGxicGV5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3MjU0MzgxNTAsImV4cCI6MjA0MTAxNDE1MH0.DRAvf8nH1ojnJBc3rD_Nw6t1AV8X_g6gmY_HByG2Mag"

	fmt.Print("Email: ")
	email, _ := reader.ReadString('\n')
	email = strings.TrimSpace(email)

	fmt.Print("Password: ")
	password, _ := reader.ReadString('\n')
	password = strings.TrimSpace(password)

	payload := strings.NewReader(fmt.Sprintf(`{"email":"%s","password":"%s"}`, email, password))

	req, err := http.NewRequest("POST", loginUrl, payload)
	if err != nil {
		return err
	}

	req.Header.Add("Authorization", authorization)
	req.Header.Add("apikey", apikey)
	req.Header.Add("Content-Type", "application/json")

	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	body, err := ioutil.ReadAll(res.Body)
	if err != nil {
		return err
	}

	var response map[string]interface{}
	err = json.Unmarshal(body, &response)
	if err != nil {
		return err
	}

	user, ok := response["user"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("user data not found in response")
	}

	userId, ok := user["id"].(string)
	if !ok {
		return fmt.Errorf("user ID not found in response")
	}

	fmt.Println("User ID:", userId)

	profileUrl := fmt.Sprintf("https://ikknngrgxuxgjhplbpey.supabase.co/rest/v1/profiles?select=personal_code&id=eq.%s", userId)
	req, err = http.NewRequest("GET", profileUrl, nil)
	if err != nil {
		return err
	}

	req.Header.Add("Authorization", authorization)
	req.Header.Add("apikey", apikey)

	res, err = http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	body, err = ioutil.ReadAll(res.Body)
	if err != nil {
		return err
	}

	fmt.Println("Profile Data:", string(body))

	err = setLocalStorage(LocalStorage{UserId: userId})
	if err != nil {
		return err
	}

	startCountdownAndPoints()
	return connectWebSocket(userId)
}

func main() {
	localStorage, err := getLocalStorage()
	if err != nil {
		fmt.Println("Error getting local storage:", err)
	}

	userId := localStorage.UserId

	if userId == "" {
		fmt.Println("User ID not found. Would you like to:")
		fmt.Println("1. Login to your account")
		fmt.Println("2. Enter User ID manually")
		fmt.Print("Choose an option: ")
		option, _ := reader.ReadString('\n')
		option = strings.TrimSpace(option)

		switch option {
		case "1":
			err := getUserId()
			if err != nil {
				fmt.Println("Error getting user ID:", err)
				return
			}
		case "2":
			fmt.Print("Please enter your user ID: ")
			userId, _ = reader.ReadString('\n')
			userId = strings.TrimSpace(userId)
			err := setLocalStorage(LocalStorage{UserId: userId})
			if err != nil {
				fmt.Println("Error setting user ID:", err)
				return
			}
			startCountdownAndPoints()
			err = connectWebSocket(userId)
			if err != nil {
				fmt.Println("Error connecting to WebSocket:", err)
				return
			}
		default:
			fmt.Println("Invalid option. Exiting...")
			return
		}
	} else {
		fmt.Println("Menu:")
		fmt.Println("1. Logout")
		fmt.Println("2. Start Running Node")
		fmt.Print("Choose an option: ")
		option, _ := reader.ReadString('\n')
		option = strings.TrimSpace(option)

		switch option {
		case "1":
			err := os.Remove(localStorageFile)
			if err != nil {
				fmt.Println("Error removing local storage file:", err)
				return
			}
			fmt.Println("Logged out successfully.")
		case "2":
			startCountdownAndPoints()
			err := connectWebSocket(userId)
			if err != nil {
				fmt.Println("Error connecting to WebSocket:", err)
				return
			}
		default:
			fmt.Println("Invalid option. Exiting...")
			return
		}
	}

	// Handle SIGINT (Ctrl+C)
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	<-c

	fmt.Println("Received SIGINT. Stopping pinging...")
	stopPinging()
	disconnectWebSocket()
}

