sonic-mania-mister — Sonic Mania for MiSTer FPGA
==================================================

A port of Sonic Mania for the MiSTer DE10-Nano. Experimental release.

For background, AI disclosure, and known issues, see the project page:
  https://github.com/kimchiman52/sonic-mania-mister


REQUIREMENTS
------------

A copy of Data.rsdk (Sonic Mania asset archive, ~200 MB) from any
retail copy of the game (Steam, GOG, Epic, console). You must legally
own the game.


INSTALLATION
------------

1. Extract this ZIP onto the ROOT of your MiSTer SD card. Files land
   under /media/fat/MiSTer_SonicMania, /media/fat/_Other/Sonic_Mania*.rbf,
   and /media/fat/games/sonic-mania/.

   FTP users: set transfer type to Binary, not Auto. Default mode
   corrupts extensionless binaries.

2. Place Data.rsdk at /media/fat/games/sonic-mania/Data.rsdk

3. Add to /media/fat/MiSTer.ini:

     [Sonic Mania]
     main=MiSTer_SonicMania

     [Sonic Mania (4:3)]
     main=MiSTer_SonicMania

4. Boot MiSTer, navigate to Other, launch "Sonic Mania" (16:9 HDMI)
   or "Sonic Mania (4:3)" (CRT).
