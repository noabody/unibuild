# unibuild - the little kludge that could
Rudimentary bash scripts to unify (*hook*) package installation trackers (*checkinstall, fpm*)

## What's it all about?
Contained herein are scripts and patches designed to automate the installation and removal of bleeding edge software, built from source, using the debian package management system.  The target OS is Ubuntu 18.04 with requirements:
```shell
sudo apt install bash binutils checkinstall coreutils dpkg-dev findutils git icnsutils icoutils imagemagick inkscape libarchive-zip-perl mercurial pandoc pcregrep perl rename ruby-dev subversion trash-cli txt2man wrestool wget
sudo gem install fpm
```

## How does it work?
The primary script creates a database of common packaging information, grouped by source folder-name, which defines a function (addtional functions must be added manually). The base folder is initially set to *$HOME/Dev/* via the **paksrc** variable.

- Use sym-links whenever a source folder doesn't conform to the function/folder naming convention.
- Sym-link sub projects to root of source (containing .git .svn .hg folder) and adjust Makefile or unibuild as needed.
- **unibuild** functionality differs depending on what folder the command is run from.
  - From a project folder, it defaults to building packages with checkinstall unless it finds *work* in the pathname - which causes it to use fpm.  The process will automatically purge existing install, update source, clean, build, package, trash backup and replace with new.  *Individual build*
  - From the source folder, it asks to clean all projects.  *Global Clean*
  - When run from outside a project or the source tree, it prompts to rebuild all projects that contain a deb file with valid hash in **paktgt**.  The process will automatically purge existing install, update source, clean, build, package, trash backup and replace with new. *Global Rebuild*

## How does one use this?
Open the **unibuild** script in a text editor.  Copy an existing entry, paste it alphabetically acording to the new project name, then edit the field variables:

- unibuild *(project/source folder name)*
  - **pakuser="noa body \<noabody@nowhere.com\>"**  - Contact email
  - **pakdesc="Scripts to unify package installation."**  - Description
  - **pakver="" ; lsrmt**  - Version number or scrape method *(path to file with version ; search term ; scrape)*
  - **pakrel="1"**  - Release, usually *1*
  - **paklic="Unl"**  - License, often *GPL*
  - **pakgrp="utils"**  - Groups could be *games, misc, libs, graphics, utils, etc.*
  - **pakneeds="bash, binutils, checkinstall"**  - Dependencies, *see Advanced internals*
  - **pakhome="https://github.com/noabody"**  - Home URL, unused
  - **pakmak="build"**  - Path, from project root, where *Makefile* is located
  - **pakcln="clean"**  - *clean* predicate to make command
  - **pakbld="-j4"**  - *make all* predicate - can be blank, all, -j4, etc.
  - **pakinst="install"**  - *install* predicate

**These functions are a set of variable declarations and each field must be populated with, at minimum, empty set ="" for recursive rebuilds to work.**  Refer to the script comments for further information.

## Helping helpers.
**repodeb** performs these functions:

- Prompt to list projects whose source and archived .deb files are/aren't in sync.  *(-c)*
- Prompt to list projects with/without .deb.  *(-d)*
- Display unique dependencies, recursively, for all binaries in current path.  *(-f)*
- Prompt to list held projects (marked by folder-name preceded by underscore) and ask to release.  *(-h)*
- Prompt to list installed packages with archived .deb files that are/aren't in sync and ask to update.  *(-i)*
- Toggles 32-bit Ubuntu lxc defined by lxc32 variable.  *(-l)*
- Prompt to trash and replace archived .deb if newer exists in source tree, or move to central location.  *(-m)*
- Prompt to update project sources if local and remote aren't in sync, otherwise display the mismatch.  *(-o)*
- Relates to patch of same name as project but one level up.  When run from project folder, applies patch directives that precede the first ```diff```.  An individual patch name may be supplied as an optional parameter  *(-p)*
- List project debs updated within last 5 days.  *(-r)*
- Displays git or mercurial tags that conform to a standard version number format.  *(-t)*
- Bulk repository update.  *(-u)*

**takeown** performs these functions:

- Prompt to normalize file permissions or show mis-matches.  *(-f)*
- Prompt to transfer files owned by root to the local user or show them.  *(-t)*

**udepsort** scrapes unibuild *Build-depends:* and performs these functions:

- dpkg -l dependencies  *(-d)*
- Prompt to sort projects and update unibuild or print sort to console  *(-f)*
- Prompt to install or print *missing* dependencies.  An individual project name may be supplied as an optional parameter  *(-i)*
- Install ```pip install``` lines  *(-p)*
- Prompt to sort depends and update unibuild or print sort to console  *(-s)*

While the scripts are designed to build and manage local packages, **this method is inappropriate for pakage distribution**.

## Advanced internals
- Except for a few exclusions, **unibuild** uniquifies dependencies for all binary executable and library files in the source folder. This is done through an extremely hackish misuse of dpkg-shlibdeps.
  - Script-language projects don't produce binaries and **pakneeds=** should be used to specify the language, e.g. *openjdk-8-jre, python*.  Any manual dependencies added via **pakneeds=** will be appended to those generated automatically.
  - Use **repodeb -f** in the project folder for verbose dependency build information.
- A version scraping mechanism exists to process CMakeLists.txt, configure.ac, git tags, user specified single and multi-line generics, or a non-delimited numeric version string.  The default pattern-match is generally effective and can sometimes be extended via **pre** and/or **post**.
- Should the repository update fail, a reset, pull, and **repodeb -p** will be performed.  
- Should the build process fail to produce a .deb, the project will automatically be *held* by prepending it's name with an underscore.  Use **repodeb -h** to clear the status or view held projects.

## Extras Data
Scripts and diff patches are contained in the data folder.  For checkinstall compatibility, source patches were created to add, or modify existing, Makefiles.

While the commands noted can be used to apply these, it's recommended to add appropriate directives to each patch file and automate their installation through **repodeb -p**.

Patches for indexed files are applied from within the source folder via:
```shell
git apply ../project.patch
```
Patches for un-indexed files require:
```shell
patch -Np1 -i ../project.patch
```
Though it might be useful to *dry-run* for exceptions:
```shell
patch -Np1 --dry-run -i ../project.patch
```
End of Line **EOL** affects whether each line ends with a Line Feed **LF** *(Unix/OSX)* or Carriage Return + Line Feed **CR/LF** *(Windows)*.  Ensure the patch EOL corresponds to that of the files to which it applies.  *dry-run* will always suggest using *--binary* for CR/LF:
```shell
patch -Np1 --binary -i ../project.patch
```
Patches shouldn't clobber as long as each entry has a date/time stamp.  A command like this will reset all files to the same:
```shell
perl -pi -e 's/((\-|\+){3}\s(a|b)[\w\/.-]+).*$/\1\t1969-12-31 17:00:00.000000000 -0700/gi' *.patch
```

## Caveats
- Though **unibuild** has a Makefile, it is not meant to be installed globally or *as-is*.  The scripts are too rudimentary and kludgy to be more than a reference as to how one might accomplish a task.
- sudo priviledge is required: for package management changes, by lxc and checkinstall, and to transfer ownership of files from root to the local user.
- deb files must be built once, then transferred to **paktgt**, for the automated rebuilding function to work.  Use this fact to selectively build targets.
- The automation requires **paktgt**.  It can be effectively disabled by setting the variable to a folder that exists but contains no .debs or subfolders.
- The patches in **unibuild/data** might be of more interest than the scripts as they allow certain source projects to be built *e.g. peazip, doublecommander*.

[Further reading](SKEL.md)
