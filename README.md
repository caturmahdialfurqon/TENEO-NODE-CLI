# TENEO-NODE
Running Teneo Node BETA CLI with 7 Diff LanguageS. <br>
Teneo Is an extension Node Based Project that will run Automatically when you click Connect Node in the Extension.

## How To SignUp (Register)

- https://teneo.pro/community-node : Download The Extension
- Extract the Extension
- Activate Developer Mode
- Load The Extension Folder (contain manifes.json)
- Open the Extention on browser Section Click SignUp Button
- Create Account
- Enter Code : Wrsrs
- Verify Email
- Run Nodes Extension
- Get 10000 Bonuse SignUp,And 2500 Node Point When Using My Referal Code.

## What inside the Script

- Login Options (For Getting UserId)
- Running Node
- Logout account (Clearing LocalStorageData)

## NODE.JS
- if await setLocalStorage({}); Doesnt Work.
- Try
  ```JavaScript
        case '1':
          fs.unlink('localStorage.json', (err) => {
            if (err) throw err;
          });
          console.log('Logged out successfully.');
          process.exit(0);
          break;
  ```
<img src="/Asset/Screenshot 2024-10-05 at 20.08.20.png" width=600>

## LocalStorage Data

<img src="/Asset/CleanShot 2024-10-05 at 20.05.19.gif" width=600>
