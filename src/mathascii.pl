use strict;
use warnings;

use Irssi;
use List::Util ();

our $VERSION = '1.00';
our %IRSSI = (
    authors     => 'l0j1k',
    name        => 'mathascii',
    description => 'Plays color ASCII art of beautiful math, drawn from the real math.',
    license     => 'MIT',
);

# Usage: /math              lists the pieces
#        /math <piece>      sends the piece to the current channel or query
#        /math -p <piece>   previews the piece in your window without sending
#
# Each line goes out as its own PRIVMSG. irssi paces them with its own flood
# queue (the cmd_queue_speed and cmds_max_at_once settings), so a 25 line piece
# takes a while with the defaults.
#
# Colors use the extended 16-98 palette because those have fixed RGB values on
# every client. See docs/irc-colors.md.

my $BLACK = 88;

# A canvas is a list of rows, each a list of [char, fg, bg] cells.
sub blank_canvas {
    my ($width, $height) = @_;
    return [ map { [ map { [ ' ', $BLACK, $BLACK ] } 1 .. $width ] } 1 .. $height ];
}

sub put_text {
    my ($canvas, $row, $col, $text, $fg) = @_;
    for my $i (0 .. length($text) - 1) {
        my $cell = $canvas->[$row][ $col + $i ];
        @$cell[ 0, 1 ] = (substr($text, $i, 1), $fg);
    }
}

# RGB of the fixed extended colors, from docs/irc-colors.md.
our %RGB = (
    16 => '470000', 17 => '472100', 18 => '474700', 19 => '324700', 20 => '004700', 21 => '00472c',
    22 => '004747', 23 => '002747', 24 => '000047', 25 => '2e0047', 26 => '470047', 27 => '47002a',
    28 => '740000', 29 => '743a00', 30 => '747400', 31 => '517400', 32 => '007400', 33 => '007449',
    34 => '007474', 35 => '004074', 36 => '000074', 37 => '4b0074', 38 => '740074', 39 => '740045',
    40 => 'b50000', 41 => 'b56300', 42 => 'b5b500', 43 => '7db500', 44 => '00b500', 45 => '00b571',
    46 => '00b5b5', 47 => '0063b5', 48 => '0000b5', 49 => '7500b5', 50 => 'b500b5', 51 => 'b5006b',
    52 => 'ff0000', 53 => 'ff8c00', 54 => 'ffff00', 55 => 'b2ff00', 56 => '00ff00', 57 => '00ffa0',
    58 => '00ffff', 59 => '008cff', 60 => '0000ff', 61 => 'a500ff', 62 => 'ff00ff', 63 => 'ff0098',
    64 => 'ff5959', 65 => 'ffb459', 66 => 'ffff71', 67 => 'cfff60', 68 => '6fff6f', 69 => '65ffc9',
    70 => '6dffff', 71 => '59b4ff', 72 => '5959ff', 73 => 'c459ff', 74 => 'ff66ff', 75 => 'ff59bc',
    76 => 'ff9c9c', 77 => 'ffd39c', 78 => 'ffff9c', 79 => 'e2ff9c', 80 => '9cff9c', 81 => '9cffdb',
    82 => '9cffff', 83 => '9cd3ff', 84 => '9c9cff', 85 => 'dc9cff', 86 => 'ff9cff', 87 => 'ff94d3',
    88 => '000000', 89 => '131313', 90 => '282828', 91 => '363636', 92 => '4d4d4d', 93 => '656565',
    94 => '818181', 95 => '9f9f9f', 96 => 'bcbcbc', 97 => 'e2e2e2', 98 => 'ffffff',
);

sub rgb { return map { hex } unpack '(A2)3', $RGB{ $_[0] } }

sub color_distance {
    my @a = rgb($_[0]);
    my @b = rgb($_[1]);
    return ($a[0] - $b[0])**2 + ($a[1] - $b[1])**2 + ($a[2] - $b[2])**2;
}

# The quadrant block characters, indexed by which quarters are drawn in the
# foreground color: 1 is top left, 2 top right, 4 bottom left, 8 bottom right.
# Each text cell is then a 2x2 grid of pixels, with the catch that a cell can
# only show two colors.
our @QUADRANT = (
    ' ',        "\x{2598}", "\x{259D}", "\x{2580}", "\x{2596}", "\x{258C}", "\x{259E}", "\x{259B}",
    "\x{2597}", "\x{259A}", "\x{2590}", "\x{259C}", "\x{2584}", "\x{2599}", "\x{259F}", "\x{2588}",
);
my %QUADRANT_BITS = map { $QUADRANT[$_] => $_ } 0 .. 15;

# Fits four pixel colors (top left, top right, bottom left, bottom right) into
# one cell. With more than two colors we try every pair of them and keep the
# pair that leaves the smallest total color error once each pixel takes the
# nearer of the two.
sub quadrant_cell {
    my @pixels = @_;
    my %seen;
    my @colors = grep { !$seen{$_}++ } @pixels;
    return [ ' ', $colors[0], $colors[0] ] if @colors == 1;

    my ($best_error, $best_fg, $best_bg);
    for my $i (0 .. $#colors - 1) {
        for my $j ($i + 1 .. $#colors) {
            my ($fg, $bg) = @colors[ $i, $j ];
            my $error = 0;
            $error += List::Util::min(color_distance($_, $fg), color_distance($_, $bg)) for @pixels;
            ($best_error, $best_fg, $best_bg) = ($error, $fg, $bg) if !defined $best_error || $error < $best_error;
        }
    }
    my $bits = 0;
    for my $i (0 .. 3) {
        $bits |= 1 << $i if color_distance($pixels[$i], $best_fg) <= color_distance($pixels[$i], $best_bg);
    }
    return [ $QUADRANT[$bits], $best_fg, $best_bg ];
}

# Turns a grid of pixel colors, two pixel rows per text row and two pixel
# columns per text column, into a canvas.
sub pixels_to_canvas {
    my ($pixels) = @_;
    my @canvas;
    for (my $r = 0; $r < @$pixels; $r += 2) {
        my ($top, $bottom) = @$pixels[ $r, $r + 1 ];
        push @canvas, [ map { quadrant_cell(@$top[ 2 * $_, 2 * $_ + 1 ], @$bottom[ 2 * $_, 2 * $_ + 1 ]) } 0 .. @$top / 2 - 1 ];
    }
    return \@canvas;
}

# Turns a canvas into IRC lines with as few color bytes as we can manage, since
# block art changes color almost every cell and a line has to fit in one
# message. The tricks:
#
#   - Only write a code when the colors that cell shows actually change. A
#     space only shows its background and a full block only its foreground.
#   - When only the foreground changes, write just that (3 bytes, not 6),
#     unless the cell is a comma, which would be read as a background.
#   - A quadrant block looks the same as its complement with the colors
#     swapped, so use whichever needs the shorter code.
#
# Codes always use two digits so a digit in the art isn't read as part of one.
sub cell_code {
    my ($char, $fg, $bg, $current_fg, $current_bg) = @_;
    my $bits = $QUADRANT_BITS{$char} // -1;
    my $fg_ok = $bits == 0  || (defined $current_fg && $current_fg == $fg);
    my $bg_ok = $bits == 15 || (defined $current_bg && $current_bg == $bg);
    return ('', $current_fg, $current_bg) if $fg_ok && $bg_ok;
    return (sprintf("\x03%02d", $fg), $fg, $current_bg) if $bg_ok && defined $current_bg && $char ne ',';

    # A cell that ignores one of its colors keeps whatever is current there.
    my $new_fg = $bits == 0  ? $current_fg // $fg : $fg;
    my $new_bg = $bits == 15 ? $current_bg // $bg : $bg;
    return (sprintf("\x03%02d,%02d", $new_fg, $new_bg), $new_fg, $new_bg);
}

sub irc_lines {
    my ($canvas) = @_;
    my @lines;
    for my $row (@$canvas) {
        my ($line, $current_fg, $current_bg) = ('');
        for my $cell (@$row) {
            my ($char, $fg, $bg) = @$cell;
            my @choices = ([ $char, cell_code($char, $fg, $bg, $current_fg, $current_bg) ]);
            if (defined(my $bits = $QUADRANT_BITS{$char})) {
                my $flipped = $QUADRANT[ 15 - $bits ];
                push @choices, [ $flipped, cell_code($flipped, $bg, $fg, $current_fg, $current_bg) ];
            }
            my ($best) = sort { length $a->[1] <=> length $b->[1] } @choices;
            (my $shown, my $code, $current_fg, $current_bg) = @$best;
            $line .= $code . $shown;
        }
        push @lines, $line;
    }
    return @lines;
}

# Picks the line character that best matches a direction of travel. dy is
# measured upward, in the same units as dx.
sub direction_char {
    my ($dx, $dy) = @_;
    my $pi    = 4 * atan2(1, 1);
    my $angle = atan2($dy, $dx) * 180 / $pi;
    $angle += 180 if $angle < 0;
    return '-'  if $angle < 22.5 || $angle >= 157.5;
    return '/'  if $angle < 67.5;
    return '|'  if $angle < 112.5;
    return '\\';
}

# The Riemann zeta function, by Euler-Maclaurin summation. We add up the first
# N-1 terms of the series directly and estimate the rest of it with an integral
# plus Bernoulli number corrections. With N = 20 and six corrections it is good
# to better than 1e-9 for |s| up to about 40, which covers everything we draw.
#
# Complex numbers are [re, im] pairs. Math::Complex reads better but its
# operator overloading made a render take seconds, which freezes irssi.
my @BERNOULLI = (1 / 6, -1 / 30, 1 / 42, -1 / 30, 5 / 66, -691 / 2730);    # B2, B4, ... B12

sub c_mul { my ($a, $b) = @_; return [ $a->[0] * $b->[0] - $a->[1] * $b->[1], $a->[0] * $b->[1] + $a->[1] * $b->[0] ] }

sub c_div {
    my ($a, $b) = @_;
    my $d = $b->[0]**2 + $b->[1]**2;
    return [ ($a->[0] * $b->[0] + $a->[1] * $b->[1]) / $d, ($a->[1] * $b->[0] - $a->[0] * $b->[1]) / $d ];
}

# n^-s for a positive integer n, which is n^-re * (cos(im ln n) - i sin(im ln n)).
sub n_to_minus_s {
    my ($n, $s) = @_;
    my $size = $n**-$s->[0];
    my $turn = $s->[1] * log $n;
    return [ $size * cos $turn, -$size * sin $turn ];
}

sub zeta {
    my ($re, $im) = @_;
    my $s = [ $re, $im ];
    my $N = 20;

    my @sum = (0, 0);
    for my $n (1 .. $N - 1) {
        my $term = n_to_minus_s($n, $s);
        $sum[0] += $term->[0];
        $sum[1] += $term->[1];
    }

    # The integral of the rest of the series, N^(1-s) / (s-1), plus half its
    # first term.
    my $N_to_minus_s = n_to_minus_s($N, $s);
    my $integral     = c_div([ $N * $N_to_minus_s->[0], $N * $N_to_minus_s->[1] ], [ $re - 1, $im ]);
    $sum[$_] += $integral->[$_] + $N_to_minus_s->[$_] / 2 for 0, 1;

    # Each correction is B(2k) / (2k)! * s(s+1)...(s+2k-2) * N^(-s-2k+1).
    my $rising    = $s;
    my $factorial = 2;
    my $N_power   = [ $N_to_minus_s->[0] / $N, $N_to_minus_s->[1] / $N ];
    for my $k (1 .. @BERNOULLI) {
        my $term  = c_mul($rising, $N_power);
        my $scale = $BERNOULLI[ $k - 1 ] / $factorial;
        $sum[$_] += $scale * $term->[$_] for 0, 1;
        $rising = c_mul(c_mul($rising, [ $re + 2 * $k - 1, $im ]), [ $re + 2 * $k, $im ]);
        $factorial *= (2 * $k + 1) * (2 * $k + 2);
        $N_power = [ map { $_ / ($N * $N) } @$N_power ];
    }
    return @sum;
}

# The zeta piece traces zeta(1/2 + it) in the complex plane as t runs from 0
# to $ZETA_T_MAX. The curve passes through the origin at every zero on the
# critical line. Color shows how far along t is.
our $ZETA_T_MAX   = 26;
our @ZETA_GRADIENT = (60, 59, 58, 57, 56, 55, 54, 53, 52, 63, 62);

my $WIDTH        = 70;
my $PLOT_TOP     = 1;    # the title takes row 0
my $PLOT_HEIGHT  = 19;
my ($X_MIN, $X_MAX, $Y_MIN, $Y_MAX) = (-1.7, 2.6, -1.35, 1.4);
my $SAMPLES      = 4000;

# Character cells are about twice as tall as they are wide.
my $CELL_ASPECT = 2;

# Where a point of the complex plane falls on the plot, as fractional
# (row, col) on the canvas.
sub plot_position {
    my ($x, $y) = @_;
    return (
        $PLOT_TOP + ($Y_MAX - $y) / ($Y_MAX - $Y_MIN) * ($PLOT_HEIGHT - 1),
        ($x - $X_MIN) / ($X_MAX - $X_MIN) * ($WIDTH - 1),
    );
}

sub plot_cell {
    my ($row, $col) = plot_position(@_);
    return (int($row + 0.5), int($col + 0.5));
}

sub zeta_canvas {
    my $canvas = blank_canvas($WIDTH, $PLOT_TOP + $PLOT_HEIGHT + 2);
    put_text($canvas, 0, 2, 'zeta(s) = 1 + 1/2^s + 1/3^s + ...  =  PROD over primes 1/(1 - p^-s)', 97);

    my ($origin_row, $origin_col) = plot_cell(0, 0);
    put_text($canvas, $origin_row, 0, '.' x $WIDTH, 92);
    put_text($canvas, $_, $origin_col, ':', 92) for $PLOT_TOP .. $PLOT_TOP + $PLOT_HEIGHT - 1;

    my @points = map {
        my $t = $ZETA_T_MAX * $_ / $SAMPLES;
        [ $t, plot_position(zeta(0.5, $t)) ];
    } 0 .. $SAMPLES;

    # Each cell takes its character and color from the sample that passes
    # closest to its center, which keeps the line one character thick.
    my %closest;
    for my $i (0 .. $#points) {
        my ($t, $row, $col) = @{ $points[$i] };
        my ($r, $c) = (int($row + 0.5), int($col + 0.5));
        next if $r < $PLOT_TOP || $r >= $PLOT_TOP + $PLOT_HEIGHT || $c < 0 || $c >= $WIDTH;
        my $distance = sqrt(($col - $c)**2 + (($row - $r) * $CELL_ASPECT)**2);
        my $best = $closest{"$r,$c"};
        $closest{"$r,$c"} = [ $distance, $i ] if !$best || $distance < $best->[0];
    }
    for my $key (keys %closest) {
        my ($r, $c) = split /,/, $key;
        my $i      = $closest{$key}[1];
        my $before = $points[ $i == 0 ? 0 : $i - 1 ];
        my $after  = $points[ $i == $#points ? $i : $i + 1 ];
        my $char   = direction_char($after->[2] - $before->[2], ($before->[1] - $after->[1]) * $CELL_ASPECT);
        my $color  = $ZETA_GRADIENT[ int($points[$i][0] / $ZETA_T_MAX * $#ZETA_GRADIENT + 0.5) ];
        put_text($canvas, $r, $c, $char, $color);
    }
    put_text($canvas, $origin_row, $origin_col, '@', 98);

    my $footer = $PLOT_TOP + $PLOT_HEIGHT;
    put_text($canvas, $footer, 2, "the path of zeta(1/2 + it) for 0 < t < $ZETA_T_MAX. it hits @ at t = 14.13,", 95);
    put_text($canvas, $footer + 1, 2, '21.02, 25.01 ... do all the nontrivial zeros live on this line?', 95);
    return $canvas;
}

# How long z -> z^2 + c, starting from z = 0, takes to run away, or undef if it
# never does within $max_steps. The count is smoothed (the standard
# n + 1 - log2(log|z|) trick with a big escape radius) so colors blend instead
# of falling into bands.
sub mandelbrot_escape {
    my ($cx, $cy, $max_steps) = @_;

    # Points in the main cardioid and the big bulb to its left never escape,
    # and they're the slowest to check by iterating, so catch them up front.
    my $q = ($cx - 0.25)**2 + $cy**2;
    return undef if $q * ($q + $cx - 0.25) <= $cy**2 / 4;
    return undef if ($cx + 1)**2 + $cy**2 <= 1 / 16;

    my ($x, $y) = (0, 0);
    for my $step (1 .. $max_steps) {
        ($x, $y) = ($x * $x - $y * $y + $cx, 2 * $x * $y + $cy);
        my $size = $x * $x + $y * $y;
        return $step + 1 - log(log($size) / 2) / log(2) if $size > 65536;
    }
    return undef;
}

# The palette color closest to an RGB color.
my %nearest_cache;

sub nearest_color {
    my @want = map { int($_ + 0.5) } @_;
    my $key  = join ',', @want;
    return $nearest_cache{$key} if exists $nearest_cache{$key};

    my ($best, $best_distance);
    for my $code (sort { $a <=> $b } keys %RGB) {
        my @have = rgb($code);
        my $distance = ($have[0] - $want[0])**2 + ($have[1] - $want[1])**2 + ($have[2] - $want[2])**2;
        ($best, $best_distance) = ($code, $distance) if !defined $best || $distance < $best_distance;
    }
    return $nearest_cache{$key} = $best;
}

# The RGB color at a position along a gradient. Stops are
# [position, r, g, b] in increasing position, and positions outside them get
# the end colors.
sub gradient_rgb {
    my ($stops, $position) = @_;
    return @{ $stops->[0] }[ 1 .. 3 ] if $position <= $stops->[0][0];
    for my $i (1 .. $#$stops) {
        my ($from, $to) = @$stops[ $i - 1, $i ];
        next if $position > $to->[0];
        my $f = ($position - $from->[0]) / ($to->[0] - $from->[0]);
        return map { $from->[$_] + $f * ($to->[$_] - $from->[$_]) } 1 .. 3;
    }
    return @{ $stops->[-1] }[ 1 .. 3 ];
}

# Far from the set it's nearly black, then it brightens through navy, blue and
# ice toward the boundary, which glows gold.
my @MANDELBROT_GLOW = (
    [ 0,    0,   0,   12 ],
    [ 0.3,  0,   10,  110 ],
    [ 0.55, 30,  110, 210 ],
    [ 0.75, 150, 220, 255 ],
    [ 0.88, 240, 255, 255 ],
    [ 1,    255, 170, 0 ],
);

# The escape time that reaches the brightest end of the glow.
my $MANDELBROT_GLOW_STEPS = 60;

our $MANDELBROT_COLS = 70;
our $MANDELBROT_ROWS = 24;

sub mandelbrot_canvas {
    my ($center_x, $center_y, $half_height) = (-0.75, 0, 1.15);
    my $pixel_rows = 2 * $MANDELBROT_ROWS;
    my $pixel_cols = 2 * $MANDELBROT_COLS;
    my $step_y     = 2 * $half_height / $pixel_rows;

    # A quadrant pixel is half a cell wide and half a cell tall, and cells are
    # twice as tall as wide, so pixels are twice as tall as wide too.
    my $step_x = $step_y / 2;

    # Each pixel takes a 2x2 grid of samples. It's black when most of them
    # stay bounded, and otherwise colored by their average escape time, which
    # smooths the color without muddying the boundary toward gray. Escape time
    # goes through log so the glow brightens at a steady pace from the far
    # field in to the boundary.
    my $max_steps = 300;
    my @pixels;
    for my $r (0 .. $pixel_rows - 1) {
        push @pixels, [ map {
            my $c = $_;
            my @escapes = grep { defined } map {
                my ($dx, $dy) = @$_;
                mandelbrot_escape(
                    $center_x + ($c + $dx - $pixel_cols / 2) * $step_x,
                    $center_y + $half_height - ($r + $dy) * $step_y,
                    $max_steps,
                );
            } [ 0.25, 0.25 ], [ 0.75, 0.25 ], [ 0.25, 0.75 ], [ 0.75, 0.75 ];
            my $mean = @escapes ? List::Util::sum(@escapes) / @escapes : 0;
            @escapes >= 2
                ? nearest_color(gradient_rgb(\@MANDELBROT_GLOW, log($mean) / log($MANDELBROT_GLOW_STEPS)))
                : $BLACK;
        } 0 .. $pixel_cols - 1 ];
    }
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, $MANDELBROT_ROWS / 2, 39, 'z -> z^2 + c', 98);
    return $canvas;
}

our %PIECES = (mandelbrot => \&mandelbrot_canvas, zeta => \&zeta_canvas);

sub piece_list { return join ' ', sort keys %PIECES }

sub cmd_math {
    my ($data, $server, $witem) = @_;

    if (!$witem) {
        Irssi::print('math: not in a channel or query window', MSGLEVEL_CLIENTERROR);
        return;
    }

    my $name = $data;
    $name =~ s/^\s+|\s+$//g;
    my $preview = $name =~ s/^-p\s+//;

    if ($name eq '') {
        $witem->print('math: pieces: ' . piece_list(), MSGLEVEL_CLIENTCRAP);
        return;
    }
    my $canvas_for = $PIECES{$name};
    if (!$canvas_for) {
        $witem->print(qq{math: no piece called "$name". pieces: } . piece_list(), MSGLEVEL_CLIENTERROR);
        return;
    }
    my @lines = irc_lines($canvas_for->());

    if ($preview) {
        $witem->print($_, MSGLEVEL_CLIENTCRAP) for @lines;
        return;
    }
    if (!$server || !$server->{connected}) {
        Irssi::print('math: not connected to a server', MSGLEVEL_CLIENTERROR);
        return;
    }
    $server->command("MSG $witem->{name} $_") for @lines;
}

Irssi::command_bind('math', 'cmd_math');
