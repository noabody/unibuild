[Contribution guidelines for this project](docs/CONTRIBUTING.md)

[Code of Conduct for this project](CODE_OF_CONDUCT.md)

[Original Unibuild](docs/READUNI.md)

# unibuild - what it was, and is

- It was a simplistic system to automate the build and creation of bleeding edge software packages.
- It is now a reference as to how this may be accomplished.

## repochk
The core helper script was subdivided into its current Arch implementation and *repodeb*.  It can be used to automate the rebuilding of compliant *PKGBUILD* projects, backup to a specified drive, and update installed packages.

## Ubuntu
Having built the 100+ projects, hundreds of times, the strength of the core scripts and patches became a visible weakness.

They collect information needed to make the projects, and build their debian packages (via *checkinstall*).  It requires the creation, or amendment, of countless Gnu *Makefiles* and *CMakeLists.txt* to provide the actual *install* directive (to place the software where it needs to be in the filesystem).  This is laborious to maintain since it's outside the scope of the developer; as they make changes, the patches need to be updated on a near continuous basis.

*checkinstall* as a packager is simply not up to the task for actual deployment.  Ubuntu LTS was a day old when it rolled out which doesn't lend itself to building anything *bleeding edge*.

## Manjaro
Many times I worked on a patch for a project only to abandon it when the developer updated their ancillary libraries to a version that was out of reach for Ubuntu LTS.  If you want to make bleeding edge, you have to be bleeding edge.

## An end and beginning
I've begun to adapt Debian (Ubuntu) patches to work on Arch (Manjaro).  The original patches, and *unibuild* script, created a road map on how to build and package the projects.  They adapt fairly easily to Arch's *PKGBUILD* system.  Compare *xash3d* and *uhexen2* to get a feel for it.

Arch packages are *patchified* so, assuming you build where source code projects reside, a command like this would prepare the folder hierarchy and files:

```shell
pch=xash3d ; cd $HOME/Dev && patch -Np1 -i unibuild/data/arch/$pch.patch ; cd $pch ; makepkg -f
```
Patches shouldn't clobber as long as each entry has a date/time stamp.  A command like this will reset all files to the same:

```shell
perl -pi -e 's/((\-|\+){3}\s(a|b)[\w\/.-]+).*$/\1\t1969-12-31 17:00:00.000000000 -0700/gi' *.patch
```

## What value is there now?
The information remains relevant and my customized game launching scripts provide an interesting way to adapt certain software to a global installation.  The afore mentioned *xash3d* and *uhexen2* don't have an Arch candidate.  Xash3D does, but not for native 64-bit, which all of these patches were made for.
