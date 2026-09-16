================================================================================
  TWO-FINGER SCROLL FOR THE APPLE MAGIC MOUSE (2024, USB-C) ON WINDOWS
  Community test build 2.0.4.3        Read this page, then run one file.
================================================================================

WHAT THIS IS

  Windows pairs the 2024 Magic Mouse over Bluetooth and moves the pointer, but
  the glass surface does nothing. This package adds a small kernel filter
  driver that turns a two-finger swipe on the glass into real scrolling
  (vertical wheel and horizontal pan). One finger keeps doing nothing, which is
  what you want - it stops the pointer scrolling while you rest a finger.

  It works on Windows 10 and Windows 11, 64-bit only, and it binds to EXACTLY
  ONE device: the Magic Mouse with Bluetooth product id 0323 (the 2024 / USB-C
  model). Magic Mouse v1 (030D) and v2 (0269 / 0310) are not supported and the
  driver will not attach to them.

  What it does NOT do: macOS-style gestures, Mission Control, swipe between
  desktops, pinch to zoom, or Windows Precision Touchpad behaviour. Pointer,
  battery level and two-finger scroll. That is the whole feature list.


THE HONEST PART: YOU HAVE TO PUT WINDOWS IN TEST MODE

  Windows only loads kernel drivers that carry a signature it already trusts.
  The driver file in this folder is deliberately shipped UNSIGNED. During setup
  your PC creates its own code-signing certificate, trusts it locally, and
  signs the driver with it. Nothing is uploaded, no key from anyone else is
  installed, and the signing key never leaves your machine.

  The price of a self-made signature is that Windows will not accept it in
  normal mode. So setup turns on Test Mode:

      bcdedit /set testsigning on

  and for that to stick you must have BOTH of these OFF beforehand:

      * Secure Boot            - firmware / BIOS setup screen
      * Memory integrity       - Windows Security > Device security >
                                 Core isolation

  While Test Mode is on, Windows shows a small "Test Mode" watermark in the
  bottom-right corner of the desktop. That is normal and only cosmetic.

  Turning Test Mode off again:   bcdedit /set testsigning off   then reboot.

  This requirement is NOT a design choice we like. Removing it needs a
  commercial EV code-signing certificate plus Microsoft Partner Center
  attestation signing, which would produce a driver that installs with Secure
  Boot left on. That work is tracked as issue #23 and has not been done.

  Do not do this on a work or school PC that requires Secure Boot, or on a PC
  with BitLocker where you do not have the recovery key to hand.


WHAT TO RUN - THERE IS ONLY ONE THING

      Double-click:   Setup-Community.cmd

  That is it. Do not open PowerShell, do not right-click anything, do not
  change an execution policy. It asks for Administrator itself and everything
  after that is automatic. Extract the whole ZIP to a folder first - running it
  from inside the ZIP viewer cannot work.

  THERE IS ONE RESTART IN THE MIDDLE. Test Mode only takes effect after a
  reboot, so the wizard stops and tells you to restart. After the restart,
  DOUBLE-CLICK Setup-Community.cmd AGAIN. It remembers what it already did and
  carries on from there.

  Setup copies what it needs into C:\ProgramData\MagicMouseDriver and signs it
  there. It never writes into this folder, so your download stays exactly as
  downloaded and you can re-run it from a fresh copy at any time.


THE SEVEN PHASES, SO YOU CAN SEE WHERE YOU ARE

  1  Preflight       Checks Windows version, 64-bit, Administrator, that a
                     Magic Mouse 0323 is paired, and that the files in this
                     folder are the right ones.
  2  Certificate     Creates the code-signing certificate on this PC and
                     trusts it.
  3  TestSigning     Turns Test Mode on.  <-- RESTART HAPPENS HERE, then run
                     Setup-Community.cmd again.
  4  SignPackage     Builds the driver catalogue and signs the driver with
                     your certificate.
  5  InstallDriver   Installs the driver package and restarts the mouse
                     device so it picks it up.
  6  EnableTouch     Switches the mouse into multitouch mode and installs a
                     small scheduled task so scroll survives switching the
                     mouse off, re-pairing it, and rebooting.
  7  Verify          Checks the service, the driver package, the device
                     status and the driver's own counters, then prints
                     PASS or FAIL.

  The wizard records progress in
      C:\ProgramData\MagicMouseDriver\community-setup-state.json
  and writes a detailed log next to it in install.log.


HOW TO CHECK IT ACTUALLY WORKED

  1. Move the mouse on the desk. The pointer must still move normally.
  2. Put TWO fingers on the glass and swipe up and down. The page must scroll.
     Sideways should pan.
  3. Put ONE finger on the glass and move it. Nothing must scroll.
  4. Turn the mouse off and on again, then repeat 1-3. Scroll must still work.
  5. Restart Windows, then repeat 1-3. Scroll must still work.

  If two-finger scroll feels too twitchy or too heavy, it is tunable without
  reinstalling anything. From an Administrator PowerShell in this folder:

      scripts\mm-scroll-tune.ps1 -ScrollStep 16

  Higher number = less sensitive. The default is 8. Valid range 1 to 224.


HOW TO UNINSTALL

  Double-click:   Uninstall-KMDF.cmd

  That removes only this driver package and its service, and leaves any other
  Apple mouse driver on the PC alone. It does NOT turn Test Mode back off and
  it does NOT delete the certificate your PC made - both of those are left to
  you, on purpose:

      bcdedit /set testsigning off        (Administrator, then reboot)
      certlm.msc                          to remove the certificate from
                                          Trusted Publishers and Trusted Root


PLEASE TELL US HOW IT WENT - WORKING OR NOT

  https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix/issues

  Useful to include: your Windows version, whether Secure Boot and Memory
  integrity were off, the phase it reached, whether the Test Mode watermark
  appeared, and the last 30 lines of
  C:\ProgramData\MagicMouseDriver\install.log.


STATUS - READ THIS BEFORE YOU DECIDE

  This driver has only ever been tested on the developer's own PC, with one
  Magic Mouse. Nobody else's machine has run it yet. It is a kernel-mode
  driver, so a bad interaction can mean a crash or an unbootable-looking PC
  (Test Mode can be switched off from Windows recovery, but you should be
  comfortable with that before starting). Treat this as an experiment you are
  volunteering for, not a finished product.

  MagicMouseDriver-kmdf-204-scroll.sys in this folder is UNSIGNED by design;
  SHA256SUMS.txt lists what every file should hash to, and you can check any of
  them yourself with:

      certutil -hashfile MagicMouseDriver-kmdf-204-scroll.sys SHA256

  Licence: MIT. Source, issues and the full documentation are in the repository
  linked above.
