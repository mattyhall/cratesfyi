#!/usr/bin/perl
##########################################################################
# Central repository for all crate documentation                         #
# Copyright (C) <2016>  Onur Aslan  <onuraslan@gmail.com>                #
#                                                                        #
# This program is free software: you can redistribute it and/or modify   #
# it under the terms of the GNU General Public License as published by   #
# the Free Software Foundation, either version 3 of the License, or      #
# (at your option) any later version.                                    #
#                                                                        #
# This program is distributed in the hope that it will be useful,        #
# but WITHOUT ANY WARRANTY; without even the implied warranty of         #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the          #
# GNU General Public License for more details.                           #
#                                                                        #
# You should have received a copy of the GNU General Public License      #
# along with this program.  If not, see <http://www.gnu.org/licenses/>.  #
##########################################################################

# TODO:
# * Handle path dependencies

use strict;
use warnings;
use File::Find;
use File::Path qw/make_path/;
use IPC::Cmd qw/run/;
use FindBin;
use JSON;
use File::Slurp;
use TOML qw/from_toml/;
use Log::Message::Simple qw/msg error debug/;
use Data::Dumper;
use Cwd;


# FIXME: This is a sad function. I kept editing until I got this monster
sub run_ {
    my $cmd = join(' ', @_);
    debug("Running command: $cmd in " . cwd(), 1);
    my($success, $error_message, $full_buf, $stdout_buf, $stderr_buf) =
            run(command => $cmd, verbose => 0);
    return (join("", @{$full_buf}), defined($success));
}


# Some deps needs to be downloaded manually
# This deps are defined with a path in Cargo.toml
sub download_dependencies {
    my $package_root = $_[0];
    my $toml_content = read_file($package_root . '/Cargo.toml');
    my $toml = from_toml($toml_content);

    msg("Checking local dependencies of $toml->{package}->{name}", 1);

    for (keys(%{$toml->{dependencies}})) {
        if (ref($toml->{dependencies}->{$_}) eq 'HASH' &&
            defined($toml->{dependencies}->{$_}->{path})) {

            my $crate = $_;
            my $version = $toml->{dependencies}->{$_}->{version};
            my $path = $toml->{dependencies}->{$_}->{'path'};

            msg("Downloading dependency $crate-$version", 1);
            my $url = "https://crates-io.s3-us-west-1.amazonaws.com/crates/" .
                      "$crate/$crate-$version.crate";
            my @wget_output = run_('wget', '-c', '--content-disposition',
                                   $url);
            msg($wget_output[0], 1);
            die "Unable to download $crate from $url\n"
                unless ($wget_output[1]);

            # Extract crate into package root
            msg("Extracting $crate-$version.crate " .
                "into: $package_root", 1);
            msg((run_('tar',
                      '-C', $package_root,
                      '-xzvf', "$crate-$version.crate"))[0], 1);

            # Move crate into right place
            msg("Moving crate into $path", 1);
            msg((run_('mv', '-v',
                      $package_root . "/$crate-$version",
                      $package_root . "/$path"))[0], 1);

            msg("Removing $crate-$version.crate", 1);
            msg((run_('rm', '-v', "$crate-$version.crate"))[0], 1);

            # Check dependencies of downloaded crate
            download_dependencies($package_root . "/$path");
        }
    }

}


# Instead of editing rustdoc for stylesheet and javascript urls
# replace them when copying docs into public_html
sub copy_doc {
    my ($source, $dest) = @_;

    my $copy = sub {

        return if $_ eq '.';

        my $source_file = $_;

        my $dir = $File::Find::dir;
        # FIXME: crate name assumption
        $dir =~ s/.*target\/doc\/[\w-]+//;
        make_path($dest . $dir);
        return if -d $_;

        open (my $sourcefh, $_);
        open (my $destfh, '>' . $dest . $dir . '/' . $_);

        while (<$sourcefh>) {

            if ($source_file =~ /\.html$/) {
                if (/href=".*\.css"/) {
                    $_ =~ s/href="(.*\.css)"/href="..\/$1"/;
                } elsif (/<script.*src=".*search-index\.js"/) {
                    $_ =~ s/src="\.\.\/(.*\.js)"/src="$1"/;
                } elsif (/<script.*src=".*(jquery|main|playpen)\.js"/) {
                    $_ =~ s/src="(.*\.js)"/src="..\/$1"/;
                }
            }

            print $destfh $_;
        }

        close $sourcefh;
        close $destfh;

    };

    find($copy, $source);
}



sub build_doc_for_version {
    my ($crate, $version) = @_;

    # Opening log file
    open my $logfh, '>' . $FindBin::Bin . "/logs/$crate-$version.log";
    local $Log::Message::Simple::MSG_FH = \*$logfh;
    local $Log::Message::Simple::ERROR_FH = \*$logfh;
    local $Log::Message::Simple::DEBUG_FH = \*$logfh;

    msg("Building documentation for crate: $crate-$version", 1);

    my $clean_package = sub {

        msg("Cleaning $crate-$version", 1);
        msg((run_('sudo', 'chroot', $FindBin::Bin . '/chroot',
                          'su', '-', 'onur',
                          '/home/onur/build.sh', 'clean',
                          "$crate-$version"))[0], 1);

        msg("Removing $crate-$version build directory", 1);
        msg((run_('rm', '-rf',
                        $FindBin::Bin . "/build_home/$crate-$version"))[0], 1);

        msg("Removing crate file $crate-$version.crate", 1);
        msg((run_('rm', '-fv', "$crate-$version.crate"))[0], 1);

    };


    # Default crate url is:
    # https://crates.io/api/v1/crates/$crate/$version/download
    # But I believe this url is increasing download count and this bot is
    # downloading alot during development. I am simply using redirected url
    my $url = "https://crates-io.s3-us-west-1.amazonaws.com/crates/" .
              "$crate/$crate-$version.crate";
    msg("Downloading $crate-$version.crate", 1);
    my @wget_output = run_('wget', '-c', '--content-disposition', $url);
    msg($wget_output[0], 1);
    die "Unable to download $crate from $url\n" unless ($wget_output[1]);

    # Extract crate file into build_home
    msg("Extracting $crate-$version.crate " .
        "into: $FindBin::Bin/build_home", 1);
    msg((run_('tar',
              '-C', $FindBin::Bin . '/build_home',
              '-xzvf', "$crate-$version.crate"))[0], 1);

    download_dependencies($FindBin::Bin . '/build_home/' . "$crate-$version");

    # Build file
    msg("Running cargo doc --no-deps in " .
        "chroot:/home/onur/$crate-$version", 1);

    my @build_output = run_('sudo', 'chroot', $FindBin::Bin . '/chroot',
                            'su', '-', 'onur',
                            '/home/onur/build.sh', 'build', "$crate-$version");
    msg($build_output[0], 1);
    unless ($build_output[1]) {
        error("Building documentation for $crate-$version failed", 1);
        $clean_package->();
        return;
    }

    # If everything goes fine move generated documentation into public_html
    mkdir($FindBin::Bin . '/public_html/' . $crate);

    # Remove old documentation for same version just in case
    debug("Removing old documentation in public_html", 1);
    msg((run_('rm', '-rf',
             $FindBin::Bin . '/public_html/' .
             $crate . '/' . $version))[0], 1);

    msg("Moving documentation into: " .
        $FindBin::Bin . '/public_html/' .
        $crate . '/' . $version, 1);
    my $crate_dname = $crate; $crate_dname =~ s/-/_/g;
    copy_doc($FindBin::Bin .
                "/build_home/$crate-$version/target/doc/$crate_dname",
             $FindBin::Bin . '/public_html/' . $crate . '/' . $version);
    # and copy search-index.js
    msg((run_('cp', '-v',
              $FindBin::Bin . "/build_home/$crate-$version" .
              "/target/doc/search-index.js",
              $FindBin::Bin . '/public_html/' .
              $crate . '/' . $version))[0], 1);

    $clean_package->();

    close $logfh;
}

# Build documentation for crates
# If you call this function with a crate name, it'll only generate docs for
# that crate.
sub build_doc_for_crate {
    my $requested_crate = $_[0];

    my $wanted = sub {

        # Skip downloaded .crate files, directories, config.json and
        # files under .git
        return if not -f $_;
        return if $_ eq 'config.json';
        return if $_ =~ /crate$/;
        return if $File::Find::dir =~ /^crates.io-index\/\.git/;

        my $crate;

        if (defined($requested_crate) && $_ ne $requested_crate) {
            return;
        } elsif (!defined($requested_crate)) {
            $crate = $_;
        }

        $crate ||= $requested_crate;

        my @versions = ();
        open (my $fh, $_);
        push @versions, decode_json($_) while (<$fh>);
        close $fh;

        # Build doc for latest version
        #for (@versions) {
        #    build_doc_for_version($crate, $_->{vers});
        #}

        build_doc_for_version($crate, $versions[-1]->{vers});
    };

    find($wanted, 'crates.io-index');

}


build_doc_for_crate('sdl2');
#download_dependencies('/tmp/sdl2-0.13.0');
