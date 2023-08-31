# Setting up Jellyfin under Windows Server Core & IIS - A Snarky Guide

Setting up Jellyfin on Windows is not a smooth experience, so I'm writing this guide to detail my findings and frustrations, and perhaps help you get set up more easily.

Some of my criticisms are exaggerated. That's kinda the whole point, it's right in the title. It makes writing documentation a whole lot more fun (this probably wouldn't exist otherwise), and maybe it'll even make reading it more fun.

Jellyfin is open-source software, which comes with the usual caveats:
- Poor documentation and instructions
- A UI with annoying usability problems and useless error messages
- A community that will chastise you for not using Linux/Apache/Docker/etc at every step of the way

With that said, once it's set up, it mostly works well. I hope you don't plan to use the metadata editing features extensively though...

If you run into issues with this guide (typos, incorrect info, etc) feel free to open a GitHub issue and I'll try to fix it. If you just need help with a specific configuration, you can still try opening an issue, but please understand that there's an 80% chance I'll just tell you to ask on a support forum instead (in which case enjoy getting yelled at for daring to not use Linux).

## Table of Contents
- [Specifics](#specifics)
- [1. Windows Server Installation](#1-windows-server-installation)
- [2. Accounts and Remoting](#2-accounts-and-remoting)
- [3. Install Jellyfin](#3-install-jellyfin)
- [4. Configure Jellyfin](#4-configure-jellyfin)
- [5. Install IIS](#5-install-iis)
- [6. Configure IIS](#6-configure-iis)
- [7. Going Public](#7-going-public)
- [8. SSL Certificate](#8-ssl-certificate)
- [9. Certificate Auto-Renewal](#9-certificate-auto-renewal)
- [Finale](#finale)

## Specifics
This guide is written for my usecase. If your usecase is different, I've tried to indicate which parts of the guide are specific to these details:
- The server is part of a domain, with media stored on another domain server hosted via SMB share
    - I've made efforts to include information for the non-domain usecase as well, but no guarantees. And in that case, it would be best practice to use a [service account](https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-service-accounts) instead of a full user account anyways, but the user approach _should_ also work.
- The server is installed in a VM that is running Windows Server Core 2022 (the minimal UI version)
    - This mostly means that the entire guide can be done through PowerShell, instead of GUIs.
- Jellyfin is accessed through an IIS reverse-proxy over HTTPS only
    - This can easily be installed on another server instead, or an existing IIS installation can be used, but for this guide I'm assuming they are on the same server.
- Jellyfin runs as a Windows service
- No Docker, no Apache, no Linux 😎

## 1. Windows Server Installation
Just a quick checklist, you should probably know how to do these already.
1) Prepare a VM
    - Dynamic RAM, capped at a reasonable amount (the VM usually only uses 1.5GB + ~1.5GB per active transcode)
    - Many CPU cores for using software transcoding
        - I found about 3-4 cores of an EPYC 7313P (2021 model server CPU) per user to be plenty sufficient for my usecase, but you'll likely need more if running on older hardware.
        - You could try setting up hardware transcoding if you have a GPU in your server, but that will not be covered in this guide as it's a whole different can of worms.
    - Static MAC address if using DHCP reservation
2) Install Windows Server Core
3) Install all available updates
4) Set the hostname (referred to as `{HOSTNAME}` from now on)
5) Join to domain (optional)
6) Set static IP if not using a DHCP reservation

## 2. Accounts and Remoting
1) Set up the user account
    - **If domain-joined**, create a domain account that the Jellyfin software will run under, and add it to the correct groups so it has at least read access to your media library. Write access is needed if you plan to save metadata into your library or want to be able to delete media through Jellyfin, but I recommend read-only access.
    - **If not domain-joined**, create a local non-admin account, and for the rest of the guide, replace `{DOMAIN}\{USER}` with `.\JellyfinUser`
    ```powershell
    # For non-domain setups only. This will prompt you for the password to use. Description is optional.
    New-LocalUser 'JellyfinUser' -PasswordNeverExpires -UserMayNotChangePassword -Description 'Runs the Jellyfin server software'
    ```
2) Set up a local admin account
    - **If domain-joined**, feel free to use a domain admin account, or make a regular domain account a local administrator on this VM, either through group policy or via:
    ```powershell
    Add-LocalGroupMember -Group 'Administrators' -Member '{DOMAIN}\{ADMIN}'
    ```
    This account will be referred to as `{DOMAIN}\{ADMIN}` for the rest of the guide _but it does not have to be a domain administrator, only a local administrator_.
    - **If not domain-joined**, you can simply use the built-in `Administrator` account, or any other local admin account. This may need additional set-up in the next step however. For the rest of this guide, replace `{DOMAIN}\{ADMIN}` with this user account.

3) Set up PowerShell remoting  
    **If not domain-joined**, you'll need to find the procedure for this elsewhere, but it should only take a few additional steps.

    **If domain-joined**, you'll want to use PowerShell remoting to manage the server from another domain-joined computer more easily. This is super useful for pasting in text in the following steps. By default, local administrator accounts are already able to use PS remoting without needing to be added to any additional groups.  
    **Not required:** If you'd like to be able to remote in as the non-admin user as well, you can use this:
    ```powershell
    Add-LocalGroupMember -Group 'Remote Management Users' -Member '{DOMAIN}\{USER}'
    ```

4) Remote in  
    Then run this from the domain-joined computer where you're reading this guide:
    ```powershell
    $JFCred = Get-Credential
    # A prompt will appear. Enter the username as {DOMAIN}\{ADMIN}, and the password, for the account Jellyfin will run under.
    Enter-PSSession -ComputerName '{HOSTNAME}' -Credential $JFCred
    ```
    The rest of this guide is written such that you won't need to access the VM's desktop/GUI at all anymore. 𝑬𝒎𝒃𝒓𝒂𝒄𝒆 𝒕𝒉𝒆 𝑷𝒐𝒘𝒆𝒓𝑺𝒉𝒆𝒍𝒍~

    There's one catch: There's a couple of times where you'll need to edit a text file. I prefer to just edit it on a network share and copy it over, but you can of course also just open it in Notepad if you're at the local console of the VM/server (`notepad.exe {FILE}`). Unlike Linux systems that usually ship with unusable garbage like Vim, Windows doesn't have a CLI text editor built in anymore, since those were 16-bit legacy programs that no longer work on 64-bit systems.

## 3. Install Jellyfin
1) Install Microsoft Visual C++ Redistributable  
    ```powershell
    cd '~\Downloads'
    Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile 'vc_redist.x64.exe' -UseBasicParsing
    & .\vc_redist.x64.exe /q /norestart
    ```

2) Install Jellyfin  
    Find the direct link to the latest `combined` Jellyfin release from [here](https://repo.jellyfin.org/releases/server/windows/stable/) (this also comes with NSSM and FFmpeg, both of which we will need). Via the administrative account on the server, download and extract that file:
    ```powershell
    cd '~\Downloads'
    Invoke-WebRequest '{LINK}' -OutFile 'Jellyfin.zip' -UseBasicParsing
    Expand-Archive 'Jellyfin.zip' $PWD
    Move-Item '.\jellyfin_{VERSION}\' 'C:\Program Files\Jellyfin'
    ```
    Note that you need the direct link to the file, not a webpage. At the time of writing, this was `https://repo.jellyfin.org/releases/server/windows/stable/combined/jellyfin_10.8.9.zip`
3) Folder Permissions  
    Change the permissions on this folder so that the non-admin account can edit files contained there:
    ```powershell
    $ACL = Get-Acl 'C:\Program Files\Jellyfin\'
    $NewRule = New-Object System.Security.AccessControl.FileSystemAccessRule('{DOMAIN}\{USER}', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $ACL.SetAccessRule($NewRule)
    Set-Acl 'C:\Program Files\Jellyfin\' $ACL
    ```
    Take a moment to enjoy the fact that we're not stuck on a system where archaic user-group-world permissions are seen as normal, and instead we actually have fine-grained control over file permissions.

4) Install the service via NSSM
    ```powershell
    cd 'C:\Program Files\Jellyfin\'
    & .\nssm.exe install JellyfinServer "C:\Program Files\Jellyfin\jellyfin.exe" --service --datadir "C:\ProgramData\Jellyfin\Server"
    & .\nssm.exe set JellyfinServer ObjectName "{DOMAIN}\{USER}" "{PASSWORD}"
    ```
    When running the last line, it should give you the following message:  
    `The "Log on as a service" right was granted to account {DOMAIN}\{USER}.`  
    If not, you may need to configure this manually, which can be rather annoying, and will not be explained here. I hope they add this capability to PowerShell one day, but for now you're just kinda stuck editing it via a UI, or group policy. This makes me sad too.

5) Configure logging to file  
    You can optionally set up log redirection as well. I recommend skipping this step for now and only coming back to do this later if you need to troubleshoot:
    ```powershell
    cd 'C:\Program Files\Jellyfin\'
    & .\nssm.exe set JellyfinServer AppStdout "C:\Program Files\Jellyfin\jellyfin-service.log"
    & .\nssm.exe set JellyfinServer AppStderr "C:\Program Files\Jellyfin\jellyfin-service.log"
    ```

6) Firewall Port  
    You might think that software which runs over the network would have an easy way to configure its port _before_ starting the program, but Jellyfin does not appear to have this easily configurable. Either that, or it's not documented well enough for me to have been able to find this information. This isn't a problem unless you're installing this on a machine with other software running that uses port 8096, because in that case you're probably just screwed. 🤷‍♂️

    Regardless, we'll need to add a firewall rule so that traffic can get to Jellyfin:
    ```powershell
    New-NetFirewallRule -DisplayName 'Jellyfin' -Direction 'Inbound' -Action 'Allow' -LocalPort 8096 -Protocol 'TCP' -Program 'C:\Program Files\Jellyfin\jellyfin.exe'
    ```
    Note that you'll probably want to remove this later once you have the IIS reverse proxy set up (if doing so).

7) Start Jellyfin  
    Make sure the service is set to automatically start when the server reboots, and start the service. Hopefully everything is configured correctly.
    ```powershell
    Set-Service 'JellyfinServer' -StartupType 'Automatic'
    Start-Service 'JellyfinServer'
    ```

## 4. Configure Jellyfin
1) Access the web UI  
    From any computer on the local network, access the web UI via `http://{HOSTNAME or IP}:8096`  
    If it's not working, check to make sure the service didn't die. The `Status` should be `Running`:
    ```powershell
    Get-Service 'JellyfinServer'
    ```
    If not, go back to step 3.5 (turn on logging to file), start the service again, then check the log file to see what went wrong.

2) Setup wizard - Media Libraries  
    Go through the setup wizard and configure the first few basic settings. When asked to configure media libraries, do the following:  
    - **If domain-joined and using a file server**, enter the UNC path to the file server, share, and folder where your media is located. It should not have any trouble connecting if you've correctly given the user account that Jellyfin is running under read access on the file server.  
    Note that even [Jellyfin team members claim that this can't work on the support forums](https://old.reddit.com/r/jellyfin/comments/sogwmb/adding_network_share_folder_to_library/hw9a4vf/), and [the official documentation agrees](https://jellyfin.org/docs/general/administration/storage#storage), but it in fact works perfectly fine. Maybe they just don't know how to properly configure a Windows network?  
    On the off chance you do have trouble with this, try this (but still use the UNC paths as before):
    ```powershell
    & net use /persistent:yes
    & net use \\{FILESERVER}\{SHARE} /user:{DOMAIN}\{USER} {PASSWORD}
    ```
    - **If using files stored locally**, just enter the path to the correct folder.
    - **If not domain-joined, yet still using a file server/NAS**, you've chosen the path of pain. Maybe this will work for you, but in my brief tests, even with the share mapped and working, Jellyfin was unable to see it. Try it by running this command **under the user Jellyfin is running as**:
    ```powershell
    & net use M: \\{FILESERVER}\{SHARE} /savecred /persistent:yes
    # It should now prompt you for the username and password, supply the credentials needed to access your file server.
    ```
    [Alternatively, give this janky workaround a try.](https://github.com/jellyfin/jellyfin-server-windows/issues/54)
    
3) Setup wizard - Remainder  
    On the "Set up Remote Access" page, I recommend leaving the "Enable automatic port mapping" box unchecked.  
    Finish the wizard, then login with the account you just made.

4) Wait  
    Jellyfin will take a while to index your media libraries for first use. You can keep an eye on progress by going to the ≡ menu, then Administration -> Dashboard, then Server -> Libraries. There should be a progress bar above the library list, wait for this to finish before proceeding.

5) Test playback  
    Try playing some video content, and enjoy likely getting this utterly unhelpful error message (with an infinite spinner overlaid on top for good measure):
    > Playback Error  
    > This client isn't compatible with the media and the server isn't sending a compatible media format.

    What this is likely _trying_ to tell you is that FFmpeg isn't set up yet. Obviously. What, did you not understand that from this error message?

6) Configure FFmpeg  
    (Even if playback worked in step 5, I'd recommend verifying this setting is correct)  
    Back in the ≡ menu, then Administration -> Dashboard, then Server -> Playback, check the "FFmpeg path" option. For me it's blank by default, so enter the path `C:\Program Files\Jellyfin\ffmpeg.exe` and click save all the way at the bottom of the page.

    **If on Server Core**, you'll likely get the worst error message yet:
    > We're unable to find FFmpeg using the path you've entered. FFprobe is also required and must exist in the same folder. These components are normally bundled together in the same download. Please check the path and try again.

    However, assuming you've followed the steps until now, they _are_ correctly installed there.

    What's actually happening here is that FFmpeg has an undocumented dependency on some DLLs that don't ship with Server Core. But of course, instead of providing any help or even just an error message when trying to run FFmpeg with any of these missing, it just silently crashes. Jellyfin then sees this, and surfaces a completely incorrect error message to you. No, I'm not salty, and definitely did not waste a bunch of time trying to troubleshoot this 🙃

    To fix this, grab these two files from a Windows 10/11 computer, or from a server running with a full desktop environment (non-Core), and copy them to the same location on the VM where Jellyfin is running:
    - `C:\Windows\System32\AVICAP32.dll`
    - `C:\Windows\System32\MSVFW32.dll`  
    ([Info found here](https://superuser.com/questions/1742768/FFmpeg-on-windows-server-core-2022))  

    After doing this, you'll need to attempt setting the FFmpeg path option in Jellyfin again, except this time it should work.

7) Other customizations  
    At this point you can do all of the other customizations you'd like as well. [Make sure to give the custom CSS field a try to really enjoy some janky UI.](https://twitter.com/MacylerJank/status/1632450092170084354) I'd recommend leaving the ports as default if you plan to set up IIS or another reverse proxy. Note that if you change the port, install plugins, or make certain other changes, Jellyfin needs to be restarted. This is as easy as:
    ```powershell
    Restart-Service 'JellyfinServer'
    ```

## 5. Install IIS
1) Installing IIS  
    ```powershell
    Install-WindowsFeature -Name 'Web-Server','Web-Http-Redirect','Web-WebSockets','Web-Mgmt-Service','NET-Framework-45-ASPNET'
    ```
2) Downloading add-ons  
    There's a few add-ons developed by Microsoft for IIS that we'll need as well:
    - [URL Rewrite](https://www.iis.net/downloads/microsoft/url-rewrite)
    - [Application Request Routing](https://www.iis.net/downloads/microsoft/application-request-routing)
    
    Get the direct links to the x64 MSI installers for these two from those pages, then download them on the server just like you did for Jellyfin itself.  
    At the time of writing, these links pointed to the newest versions of both (URL Rewrite 2.1, ARR 3.0). Check that's still the case **before copy-pasting this**:
    ```powershell
    Invoke-WebRequest 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' -OutFile 'rewrite_amd64_en-US.msi' -UseBasicParsing
    Invoke-WebRequest 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi' -OutFile 'requestRouter_amd64.msi' -UseBasicParsing
    ```
3) Installing add-ons  
    Nice and simple, just make sure you do these in the correct order:
    ```powershell
    & msiexec /i rewrite_amd64_en-US.msi /qn /norestart
    & msiexec /i requestRouter_amd64.msi /qn /norestart
    Restart-Service 'w3svc' # This restarts IIS
    ```
    Maybe at some point Microsoft will stop neglecting the MSI system and add a proper PowerShell cmdlet to make these commands nicer. But probably not.

## 6. Configure IIS
⚠ **DISCLAIMER: I am far from an IIS expert, and some of this information may be wrong, suboptimal, or have negative security implications. Please let me know if so and I'll update the guide.**
1) Proxy configuration  
    This is taken directly from the [official Jellyfin docs](https://jellyfin.org/docs/general/networking/iis/), and worked fine for me:
    ```powershell
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name 'enabled' -Value 'True'
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy/cache' -Name 'enabled' -Value 'False'
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name 'httpVersion' -Value 'Http11'
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name 'preserveHostHeader' -Value 'True'

    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -Value @{name='HTTP_X_FORWARDED_PROTOCOL'}
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -Value @{name='HTTP_X_FORWARDED_PROTO'}
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -Value @{name='HTTP_X_REAL_IP'}
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -Value @{name='HTTP_X_FORWARDED_HOST'}
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/rewrite/allowedServerVariables' -Name '.' -Value @{name='HTTP_X_FORWARDED_PORT'}
    ```

2) Rewrite & Header configuration  
    This was taken from the same documentation page as the previous step, but I've made a copy in this repository with de-jankified indenting for convenience.  
    If you changed the port Jellyfin accepts HTTP connections on, you'll need to edit line 54 to point to the correct port.  
    You'll need to just copy this to the default site's wwwroot folder (make sure to change this to the correct one if you are running other sites on this IIS server!)
    ```powershell
    cd '~/Downloads'
    Invoke-WebRequest 'https://github.com/CaiB/Jellyfin-IIS-Snarky-Guide/raw/main/web.config' -OutFile 'web.config' -UseBasicParsing
    Copy-Item '.\web.config' 'C:\inetpub\wwwroot\'
    Restart-Service 'w3svc'
    ```
    Now, if you attempt to access the IIS server on the regular HTTP port 80 using a web browser on another computer, it should result in you seeing the Jellyfin web UI as before. This means IIS is correctly forwarding your traffic. Note that HTTPS/port 443 won't work until you configure a SSL certificate, which we'll do later.

3) Configure cryptography  
    I strongly recommend disabling the use of outdated protocols and cipher modes to strengthen security. To make this easy, Nartac Software makes a free tool called IIS Crypto that we'll use.  
    If you have easy GUI access to the server VM, I'd recommend downloading the GUI version of the tool, applying the template as explained below, and also having a look around the software to gain a better understanding of the options and what they mean. I'm a strong believer in using a good GUI to learn about what you are doing (even if the rest of this guide didn't seem that way). On Windows we're lucky enough to have the option of a nice GUI for some tasks, so use it.

    There are different configuration templates you can pick, based on your needs:
    | GUI Name | CLI Name | Description |
    |---|---|---|
    | Best Practices | `best` | Useful if you plan to use some older clients/devices that don't support the most modern security, like Android devices, smart TVs, a bathtub, etc.
    | PCI 4.0 | `pci40` | Use this if you only plan to use modern clients/devices and aren't worried about backwards compatibility. |
    | Strict | `strict` | Use this if you are paranoid and require only the absolute best. I haven't tested this one. |

    **If using the GUI**, download and run the program (double-check the download link is still correct for the newest version):
    ```powershell
    cd '~/Downloads'
    Invoke-WebRequest 'https://www.nartac.com/Downloads/IISCrypto/IISCrypto.exe' -OutFile 'IISCrypto.exe' -UseBasicParsing
    & .\IISCrypto.exe
    ```
    Then use the "Templates" tab on the left, pick your template, and apply it. A reboot is likely not required. However, restarting IIS with `Restart-Service 'w3svc'` may not be a bad idea.

    **If not using the GUI**, download and use the program to apply the template you've selected from the table above:
    ```powershell
    cd '~/Downloads'
    Invoke-WebRequest 'https://www.nartac.com/Downloads/IISCrypto/IISCryptoCli.exe' -OutFile 'IISCryptoCli.exe' -UseBasicParsing
    & .\IISCryptoCli.exe /template {TEMPLATE}
    Restart-Service 'w3svc'
    ```

## 7. Going Public
1) Port forwarding  
    At this point, Jellyfin is fully set up to be used on the local network, and IIS is almost ready. If you want it to be internet-accessible as well (which I assume you would after setting up IIS), you'll need to edit your router's configuration to create a port forwarding rule to port 443 (HTTPS) on the server running IIS.  
    You can directly forward external port 443, but if you have other web services, or just want to cut down on the amount of spam traffic coming into your network, I'd suggest using a nonstandard port, ideally above 1024.  
    This is left as an exercise to the reader, as every router is different and you know your network/equipment best.
2) DNS  
    Assuming you want to access your server via a nice name, rather than an IP address that may change, you should either buy and use a domain, or use a free DNS service (with some caveats).  
    This procedure depends on your domain and your DNS provider, so look at their documentation on how to set this up.

## 8. SSL Certificate
1) Download Posh-ACME  
    We'll be using [Posh-ACME](https://github.com/rmbolger/Posh-ACME) to manage the SSL certificate and auto-renew it from [Let's Encrypt](https://letsencrypt.org/). Start by installing these 2 modules:
    ```powershell
    # You'll get some some confirmation prompts when running these.
    Install-Module -Name 'Posh-ACME' -Scope CurrentUser
    Install-Module -Name 'Posh-ACME.Deploy' -Scope CurrentUser
    Import-Module Posh-ACME
    ```
    If you got an error when doing `Import-Module`, you'll need to change your PowerShell execution policy to a less restrictive one, then try again:
    ```powershell
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Import-Module Posh-ACME
    ```

2) Determine authentication method  
    There are 2 main ways that you can authenticate ownership of your domain, which is required to get the SSL certificate:
    - HTTP: this only works if your server is publicly accessible on port 80/443. I use a custom port, so cannot use this, but if you can, it'll be somewhat easier.
    - DNS: this works even if your server is not publicly accessible at all, or on a non-standard port. You'll need to [ensure Posh-ACME has a plugin](https://poshac.me/docs/v4/Plugins/) that works with your DNS provider for the domain you're using. If not, you can either write one (like I did), request the creator of Posh-ACME write one for you, or consider using software other than Posh-ACME.

3) Set up the certificate  
    You should only need to do this once. To set up the certificate, start by choosing your SSL certificate provider (I use Let's Encrypt), reading their TOS, and requesting a certificate.  
    For DNS authentication using a specific Posh-ACME plugin, use this:
    ```powershell
    New-PAAccount -AcceptTOS -Contact '{YOUR VALID EMAIL}' -UseAltPluginEncryption
    $PluginArgs = @{ ... } # See the plugin's documentation page for what is needed here
    $Cert = New-PACertificate '{YOUR DOMAIN NAME}' -Plugin '{NAME OF PLUGIN}' -PluginArgs $PluginArgs
    # This could take a few minutes, as it takes time for DNS changes to apply.
    ```
    Note that your email will only be used to notify you if the certificate is expiring (i.e. your auto-renewal is failing for some reason).

4) Apply the certificate and enable HTTPS  
    Make sure to change `'Default Web Site'` below if you used a different site name when configuring IIS, or if there are multiple sites on this IIS server.  
    This will also enable HTTPS/port 443 on your IIS server.
    ```powershell
    $Cert | Set-IISCertificate -SiteName 'Default Web Site' -Verbose
    ```

5) Test HTTPS  
    Once you have your HTTPS port forwarded, try connecting to your domain/port over HTTPS from a device on another internet connection (such as a phone on a mobile network, or a computer with VPN software enabled - yeah that stuff that every YouTuber is shilling without even understanding what they're peddling).  
    You should be able to access Jellyfin over HTTPS, and should see a valid certificate issued by Let's Encrypt on the webpage.  
    You may also notice that Jellyfin can (and as such will) now request permission to send you notifications when you get to the site, before you've even logged in. [This is "intended" behaviour](https://old.reddit.com/r/jellyfin/comments/10wktfp/jellyfinweb_completely_disable_notifications_api/j7o0q94/), and you cannot disable it.

## 9. Certificate Auto-Renewal
1) Download the scripts  
    For convenience, I've included a pair of simple scripts in this repository that you can download, edit, and use for certificate renewal.
    ```powershell
    cd '~/Documents'
    Invoke-WebRequest 'https://github.com/CaiB/Jellyfin-IIS-Snarky-Guide/raw/main/Update-IISCert.ps1' -OutFile 'Update-IISCert.ps1' -UseBasicParsing
    Invoke-WebRequest 'https://github.com/CaiB/Jellyfin-IIS-Snarky-Guide/raw/main/Update-IISCert-ToFile.ps1' -OutFile 'Update-IISCert-ToFile.ps1' -UseBasicParsing
    ```

    The `-ToFile.ps1` script just invokes the main script, redirecting output to a log file. This will be used in a moment when we make the renewal process a scheduled task.

2) Set options  
    You'll need to make the following changes to the `Update-IISCert.ps1` script:
    - Line 1: Set your domain name
    - Line 2: Set your IIS site name if it is not the default (only if you configured the IIS server differently from this guide)
    - Line 7/8: Toggle these if you'd like to use the testing server (not needed if just testing once, but Let's Encrypt has pretty strict limits on the number of failed attempts per hour)

3) Scheduled task  
    This creates a task in the Windows Task Scheduler so that your certificate gets checked every morning, and if it needs renewal, that is done. Make sure to edit the lines below to replace all 3 config-specific details.
    ```powershell
    $Action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy RemoteSigned .\Update-IISCert-ToFile.ps1' -WorkingDirectory 'C:\Users\{ADMIN}\Documents\'
    $Trigger = New-ScheduledTaskTrigger -Daily -At '4AM'
    $TaskSettings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable
    Register-ScheduledTask -Action $Action -Trigger $Trigger -User '{DOMAIN}\{ADMIN}' -Password '{PASSWORD}' -RunLevel 'Highest' -Settings $TaskSettings -TaskName 'IIS Certificate Update'
    ```
4) Force renewal  
    We want to run the scheduled task to make sure it's working correctly, but our certificate is brand new. Just for this one time, you'll want to edit line 11 in `Update-IISCert.ps1` to add a `-Force`, so that it looks like this:
    ```powershell
    if ($NewCert = Submit-Renewal -Verbose -Force)
    ```
    This forces the certificate renewal to happen, even if the certificate is not yet due for a renewal. We're doing this to verify that both the renewal and installation process work, because otherwise it'd just exit immediately.
5) Run the task  
    ```powershell
    Start-ScheduledTask -TaskName 'IIS Certificate Update'
    # Wait about 10 seconds or so before running:
    Get-Content '~\Documents\IISCertUpdateLog.txt'
    ```
    Check to make sure there's no errors, and that the file ends with the line `Done!` (otherwise wait some more and check again)
6) Remove forced renewal  
    The opposite of step 4 above, just go back and remove the `-Force` from the script again. There's no reason to actually renew the certificate every day, since Let's Encrypt certificates expire after 90 days.

## Finale
You're done. Hopefully you've got a fully working Jellyfin + IIS setup now.

Thanks for reading my guide. Like mentioned previously, if you found any mistakes in this guide, please open an issue here on GitHub and I'll try to fix it. Enjoy your new media server!
