#!/usr/bin/env perl
#
# Copyright (c) 2004-2005 The Trustees of Indiana University.
#                         All rights reserved.
# Copyright (c) 2004-2005 The Trustees of the University of Tennessee.
#                         All rights reserved.
# Copyright (c) 2004-2005 High Performance Computing Center Stuttgart, 
#                         University of Stuttgart.  All rights reserved.
# Copyright (c) 2004-2005 The Regents of the University of California.
#                         All rights reserved.
# $COPYRIGHT$
# 
# Additional copyrights may follow
# 
# $HEADER$
#

package MTT::Files;

use strict;
use Cwd;
use File::Basename;
use MTT::Messages;
use MTT::DoCommand;
use MTT::FindProgram;
use Data::Dumper;

# How many old builds to keep
my $keep_builds = 3;

# the download program to use
my $http_agent;

#--------------------------------------------------------------------------

sub make_safe_filename {
    my ($filename) = @_;

    $filename =~ s/[ :\/\\\*\&\$\#\@\!\t]/_/g;
    return $filename;
}

#--------------------------------------------------------------------------

sub mkdir {
    my ($dir) = @_;

    Debug("Making dir: $dir\n");
    my @parts = split(/\//, $dir);

    my $str;
    if (substr($dir, 0, 1) eq "/") {
        $str = "/";
        shift(@parts);
    }

    # Test and make

    foreach my $p (@parts) {
        next if (! $p);

        $str .= "$p";
        if (! -d $str) {
            Debug("$str does not exist -- creating\n");
            mkdir($str, 0777);
            if (! -d $str) {
                Error("Could not make directory $p\n");
            }
        }
        $str .= "/";
    }

    # Return an absolute version of the created directory

    my $orig = cwd();
    chdir($str);
    my $newdir = cwd();
    chdir($orig);
    $newdir;
} 

#--------------------------------------------------------------------------

# Trim old build directories
sub trim_builds {
    my ($base_dir) = @_;

    # Get all the directory entries in the top of the build tree.
    # Currently determining trim by a simple sort; may need to do
    # something better (like mtime?) in the futre...?
    opendir(DIR, $base_dir);
    my @entries = sort(grep { ! /^\./ && -d "$base_dir/$_" } readdir(DIR));
    closedir(DIR);
    print Dumper(@entries);

    # Discard the last $keep_builds entries
    my $len = $#entries - $keep_builds;
    return if ($len < 0);

    my $old_cwd = cwd();
    chdir($base_dir);

    my $i = 0;
    while ($i <= $len) {
        my $trim = 1;
        my $e = $entries[$i];
        foreach my $tarball (@MTT::Download::tarballs) {
            my $b = basename($tarball->{tarball});
            if ($e eq $b) {
                $trim = 0;
                last;
            }
        }

        if ($trim) {
            Debug("Trimming build tree: $e\n");
            MTT::DoCommand::Cmd(1, "rm -rf $e");
        } else {
            Debug("NOT trimming build tree: $e\n");
        }
        ++$i;
    }
    chdir($old_cwd);
}

#--------------------------------------------------------------------------

# unpack a tarball in the cwd and figure out what directory it
# unpacked into
sub unpack_tarball {
    my ($tarball, $delete_first) = @_;

    Debug("Unpacking tarball: $tarball\n");

    if (! -f $tarball) {
        Warning("Tarball does not exist: $tarball\n");
        return undef;
    }

    # Decide which unpacker to use

    my $unpacker;
    if ($tarball =~ /.*\.bz2$/) {
        $unpacker="bunzip2";
    } elsif ($tarball =~ /.*\.gz$/) {
        $unpacker="gunzip";
    } else {
        Warning("Unrecognized tarball extension ($tarball); don't know how to uncompress -- skipped\n");
        return undef;
    }

    # Examine the tarball and see what it puts in the cwd

    open(TAR, "tar tf $tarball|");
    my @entries = <TAR>;
    close(TAR);
    my $dirs;
    my $files;
    foreach my $e (@entries) {
        chomp($e);
        # If no /'s, then it's possibly a file in the top-level dir --
        # save for later analysis.
        if ($e !~ /\//) {
            $files->{$e} = 1;
        } else {
            # If there's a / anywhere in the name, then save the
            # top-level dir name
            $e =~ s/(.+?)\/.*/\1/;
            $dirs->{$e} = 1;
        }
    }

    # Check all the "files" and ensure that they weren't just entries
    # in the tarball to make a directory (this shouldn't happen, but
    # just in case...)

    foreach my $f (keys(%$files)) {
        if (exists($dirs->{$f})) {
            delete $files->{$f};
        }
    }

    # Any top-level files left?

    my $tarball_dir;
    if (keys(%$files)) {
        my $b = basename($tarball);
        Debug("GOT FILES IN TARBALL\n");
        $tarball_dir = MTT::Files::mkdir("slimy_tarball_$b");
        chdir($tarball_dir);
    } else {
        my @k = keys(%$dirs);
        if ($#k != 0) {
            my $b = basename($tarball);
            Debug("GOT MULTI DIRS IN TARBALL\n");
            print Dumper($dirs);
            $tarball_dir = MTT::Files::mkdir("slimy_tarball_$b");
            chdir($tarball_dir);
        } else {
            $tarball_dir = $k[0];
        }
    }
    Debug("Tarball dir is: $tarball_dir\n");

    # Remove the tree first if requested
    MTT::DoCommand::Cmd(1, "rm -rf $tarball_dir")
        if ($delete_first);

    # Untar the tarball.  Do not use DoCommand here
    # because we don't want the stdout intercepted.

    system("$unpacker -c $tarball | tar xf -");
    my $ret = $? >> 8;
    if ($ret != 0) {
        Warning("Failed to unpack tarball successfully: $tarball: $@\n");
        return undef;
    }
    
    return $tarball_dir;
}

#--------------------------------------------------------------------------

# do a svn checkout
sub svn_checkout {
    my ($url, $username, $pw, $pw_cache, $delete_first, $export) = @_;

    Debug("SVN checkout: $url\n");

    my $b = basename($url);
    MTT::DoCommand::Cmd(1, "rm -rf $b")
        if ($delete_first);

    my $str = "svn ";
    if ($export) {
        $str .= "export "
    } else {
        $str .= "co "
    }
    if ($username) {
        $str .= "--username $username ";
    }
    if ($pw) {
        $str .= "--password $pw ";
    }
    if ("0" eq $pw_cache) {
        $str .= "--no-auth-cache ";
    }
    $str .= $url;
    my $ret = MTT::DoCommand::Cmd(1, $str);
    if (0 != $ret->{status}) {
        Warning("Could not SVN checkout $url: $@\n");
        return undef;
    }
    my $r = undef;
    if ($ret->{stdout} =~ m/Exported revision (\d+)\.\n$/) {
        $r = $1;
    }

    return ($b, $r);
}

#--------------------------------------------------------------------------

# Copy and entire file tree
sub copy_tree {
    my ($srcdir, $delete_first) = @_;

    Debug("Copying directory: $srcdir\n");

    if (! -d $srcdir) {
        Warning("Directory does not exist: $srcdir\n");
        return undef;
    }

    my $b = basename($srcdir);
    MTT::DoCommand::Cmd(1, "rm -rf $b")
        if ($delete_first);

    my $ret = MTT::DoCommand::Cmd(1, "cp -r $srcdir .");
    if (0 != $ret->{status}) {
        Warning("Could not copy file tree $srcdir: $@\n");
        return undef;
    }

    return $b;
}

#--------------------------------------------------------------------------

my $md5sum_path;
my $md5sum_searched;

sub _find_md5sum {
    # Search
    $md5sum_path = FindProgram(qw(md5sum gmd5sum));
    $md5sum_searched = 1;
    if (!$md5sum_path) {
        Warning("Could not find md5sum executable, so I will not be able to check the validity of downloaded executables against their known MD5 checksums.  Proceeding anyway...\n");
    }
}

sub md5sum {
    my ($file) = @_;

    _find_md5sum()
        if (!$md5sum_searched);
    # If we already searched and didn't find then, then just return undef
    return undef
        if (!$md5sum_path && $md5sum_searched);
    return undef
        if (! -f $file);

    my $x = MTT::DoCommand::Cmd(1, "$md5sum_path $file");
    if (0 != $x->{status}) {
        Warning("md5sum unable to run properly\n");
        return undef;
    }
    $x->{stdout} =~ m/^(\w{32})/;
    return $1;
}

sub md5sum_tree {
    my ($dir) = @_;

    _find_md5sum()
        if (!$md5sum_searched);
    # If we already searched and didn't find then, then just return undef
    return undef
        if (!$md5sum_path && $md5sum_searched);
    return undef
        if (! -d $dir);

    # Can't use DoCommand here because we need to use |
    my $x = `tar cf - $dir | $md5sum_path`;
    my $status = $?;
    chomp($x);
    if (0 != $status) {
        Warning("md5sum unable to run properly\n");
        return undef;
    }
    $x =~ m/^(\w{32})/;
    return $1;
}

#--------------------------------------------------------------------------

my $sha1sum_path;
my $sha1sum_searched;

sub sha1sum {
    my ($file) = @_;

    # Setup if we haven't already
    if (!$sha1sum_path) {
        # If we already searched and didn't find then, then just return undef
        return undef
            if ($sha1sum_searched);

        # Search
        $sha1sum_path = FindProgram(qw(sha1sum gsha1sum));
        $sha1sum_searched = 1;
        if (!$sha1sum_path) {
            Warning("Could not find sha1sum executable, so I will not be able to check the validity of downloaded executables against their known SHA1 checksums.  Proceeding anyway...\n");
            return undef;
        }
    }

    my $x = MTT::DoCommand::Cmd(1, "$sha1sum_path $file");
    if (0 != $x->{status}) {
        Warning("sha1sum unable to run properly\n");
        return undef;
    }
    $x->{stdout} =~ m/^(\w{40})/;
    return $1;
}

#--------------------------------------------------------------------------

sub http_get {
    my ($url) = @_;

    # figure out what download command to use
    if (!$http_agent) {
        $http_agent = FindProgram(@MTT::Constants::http_agents);
    }
    Abort("Cannot find downloading program -- aborting in despair\n")
        if (!defined($http_agent));

    my $x = MTT::DoCommand::Cmd(1, "$http_agent $url");
    if (0 != $x->{status}) {
        return undef;
    }
    return 1;
}

1;
