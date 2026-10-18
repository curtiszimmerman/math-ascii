#!/usr/bin/perl
# Renders a mathascii piece outside irssi, for checking the art and timing it.
#
# Usage: scripts/render.pl [--plain] [--time] <piece>
#
#   (default)  prints the raw IRC lines, color codes and all
#   --plain    strips the color codes so you can see the shape
#   --time     reports how long the render took on stderr
use strict;
use warnings;

use FindBin;
use Getopt::Long;
use Time::HiRes ();

my ($plain, $time);
GetOptions('plain' => \$plain, 'time' => \$time) && @ARGV == 1
    or die "usage: $0 [--plain] [--time] <piece>\n";
my $name = $ARGV[0];

# The script talks to irssi when it loads. Outside irssi these do nothing.
BEGIN {
    $INC{'Irssi.pm'} = __FILE__;
    no strict 'refs';
    *{'main::MSGLEVEL_CLIENTERROR'} = sub { 0 };
    *{'main::MSGLEVEL_CLIENTCRAP'}  = sub { 0 };
    # Returns true because the script's last statement is its load result.
    *{'Irssi::command_bind'}        = sub { 1 };
}

my $script = "$FindBin::Bin/../src/mathascii.pl";
do $script or die "could not load $script: " . ($@ || $!);

my $render = main->can("render_$name") or die "no piece called \"$name\"\n";
my $start  = Time::HiRes::time();
my @lines  = $render->();
printf STDERR "rendered %s in %.2fs\n", $name, Time::HiRes::time() - $start if $time;

for my $line (@lines) {
    $line =~ s/\x03\d\d,\d\d//g if $plain;
    print "$line\n";
}
