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

1. Extract this ZIP into the FAT partition of your MiSTer SD card.
   The end result should be:
     <fat>/MiSTer_SonicMania
     <fat>/_Other/Sonic_Mania*.rbf
     <fat>/games/sonic-mania/...

   Where <fat> is:
     - The SD card root  (if the card is plugged into your PC/Mac —
       the partition shows up as e.g. D:\ on Windows or
       /Volumes/MISTER/ on macOS)
     - /media/fat/        (if you are FTPing/SFTPing into a running
       MiSTer — do NOT extract to "/", that's the Linux root)

   FTP/SFTP users: set transfer type to Binary, not Auto. Default
   mode corrupts extensionless binaries.

2. Place Data.rsdk at /media/fat/games/sonic-mania/Data.rsdk

3. Add to /media/fat/MiSTer.ini:

     [Sonic Mania]
     main=MiSTer_SonicMania

     [Sonic Mania (4:3)]
     main=MiSTer_SonicMania

4. Boot MiSTer, navigate to Other, launch "Sonic Mania" (16:9 HDMI)
   or "Sonic Mania (4:3)" (CRT).
