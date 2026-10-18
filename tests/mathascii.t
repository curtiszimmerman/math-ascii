#!/usr/bin/perl
# Tests for src/mathascii.pl. Run with: prove tests/
#
# The script expects to run inside irssi, so this file supplies a minimal
# stand-in for the Irssi module plus fake server and window item objects. The
# fakes only record what the script asks irssi to do; the logic under test (the
# math, pixel fitting, color encoding, command handling) is the script's own.
use strict;
use warnings;

use Encode ();
use FindBin;
use Test::More;

my (@printed, %commands);

BEGIN {
    $INC{'Irssi.pm'} = __FILE__;
    no strict 'refs';
    *{'main::MSGLEVEL_CLIENTERROR'} = sub { 'CLIENTERROR' };
    *{'main::MSGLEVEL_CLIENTCRAP'}  = sub { 'CLIENTCRAP' };
}

package Irssi {
    sub print        { push @printed, [@_] }
    sub command_bind { $commands{ $_[0] } = $_[1] }
}

package FakeServer {
    sub new     { my ($class, %args) = @_; bless { connected => 1, sent => [], %args }, $class }
    sub command { push @{ $_[0]{sent} }, $_[1] }
}

package FakeItem {
    sub new   { my ($class, %args) = @_; bless { type => 'CHANNEL', name => '#chan', printed => [], %args }, $class }
    sub print { push @{ $_[0]{printed} }, [ $_[1], $_[2] ] }
}

package main;

our ($ZETA_T_MAX, @ZETA_GRADIENT, %PIECES, @QUADRANT);
my $script = "$FindBin::Bin/../src/mathascii.pl";
do $script or die "could not load $script: " . ($@ || $!);

sub strip_colors {
    my ($line) = @_;
    $line =~ s/\x03\d\d(?:,\d\d)?//g;
    return $line;
}

sub close_to {
    my ($got, $want, $name) = @_;
    ok abs($got - $want) < 1e-9, $name or diag "got $got, want $want";
}

# What a cell looks like on screen. A quadrant glyph (including space and the
# full block) is four pixels; anything else is the character in its colors.
my %QUADRANT_BITS = map { $QUADRANT[$_] => $_ } 0 .. 15;

sub cell_look {
    my ($char, $fg, $bg) = @_;
    my $bits = $QUADRANT_BITS{$char};
    return "$char:$fg,$bg" if !defined $bits;
    return join ' ', map { $bits & (1 << $_) ? $fg : $bg } 0 .. 3;
}

# Reads IRC lines back the way a client would, tracking the current colors.
sub decode_looks {
    my ($line) = @_;
    my ($fg, $bg) = ('?', '?');
    my @looks;
    while ($line =~ /\G(?:\x03(\d\d)(?:,(\d\d))?|(.))/gs) {
        if (defined $1) {
            $fg = $1 + 0;
            $bg = $2 + 0 if defined $2;
        } else {
            push @looks, cell_look($3, $fg, $bg);
        }
    }
    return @looks;
}

sub canvas_looks {
    my ($row) = @_;
    return map { cell_look(@$_) } @$row;
}

is $commands{math}, 'cmd_math', '/math is bound';

subtest 'zeta matches reference values' => sub {
    my $pi = 4 * atan2(1, 1);
    my @z = zeta(2, 0);
    close_to $z[0], $pi**2 / 6, 'zeta(2) = pi^2/6';
    close_to $z[1], 0, 'zeta(2) is real';

    @z = zeta(0.5, 0);
    close_to $z[0], -1.4603545088095868, 'zeta(1/2)';

    # Reference values from mpmath 1.3.0.
    @z = zeta(0.5, 10);
    close_to $z[0], 1.54489522029675, 'zeta(1/2 + 10i) real part';
    close_to $z[1], -0.115336465271273, 'zeta(1/2 + 10i) imaginary part';
    @z = zeta(0.5, 25);
    close_to $z[0], 0.00498459336403568, 'zeta(1/2 + 25i) real part';
    close_to $z[1], -0.0140123019625834, 'zeta(1/2 + 25i) imaginary part';
    @z = zeta(2, 3);
    close_to $z[0], 0.798021985146276, 'zeta(2 + 3i) real part';
    close_to $z[1], -0.113744308052939, 'zeta(2 + 3i) imaginary part';

    for my $t (14.134725141734695, 21.022039638771556, 25.01085758014569) {
        my ($re, $im) = zeta(0.5, $t);
        ok sqrt($re**2 + $im**2) < 1e-9, "vanishes at the zero t = $t";
    }
};

subtest 'direction_char' => sub {
    is direction_char(1, 0),   '-',  'flat';
    is direction_char(-1, 0),  '-',  'flat, moving left';
    is direction_char(0, 1),   '|',  'vertical';
    is direction_char(1, 1),   '/',  'rising';
    is direction_char(-1, -1), '/',  'rising, travelled backwards';
    is direction_char(1, -1),  '\\', 'falling';
    is direction_char(1, 0.3), '-',  'shallow rise rounds to flat';
};

subtest 'irc_lines' => sub {
    my $full  = $QUADRANT[15];
    my $upper = $QUADRANT[3];
    my $lower = $QUADRANT[12];

    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ], [ 'b', 52, 88 ] ] ]) ], ["\x0352,88ab"],
        'a run of the same colors needs one code';
    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ], [ '1', 60, 88 ] ] ]) ], ["\x0352,88a\x03601"],
        'a foreground change alone writes only the foreground, in two digits';
    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ], [ ',', 60, 88 ] ] ]) ], ["\x0352,88a\x0360,88,"],
        'a comma after a foreground-only code would read as a background, so write both';
    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ], [ 'b', 52, 89 ] ] ]) ], ["\x0352,88a\x0352,89b"],
        'a background change writes both';
    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ], [ ' ', 60, 88 ] ] ]) ], ["\x0352,88a "],
        'a space only needs its background';
    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ], [ $full, 52, 60 ] ] ]) ], ["\x0352,88a$full"],
        'a full block only needs its foreground';
    is_deeply [ irc_lines([ [ [ $upper, 52, 60 ], [ $lower, 60, 52 ] ] ]) ], ["\x0352,60$upper$upper"],
        'a block flips to its complement when that saves a code';
    is_deeply [ irc_lines([ [ [ 'a', 52, 88 ] ], [ [ 'a', 52, 88 ] ] ]) ], [ "\x0352,88a", "\x0352,88a" ],
        'every line starts with its own colors';
};

subtest 'quadrant_cell' => sub {
    is cell_look(@{ quadrant_cell(52, 52, 52, 52) }), '52 52 52 52', 'one color';
    is cell_look(@{ quadrant_cell(52, 60, 60, 52) }), '52 60 60 52', 'two colors come out exactly';
    is cell_look(@{ quadrant_cell(52, 52, 60, 64) }), '52 52 60 52',
        'with three colors, the odd one out takes the nearest of the other two';
    is cell_look(@{ quadrant_cell(88, 89, 92, 98) }), '89 89 89 98',
        'with four colors, keeps the pair that fits all four best';
};

subtest 'gradient_rgb' => sub {
    my @stops = ([ 0, 0, 0, 0 ], [ 0.5, 100, 200, 0 ], [ 1, 200, 200, 200 ]);
    is_deeply [ gradient_rgb(\@stops, 0.25) ], [ 50, 100, 0 ], 'blends between the stops either side';
    is_deeply [ gradient_rgb(\@stops, 0.5) ], [ 100, 200, 0 ], 'lands exactly on a stop';
    is_deeply [ gradient_rgb(\@stops, 0.75) ], [ 150, 200, 100 ], 'blends in the second stretch';
    is_deeply [ gradient_rgb(\@stops, -1) ], [ 0, 0, 0 ], 'before the first stop is the first color';
    is_deeply [ gradient_rgb(\@stops, 7) ], [ 200, 200, 200 ], 'past the last stop is the last color';
};

subtest 'nearest_color' => sub {
    is nearest_color(255, 140, 0), 53, 'an exact palette color is itself';
    is nearest_color(250, 145, 10), 53, 'a near miss snaps to it';
    is nearest_color(128, 128, 128), 94, 'mid gray goes to the closest gray';
};

subtest 'pixels_to_canvas' => sub {
    my $canvas = pixels_to_canvas([ [ 52, 60, 88, 88 ], [ 60, 52, 88, 98 ] ]);
    is scalar @$canvas, 1, 'two pixel rows make one text row';
    is_deeply [ canvas_looks($canvas->[0]) ], [ '52 60 60 52', '88 88 88 98' ],
        'each cell takes a 2x2 block, left to right, top to bottom';
};

subtest 'mandelbrot_escape' => sub {
    for my $x (0, 0.24, -1, -1.9) {
        is mandelbrot_escape($x, 0, 500), undef, "c = $x stays bounded";
    }
    is mandelbrot_escape(-0.5, 0.5, 500), undef, 'a point inside the main cardioid stays bounded';
    for my $x (0.26, 0.5, 1, -2.05) {
        ok defined mandelbrot_escape($x, 0, 500), "c = $x escapes";
    }
    my @times = map { mandelbrot_escape($_, 0, 500) } 0.26, 0.3, 0.5, 1, 2;
    is_deeply [ sort { $b <=> $a } @times ], \@times,
        'escape time shrinks steadily moving away from the set';
    ok abs(mandelbrot_escape(0.5, 0, 500) - mandelbrot_escape(0.5001, 0, 500)) < 0.01,
        'escape time is smooth, not stepped';
};

subtest 'pieces' => sub {
    for my $name (sort keys %PIECES) {
        my $canvas = $PIECES{$name}->();
        my @lines  = irc_lines($canvas);
        ok @lines >= 10, "$name has a body";

        my $width = length strip_colors($lines[0]);
        is_deeply [ grep { length strip_colors($_) != $width } @lines ], [],
            "$name: every line is the same width, so the background forms a block";
        is_deeply [ grep { length(Encode::encode_utf8($_)) > 400 } @lines ], [],
            "$name: every line fits in one IRC message";
        is_deeply [ map { [ decode_looks($_) ] } @lines ], [ map { [ canvas_looks($_) ] } @$canvas ],
            "$name: a client reading the lines sees exactly the canvas";
    }
};

subtest 'zeta piece' => sub {
    is_deeply [ grep { /[^\x03\x20-\x7e]/ } irc_lines(zeta_canvas()) ], [],
        'pure ASCII apart from color codes';

    my @origin = plot_cell(0, 0);
    for my $t (14.134725141734695, 21.022039638771556, 25.01085758014569) {
        is_deeply [ plot_cell(zeta(0.5, $t)) ], \@origin, "the zero at t = $t lands on the origin";
    }

    my $canvas = zeta_canvas();
    my ($row, $col) = plot_cell(zeta(0.5, 0));
    is $canvas->[$row][$col][1], $ZETA_GRADIENT[0], 'the curve starts in the first gradient color';
    ($row, $col) = plot_cell(zeta(0.5, $ZETA_T_MAX));
    is $canvas->[$row][$col][1], $ZETA_GRADIENT[-1], 'the curve ends in the last gradient color';
};

subtest 'cmd_math with no piece lists the pieces' => sub {
    my $server = FakeServer->new;
    my $item   = FakeItem->new;
    cmd_math('', $server, $item);
    is_deeply $item->{printed}, [ [ 'math: pieces: mandelbrot zeta', 'CLIENTCRAP' ] ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

subtest 'cmd_math sends the piece to the window' => sub {
    my $server = FakeServer->new;
    cmd_math(' zeta ', $server, FakeItem->new(name => '#math'));
    is_deeply $server->{sent}, [ map { "MSG #math $_" } irc_lines(zeta_canvas()) ];
};

subtest 'cmd_math -p previews without sending' => sub {
    my $server = FakeServer->new;
    my $item   = FakeItem->new;
    cmd_math('-p zeta', $server, $item);
    is_deeply $item->{printed}, [ map { [ $_, 'CLIENTCRAP' ] } irc_lines(zeta_canvas()) ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

subtest 'cmd_math refuses bad input' => sub {
    my $item = FakeItem->new;
    cmd_math('nope', FakeServer->new, $item);
    is_deeply $item->{printed}, [ [ 'math: no piece called "nope". pieces: mandelbrot zeta', 'CLIENTERROR' ] ],
        'unknown piece';

    @printed = ();
    cmd_math('zeta', FakeServer->new(connected => 0), FakeItem->new);
    is_deeply \@printed, [ [ 'math: not connected to a server', 'CLIENTERROR' ] ],
        'disconnected server';

    @printed = ();
    cmd_math('zeta', FakeServer->new, undef);
    is_deeply \@printed, [ [ 'math: not in a channel or query window', 'CLIENTERROR' ] ],
        'no window item';
};

done_testing;
