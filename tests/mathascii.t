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

our ($ZETA_T_MAX, @ZETA_HUES, %PIECES, @QUADRANT, %RENDERED);
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
    is_deeply $item->{printed}, [ [ 'math: pieces: burningship julia lorenz mandelbrot newton pascal seahorse ulam zeta', 'CLIENTCRAP' ] ];
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
            'burningship  the Burning Ship fractal, z^2 + c with the orbit folded',
            'julia        the Julia set called Douady\'s rabbit, ears within ears',
            'lorenz       the Lorenz attractor, the butterfly of chaos',
            'mandelbrot   the whole Mandelbrot set, glowing toward its edge',
            'newton       Newton\'s method on z^3 - 1, three basins with a fractal border',
            'pascal       Pascal\'s triangle mod 2, which turns out to be Sierpinski\'s',
            'seahorse     a seahorse tail in Seahorse Valley, 600 times closer',
            'ulam         the Ulam spiral, where the primes line up on diagonals',
            'zeta         the path of zeta(1/2 + it) through its first three zeros',
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

subtest 'cmd_math refuses bad input' => sub {
    my $item = FakeItem->new;
    cmd_math('nope', FakeServer->new, $item);
    is_deeply $item->{printed}, [ [ 'math: no piece called "nope". pieces: burningship julia lorenz mandelbrot newton pascal seahorse ulam zeta', 'CLIENTERROR' ] ],
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
