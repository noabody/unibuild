# Information about makefile skeletons.

Many source projects do not require the package management system for installation.  This does not mean that they can't or should not be installed globally but, certainly, some work will be required to make that happen.

## Creating the *install:* section of a makefile.

This is the most likely scenario, a makefile exists but lacks ```make install``` .  The user will have to determine what files are required to make the software functional and where they should be placed.

Often the readme, that accompanies a project, contains this information.  Sometimes a built project is available for download via third party website or even the package management system.  File-roller can be used to examine debs or other archives, including those for other targets.

The target install location for both autoconf and cmake can be specified on the command line.  By using ```usr``` instead of ```/usr```, followed by ``` make install```, the normal install will redirect to the current folder which is a great way to determine how the project groups files and folders.

```shell
(autogen)
./configure --prefix=usr

(cmake)
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=usr ..
```
The important thing to do is build a map of what needs to go where.

## How does one handle a project that has more than a self-contained binary?

It'd be nice if the output of ```make all``` was a single file that could be installed to ```/usr/bin```.  How do we handle situations where this isn't the case?  The patch I made for **Blastem** is a prime example of the complication required to make some projects work as a global install.

```diff
diff -r 31effaadf877 Makefile
--- a/Makefile	Fri Jun 22 23:10:27 2018 -0700
+++ b/Makefile	Fri Jul 06 20:50:10 2018 -0600
@@ -281,3 +281,34 @@
 
 clean :
 	rm -rf $(ALL) trans ztestrun ztestgen *.o nuklear_ui/*.o zlib/*.o
+
+# paths
+prefix := /usr
+name := blastem
+bindir := $(prefix)/share/$(name)
+icondir := $(prefix)/share/icons/hicolor/scalable/apps
+
+install:
+	mkdir -p $(prefix)/bin/
+	mkdir -p $(prefix)/share/applications/
+	mkdir -p $(icondir)/
+	mkdir -p $(bindir)/shaders/
+	mkdir -p $(bindir)/images/
+	cp $(name) $(bindir)/$(name)-bin
+	install -m 755 $(name).sh $(prefix)/bin/$(name)
+	cp $(name).desktop $(prefix)/share/applications/$(name).desktop
+	cp CHANGELOG $(bindir)/CHANGELOG
+	cp COPYING $(bindir)/COPYING
+	cp default.cfg $(bindir)/default.cfg
+	cp dis $(bindir)/dis
+	cp gamecontrollerdb.txt $(bindir)/gamecontrollerdb.txt
+	cp menu.bin $(bindir)/menu.bin
+	cp README $(bindir)/README
+	cp rom.db $(bindir)/rom.db
+	cp stateview $(bindir)/stateview
+	cp termhelper $(bindir)/termhelper
+	cp vgmplay $(bindir)/vgmplay
+	cp zdis $(bindir)/zdis
+	cp shaders/* $(bindir)/shaders/
+	cp images/* $(bindir)/images/
+	convert icons/windows.ico $(icondir)/$(name).svg
diff -r 31effaadf877 blastem.desktop
--- /dev/null	Thu Jan 01 00:00:00 1970 +0000
+++ b/blastem.desktop	Fri Jul 06 20:50:10 2018 -0600
@@ -0,0 +1,10 @@
+[Desktop Entry]
+Name=blastem
+Comment=Fast and accurate Genesis emulator
+Keywords=game;console;
+Exec=blastem
+Icon=blastem
+Terminal=false
+Type=Application
+Categories=GNOME;GTK;Game;
+StartupNotify=false
diff -r 31effaadf877 blastem.sh
--- /dev/null	Thu Jan 01 00:00:00 1970 +0000
+++ b/blastem.sh	Fri Jul 06 20:50:10 2018 -0600
@@ -0,0 +1,8 @@
+#!/bin/bash
+gmcfg="$HOME/.config/blastem"
+
+test -d "$gmcfg" || mkdir -p "$gmcfg"
+test -f "$gmcfg/blastem.cfg" || cp /usr/share/blastem/default.cfg "$gmcfg/blastem.cfg"
+test -f "$gmcfg/rom.db" || cp /usr/share/blastem/rom.db "$gmcfg/rom.db"
+test -d "$gmcfg/shaders" || ln -sf /usr/share/blastem/shaders/ "$gmcfg/shaders"
+/usr/share/blastem/blastem-bin $@
```
- This patch is composed of three sections.  The first adds an *install:* directive to the existing makefile, the second creates a desktop file for the menu and the third is a bash script that will be installed in ```/usr/bin```.  This script will create the necessary environment for *Blastem* to run properly.

- Notice that *Blastem* itself is wholly installed to ```/usr/share/blastem```.  That is our baseline and it's necessary because the *Blastem* executable needs to be nestled within those files and folders that resulted from build.

- Once installed globally, the program loses file-system write access.  As such, a bash script is needed to copy certain components from ```/usr/share/blastem``` to ```$HOME/.config/blastem```.

- ```default.cfg``` is renamed to ```blastem.cfg```.  It and ```rom.db``` are copied into ```$HOME/.config/blastem``` and the ```shaders``` folder is sym-linked to this location.

- The bulk of *Blastem* is contained and run from a global location and only those files that need write-access are copied over.

- We test for the existence of necessary files and only copy as required **not on every run**.

- The bash script bears the name of our program, *Blastem*, while it is renamed to ```/usr/share/blastem/blastem-bin```.  The final line of script points to the actual binary and passes all command line arguments to it.

## What about CMake?
The previous example was of a general *Makefile, GNUMakefile, makefile*. How about CMakeListst.txt?  A fairly straightforward example of this is:
```diff
diff --git a/CMakeLists.txt b/CMakeLists.txt
index 307c448..62f5150 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -17,6 +17,99 @@ INCLUDE_DIRECTORIES(
 	engine
 )
 
+include(GNUInstallDirs)
+
+set(PROGRAM_PERMISSIONS_DEFAULT
+    OWNER_WRITE OWNER_READ OWNER_EXECUTE
+    GROUP_READ GROUP_EXECUTE
+    WORLD_READ WORLD_EXECUTE)
+
+IF(PREFIX)
+	SET(CMAKE_INSTALL_PREFIX ${PREFIX})
+	# cmake 3 makes internal use of this variable ...
+	UNSET(PREFIX)
+	UNSET(PREFIX CACHE)
+ENDIF(PREFIX)
+
+if (NOT LAYOUT)
+	if (WIN32)
+		set(LAYOUT "home")
+	elseif (APPLE)
+		set(LAYOUT "bundle")
+		# favor mac frameworks over unix libraries
+		set(CMAKE_FIND_FRAMEWORK FIRST)
+	else (APPLE)
+		set(LAYOUT "fhs")
+	endif (WIN32)
+endif (NOT LAYOUT)
+
+SET(LAYOUT "${LAYOUT}" CACHE STRING "Directory layout.")
+
+# macro that sets a default (path) if one wasn't specified
+MACRO(SET_PATH variable default)
+	IF(NOT ${variable})
+		SET(${variable} ${default})
+	ENDIF(NOT ${variable})
+ENDMACRO(SET_PATH)
+
+if (${LAYOUT} MATCHES "home")
+	SET_PATH( PLUGIN_DIR ${CMAKE_INSTALL_PREFIX}/plugins )
+	SET_PATH( DATA_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( MAN_DIR ${CMAKE_INSTALL_PREFIX}/man/man6 )
+	SET_PATH( BIN_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( GAME_DIR ${CMAKE_INSTALL_PREFIX}/games )
+	SET_PATH( SYSCONF_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( LIB_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( DOC_DIR ${CMAKE_INSTALL_PREFIX}/doc )
+	SET_PATH( ICON_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( SVG_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( MENU_DIR ${CMAKE_INSTALL_PREFIX} )
+	SET_PATH( EXAMPLE_CONF_DIR ${CMAKE_INSTALL_PREFIX} )
+elseif (${LAYOUT} MATCHES "fhs")
+	SET_PATH( LIB_DIR ${CMAKE_INSTALL_PREFIX}/lib/fteqw )
+	SET_PATH( PLUGIN_DIR ${LIB_DIR}/plugins )
+	SET_PATH( DATA_DIR ${CMAKE_INSTALL_PREFIX}/share/fteqw )
+	SET_PATH( MAN_DIR ${CMAKE_INSTALL_PREFIX}/share/man/man6 )
+	SET_PATH( BIN_DIR ${CMAKE_INSTALL_PREFIX}/bin )
+	SET_PATH( GAME_DIR ${CMAKE_INSTALL_PREFIX}/games )
+	IF( NOT SYSCONF_DIR )
+		if ( ${CMAKE_INSTALL_PREFIX} STREQUAL "/usr" )
+			SET( SYSCONF_DIR /etc/fteqw )
+		else ()
+			SET( SYSCONF_DIR ${CMAKE_INSTALL_PREFIX}/etc/fteqw )
+		endif ()
+	ENDIF( NOT SYSCONF_DIR )
+	SET_PATH( DOC_DIR ${CMAKE_INSTALL_PREFIX}/share/doc/fteqw )
+	SET_PATH( ICON_DIR ${CMAKE_INSTALL_PREFIX}/share/pixmaps )
+	SET_PATH( SVG_DIR ${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/scalable/apps )
+	SET_PATH( MENU_DIR ${CMAKE_INSTALL_PREFIX}/share/applications )
+	SET_PATH( EXAMPLE_CONF_DIR ${SYSCONF_DIR} )
+elseif (${LAYOUT} MATCHES "opt")
+	SET_PATH( LIB_DIR ${CMAKE_INSTALL_PREFIX}/lib )
+	SET_PATH( PLUGIN_DIR ${LIB_DIR}/plugins )
+	SET_PATH( DATA_DIR ${CMAKE_INSTALL_PREFIX}/share/ )
+	SET_PATH( MAN_DIR ${CMAKE_INSTALL_PREFIX}/man/man6 )
+	SET_PATH( BIN_DIR ${CMAKE_INSTALL_PREFIX}/bin )
+	SET_PATH( GAME_DIR ${CMAKE_INSTALL_PREFIX}/games )
+	SET_PATH( SYSCONF_DIR ${CMAKE_INSTALL_PREFIX}/etc )
+	SET_PATH( DOC_DIR ${CMAKE_INSTALL_PREFIX}/share/doc/fteqw )
+	SET_PATH( ICON_DIR ${CMAKE_INSTALL_PREFIX}/share/pixmaps )
+	SET_PATH( SVG_DIR ${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/scalable/apps )
+	SET_PATH( MENU_DIR ${CMAKE_INSTALL_PREFIX}/share/applications )
+	SET_PATH( EXAMPLE_CONF_DIR ${SYSCONF_DIR} )
+else (${LAYOUT} MATCHES "bundle") # Mac or iOS
+	SET(CMAKE_INSTALL_RPATH @loader_path/../Frameworks)
+	SET(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE) 
+	# most paths are irrelevant since the items will be bundled with application
+	SET_PATH( BIN_DIR /Applications )
+	# TODO: these should be copied during build and not install.
+	SET_PATH( PLUGIN_DIR "${BIN_DIR}/${PROJECT_NAME}.app/Contents/Plugins" )
+	SET_PATH( DOC_DIR "${BIN_DIR}/${PROJECT_NAME}.app/Contents/Resources" )
+	SET_PATH( LIB_DIR @loader_path/../Frameworks )
+endif (${LAYOUT} MATCHES "home")
+# convert the slashes for windows' users' convenience
+file(TO_NATIVE_PATH ${PLUGIN_DIR} DEFAULT_PLUGINS_DIR)
+
 EXECUTE_PROCESS(COMMAND
 	"svnversion"
 	WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
@@ -635,3 +728,52 @@ ENDIF()
 
 #ffmpeg plugin
 #cef plugin
+
+macro(install_newdir newdir)
+  install(CODE "execute_process(COMMAND mkdir -p ${newdir})")
+endmacro()
+
+macro(install_icon iconpath filepath)
+  install(CODE "execute_process(COMMAND convert -background none -thumbnail 256x256 -flatten  ${iconpath} ${filepath})")
+  install(CODE "message(\"-- Converted icon: ${iconpath} -> ${filepath}\")")
+endmacro()
+
+macro(install_symlink filepath sympath)
+  install(CODE "execute_process(COMMAND ln -rsf  ${filepath} ${sympath})")
+  install(CODE "message(\"-- Created symlink: ${sympath} -> ${filepath}\")")
+endmacro()
+
+install(FILES fteqw.sh PERMISSIONS ${PROGRAM_PERMISSIONS_DEFAULT}
+	DESTINATION ${DATA_DIR})
+
+install(FILES ${CMAKE_CURRENT_BINARY_DIR}/fteqw PERMISSIONS ${PROGRAM_PERMISSIONS_DEFAULT}
+	DESTINATION ${DATA_DIR})
+
+install(FILES ${CMAKE_CURRENT_BINARY_DIR}/fteqw-sv PERMISSIONS ${PROGRAM_PERMISSIONS_DEFAULT}
+	DESTINATION ${DATA_DIR})
+
+install(FILES ${CMAKE_CURRENT_BINARY_DIR}/fteqcc PERMISSIONS ${PROGRAM_PERMISSIONS_DEFAULT}
+	DESTINATION ${DATA_DIR})
+
+install(FILES ${CMAKE_CURRENT_BINARY_DIR}/fteplug_ezhud.so
+	DESTINATION ${DATA_DIR} RENAME fteplug_ezhud_amd64.so)
+
+install(FILES ${CMAKE_CURRENT_BINARY_DIR}/fteplug_irc.so
+	DESTINATION ${DATA_DIR} RENAME fteplug_irc_amd64.so)
+
+install(FILES ${CMAKE_CURRENT_BINARY_DIR}/fteplug_qi.so
+	DESTINATION ${DATA_DIR} RENAME fteplug_qi_amd64.so)
+
+install_newdir(${SVG_DIR})
+
+install_newdir(${GAME_DIR})
+
+install_icon(${CMAKE_CURRENT_SOURCE_DIR}/engine/client/fte_eukaranopng.ico ${SVG_DIR}/fteqw.svg)
+
+install(FILES fteqw.desktop DESTINATION ${MENU_DIR})
+
+install_symlink(${DATA_DIR}/fteqw ${GAME_DIR}/fteqw)
+
+install_symlink(${DATA_DIR}/fteqw-sv ${GAME_DIR}/fteqw-sv)
+
+install_symlink(${DATA_DIR}/fteqcc ${GAME_DIR}/fteqcc)
```
I stole the path definitions from GemRB's CMakeLists.txt because they avoid using ```GNUInstallDirs```.  Beyond that there are a few macro definitions that work almost exactly like a makefile.  In other words, rather than fumble through cmake, let's use a tried and tested external command that is known to work.

The install files section sets permissions for all executables based on a global definition.

## Using a script to call the binary for game engines.

Game engines are unique in that they rarely contain a GUI, as opposed to emulators that most often do.  To reconcile this, it's necessary to institute a minimal startup wrapper.  The general structure is:

- Place engine files in /usr/share/game
- Icons and desktop files go in their usual location with the latter calling the game launcher script
- Sym-link binaries to /usr/bin

```diff
rm -rf build edge.sh edge.desktop && git reset --hard
patch -p1 < ../edge.patch
mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr ..
diff  a/edge.sh b/edge.sh
--- a/edge.sh	1969-12-31 17:00:00.000000000 -0700
+++ b/edge.sh	2018-08-08 12:41:13.390810041 -0600
@@ -0,0 +1,61 @@
+#!/bin/bash
+gmdir="$HOME/games/doom"
+gmcfg="$HOME/.EDGE2"
+gmtgt="doom.wad"
+gmprm="-file nerve.wad"
+glnch="edge"
+i_syms=()
+
+gconf () {
+test -d "$gmcfg" || mkdir -p "$gmcfg"
+echo -e "gamepath= $gmdir\ngamemod= $gmtgt\ngameparm= $gmprm" | tee "$gmcfg/basedir"
+}
+
+gstart () {
+readarray -t i_syms < <(find /usr/share/edge -type f,d \( -ipath '*_ddf' -o -iname '*.epk' \) -printf '%P\n')
+for i in ${!i_syms[@]}; do
+  test -h "$gmbdr/${i_syms[$i]}" || ln -sf "/usr/share/edge/${i_syms[$i]}" "$gmbdr/${i_syms[$i]}"
+done
+unset i_syms
+echo "cd $gmbdr && $glnch -config $gmbdr/EDGE.ini $gmgnm $gmpar" | xargs -i -r sh -c "{}"
+}
+
+gtest () {
+gmbse="$(grep -Pi '^gamepath=.*' "$gmcfg/basedir" | head -1)"
+gmgme="$(grep -Pi '^gamemod=.*' "$gmcfg/basedir" | head -1)"
+gmgpm="$(grep -Pi '^gameparm=.*' "$gmcfg/basedir" | head -1)"
+gmbdr="$(echo "$gmbse" | grep -Pio '(?<=gamepath= ).*')"
+gmgnm="$(echo "$gmgme" | grep -Pio '(?<=gamemod= ).*')"
+gmpar="$(echo "$gmgpm" | grep -Pio '(?<=gameparm= ).*')"
+gmgnm="${gmgnm,,}"
+}
+
+test -f "$gmcfg/basedir" || gconf
+gtest
+if [ -z "$gmbdr" ]; then
+  gconf
+  gtest
+fi
+if [ -d "$gmbdr" ]; then
+  if [ ! -f "$gmbdr/$gmgnm" ]; then
+    gmchk="$(find "$gmbdr" -mindepth 1 -maxdepth 1 -type f -regextype posix-extended -iregex "$gmbdr/$gmgnm" -printf '%p\n' | grep -Pic "$gmbdr/$gmgnm")"
+    if [ $gmchk -eq 1 ]; then
+      echo -e "File system is case sensitive\nFile/folder names must be lowercase\n Rename subdirs of\n  $gmbdr\n    containing\n  $gmtgt?\nRequires rename command" | xmessage -file - -buttons Yes,No -default No -center -timeout 30
+      test $? -eq 101 && find "$gmbdr" -depth -exec rename 's|([^/]*\Z)|lc($1)|e' {} +
+    elif [ $gmchk -gt 1 ]; then
+      echo -e "File system is case sensitive\nFile/folder names must be lowercase\n Cannot rename subdirs of\n  $gmbdr\n    containing\n  $gmtgt\n\nBecause more than one exists" | xmessage -file - -buttons Ok:0 -center -timeout 30
+    elif [ -z "$(echo "$gmgnm" | grep -Pio '\w+')" ] && [ -n "$(find "$gmbdr" -mindepth 1 -maxdepth 1 -type f -iname '*.wad' -printf '%f')" ]; then
+      gmgnm=""
+      gstart
+    else
+      echo -e "Config:\n $gmcfg/basedir\n  $gmbse\n found, but not\n  $gmgme\n ($gmbdr/$gmgnm)\n\nRebuild config?" | xmessage -file - -buttons Yes,No -default No -center -timeout 30
+      test $? -eq 101 && gconf
+    fi
+  else
+    gmgnm="-iwad $gmgnm"
+    gstart
+  fi
+else
+  echo -e "Config:\n $gmcfg/basedir\n  $gmbse\n not found\n\nRebuild config?" | xmessage -file - -buttons Yes,No -default No -center -timeout 30
+  test $? -eq 101 && gconf
+fi
diff --git a/edge.desktop b/edge.desktop
index e69de29..feb733a 100644
--- a/edge.desktop
+++ b/edge.desktop
@@ -0,0 +1,10 @@
+[Desktop Entry]
+Name=edge
+Comment=Advanced OpenGL DOOM engine source port.
+Keywords=game;engine;
+Exec=/usr/share/edge/edge.sh
+Icon=edge
+Terminal=false
+Type=Application
+Categories=GNOME;GTK;Game;
+StartupNotify=false
diff --git a/CMakeLists.txt b/CMakeLists.txt
index 355f153..26fbccf 100644
--- a/CMakeLists.txt
+++ b/CMakeLists.txt
@@ -116,7 +116,7 @@ function( add_pk3 PK3_NAME PK3_DIR )
 	if( WIN32 )
 		set( INSTALL_PK3_PATH . CACHE STRING "Directory where zdoom.pk3 will be placed during install." )
 	else()
-		set( INSTALL_PK3_PATH share/games/doom CACHE STRING "Directory where zdoom.pk3 will be placed during install." )
+		set( INSTALL_PK3_PATH share/edge CACHE STRING "Directory where zdoom.pk3 will be placed during install." )
 	endif()
 	install(FILES "${PROJECT_BINARY_DIR}/${PK3_NAME}"
 			DESTINATION ${INSTALL_PK3_PATH}
@@ -616,3 +616,39 @@ elseif(APPLE)
 elseif(NOT ${CMAKE_SYSTEM_NAME} MATCHES "(Free|Open)BSD")
 	target_link_libraries(EDGE GL dl)
 endif()
+
+# macro that sets a default (path) if one wasn't specified
+MACRO(SET_PATH variable default)
+	IF(NOT ${variable})
+		SET(${variable} ${default})
+	ENDIF(NOT ${variable})
+ENDMACRO(SET_PATH)
+include(GNUInstallDirs)
+SET_PATH( GAME_DIR ${CMAKE_INSTALL_PREFIX}/games )
+SET_PATH( DATA_DIR ${CMAKE_INSTALL_PREFIX}/share/edge )
+SET_PATH( SVG_DIR ${CMAKE_INSTALL_PREFIX}/share/icons/hicolor/scalable/apps )
+SET_PATH( MENU_DIR ${CMAKE_INSTALL_PREFIX}/share/applications )
+set(PROGRAM_PERMISSIONS_DEFAULT
+    OWNER_WRITE OWNER_READ OWNER_EXECUTE
+    GROUP_READ GROUP_EXECUTE
+    WORLD_READ WORLD_EXECUTE)
+macro(install_icon iconpath filepath)
+  install(CODE "execute_process(COMMAND convert -background none -thumbnail 256x256 ${iconpath} ${filepath})")
+  install(CODE "message(\"-- Converted icon: ${iconpath} -> ${filepath}\")")
+endmacro()
+macro(install_symlink filepath sympath)
+  install(CODE "execute_process(COMMAND ln -rsf  ${filepath} ${sympath})")
+  install(CODE "message(\"-- Created symlink: ${sympath} -> ${filepath}\")")
+endmacro()
+install_icon(${CMAKE_CURRENT_SOURCE_DIR}/data/iconfile.gif ${SVG_DIR}/edge.svg)
+install(FILES ${CMAKE_CURRENT_SOURCE_DIR}/edge.desktop DESTINATION ${MENU_DIR})
+install(FILES ${PROJECT_BINARY_DIR}/EDGE PERMISSIONS ${PROGRAM_PERMISSIONS_DEFAULT}
+	DESTINATION ${DATA_DIR} RENAME edge)
+install(FILES edge.sh PERMISSIONS ${PROGRAM_PERMISSIONS_DEFAULT}
+	DESTINATION ${DATA_DIR})
+install( DIRECTORY ${PROJECT_BINARY_DIR}/doom_ddf DESTINATION "${DATA_DIR}")
+install( DIRECTORY ${PROJECT_BINARY_DIR}/her_ddf DESTINATION "${DATA_DIR}")
+install( DIRECTORY ${PROJECT_BINARY_DIR}/hexen_ddf DESTINATION "${DATA_DIR}")
+install( DIRECTORY ${PROJECT_BINARY_DIR}/rott_ddf DESTINATION "${DATA_DIR}")
+install( DIRECTORY ${PROJECT_BINARY_DIR}/wolf_ddf DESTINATION "${DATA_DIR}")
+install_symlink(${DATA_DIR}/edge ${GAME_DIR}/edge)
```

CMakeLists.txt has been extended to maintain the hierarchy noted.  The script works by creating a file called *basedir*, in the user configuration folder, which contains the game path and extra arguments.

Edge, being a doom engine, uses a somewhat flat directory structure.  Quake, on the other hand, has more depth and the engine must always see id1/pak0.pak.  These considerations are reflected in the patches.  The operation of the script is as follows:

- set up paths/optional parameters
- write default paths/optional parameters to basedir as needed
- scrape paths/optional parameters from basedir
- check for target game folder and popup error if not found, otherwise:
  - test for existence of one keyfile *(to verify good game path)*
  - if keyfile isn't found, do a case-sensitive search
  - if keyfile is case-sensitive, offer to change case of files
  - if keyfile doesn't exist, popup error message and quit
- setup game dir by copying files or sym-linking if required
- execute game with arguments or by launching from game dir

Default paths are placed in ```basedir``` and the user is told to edit this file, or correct the game paths, should an error occur.  The game folder and arguments are always derived from ```basedir```, not the script, which allows for user re-configuration.
