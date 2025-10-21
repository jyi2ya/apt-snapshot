#!/usr/bin/env perl
use 5.036;
use utf8;
use warnings 'all';
use autodie ':all';

utf8::decode($_) for @ARGV;

my $VERSION = '0.1.0';

use JSON::PP;
use Getopt::Long;
use List::Util qw/uniq/;
use Dpkg::Control;
use File::Temp qw/tempfile/;

sub apt_install (@packages) {
    system 'apt', 'instsall', @packages;
}

sub apt_mark_auto (@packages) {
    system 'apt-mark', 'auto', @packages;
}

sub parse_apt_output ($content) {
    my @result = grep { ! /^\s*$/ } map { s/#.*$//r  } split /\n/, $content;
    \@result
}

sub serialize_snapshot ($snapshot) {
    JSON::PP::encode_json {
        version => $VERSION,
        data => $snapshot,
    };
}

sub deserialize_snapshot ($bytes) {
    my $data = JSON::PP::decode_json $bytes;
    $data->{data};
}

sub read_snapshot_from_fh ($fh) {
    local $/ = undef;
    my $content = <$fh>;
    deserialize_snapshot($content);
}

sub read_snapshot_file ($filename) {
    open my $fh, '<', $filename;
    read_snapshot_from_fh $fh;
}

sub write_snapshot_file ($snapshot, $filename) {
    my $content = serialize_snapshot($snapshot);
    open my $fd, '>', $filename;
    print $fd $content;
}

sub take_snapshot {
    my $content = do {
        local $/ = undef;
        open my $fd, 'apt-mark showmanual |';
        <$fd>
    };
    parse_apt_output($content);
}

sub diff_snapshot ($old, $new) {
    my %old = map { $_ => undef } @$old;
    my %new = map { $_ => undef } @$new;
    my @installed = grep { !exists($old{$_}) } @$new;
    my @removed = grep { !exists($new{$_}) } @$old;
    (\@installed, \@removed)
}

sub pack_installed ($installed, $name) {
    my $equivs = Dpkg::Control->new();

    $equivs->{Package} = "$name-deps";
    $equivs->{Version} = '1.0';
    $equivs->{Architecture} = 'all';
    $equivs->{Depends} = join ", ", @$installed;
    $equivs->{Description} = "Dependencies meta-package for $name";

    my ($fh, $equivs_filename) = tempfile;
    print $fh $equivs->output();
    close $fh;

    system('equivs-build', $equivs_filename);

    unlink "$equivs->{Package}_$equivs->{Version}_amd64.buildinfo";
    unlink "$equivs->{Package}_$equivs->{Version}_amd64.changes";
}

sub find_snapshot_inputs (@argv) {
    if (@argv == 0) {
        (read_snapshot_from_fh(*STDIN), take_snapshot);
    } elsif (@argv == 1) {
        (read_snapshot_file($argv[0]), take_snapshot);
    } else {
        (read_snapshot_file($argv[0]), read_snapshot_file($argv[1]));
    }
}

sub main {
    my $cmd = shift(@ARGV) or die;

    if ($cmd eq 'take') {
        my $filename = shift @ARGV;
        my $snapshot = take_snapshot;
        if ($filename) {
            write_snapshot_file($snapshot, $filename);
        } else {
            say serialize_snapshot($snapshot);
        }
    } elsif ($cmd eq 'apply') {
        my $filename = shift @ARGV;
        my $snapshot = do {
            if ($filename) {
                read_snapshot_file($filename);
            } else {
                read_snapshot_from_fh(*STDIN);

                # interactive apt needs this
                open STDIN, '<', '/dev/tty';
            }
        };
        my $current = take_snapshot;
        my ($installed, $removed) = diff_snapshot($current, $snapshot);
        if (@$removed) {
            apt_mark_auto @$removed;
        }
        if (@$installed) {
            apt_install @$installed;
        }
    } elsif ($cmd eq 'diff') {
        my $json_output = 0;
        GetOptions( json => \$json_output );

        my ($old, $current) = find_snapshot_inputs(@ARGV);
        my ($installed, $removed) = diff_snapshot($old, $current);
        if ($json_output) {
            say JSON::PP::encode_json {
                installed => $installed,
                removed => $removed,
            };
        } else {
            if (@$installed) {
                say "INSTALLED: ", join ", ", @$installed;
            } else {
                say "NOTHING INSTALLED";
            }
            if (@$removed) {
                say "REMOVED  : ", join ", ", @$removed;
            } else {
                say "NOTHING REMOVED";
            }
        }
    } elsif ($cmd eq 'pack') {
        my $name = undef;
        GetOptions( 'name=s' => \$name );

        my ($old, $current) = find_snapshot_inputs(@ARGV);
        my ($installed, $removed) = diff_snapshot($old, $current);
        pack_installed($installed, $name);
    } else {
        die;
    }
}

main unless caller;
