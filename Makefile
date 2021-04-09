prefix = /usr
datarootdir = $(prefix)/share
datadir = $(datarootdir)
exec_prefix = $(prefix)
bindir = $(exec_prefix)/bin
mandir = $(datarootdir)/man
man1dir = $(mandir)/man1
sysconfdir = /etc
name = unibuild

all:
	pandoc -s -o unibuild.1 docs/READUNI.md
clean:
	rm -f $(name).1
install:
	install -m 755 -vCDt $(DESTDIR)$(bindir) data/$(name)
	install -m 755 -vCDt $(DESTDIR)$(bindir) data/repochk
	install -m 755 -vCDt $(DESTDIR)$(bindir) data/udepsort
	install -m 755 -vCDt $(DESTDIR)$(bindir) data/takeown
	install -m 644 -vCDt $(DESTDIR)$(man1dir) $(name).1
uninstall:
	rm -f $(DESTDIR)$(bindir)/$(name)
	rm -f $(DESTDIR)$(bindir)/repochk
	rm -f $(DESTDIR)$(bindir)/udepsort
	rm -f $(DESTDIR)$(bindir)/takeown
	rm -f $(DESTDIR)$(man1dir)/$(name).1
.PHONY: all clean install uninstall
