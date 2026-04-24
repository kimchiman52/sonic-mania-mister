sonic-mania-mister — Sonic Mania for MiSTer FPGA
=================================================

A hybrid ARM + FPGA port of Sonic Mania running on the MiSTer DE10-Nano.
Game logic runs on the ARM CPU via the upstream RSDKv5 engine; the FPGA
handles native 320x240 video output, audio buffering, and DAC conversion.

This is an experimental release. Expect rough edges.


REQUIREMENTS
------------

You need a copy of Data.rsdk, the Sonic Mania asset archive. This file
ships with retail copies of Sonic Mania (Steam, GOG, console releases).
You must legally own the game.

Locate the file in your Sonic Mania installation directory:

  Steam:  steamapps/common/Sonic Mania/Data.rsdk
  GOG:    GOG Galaxy/Games/Sonic Mania/Data.rsdk

The file is around 200 MB.


INSTALLATION
------------

1. Extract this ZIP onto the ROOT of your MiSTer SD card.

   The archive is structured so files land in the right places:

     /media/fat/MiSTer_SonicMania              (HPS wrapper)
     /media/fat/_Other/Sonic Mania.rbf         (FPGA bitstream)
     /media/fat/games/sonic-mania/bin/RSDKv5U  (game engine binary)
     /media/fat/games/sonic-mania/lib/         (bundled libtheora)
     /media/fat/games/sonic-mania/scripts/     (launcher)
     /media/fat/games/sonic-mania/saves/       (engine save dir)

   ** FTP users: ** If transferring files via FileZilla or another
   FTP client, set the transfer type to Binary (not Auto or ASCII).
   The default mode corrupts extensionless binaries like
   MiSTer_SonicMania and RSDKv5U, causing the core to crash on launch.

2. Place your Data.rsdk file here:

     /media/fat/games/sonic-mania/Data.rsdk

3. Edit /media/fat/MiSTer.ini and add the following section:

     [Sonic Mania]
     main=MiSTer_SonicMania
     vga_scaler=0


CRT TROUBLESHOOTING
-------------------

The native video path outputs at 320x240 progressive, ~59.59 Hz, 6.151
MHz pixel clock. Most 15 kHz CRTs and arcade monitors should sync
directly with vga_scaler=0 (the required default).

vga_scaler=0 is REQUIRED for S-Video color output. If the section
inherits a global vga_scaler=1, the FPGA will route the HDMI scaler's
plain RGB to the VGA DAC, producing grayscale S-Video and a wrong
aspect ratio.

If you cannot get sync at all, try the MiSTer scaler path (no native
YC color, but more flexible timing):

     [Sonic Mania]
     main=MiSTer_SonicMania
     vga_scaler=1
     video_mode=320,16,32,48,240,8,3,17,6151

If your CRT expects composite sync, also add composite_sync=1 to the
[Sonic Mania] section.


RUNNING
-------

1. Boot MiSTer normally.
2. Navigate to the "Other" core folder.
3. Launch "Sonic Mania".

If the core immediately exits back to MiSTer, the most common cause is
a missing Data.rsdk file at /media/fat/games/sonic-mania/Data.rsdk.

Check the wrapper log for the precise reason:
  /media/fat/games/sonic-mania/logs/osd-wrapper.log

The engine log also lands at:
  /media/fat/games/sonic-mania/logs/last-run.log
  /media/fat/games/sonic-mania/log.txt


SAVES AND SETTINGS
------------------

Game saves, replays, and Settings.ini are written to:

  /media/fat/games/sonic-mania/saves/

The directory is created automatically on first launch. Future
release upgrades replace bin/, lib/, and scripts/ but never touch
saves/ or Data.rsdk, so your progress is preserved.

For per-controller rebinding, use the in-game Options -> Controls
menu. SDL2-level controller mapping overrides can be supplied by
dropping a custom gamecontrollerdb.txt into the saves/ directory.


KNOWN LIMITATIONS
-----------------

- Cutscenes (intro, level transitions) currently render black with
  audio only. CPU YUV->RGB565 conversion in the MiSTer render device
  is stubbed pending a future release.
- Widescreen mode is disabled. Native render width is fixed at 320
  pixels to match the FPGA core.
- The MiSTer OSD overlay (F12 menu) cannot be reached while Sonic
  Mania is running. Exit the core first to access the OSD.


MORE INFORMATION
----------------

Source code, build instructions, and full technical documentation:
  https://github.com/kimchiman52/sonic-mania-mister

Upstream RSDKv5 engine:
  https://github.com/RSDKModding/RSDKv5-Decompilation

This project is licensed under the GNU General Public License v3.
Sonic Mania is the property of SEGA. This project does not contain
or distribute any copyrighted Sonic Mania asset data.
