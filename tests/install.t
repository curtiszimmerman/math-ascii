#!/usr/bin/perl
# Tests for scripts/install.sh. Run with: prove tests/
#
# Every run points the installer at a scratch irssi home, so nothing touches
# your real ~/.irssi.
use strict;
use warnings;

use File::Temp ();
use FindBin;
use Test::More;

my $install = "$FindBin::Bin/../scripts/install.sh";
my $source  = "$FindBin::Bin/../src/mathascii.pl";

sub run_install {
    my @args = @_;
    my $output = `"$install" @args 2>&1`;
    return ($? >> 8, $output);
}

sub slurp { local (@ARGV, $/) = @_; return <> }

subtest 'installs into the scripts directory' => sub {
    my $home = File::Temp->newdir;
    my ($status, $output) = run_install('--home', $home);
    is $status, 0, 'succeeds';
    is slurp("$home/scripts/mathascii.pl"), slurp($source), 'the installed copy is the script';
    like $output, qr{installed \Q$home\E/scripts/mathascii\.pl}, 'says where it went';
    like $output, qr{/script load mathascii}, 'says how to load it';
    ok !-e "$home/scripts/autorun/mathascii.pl", 'does not autorun unless asked';
};

subtest 'replaces an older copy' => sub {
    my $home = File::Temp->newdir;
    mkdir "$home/scripts";
    open my $old, '>', "$home/scripts/mathascii.pl" or die $!;
    print $old "old\n";
    close $old;
    my ($status) = run_install('--home', $home);
    is $status, 0, 'succeeds';
    is slurp("$home/scripts/mathascii.pl"), slurp($source), 'the old copy is replaced';
};

subtest '--autorun links it into autorun' => sub {
    my $home = File::Temp->newdir;
    my ($status, $output) = run_install('--home', $home, '--autorun');
    is $status, 0, 'succeeds';
    ok -l "$home/scripts/autorun/mathascii.pl", 'autorun has a link';
    is readlink("$home/scripts/autorun/mathascii.pl"), '../mathascii.pl', 'pointing at the installed copy';
    like $output, qr{irssi will load it at startup}, 'and says so';

    ($status) = run_install('--home', $home, '--autorun');
    is $status, 0, 'running it again is fine';
};

subtest 'refuses what it does not understand' => sub {
    my ($status, $output) = run_install('--bogus');
    isnt $status, 0, 'fails on an unknown option';
    like $output, qr{unknown option: --bogus}, 'names it';
    like $output, qr{usage:}i, 'and shows usage';

    ($status, $output) = run_install('--home');
    isnt $status, 0, 'fails when --home has no directory';
    like $output, qr{--home needs a directory}, 'and says so';

    ($status, $output) = run_install('--help');
    is $status, 0, '--help is not an error';
    like $output, qr{^Usage: scripts/install\.sh}, 'and starts right in on the usage';
};

done_testing;
