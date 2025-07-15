TODO: to be cleaned up by Erik

- Install Visual code on your personal developer machine (MacOS, Linux, Windows)
- Install the Visual Code CBL Remote Development extension pack (search in VC and install in VC)
- ensure you have ssh installed on your development machine and you have keys generated
- upload keys to the tapas@tapas-cicd VM users, authorized keys.
- test that you can ssh into tappaas@tappaas-cicd from the development machine
you can now connect to the CICD VM using the connection bottom in the lower left corner of VC

help you set up Visual Studio Code Remote Development and connect to your CICD VM using SSH. I’ve included the exact terminal commands you’ll need.

✅ Step 1: Install the Remote Development Extension Pack in VS Code
Open Visual Studio Code.
Go to the Extensions view (click the square icon on the left or press Ctrl+Shift+X).
In the search bar, type:
Remote Development
Click Install on the extension pack by Microsoft.
✅ Step 2: Check if SSH is Installed
Open your terminal and run:

    ssh -V

If you see a version number (like OpenSSH_8.9p1), SSH is installed. If not, install it:

Ubuntu/Debian:

    sudo apt update
    sudo apt install openssh-client


macOS: SSH is already installed.

Windows: Use Git Bash or install OpenSSH via Windows Features.

✅ Step 3: Generate SSH Keys (if you don’t have them)
Check if you already have keys:


If you don’t see id_rsa and id_rsa.pub, generate them:

    ssh-keygen -t rsa -b 4096 -C "your_email@example.com"


Just press Enter to accept the default file location and leave the passphrase empty (or set one if you prefer).

✅ Step 4: Upload Your Public Key to the Remote VM

Replace tapas@tapas-cicd with your actual username and host if different.


    ssh-copy-id tappaas@tappaas-cicd

If ssh-copy-id is not available, use:

    cat ~/.ssh/id_rsa.pub | ssh tappaas@tappaas-cicd "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys


✅ Step 5: Test SSH Connection
Try connecting to the VM:
  
    ssh tappaas@tappaas-cicd

If you see a welcome message or terminal access, it works!

✅ Step 6: Connect to the VM from VS Code
In VS Code, click the green icon in the bottom-left corner.
Choose "Connect to Host...".
Select tapas@tapas-cicd or enter it manually.
VS Code will open a new window connected to the remote machine
