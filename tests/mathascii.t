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

our ($ZETA_T_MAX, @ZETA_HUES, %PIECES, @QUADRANT, %RENDERED, $GOLDEN_ANGLE, $GOSPER_GUN, $SANDPILE_GRAINS, $SANDPILE_SIZE);
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
    is_deeply [ @{ $ant->{painted} }{qw(1,0 1,1 0,0)} ], [ 2, 3, 5 ], 'it remembers the step that last flipped each square';

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
    is_deeply $item->{printed}, [ [ 'math: pieces: apollonian buddhabrot burningship chladni clifford collatz dragon fern ford harmonograph hilbert julia koch langton life logistic lorenz lyapunov mandelbrot newton pascal phase piwalk rule30 sandpile seahorse spirograph sunflower timestable ulam zeta', 'CLIENTCRAP' ] ];
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
            'buddhabrot    the Buddhabrot: the paths of every point that escapes the Mandelbrot set',
            'burningship   the Burning Ship fractal, z^2 + c with the orbit folded',
            'chladni       sand on a ringing metal plate, gathered on the lines that stand still',
            'clifford      a Clifford strange attractor, drawn like smoke',
            'collatz       the Collatz coral: every trip down to 1, bending left on even, right on odd',
            'dragon        the Heighway dragon, a strip of paper folded in half eight times',
            'fern          Barnsley\'s fern, grown from four random affine maps',
            'ford          Ford circles: a circle on every fraction, and neighbors always touch',
            'harmonograph  two damped pendulums drawing on paper, spiraling in as they tire',
            'hilbert       the Hilbert curve, one line through all 256 squares of a grid',
            'julia         the Julia set called Douady\'s rabbit, ears within ears',
            'koch          the Koch snowflake, an infinitely long edge around a finite area',
            'langton       Langton\'s ant: ten thousand steps of mess, then out of nowhere a highway',
            'life          Conway\'s Game of Life: a glider gun firing gliders, with trails',
            'logistic      the logistic map doubling its period over and over until it turns to chaos',
            'lorenz        the Lorenz attractor, the butterfly of chaos',
            'lyapunov      a Lyapunov fractal: where a logistic map flipping between two rates settles or turns to chaos',
            'mandelbrot    the whole Mandelbrot set, glowing toward its edge',
            'newton        Newton\'s method on z^3 - 1, three basins with a fractal border',
            'pascal        Pascal\'s triangle mod 2, which turns out to be Sierpinski\'s',
            'phase         a phase portrait: zeros and poles of a complex function as color pinwheels',
            'piwalk        a walk steered by the first thousand digits of pi',
            'rule30        Wolfram\'s rule 30, one cell growing into chaos',
            'sandpile      the Abelian sandpile: grains dropped on one square, toppling in fours',
            'seahorse      a seahorse tail in Seahorse Valley, 600 times closer',
            'spirograph    a spirograph: a gear rolling inside a ring, drawing loops',
            'sunflower     seeds placed by the golden angle, falling into Fibonacci spirals',
            'timestable    times tables drawn on a circle, where a cardioid and a nephroid appear',
            'ulam          the Ulam spiral, where the primes line up on diagonals',
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
);

subtest 'cmd_math refuses bad input' => sub {
    my $item = FakeItem->new;
    cmd_math('nope', FakeServer->new, $item);
    is_deeply $item->{printed}, [ [ 'math: no piece called "nope". pieces: apollonian buddhabrot burningship chladni clifford collatz dragon fern ford harmonograph hilbert julia koch langton life logistic lorenz lyapunov mandelbrot newton pascal phase piwalk rule30 sandpile seahorse spirograph sunflower timestable ulam zeta', 'CLIENTERROR' ] ],
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
