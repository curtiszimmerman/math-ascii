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
use Time::HiRes ();

my (@printed, %commands, %servers, %inputs, @waiting_pids);
my $next_tag = 0;

BEGIN {
    $INC{'Irssi.pm'} = __FILE__;
    no strict 'refs';
    *{'main::MSGLEVEL_CLIENTERROR'} = sub { 'CLIENTERROR' };
    *{'main::MSGLEVEL_CLIENTCRAP'}  = sub { 'CLIENTCRAP' };
    *{'main::INPUT_READ'}           = sub { 'READ' };
}

package Irssi {
    sub print           { push @printed, [@_] }
    sub command_bind    { $commands{ $_[0] } = $_[1] }
    sub server_find_tag { $servers{ $_[0] } }
    sub pidwait_add     { push @waiting_pids, $_[0] }
    sub input_remove    { delete $inputs{ $_[0] } }

    sub input_add {
        my ($fd, $condition, $func, $data) = @_;
        $inputs{ ++$next_tag } = [ $func, $data ];
        return $next_tag;
    }
}

package FakeServer {
    sub new {
        my ($class, %args) = @_;
        my $self = bless { connected => 1, sent => [], items => {}, tag => 'net' . ++$next_tag, %args }, $class;
        $servers{ $self->{tag} } = $self;
        return $self;
    }
    sub command          { push @{ $_[0]{sent} }, $_[1] }
    sub window_item_find { $_[0]{items}{ $_[1] } }
    sub add_item         { my ($self, %args) = @_; $self->{items}{ $args{name} } = FakeItem->new(%args) }
    sub remove_item      { delete $_[0]{items}{ $_[1] } }
}

package FakeItem {
    sub new   { my ($class, %args) = @_; bless { type => 'CHANNEL', name => '#chan', printed => [], %args }, $class }
    sub print { push @{ $_[0]{printed} }, [ $_[1], $_[2] ] }
}

package main;

our ($ZETA_T_MAX, @ZETA_HUES, %PIECES, @QUADRANT, %RENDERED, @SHUFFLE_BAG, $GOLDEN_ANGLE, $GOSPER_GUN, $SANDPILE_GRAINS, $SANDPILE_SIZE);
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

subtest 'glow_rgb' => sub {
    my @base = (0, 0, 20);
    my @hue  = (200, 100, 0);
    is_deeply [ glow_rgb(\@base, \@hue, 0) ], \@hue, 'on the line is the full hue';
    is_deeply [ glow_rgb(\@base, \@hue, 50) ], \@base, 'far from the line is the background';
    my @near = glow_rgb(\@base, \@hue, 1.5);
    my @far  = glow_rgb(\@base, \@hue, 2.5);
    ok $near[0] > $far[0] && $far[0] > 0, 'the glow fades with distance';
};

subtest 'draw_glow_curve' => sub {
    my @rgb = map { [ map { [ 0, 0, 0 ] } 1 .. 20 ] } 1 .. 10;
    my @hues = ([ 0, 255, 0, 0 ], [ 1, 0, 0, 255 ]);

    # Two strands: a red one through (5, 5) and a blue one through (5, 7).
    draw_glow_curve(\@rgb, [ [ 5, 5, 0 ], [ 5, 7, 1 ] ], \@hues);
    is_deeply $rgb[5][5], [ 255, 0, 0 ], 'full hue on the curve';
    is_deeply $rgb[5][7], [ 0, 0, 255 ], 'each point takes its own hue';
    is_deeply $rgb[5][6], [ 255, 0, 0 ], 'between strands, the first one at the same distance keeps it';
    ok $rgb[5][9][2] > 0 && $rgb[5][9][2] < 255, 'it glows a little way off';
    is_deeply $rgb[5][15], [ 0, 0, 0 ], 'and leaves far pixels alone';
    is_deeply $rgb[9][5], [ 0, 0, 0 ], 'rows count double, since pixels are twice as tall as wide';

    my @thin = map { [ map { [ 0, 0, 0 ] } 1 .. 20 ] } 1 .. 10;
    draw_glow_curve(\@thin, [ [ 5, 5, 0 ] ], \@hues, 0.4);
    is_deeply $thin[5][5], [ 255, 0, 0 ], 'a thinner line still has its hue at the center';
    is_deeply $thin[5][7], [ 0, 0, 0 ], 'but stops sooner';

    # A blue strand passing in front of a red one: the fourth number is how
    # near the viewer each point is.
    my @deep = map { [ map { [ 0, 0, 0 ] } 1 .. 20 ] } 1 .. 10;
    draw_glow_curve(\@deep, [ [ 5, 5, 0, 0 ], [ 5, 7, 1, 1 ] ], \@hues);
    my @alone = map { [ map { [ 0, 0, 0 ] } 1 .. 20 ] } 1 .. 10;
    draw_glow_curve(\@alone, [ [ 5, 5, 0 ] ], \@hues);
    ok $deep[5][5][0] == 0 && $deep[5][5][2] > 0, 'a strand in front covers the one behind with its fading glow';
    is_deeply $deep[5][7], [ 0, 0, 255 ], 'and is drawn in full';
    is_deeply $deep[5][2], $alone[5][2], 'the strand behind shows as usual beyond the reach of the one in front';
};

subtest 'lorenz_points' => sub {
    my @points = lorenz_points(4000);
    is scalar @points, 4000, 'one point per step';
    is_deeply [ grep { abs($_->[0]) > 25 || abs($_->[1]) > 30 || $_->[2] < 0 || $_->[2] > 55 } @points ], [],
        'the trajectory stays inside the attractor\'s bounding box';
    ok((grep { $_->[0] > 5 } @points) && (grep { $_->[0] < -5 } @points), 'and loops around both wings');
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
        is_deeply [ mandelbrot_escape($x, 0, 500) ], [], "c = $x stays bounded";
    }
    is_deeply [ mandelbrot_escape(-0.5, 0.5, 500) ], [], 'a point inside the main cardioid stays bounded';
    for my $x (0.26, 0.5, 1, -2.05) {
        ok defined mandelbrot_escape($x, 0, 500), "c = $x escapes";
    }

    my @times = map { scalar mandelbrot_escape($_, 0, 500) } 0.26, 0.3, 0.5, 1, 2;
    is_deeply [ sort { $b <=> $a } @times ], \@times,
        'escape time shrinks steadily moving away from the set';
    ok abs(mandelbrot_escape(0.5, 0, 500) - mandelbrot_escape(0.5001, 0, 500)) < 0.01,
        'escape time is smooth, not stepped';

    # c = -1.3 sits in the period-4 bulb, outside the cardioid and big-bulb
    # shortcuts. Iterating all ten million steps would take many seconds, so
    # finishing fast means the cycle check caught it.
    my $start = Time::HiRes::time();
    is_deeply [ mandelbrot_escape(-1.3, 0, 10_000_000) ], [], 'c = -1.3 stays bounded';
    ok Time::HiRes::time() - $start < 1, 'and is recognized as cycling instead of iterated to the limit';
};

subtest 'escape_time' => sub {
    # With c = 0 the map is z -> z^2, so anything inside the unit circle
    # stays and anything outside runs away: the Julia set is the circle.
    is_deeply [ escape_time(0.5, 0.5, 0, 0, 500) ], [], 'inside the unit circle stays bounded when c = 0';
    ok defined escape_time(0.8, 0.7, 0, 0, 500), 'outside the unit circle escapes when c = 0';
    is_deeply [ escape_time(0, 0, -0.123, 0.745, 1_000_000) ], [],
        'the rabbit\'s critical point cycles, and is caught doing so';
    is scalar escape_time(0, 0, 0.5, 0, 500), scalar mandelbrot_escape(0.5, 0, 500),
        'starting from 0 it agrees with the Mandelbrot escape';
};

subtest 'newton_basin' => sub {
    my ($root, $steps) = newton_basin(2, 0, 100);
    is $root, 0, 'z = 2 slides to the root at 1';
    is +(newton_basin(-1, sqrt 3, 100))[0], 1, 'a point out along the second root\'s ray goes to it';
    is +(newton_basin(-1, -sqrt 3, 100))[0], 2, 'and likewise the third';
    is_deeply [ newton_basin(0, 0, 100) ], [], 'z = 0 has no tangent to follow and goes nowhere';

    # Rotating the start by a third of a turn rotates the whole iteration, so
    # it lands on the next root after just as many steps.
    my ($x, $y) = (0.3, 0.9);
    my ($c, $s) = (cos(2 * 3.14159265358979 / 3), sin(2 * 3.14159265358979 / 3));
    my ($root_a, $steps_a) = newton_basin($x, $y, 100);
    my ($root_b, $steps_b) = newton_basin($x * $c - $y * $s, $x * $s + $y * $c, 100);
    is $root_b, ($root_a + 1) % 3, 'turning the start a third of a turn moves to the next root';
    ok abs($steps_b - $steps_a) < 1e-6, 'in the same number of steps';

    my @steps = map { (newton_basin($_, 0, 100))[1] } 1.01, 1.1, 1.5, 3, 10;
    is_deeply [ sort { $a <=> $b } @steps ], \@steps, 'farther from the root takes longer';
    ok abs((newton_basin(1.5, 0, 100))[1] - (newton_basin(1.5001, 0, 100))[1]) < 0.01,
        'the step count is smooth, not whole steps';
};

subtest 'ulam_spiral' => sub {
    # 1 in the middle, 2 to its right, then counterclockwise, with y up.
    is_deeply [ ulam_spiral(10) ],
        [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ], [ 0, 1 ], [ -1, 1 ], [ -1, 0 ], [ -1, -1 ], [ 0, -1 ], [ 1, -1 ], [ 2, -1 ] ];
    my @spiral = ulam_spiral(441);
    is_deeply $spiral[-1], [ 10, -10 ], 'the 21x21 square closes at its bottom right corner';
    my %seen;
    is_deeply [ grep { $seen{"@$_"}++ } @spiral ], [], 'no square is used twice';
};

subtest 'primes_up_to' => sub {
    my $is_prime = primes_up_to(30);
    is_deeply [ grep { $is_prime->[$_] } 0 .. 30 ], [ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29 ];
};

subtest 'escape_time with the burning ship fold' => sub {
    for my $x (-1.9, -1, 0, 0.2, 0.3, 1) {
        is_deeply [ escape_time(0, 0, $x, 0, 500, 1) ], [ escape_time(0, 0, $x, 0, 500) ],
            "on the real axis the fold changes nothing (c = $x)";
    }
    # Worked by hand: with the fold, c = i goes (0,1) (-1,1) (0,3) (-9,1)
    # (80,19) (6039,3041) and is gone, where plain z^2 + c cycles forever.
    is_deeply [ escape_time(0, 0, 0, 1, 500) ], [], 'c = i cycles without the fold';
    ok defined escape_time(0, 0, 0, 1, 500, 1), 'and escapes with it';
};

subtest 'escape_time with a higher power' => sub {
    # z^3 + i goes 0, i, -i + i = 0, i, ... round a cycle.
    is_deeply [ escape_time(0, 0, 0, 1, 500, 0, 0, 3) ], [], 'z^3 + i cycles';
    my ($x, $step) = (0, 0);
    ($x, $step) = ($x**3 + 0.5, $step + 1) until $x**2 > 65536;
    is sprintf('%.9f', escape_time(0, 0, 0.5, 0, 500, 0, 0, 3)), sprintf('%.9f', $step + 1 - log(log($x**2) / 2) / log(3)),
        'c = 0.5 escapes when cubing just as it does by hand';
    my @lopsided = grep { (escape_time(0, 0, @$_, 300, 0, 0, 3) // -1) != (escape_time(0, 0, -$_->[0], -$_->[1], 300, 0, 0, 3) // -1) }
        [ 0.3, 0.6 ], [ -0.4, 0.9 ], [ 0.55, 0.1 ], [ 0.1, 1.1 ];
    is_deeply \@lopsided, [], 'the z^3 + c set looks the same turned half way round';
    is escape_time(0, 0, 0.3, 0.6, 300, 0, 0, 2), escape_time(0, 0, 0.3, 0.6, 300), 'power 2 is the Mandelbrot set';
};

subtest 'fern_points' => sub {
    my @points = fern_points(20_000);
    is scalar @points, 20_000, 'one point per step';
    is_deeply [ grep { $_->[0] < -2.19 || $_->[0] > 2.66 || $_->[1] < 0 || $_->[1] > 10 } @points ], [],
        'every point is inside the fern\'s bounding box';
    ok((grep { $_->[0] < -1.5 } @points) && (grep { $_->[0] > 1.5 } @points) && (grep { $_->[1] > 9 } @points),
        'and they reach out to both sides and up to the tip');
    is_deeply [ fern_points(500) ], [ @points[ 0 .. 499 ] ], 'the same every time';
};

subtest 'clifford_points' => sub {
    my @points = clifford_points(5000);
    is scalar @points, 5000, 'one point per step';
    is_deeply [ grep { abs($_->[0]) > 2 || abs($_->[1]) > 1.7 } @points ], [],
        'x stays within 1 + |c| and y within 1 + |d|, since sin and cos do';
    my %distinct = map { sprintf('%.3f,%.3f', @$_) => 1 } @points;
    ok keys(%distinct) > 3000, 'and it never settles down';
};

subtest 'spirograph_points' => sub {
    my $gap = sub { sqrt(($_[0][0] - $_[1][0])**2 + ($_[0][1] - $_[1][1])**2) };
    for ([ 8, 5, 5, 5 ], [ 9, 6, 4, 2 ], [ 10, 4, 3, 2 ]) {
        my ($R, $r, $d, $trips) = @$_;
        my @points = spirograph_points($R, $r, $d, 600);
        ok $gap->(@points[ 0, -1 ]) < 1e-9, "R=$R r=$r closes after $trips trips round the ring";
        my @early = grep { $gap->($points[0], $points[ $_ * 600 / $trips ]) < 1e-6 } 1 .. $trips - 1;
        is_deeply \@early, [], 'and not before';
    }
};

subtest 'life' => sub {
    my $cells = sub { [ sort map { "@$_" } @_ ] };
    my $board = sub { my %alive = map { ("$_->[0],$_->[1]" => 1) } @_; return \%alive };
    my $listed = sub { [ sort map { join ' ', split /,/ } keys %{ $_[0] } ] };

    is_deeply $cells->(rle_cells('bo$2bo$3o!')), $cells->([ 1, 0 ], [ 2, 1 ], [ 0, 2 ], [ 1, 2 ], [ 2, 2 ]), 'reads a glider in RLE';

    my $blinker = $board->([ 0, 1 ], [ 1, 1 ], [ 2, 1 ]);
    is_deeply $listed->(life_step($blinker)), $cells->([ 1, 0 ], [ 1, 1 ], [ 1, 2 ]), 'a blinker turns upright';
    is_deeply $listed->(life_step(life_step($blinker))), $listed->($blinker), 'and back';

    my $block = $board->([ 0, 0 ], [ 1, 0 ], [ 0, 1 ], [ 1, 1 ]);
    is_deeply $listed->(life_step($block)), $listed->($block), 'a block never changes';

    my $glider = $board->(rle_cells('bo$2bo$3o!'));
    my $later  = $glider;
    $later = life_step($later) for 1 .. 4;
    is_deeply $listed->($later), $cells->(map { [ $_->[0] + 1, $_->[1] + 1 ] } rle_cells('bo$2bo$3o!')),
        'a glider moves one cell diagonally every four generations';

    my $gun = $board->(rle_cells($GOSPER_GUN));
    is scalar keys %$gun, 36, 'the glider gun starts with 36 cells';
    $gun = life_step($gun) for 1 .. 30;
    is scalar keys %$gun, 41, 'and after 30 generations has fired one 5-cell glider';
    $gun = life_step($gun) for 1 .. 30;
    is scalar keys %$gun, 46, 'and another 30 later';
};

subtest 'automaton_rows' => sub {
    my $show = sub { join '', map { $_ ? 1 : 0 } @{ $_[0] } };
    my @rows = automaton_rows(30, 7, 3);
    is_deeply [ map { $show->($_) } @rows ], [ '0001000', '0011100', '0110010' ],
        'rule 30 from one cell, worked by hand: 1, 111, 11001';

    # Rule 90 sets each cell to the XOR of its neighbors, which is Pascal's
    # rule mod 2, so from one cell it draws the odd binomial coefficients.
    @rows = automaton_rows(90, 81, 40);
    my @wrong = grep {
        my $n = $_;
        grep { ($rows[$n][ 40 - $n + 2 * $_ ] ? 1 : 0) != (binomial_is_odd($n, $_) ? 1 : 0) } 0 .. $n;
    } 0 .. 39;
    is_deeply \@wrong, [], 'rule 90 is Pascal\'s triangle mod 2';
};

subtest 'sandpile' => sub {
    is_deeply sandpile(4, 3), [ [ 0, 1, 0 ], [ 1, 0, 1 ], [ 0, 1, 0 ] ], 'four grains topple once, one to each neighbor';
    is_deeply sandpile(16, 5), [ [ 0, 0, 1, 0, 0 ], [ 0, 2, 1, 2, 0 ], [ 1, 1, 0, 1, 1 ], [ 0, 2, 1, 2, 0 ], [ 0, 0, 1, 0, 0 ] ],
        'sixteen grains, worked by hand';

    my $pile = sandpile(1000, 41);
    is List::Util::sum(map { @$_ } @$pile), 1000, 'no grain is lost when the grid is big enough';
    is_deeply [ grep { $_ > 3 } map { @$_ } @$pile ], [], 'every pile ends up with at most three grains';
    is_deeply $pile, [ map { my $c = $_; [ map { $_->[$c] } @$pile ] } 0 .. 40 ], 'it is symmetric across the diagonal';
    is_deeply $pile, [ reverse @$pile ], 'and top to bottom';

    my $in_two_goes = sandpile(400, 41);
    $in_two_goes->[20][20] += 600;
    topple($in_two_goes);
    is_deeply $in_two_goes, $pile, 'dropping the grains in two goes ends the same, since toppling order never matters';

    my $edge = sandpile(1000, 9);
    ok List::Util::sum(map { @$_ } @$edge) < 1000, 'on a small grid grains fall off the edge';

    is List::Util::sum(map { @$_ } @{ sandpile($SANDPILE_GRAINS, $SANDPILE_SIZE) }), $SANDPILE_GRAINS,
        'the piece\'s pile fits on its grid';
};

subtest 'langton_ant' => sub {
    my $ant = langton_ant(4);
    is_deeply [ sort keys %{ $ant->{black} } ], [ '0,0', '0,1', '1,0', '1,1' ],
        'on white it turns right each time, so the first four steps paint a square';
    is_deeply [ @$ant{qw(x y heading)} ], [ 0, 0, 0 ], 'and it ends back where it started, facing up';

    $ant = langton_ant(5);
    is_deeply [ sort keys %{ $ant->{black} } ], [ '0,1', '1,0', '1,1' ], 'the fifth step is on black: it turns it white';
    is_deeply [ @$ant{qw(x y heading)} ], [ -1, 0, 3 ], 'and turns left';
    is_deeply [ @{ $ant->{painted} }{ '1,0', '1,1', '0,0' } ], [ 2, 3, 5 ], 'it remembers the step that last flipped each square';

    # After about ten thousand steps of mess the ant starts building a
    # "highway" that repeats every 104 steps, two squares further on.
    my ($early, $late) = (langton_ant(11_000), langton_ant(11_104));
    is_deeply [ map { abs($late->{$_} - $early->{$_}) } qw(x y) ], [ 2, 2 ], 'on the highway it moves two squares diagonally every 104 steps';
    is $late->{heading}, $early->{heading}, 'facing the same way';
    is scalar(keys %{ $late->{black} }) - scalar(keys %{ $early->{black} }), 12, 'and leaves twelve more black squares';
};

subtest 'lyapunov_exponent' => sub {
    # With only A in the sequence it's the plain logistic map at r = a.
    # At r = 2.5 it settles on x = 0.6, where the slope r(1 - 2x) is -0.5.
    ok abs(lyapunov_exponent('A', 2.5, 0, 2000) - log 0.5) < 1e-9, 'a fixed point gives the log of its slope';
    ok abs(lyapunov_exponent('A', 4, 0, 200_000) - log 2) < 0.01, 'at r = 4 it is exactly log 2 (Ulam and von Neumann)';
    ok lyapunov_exponent('A', 3.2, 0, 2000) < 0, 'a period-2 cycle is stable';
    ok lyapunov_exponent('A', 3.9, 0, 2000) > 0, 'r = 3.9 is chaotic';
    is lyapunov_exponent('AB', 3.7, 3.7, 2000), lyapunov_exponent('A', 3.7, 0, 2000), 'with a = b the sequence makes no difference';
    ok abs(lyapunov_exponent('AB', 3.2, 3.5, 2000) - lyapunov_exponent('AB', 3.5, 3.2, 2000)) < 1e-9,
        'swapping a and b only shifts the cycle by a step, which leaves its stability alone';
};

subtest 'ford circles' => sub {
    is join(' ', map { "$_->[0]/$_->[1]" } farey(5)), '0/1 1/5 1/4 1/3 2/5 1/2 3/5 2/3 3/4 4/5 1/1', 'the Farey fractions up to fifths';
    is scalar(my @f = farey(10)), 33, 'there are 1 + (sum of phi(k) for k up to 10) = 33 up to tenths';

    my @fractions = farey(12);
    my @wrong = grep { $fractions[ $_ + 1 ][0] * $fractions[$_][1] - $fractions[$_][0] * $fractions[ $_ + 1 ][1] != 1 } 0 .. $#fractions - 1;
    is_deeply \@wrong, [], 'neighbors p/q < r/s always have rq - ps = 1';

    my $gap = sub {
        my ($c, $d) = map { ford_circle(@$_) } @_;
        return sqrt(($c->[0] - $d->[0])**2 + ($c->[1] - $d->[1])**2) - $c->[2] - $d->[2];
    };
    @wrong = grep { abs($gap->(@fractions[ $_, $_ + 1 ])) > 1e-12 } 0 .. $#fractions - 1;
    is_deeply \@wrong, [], 'so the circles of neighbors touch';
    my @overlapping;
    for my $i (0 .. $#fractions) {
        push @overlapping, grep { $gap->(@fractions[ $i, $_ ]) < -1e-12 } $i + 1 .. $#fractions;
    }
    is_deeply \@overlapping, [], 'and no two circles ever overlap';
    is_deeply ford_circle(1, 2), [ 0.5, 0.125, 0.125 ], 'each one sits on the line, radius 1/(2q^2)';
};

subtest 'square_wave_sum' => sub {
    my $pi = 4 * atan2(1, 1);
    is square_wave_sum(0, 50), 0, 'zero where the wave jumps';
    ok abs(square_wave_sum(1, 7) + square_wave_sum(-1, 7)) < 1e-12, 'odd, like the wave';
    ok abs(square_wave_sum($pi / 2, 1) - 4 / $pi) < 1e-12, 'one term is (4/pi) sin x';
    ok abs(square_wave_sum($pi / 2, 2000) - 1) < 1e-3, 'many terms add up to the wave: 1 - 1/3 + 1/5 - ... = pi/4';
    ok abs(square_wave_sum(2.5, 2000) - 1) < 1e-3, 'anywhere between the jumps';

    # Gibbs: next to the jump the sums overshoot by about 9% of the jump, however many terms.
    for my $terms (50, 200) {
        my $peak = List::Util::max(map { square_wave_sum($_ * $pi / (2000 * $terms), $terms) } 1 .. 4000);
        ok abs($peak - 1.17898) < 0.001, "$terms terms still overshoot to 1.179, (2/pi) Si(pi)";
    }
};

subtest 'golden_squares' => sub {
    my @squares = golden_squares(10);
    is join(' ', map { $_->{size} } @squares), '1 1 2 3 5 8 13 21 34 55', 'each square is the size of the side it sits on: Fibonacci';
    my @overlapping;
    for my $i (0 .. $#squares) {
        for my $j ($i + 1 .. $#squares) {
            my ($s, $t) = @squares[ $i, $j ];
            push @overlapping, "$i,$j"
                if $s->{x} < $t->{x} + $t->{size} && $t->{x} < $s->{x} + $s->{size} && $s->{y} < $t->{y} + $t->{size} && $t->{y} < $s->{y} + $s->{size};
        }
    }
    is_deeply \@overlapping, [], 'no two squares overlap';
    my $width  = List::Util::max(map { $_->{x} + $_->{size} } @squares) - List::Util::min(map { $_->{x} } @squares);
    my $height = List::Util::max(map { $_->{y} + $_->{size} } @squares) - List::Util::min(map { $_->{y} } @squares);
    is_deeply [ sort { $a <=> $b } $width, $height ], [ 55, 89 ], 'together they fill a 55 by 89 rectangle';
    is List::Util::sum(map { $_->{size}**2 } @squares), 55 * 89, 'with no gaps';

    my $end = sub { my ($s, $angle) = @_; [ map { sprintf '%.9f', $_ } $s->{cx} + $s->{size} * cos($angle), $s->{cy} + $s->{size} * sin($angle) ] };
    my @breaks = grep {
        my ($s, $t) = @squares[ $_, $_ + 1 ];
        "@{ $end->($s, $s->{to}) }" ne "@{ $end->($t, $t->{from}) }";
    } 0 .. $#squares - 1;
    is_deeply \@breaks, [], 'the quarter circles join into one spiral';
};

subtest 'torus_knot_points' => sub {
    my $pi    = 4 * atan2(1, 1);
    my $turns = sub {
        my ($angles) = @_;
        my $total = 0;
        for my $i (1 .. $#$angles) {
            my $step = $angles->[$i] - $angles->[ $i - 1 ];
            $step -= 2 * $pi * POSIX::floor(($step + $pi) / (2 * $pi));
            $total += $step;
        }
        return sprintf '%.6f', $total / (2 * $pi);
    };
    for ([ 2, 3 ], [ 3, 7 ], [ 5, 2 ]) {
        my ($p, $q) = @$_;
        my @points = torus_knot_points($p, $q, 2000);
        my ($first, $last) = @points[ 0, -1 ];
        ok abs($first->[0] - $last->[0]) + abs($first->[1] - $last->[1]) + abs($first->[2] - $last->[2]) < 1e-9, "the ($p,$q) knot closes";
        is $turns->([ map { atan2($_->[1], $_->[0]) } @points ]), sprintf('%.6f', $p), "going $p times round the hole";
        is $turns->([ map { atan2($_->[2], sqrt($_->[0]**2 + $_->[1]**2) - 2) } @points ]), sprintf('%.6f', $q), "and $q times round the tube";
    }
};

subtest 'penrose_triangles' => sub {
    my $phi = (1 + sqrt 5) / 2;
    my @counts;
    for my $level (0 .. 5) {
        my @triangles = penrose_triangles($level);
        push @counts, join '/', scalar(grep { $_->[0] == 0 } @triangles), scalar(grep { $_->[0] == 1 } @triangles);
    }
    is "@counts", '10/0 10/10 20/30 50/80 130/210 340/550', 'each step splits a thin piece in two and a thick one in three';

    my @triangles = penrose_triangles(5);
    my $length = sub { sqrt(($_[0][0] - $_[1][0])**2 + ($_[0][1] - $_[1][1])**2) };
    my $area   = sub { my ($a, $b, $c) = @_; abs(($b->[0] - $a->[0]) * ($c->[1] - $a->[1]) - ($c->[0] - $a->[0]) * ($b->[1] - $a->[1])) / 2 };
    my @wrong = grep {
        my ($color, $a, $b, $c) = @$_;
        my ($ab, $ac, $bc) = ($length->($a, $b), $length->($a, $c), $length->($b, $c));
        abs($ab - $ac) > 1e-9 || abs($bc / $ab - ($color ? $phi : 1 / $phi)) > 1e-9;
    } @triangles;
    is_deeply \@wrong, [], 'thin pieces are golden triangles and thick ones golden gnomons';
    ok abs(List::Util::sum(map { $area->(@$_[ 1 .. 3 ]) } @triangles) - List::Util::sum(map { $area->(@$_[ 1 .. 3 ]) } penrose_triangles(0))) < 1e-9,
        'and they still cover exactly the starting wheel';
};

subtest 'recaman_sequence' => sub {
    is join(' ', recaman_sequence(21)), '0 1 3 6 2 7 13 20 12 21 11 22 10 23 9 24 8 25 43 62 42',
        'step back by n if that lands on a new positive number, otherwise forward (worked by hand)';
    my @terms = recaman_sequence(500);
    my @bad = grep { abs($terms[$_] - $terms[ $_ - 1 ]) != $_ || $terms[$_] < 0 } 1 .. $#terms;
    is_deeply \@bad, [], 'every step is exactly n long and never goes below zero';
};

subtest 'pythagoras_tree' => sub {
    for my $angle (0.785398163397448, 0.6) {
        my @squares = pythagoras_tree(6, $angle);
        is scalar @squares, 127, "a trunk and six levels of branches make 127 squares (angle $angle)";
        my %area;
        for my $square (@squares) {
            my ($depth, $a, $b) = @$square;
            $area{$depth} += ($b->[0] - $a->[0])**2 + ($b->[1] - $a->[1])**2;
        }
        my @wrong = grep { abs($area{$_} - 1) > 1e-9 } sort keys %area;
        is_deeply \@wrong, [], 'every level has the same area as the trunk, which is Pythagoras\'s theorem';
    }
    my ($trunk, $left, $right) = pythagoras_tree(1, 0.6);
    my ($apex, $from, $to) = ($left->[2], $left->[1], $right->[2]);
    ok abs(($from->[0] - $apex->[0]) * ($to->[0] - $apex->[0]) + ($from->[1] - $apex->[1]) * ($to->[1] - $apex->[1])) < 1e-12,
        'the two branches meet at a right angle';
};

subtest 'hyperbolic tiling' => sub {
    my ($p, $q) = (7, 3);
    my ($center, $radius) = hyperbolic_mirror($p, $q);
    my $pi = 4 * atan2(1, 1);
    ok abs($center**2 - $radius**2 - 1) < 1e-12, 'the curved mirror meets the edge of the disk at right angles';
    my $angle = POSIX::acos($center * sin($pi / $p) / $radius);
    ok abs($angle - $pi / $q) < 1e-12, 'and meets the slanted mirror at pi/q';

    my $distance = sub {
        my ($u, $v) = @_;
        my $gap = ($u->[0] - $v->[0])**2 + ($u->[1] - $v->[1])**2;
        return POSIX::acosh(1 + 2 * $gap / ((1 - $u->[0]**2 - $u->[1]**2) * (1 - $v->[0]**2 - $v->[1]**2)));
    };
    my ($u, $v) = ([ 0.1, 0.2 ], [ 0.5, -0.3 ]);
    my @mirrored = map { [ hyperbolic_reflect(@$_, $center, $radius) ] } $u, $v;
    ok abs($distance->($u, $v) - $distance->(@mirrored)) < 1e-9, 'reflecting in the curved mirror keeps hyperbolic distances';

    my @outside;
    for my $x (map { -0.95 + $_ / 10 } 0 .. 19) {
        for my $y (map { -0.95 + $_ / 10 } 0 .. 19) {
            next if $x**2 + $y**2 >= 0.99;
            my ($fx, $fy) = hyperbolic_fold($x, $y, $p, $q);
            push @outside, "$x,$y"
                if $fy < -1e-12 || $fy * cos($pi / $p) - $fx * sin($pi / $p) > 1e-12 || ($fx - $center)**2 + $fy**2 < $radius**2 - 1e-12;
        }
    }
    is_deeply \@outside, [], 'folding takes every point of the disk into the one starting triangle';

    # In the {5,4} tiling the middle pentagon's edge crosses the x axis
    # where the curved mirror does, at center - radius.
    ($center, $radius) = hyperbolic_mirror(5, 4);
    my $edge = $center - $radius;
    my @counts = map { (hyperbolic_fold($_, 0.001, 5, 4))[2] } $edge - 0.01, $edge + 0.01;
    is_deeply \@counts, [ 0, 1 ], 'stepping over a pentagon\'s edge is one crossing';
    is((hyperbolic_fold(0.1, -0.05, 5, 4))[2], 0, 'and moving about inside one is none');
};

subtest 'ripple_height' => sub {
    my ($gap, $wavelength, $pi) = (4, 1, 4 * atan2(1, 1));
    ok abs(ripple_height(0, 7, $gap, $wavelength, 0) - 2 * cos(2 * $pi * sqrt(4 + 49))) < 1e-12,
        'halfway between the sources the two waves arrive together and add up';
    # The sources are at x = -2 and 2. On this hyperbola the left one is always
    # half a wave further away than the right one.
    my $x = 0.25 * sqrt(1 + 9 / (4 - 0.25**2));
    for my $time (0, 0.13, 0.5) {
        ok abs(ripple_height($x, 3, $gap, $wavelength, $time)) < 1e-9, "where the paths differ by half a wave they cancel (time $time)";
    }
};

subtest 'weierstrass' => sub {
    my $pi = 4 * atan2(1, 1);
    ok abs(weierstrass(0, 0.5, 3, 6) - (1 - 0.5**6) / 0.5) < 1e-12, 'at 0 every cosine is 1, a geometric series';
    ok abs(weierstrass(1, 0.5, 3, 6) + (1 - 0.5**6) / 0.5) < 1e-12, 'at 1 with odd b every cosine is -1';
    for my $x (0.1, 0.37, -0.8) {
        ok abs(weierstrass($x, 0.6, 3, 8) - cos($pi * $x) - 0.6 * weierstrass(3 * $x, 0.6, 3, 7)) < 1e-12,
            "it holds a smaller copy of itself: W(x) = cos(pi x) + a W(bx) (x = $x)";
    }
};

subtest 'nearest_seed' => sub {
    my @seeds = ([ 0, 0 ], [ 4, 0 ], [ 0, 10 ]);
    my ($seed, $gap) = nearest_seed(\@seeds, 1, 1);
    is $seed, 0, 'the seed nearest the point';
    ok abs($gap - (sqrt(10) - sqrt(2))) < 1e-12, 'and how much further the next nearest is';
    ($seed, $gap) = nearest_seed(\@seeds, 2, 3);
    ok abs($gap) < 1e-12, 'a point halfway between two seeds is on the border, with no gap';
    is((nearest_seed(\@seeds, 0.5, 9))[0], 2, 'any seed can be nearest');
};

subtest 'euler_spiral' => sub {
    my ($length, $steps) = (4, 2000);
    my $ds     = $length / $steps;
    my @spiral = euler_spiral($length, $steps);
    is scalar @spiral, 2 * $steps + 1, 'points from one end to the other';
    is_deeply $spiral[$steps], [ 0, 0 ], 'with the middle at the origin';
    is_deeply [ grep { abs($spiral[$_][0] + $spiral[ -1 - $_ ][0]) > 1e-12 || abs($spiral[$_][1] + $spiral[ -1 - $_ ][1]) > 1e-12 } 0 .. $steps ], [],
        'the two halves are the same turned half round';
    is_deeply [ grep { abs(sqrt(($spiral[$_][0] - $spiral[ $_ - 1 ][0])**2 + ($spiral[$_][1] - $spiral[ $_ - 1 ][1])**2) - $ds) > 1e-12 } 1 .. $#spiral ], [],
        'every step is the same length';

    my $heading = sub { atan2($spiral[ $_[0] ][1] - $spiral[ $_[0] - 1 ][1], $spiral[ $_[0] ][0] - $spiral[ $_[0] - 1 ][0]) };
    for my $i (500, 1500) {
        my $s    = ($i - $steps) * $ds;
        my $turn = $heading->($i + 1) - $heading->($i);
        ok abs($turn / $ds - $s) < 1e-9, "its curvature is the distance along it (s = $s)";
    }

    my $end = (euler_spiral(30, 60000))[-1];
    my $eye = sqrt(4 * atan2(1, 1)) / 2;
    ok sqrt(($end->[0] - $eye)**2 + ($end->[1] - $eye)**2) < 1 / 30 + 1e-3, 'it winds in toward (sqrt(pi)/2, sqrt(pi)/2)';
};

subtest 'hopf_fiber' => sub {
    my @circle = hopf_fiber(0, 0, 100);
    is_deeply [ grep { abs(sqrt($_->[0]**2 + $_->[1]**2) - 1) > 1e-12 || abs($_->[2]) > 1e-12 } @circle ], [],
        'the fiber over the north pole is the unit circle';

    # Over the latitude theta the fibers fill a torus that goes round a circle
    # of radius 1 / cos(theta / 2) with a tube of radius tan(theta / 2).
    my $theta = 1.1;
    my ($around, $tube) = (1 / cos($theta / 2), sin($theta / 2) / cos($theta / 2));
    for my $phi (0, 2, 4) {
        my @fiber = hopf_fiber($theta, $phi, 400);
        is_deeply [ grep { abs((sqrt($_->[0]**2 + $_->[1]**2) - $around)**2 + $_->[2]**2 - $tube**2) > 1e-9 } @fiber ], [],
            "fibers over one latitude lie on one torus (phi = $phi)";
        my $through = grep {
            my ($from, $to) = @fiber[ $_ - 1, $_ ];
            my $f = $from->[2] / ($from->[2] - $to->[2]);
            $from->[2] * $to->[2] < 0
                && sqrt(($from->[0] + $f * ($to->[0] - $from->[0]))**2 + ($from->[1] + $f * ($to->[1] - $from->[1]))**2) < 1;
        } 1 .. $#fiber;
        is $through, 1, "and each passes once through the north pole's circle, so the two are linked (phi = $phi)";
    }
};

subtest 'cantor' => sub {
    is_deeply [ cantor_intervals(0) ], [ [ 0, 1 ] ], 'the Cantor set starts as the whole line';
    my @third = cantor_intervals(3);
    is scalar @third, 8, 'every step doubles the pieces';
    is_deeply [ grep { abs($_->[1] - $_->[0] - 1 / 27) > 1e-12 } @third ], [], 'and cuts their length to a third';
    ok abs($third[1][0] - 2 / 27) < 1e-12 && abs($third[2][1] - 7 / 27) < 1e-12, 'by dropping the middle thirds';

    is cantor_function(0, 20), 0, 'the staircase starts at 0';
    is cantor_function(1, 20), 1, 'and climbs to 1';
    is cantor_function(0.4, 20), 0.5, 'it is flat across the first middle third';
    is cantor_function(0.6, 20), 0.5, 'all the way';
    ok abs(cantor_function(0.25, 30) - 1 / 3) < 1e-6, 'at 1/4, 0.0202... in base 3, it is 0.0101... in base 2, which is 1/3';
    for my $x (0.1, 0.27, 0.71) {
        ok abs(cantor_function($x, 30) + cantor_function(1 - $x, 30) - 1) < 1e-6, "it is symmetric (x = $x)";
    }
};

subtest 'tesseract' => sub {
    my @vertices = tesseract_vertices();
    is scalar @vertices, 16, 'sixteen corners';
    my @edges = tesseract_edges();
    is scalar @edges, 32, 'thirty-two edges';
    is_deeply [ grep { my ($a, $b) = @vertices[@$_]; 1 != grep { $a->[$_] != $b->[$_] } 0 .. 3 } @edges ], [],
        'each joining corners that differ in one coordinate';
    my %degree;
    $degree{$_}++ for map {@$_} @edges;
    is_deeply [ grep { $degree{$_} != 4 } 0 .. 15 ], [], 'four edges meet at every corner';

    my $pi      = 4 * atan2(1, 1);
    my $rotated = rotate_plane([ 1, 0, 0, 0 ], 0, 3, $pi / 2);
    ok abs($rotated->[0]) < 1e-12 && abs($rotated->[3] - 1) < 1e-12, 'a quarter turn in the x-w plane takes x to w';
    my $point = rotate_plane([ 1, 2, 3, 4 ], 1, 2, 0.7);
    ok abs(List::Util::sum(map { $_**2 } @$point) - 30) < 1e-12, 'turning keeps lengths';
    is_deeply [ @$point[ 0, 3 ] ], [ 1, 4 ], 'and leaves the other two coordinates alone';
};

subtest 'truchet' => sub {
    my $tiles = truchet_tiles(6, 5);
    is scalar @$tiles, 5, 'as many rows as asked for';
    is scalar @{ $tiles->[0] }, 6, 'and columns';
    my %turns = map { $_ => 1 } map {@$_} @$tiles;
    is_deeply [ sort keys %turns ], [ 0, 1 ], 'tiles are laid both ways';

    # Coloring each side of the arcs by the tile's turn and its place in the
    # checkerboard has to make every arc a border and no tile edge one.
    my @seams;
    for my $i (1 .. 5) {
        for my $j (0 .. 4) {
            for my $along (0.1, 0.3, 0.7, 0.9) {
                push @seams, "column edge $i,$j,$along" if truchet_side($tiles, $i - 1e-9, $j + $along) != truchet_side($tiles, $i + 1e-9, $j + $along);
                push @seams, "row edge $j,$i,$along" if $i < 5 && truchet_side($tiles, $j + $along, $i - 1e-9) != truchet_side($tiles, $j + $along, $i + 1e-9);
            }
        }
    }
    is_deeply \@seams, [], 'the two colors run straight across tile edges';
    my ($x, $y) = (2, 3);
    my $corner = $tiles->[$y][$x] ? [ $x + 1, $y ] : [ $x, $y ];
    isnt truchet_side($tiles, $corner->[0] + 0.3 * ($x + 0.5 - $corner->[0]), $corner->[1] + 0.3 * ($y + 0.5 - $corner->[1])),
        truchet_side($tiles, $corner->[0] + 0.9 * ($x + 0.5 - $corner->[0]), $corner->[1] + 0.9 * ($y + 0.5 - $corner->[1])),
        'but change across an arc';
};

subtest 'complex_sin' => sub {
    my ($u, $v) = complex_sin(0.3, 0);
    ok abs($u - sin 0.3) < 1e-12 && $v == 0, 'on the real line it is the ordinary sine';
    for my $y (0.4, 1.2) {
        my @off = grep { my ($u, $v) = complex_sin($_, $y); abs(($u / POSIX::cosh($y))**2 + ($v / POSIX::sinh($y))**2 - 1) > 1e-12 } -1.5, -0.4, 0.2, 1.1;
        is_deeply \@off, [], "it bends the line y = $y into an ellipse";
    }
    for my $x (0.3, -1.1) {
        my @off = grep { my ($u, $v) = complex_sin($x, $_); abs(($u / sin $x)**2 - ($v / cos $x)**2 - 1) > 1e-12 } -1, 0.2, 1.4;
        is_deeply \@off, [], "and the line x = $x into a hyperbola";
    }
    my ($h, $x, $y) = (1e-6, 0.7, 0.5);
    my @across = map { (($_->[0] - $_->[1]) / (2 * $h)) } [ (complex_sin($x + $h, $y))[0], (complex_sin($x - $h, $y))[0] ],
        [ (complex_sin($x + $h, $y))[1], (complex_sin($x - $h, $y))[1] ];
    my @up = map { (($_->[0] - $_->[1]) / (2 * $h)) } [ (complex_sin($x, $y + $h))[0], (complex_sin($x, $y - $h))[0] ],
        [ (complex_sin($x, $y + $h))[1], (complex_sin($x, $y - $h))[1] ];
    ok abs($across[0] * $up[0] + $across[1] * $up[1]) < 1e-6, 'the curves still cross at right angles';
};

subtest 'maurer_rose' => sub {
    my $pi   = 4 * atan2(1, 1);
    my @rose = maurer_rose(6, 71);
    is scalar @rose, 361, 'a point for every step and one to close it';
    ok abs($rose[360][0] - $rose[0][0]) < 1e-12 && abs($rose[360][1] - $rose[0][1]) < 1e-12, 'and it closes up';
    for my $k (1, 7, 200) {
        my $angle = $k * 71 * $pi / 180;
        my $r     = sin(6 * $angle);
        ok abs($rose[$k][0] - $r * cos $angle) < 1e-12 && abs($rose[$k][1] - $r * sin $angle) < 1e-12,
            "step $k is $k times 71 degrees round, on the rose r = sin 6 theta";
    }
};

subtest 'tricorn' => sub {
    my $pi = 4 * atan2(1, 1);
    ok !defined escape_time(0, 0, 0, 0, 100, 0, 1), 'c = 0 stays put';
    for my $cx (-1.9, 0.3, 0.5) {
        is_deeply [ escape_time(0, 0, $cx, 0, 300, 0, 1) ], [ escape_time(0, 0, $cx, 0, 300) ],
            "on the real line it is the Mandelbrot set (c = $cx)";
    }
    for my $c ([ 0.5, 0.6 ], [ -0.9, 0.7 ], [ 0.1, -1.1 ]) {
        my ($x, $y) = @$c;
        my ($turned_x, $turned_y) = ($x * cos(2 * $pi / 3) - $y * sin(2 * $pi / 3), $x * sin(2 * $pi / 3) + $y * cos(2 * $pi / 3));
        my $here  = escape_time(0, 0, $x, $y, 300, 0, 1);
        my $there = escape_time(0, 0, $turned_x, $turned_y, 300, 0, 1);
        ok defined $here && abs($here - $there) < 1e-6, "it looks the same a third of a turn round (c = $x, $y)";
    }
};

subtest 'three_body_orbit' => sub {
    my $period = 6.32591398;
    my @orbit  = three_body_orbit($period, 30000);
    is scalar @orbit, 30001, 'a state for every step and the start';
    my $energy = sub {
        my ($bodies, $velocities) = @{ $_[0] };
        my $energy = List::Util::sum(map { ($_->[0]**2 + $_->[1]**2) / 2 } @$velocities);
        for my $pair ([ 0, 1 ], [ 0, 2 ], [ 1, 2 ]) {
            my ($a, $b) = @$bodies[@$pair];
            $energy -= 1 / sqrt(($a->[0] - $b->[0])**2 + ($a->[1] - $b->[1])**2);
        }
        return $energy;
    };
    ok abs($energy->($orbit[-1]) - $energy->($orbit[0])) < 1e-6, 'energy is kept';
    is_deeply [ grep { my $b = $_->[0]; abs($b->[0][0] + $b->[1][0] + $b->[2][0]) > 1e-9 || abs($b->[0][1] + $b->[1][1] + $b->[2][1]) > 1e-9 } @orbit ], [],
        'their center of mass never moves';
    my ($start, $end) = ($orbit[0][0], $orbit[-1][0]);
    ok !(grep { abs($start->[$_][0] - $end->[$_][0]) > 1e-3 || abs($start->[$_][1] - $end->[$_][1]) > 1e-3 } 0 .. 2),
        'after one period every body is back where it started';
    my $third = $orbit[10000][0];
    my @took  = grep { abs($third->[0][0] - $start->[$_][0]) < 1e-3 && abs($third->[0][1] - $start->[$_][1]) < 1e-3 } 1, 2;
    is scalar @took, 1, 'and a third of the way round, a body has taken the place of another, because all three chase each other round one figure eight';
};

subtest 'quasicrystal_height' => sub {
    my $pi = 4 * atan2(1, 1);
    is quasicrystal_height(0, 0, 7), 7, 'at the center all seven waves crest together';
    for my $point ([ 1.3, 0.4 ], [ -2.2, 5.1 ]) {
        my ($x, $y) = @$point;
        my $turned = quasicrystal_height($x * cos($pi / 7) - $y * sin($pi / 7), $x * sin($pi / 7) + $y * cos($pi / 7), 7);
        ok abs($turned - quasicrystal_height($x, $y, 7)) < 1e-9, "it looks the same turned a fourteenth of the way round ($x, $y)";
    }
    ok !(grep { quasicrystal_height($_ * 0.37, 0, 7) > 7 - 1e-6 } 1 .. 400), 'nowhere else along a line do all seven crest together';
};

subtest 'gosper_path' => sub {
    my $pi = 4 * atan2(1, 1);
    for my $order (1 .. 3) {
        my @path = gosper_path($order);
        is scalar @path, 7**$order + 1, "order $order is 7^$order steps";
        my @odd = grep {
            my ($dx, $dy) = ($path[$_][0] - $path[ $_ - 1 ][0], $path[$_][1] - $path[ $_ - 1 ][1]);
            my $sixths = atan2($dy, $dx) / ($pi / 3);
            abs(sqrt($dx**2 + $dy**2) - 1) > 1e-9 || abs($sixths - POSIX::floor($sixths + 0.5)) > 1e-9;
        } 1 .. $#path;
        is_deeply \@odd, [], 'every step is one long and heads along one of the six directions of a hexagon';
        ok abs(sqrt($path[-1][0]**2 + $path[-1][1]**2) - sqrt(7)**$order) < 1e-9, 'each order ends sqrt(7) times further away';
    }
};

subtest 'bessel' => sub {
    is bessel_j(0, 0), 1, 'J0(0) = 1';
    is bessel_j(1, 0), 0, 'J1(0) = 0';
    ok abs(bessel_j(1, 1) - 0.4400505857449335) < 1e-12, 'J1(1)';
    for my $x (0.7, 4.2, 11.3) {
        ok abs(bessel_j(1, $x) + bessel_j(3, $x) - 4 / $x * bessel_j(2, $x)) < 1e-9, "J(m-1) + J(m+1) = (2m/x) J(m) (x = $x)";
    }
    ok abs(bessel_zero(0, 1) - 2.404825557695773) < 1e-9, 'the first zero of J0';
    ok abs(bessel_zero(1, 1) - 3.831705970207512) < 1e-9, 'the first zero of J1';
    ok abs(bessel_zero(2, 2) - 8.417244140399865) < 1e-9, 'the second zero of J2';
};

subtest 'drum_height' => sub {
    my $pi = 4 * atan2(1, 1);
    is_deeply [ grep { abs(drum_height(3, 2, 1, $_)) > 1e-9 } 0.1, 1, 2.5, 4 ], [], 'the rim is held still';
    is_deeply [ grep { abs(drum_height(3, 2, $_, $pi / 6)) > 1e-9 } 0.2, 0.5, 0.9 ], [], 'and so are the lines out from the center between the lobes';
    my $ring = bessel_zero(3, 1) / bessel_zero(3, 2);
    ok abs(drum_height(3, 2, $ring, 0.3)) < 1e-9, 'and a circle partway out';
    ok drum_height(3, 2, $ring / 2, 0) * drum_height(3, 2, ($ring + 1) / 2, 0) < 0, 'with the drum moving opposite ways either side of it';
};

subtest 'theodorus_points' => sub {
    my $pi     = 4 * atan2(1, 1);
    my @points = theodorus_points(18);
    is_deeply [ grep { abs(sqrt($points[$_][0]**2 + $points[$_][1]**2) - sqrt($_ + 1)) > 1e-9 } 0 .. $#points ], [],
        'the nth point is sqrt(n) from the center';
    is_deeply [ grep {
        my ($dx, $dy) = ($points[$_][0] - $points[ $_ - 1 ][0], $points[$_][1] - $points[ $_ - 1 ][1]);
        abs(sqrt($dx**2 + $dy**2) - 1) > 1e-9 || abs($dx * $points[ $_ - 1 ][0] + $dy * $points[ $_ - 1 ][1]) > 1e-9;
    } 1 .. $#points ], [], 'each step is one long, at right angles to the line out to where it starts';
    my $turned = 0;
    my @total  = map { $turned += atan2(1, sqrt $_) } 1 .. 17;
    ok $total[15] < 2 * $pi && $total[16] > 2 * $pi, 'sixteen triangles fit in one turn and the seventeenth overlaps';
    my $last = atan2($points[16][1], $points[16][0]);
    ok abs($last - ($total[15] - 2 * $pi)) < 1e-9, 'which is where the points are';
};

subtest 'brachistochrone' => sub {
    my $pi       = 4 * atan2(1, 1);
    my @line     = map { [ $pi * $_ / 100, -2 * $_ / 100 ] } 0 .. 100;
    my @times    = curve_times(\@line);
    ok abs($times[-1] - sqrt($pi**2 + 4)) < 1e-9, 'sliding down a straight line takes its length times sqrt(2 / gh)';
    is_deeply [ grep { $times[$_] <= $times[ $_ - 1 ] } 1 .. $#times ], [], 'and the times only go up';

    my @cycloid = cycloid_points(0, 20000);
    ok abs((curve_times(\@cycloid))[-1] - $pi) < 1e-3, 'down the cycloid it takes pi, less than the line';
    ok abs((curve_times([ cycloid_points(1.2, 20000) ]))[-1] - $pi) < 1e-3, 'let go from partway down, it still takes pi to reach the bottom';
    ok abs((curve_times([ cycloid_points(2.5, 20000) ]))[-1] - $pi) < 1e-3, 'wherever you let go';
};

subtest 'double_pendulum' => sub {
    my $pi     = 4 * atan2(1, 1);
    my $energy = sub {
        my ($a, $b, $va, $vb) = @{ $_[0] };
        return $va**2 + $vb**2 / 2 + $va * $vb * cos($a - $b) - 2 * cos($a) - cos($b);
    };
    my @swing = double_pendulum([ 2, 2, 0, 0 ], 20, 20000);
    is scalar @swing, 20001, 'a state for every step and the start';
    ok abs($energy->($swing[-1]) - $energy->($swing[0])) < 1e-6, 'energy is kept, even swinging wildly';
    is_deeply [ double_pendulum([ 0, 0, 0, 0 ], 1, 10) ]->[-1], [ 0, 0, 0, 0 ], 'hanging still it stays still';

    # Swinging a little with the lower arm sqrt(2) times as far out as the
    # upper, both arms move together at one frequency.
    my $small  = 0.001;
    my $period = 2 * $pi / sqrt(2 - sqrt 2);
    my $back   = (double_pendulum([ $small, sqrt(2) * $small, 0, 0 ], $period, 20000))[-1];
    ok abs($back->[0] - $small) < 1e-8 && abs($back->[1] - sqrt(2) * $small) < 1e-8, 'small swings in step come back after 2 pi / sqrt(2 - sqrt 2)';
};

subtest 'butterfly_point' => sub {
    my ($x, $y) = @{ butterfly_point(1.3) };
    my $r = exp(cos 1.3) - 2 * cos(4 * 1.3) - sin(1.3 / 12)**5;
    ok abs($x - sin(1.3) * $r) < 1e-12 && abs($y - cos(1.3) * $r) < 1e-12, 'r = e^cos t - 2 cos 4t - sin^5(t / 12), as x = r sin t, y = r cos t';
    my ($start, $end) = (butterfly_point(0), butterfly_point(96 * atan2(1, 1)));
    ok abs($start->[0] - $end->[0]) < 1e-9 && abs($start->[1] - $end->[1]) < 1e-9, 'it closes up after twelve turns';
};

subtest 'rotation_number' => sub {
    ok abs(rotation_number(0.3, 0) - 0.3) < 1e-9, 'without the kick the circle just turns by omega each step';
    ok abs(rotation_number(0.1, 0.9)) < 1e-6, 'a strong kick locks a small turn to none at all';
    ok abs(rotation_number(0.5, 0.9) - 0.5) < 1e-6, 'and half a turn stays locked at half';
    ok abs(rotation_number(0.345, 0.9) - 1 / 3) < 1e-6, 'and a little over a third at a third';
    ok abs(rotation_number(1 / 3, 0.9) - 1 / 3) > 1e-3, 'but the kick has pushed that tongue off a third itself';
    my @rising = map { rotation_number($_ / 20, 0.6) } 0 .. 20;
    is_deeply [ grep { $rising[$_] < $rising[ $_ - 1 ] - 1e-9 } 1 .. 20 ], [], 'more turn never means less rotation';
    is locked_denominator(rotation_number(0.345, 0.9), 8), 3, 'a third is locked with denominator 3';
    is locked_denominator(0.5, 8), 2, 'a half with 2';
    is locked_denominator(0.3183, 8), undef, 'an unlocked rotation has no small denominator';
};

subtest 'rk4_step' => sub {
    my $pi = 4 * atan2(1, 1);
    my ($grown) = rk4_step(sub { @_ }, [1], 0.1);
    ok abs($grown - exp 0.1) < 1e-6, 'growing at its own size, a step of 0.1 multiplies by about e^0.1';
    my @spring = (1, 0);
    @spring = rk4_step(sub { ($_[1], -$_[0]) }, \@spring, $pi / 1000) for 1 .. 2000;
    ok abs($spring[0] - 1) < 1e-8 && abs($spring[1]) < 1e-8, 'a spring comes back where it started after 2 pi';
};

subtest 'rossler_points' => sub {
    my @points = rossler_points(6000);
    is scalar @points, 6000, 'one point per step';
    is_deeply [ grep { abs($_->[0]) > 13 || abs($_->[1]) > 13 || $_->[2] < 0 || $_->[2] > 25 } @points ], [],
        'the trajectory stays inside the attractor\'s bounding box';
    ok((grep { $_->[2] > 5 } @points), 'and every so often it flies up out of the plane');
    my @backwards = grep {
        my ($x, $y, $z) = @{ $points[$_] };
        my $turning = $x * ($points[ $_ + 1 ][1] - $y) - $y * ($points[ $_ + 1 ][0] - $x);
        $z < 1 && $turning <= 0;
    } 0 .. $#points - 1;
    is_deeply \@backwards, [], 'down in the plane it always circles the z axis counterclockwise';
};

# Rounds the numbers in a nested list, so a turtle's cos(90 degrees) of
# 6e-17 compares equal to 0.
sub rounded {
    my ($value) = @_;
    return ref $value ? [ map { rounded($_) } @$value ] : 0 + sprintf '%.9f', $value;
}

subtest 'lsystem_moves' => sub {
    my @words = map { lsystem_moves('A', { A => 'AB', B => 'A' }, $_) } 0 .. 5;
    is_deeply \@words, [qw(A AB ABA ABAAB ABAABABA ABAABABAABAAB)], 'Lindenmayer\'s algae: each word is the last two joined';
    is lsystem_moves('F+F', { F => 'FF' }, 2), 'FFFF+FFFF', 'symbols without a rule are kept';
};

subtest 'turtle_segments' => sub {
    is_deeply rounded([ turtle_segments('F+F', 90) ]), [ [ [ 0, 0 ], [ 1, 0 ], 0 ], [ [ 1, 0 ], [ 1, 1 ], 0 ] ],
        'a step east, a quarter turn left, and a step north';
    is_deeply rounded([ turtle_segments('F[+F]-F', 90) ]),
        [ [ [ 0, 0 ], [ 1, 0 ], 0 ], [ [ 1, 0 ], [ 1, 1 ], 1 ], [ [ 1, 0 ], [ 1, -1 ], 0 ] ],
        'a branch in brackets goes off and the turtle comes back to where and how it started it';
    is_deeply rounded([ turtle_segments('A-B', 60) ]), rounded([ [ [ 0, 0 ], [ 1, 0 ], 0 ], [ [ 1, 0 ], [ 1.5, -sqrt(3) / 2 ], 0 ] ]),
        'any letter steps forward';
};

subtest 'levy_path' => sub {
    my $pi = 4 * atan2(1, 1);
    for my $order (2, 5, 8) {
        my @path = levy_path($order);
        is scalar @path, 2**$order + 1, "order $order is 2^$order steps";
        my @odd = grep {
            my ($dx, $dy) = ($path[$_][0] - $path[ $_ - 1 ][0], $path[$_][1] - $path[ $_ - 1 ][1]);
            my $eighths = atan2($dy, $dx) / ($pi / 4);
            abs(sqrt($dx**2 + $dy**2) - 1) > 1e-9 || abs($eighths - POSIX::floor($eighths + 0.5)) > 1e-9;
        } 1 .. $#path;
        is_deeply \@odd, [], 'every step is one long and heads along a multiple of 45 degrees';
        ok abs($path[-1][0] - sqrt(2)**$order) < 1e-9 && abs($path[-1][1]) < 1e-9, 'each order ends sqrt(2) times further east';
        my @unmirrored = grep { abs($path[$_][0] + $path[ -1 - $_ ][0] - $path[-1][0]) > 1e-9 || abs($path[$_][1] - $path[ -1 - $_ ][1]) > 1e-9 } 0 .. $#path;
        is_deeply \@unmirrored, [], 'and its two halves are mirror images';
    }
};

subtest 'plant_segments' => sub {
    my $pi = 4 * atan2(1, 1);
    for my $order (1 .. 4) {
        my @segments = plant_segments($order);
        is scalar @segments, 2**$order * (2**$order - 1), "order $order has 2^$order (2^$order - 1) steps";
        is_deeply rounded([ map { $_->[1] } @segments[ 0 .. 2**($order - 1) - 1 ] ]), [ map { [ $_, 0 ] } 1 .. 2**($order - 1) ],
            'starting with a straight stem half as long as the plant is wide in steps';
        my @odd = grep {
            my ($dx, $dy) = ($_->[1][0] - $_->[0][0], $_->[1][1] - $_->[0][1]);
            my $turns = atan2($dy, $dx) / ($pi * 25 / 180);
            abs(sqrt($dx**2 + $dy**2) - 1) > 1e-9 || abs($turns - POSIX::floor($turns + 0.5)) > 1e-9;
        } @segments;
        is_deeply \@odd, [], 'every step is one long, at a multiple of 25 degrees';
    }
};

subtest 'phoenix_escape' => sub {
    for my $point ([ 0.3, 0.2 ], [ -0.6, 0.5 ], [ 1.1, 0 ]) {
        my ($x, $y) = @$point;
        my $plain = escape_time($x, $y, 0.5667, 0, 200);
        ok defined $plain && abs(phoenix_escape($x, $y, 0.5667, 0, 200) - $plain) < 1e-9, "with p = 0 it's the Julia set's escape ($x, $y)";
    }
    my @off = grep { my ($x, $y) = ($_ / 7 - 1, $_ / 11 - 0.5); (phoenix_escape($x, $y, 0.5667, -0.5, 200) // -1) != (phoenix_escape($x, -$y, 0.5667, -0.5, 200) // -1) } 0 .. 14;
    is_deeply \@off, [], 'mirrored across the real line it escapes just the same';
    # From 2: 4 + 0.5667, then that squared + 0.5667 - 2/2, then that
    # squared + 0.5667 - 4.5667/2, which is past the escape radius of 256.
    my ($z1, $z2) = (4.5667, 4.5667**2 + 0.5667 - 1);
    my $z3 = $z2**2 + 0.5667 - $z1 / 2;
    ok abs(phoenix_escape(2, 0, 0.5667, -0.5, 200) - (4 - log(log($z3**2) / 2) / log(2))) < 1e-9, 'each step adds p times the step before';
};

subtest 'gaussian_prime' => sub {
    my $is_prime = primes_up_to(200);
    ok gaussian_prime(1, 1, $is_prime), '1 + i is prime';
    ok !gaussian_prime(2, 0, $is_prime), '2 is not, it\'s -i(1 + i)^2';
    ok gaussian_prime(3, 0, $is_prime) && gaussian_prime(0, -7, $is_prime), 'primes 3 more than a multiple of 4 stay prime';
    ok !gaussian_prime(5, 0, $is_prime) && !gaussian_prime(0, 13, $is_prime), 'primes 1 more than a multiple of 4 split, like 5 = (2 + i)(2 - i)';
    ok gaussian_prime(2, 1, $is_prime) && gaussian_prime(-3, 2, $is_prime), 'and their factors are prime, with prime norms 5 and 13';
    ok !gaussian_prime(3, 3, $is_prime), '3 + 3i = 3(1 + i) is not';
    my @asymmetric = grep {
        my ($a, $b) = ($_ % 13 - 6, int($_ / 13) - 6);
        my $prime = gaussian_prime($a, $b, $is_prime) ? 1 : 0;
        grep { (gaussian_prime(@$_, $is_prime) ? 1 : 0) != $prime } [ -$b, $a ], [ $b, $a ], [ $a, -$b ];
    } 0 .. 168;
    is_deeply \@asymmetric, [], 'turning a quarter or flipping across a diagonal or the real line keeps primes prime';
};

subtest 'cup_caustic' => sub {
    my $pi = 4 * atan2(1, 1);
    is_deeply rounded(cup_caustic_point(0)), [ 0.5, 0 ], 'rays near the middle focus halfway to the mirror';
    for my $theta (-1.2, -0.4, 0.3, 1) {
        my ($hit, $direction) = cup_reflection($theta);
        is_deeply rounded($hit), rounded([ cos $theta, sin $theta ]), "a ray along the x axis hits the mirror at angle $theta";
        ok abs($direction->[0] * $hit->[0] + $direction->[1] * $hit->[1] + cos $theta) < 1e-12 && abs($direction->[0]**2 + $direction->[1]**2 - 1) < 1e-12,
            'and bounces off at the angle it came in';
        my $point = cup_caustic_point($theta);
        is_deeply rounded($point), rounded([ (3 * cos($theta) - cos(3 * $theta)) / 4, (3 * sin($theta) - sin(3 * $theta)) / 4 ]), 'the caustic is a nephroid';
        my ($ahead, $behind) = (cup_caustic_point($theta + 1e-6), cup_caustic_point($theta - 1e-6));
        my @along = ($ahead->[0] - $behind->[0], $ahead->[1] - $behind->[1]);
        ok abs($along[0] * $direction->[1] - $along[1] * $direction->[0]) < 1e-9, 'and the reflected ray just touches it there';
    }
};

subtest 'orbitals' => sub {
    for my $x (0, 0.7, 3.2) {
        ok abs(associated_laguerre(2, 1, $x) - ($x**2 - 6 * $x + 6) / 2) < 1e-12, "L_2^1($x) = (x^2 - 6x + 6)/2";
        ok abs(associated_laguerre(1, 3, $x) - (4 - $x)) < 1e-12, "L_1^3($x) = 4 - x";
    }
    for my $x (-0.6, 0.2, 0.9) {
        ok abs(associated_legendre(2, 0, $x) - (3 * $x**2 - 1) / 2) < 1e-12, "P_2($x) = (3x^2 - 1)/2";
        ok abs(associated_legendre(3, 1, $x) + 1.5 * (5 * $x**2 - 1) * sqrt(1 - $x**2)) < 1e-12, "P_3^1($x) = -3/2 (5x^2 - 1) sqrt(1 - x^2)";
        ok abs(associated_legendre(2, 2, $x) - 3 * (1 - $x**2)) < 1e-12, "P_2^2($x) = 3(1 - x^2)";
    }
    my @along_z = map { hydrogen_wave(4, 1, 0, 0, $_ / 10) } 1 .. 400;
    my $flips   = grep { $along_z[$_] * $along_z[ $_ - 1 ] < 0 } 1 .. $#along_z;
    is $flips, 2, '4p has n - l - 1 = 2 spheres where it\'s zero';
    is_deeply [ grep { abs(hydrogen_wave(4, 1, 0, $_, 0)) > 1e-12 } 0.5, 3, 9 ], [], 'and a flat plane across the z axis';
    ok hydrogen_wave(3, 2, 1, 2, 2) * hydrogen_wave(3, 2, 1, -2, 2) < 0, 'with m = 1 the two sides of the z axis have opposite signs';
};

subtest 'mandelbrot_nucleus' => sub {
    my $returns = sub {
        my ($cx, $cy, $period) = @_;
        my ($x, $y) = (0, 0);
        ($x, $y) = ($x * $x - $y * $y + $cx, 2 * $x * $y + $cy) for 1 .. $period;
        return abs($x) < 1e-9 && abs($y) < 1e-9;
    };
    is_deeply rounded([ mandelbrot_nucleus(0.1, 0.1, 1) ]), [ 0, 0 ], 'the main cardioid\'s center is 0';
    is_deeply rounded([ mandelbrot_nucleus(-0.9, 0, 2) ]), [ -1, 0 ], 'the big bulb\'s is -1';
    my ($cx, $cy) = mandelbrot_nucleus(-1.75, 0, 3);
    ok abs($cx**3 + 2 * $cx**2 + $cx + 1) < 1e-9 && abs($cy) < 1e-12, 'the period 3 copy on the real line solves c^3 + 2c^2 + c + 1 = 0';
    ok $returns->($cx, $cy, 3), 'so 0 comes back to 0 after three steps';
    ($cx, $cy) = mandelbrot_nucleus(-0.1, 0.7, 3);
    ok $returns->($cx, $cy, 3) && $cy > 0.7, 'and the rabbit\'s c is one too, up off the line';
};

subtest 'euler_power_path' => sub {
    my $pi   = 4 * atan2(1, 1);
    my @path = euler_power_path(8);
    is scalar @path, 9, 'from the 0th power up to the 8th';
    is_deeply rounded($path[0]), [ 1, 0 ], 'starting at 1';
    my @off = grep {
        my ($x, $y) = @{ $path[ $_ - 1 ] };
        abs($path[$_][0] - ($x - $y * $pi / 8)) > 1e-12 || abs($path[$_][1] - ($y + $x * $pi / 8)) > 1e-12;
    } 1 .. 8;
    is_deeply \@off, [], 'each point is the last times 1 + i pi/8';
    my $end = (euler_power_path(20000))[-1];
    ok abs($end->[0] + 1) < 1e-3 && abs($end->[1]) < 1e-3, 'with many steps, (1 + i pi/n)^n comes to -1';
};

subtest 'field_line' => sub {
    my $pi   = 4 * atan2(1, 1);
    my @line = field_line(1);
    ok sqrt(($line[0][0] + 1)**2 + $line[0][1]**2) < 0.11, 'it leaves from the positive charge';
    ok sqrt(($line[-1][0] - 1)**2 + $line[-1][1]**2) < 0.11, 'and ends on the negative one';
    my $flux = sub { my ($x, $y) = @{ $_[0] }; ($x + 1) / sqrt(($x + 1)**2 + $y**2) - ($x - 1) / sqrt(($x - 1)**2 + $y**2) };
    my $start = $flux->($line[0]);
    is_deeply [ grep { abs($flux->($_) - $start) > 1e-6 } @line ], [], 'along the way cos a - cos b never changes, a and b the angles at the two charges';
    my $mirror = sub { my ($k) = @_; abs($line[$k][0] + $line[ -1 - $k ][0]) < 0.02 && abs($line[$k][1] - $line[ -1 - $k ][1]) < 0.02 };
    ok $mirror->(0) && $mirror->(int(@line / 4)), 'and its two halves mirror each other';
    is_deeply [ grep { $_->[1] <= 0 } @line ], [], 'it never crosses the line through the charges';
};

subtest 'pursuit_polygons' => sub {
    my $pi       = 4 * atan2(1, 1);
    my @polygons = pursuit_polygons(4, 0.05, 30);
    is scalar @polygons, 31, 'the start and every step';
    my $side = sub { my ($p, $q) = @_; sqrt(($p->[0] - $q->[0])**2 + ($p->[1] - $q->[1])**2) };
    my @lopsided = grep {
        my $polygon = $_;
        my @sides   = map { $side->($polygon->[$_], $polygon->[ ($_ + 1) % 4 ]) } 0 .. 3;
        List::Util::max(@sides) - List::Util::min(@sides) > 1e-9 || abs($side->($polygon->[0], $polygon->[2]) - sqrt(2) * $sides[0]) > 1e-9;
    } @polygons;
    is_deeply \@lopsided, [], 'the four bugs are always at the corners of a square';
    for my $n (3, 4, 6) {
        my @slow   = pursuit_polygons($n, 0.0002, 100000);
        my $walked = 0;
        $walked += $side->($slow[$_][0], $slow[ $_ - 1 ][0]) for 1 .. $#slow;
        my $first = $side->(@{ $slow[0] }[ 0, 1 ]);
        ok abs($walked - $first / (1 - cos(2 * $pi / $n))) < 1e-3 * $first, "$n bugs each walk side / (1 - cos(2 pi / $n)) to meet";
    }
};

subtest 'mobius_point' => sub {
    my $pi    = 4 * atan2(1, 1);
    my $close = sub { my ($p, $q) = @_; !(grep { abs($p->[$_] - $q->[$_]) > 1e-9 } 0 .. 2) };
    ok !(grep { !$close->(mobius_point($_ + 2 * $pi, 0.3), mobius_point($_, -0.3)) } 0.2, 1.7, 4), 'once round, the strip comes back flipped over';
    ok !(grep { !$close->(mobius_point($_, 0), [ cos $_, sin $_, 0 ]) } 0.2, 1.7, 4), 'its middle is the unit circle';
    ok !$close->(mobius_point(0.5, 0.3), mobius_point(0.5 + 2 * $pi, 0.3)), 'so the edge isn\'t back where it started after one turn';
    ok $close->(mobius_point(0.5, 0.3), mobius_point(0.5 + 4 * $pi, 0.3)), 'but is after two: it has only one edge';
};

subtest 'circle_through' => sub {
    is_deeply rounded(circle_through([ 1, 0 ], [ 0, 1 ], [ -1, 0 ])), [ 0, 0, 1 ], 'the unit circle';
    is_deeply rounded(circle_through([ 3, 2 ], [ 1, 4 ], [ -1, 2 ])), [ 1, 2, 2 ], 'a circle of radius 2 round (1, 2)';
};

subtest 'steiner_chain' => sub {
    for my $turn (0, 0.1, 0.25) {
        my ($outer, $inner, @chain) = steiner_chain(9, 0.4, $turn);
        is scalar @chain, 9, "nine circles in the chain (turned $turn)";
        my $gap = sub { my ($p, $q) = @_; sqrt(($p->[0] - $q->[0])**2 + ($p->[1] - $q->[1])**2) };
        is_deeply [ grep { abs($gap->($chain[$_], $chain[ $_ - 1 ]) - $chain[$_][2] - $chain[ $_ - 1 ][2]) > 1e-9 } 0 .. 8 ], [],
            'each touches the next, all the way round';
        is_deeply [ grep { abs($gap->($_, $inner) - $_->[2] - $inner->[2]) > 1e-9 } @chain ], [], 'each touches the inner circle';
        is_deeply [ grep { abs($outer->[2] - $gap->($_, $outer) - $_->[2]) > 1e-9 } @chain ], [], 'and the outer one from inside';
    }
    my ($outer, $inner) = steiner_chain(9, 0.4, 0);
    ok abs($outer->[0] - $inner->[0]) > 0.1, 'the inner circle is off center';
};

subtest 'kepler' => sub {
    my $pi = 4 * atan2(1, 1);
    for my $mean (0.3, 2, 5.5) {
        my $eccentric = eccentric_anomaly($mean, 0.7);
        ok abs($eccentric - 0.7 * sin($eccentric) - $mean) < 1e-12, "solves Kepler's equation E - e sin E = M (M = $mean)";
    }
    is_deeply rounded(orbit_position(0, 0.7)), [ 0.3, 0 ], 'it starts closest to the sun, at the focus';
    is_deeply rounded(orbit_position(0.5, 0.7)), [ -1.7, 0 ], 'and is furthest away half a year later';
    my @slices = map {
        my ($from, $to) = ($_ / 12, ($_ + 1) / 12);
        my @arc = map { orbit_position($from + ($to - $from) * $_ / 2000, 0.7) } 0 .. 2000;
        my $area = 0;
        $area += ($arc[ $_ - 1 ][0] * $arc[$_][1] - $arc[$_][0] * $arc[ $_ - 1 ][1]) / 2 for 1 .. $#arc;
        $area;
    } 0 .. 11;
    my $share = $pi * sqrt(1 - 0.7**2) / 12;
    is_deeply [ grep { abs($_ - $share) > 1e-6 } @slices ], [], 'the line to the sun sweeps equal areas in equal times';
};

subtest 'fibonacci_word_path' => sub {
    is lsystem_moves('0', { 0 => '01', 1 => '0' }, 5), '0100101001001', 'the Fibonacci word';
    my @fibonacci = (1, 2);
    push @fibonacci, $fibonacci[-1] + $fibonacci[-2] for 1 .. 12;
    for my $order (6, 10, 13) {
        my @path = fibonacci_word_path($order);
        is scalar @path, $fibonacci[$order] + 1, "order $order takes a Fibonacci number of steps";
        is_deeply [ grep { abs(abs($path[$_][0] - $path[ $_ - 1 ][0]) + abs($path[$_][1] - $path[ $_ - 1 ][1]) - 1) > 1e-9 } 1 .. $#path ], [],
            'every step is one long, across or up and down';
        my %seen;
        is_deeply [ grep { $seen{ join ',', map { POSIX::floor($_ + 0.5) } @$_ }++ } @path ], [], 'and it never comes back to a corner it has been to';
    }
};

subtest 'ellipse_bounces' => sub {
    my $pi = 4 * atan2(1, 1);
    my ($a, $b) = (2, 1.2);
    my @bounces = ellipse_bounces($a, $b, 0.4, 2.1, 200);
    is scalar @bounces, 201, 'the start and every bounce';
    is_deeply [ grep { abs($_->[0]**2 / $a**2 + $_->[1]**2 / $b**2 - 1) > 1e-9 } @bounces ], [], 'all on the ellipse';
    is_deeply rounded($bounces[0]), rounded([ $a * cos 0.4, $b * sin 0.4 ]), 'starting where it was asked to';

    my $unit = sub { my ($from, $to) = @_; my ($dx, $dy) = ($to->[0] - $from->[0], $to->[1] - $from->[1]); my $l = sqrt($dx**2 + $dy**2); [ $dx / $l, $dy / $l ] };
    my @unequal = grep {
        my ($in, $out) = ($unit->(@bounces[ $_ - 1, $_ ]), $unit->(@bounces[ $_, $_ + 1 ]));
        my ($x, $y) = @{ $bounces[$_] };
        my @tangent = (-$y / $b**2, $x / $a**2);
        abs(($in->[0] * $tangent[0] + $in->[1] * $tangent[1]) - ($out->[0] * $tangent[0] + $out->[1] * $tangent[1])) > 1e-9;
    } 1 .. 199;
    is_deeply \@unequal, [], 'each bounce leaves at the angle it came in at';

    # The angular momenta about the two foci multiply to the same number on
    # every chord, which is why the chords all touch one smaller ellipse.
    my $focus    = sqrt($a**2 - $b**2);
    my $momentum = sub {
        my ($k) = @_;
        my $d = $unit->(@bounces[ $k, $k + 1 ]);
        my ($x, $y) = @{ $bounces[$k] };
        return (($x - $focus) * $d->[1] - $y * $d->[0]) * (($x + $focus) * $d->[1] - $y * $d->[0]);
    };
    my $first = $momentum->(0);
    is_deeply [ grep { abs($momentum->($_) - $first) > 1e-9 } 1 .. 199 ], [], 'the product of the momenta about the foci never changes';

    is_deeply rounded([ ellipse_bounces($a, $b, 0, $pi, 3) ]), [ [ 2, 0 ], [ -2, 0 ], [ 2, 0 ], [ -2, 0 ] ],
        'shot along the long axis it bounces straight back and forth';
};

subtest 'terdragon_path' => sub {
    my $pi = 4 * atan2(1, 1);
    for my $order (1, 3, 6) {
        my @path = terdragon_path($order);
        is scalar @path, 3**$order + 1, "order $order is 3^$order steps";
        my @odd = grep {
            my ($dx, $dy) = ($path[$_][0] - $path[ $_ - 1 ][0], $path[$_][1] - $path[ $_ - 1 ][1]);
            my $thirds = atan2($dy, $dx) / (2 * $pi / 3);
            abs(sqrt($dx**2 + $dy**2) - 1) > 1e-9 || abs($thirds - POSIX::floor($thirds + 0.5)) > 1e-9;
        } 1 .. $#path;
        is_deeply \@odd, [], 'every step is one long and heads along a multiple of 120 degrees';
        is_deeply rounded($path[-1]), rounded([ sqrt(3)**$order * cos($order * $pi / 6), sqrt(3)**$order * sin($order * $pi / 6) ]),
            'each order ends sqrt(3) times further out, turned 30 degrees';
        my %walked;
        is_deeply [ grep { $walked{ join ',', sort map { join ',', @{ rounded($_) } } @path[ $_ - 1, $_ ] }++ } 1 .. $#path ], [],
            'it comes back to corners but never walks the same edge twice';
    }
};

subtest 'brownian_tree' => sub {
    my @tree = brownian_tree(12, 7);
    is_deeply $tree[0], [ 0, 0 ], 'it grows from the seed at the origin';
    my %stuck = ('0,0' => 1);
    my @loose;
    for my $cell (@tree[ 1 .. $#tree ]) {
        my ($x, $y) = @$cell;
        push @loose, "$x,$y" if $stuck{"$x,$y"} || !grep { $stuck{$_} } ($x - 1) . ",$y", ($x + 1) . ",$y", "$x," . ($y - 1), "$x," . ($y + 1);
        $stuck{"$x,$y"} = 1;
    }
    is_deeply \@loose, [], 'every grain lands on an empty square next to one already stuck';
    my $far = sub { sqrt($_[0][0]**2 + $_[0][1]**2) };
    ok $far->($tree[-1]) >= 12, 'it stops once a grain lands as far out as asked';
    is_deeply [ grep { $far->($_) >= 12 } @tree[ 0 .. $#tree - 1 ] ], [], 'and not before';
    ok @tree > 50, 'by which time plenty have stuck';
    is_deeply [ brownian_tree(12, 7) ], \@tree, 'the same seed grows the same tree';
    isnt join(' ', map { "@$_" } brownian_tree(12, 8)), join(' ', map { "@$_" } @tree), 'and another seed another';
};

subtest 'cassini_product' => sub {
    my $pi = 4 * atan2(1, 1);
    is_deeply [ map { sprintf '%.9f', cassini_product($_, 0) } 0, 0.5, 2, -3 ], [ map { sprintf '%.9f', abs($_**2 - 1) } 0, 0.5, 2, -3 ],
        'along the line through the foci it is |x^2 - 1|';
    my @off = grep {
        my $r = sqrt(2 * cos(2 * $_));
        abs(cassini_product($r * cos $_, $r * sin $_) - 1) > 1e-9;
    } map { $_ * $pi / 20 - $pi / 4 + 0.01 } 0 .. 9;
    is_deeply \@off, [], 'on the lemniscate r^2 = 2 cos 2t it is 1';
    is cassini_product(0.3, 0.7), cassini_product(-0.3, -0.7), 'turning half way round leaves it alone';
};

subtest 'klein_point' => sub {
    my $pi = 4 * atan2(1, 1);
    my @unclosed = grep { "@{ rounded([ klein_point($pi, $_) ]) }" ne "@{ rounded([ klein_point(0, $pi - $_) ]) }" } 0, 0.4, 1, 2.5, 4;
    is_deeply \@unclosed, [], 'the tube closes up, its two ends glued with a flip';
    isnt "@{ rounded([ klein_point($pi, 1) ]) }", "@{ rounded([ klein_point(0, 1) ]) }", 'which glued straight would make it a torus';
    is_deeply rounded([ klein_point(0, 1) ]), rounded([ -0.4 * cos 1, 0, 0.4 * sin 1 ]), 'the mouth is a circle of radius 0.4';
};

subtest 'arrowhead_path' => sub {
    my $pi = 4 * atan2(1, 1);
    for my $order (1, 4, 5) {
        my @path = arrowhead_path($order);
        is scalar @path, 3**$order + 1, "order $order is 3^$order steps";
        my @odd = grep {
            my ($dx, $dy) = ($path[$_][0] - $path[ $_ - 1 ][0], $path[$_][1] - $path[ $_ - 1 ][1]);
            my $sixths = atan2($dy, $dx) / ($pi / 3);
            abs(sqrt($dx**2 + $dy**2) - 1) > 1e-9 || abs($sixths - POSIX::floor($sixths + 0.5)) > 1e-9;
        } 1 .. $#path;
        is_deeply \@odd, [], 'every step is one long and heads along a multiple of 60 degrees';
        is sprintf('%.9f', sqrt($path[-1][0]**2 + $path[-1][1]**2)), sprintf('%.9f', 2**$order), 'it ends 2^order away from where it began';
        my %seen;
        is_deeply [ grep { $seen{"@{ rounded($_) }"}++ } @path ], [], 'and never comes back to a corner';
    }
    # Whether (x, y) is in Sierpinski's triangle with corners (0, 0), (side,
    # 0) and the one above, cut down until the triangles left are side 1.
    # Edges count as in.
    my $in_sierpinski;
    $in_sierpinski = sub {
        my ($x, $y, $side) = @_;
        my $h = sqrt(3) / 2;
        return 0 if $y < -1e-9 || $y > $x * 2 * $h + 1e-9 || $y > ($side - $x) * 2 * $h + 1e-9;
        return 1 if $side <= 1;
        my $half = $side / 2;
        return $in_sierpinski->($x, $y, $half) || $in_sierpinski->($x - $half, $y, $half) || $in_sierpinski->($x - $half / 2, $y - $half * $h, $half);
    };
    for my $order (2, 4) {
        is_deeply [ grep { !$in_sierpinski->(@$_, 2**$order) } arrowhead_path($order) ], [],
            "order $order stays inside Sierpinski's triangle, out of every hole";
    }
    ok !$in_sierpinski->(8, 2, 16), 'which has a hole in the middle';
    ok $in_sierpinski->(8, 0, 16) && $in_sierpinski->(1.5, 0.2, 16), 'but not everywhere';
};

subtest 'henon_points' => sub {
    my @points = henon_points(2000);
    is scalar @points, 2000, 'as many points as asked for';
    my @unruly = grep { abs($points[$_][0] - (1 - 1.4 * $points[ $_ - 1 ][0]**2 + $points[ $_ - 1 ][1])) > 1e-9 || abs($points[$_][1] - 0.3 * $points[ $_ - 1 ][0]) > 1e-9 } 1 .. $#points;
    is_deeply \@unruly, [], 'each point is (1 - 1.4x^2 + y, 0.3x) of the one before';
    is_deeply [ grep { abs($_->[0]) > 1.3 || abs($_->[1]) > 0.4 } @points ], [], 'all on the attractor, inside its box';
};

subtest 'gray_scott_step' => sub {
    my ($cols, $rows) = (6, 5);
    my @u = (1) x ($cols * $rows);
    my @v = (0) x ($cols * $rows);
    my ($u, $v) = gray_scott_step(\@u, \@v, $cols, $rows, 0.055, 0.062, 1);
    is_deeply [ $u, $v ], [ \@u, \@v ], 'all chemical u and none of v stays that way';

    my @spike = (0) x ($cols * $rows);
    $spike[7] = 1;
    ($u) = gray_scott_step(\@spike, [ (0) x ($cols * $rows) ], $cols, $rows, 0, 0, 1);
    is sprintf('%.9f', List::Util::sum(@$u)), '1.000000000', 'with no feed or kill, spreading out keeps the total';
    ok $u->[7] < 1 && $u->[8] > 0 && $u->[6] > 0 && $u->[1] > 0 && $u->[13] > 0, 'spreading to its neighbors';
    ($u) = gray_scott_step([ (0) x 5, 1, (0) x 24 ], [ (0) x 30 ], $cols, $rows, 0, 0, 1);
    ok $u->[0] > 0 && $u->[11] > 0 && $u->[2] == 0, 'and across the edge, which wraps round';

    @u = (0.5) x ($cols * $rows);
    @v = (0.25) x ($cols * $rows);
    ($u, $v) = gray_scott_step(\@u, \@v, $cols, $rows, 0.04, 0.06, 1);
    is sprintf('%.9f', $u->[0]), sprintf('%.9f', 0.5 - 0.5 * 0.25**2 + 0.04 * 0.5), 'evenly mixed, u loses u v^2 and gains the feed';
    is sprintf('%.9f', $v->[0]), sprintf('%.9f', 0.25 + 0.5 * 0.25**2 - 0.1 * 0.25), 'and v gains u v^2 and loses feed plus kill';
};

subtest 'thomas_velocity' => sub {
    my $b = 0.208186;
    is_deeply rounded([ thomas_velocity(0, 0, 0) ]), [ 0, 0, 0 ], 'the origin stands still';
    is_deeply rounded([ thomas_velocity(1, 0, 0) ]), rounded([ -$b, 0, sin 1 ]), 'worked by hand at (1, 0, 0)';
    my @turned = grep {
        my @v = thomas_velocity(@$_);
        "@{ rounded([ thomas_velocity(@$_[ 1, 2, 0 ]) ]) }" ne "@{ rounded([ @v[ 1, 2, 0 ] ]) }";
    } [ 0.3, -1.2, 2 ], [ 4, 0.5, -3 ];
    is_deeply \@turned, [], 'cycling x -> y -> z -> x cycles the velocity the same way';
    my @path = thomas_points(500);
    is scalar @path, 500, 'as many points as asked for';
    is_deeply [ grep { grep { abs > 1 / $b } @$_ } @path ], [], 'and they stay inside the box |x|, |y|, |z| < 1/b';
};

subtest 'percolation_clusters' => sub {
    my $labels = percolation_clusters([ [ 1, 1, 0, 1 ], [ 0, 1, 0, 1 ], [ 1, 0, 0, 1 ] ]);
    is_deeply $labels, [ [ 1, 1, 0, 2 ], [ 0, 1, 0, 2 ], [ 3, 0, 0, 2 ] ],
        'open squares touching side to side share a cluster, numbered biggest first, then top to bottom';

    my $seed = 5;
    my $open = [ map { [ map { $seed = next_seed($seed); $seed < 0.6 * 2147483648 ? 1 : 0 } 1 .. 30 ] } 1 .. 20 ];
    $labels = percolation_clusters($open);
    my (@split, %size);
    for my $r (0 .. 19) {
        for my $c (0 .. 29) {
            push @split, "$r,$c" if !$open->[$r][$c] != !$labels->[$r][$c];
            $size{ $labels->[$r][$c] }++ if $labels->[$r][$c];
            push @split, "$r,$c" if $c < 29 && $open->[$r][$c] && $open->[$r][ $c + 1 ] && $labels->[$r][$c] != $labels->[$r][ $c + 1 ];
            push @split, "$r,$c" if $r < 19 && $open->[$r][$c] && $open->[ $r + 1 ][$c] && $labels->[$r][$c] != $labels->[ $r + 1 ][$c];
        }
    }
    is_deeply \@split, [], 'on a random grid every open square is labeled and neighbors agree';
    my @sizes = map { $size{$_} } sort { $a <=> $b } keys %size;
    is_deeply \@sizes, [ sort { $b <=> $a } @sizes ], 'and bigger clusters get smaller numbers';
    is_deeply [ sort { $a <=> $b } keys %size ], [ 1 .. keys %size ], 'numbered 1, 2, 3, ... with none skipped';
};

subtest 'ikeda_points' => sub {
    my @points = ikeda_points(1000);
    is scalar @points, 1000, 'as many points as asked for';
    my @unruly = grep {
        my ($x, $y) = @{ $points[ $_ - 1 ] };
        my $t = 0.4 - 6 / (1 + $x**2 + $y**2);
        abs($points[$_][0] - (1 + 0.9 * ($x * cos($t) - $y * sin($t)))) > 1e-9 || abs($points[$_][1] - 0.9 * ($x * sin($t) + $y * cos($t))) > 1e-9;
    } 1 .. $#points;
    is_deeply \@unruly, [], 'each point is the one before turned by 0.4 - 6 / (1 + |z|^2), shrunk by 0.9 and moved 1 right';
};

subtest 'carpet_hole' => sub {
    is carpet_hole(0.5,  0.5,  4), 1, 'the middle ninth is the first hole';
    is carpet_hole(1 / 6, 1 / 6, 4), 2, 'the middle of the bottom left ninth is a second hole';
    is carpet_hole(0.05, 0.05, 4), 3, '0.05 is 0.0011... in base 3, so a third hole';
    is carpet_hole(0.05, 0.05, 2), 0, 'which is still carpet if we only cut twice';
    is carpet_hole(0.5,  0.01, 4), 0, '0.5 is 0.111... but 0.01 is 0.00002..., so they never both have a 1';

    # Cell centers of a 243 square grid fall in a hole at the same level as
    # their whole cell, and each cut keeps 8 of every 9 squares.
    my $kept = grep { !carpet_hole(($_ % 243 + 0.5) / 243, (int($_ / 243) + 0.5) / 243, 3) } 0 .. 243**2 - 1;
    is $kept, 243**2 * 8**3 / 9**3, 'three cuts keep (8/9)^3 of the square';

    my @unsymmetric = grep {
        my ($x, $y) = @$_;
        my $level = carpet_hole($x, $y, 5);
        grep { carpet_hole(@$_, 5) != $level } [ $y, $x ], [ 1 - $x, $y ], [ $x, 1 - $y ];
    } [ 0.13, 0.71 ], [ 0.402, 0.05 ], [ 0.93, 0.62 ];
    is_deeply \@unsymmetric, [], 'it has the symmetry of a square';
};

subtest 'lotka_velocity' => sub {
    is_deeply rounded([ lotka_velocity(4, 2.75) ]), [ 0, 0 ], 'prey and predators balance at (0.4/0.1, 1.1/0.4)';
    is_deeply rounded([ lotka_velocity(2, 1) ]), [ 1.4, -0.2 ], 'worked by hand at (2, 1)';
    is_deeply rounded([ lotka_velocity(3, 0) ]), [ 3.3, 0 ], 'with no predators the prey just grow';

    my @orbit  = lotka_orbit(8, 2.75, 20, 1000);
    my @values = map { lotka_invariant(@$_) } @orbit;
    is scalar @orbit, 1001, 'an orbit has its start and a point per step';
    ok List::Util::max(@values) - List::Util::min(@values) < 1e-6, '0.1x - 0.4 ln x + 0.4y - 1.1 ln y stays the same along it';
    ok List::Util::min(map { $_->[0] } @orbit) < 2, 'and the prey crash';
    ok List::Util::max(map { $_->[1] } @orbit) > 4, 'while the predators boom';
};

subtest 'magnet_step' => sub {
    is_deeply rounded([ magnet_step(0, 0, 0, 0) ]), [ 0.25, 0 ], '((0 - 1) / (0 - 2))^2 at c = 0';
    is_deeply rounded([ magnet_step(0, 0, 0, 1) ]), [ 0.32, -0.24 ], '((i - 1) / (i - 2))^2 = (8 - 6i) / 25';
    my @moved = grep { "@{ rounded([ magnet_step(1, 0, @$_) ]) }" ne '1 0' } [ 0.3, 0.7 ], [ -2, 1.5 ], [ 3, 0 ];
    is_deeply \@moved, [], 'z = 1 stays put for every c';
};

subtest 'magnet_escape' => sub {
    is_deeply [ magnet_escape(1.5, 0, 100) ], [ 'settled', 1 ], 'at c = 1.5 the first step lands on 1';
    is_deeply [ magnet_escape(1, 0, 50) ], [], 'at c = 1 it sits at 0 forever';
    for my $case ([ -0.25, 1, 'escaped' ], [ 0, 1.5, 'escaped' ], [ -2, 0.5, 'settled' ], [ 3, 0.5, 'settled' ]) {
        my ($cx, $cy, $expected) = @$case;
        my $c = [ $cx, $cy ];
        my ($fate, $steps) = magnet_escape(@$c, 200);
        is $fate, $expected, "c = @$c $expected";
        my ($x, $y) = (0, 0);
        ($x, $y) = magnet_step($x, $y, @$c) for 1 .. $steps;
        my $size = $fate eq 'settled' ? ($x - 1)**2 + $y**2 : $x**2 + $y**2;
        ok $fate eq 'settled' ? $size < 1e-6 : $size > 1e4, "c = @$c: $fate after $steps steps, and it did";
    }
};

subtest 'ising_energy' => sub {
    is ising_energy([ [ 1, 1 ], [ 1, 1 ] ]), -8, 'a 2 by 2 wrapped grid has each pair joined twice, all agreeing';
    is ising_energy([ [ 1, -1, 1, -1 ], [ -1, 1, -1, 1 ] ]), 16, 'a checkerboard disagrees everywhere';
    is ising_energy([ [ 1, 1, -1 ], [ 1, -1, -1 ] ]), 0, 'worked by hand: two up pairs across, four down, both ways round';

    my $seed  = 9;
    my $spins = [ map { [ map { $seed = next_seed($seed); $seed % 2 ? 1 : -1 } 1 .. 7 ] } 1 .. 5 ];
    my @wrong = grep {
        my ($r, $c) = (int($_ / 7), $_ % 7);
        my $before = ising_energy($spins);
        $spins->[$r][$c] *= -1;
        my $after = ising_energy($spins);
        $spins->[$r][$c] *= -1;
        ising_flip_cost($spins, $r, $c) != $after - $before;
    } 0 .. 34;
    is_deeply \@wrong, [], 'the cost of flipping a spin is the change in energy, wrapping round the edges';
};

subtest 'ising_sweep' => sub {
    my $seed  = 4;
    my $spins = [ map { [ map { $seed = next_seed($seed); $seed % 2 ? 1 : -1 } 1 .. 20 ] } 1 .. 10 ];
    my @energies = (ising_energy($spins));
    for (1 .. 5) {
        $seed = ising_sweep($spins, 0.01, $seed);
        push @energies, ising_energy($spins);
    }
    is_deeply [ grep { $energies[$_] > $energies[ $_ - 1 ] } 1 .. 5 ], [], 'nearly frozen, the energy never goes up';
    ok $energies[-1] < $energies[0], 'and it comes down';

    my $up = [ map { [ (1) x 20 ] } 1 .. 10 ];
    ising_sweep($up, 0.01, 1);
    is_deeply $up, [ map { [ (1) x 20 ] } 1 .. 10 ], 'all spins up stays up';

    my $magnetization = sub {
        my ($temperature) = @_;
        my ($spins, $seed, $total) = ([ map { [ (1) x 20 ] } 1 .. 10 ], 1, 0);
        for my $sweep (1 .. 20) {
            $seed = ising_sweep($spins, $temperature, $seed);
            $total += abs(List::Util::sum(map { @$_ } @$spins) / 200) if $sweep > 10;
        }
        return $total / 10;
    };
    ok $magnetization->(1) > 0.9, 'cold, all up mostly stays up';
    ok $magnetization->(5) < 0.3, 'hot, it melts into a mix of up and down';
};

subtest 'tribonacci_word' => sub {
    is tribonacci_word(13), '1213121121312', '1 -> 12, 2 -> 13, 3 -> 1, starting from 1';
    my $word = tribonacci_word(20000);
    is length $word, 20000, 'as long as asked for';
    my %count;
    $count{$_}++ for split //, $word;
    ok abs($count{1} / $count{2} - 1.839286755) < 1e-3, '1s outnumber 2s by the tribonacci constant';
    ok abs($count{2} / $count{3} - 1.839286755) < 1e-3, 'and 2s outnumber 3s by it too';
};

subtest 'rauzy_points' => sub {
    my @points = rauzy_points(5000);
    is scalar @points, 5000, 'as many points as asked for';
    is join('', map { $_->[2] } @points[ 0 .. 6 ]), '1213121', 'each is tagged with the letter that comes next';
    is_deeply rounded([ @{ $points[0] }[ 0, 1 ] ]), [ 0, 0 ], 'the empty start sits at 0';

    # The second point is the 1 step, which lands on the small root of
    # x^3 = x^2 + x + 1.
    my ($ax, $ay) = @{ $points[1] }[ 0, 1 ];
    my ($sx, $sy) = ($ax * $ax - $ay * $ay, 2 * $ax * $ay);
    my ($cx, $cy) = ($sx * $ax - $sy * $ay, $sx * $ay + $sy * $ax);
    ok abs($cx - $sx - $ax - 1) < 1e-9 && abs($cy - $sy - $ay) < 1e-9, 'one step of 1 lands on a root of x^3 = x^2 + x + 1';
    ok $ax**2 + $ay**2 < 1, 'the one inside the unit circle';
    my $size = $ax**2 + $ay**2;
    my ($two_x, $two_y) = (($ax + 1) * $ax / $size + $ay * $ay / $size, ($ay * $ax - ($ax + 1) * $ay) / $size);
    is_deeply rounded([ @{ $points[2] }[ 0, 1 ] ]), rounded([ $ax + $two_x, $ay + $two_y ]), 'a 2 step adds (a + 1) / a';
    is_deeply [ grep { $_->[0]**2 + $_->[1]**2 > 9 } @points ], [], 'and it never wanders off';
};

subtest 'biomorph' => sub {
    ok defined biomorph(0, 0, 0, 0, 50), 'z = 0 with c = 0 stays put, inside';
    ok !defined biomorph(100, 100, 0, 0, 50), '(100 + 100i)^3 = 10^6(-2 + 2i) is far out both ways, outside';
    is biomorph(100, 0, 0, 0, 50), 1, '100^3 is far out, but only along the real line, so it counts as inside';
    is biomorph(2, 0, 0.5, 0, 50), 2, '2 -> 8.5 -> 614.6, still real';
};

subtest 'harper_trace' => sub {
    my @wrong = grep { abs(harper_trace($_, 0, 1) - $_) > 1e-9 } -5, -1, 0.3, 4;
    is_deeply \@wrong, [], 'with no field the trace is just E, so the band is -4 to 4';
    @wrong = grep { abs(harper_trace($_, 1, 2) - ($_ * $_ - 4)) > 1e-9 } -3, -1, 0.5, 2;
    is_deeply \@wrong, [], 'at half a flux quantum it is E^2 - 4, so the bands reach 2 sqrt 2';
    my @lopsided = grep {
        my ($e, $p, $q) = @$_;
        abs(harper_trace($e, $p, $q) - harper_trace(-$e, $p, $q) * (-1)**$q) > 1e-9 || abs(harper_trace($e, $p, $q) - harper_trace($e, $q - $p, $q)) > 1e-9;
    } [ 1.3, 1, 3 ], [ -0.7, 2, 5 ], [ 2.2, 3, 7 ];
    is_deeply \@lopsided, [], 'flipping E or the flux gives the same spectrum';
};

subtest 'galaxy_point' => sub {
    is_deeply rounded(galaxy_point(3, 2, 0, 0)), [ 3, 0 ], 'an untilted ellipse starts at the end of its long axis';
    is_deeply rounded(galaxy_point(3, 2, 0, atan2(1, 0))), [ 0, 2 ], 'and a quarter of the way round reaches the short one';
    my @off = grep {
        my ($x, $y) = @{ galaxy_point(3, 2, 0.7, $_) };
        my ($u, $v) = ($x * cos(0.7) + $y * sin(0.7), -$x * sin(0.7) + $y * cos(0.7));
        abs(($u / 3)**2 + ($v / 2)**2 - 1) > 1e-9;
    } 0.1, 1, 2.5, 4;
    is_deeply \@off, [], 'tilted, it is the same ellipse turned';
};

# The squares a domino covers, from its lower left square and type.
sub domino_squares {
    my ($key, $type) = @_;
    my ($x, $y) = split /,/, $key;
    return $type =~ /[NS]/ ? ("$x,$y", ($x + 1) . ",$y") : ("$x,$y", "$x," . ($y + 1));
}

subtest 'aztec_tiling' => sub {
    for my $order (1 .. 8) {
        my $tiling = aztec_tiling($order, 100 + $order);
        my %covered;
        $covered{$_}++ for map { domino_squares($_, $tiling->{$_}) } keys %$tiling;
        my %diamond = map {
            my $x = $_;
            map { ("$x,$_" => 1) } grep { abs($x + 0.5) + abs($_ + 0.5) <= $order } -$order .. $order - 1;
        } -$order .. $order - 1;
        is_deeply \%covered, \%diamond, "order $order: every square of the diamond covered exactly once";
        is scalar keys %$tiling, $order * ($order + 1), "by n(n + 1) dominoes";
    }

    my %tilings = map { my $t = aztec_tiling(2, $_); (join(' ', map {"$_$t->{$_}"} sort keys %$t) => 1) } 1 .. 200;
    is scalar keys %tilings, 8, 'all 8 tilings of the order 2 diamond turn up';

    my $big = aztec_tiling(20, 7);
    is $big->{'-1,19'}, 'N', 'the domino at the top is a north one';
    is $big->{'-20,-1'}, 'W', 'and the one at the far left a west one';
};

subtest 'rotor_cluster' => sub {
    is_deeply rotor_cluster(6), { '0,0' => 1, '0,1' => 2, '-1,0' => 3, '0,-1' => 4, '1,0' => 5, '0,2' => 6 },
        'worked by hand: the first stays put, the next four go north, west, south and east, and the sixth turns north twice';
    my $cluster = rotor_cluster(2000);
    is scalar keys %$cluster, 2000, 'every particle adds a square';
    my $radius = sqrt(2000 / (4 * atan2(1, 1)));
    my @far = grep { my ($x, $y) = split /,/; sqrt($x * $x + $y * $y) > $radius + 1.5 } keys %$cluster;
    is_deeply \@far, [], 'it stays inside a circle of the same area, give or take a square or two';
    my @holes = grep { !exists $cluster->{$_} } map { my $x = $_; map {"$x,$_"} grep { $x * $x + $_ * $_ < ($radius - 1.5)**2 } -30 .. 30 } -30 .. 30;
    is_deeply \@holes, [], 'and fills it with no holes';
};

subtest 'mira_step' => sub {
    is_deeply rounded([ mira_step(2, 1, 0.5, 1) ]), [ 2.8, 0.286877828 ], 'worked by hand: x = 1 + F(2) = 2.8, y = -2 + F(2.8)';
    my $f = sub { -0.48 * $_[0] + 2 * 1.48 * $_[0]**2 / (1 + $_[0]**2) };
    my @lost = grep {
        my ($x, $y) = @$_;
        my ($next_x, $next_y) = mira_step($x, $y, -0.48, 1);
        my $back_x = $f->($next_x) - $next_y;
        my $back_y = $next_x - $f->($back_x);
        abs($back_x - $x) > 1e-9 || abs($back_y - $y) > 1e-9;
    } [ 0.3, 2 ], [ -4, 1.5 ], [ 7, -3 ];
    is_deeply \@lost, [], 'with b = 1 each step can be undone';
    is scalar(my @points = mira_points(300, -0.48, 1, 4, 0)), 300, 'as many points as asked for';
};

subtest 'pappus_circle' => sub {
    for my $r (0.3, 0.6) {
        is_deeply rounded(pappus_circle(0, $r)), rounded([ (1 + $r) / 2, 0, (1 - $r) / 2 ]), "r = $r: circle 0 is the semicircle on CB";
        my @untouching = grep {
            my ($x, $y, $radius) = @{ pappus_circle($_, $r) };
            my ($next_x, $next_y, $next_radius) = @{ pappus_circle($_ + 1, $r) };
            abs(sqrt(($x - 0.5)**2 + $y**2) - (0.5 - $radius)) > 1e-12
                || abs(sqrt(($x - $r / 2)**2 + $y**2) - ($r / 2 + $radius)) > 1e-12
                || abs(sqrt(($x - $next_x)**2 + ($y - $next_y)**2) - ($radius + $next_radius)) > 1e-12;
        } 0 .. 8;
        is_deeply \@untouching, [], "r = $r: each circle touches the big semicircle, the one on AC, and the next circle";
        my @misplaced = grep { my ($x, $y, $radius) = @{ pappus_circle($_, $r) }; abs($y - 2 * $_ * $radius) > 1e-12 } 1 .. 8;
        is_deeply \@misplaced, [], "r = $r: circle n's center is n diameters up";
    }
};

subtest 'pi_digits' => sub {
    my @digits = pi_digits(800);
    is scalar @digits, 800, 'as many digits as asked for';
    is join('', @digits[ 0 .. 49 ]), '31415926535897932384626433832795028841971693993751', 'the first fifty';
    is join('', @digits[ 762 .. 767 ]), '999999', 'the Feynman point: six nines from decimal place 762';
};

subtest 'phase_function' => sub {
    my $size = sub { my ($re, $im) = phase_function(@_); return sqrt($re**2 + $im**2) };
    ok $size->(@$_) < 1e-12, "vanishes at (@$_)" for [ 1, 0 ], [ -1, 0 ], [ 2, 1 ];

    # The poles are the square roots of -2 - 2i: size 8^(1/4), angle -67.5 degrees.
    my $pi = 4 * atan2(1, 1);
    my ($px, $py) = (8**0.25 * cos(-3 * $pi / 8), 8**0.25 * sin(-3 * $pi / 8));
    ok $size->($px + 1e-7, $py) > 1e5,  'blows up next to one pole';
    ok $size->(-$px + 1e-7, -$py) > 1e5, 'and the other';
};

subtest 'phase_wheel' => sub {
    my $pi = 4 * atan2(1, 1);
    is_deeply [ map { int($_ + 0.5) } phase_wheel(0) ],              [ 255, 0, 0 ], 'angle 0 is red';
    is_deeply [ map { int($_ + 0.5) } phase_wheel(2 * $pi / 3) ],   [ 0, 255, 0 ], 'a third of a turn is green';
    is_deeply [ map { int($_ + 0.5) } phase_wheel(-2 * $pi / 3) ],  [ 0, 0, 255 ], 'a third back is blue';
    is_deeply [ map { int($_ + 0.5) } phase_wheel($pi) ], [ map { int($_ + 0.5) } phase_wheel(-$pi) ], 'and it closes up';
};

subtest 'escaping_orbit' => sub {
    is_deeply [ escaping_orbit(1, 0, 100) ], [ [ 1, 0 ], [ 2, 0 ] ], 'c = 1 passes through 1 and 2, then leaves at 5';
    is_deeply [ escaping_orbit(0, 0, 100) ],  [], 'c = 0 never leaves, so it marks nothing';
    is_deeply [ escaping_orbit(-2, 0, 100) ], [], 'nor does c = -2, which sits on the edge at 2 forever';

    my $hits = buddhabrot_hits(60);
    my @lopsided = grep { my ($r, $c) = split /,/; ($hits->{"$r,$c"} // 0) != ($hits->{ $r . ',' . (139 - $c) } // 0) } keys %$hits;
    is_deeply \@lopsided, [], 'the picture is its own mirror image, since conjugate c gives conjugate orbits';
    ok keys(%$hits) > 500, 'and lots of pixels get marked';
};

subtest 'logistic_orbit' => sub {
    my $distinct = sub { my %seen = map { sprintf('%.6f', $_) => 1 } @_; return sort keys %seen };
    is_deeply [ $distinct->(logistic_orbit(2.8, 1000, 100)) ], [ sprintf '%.6f', 1 - 1 / 2.8 ],
        'r = 2.8 settles on 1 - 1/r';
    my $r = 3.2;
    my @pair = map { sprintf '%.6f', ($r + 1 + $_ * sqrt(($r + 1) * ($r - 3))) / (2 * $r) } -1, 1;
    is_deeply [ $distinct->(logistic_orbit($r, 1000, 100)) ], \@pair, 'r = 3.2 flips between the two values of the 2-cycle';
    is scalar(my @four = $distinct->(logistic_orbit(3.5, 1000, 100))), 4, 'r = 3.5 has doubled again, to 4';
    ok scalar(my @many = $distinct->(logistic_orbit(3.9, 1000, 100))) > 50, 'r = 3.9 is chaos';
};

subtest 'apollonian_circles' => sub {
    my @circles = apollonian_circles(0.04);
    my @first   = map { $_->[0] } @circles[ 0 .. 3 ];
    close_to List::Util::sum(@first)**2, 2 * List::Util::sum(map { $_**2 } @first),
        'the starting four satisfy Descartes: (sum of k)^2 = 2 (sum of k^2)';

    # Circles are [curvature, x, y]; the outer one has curvature -1.
    my $gap = sub {
        my ($a, $b) = @_;
        my $distance = sqrt(($a->[1] - $b->[1])**2 + ($a->[2] - $b->[2])**2);
        return $distance - abs(1 / $a->[0] + 1 / $b->[0]);
    };
    my @inner = grep { $_->[0] > 0 } @circles;
    my @lonely = grep {
        my $c = $_;
        (grep { $_ != $c && abs($gap->($c, $_)) < 1e-9 } @circles) < 3;
    } @inner;
    is scalar @lonely, 0, 'every circle touches at least three others';
    my @overlaps = grep {
        my $i = $_;
        grep { $gap->($inner[$i], $inner[$_]) < -1e-9 } $i + 1 .. $#inner;
    } 0 .. $#inner;
    is scalar @overlaps, 0, 'no two circles overlap';
    # Against the outer circle the gap is d - (1 - r), which is at most 0
    # for a circle inside it.
    is_deeply [ grep { $gap->($circles[0], $_) > 1e-9 } @inner ], [], 'and they all sit inside the outer one';

    # Halving the smallest radius allowed multiplies the number of circles by
    # 2^d, where d is the gasket's fractal dimension, about 1.3057.
    my $finer  = () = apollonian_circles(0.0005);
    my $coarse = () = apollonian_circles(0.001);
    ok abs(log($finer / $coarse) / log(2) - 1.3057) < 0.02, 'the count of circles grows at the fractal dimension, 1.3057'
        or diag "$coarse -> $finer";
};

subtest 'collatz_sequence' => sub {
    is_deeply [ collatz_sequence(6) ], [ 6, 3, 10, 5, 16, 8, 4, 2, 1 ];
    is_deeply [ collatz_sequence(1) ], [1], '1 is already home';
    my @long = collatz_sequence(27);
    is scalar @long, 112, '27 takes 111 steps';
    is List::Util::max(@long), 9232, 'and climbs as high as 9232 on the way';
};

subtest 'fit_to_frame' => sub {
    my $place = fit_to_frame([ [ 0, 0 ], [ 10, 0 ], [ 10, 5 ] ]);
    my ($left, $right, $top) = map { $place->(@$_) } [ 0, 0 ], [ 10, 0 ], [ 10, 5 ];
    ok abs(($left->[1] + $right->[1]) / 2 - 69.5) < 1e-9, 'centered across';
    ok abs(($left->[0] + $top->[0]) / 2 - 23.5) < 1e-9, 'centered down';
    ok abs(($right->[1] - $left->[1]) - 2 * 2 * ($right->[0] - $top->[0])) < 1e-9,
        'a unit is twice as many pixels across as rows down, so shapes keep their proportions';
    ok $left->[1] >= 0 && $right->[1] <= 139 && $top->[0] >= 0 && $left->[0] <= 47, 'and it all fits';
};

subtest 'times_table_chords' => sub {
    is_deeply [ times_table_chords(10, 2) ], [ map { [ $_, 2 * $_ % 10 ] } 1 .. 9 ], 'k joins 2k mod 10, skipping 0 which joins itself';
    for ([ 200, 2, 1 ], [ 200, 3, 2 ], [ 200, 21, 20 ]) {
        my ($n, $m, $fixed) = @$_;
        is scalar(my @chords = times_table_chords($n, $m)), $n - $fixed,
            "k -> ${m}k mod $n leaves out the $fixed points where (m - 1)k is a multiple of $n";
    }
};

subtest 'koch_outline' => sub {
    my $length = sub { sqrt(($_[0][0] - $_[1][0])**2 + ($_[0][1] - $_[1][1])**2) };
    my @perimeters;
    for my $order (0 .. 4) {
        my @outline = koch_outline($order);
        is scalar @outline, 3 * 4**$order + 1, "order $order has 3 x 4^$order edges";
        ok $length->(@outline[ 0, -1 ]) < 1e-9, "order $order closes on itself";
        my @edges = map { $length->(@outline[ $_ - 1, $_ ]) } 1 .. $#outline;
        ok((List::Util::max(@edges) - List::Util::min(@edges)) < 1e-9, "order $order has every edge the same length");
        push @perimeters, List::Util::sum(@edges);
    }
    is_deeply [ grep { abs($perimeters[$_] / $perimeters[ $_ - 1 ] - 4 / 3) > 1e-9 } 1 .. 4 ], [],
        'each order is 4/3 the perimeter of the last, so the limit is infinitely long';

    # Shoelace area. The bumps must point out: inward ones would shrink it.
    my $area = sub {
        my @p = @_;
        return abs(List::Util::sum(map { $p[ $_ - 1 ][0] * $p[$_][1] - $p[$_][0] * $p[ $_ - 1 ][1] } 1 .. $#p)) / 2;
    };
    my $triangle = $area->(koch_outline(0));
    for my $order (1 .. 4) {
        close_to $area->(koch_outline($order)) / $triangle, 1 + 3 / 5 * (1 - (4 / 9)**$order),
            "order $order has 1 + 3/5 (1 - (4/9)^$order) of the triangle's area, heading for 8/5";
    }
};

subtest 'chladni' => sub {
    close_to chladni(1, 2, 0, 0.5), -1, 'worked by hand: cos 0 cos pi - cos 0 cos pi/2';
    is_deeply [ grep { abs(chladni(3, 5, $_ / 10, $_ / 10)) > 1e-12 } 0 .. 10 ], [], 'the diagonal never moves';
    close_to chladni(3, 5, 0.2, 0.7), -chladni(3, 5, 0.7, 0.2), 'swapping x and y flips the sign';
};

subtest 'harmonograph_points' => sub {
    my @points = harmonograph_points(20_000);
    is scalar @points, 20_000, 'one point per step';
    is_deeply [ grep { abs($_->[0]) > 3 || abs($_->[1]) > 2 } @points ], [],
        'the pen never goes past the pendulums\' full swing';
    my $reach = sub { List::Util::max(map { sqrt($_->[0]**2 + $_->[1]**2) } @_) };
    ok $reach->(@points[ -2000 .. -1 ]) < $reach->(@points[ 0 .. 1999 ]) / 2, 'and the swing dies away as it goes';
};

subtest 'sunflower_seeds' => sub {
    my $pi = 4 * atan2(1, 1);
    close_to $GOLDEN_ANGLE * 180 / $pi, 137.50776405003785, 'the golden angle';

    # How far k turns of the golden angle land from a whole number of turns.
    my $miss = sub {
        my $turns = $_[0] * $GOLDEN_ANGLE / (2 * $pi);
        return 360 * abs($turns - int($turns + 0.5));
    };
    is_deeply [ grep { $miss->($_) < 10 } 1 .. 40 ], [ 21, 34 ],
        'only Fibonacci numbers of turns come back close to where they started';

    my @seeds = sunflower_seeds(1000, 1);
    my @wedges = (0) x 8;
    for my $seed (@seeds) {
        my $angle = atan2($seed->[1], $seed->[0]);
        $angle += 2 * $pi if $angle < 0;
        $wedges[ int($angle / ($pi / 4)) % 8 ]++;
    }
    is_deeply [ grep { abs($_ - 125) > 6 } @wedges ], [], 'seeds spread evenly around the head'
        or diag "@wedges";
    close_to sqrt($seeds[99][0]**2 + $seeds[99][1]**2), 10, 'seed n sits at radius sqrt(n)';
};

subtest 'hilbert_path' => sub {
    for my $order (1, 3, 4) {
        my $side = 2**$order;
        my @path = hilbert_path($order);
        is scalar @path, $side * $side, "order $order has a point for every cell";
        is_deeply [ @path[ 0, -1 ] ], [ [ 0, 0 ], [ $side - 1, 0 ] ], "order $order runs corner to neighboring corner";
        is_deeply [ grep { abs($path[$_][0] - $path[ $_ - 1 ][0]) + abs($path[$_][1] - $path[ $_ - 1 ][1]) != 1 } 1 .. $#path ], [],
            "order $order always steps to a neighboring cell";
        my %seen;
        is_deeply [ grep { $seen{"@$_"}++ || $_->[0] < 0 || $_->[1] < 0 || $_->[0] >= $side || $_->[1] >= $side } @path ], [],
            "order $order visits every cell once, inside the grid";
    }
};

subtest 'rotate_quarter_turns' => sub {
    is_deeply rotate_quarter_turns([ 2, 1 ], 1),  [ -1, 2 ],  'a quarter turn counterclockwise';
    is_deeply rotate_quarter_turns([ 2, 1 ], 2),  [ -2, -1 ], 'a half turn';
    is_deeply rotate_quarter_turns([ 2, 1 ], -1), [ 1, -2 ],  'a quarter turn clockwise';
    is_deeply rotate_quarter_turns([ 2, 1 ], 4),  [ 2, 1 ],   'a full turn comes back';
};

subtest 'dragon_path' => sub {
    is join('', map { dragon_turn($_) > 0 ? 'L' : 'R' } 1 .. 8), 'LLRLLRRL', 'the first turns of the paper folding sequence';

    for my $order (4, 7, 10) {
        my @path = dragon_path($order);
        is scalar @path, 2**$order + 1, "order $order has 2^$order segments";
        my %edges;
        my @reused = grep {
            my ($a, $b) = sort map { "@$_" } @path[ $_ - 1, $_ ];
            $edges{"$a|$b"}++;
        } 1 .. $#path;
        is_deeply \@reused, [], "order $order never runs along the same edge twice";
        is $path[-1][0]**2 + $path[-1][1]**2, 2**$order, "order $order ends 2^($order/2) from the start";
    }
};

subtest 'binomial_is_odd' => sub {
    # Build Pascal's triangle the slow way and compare.
    my @row = (1);
    for my $n (0 .. 40) {
        my @wrong = grep { binomial_is_odd($n, $_) xor $row[$_] % 2 } 0 .. $n;
        is_deeply \@wrong, [], "row $n";
        @row = (1, (map { ($row[ $_ - 1 ] + $row[$_]) % 1024 } 1 .. $n), 1);
    }
};

subtest 'gradient_palette' => sub {
    my @palette = gradient_palette([ [ 0, 255, 0, 0 ], [ 1, 0, 0, 255 ] ]);
    is $palette[0],  52, 'starts at the color the gradient starts on';
    is $palette[-1], 60, 'ends at the color the gradient ends on';
    my %seen;
    is_deeply [ grep { $seen{$_}++ } @palette ], [], 'lists each color once';
};

subtest 'average_rgb' => sub {
    is_deeply average_rgb([ 0, 10, 200 ], [ 100, 30, 0 ]), [ 50, 20, 100 ];
};

subtest 'pieces' => sub {
    for my $name (sort keys %PIECES) {
        my $canvas = $PIECES{$name}{draw}->();
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
    my @origin = zeta_pixel(0, 0);
    for my $t (14.134725141734695, 21.022039638771556, 25.01085758014569) {
        is_deeply [ zeta_pixel(zeta(0.5, $t)) ], \@origin, "the zero at t = $t lands on the origin pixel";
    }

    my $pixels = zeta_pixels();
    is $pixels->[ $origin[0] ][ $origin[1] ], 98, 'the origin is marked in white';
    my ($row, $col) = zeta_pixel(zeta(0.5, 0));
    is $pixels->[$row][$col], nearest_color(gradient_rgb(\@ZETA_HUES, 0)),
        'the curve starts in the first hue';
    ($row, $col) = zeta_pixel(zeta(0.5, $ZETA_T_MAX));
    is $pixels->[$row][$col], nearest_color(gradient_rgb(\@ZETA_HUES, 1)),
        'the curve ends in the last hue';

    my @rows = irc_lines(zeta_canvas());
    like strip_colors($rows[0]), qr/zeta\(s\) = 1 \+ 1\/2\^s/, 'the title sits above the plot';
    is scalar @rows, @$pixels / 2 + 3, 'one title row, the plot, and two footer rows';
};

subtest 'cmd_math with no piece lists the pieces' => sub {
    my $server = FakeServer->new;
    my $item   = FakeItem->new;
    cmd_math('', $server, $item);
    is_deeply $item->{printed}, [ [ 'math: pieces: apollonian arrowhead aztec billiard biomorph brownian buddhabrot burningship butterfly cantor carpet cassini caustic chladni clifford clothoid collatz conformal cycloid dipole dragon drum elephant euler fern fibword ford fourier galaxy gaussian golden gosper harmonograph henon hilbert hofstadter hopf hyperbolic ikeda ising julia kepler klein knot koch langton levy life logistic lorenz lotka lyapunov magnet mandelbrot maurer minibrot mira mobius multibrot newton orbital pappus pascal pendulum penrose percolation phase phoenix piwalk plant pursuit pythagoras quasicrystal rauzy recaman ripples rossler rotor rule30 sandpile seahorse spiral spirograph steiner sunflower terdragon tesseract theodorus thomas threebody timestable tongues tricorn truchet turing ulam voronoi weierstrass zeta', 'CLIENTCRAP' ] ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

# Plays the part of irssi's main loop: keeps handing each background drawing
# its pipe until the drawing says it's done by removing its listener. The
# drawings are real forked processes writing to real pipes.
sub finish_drawings {
    for (1 .. 100_000) {
        last if !%inputs;
        for my $tag (keys %inputs) {
            my $input = $inputs{$tag} or next;
            $input->[0]->($input->[1]);
        }
    }
    fail 'drawings never finished' if %inputs;
    waitpid $_, 0 for splice @waiting_pids;
}

subtest 'cmd_math -l lists the pieces with what each one is' => sub {
    my $server = FakeServer->new;
    my $item   = $server->add_item(name => '#math');
    cmd_math(' -l ', $server, $item);
    is_deeply $item->{printed}, [
        map { [ "math: $_", 'CLIENTCRAP' ] }
            'apollonian    the Apollonian gasket, every gap between circles filled with another circle',
            'arrowhead     Sierpinski\'s arrowhead curve: one line that traces Sierpinski\'s triangle',
            'aztec         the arctic circle: a random domino tiling, frozen at the corners and wild inside',
            'billiard      a billiard ball in an ellipse, its path never crossing a smaller ellipse inside',
            'biomorph      a biomorph: Pickover\'s creature, grown from z^3 + c and a lucky bug',
            'brownian      a Brownian tree: grains wander in at random and stick where they first touch',
            'buddhabrot    the Buddhabrot: the paths of every point that escapes the Mandelbrot set',
            'burningship   the Burning Ship fractal, z^2 + c with the orbit folded',
            'butterfly     Fay\'s butterfly curve, twelve turns of a polar curve',
            'cantor        the devil\'s staircase, climbing only on the Cantor set',
            'carpet        Sierpinski\'s carpet: a square with its middle ninth cut out, over and over',
            'cassini       Cassini ovals: the curves where the distances to two points multiply to the same number',
            'caustic       the bright cusped curve that light draws in the bottom of a coffee cup',
            'chladni       sand on a ringing metal plate, gathered on the lines that stand still',
            'clifford      a Clifford strange attractor, drawn like smoke',
            'clothoid      the Euler spiral, which bends more the further along it you go',
            'collatz       the Collatz coral: every trip down to 1, bending left on even, right on odd',
            'conformal     a square grid under w = sin z, bent but still square at every crossing',
            'cycloid       the fastest way down: beads racing on a line, a sine and a cycloid',
            'dipole        the field lines of a positive and a negative charge',
            'dragon        the Heighway dragon, a strip of paper folded in half eight times',
            'drum          a round drum ringing in two of its modes, with the lines that hold still',
            'elephant      Elephant Valley in the Mandelbrot set, trunks and all',
            'euler         Euler\'s identity: (1 + i pi/n)^n walking round to -1 as n grows',
            'fern          Barnsley\'s fern, grown from four random affine maps',
            'fibword       the Fibonacci word fractal: a turn after every 0 in 0100101001001...',
            'ford          Ford circles: a circle on every fraction, and neighbors always touch',
            'fourier       a square wave built from sine waves, overshooting at every corner',
            'galaxy        a spiral galaxy drawn with ellipses, each turned a little more than the last',
            'gaussian      the Gaussian primes: the primes among the complex numbers a + bi',
            'golden        the golden spiral, drawn through squares whose sides are the Fibonacci numbers',
            'gosper        the flowsnake: Gosper\'s curve, seven copies of itself on a hexagonal grid',
            'harmonograph  two damped pendulums drawing on paper, spiraling in as they tire',
            'henon         the Henon attractor: a map that stretches and folds, leaving layers within layers',
            'hilbert       the Hilbert curve, one line through all 256 squares of a grid',
            'hofstadter    Hofstadter\'s butterfly: the energies of an electron in a magnetic field',
            'hopf          the Hopf fibration: circles on a doughnut, every one linked through every other',
            'hyperbolic    the hyperbolic plane in a disk, tiled by same-size pentagons, four to a corner',
            'ikeda         the Ikeda attractor: light circling a ring cavity, spiraling into chaos',
            'ising         the Ising model: a magnet at the temperature where it\'s about to pick a side',
            'julia         the Julia set called Douady\'s rabbit, ears within ears',
            'kepler        Kepler\'s second law: an orbit cut into months that all sweep the same area',
            'klein         the Klein bottle, a surface with only one side, passing through itself',
            'knot          a torus knot: a line wound round a doughnut, twice one way and five times the other',
            'koch          the Koch snowflake, an infinitely long edge around a finite area',
            'langton       Langton\'s ant: ten thousand steps of mess, then out of nowhere a highway',
            'levy          the Levy C curve: every line replaced by two at right angles, over and over',
            'life          Conway\'s Game of Life: a glider gun firing gliders, with trails',
            'logistic      the logistic map doubling its period over and over until it turns to chaos',
            'lorenz        the Lorenz attractor, the butterfly of chaos',
            'lotka         foxes and rabbits: predators and prey booming and crashing round and round',
            'lyapunov      a Lyapunov fractal: where a logistic map flipping between two rates settles or turns to chaos',
            'magnet        the magnet fractal, from a model of magnetism, where points can escape or settle',
            'mandelbrot    the whole Mandelbrot set, glowing toward its edge',
            'maurer        a Maurer rose: a walk round a rose in steps of 71 degrees',
            'minibrot      a tiny copy of the Mandelbrot set, out on its needle',
            'mira          the Gumowski-Mira map, from a study of particles in an accelerator',
            'mobius        a Mobius strip: a band with a half twist, so it has one side and one edge',
            'multibrot     a Multibrot set: the Mandelbrot set\'s rule with z cubed instead of squared',
            'newton        Newton\'s method on z^3 - 1, three basins with a fractal border',
            'orbital       a slice through a hydrogen atom\'s 4d orbital',
            'pappus        the Pappus chain: circles packed in an arbelos, each one diameter higher than the last',
            'pascal        Pascal\'s triangle mod 2, which turns out to be Sierpinski\'s',
            'pendulum      a double pendulum swinging wildly for thirty seconds',
            'penrose       a Penrose tiling: two rhombs covering the plane without ever repeating',
            'percolation   percolation: squares opened at random, just enough for one cluster to span the grid',
            'phase         a phase portrait: zeros and poles of a complex function as color pinwheels',
            'phoenix       the Phoenix fractal, where each step remembers the one before',
            'piwalk        a walk steered by the first thousand digits of pi',
            'plant         Lindenmayer\'s fractal plant, grown by rewriting a string of turtle moves',
            'pursuit       four bugs at the corners of a square, each chasing the next into a whirl',
            'pythagoras    the Pythagoras tree: squares on the sides of right triangles, branching forever',
            'quasicrystal  seven waves added up into a pattern that never repeats',
            'rauzy         the Rauzy fractal: a walk through the tribonacci word, seen end on',
            'recaman       Recaman\'s sequence: hop back if you can, forward if you can\'t, drawn as arcs',
            'ripples       ripples from two stones meeting, calm wherever they cancel',
            'rossler       the Rossler attractor: chaos from a spiral with a single fold',
            'rotor         rotor-router aggregation: particles steered by turning arrows, growing a perfect disk',
            'rule30        Wolfram\'s rule 30, one cell growing into chaos',
            'sandpile      the Abelian sandpile: grains dropped on one square, toppling in fours',
            'seahorse      a seahorse tail in Seahorse Valley, 600 times closer',
            'spiral        a spiral in the Mandelbrot set, 2000 times closer than the whole set',
            'spirograph    a spirograph: a gear rolling inside a ring, drawing loops',
            'steiner       a Steiner chain: a ring of circles that fits however far you turn it',
            'sunflower     seeds placed by the golden angle, falling into Fibonacci spirals',
            'terdragon     the terdragon: every line replaced by three in a zigzag, over and over',
            'tesseract     a tesseract, the four dimensional cube, turned and seen in perspective',
            'theodorus     the spiral of Theodorus: right triangles with sides sqrt 2, sqrt 3, ... sqrt 17',
            'thomas        Thomas\'s attractor: chaos with three-fold symmetry, seen down its axis',
            'threebody     three bodies chasing each other round a figure eight under gravity',
            'timestable    times tables drawn on a circle, where a cardioid and a nephroid appear',
            'tongues       Arnold tongues: where a kicked circle locks onto a fraction of a turn',
            'tricorn       the Tricorn, the Mandelbrot set\'s rule with z flipped to its conjugate',
            'truchet       Truchet tiles: quarter circles laid at random, joining into endless paths',
            'turing        Turing patterns: two chemicals reacting and spreading into stripes like coral',
            'ulam          the Ulam spiral, where the primes line up on diagonals',
            'voronoi       a sunflower\'s seeds, each given the patch of head nearest it',
            'weierstrass   the Weierstrass function: continuous everywhere, smooth nowhere',
            'zeta          the path of zeta(1/2 + it) through its first three zeros',
    ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

subtest 'cmd_math draws in the background, then sends' => sub {
    %RENDERED = ();
    my $server = FakeServer->new;
    my $item   = $server->add_item(name => '#math');
    cmd_math(' zeta ', $server, $item);
    is_deeply $item->{printed}, [ [ 'math: drawing zeta...', 'CLIENTCRAP' ] ], 'says it is drawing';
    is_deeply $server->{sent}, [], 'nothing goes out before the drawing is done';
    finish_drawings();
    is_deeply $server->{sent}, [ map { "MSG #math $_" } irc_lines(zeta_canvas()) ], 'then the piece goes out';
};

subtest 'a drawn piece is kept and sent straight away next time' => sub {
    my $server = FakeServer->new;
    my $item   = $server->add_item(name => '#math');
    cmd_math('zeta', $server, $item);
    is_deeply $server->{sent}, [ map { "MSG #math $_" } irc_lines(zeta_canvas()) ], 'sent at once';
    is_deeply $item->{printed}, [], 'without drawing it again';
};

subtest 'cmd_math -p previews without sending' => sub {
    %RENDERED = ();
    my $server = FakeServer->new;
    my $item   = $server->add_item(name => '#math');
    cmd_math('-p zeta', $server, $item);
    finish_drawings();
    is_deeply $item->{printed},
        [ [ 'math: drawing zeta...', 'CLIENTCRAP' ], map { [ $_, 'CLIENTCRAP' ] } irc_lines(zeta_canvas()) ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

subtest 'cmd_math -r sends a random piece' => sub {
    # Every piece already drawn, as one line naming it, so we can tell which
    # one went out without drawing them all.
    %RENDERED = map { $_ => ["the $_ piece"] } keys %PIECES;
    @SHUFFLE_BAG = ();
    my $all = join ' ', sort keys %PIECES;
    my @runs;
    for my $option ('-r', '--random', ' -r ') {
        my @picked;
        for (1 .. keys %PIECES) {
            my $server = FakeServer->new;
            my $item   = $server->add_item(name => '#math');
            cmd_math($option, $server, $item);
            my ($name) = ($item->{printed}[0][0] // '') =~ /^math: random piece: (\S+)$/;
            ok $name && $PIECES{$name}, "$option says which piece it picked" or last;
            is_deeply $server->{sent}, ["MSG #math the $name piece"], 'and sends that one' or last;
            push @picked, $name;
        }
        is join(' ', sort @picked), $all, "as many $option in a row as there are pieces send every piece once";
        push @runs, "@picked";
    }
    isnt $runs[0], $runs[1], 'in a new order each time round';

    my $server = FakeServer->new;
    my $item   = $server->add_item(name => '#math');
    cmd_math('-p -r', $server, $item);
    my ($name) = $item->{printed}[0][0] =~ /^math: random piece: (\S+)$/;
    is_deeply $item->{printed}, [ [ "math: random piece: $name", 'CLIENTCRAP' ], [ "the $name piece", 'CLIENTCRAP' ] ],
        '-p -r previews a random piece';
    is_deeply $server->{sent}, [], 'without sending it';
    %RENDERED = ();
};

subtest 'requests made while a piece is drawing share the drawing' => sub {
    %RENDERED = ();
    my $server = FakeServer->new;
    my $one    = $server->add_item(name => '#one');
    my $two    = $server->add_item(name => '#two');
    cmd_math('mandelbrot', $server, $one);
    cmd_math('-p mandelbrot', $server, $two);
    is scalar(keys %inputs), 1, 'only one drawing runs';
    finish_drawings();

    my @lines = irc_lines(mandelbrot_canvas());
    is_deeply $server->{sent}, [ map { "MSG #one $_" } @lines ], 'the first request is sent';
    is_deeply $two->{printed}, [ map { [ $_, 'CLIENTCRAP' ] } @lines ], 'the second is previewed';
};

subtest 'a piece that fails to draw is reported' => sub {
    local $PIECES{broken} = { draw => sub { die "boom\n" } };
    my $server = FakeServer->new;
    my $item   = $server->add_item(name => '#math');
    cmd_math('broken', $server, $item);
    finish_drawings();
    is_deeply $item->{printed},
        [ [ 'math: drawing broken...', 'CLIENTCRAP' ], [ 'math: could not draw broken: boom', 'CLIENTERROR' ] ];
    is_deeply $server->{sent}, [], 'nothing was sent';
    ok !exists $RENDERED{broken}, 'the failure is not kept';
};

subtest 'things that change while a piece is drawing' => sub {
    %RENDERED = ();
    my $server = FakeServer->new;
    $server->add_item(name => '#gone');
    cmd_math('zeta', $server, $server->window_item_find('#gone'));
    $server->remove_item('#gone');
    finish_drawings();
    is_deeply $server->{sent}, [], 'a window closed meanwhile gets nothing';

    %RENDERED = ();
    my $item = $server->add_item(name => '#math');
    cmd_math('zeta', $server, $item);
    $server->{connected} = 0;
    finish_drawings();
    is_deeply $server->{sent}, [], 'a server that disconnected meanwhile gets nothing';
    is_deeply $item->{printed}[-1], [ 'math: not connected to a server', 'CLIENTERROR' ], 'and says why';
};

my @usage = (
    'usage: /math              list the pieces',
    '       /math -l           list the pieces with what each one is',
    '       /math -h           show this help',
    '       /math <piece>      send a piece to this channel or query',
    '       /math -p <piece>   preview a piece here without sending it',
    '       /math -r           send a random piece (--random works too)',
    '       /math -p -r        preview a random piece',
);

subtest 'cmd_math refuses bad input' => sub {
    my $item = FakeItem->new;
    cmd_math('nope', FakeServer->new, $item);
    is_deeply $item->{printed}, [ [ 'math: no piece called "nope". pieces: apollonian arrowhead aztec billiard biomorph brownian buddhabrot burningship butterfly cantor carpet cassini caustic chladni clifford clothoid collatz conformal cycloid dipole dragon drum elephant euler fern fibword ford fourier galaxy gaussian golden gosper harmonograph henon hilbert hofstadter hopf hyperbolic ikeda ising julia kepler klein knot koch langton levy life logistic lorenz lotka lyapunov magnet mandelbrot maurer minibrot mira mobius multibrot newton orbital pappus pascal pendulum penrose percolation phase phoenix piwalk plant pursuit pythagoras quasicrystal rauzy recaman ripples rossler rotor rule30 sandpile seahorse spiral spirograph steiner sunflower terdragon tesseract theodorus thomas threebody timestable tongues tricorn truchet turing ulam voronoi weierstrass zeta', 'CLIENTERROR' ] ],
        'unknown piece';

    @printed = ();
    cmd_math('zeta', FakeServer->new(connected => 0), FakeItem->new);
    is_deeply \@printed, [ [ 'math: not connected to a server', 'CLIENTERROR' ] ],
        'disconnected server';

    @printed = ();
    cmd_math('zeta', FakeServer->new, undef);
    is_deeply \@printed, [ [ 'math: not in a channel or query window', 'CLIENTERROR' ] ],
        'no window item';

    @printed = ();
    cmd_math('-p zeta', FakeServer->new, undef);
    is_deeply \@printed, [ [ 'math: not in a channel or query window', 'CLIENTERROR' ] ],
        'previewing needs a window item too';

    $item = FakeItem->new;
    cmd_math('-x', FakeServer->new, $item);
    is_deeply $item->{printed}, [ [ 'math: unknown option "-x"', 'CLIENTERROR' ], map { [ "math: $_", 'CLIENTCRAP' ] } @usage ],
        'an unknown option shows the usage';
};

subtest 'cmd_math -h shows the usage' => sub {
    my $item = FakeItem->new;
    cmd_math(' -h ', FakeServer->new, $item);
    is_deeply $item->{printed}, [ map { [ "math: $_", 'CLIENTCRAP' ] } @usage ];
};

subtest 'listing and help work outside a channel, in the status window' => sub {
    @printed = ();
    cmd_math('', undef, undef);
    is_deeply \@printed, [ [ 'math: pieces: ' . piece_list(), 'CLIENTCRAP' ] ], 'the piece list';

    @printed = ();
    cmd_math('-l', undef, undef);
    is scalar @printed, scalar keys %PIECES, 'the descriptions, one line a piece';
    like $printed[0][0], qr/^math: apollonian +the Apollonian gasket/, 'in order';

    @printed = ();
    cmd_math('-h', undef, undef);
    is_deeply \@printed, [ map { [ "math: $_", 'CLIENTCRAP' ] } @usage ], 'the usage';
};

done_testing;
