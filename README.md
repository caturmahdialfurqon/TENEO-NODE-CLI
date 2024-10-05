# TENEO-NODE
Running Teneo Node BETA CLI with 7 Diff LanguageS.
Teneo Is an extension Node Based Project that will run Automatically when you click Connect Node in the Extension.

## What inside the Script

- Login Options
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
