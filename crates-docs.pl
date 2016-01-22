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
# * Don't die if download fails
# * Some of the local dependency crates are using asterix for version.
#   I need to get latest version of crate.
# * bindgen crate failed to build because there was no libclang.so
#   available.
# * Left column is not visible on crate index. No idea why. Need to fix
#   this.
# * This script is becoming hard to maintain. Need more comments in base
#   functions.
# * Add global options for prefix and log folder.


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
use Cwd qw/cwd abs_path/;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;


my %OPTIONS = (
    'keep_build_directory' => 0,
    'destination' => $FindBin::Bin . '/public_html/crates',
    'chroot_path' => $FindBin::Bin . '/chroot',
    'chroot_user' => 'onur',
    'chroot_user_home_dir' => '/home/onur',
    'crates_io_index_path' => $FindBin::Bin . '/crates.io-index',
    'logs_path' => $FindBin::Bin . '/logs',
    'skip_if_exists' => 0,
    'debug' => 0,
);



# FIXME: This is a sad function. I kept editing until I got this monster
sub run_ {
    my $cmd = join(' ', @_);
    debug("Running command: $cmd in " . cwd(), $OPTIONS{debug});
    my($success, $error_message, $full_buf, $stdout_buf, $stderr_buf) =
            run(command => $cmd, verbose => 0);
    $full_buf->[-1] =~ s/\n$//g if scalar(@{$full_buf});
    return (join("", @{$full_buf}), defined($success));
}


# Get latest version of a crate
# Some crates are pointing to * version.
# We need to find out which version is latest for given crate.
sub get_latest_version {
    my $crate = $_[0];
    my $latest_version;

    my $wanted = sub {
        return unless -f $_;
        return unless $_ eq $crate;

        open (my $fh, $_);
        while (<$fh>) {
            my $version_info = decode_json($_);
            $latest_version = $version_info->{vers};
        }
        close $fh;
    };

    find($wanted, $OPTIONS{crates_io_index_path});

    return $latest_version;
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
            my $path = $toml->{dependencies}->{$_}->{'path'};
            my $version = $toml->{dependencies}->{$_}->{version};

            $version = get_latest_version($crate) if ($version eq '*');

            msg("Downloading dependency $crate-$version", 1);
            my $url = "https://crates-io.s3-us-west-1.amazonaws.com/crates/" .
                      "$crate/$crate-$version.crate";
            my @wget_output = run_('wget', '-c', '--content-disposition',
                                   $url);
            msg($wget_output[0], 1);
            unless ($wget_output[1]) {
                error("Unable to download $crate");
                return 0;
            }

            # Extract crate into package root
            msg("Extracting $crate-$version.crate " .
                "into: $package_root", 1);
            msg((run_('tar',
                      '-C', $package_root,
                      '-xzvf', "$crate-$version.crate"))[0], 1);

            # Move crate into right place
            msg("Moving crate into $path", 1);
            if ($path eq '..') {
                msg((run_('mv', '-v',
                          $package_root . "/$crate-$version/*",
                          $package_root . "/$path"))[0], 1);
            } else {
                msg((run_('mv', '-v',
                          $package_root . "/$crate-$version",
                          $package_root . "/$path"))[0], 1);
            }

            msg("Removing $crate-$version.crate", 1);
            msg((run_('rm', '-v', "$crate-$version.crate"))[0], 1);

            # Check dependencies of downloaded crate
            return 0 unless download_dependencies($package_root . "/$path");
        }
    }

    return 1;
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
        $dir =~ s/.*target\/doc\/(src\/)*[\w-]+//;
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
                } elsif (/href='.*?\.\.\/src/) {
                    $_ =~ s/href='(.*?)\.\.\/src\/[\w-]+\//href='$1src\//g;
                } elsif (/href='.*?\.\.\/[\w_-]+/) {
                    $_ =~ s/href='(.*?)\.\.\/[\w_-]+\//href='$1/g;
                } elsif (/window.rootPath = "(.*?)\.\.\//) {
                    $_ =~ s/window.rootPath = "(.*?)\.\.\//window.rootPath = "$1/g;
                }
            }

            print $destfh $_;
        }

        close $sourcefh;
        close $destfh;

    };

    find($copy, $source) if -e $source;
}



sub build_doc_for_version {
    my ($crate, $version) = @_;

    if ($OPTIONS{skip_if_exists} &&
        -d $OPTIONS{destination} . '/' . $crate . '/' . $version) {
        print "Skipping $crate-$version documentation is already exist in: ",
              $OPTIONS{destination} . '/' . $crate . '/' . $version . "\n";
        return;
    }

    # Opening log file
    make_path($OPTIONS{logs_path} . "/$crate");
    open my $logfh, '>' . $OPTIONS{logs_path} . "/$crate/$crate-$version.log";
    local $Log::Message::Simple::MSG_FH = \*$logfh;
    local $Log::Message::Simple::ERROR_FH = \*$logfh;
    local $Log::Message::Simple::DEBUG_FH = \*$logfh;

    print "Building documentation for: $crate-$version\n";
    msg("Building documentation for: $crate-$version", 1);

    my $clean_package = sub {

        if ($OPTIONS{keep_build_directory}) {
            return;
        }

        msg("Cleaning $crate-$version", 1);
        msg((run_('sudo', 'chroot', $OPTIONS{chroot_path},
                          'su', '-', $OPTIONS{chroot_user},
                          $OPTIONS{chroot_user_home_dir} . '/.build.sh',
                          'clean', "$crate-$version"))[0], 1);

        msg("Removing $crate-$version build directory", 1);
        msg((run_('rm', '-rf',
                        $FindBin::Bin . "/build_home/$crate-$version"))[0], 1);

        # Some packages are moving stuff into build_home directory
        # I think its better to clean up everything in home directory
        msg("Cleaning build_home", 1);
        msg((run_('rm', '-rf',
                        $FindBin::Bin . "/build_home/*"))[0], 1);

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
    unless ($wget_output[1]) {
        error("Unable to download $crate", 1);
        return;
    }

    # Extract crate file into build_home
    msg("Extracting $crate-$version.crate " .
        "into: $FindBin::Bin/build_home", 1);
    msg((run_('tar',
              '-C', $FindBin::Bin . '/build_home',
              '-xzvf', "$crate-$version.crate"))[0], 1);

    download_dependencies($FindBin::Bin . '/build_home/' . "$crate-$version");

    # Build file
    msg("Running cargo doc --no-deps", 1);

    my @build_output = run_('sudo', 'chroot', $OPTIONS{chroot_path},
                            'su', '-', $OPTIONS{chroot_user},
                            $OPTIONS{chroot_user_home_dir} . '/.build.sh',
                            'build', "$crate-$version");
    msg($build_output[0], 1);
    unless ($build_output[1]) {
        error("Building documentation for $crate-$version failed", 1);
        $clean_package->();
        return;
    }

    # If everything goes fine move generated documentation into public_html

    # Remove old documentation for same version just in case
    debug('Removing old documentation in ' . $OPTIONS{destination} . '/',
          $OPTIONS{debug});
    msg((run_('rm', '-rf',
              $OPTIONS{destination} . '/' .
              $crate . '/' . $version))[0], 1);

    make_path($OPTIONS{destination} . '/' . $crate . '/' . $version);

    msg("Moving documentation into: " .
        $OPTIONS{destination} . '/' .
        $crate . '/' . $version, 1);
    my $crate_dname = $crate; $crate_dname =~ s/-/_/g;
    copy_doc($FindBin::Bin .
                "/build_home/$crate-$version/target/doc/$crate_dname",
             $OPTIONS{destination} . '/' . $crate . '/' . $version);
    # Copy source as well
    # FIXME: 80+
    copy_doc($FindBin::Bin . "/build_home/$crate-$version/target/doc/src/$crate_dname",
             $OPTIONS{destination} . '/' . $crate . '/' . $version . '/src');
    # and copy search-index.js
    msg((run_('cp', '-v',
              $FindBin::Bin . "/build_home/$crate-$version" .
              "/target/doc/search-index.js",
              $OPTIONS{destination} . '/' . $crate . '/' . $version))[0], 1);

    $clean_package->();

    close $logfh;
}

# Build documentation for crates
# If you call this function with a crate name, it'll only generate docs for
# that crate.
sub build_doc_for_crate {
    my ($requested_crate, $requested_version) = @_;

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


        my $found = 0;
        for (reverse(@versions)) {
            if (defined($requested_version)) {
                if ($_->{vers} eq $requested_version) {
                    build_doc_for_version($crate, $_->{vers});
                    $found = 1;
                }
            } else {
                $found = 1;
                build_doc_for_version($crate, $_->{vers});
            }
        }

        print "$crate-$requested_version is not available in crates.io-index\n"
            unless $found;

    };

    find($wanted, 'crates.io-index');

}


sub check_prerequisities {
    my @error = ();

    # convert options to abs paths
    for ('destination',
         'chroot_path',
         'chroot_user_home_dir',
         'crates_io_index_path',
         'logs_path') {
         $OPTIONS{$_} = abs_path($OPTIONS{$_});
    }

    push @error, 'chroot path doesn\'t exist' unless -e $OPTIONS{chroot_path};
    push @error, 'chroot user home directory doesn\'t exist'
        unless -e abs_path($OPTIONS{chroot_path} . '/' .
                           $OPTIONS{chroot_user_home_dir});
    push @error, 'crates.io-index doesn\'t exist'
        unless -e $OPTIONS{crates_io_index_path};

    error($_, 1) for (@error);
    return scalar(@error);
}


sub main {

    my $help = sub {
        pod2usage(-verbose  => 99,
                  -sections => [qw/SYNOPSIS ARGS/]);
    };

    my $actions = {
        build_docs => '',
        packages => [],
        version => undef,
    };

    GetOptions(
        'build-documentation|b@' => \$actions->{build_docs},
        '<>' => sub { push(@{$actions->{packages}}, $_[0]) },
        'version|v=s' => \$actions->{version},
        'skip|s' => \$OPTIONS{skip_if_exists},
        'keep-build-directory' => \$OPTIONS{keep_build_directory},
        'destination=s' => \$OPTIONS{destination},
        'chroot=s' => \$OPTIONS{chroot_path},
        'debug' => \$OPTIONS{debug},
        'help|h' => $help
    );

    return if (check_prerequisities());

    if ($actions->{build_docs}) {
        if (scalar(@{$actions->{packages}})) {
            build_doc_for_crate($_, $actions->{version})
                for (@{$actions->{packages}});
        } else {
            build_doc_for_crate();
        }
    } else {
        $help->();
    }

}


&main();

0;

=encoding utf8

=head1 NAME

creates-docs.pl - L<https://crates.io> documentation generator

=head1 SYNOPSIS

./crates-docs.pl -b I<package>

=head1 DESCRIPTION

This script is an attempt to make a centralized documentation repository
for crates available in crates.io. Script is using chroot environment to
build documentation and fixing links on the fly.

=head2 PREPARING CHROOT ENVIRONMENT

This script is using a chroot environment to build documentation. I don't
think it was necessary but I didn't wanted to add bunch of stuff to my
stable server and a little bit more security doesn't hurt anyone.

chroot environment must be placed in B<script_dir/chroot> directory. And
you must install desired version of rustc inside chroot environment. Don't
forget to add a regular user and create a link named B<build_home> which is
pointing to chroot user's home directory.  Make sure regular user is using
same uid with your current user. You can change username of chroot user in
$OPTIONS variable placed on top of this script. By default it is using
I<onur>.

You also need clone crates.io-index respository. You can clone repository
from L<https://github.com/rust-lang/crates.io-index>.

This script is using I<sudo> to use chroot command. chroot is only command
called by sudo in this script. Make sure user has rights to call chroot
command with sudo.

And lastly you need to copy build.sh script into users home directory with
B<.build.sh> name. Make sure chroot user has permissions to execute
B<.build.sh> script.

Directory structure should look like this:

  .
  ├── crates-docs.pl                  # This script
  ├── build_home -> chroot/home/onur  # Sym link to chroot user's home
  ├── chroot                          # chroot environment
  │   ├── bin
  │   ├── etc
  │   ├── home
  │   │   └── onur                    # chroot user's home directory
  │   │       └── .build.sh           # Build script to run cargo doc
  │   └── ...
  ├── crates.io-index                 # Clone of crates.io-index
  │   ├── 1
  │   ├── 2
  │   └── ...
  ├── logs                            # Build logs will be placed here
  │   └── ...
  └── public_html
      └── crates                      # Documentations will be placed here


=head1 ARGS

=over

=item B<-b, --build-documentation> I<crate>

Build documentation of a crate. If no crate name is provided, script will
try to build documentation for all crates.

=item B<-v, --version> I<version>

Build documentation of a crate with given version. Otherwise script will
try to build documentation for all versions. This option must be used with
I<-b> argument and a crate name.

=item B<-s, --skip>

Skip generating if documentation is exist in destination directory.

=item B<--keep-build-directory>

Keep crate files in build directory after operation finishes.

=item B<--destination> I<path>

Destination path. Generated documentation directories will be moved to this
directory. Default value: B<script_dir/public_html/crates>

=item B<--chroot> I<path>

Chroot path. Default value: B<script_dir/chroot>

=item B<--debug>

Show debug messages and place debug info in logs.

=item B<-h, --help>

Show usage information and exit.

=cut

=back

=head1 COPYRIGHT

Copyright 2016 Onur Aslan.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see L<http://www.gnu.org/licenses/>.

=cut
