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
use Getopt::Long;
use Pod::Usage;


=pod

=head1 NAME

create-docs.pl - Central documentation repository for L<https://crates.io>

=head1 SYNOPSIS

./crate-docs.pl -b I<package>

=head1 ARGS

=over

=item B<-b, --build-documentation> I<package>

Builds documentation of a package. If no package provided, script will
try to build documentation for all crates.

=back

=cut



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

    # Opening log file
    make_path($FindBin::Bin . "/logs/$crate");
    open my $logfh, '>' . $FindBin::Bin . "/logs/$crate/$crate-$version.log";
    local $Log::Message::Simple::MSG_FH = \*$logfh;
    local $Log::Message::Simple::ERROR_FH = \*$logfh;
    local $Log::Message::Simple::DEBUG_FH = \*$logfh;

    print "Building documentation for: $crate-$version\n";
    msg("Building documentation for: $crate-$version", 1);

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

    # Remove old documentation for same version just in case
    debug("Removing old documentation in public_html/crates", 1);
    msg((run_('rm', '-rf',
             $FindBin::Bin . '/public_html/crates/' .
             $crate . '/' . $version))[0], 1);

    make_path($FindBin::Bin . '/public_html/crates/' . $crate . '/' . $version);

    msg("Moving documentation into: " .
        $FindBin::Bin . '/public_html/crates/' .
        $crate . '/' . $version, 1);
    my $crate_dname = $crate; $crate_dname =~ s/-/_/g;
    copy_doc($FindBin::Bin .
                "/build_home/$crate-$version/target/doc/$crate_dname",
             $FindBin::Bin . '/public_html/crates/' . $crate . '/' . $version);
    # Copy source as well
    # FIXME: 80+
    copy_doc($FindBin::Bin . "/build_home/$crate-$version/target/doc/src/$crate_dname",
             $FindBin::Bin . '/public_html/crates/' . $crate . '/' . $version . '/src');
    # and copy search-index.js
    msg((run_('cp', '-v',
              $FindBin::Bin . "/build_home/$crate-$version" .
              "/target/doc/search-index.js",
              $FindBin::Bin . '/public_html/crates/' .
              $crate . '/' . $version))[0], 1);

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


sub main {

    my $help = sub {
        pod2usage(-verbose  => 2,
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
        'help|h' => $help
    );

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
