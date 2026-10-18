use strict;
use warnings;

use Encode ();
use Irssi;
use List::Util ();
use POSIX ();

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
# The first time a piece is asked for it's drawn in the background, which can
# take a few seconds; after that it's sent straight away.
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

# The palette color closest to an RGB color.
sub nearest_color { return nearest_color_in([ sort { $a <=> $b } keys %RGB ], @_) }

# The color closest to an RGB color out of a chosen few.
my %nearest_cache;

sub nearest_color_in {
    my ($codes, @rgb) = @_;
    my @want = map { int($_ + 0.5) } @rgb;
    my $key  = join ',', @want, @$codes;
    return $nearest_cache{$key} if exists $nearest_cache{$key};

    my ($best, $best_distance);
    for my $code (@$codes) {
        my @have = rgb($code);
        my $distance = ($have[0] - $want[0])**2 + ($have[1] - $want[1])**2 + ($have[2] - $want[2])**2;
        ($best, $best_distance) = ($code, $distance) if !defined $best || $distance < $best_distance;
    }
    return $nearest_cache{$key} = $best;
}

# The palette colors a gradient passes closest to, from start to end. Snapping
# to only these keeps blended colors from landing on some unrelated hue that
# happens to be nearby, which looks like noise and costs a color code.
sub gradient_palette {
    my ($stops) = @_;
    my %seen;
    return grep { !$seen{$_}++ } map { nearest_color(gradient_rgb($stops, $_ / 100)) } 0 .. 100;
}

sub average_rgb {
    my @colors = @_;
    return [ map { my $i = $_; List::Util::sum(map { $_->[$i] } @colors) / @colors } 0 .. 2 ];
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

# A pixel's color near a glowing line: the full hue within $GLOW_CORE of the
# line, then fading into the background color until $GLOW_REACH. Distances are
# in pixel widths.
my $GLOW_CORE  = 1;
my $GLOW_REACH = 4;

sub glow_rgb {
    my ($base, $hue, $distance) = @_;
    return @$base if $distance >= $GLOW_REACH;
    my $strength = $distance <= $GLOW_CORE ? 1 : exp(-0.8 * ($distance - $GLOW_CORE));
    return map { $base->[$_] + $strength * ($hue->[$_] - $base->[$_]) } 0 .. 2;
}

# The zeta piece traces zeta(1/2 + it) in the complex plane as t runs from 0
# to $ZETA_T_MAX, as a glowing line whose hue runs from violet to pink with t.
# The curve passes through the origin at every zero on the critical line.
our $ZETA_T_MAX = 26;
our @ZETA_HUES  = (
    [ 0,    140, 70,  255 ],
    [ 0.2,  0,   140, 255 ],
    [ 0.4,  0,   255, 210 ],
    [ 0.55, 140, 255, 0 ],
    [ 0.7,  255, 230, 0 ],
    [ 0.85, 255, 120, 0 ],
    [ 1,    255, 0,   150 ],
);
my @ZETA_BACKGROUND = (0,  0,  14);
my @ZETA_AXIS       = (54, 54, 54);
my $ZETA_SAMPLES    = 6000;

my $ZETA_COLS       = 70;
my $ZETA_PIXEL_ROWS = 46;
my $ZETA_X_MIN      = -1.7;

# How wide a pixel is in the complex plane. Pixels are twice as tall as they
# are wide. The top edge is set so that y = 0 runs through the middle of a
# pixel row, which keeps the zeros from wobbling between two rows.
my $ZETA_STEP  = 4.3 / (2 * $ZETA_COLS);
my $ZETA_Y_MAX = ($ZETA_PIXEL_ROWS + 1) * $ZETA_STEP;

# Where a point of the complex plane falls, as fractional (row, col) pixels.
sub zeta_pixel_position {
    my ($x, $y) = @_;
    return (($ZETA_Y_MAX - $y) / (2 * $ZETA_STEP) - 0.5, ($x - $ZETA_X_MIN) / $ZETA_STEP - 0.5);
}

sub zeta_pixel {
    my ($row, $col) = zeta_pixel_position(@_);
    return (POSIX::floor($row + 0.5), POSIX::floor($col + 0.5));
}

sub zeta_pixels {
    my ($origin_row, $origin_col) = zeta_pixel(0, 0);
    my $pixel_cols = 2 * $ZETA_COLS;
    my @rgb = map {
        my $r = $_;
        [ map { [ $r == $origin_row || $_ == $origin_col ? @ZETA_AXIS : @ZETA_BACKGROUND ] } 0 .. $pixel_cols - 1 ];
    } 0 .. $ZETA_PIXEL_ROWS - 1;

    # For every pixel near the curve, find how close the curve comes and at
    # which t. Where the curve crosses itself, the nearer strand wins.
    my (%distance, %t_at);
    for my $i (0 .. $ZETA_SAMPLES) {
        my $t = $ZETA_T_MAX * $i / $ZETA_SAMPLES;
        my ($row, $col) = zeta_pixel_position(zeta(0.5, $t));
        for my $r (POSIX::ceil($row - $GLOW_REACH / 2) .. POSIX::floor($row + $GLOW_REACH / 2)) {
            next if $r < 0 || $r >= $ZETA_PIXEL_ROWS;
            for my $c (POSIX::ceil($col - $GLOW_REACH) .. POSIX::floor($col + $GLOW_REACH)) {
                next if $c < 0 || $c >= $pixel_cols;
                my $d = sqrt(($c - $col)**2 + (2 * ($r - $row))**2);
                next if exists $distance{"$r,$c"} && $distance{"$r,$c"} <= $d;
                $distance{"$r,$c"} = $d;
                $t_at{"$r,$c"}     = $t;
            }
        }
    }
    for my $key (keys %distance) {
        my ($r, $c) = split /,/, $key;
        my @hue = gradient_rgb(\@ZETA_HUES, $t_at{$key} / $ZETA_T_MAX);
        $rgb[$r][$c] = [ glow_rgb($rgb[$r][$c], \@hue, $distance{$key}) ];
    }

    my @pixels = map { [ map { nearest_color(@$_) } @$_ ] } @rgb;
    # Three pixels across makes a dot about as wide as it is tall.
    $pixels[$origin_row][ $origin_col + $_ ] = 98 for -1 .. 1;
    return \@pixels;
}

sub zeta_canvas {
    my $title = blank_canvas($ZETA_COLS, 1);
    put_text($title, 0, 2, 'zeta(s) = 1 + 1/2^s + 1/3^s + ...  =  PROD over primes 1/(1 - p^-s)', 97);
    my $footer = blank_canvas($ZETA_COLS, 2);
    put_text($footer, 0, 2, "the path of zeta(1/2 + it) as t runs from 0 (violet) to $ZETA_T_MAX (pink).", 95);
    put_text($footer, 1, 2, 'it hits the white dot at t = 14.13, 21.02, 25.01: all zeros on 1/2?', 95);
    return [ @$title, @{ pixels_to_canvas(zeta_pixels()) }, @$footer ];
}

# Follows z -> z^2 + c from z = 0. If z runs away within $max_steps, returns
# how long it took; otherwise returns nothing. The step count is smoothed (the
# standard n + 1 - log2(log|z|) trick with a big escape radius) so colors blend
# instead of falling into bands.
sub mandelbrot_escape {
    my ($cx, $cy, $max_steps) = @_;

    # Points in the main cardioid and the big bulb to its left never escape,
    # and they're the slowest to check by iterating, so catch them up front.
    my $q = ($cx - 0.25)**2 + $cy**2;
    return if $q * ($q + $cx - 0.25) <= $cy**2 / 4;
    return if ($cx + 1)**2 + $cy**2 <= 1 / 16;

    # Other bounded points settle into a cycle. We remember z at steps 1, 2,
    # 4, 8, ... and if z ever comes back to the remembered value, it's caught
    # in a loop and will never escape. Without this, every such point burns
    # all $max_steps.
    my ($x, $y) = (0, 0);
    my ($seen_x, $seen_y, $next_check) = (0, 0, 1);
    for my $step (1 .. $max_steps) {
        ($x, $y) = ($x * $x - $y * $y + $cx, 2 * $x * $y + $cy);
        my $size = $x * $x + $y * $y;
        return $step + 1 - log(log($size) / 2) / log(2) if $size > 65536;
        return if abs($x - $seen_x) < 1e-13 && abs($y - $seen_y) < 1e-13;
        if ($step == $next_check) {
            ($seen_x, $seen_y) = ($x, $y);
            $next_check *= 2;
        }
    }
    return;
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

my $MANDELBROT_COLS = 70;
my $MANDELBROT_ROWS = 24;

# Draws a window onto the Mandelbrot set as a canvas. The view is given by its
# center, half its height in the complex plane, and how many steps to iterate
# before calling a point bounded. Escape times from glow_from to glow_to are
# spread over the glow gradient; zoomed views need a higher range because
# everything near the boundary takes longer to escape.
sub mandelbrot_view {
    my (%view) = @_;
    my ($center_x, $center_y, $half_height) = @view{qw(center_x center_y half_height)};
    my $pixel_rows = 2 * $MANDELBROT_ROWS;
    my $pixel_cols = 2 * $MANDELBROT_COLS;
    my $step_y     = 2 * $half_height / $pixel_rows;

    # A quadrant pixel is half a cell wide and half a cell tall, and cells are
    # twice as tall as wide, so pixels are twice as tall as wide too.
    my $step_x = $step_y / 2;

    # Each pixel takes a 3x3 grid of samples and is black when most of them
    # stay bounded. Otherwise it's the average color of the samples that
    # escaped, which smooths over boundary detail finer than a pixel without
    # mixing in the black of the set and going gray. Escape time goes through
    # log so the glow brightens at a steady pace from the far field in.
    my $glow_from = log $view{glow_from};
    my $glow_span = log($view{glow_to}) - $glow_from;
    my @offsets   = map { my $dy = $_; map { [ $_, $dy ] } 1 / 6, 1 / 2, 5 / 6 } 1 / 6, 1 / 2, 5 / 6;
    my @palette   = gradient_palette(\@MANDELBROT_GLOW);
    my @rgb;
    for my $r (0 .. $pixel_rows - 1) {
        push @rgb, [ map {
            my $c = $_;
            my @colors = map {
                my ($dx, $dy) = @$_;
                my ($steps) = mandelbrot_escape(
                    $center_x + ($c + $dx - $pixel_cols / 2) * $step_x,
                    $center_y + $half_height - ($r + $dy) * $step_y,
                    $view{max_steps},
                );
                defined $steps ? [ gradient_rgb(\@MANDELBROT_GLOW, (log($steps) - $glow_from) / $glow_span) ] : ();
            } @offsets;
            @colors * 2 <= @offsets ? undef : average_rgb(@colors);
        } 0 .. $pixel_cols - 1 ];
    }

    # Zoomed in, the boundary has detail far finer than a pixel and neighbors
    # flicker between bright and dark, which is noise to the eye and costs a
    # color code per flicker. Blurring each escaped pixel with its escaped
    # neighbors calms that down; pixels in the set stay black so the shape
    # keeps its edge.
    my @pixels;
    for my $r (0 .. $pixel_rows - 1) {
        push @pixels, [ map {
            my $c = $_;
            if (!$rgb[$r][$c]) {
                $BLACK;
            } else {
                my @near = grep { $_ } map {
                    my $nr = $_;
                    map { $nr >= 0 && $nr < $pixel_rows && $_ >= 0 && $_ < $pixel_cols ? $rgb[$nr][$_] : undef } $c - 1 .. $c + 1;
                } $r - 1 .. $r + 1;
                nearest_color_in(\@palette, @{ average_rgb(@near) });
            }
        } 0 .. $pixel_cols - 1 ];
    }
    return pixels_to_canvas(\@pixels);
}

sub mandelbrot_canvas {
    my $canvas = mandelbrot_view(
        center_x  => -0.75, center_y => 0, half_height => 1.15,
        max_steps => 300,   glow_from => 1, glow_to => 60,
    );
    put_text($canvas, $MANDELBROT_ROWS / 2, 39, 'z -> z^2 + c', 98);
    return $canvas;
}

# Seahorse Valley is the crack between the main cardioid and the big bulb to
# its left, where the boundary curls into spirals that look like seahorse
# tails. This frames one tail about 600 times closer than the full view.
sub seahorse_canvas {
    my $canvas = mandelbrot_view(
        center_x  => -0.7453, center_y  => 0.1127, half_height => 0.0015,
        max_steps => 1500,    glow_from => 40,     glow_to     => 160,
    );
    put_text($canvas, 9,  1, 'seahorse valley', 97);
    put_text($canvas, 10, 1, '-0.7453+0.1127i', 94);
    return $canvas;
}

our %PIECES = (mandelbrot => \&mandelbrot_canvas, seahorse => \&seahorse_canvas, zeta => \&zeta_canvas);

sub piece_list { return join ' ', sort keys %PIECES }

# Drawing a piece can take seconds, and irssi would freeze for all of it, so it
# happens in a forked child that writes the finished lines back through a pipe.
# Each piece is drawn once per session and kept in %RENDERED. Anyone asking for
# a piece while it's being drawn waits in %drawing and gets it when it's done.
our %RENDERED;
my %drawing;

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
    if (!$PIECES{$name}) {
        $witem->print(qq{math: no piece called "$name". pieces: } . piece_list(), MSGLEVEL_CLIENTERROR);
        return;
    }
    if (!$preview && (!$server || !$server->{connected})) {
        Irssi::print('math: not connected to a server', MSGLEVEL_CLIENTERROR);
        return;
    }

    my $request = { server_tag => $server && $server->{tag}, target => $witem->{name}, preview => $preview };
    if (my $lines = $RENDERED{$name}) {
        deliver($request, $lines);
    } elsif ($drawing{$name}) {
        push @{ $drawing{$name} }, $request;
    } else {
        $witem->print("math: drawing $name...", MSGLEVEL_CLIENTCRAP);
        $drawing{$name} = [$request];
        if (my $error = start_drawing($name)) {
            delete $drawing{$name};
            $witem->print("math: could not draw $name: $error", MSGLEVEL_CLIENTERROR);
        }
    }
}

# Returns an error message if the drawing couldn't be started.
sub start_drawing {
    my ($name) = @_;
    pipe(my $reader, my $writer) or return "could not open a pipe: $!";
    my $pid = fork;
    return "could not fork: $!" if !defined $pid;

    if ($pid == 0) {
        close $reader;
        binmode $writer;
        my @lines = eval { irc_lines($PIECES{$name}->()) };
        print $writer $@ ? "error $@" : map { 'line ' . Encode::encode_utf8($_) . "\n" } @lines;
        close $writer;

        # _exit skips the cleanup that belongs to irssi, which this copy of
        # the process must not run.
        POSIX::_exit(0);
    }

    close $writer;
    Irssi::pidwait_add($pid);
    my $drawing = { name => $name, reader => $reader, output => '' };
    $drawing->{tag} = Irssi::input_add(fileno($reader), INPUT_READ, \&read_drawing, $drawing);
    return;
}

sub read_drawing {
    my ($drawing) = @_;
    my $got = sysread $drawing->{reader}, my $chunk, 65536;
    if ($got) {
        $drawing->{output} .= $chunk;
        return;
    }

    # The child closed its end, so the drawing is finished one way or another.
    Irssi::input_remove($drawing->{tag});
    close $drawing->{reader};
    my $name     = $drawing->{name};
    my $requests = delete $drawing{$name};

    my (@lines, $error);
    for (split /\n/, $drawing->{output}) {
        push @lines, Encode::decode_utf8($1) if /^line (.*)/s;
        $error = $1 if /^error (.*)/s;
    }
    $error //= 'the drawing process died' if !@lines;
    if (defined $error) {
        for my $request (@$requests) {
            my (undef, $item) = request_window($request);
            $item->print("math: could not draw $name: $error", MSGLEVEL_CLIENTERROR) if $item;
        }
        return;
    }
    $RENDERED{$name} = \@lines;
    deliver($_, \@lines) for @$requests;
}

# Finds a request's server and window again. Either may have gone away while
# the piece was drawing, so we never hold on to the objects themselves.
sub request_window {
    my ($request) = @_;
    my $server = defined $request->{server_tag} ? Irssi::server_find_tag($request->{server_tag}) : undef;
    my $item   = $server ? $server->window_item_find($request->{target}) : Irssi::window_item_find($request->{target});
    return ($server, $item);
}

sub deliver {
    my ($request, $lines) = @_;
    my ($server, $item) = request_window($request);
    return if !$item;

    if ($request->{preview}) {
        $item->print($_, MSGLEVEL_CLIENTCRAP) for @$lines;
        return;
    }
    if (!$server->{connected}) {
        $item->print('math: not connected to a server', MSGLEVEL_CLIENTERROR);
        return;
    }
    $server->command("MSG $request->{target} $_") for @$lines;
}

Irssi::command_bind('math', 'cmd_math');
