#!/usr/bin/perl
# Renders a mathascii piece outside irssi, for checking the art and timing it.
#
# Usage: scripts/render.pl [--plain] [--time] [--png FILE] <piece>
#        scripts/render.pl [...] --mandelbrot CX,CY,HALF_HEIGHT,MAX_STEPS,GLOW_FROM,GLOW_TO
#
#   (default)   prints the raw IRC lines, color codes and all
#   --plain     strips the color codes so you can see the shape
#   --time      reports how long the render took on stderr
#   --png FILE  also draws the piece as it would look in a client, using
#               ImageMagick and DejaVu Sans Mono, so you can see the colors
#   --mandelbrot  renders any Mandelbrot view instead of a named piece, for
#               hunting down new zooms. The numbers are mandelbrot_view's.
use strict;
use warnings;

use File::Temp ();
use FindBin;
use Getopt::Long;
use Time::HiRes ();

my ($plain, $time, $png, $view);
GetOptions('plain' => \$plain, 'time' => \$time, 'png=s' => \$png, 'mandelbrot=s' => \$view)
    && @ARGV == ($view ? 0 : 1)
    or die "usage: $0 [--plain] [--time] [--png FILE] <piece | --mandelbrot CX,CY,HALF_HEIGHT,MAX_STEPS,GLOW_FROM,GLOW_TO>\n";
my $name = $view ? "mandelbrot view $view" : $ARGV[0];

# The script talks to irssi when it loads. Outside irssi these do nothing.
BEGIN {
    $INC{'Irssi.pm'} = __FILE__;
    no strict 'refs';
    *{'main::MSGLEVEL_CLIENTERROR'} = sub { 0 };
    *{'main::MSGLEVEL_CLIENTCRAP'}  = sub { 0 };
    *{'main::INPUT_READ'}           = sub { 0 };
    # Returns true because the script's last statement is its load result.
    *{'Irssi::command_bind'}        = sub { 1 };
}

our (%PIECES, @QUADRANT, %RGB);
my $script = "$FindBin::Bin/../src/mathascii.pl";
do $script or die "could not load $script: " . ($@ || $!);

my $canvas_for;
if ($view) {
    my @numbers = split /,/, $view;
    @numbers == 6 or die "--mandelbrot needs six comma-separated numbers, got \"$view\"\n";
    my %args;
    @args{qw(center_x center_y half_height max_steps glow_from glow_to)} = @numbers;
    $canvas_for = sub { mandelbrot_view(%args) };
} else {
    my $piece = $PIECES{$name} or die "no piece called \"$name\". pieces: @{[ sort keys %PIECES ]}\n";
    $canvas_for = $piece->{draw};
}
my $start  = Time::HiRes::time();
my $canvas = $canvas_for->();
my @lines  = irc_lines($canvas);
printf STDERR "rendered %s in %.2fs\n", $name, Time::HiRes::time() - $start if $time;

binmode STDOUT, ':encoding(UTF-8)';
for my $line (@lines) {
    $line =~ s/\x03\d\d(?:,\d\d)?//g if $plain;
    print "$line\n";
}

draw_png($canvas, $png) if $png;

sub draw_png {
    my ($canvas, $file) = @_;
    my ($cell_w, $cell_h) = (10, 20);
    my %bits = map { $QUADRANT[$_] => $_ } 0 .. 15;
    my $font = '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf';
    -f $font or die "render.pl: --png needs $font\n";

    my $mvg = sprintf "viewbox 0 0 %d %d\nfont '%s'\nfont-size 16\n",
        $cell_w * @{ $canvas->[0] }, $cell_h * @$canvas, $font;
    for my $r (0 .. $#$canvas) {
        for my $c (0 .. $#{ $canvas->[$r] }) {
            my ($char, $fg, $bg) = @{ $canvas->[$r][$c] };
            my ($x, $y) = ($c * $cell_w, $r * $cell_h);
            $mvg .= rect($bg, $x, $y, $cell_w, $cell_h);
            if (defined(my $b = $bits{$char})) {
                my ($hw, $hh) = ($cell_w / 2, $cell_h / 2);
                $mvg .= rect($fg, $x,       $y,       $hw, $hh) if $b & 1;
                $mvg .= rect($fg, $x + $hw, $y,       $hw, $hh) if $b & 2;
                $mvg .= rect($fg, $x,       $y + $hh, $hw, $hh) if $b & 4;
                $mvg .= rect($fg, $x + $hw, $y + $hh, $hw, $hh) if $b & 8;
            } else {
                (my $text = $char) =~ s/(['\\])/\\$1/g;
                $mvg .= sprintf "fill '#%s'\ntext %d,%d '%s'\n", $RGB{$fg}, $x, $y + 15, $text;
            }
        }
    }

    my $tmp = File::Temp->new(SUFFIX => '.mvg');
    binmode $tmp, ':encoding(UTF-8)';
    print $tmp $mvg;
    close $tmp;
    system('convert', "mvg:$tmp", $file) == 0 or die "render.pl: convert failed drawing $file\n";
    print STDERR "drew $file\n";
}

sub rect {
    my ($color, $x, $y, $w, $h) = @_;
    return sprintf "fill '#%s'\nrectangle %d,%d %d,%d\n", $RGB{$color}, $x, $y, $x + $w - 1, $y + $h - 1;
}
