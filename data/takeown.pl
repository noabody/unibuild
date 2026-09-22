#!/usr/bin/env perl
use strict;
use warnings;
use File::Find;
use File::Basename;
use Getopt::Long qw(:config no_ignore_case);
use File::LibMagic; # requires arch perl-file-libmagic

my $mydir = '.';
my $dperm = '755';
my $fperm = '644';

sub usage {
    my ($msg) = @_;
    my $name = basename($0);
    print STDERR "$name: ERROR: $msg\n" if $msg;
    print STDERR "usage: $name\n [-f|--fixperms] [-t|--takeown]\n";
    exit 1;
}

my ($fixperms, $takeown);
GetOptions(
    'f|fixperms' => \$fixperms,
    't|takeown'  => \$takeown,
) or usage("invalid option");

usage("no options given") if (!$fixperms && !$takeown);
usage("too many options given") if ($fixperms && $takeown);

if ($fixperms) {
    print "Correct file and folder permissions? [y/N] ";
    my $ans = <STDIN>;
    chomp $ans if defined $ans;

    my $chse = ($ans && $ans =~ /^y(?:es)?$/i) ? 1 : 0;
    if ($chse) {
        print "Correcting Permissions ...\n";
    } else {
        print "Displaying mis-matched Permissions ...\n";
    }

    # Initialize libmagic once in memory for blistering speed
    my $magic = File::LibMagic->new();

    find({
        wanted => sub {
            my $path = $File::Find::name;
            return if $path eq '.';

            my $base = basename($path);

            # Prune hidden directories or dropbox directories
            if ($base =~ /^\./ || $base =~ /^dropbox$/i) {
                $File::Find::prune = 1 if -d $path;
                return;
            }

            # Skip backup files
            if ($base =~ /\.bak$/i) {
                return;
            }

            # Don't process symlinks
            return if -l $path;

            my @st = stat($path);
            return unless @st;
            my $perm = sprintf("%03o", $st[2] & 0777);

            if (-d $path) {
                # Folders -> 755
                if ($perm ne $dperm) {
                    if ($chse) {
                        chmod(0755, $path);
                        print "Set folder 755 $path\n";
                    } else {
                        print "Folder $perm $path\n";
                    }
                }
            } elsif (-f $path) {
                my $info = $magic->info_from_filename($path);
                my $mime     = $info->{mime_type} // '';
                my $description = $info->{description} // '';

                my $needs_exec = 0;
                my $label = "Regular";

                # 1. Check for shebang script
                if (open(my $fh, '<:raw', $path)) {
                    my $head;
                    read($fh, $head, 2);
                    if ($head && $head eq '#!') {
                        $needs_exec = 1;
                        $label = "Script";
                    }
                    close($fh);
                }

                # 2. If not a script, check libmagic profile
                if (!$needs_exec) {
                    if ($description =~ /ELF.*executable/i) {
                        $needs_exec = 1;
                        $label = "Binary";
                    } elsif ($description =~ /ELF.*shared object/i) {
                        if ($path =~ /lib.*\.so/i) {
                            $label = "Library";
                            # $needs_exec remains 0 -> 644
                        } else {
                            $needs_exec = 1;
                            $label = "Binary";
                            # Treated as an executable -> 755
                        }
                    } else {
                        # Windows PE executables, text files, assets -> Regular (644)
                        $label = "Regular";
                    }
                }

                my $target_perm = $needs_exec ? $dperm : $fperm;

                if ($perm ne $target_perm) {
                    if ($chse) {
                        chmod($needs_exec ? 0755 : 0644, $path);
                        print "Set $label $target_perm $path\n";
                    } else {
                        print "$label $perm $path\n";
                    }
                }
            }
        },
        no_chdir => 1,
    }, $mydir);

} elsif ($takeown) {
    print "Transfer root ownership of files/folders to current user? [y/N] ";
    my $ans = <STDIN>;
    chomp $ans if defined $ans;

    my $chse = ($ans && $ans =~ /^y(?:es)?$/i) ? 1 : 0;

    my @root_owned;

    find({
        wanted => sub {
            my $path = $File::Find::name;
            my @st = lstat($path);
            return unless @st;

            my $uid = $st[4];
            my $gid = $st[5];

            if ($uid == 0 && $gid == 0) {
                push @root_owned, $path;
            }
        },
        no_chdir => 1,
    }, $mydir);

    if ($chse) {
        print "Taking ownership ...\n";
        my $user = $ENV{LOGNAME} || $ENV{USER} || getpwuid($>);
        if (@root_owned) {
            system('sudo', 'chown', '-h', "$user:$user", @root_owned);
        }
    } else {
        print "Displaying files/folders owned by root ...\n";
        for my $p (sort @root_owned) {
            print "$p\n";
        }
    }
}
