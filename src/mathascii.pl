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
#        /math -l           lists the pieces with what each one is
#        /math -h           shows this usage
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

# Draws a curve as a glowing line onto a grid of RGB pixels. The curve is a
# list of closely spaced [row, col, position] points, in fractional pixels,
# and each point's color is its position along the hues gradient. For every
# pixel near the curve we find how close the curve comes; where the curve
# crosses itself, the nearer strand wins. A width below 1 draws a thinner line
# with a shorter glow, for curves whose strands run close together.
sub draw_glow_curve {
    my ($rgb, $points, $hues, $width) = @_;
    $width //= 1;
    my $reach = $GLOW_REACH * $width;
    my ($rows, $cols) = (scalar @$rgb, scalar @{ $rgb->[0] });
    my (%distance, %position_at);
    for my $point (@$points) {
        my ($row, $col, $position) = @$point;
        for my $r (POSIX::ceil($row - $reach / 2) .. POSIX::floor($row + $reach / 2)) {
            next if $r < 0 || $r >= $rows;
            for my $c (POSIX::ceil($col - $reach) .. POSIX::floor($col + $reach)) {
                next if $c < 0 || $c >= $cols;
                my $d = sqrt(($c - $col)**2 + (2 * ($r - $row))**2) / $width;
                next if exists $distance{"$r,$c"} && $distance{"$r,$c"} <= $d;
                $distance{"$r,$c"}    = $d;
                $position_at{"$r,$c"} = $position;
            }
        }
    }
    for my $key (keys %distance) {
        my ($r, $c) = split /,/, $key;
        my @hue = gradient_rgb($hues, $position_at{$key});
        $rgb->[$r][$c] = [ glow_rgb($rgb->[$r][$c], \@hue, $distance{$key}) ];
    }
}

# A whole frame of glowing lines on black: draws the points with
# draw_glow_curve and snaps every pixel to the hues' own palette colors.
sub glow_lines_canvas {
    my ($points, $hues, $width) = @_;
    my @rgb = map { [ map { [ 0, 0, 0 ] } 1 .. 140 ] } 1 .. 48;
    draw_glow_curve(\@rgb, $points, $hues, $width);
    my @palette = (gradient_palette($hues), $BLACK);
    return pixels_to_canvas([ map { [ map { nearest_color_in(\@palette, @$_) } @$_ ] } @rgb ]);
}

# A whole frame colored by how many times something landed on each pixel.
# $counts maps "row,col" to a count; pixels nobody landed on stay black. The
# count that reaches the top of the gradient is the one at the $top
# percentile, so a few very busy pixels don't leave everything else dim, and
# $power below 1 brightens the quiet pixels, above 1 darkens them.
sub density_canvas {
    my ($counts, $gradient, $top, $power) = @_;
    my @sorted  = sort { $a <=> $b } values %$counts;
    my $most    = $sorted[ int($top * $#sorted) ];
    my @palette = gradient_palette($gradient);
    my @pixels  = map {
        my $r = $_;
        [ map {
            my $count = $counts->{"$r,$_"};
            $count ? nearest_color_in(\@palette, gradient_rgb($gradient, List::Util::min(1, $count / $most)**$power)) : $BLACK;
        } 0 .. 139 ];
    } 0 .. 47;
    return pixels_to_canvas(\@pixels);
}

# Points every pixel or so along a straight line between two [row, col]
# pixel positions, for draw_glow_curve, all at the same gradient position.
sub line_points {
    my ($from, $to, $position) = @_;
    my $steps = POSIX::ceil(abs($to->[1] - $from->[1]) + 2 * abs($to->[0] - $from->[0]));
    return map {
        [ $from->[0] + ($to->[0] - $from->[0]) * $_ / $steps, $from->[1] + ($to->[1] - $from->[1]) * $_ / $steps, $position ]
    } 0 .. $steps;
}

# Where a point (x, y) of a drawing centered on the frame lands, as fractional
# [row, col] pixels, with $scale pixels to a unit across. Pixels are twice as
# tall as wide, so a unit is half as many rows down.
sub centered_pixel {
    my ($x, $y, $scale) = @_;
    return [ 24 - $y * $scale / 2 - 0.5, 70 + $x * $scale - 0.5 ];
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

    my @points = map {
        my $t = $ZETA_T_MAX * $_ / $ZETA_SAMPLES;
        [ zeta_pixel_position(zeta(0.5, $t)), $t / $ZETA_T_MAX ];
    } 0 .. $ZETA_SAMPLES;
    draw_glow_curve(\@rgb, \@points, \@ZETA_HUES);

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

# Newton's method on z^3 - 1 slides z toward a root by following the tangent:
# z -> z - (z^3 - 1) / 3z^2, which simplifies to 2z/3 + 1/(3z^2). Returns which
# of the three cube roots of 1 it reaches (0 is 1 itself, then counting
# counterclockwise) and in how many steps, or nothing if it doesn't settle.
#
# The step count is smoothed so shading is continuous rather than in bands.
# Near a root the error roughly squares every step, so log(log(error)) grows
# by log 2 a step, and how far the last step overshot the tolerance in those
# terms gives the fraction.
my @CUBE_ROOTS = ([ 1, 0 ], [ -0.5, sqrt(3) / 2 ], [ -0.5, -sqrt(3) / 2 ]);
my $NEWTON_TOLERANCE = 1e-12;    # squared distance from the root

sub newton_basin {
    my ($x, $y, $max_steps) = @_;
    my $previous = 1;
    for my $step (1 .. $max_steps) {
        my $size = ($x * $x + $y * $y)**2;    # |z^2|^2
        return if $size == 0;
        # 1/(3z^2) = conj(z^2) / (3 |z^2|^2)
        my ($sq_x, $sq_y) = ($x * $x - $y * $y, 2 * $x * $y);
        ($x, $y) = (2 * $x / 3 + $sq_x / (3 * $size), 2 * $y / 3 - $sq_y / (3 * $size));
        my $nearest = List::Util::min(map { ($x - $_->[0])**2 + ($y - $_->[1])**2 } @CUBE_ROOTS);
        if ($nearest < $NEWTON_TOLERANCE) {
            my ($root) = grep { ($x - $CUBE_ROOTS[$_][0])**2 + ($y - $CUBE_ROOTS[$_][1])**2 == $nearest } 0 .. 2;
            my $fraction = $previous < 1 ? log(log($NEWTON_TOLERANCE) / log($previous)) / log(2) : 0;
            return ($root, $step - 1 + List::Util::min(1, $fraction));
        }
        $previous = $nearest;
    }
    return;
}

# Each root gets its own hue, bright where points reach it fast and dark
# where they dither, which is along the fractal boundary between basins.
my @NEWTON_HUES = (
    [ [ 0, 255, 220, 120 ], [ 0.35, 255, 120, 0 ],   [ 0.7, 120, 0,  20 ],  [ 1, 0, 0, 0 ] ],
    [ [ 0, 180, 255, 200 ], [ 0.35, 0,   200, 100 ], [ 0.7, 0,   70, 60 ],  [ 1, 0, 0, 0 ] ],
    [ [ 0, 190, 190, 255 ], [ 0.35, 60,  80,  255 ], [ 0.7, 30,  0,  120 ], [ 1, 0, 0, 0 ] ],
);

sub newton_canvas {
    my $canvas = sampled_view(
        center_x => 0, center_y => 0, half_height => 1,
        palette  => [ map { gradient_palette($_) } @NEWTON_HUES ],
        color    => sub {
            my ($root, $steps) = newton_basin(@_, 60);
            return defined $root ? [ gradient_rgb($NEWTON_HUES[$root], ($steps - 2) / 8) ] : undef;
        },
    );
    put_text($canvas, 23, 1, 'z -> z - (z^3 - 1) / 3z^2', 97);
    return $canvas;
}

# Where 1, 2, 3, ... $count land when written in a square spiral: 1 in the
# middle, 2 to its right, then turning counterclockwise, with y up. The walk
# goes 1 step, turns, 1 step, turns, 2 steps, turns, 2 steps, and so on.
sub ulam_spiral {
    my ($count) = @_;
    my @directions = ([ 1, 0 ], [ 0, 1 ], [ -1, 0 ], [ 0, -1 ]);
    my ($x, $y, $direction, $run) = (0, 0, 0, 1);
    my @spiral = ([ 0, 0 ]);
    while (@spiral < $count) {
        for (1 .. 2) {
            for (1 .. $run) {
                last if @spiral >= $count;
                $x += $directions[$direction][0];
                $y += $directions[$direction][1];
                push @spiral, [ $x, $y ];
            }
            $direction = ($direction + 1) % 4;
        }
        $run++;
    }
    return @spiral;
}

# A sieve of Eratosthenes: element n is true when n is prime.
sub primes_up_to {
    my ($limit) = @_;
    my @is_prime = (0, 0, (1) x ($limit - 1));
    for my $n (2 .. int sqrt $limit) {
        next if !$is_prime[$n];
        for (my $multiple = $n * $n; $multiple <= $limit; $multiple += $n) {
            $is_prime[$multiple] = 0;
        }
    }
    return \@is_prime;
}

# The Ulam spiral lights up the primes among the first few thousand numbers.
# They pile up along diagonals, which happens because some quadratics (the
# diagonals) are far richer in primes than others, and nobody can fully
# explain why. Each number is two pixels side by side so it draws square.
# Primes are colored by size, pale gold in the middle out to violet.
my @ULAM_HUES = (
    [ 0,   255, 240, 150 ],
    [ 0.3, 255, 180, 0 ],
    [ 0.6, 255, 60,  80 ],
    [ 1,   170, 60,  255 ],
);

sub ulam_canvas {
    my ($cols, $rows) = (70, 48);
    my $count    = $cols * $cols;
    my $is_prime = primes_up_to($count);
    my @palette  = gradient_palette(\@ULAM_HUES);
    my @pixels   = map { [ ($BLACK) x (2 * $cols) ] } 1 .. $rows;

    my @spiral = ulam_spiral($count);
    for my $n (1 .. $count) {
        my ($x, $y) = @{ $spiral[ $n - 1 ] };
        my ($row, $col) = ($rows / 2 - $y, $cols / 2 + $x);
        next if $row < 0 || $row >= $rows || $col < 0 || $col >= $cols;
        my $color = $n == 1 ? 98
            : $is_prime->[$n] ? nearest_color_in(\@palette, gradient_rgb(\@ULAM_HUES, sqrt($n / $count)))
            :                   next;
        @{ $pixels[$row] }[ 2 * $col, 2 * $col + 1 ] = ($color, $color);
    }
    return pixels_to_canvas(\@pixels);
}

# The Burning Ship, here its biggest ship, a little left of the main body.
# It's drawn with the imaginary axis pointing down, the usual way, because
# that's what puts the ship upright on the water.
#
# Like the Julia set's, the gradient starts on a palette color (16, a deep
# maroon) because blends up from black land on gray.
my @BURNING_GLOW = (
    [ 0,    71,  0,   0 ],
    [ 0.3,  116, 0,   0 ],
    [ 0.55, 220, 40,  0 ],
    [ 0.75, 255, 150, 0 ],
    [ 0.9,  255, 230, 80 ],
    [ 1,    255, 255, 220 ],
);

sub burningship_canvas {
    my $canvas = escape_view(
        center_x  => -1.765, center_y => 0.02, half_height => 0.065,
        glow_from => 8,      glow_to  => 120,   glow        => \@BURNING_GLOW,
        escape    => sub { escape_time(0, 0, $_[0], -$_[1], 500, 1) },
    );
    put_text($canvas, 0, 1, 'z -> (|Re z| + i|Im z|)^2 + c', 97);
    return $canvas;
}

# Barnsley's fern: start anywhere, then over and over pick one of four
# affine maps at random and apply it. The points pile up into a fern, because
# each map shrinks the whole fern into one part of itself: the stem, the next
# frond up, or the lowest leaflet on either side. Each map is
# [chance, a, b, c, d, e, f] for (x, y) -> (ax + by + e, cx + dy + f).
my @FERN_MAPS = (
    [ 0.01, 0,     0,     0,     0.16, 0, 0 ],
    [ 0.85, 0.85,  0.04,  -0.04, 0.85, 0, 1.6 ],
    [ 0.07, 0.2,   -0.26, 0.23,  0.22, 0, 1.6 ],
    [ 0.07, -0.15, 0.28,  0.26,  0.24, 0, 0.44 ],
);

# $count points of the fern, as [x, y]. The randomness comes from a little
# generator of our own with a fixed seed, so the fern comes out the same every
# time and nothing else's use of rand changes it.
sub fern_points {
    my ($count) = @_;
    my ($x, $y, $seed) = (0, 0, 20261018);
    my @points;
    for (1 .. $count) {
        $seed = ($seed * 1103515245 + 12345) % 2147483648;
        my $roll = $seed / 2147483648;
        my $map  = $FERN_MAPS[-1];
        for my $candidate (@FERN_MAPS) {
            if ($roll < $candidate->[0]) {
                $map = $candidate;
                last;
            }
            $roll -= $candidate->[0];
        }
        my (undef, $a, $b, $c, $d, $e, $f) = @$map;
        ($x, $y) = ($a * $x + $b * $y + $e, $c * $x + $d * $y + $f);
        push @points, [ $x, $y ];
    }
    return @points;
}

# The fern is about 10 long and 5 wide. Standing up it would get only a third
# of the width and its leaflets would be smaller than a pixel, so it lies on
# its side with the stem at the left. It's colored by how many points land in
# each pixel: dark green where few do, bright where they pile up.
my @FERN_GREENS = (
    [ 0,   0,   60,  0 ],
    [ 0.4, 0,   170, 40 ],
    [ 0.8, 150, 255, 80 ],
    [ 1,   230, 255, 200 ],
);

sub fern_canvas {
    my ($pixel_cols, $pixel_rows) = (140, 48);
    my $step = 10.2 / $pixel_cols;    # the width of a pixel, in fern units
    my %hits;
    # Too many points fill in the gaps between the leaflets.
    for my $point (fern_points(10_000)) {
        my ($x, $y) = @$point;
        my $row = int(($x + 2.3) / (2 * $step)) + 7;
        my $col = int($y / $step) + 1;
        $hits{$row}{$col}++;
    }
    my $most    = log(List::Util::max(map { values %$_ } values %hits));
    my @palette = gradient_palette(\@FERN_GREENS);
    my @pixels  = map {
        my $r = $_;
        [ map { $hits{$r}{$_} ? nearest_color_in(\@palette, gradient_rgb(\@FERN_GREENS, log(1 + $hits{$r}{$_}) / $most)) : $BLACK } 0 .. $pixel_cols - 1 ];
    } 0 .. $pixel_rows - 1;

    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0, 34, "Barnsley's fern: four affine maps,", 97);
    put_text($canvas, 1, 34, 'one picked at random, over and over', 94);
    return $canvas;
}

# The Heighway dragon: fold a strip of paper in half again and again, open
# every fold to a right angle, and look at it edge on. Turn n is left when n,
# with its factors of 2 divided out, is one more than a multiple of 4, and
# right otherwise. Returns 1 for left and -1 for right.
sub dragon_turn {
    my ($n) = @_;
    $n /= 2 while $n % 2 == 0;
    return $n % 4 == 1 ? 1 : -1;
}

# The corners of the dragon after $order folds, as [x, y] on a unit grid,
# starting at the origin heading east.
sub dragon_path {
    my ($order) = @_;
    my @directions = ([ 1, 0 ], [ 0, 1 ], [ -1, 0 ], [ 0, -1 ]);
    my ($x, $y, $direction) = (1, 0, 0);
    my @path = ([ 0, 0 ], [ 1, 0 ]);
    for my $n (1 .. 2**$order - 1) {
        $direction = ($direction + dragon_turn($n)) % 4;
        $x += $directions[$direction][0];
        $y += $directions[$direction][1];
        push @path, [ $x, $y ];
    }
    return @path;
}

# The first $count digits of pi, starting with the 3, by Rabinowitz and
# Wagon's spigot: pi is written in a mixed-radix form whose "digits" are all
# 2, and each round multiplies that by 10 and carries from right to left,
# which pushes out the next decimal digit at the left end. The digit that
# comes out can be 10, which means a carry into the digits already found, so
# each digit is held back until the next one shows there's no carry, and any
# run of 9s is held back with it, since a carry would turn them all to 0s.
sub pi_digits {
    my ($count) = @_;
    my $length = int(10 * $count / 3) + 1;
    my @mixed  = (2) x $length;
    my ($held, $nines) = (undef, 0);
    my @digits;
    for (1 .. $count) {
        my $carry = 0;
        for my $i (reverse 1 .. $length) {
            my $x = 10 * $mixed[ $i - 1 ] + $carry * $i;
            $mixed[ $i - 1 ] = $x % (2 * $i - 1);
            $carry = int($x / (2 * $i - 1));
        }
        $mixed[0] = $carry % 10;
        my $digit = int($carry / 10);
        if ($digit == 9) {
            $nines++;
        } elsif ($digit == 10) {
            push @digits, $held + 1, (0) x $nines;
            ($held, $nines) = (0, 0);
        } else {
            push @digits, $held if defined $held;
            push @digits, (9) x $nines;
            ($held, $nines) = ($digit, 0);
        }
    }
    push @digits, $held, (9) x $nines;
    return @digits[ 0 .. $count - 1 ];
}

# A walk steered by pi: each digit d is a step one unit long in direction
# d tenths of a full turn. If pi's digits are as evenly mixed as everyone
# believes (nobody has proved it), the walk wanders like a random one. The
# hue runs along the walk from the 3 to the last digit.
sub piwalk_canvas {
    my $pi = 4 * atan2(1, 1);
    my ($x, $y) = (0, 0);
    my @path = ([ 0, 0 ]);
    for my $digit (pi_digits(1000)) {
        ($x, $y) = ($x + cos(2 * $pi * $digit / 10), $y + sin(2 * $pi * $digit / 10));
        push @path, [ $x, $y ];
    }
    my $place  = fit_to_frame(\@path);
    my @points = map { line_points($place->(@{ $path[ $_ - 1 ] }), $place->(@{ $path[$_] }), $_ / $#path) } 1 .. $#path;
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.5);
    put_text($canvas, 23, 1, '3.14159265358979... each digit a direction', 97);
    return $canvas;
}

# A phase portrait colors every point z of the plane by the angle of f(z):
# red where f(z) points along the positive real axis, round the color wheel
# through green and blue as the angle turns. Around a zero of f the colors go
# round once (twice for a double zero), and around a pole they go round the
# other way, so zeros and poles show up as pinwheels. This is the classic
# example, f(z) = (z^2 - 1)(z - 2 - i)^2 / (z^2 + 2 + 2i), with zeros at 1,
# -1 and a double zero at 2 + i, and poles at the square roots of -2 - 2i.
sub phase_function {
    my ($x, $y) = @_;
    my $z      = [ $x, $y ];
    my $square = c_mul($z, $z);
    my $shift  = [ $x - 2, $y - 1 ];
    my $top    = c_mul([ $square->[0] - 1, $square->[1] ], c_mul($shift, $shift));
    my $bottom = [ $square->[0] + 2, $square->[1] + 2 ];
    return @{ c_div($top, $bottom) };
}

# The color wheel, by angle from -pi to pi: red at 0, green a third of a turn
# round, blue a third back.
my @PHASE_WHEEL = (
    [ 0,     255, 0,   0 ],
    [ 1 / 6, 255, 255, 0 ],
    [ 1 / 3, 0,   255, 0 ],
    [ 1 / 2, 0,   255, 255 ],
    [ 2 / 3, 0,   0,   255 ],
    [ 5 / 6, 255, 0,   255 ],
    [ 1,     255, 0,   0 ],
);

sub phase_wheel {
    my ($angle) = @_;
    my $turn = $angle / (8 * atan2(1, 1));
    $turn += 1 if $turn < 0;
    return gradient_rgb(\@PHASE_WHEEL, $turn);
}

# Each point gets the wheel color for the angle of f(z), snapped to the
# twelve bright palette colors that go round the wheel (52 to 63), so each
# pinwheel has twelve clean blades. Shading rings by |f| as well looked good
# in principle but came out as ragged stripes at this size.
sub phase_canvas {
    my $canvas = sampled_view(
        center_x => 0.3, center_y => 0, half_height => 2,
        palette  => [ 52 .. 63 ],
        color    => sub {
            my ($re, $im) = phase_function(@_);
            return [ phase_wheel(atan2($im, $re)) ];
        },
    );
    put_text($canvas, 23, 1, 'f(z) = (z^2 - 1)(z - 2 - i)^2 / (z^2 + 2 + 2i)', 98);
    return $canvas;
}

# Follows z -> z^2 + c from 0 and, if z leaves the disk of radius 2 within
# $max_steps, returns every point it passed through on the way out, as [x, y].
# Points that stay return nothing.
sub escaping_orbit {
    my ($cx, $cy, $max_steps) = @_;
    my ($x, $y) = (0, 0);
    my @orbit;
    for (1 .. $max_steps) {
        ($x, $y) = ($x * $x - $y * $y + $cx, 2 * $x * $y + $cy);
        return @orbit if $x * $x + $y * $y > 4;
        push @orbit, [ $x, $y ];
    }
    return;
}

# The Buddhabrot: instead of coloring each c by whether it escapes, take every
# c that does escape and mark each point its orbit passes through on the way
# out. Piled up, the orbits draw a ghostly seated figure. It's stood upright
# the usual way, with the real axis running down the frame (from -2.05 at the
# top) and the imaginary axis across. Returns hit counts by "row,col", from
# c sampled on a grid $density points to a unit. Each orbit is also mirrored
# across the real axis, since conjugate c gives conjugate orbits, which
# doubles the hits for free and keeps the figure symmetric.
sub buddhabrot_hits {
    my ($density) = @_;
    my $rows_per_unit = 15;
    my %hits;
    for my $i (0 .. 3 * $density) {
        my $cx = -2 + $i / $density;
        for my $j (0 .. 1.5 * $density) {
            my $cy = $j / $density;

            # Points in the main cardioid and the big bulb never escape.
            my $q = ($cx - 0.25)**2 + $cy**2;
            next if $q * ($q + $cx - 0.25) <= $cy**2 / 4 || ($cx + 1)**2 + $cy**2 <= 1 / 16;

            # Orbits that escape in a few steps mostly just mark the sampling
            # grid near where they started, and wash the figure out in a flat
            # box, so only the slow escapers near the set count.
            my @orbit = escaping_orbit($cx, $cy, 200);
            next if @orbit < 8;
            for my $point (@orbit) {
                my ($x, $y) = @$point;
                my $row = int(($x + 2.05) * $rows_per_unit);
                next if $row < 0 || $row > 47;
                my $col = POSIX::floor(70 + $y * 2 * $rows_per_unit);
                next if $col < 0 || $col > 139;
                $hits{"$row,$col"}++;
                $hits{ $row . ',' . (139 - $col) }++;
            }
        }
    }
    return \%hits;
}

# Deep blue through violet and pink to white, on palette colors (24, 37, 50,
# 74, 98) so blends don't land on gray.
my @BUDDHA_GLOW = (
    [ 0,    0,   0,   71 ],
    [ 0.25, 75,  0,   116 ],
    [ 0.5,  181, 0,   181 ],
    [ 0.75, 255, 102, 255 ],
    [ 1,    255, 255, 255 ],
);

sub buddhabrot_canvas {
    return density_canvas(buddhabrot_hits(150), \@BUDDHA_GLOW, 0.995, 0.5);
}

# The logistic map, x -> r x (1 - x), a toy model of a population that grows
# but is held back by crowding. Returns $count values of x after letting it
# settle for $settle steps from x = 0.5. For small r it settles on one value;
# past r = 3 it flips between two, then four, then eight, the doublings coming
# faster and faster (by Feigenbaum's constant, 4.669...) until around 3.57 it
# never repeats at all.
sub logistic_orbit {
    my ($r, $settle, $count) = @_;
    my $x = 0.5;
    $x = $r * $x * (1 - $x) for 1 .. $settle;
    return map { $x = $r * $x * (1 - $x) } 1 .. $count;
}

# The bifurcation diagram: r runs across from 2.8 to 4 and every value x
# settles into is marked above it, brighter where it lands more often. The
# stops are palette colors (28, 52, 53, 54, 98) so blends don't land on gray.
my @LOGISTIC_GLOW = (
    [ 0,    116, 0,   0 ],
    [ 0.3,  255, 0,   0 ],
    [ 0.6,  255, 140, 0 ],
    [ 0.85, 255, 255, 0 ],
    [ 1,    255, 255, 255 ],
);

sub logistic_canvas {
    my %hits;
    for my $sub_column (0 .. 4 * 140 - 1) {
        my $r = 2.8 + 1.2 * ($sub_column + 0.5) / (4 * 140);
        for my $x (logistic_orbit($r, 500, 200)) {
            $hits{ int((1 - $x) * 48) . ',' . int($sub_column / 4) }++;
        }
    }
    my $canvas = density_canvas(\%hits, \@LOGISTIC_GLOW, 0.9, 0.5);
    put_text($canvas, 0, 1, 'x -> r x (1 - x)', 97);
    put_text($canvas, 1, 1, 'r from 2.8 to 4', 94);
    return $canvas;
}

# The Apollonian gasket: inside a circle put three equal circles that all
# touch each other and it, then fill every curved gap with the biggest circle
# that fits, and the new gaps the same way, forever. Circles are
# [curvature, x, y], curvature being 1/radius, with the outer circle's
# negative because the others touch it from the inside.
#
# Descartes' theorem says four mutually touching circles satisfy
# (k1 + k2 + k3 + k4)^2 = 2 (k1^2 + k2^2 + k3^2 + k4^2). Given three circles,
# that's a quadratic with two answers for the fourth: the circle we already
# have on the other side of the gap, and the new one. The two answers add up
# to 2 (k1 + k2 + k3), so the new one is 2 (k1 + k2 + k3) - k_old. Curvature
# times center obeys the same rule, which gives the new center without
# square roots or choosing signs.
sub apollonian_circles {
    my ($smallest) = @_;
    my $pi    = 4 * atan2(1, 1);
    my $k     = 1 + 2 / sqrt(3);
    my $outer = [ -1, 0, 0 ];
    my @three = map { [ $k, (1 - 1 / $k) * cos($pi / 2 + 2 * $pi * $_ / 3), (1 - 1 / $k) * sin($pi / 2 + 2 * $pi * $_ / 3) ] } 0 .. 2;
    my @circles = ($outer, @three);

    my $fill;
    $fill = sub {
        my ($a, $b, $c, $old) = @_;
        my $new_k = 2 * ($a->[0] + $b->[0] + $c->[0]) - $old->[0];
        return if 1 / $new_k < $smallest;
        my $new = [ $new_k, map { my $i = $_; (2 * ($a->[0] * $a->[$i] + $b->[0] * $b->[$i] + $c->[0] * $c->[$i]) - $old->[0] * $old->[$i]) / $new_k } 1, 2 ];
        push @circles, $new;
        $fill->($a, $b, $new, $c);
        $fill->($a, $c, $new, $b);
        $fill->($b, $c, $new, $a);
    };
    my ($p, $q, $r) = @three;
    $fill->($outer, $p, $q, $r);
    $fill->($outer, $q, $r, $p);
    $fill->($outer, $p, $r, $q);
    $fill->($p, $q, $r, $outer);
    undef $fill;    # it refers to itself, so break the loop for the garbage collector
    return @circles;
}

# Each circle drawn as a thin glowing ring, colored by size: the big ones
# violet, down through the rainbow to the tiniest in pink.
sub apollonian_canvas {
    my $scale   = 46;    # pixels per unit across, so the outer circle fills the height
    my @circles = apollonian_circles(0.015);
    my $biggest = log(List::Util::max(map { $_->[0] } @circles));
    my $pi      = 4 * atan2(1, 1);
    my @points;
    for my $circle (@circles) {
        my ($k, $x, $y) = @$circle;
        my $radius   = 1 / abs $k;
        my $position = $k < 0 ? 0 : log($k) / $biggest;
        my $steps    = POSIX::ceil(4 * $pi * $radius * $scale) + 4;
        push @points, map {
            my $angle = 2 * $pi * $_ / $steps;
            [ @{ centered_pixel($x + $radius * cos $angle, $y + $radius * sin $angle, $scale) }, $position ];
        } 0 .. $steps;
    }
    return glow_lines_canvas(\@points, \@ZETA_HUES, 0.5);
}

# Scales a drawing to fill the frame, keeping its proportions, and returns a
# function that takes a point (x, y) of the drawing, with y up, to fractional
# [row, col] pixels. A unit is twice as many pixels across as rows down
# because pixels are twice as tall as wide.
sub fit_to_frame {
    my ($points) = @_;
    my @xs = map { $_->[0] } @$points;
    my @ys = map { $_->[1] } @$points;
    my ($min_x, $max_x, $min_y, $max_y) = (List::Util::min(@xs), List::Util::max(@xs), List::Util::min(@ys), List::Util::max(@ys));
    my $scale = List::Util::min(136 / (($max_x - $min_x) || 1), 2 * 44 / (($max_y - $min_y) || 1));
    my ($mid_x, $mid_y) = (($min_x + $max_x) / 2, ($min_y + $max_y) / 2);
    return sub {
        my ($x, $y) = @_;
        return [ 23.5 - ($y - $mid_y) * $scale / 2, 69.5 + ($x - $mid_x) * $scale ];
    };
}

# The Collatz rule: halve even numbers, and take odd ones to 3n + 1. Every
# number anyone has tried ends up at 1, but nobody has proved they all do.
# Returns the whole trip from $n down to 1.
sub collatz_sequence {
    my ($n) = @_;
    my @trip = ($n);
    while ($n != 1) {
        $n = $n % 2 ? 3 * $n + 1 : $n / 2;
        push @trip, $n;
    }
    return @trip;
}

# The Collatz coral: every number's trip, read backwards from 1, drawn as a
# stem that bends one way at every even number and the other way at every odd
# one. Numbers whose trips end the same way share a trunk, so the whole lot
# grows like coral. The hue goes with how far up the stem a point is.
sub collatz_canvas {
    my ($even_turn, $odd_turn) = (0.15, -0.27);
    my (@stems, $tallest);
    # A few hundred numbers mostly share one long trunk; it takes more than a
    # thousand before the branches fan out.
    for my $n (2 .. 1500) {
        my ($x, $y, $heading) = (0, 0, 2 * atan2(1, 1));
        my @stem = ([ 0, 0 ]);
        for my $value (reverse collatz_sequence($n)) {
            next if $value == 1;
            $heading += $value % 2 ? $odd_turn : $even_turn;
            ($x, $y) = ($x + cos $heading, $y + sin $heading);
            push @stem, [ $x, $y ];
        }
        push @stems, \@stem;
        $tallest = List::Util::max($tallest // 0, $#stem);
    }
    my $place = fit_to_frame([ map {@$_} @stems ]);
    my @points;
    for my $stem (@stems) {
        push @points, map { line_points($place->(@{ $stem->[ $_ - 1 ] }), $place->(@{ $stem->[$_] }), $_ / $tallest) } 1 .. $#$stem;
    }
    return glow_lines_canvas(\@points, \@ZETA_HUES, 0.4);
}

# The times table on a circle: put $n points around a circle and join each
# point k to point m*k mod $n. Nothing about it mentions curves, yet with
# m = 2 the chords trace out a cardioid (the same shape as the Mandelbrot
# set's body) and with m = 3 a nephroid. Points that would join themselves
# are left out. Returns [k, m*k mod $n] pairs.
sub times_table_chords {
    my ($n, $m) = @_;
    return grep { $_->[0] != $_->[1] } map { [ $_, $m * $_ % $n ] } 0 .. $n - 1;
}

# Two circles side by side, times 2 and times 3. The curves are envelopes,
# where the chords crowd together, so each pixel counts how many chords cross
# it and glows brighter the more there are. Coloring chords one by one just
# makes confetti. The gradient's stops are palette colors (25, 49, 74, 98) so
# the blends between them don't land on grays.
my @TIMESTABLE_GLOW = (
    [ 0,   46,  0,   71 ],
    [ 0.4, 117, 0,   181 ],
    [ 0.7, 255, 102, 255 ],
    [ 1,   255, 255, 255 ],
);

sub timestable_canvas {
    my $n      = 200;
    my $radius = 17;    # in rows; a circle is twice that many pixels across
    my $pi     = 4 * atan2(1, 1);
    my %crossings;
    for my $circle ([ 2, 35 ], [ 3, 105 ]) {
        my ($m, $center_col) = @$circle;
        my $place = sub {
            my $angle = $pi / 2 - 2 * $pi * $_[0] / $n;
            return [ 25 - $radius * sin($angle) - 0.5, $center_col + 2 * $radius * cos($angle) - 0.5 ];
        };
        for my $chord (times_table_chords($n, $m)) {
            my %crossed = map { POSIX::floor($_->[0] + 0.5) . ',' . POSIX::floor($_->[1] + 0.5) => 1 }
                line_points($place->($chord->[0]), $place->($chord->[1]), 0);
            $crossings{$_}++ for keys %crossed;
        }
    }
    # A straight count, not a log of it, so that only real crowding glows and
    # the scattered chords elsewhere stay dim. The cusps are far more crowded
    # than anywhere else, so the scale tops out at the 95th percentile rather
    # than the very busiest pixel, or the rest of the curve would be dim too.
    my $canvas = density_canvas(\%crossings, \@TIMESTABLE_GLOW, 0.95, 1);
    put_text($canvas, 0, 9,  "k -> 2k mod $n", 97);
    put_text($canvas, 0, 44, "k -> 3k mod $n", 97);
    return $canvas;
}

# The Koch snowflake: start with a triangle, and on the middle third of every
# edge raise a smaller triangle, again and again. Every round makes the edge
# 4/3 as long, so in the limit the outline is infinitely long, though it
# never gets outside a circle and the area only reaches 8/5 of the triangle.
# Returns the corners in order, with the first repeated at the end to close it.
sub koch_outline {
    my ($order) = @_;
    my $pi = 4 * atan2(1, 1);
    my @outline = map { [ cos($pi / 2 - 2 * $pi * $_ / 3), sin($pi / 2 - 2 * $pi * $_ / 3) ] } 0 .. 3;
    for (1 .. $order) {
        my @finer = ($outline[0]);
        for my $i (1 .. $#outline) {
            my ($a, $b) = @outline[ $i - 1, $i ];
            my ($dx, $dy) = (($b->[0] - $a->[0]) / 3, ($b->[1] - $a->[1]) / 3);
            my $first  = [ $a->[0] + $dx,     $a->[1] + $dy ];
            my $second = [ $a->[0] + 2 * $dx, $a->[1] + 2 * $dy ];

            # The new tip is the middle third turned 60 degrees outward. The
            # outline runs clockwise, so outward is a counterclockwise turn.
            my $tip = [ $first->[0] + $dx / 2 - $dy * sqrt(3) / 2, $first->[1] + $dy / 2 + $dx * sqrt(3) / 2 ];
            push @finer, $first, $tip, $second, $b;
        }
        @outline = @finer;
    }
    return @outline;
}

# The snowflake after four rounds, its outline glowing through the rainbow.
sub koch_canvas {
    my @outline = map { centered_pixel($_->[0], $_->[1] + 0.13, 42) } koch_outline(4);
    my @points  = map { line_points(@outline[ $_ - 1, $_ ], $_ / $#outline) } 1 .. $#outline;
    my $canvas  = glow_lines_canvas(\@points, \@ZETA_HUES, 0.6);
    put_text($canvas, 22, 1, 'perimeter: infinite', 95);
    put_text($canvas, 23, 1, 'area: 8/5 of the triangle', 95);
    return $canvas;
}

# Chladni's plates: scatter sand on a square metal plate and bow its edge, and
# the sand shakes off the parts that move and settles on the lines that stand
# still. A simple model of how the plate moves at one of its notes is
# cos(n pi x) cos(m pi y) - cos(m pi x) cos(n pi y), for x and y from 0 to 1,
# and the sand gathers where that's zero.
sub chladni {
    my ($n, $m, $x, $y) = @_;
    my $pi = 4 * atan2(1, 1);
    return cos($n * $pi * $x) * cos($m * $pi * $y) - cos($m * $pi * $x) * cos($n * $pi * $y);
}

# The plate fills the left of the frame. Each pixel averages four samples of
# how still the plate is there, and the stillest places glow like sand. The
# stops are palette colors (23, 41, 65, 77) because blends between a dark
# plate and sand otherwise land on grays.
my @CHLADNI_SAND = (
    [ 0,   0,   39,  71 ],
    [ 0.5, 181, 99,  0 ],
    [ 0.8, 255, 180, 89 ],
    [ 1,   255, 211, 156 ],
);

sub chladni_canvas {
    my ($n, $m) = (3, 5);
    my ($side_cols, $pixel_rows) = (96, 48);
    my @palette = gradient_palette(\@CHLADNI_SAND);
    my @pixels  = map { [ ($BLACK) x 140 ] } 1 .. $pixel_rows;
    for my $r (0 .. $pixel_rows - 1) {
        for my $c (0 .. $side_cols - 1) {
            my $stillness = List::Util::sum(map {
                my ($dx, $dy) = @$_;
                exp(-4 * abs(chladni($n, $m, ($c + $dx) / $side_cols, ($r + $dy) / $pixel_rows)));
            } [ 0.25, 0.25 ], [ 0.75, 0.25 ], [ 0.25, 0.75 ], [ 0.75, 0.75 ]) / 4;
            $pixels[$r][$c] = nearest_color_in(\@palette, gradient_rgb(\@CHLADNI_SAND, $stillness));
        }
    }
    my $canvas = pixels_to_canvas(\@pixels);
    my @text = (
        [ 97, 'Chladni plate' ],
        [ 88, '' ],
        [ 94, 'sand on a ringing' ],
        [ 94, 'square of metal' ],
        [ 94, 'settles where it' ],
        [ 94, 'stands still:' ],
        [ 88, '' ],
        [ 95, 'cos 3pi x cos 5pi y' ],
        [ 95, '- cos 5pi x cos 3pi y' ],
        [ 95, '= 0' ],
    );
    put_text($canvas, 7 + $_, 49, $text[$_][1], $text[$_][0]) for 0 .. $#text;
    return $canvas;
}

# A harmonograph: one pendulum swings a pen across and another swings the
# paper up and down, each slowly losing energy, so each direction is a damped
# sine wave. Real ones often hang a second pendulum on an axis, so each
# direction is a list of waves to add up. The frequencies are close to 3:2
# but a little off, so the figure slowly turns as it spirals in. Each wave is
# [amplitude, frequency, phase, damping].
my @HARMONOGRAPH_ACROSS = ([ 3, 3.006, 1.5708, 0.03 ]);
my @HARMONOGRAPH_DOWN   = ([ 2, 2,     0,      0.03 ]);

sub harmonograph_points {
    my ($count) = @_;
    my $dt = 0.006;
    my $swing = sub {
        my ($waves, $t) = @_;
        return List::Util::sum(map { my ($a, $f, $p, $d) = @$_; $a * sin($f * $t + $p) * exp(-$d * $t) } @$waves);
    };
    return map { my $t = $_ * $dt; [ $swing->(\@HARMONOGRAPH_ACROSS, $t), $swing->(\@HARMONOGRAPH_DOWN, $t) ] } 0 .. $count - 1;
}

# Drawn as a thin glowing line whose hue runs with time, from the wide early
# swings at the outside to the small late ones in the middle.
sub harmonograph_canvas {
    # Running longer piles the small late loops up into a blur in the middle.
    my @path   = harmonograph_points(5_000);
    my @points = map { [ @{ centered_pixel(@{ $path[$_] }, 22) }, $_ / $#path ] } 0 .. $#path;
    return glow_lines_canvas(\@points, \@ZETA_HUES, 0.5);
}

# Vogel's model of a sunflower head: seed n sits at n golden angles around
# and sqrt(n) out, so every seed gets the same area. The golden angle is the
# full turn cut in the golden ratio, about 137.5 degrees. Because it's as far
# from any fraction as a number can be, no two seeds ever line up behind each
# other, and the turns that come closest to lining up are Fibonacci numbers,
# which is why the eye picks out 21 spirals one way and 34 the other.
our $GOLDEN_ANGLE = 4 * atan2(1, 1) * (3 - sqrt 5);

# $count seeds as [x, y], $spacing apart.
sub sunflower_seeds {
    my ($count, $spacing) = @_;
    return map { [ $spacing * sqrt($_) * cos($_ * $GOLDEN_ANGLE), $spacing * sqrt($_) * sin($_ * $GOLDEN_ANGLE) ] } 1 .. $count;
}

# At this size the seeds alone are too few and too coarse for the eye to find
# the spirals, so we draw them. With 150 seeds the spirals near the rim are
# the 13 and the 21: every seed is joined to the seed 13 after it, making 13
# gold spirals turning one way, and to the seed 21 after it, making 21 magenta
# spirals turning the other. Each seed sits where two spirals cross. Near the
# middle those same gaps would jump across the head, so joins much longer
# than the seed spacing are left out. Too strict a cutoff and the two families
# only meet in a thin ring instead of crossing all over the head.
my @SUNFLOWER_HUES = ([ 0, 255, 190, 0 ], [ 1, 255, 40, 200 ]);

sub sunflower_canvas {
    my $spacing = 3.7;
    my @seeds   = map { centered_pixel(@$_, 1) } sunflower_seeds(150, $spacing);
    my @points;
    for my $family ([ 13, 0 ], [ 21, 1 ]) {
        my ($gap, $position) = @$family;
        for my $n ($gap .. $#seeds) {
            my ($from, $to) = @seeds[ $n - $gap, $n ];
            next if ($to->[1] - $from->[1])**2 + (2 * ($to->[0] - $from->[0]))**2 > (2.6 * $spacing)**2;
            push @points, line_points($from, $to, $position);
        }
    }
    return glow_lines_canvas(\@points, \@SUNFLOWER_HUES, 0.5);
}

# The Hilbert curve of the given order: one unbroken path through every cell
# of a 2^order square grid, never crossing itself, from the bottom left corner
# to the bottom right. Each cell's place along the path is turned into (x, y)
# two bits at a time: the bits pick a quadrant, and the smaller curve inside
# that quadrant is flipped or turned so the four pieces join end to end.
sub hilbert_path {
    my ($order) = @_;
    my $side = 2**$order;
    my @path;
    for my $index (0 .. $side * $side - 1) {
        my ($x, $y, $rest) = (0, 0, $index);
        for (my $size = 1; $size < $side; $size *= 2) {
            my $right = 1 & int($rest / 2);
            my $up    = 1 & ($rest ^ $right);
            if (!$up) {
                ($x, $y) = ($size - 1 - $x, $size - 1 - $y) if $right;
                ($x, $y) = ($y, $x);
            }
            $x += $size * $right;
            $y += $size * $up;
            $rest = int($rest / 4);
        }
        push @path, [ $x, $y ];
    }
    return @path;
}

sub hilbert_canvas { return grid_path_canvas([ hilbert_path(4) ], 6) }

# Turns a point [x, y] counterclockwise about the origin by whole quarter
# turns (negative for clockwise).
sub rotate_quarter_turns {
    my ($point, $turns) = @_;
    my ($x, $y) = @$point;
    ($x, $y) = (-$y, $x) for 1 .. $turns % 4;
    return [ $x, $y ];
}

# The dragon scaled to fill the frame, drawn as a thin glowing line whose hue
# runs along the strip from one end to the other. Each fold turns the dragon
# 45 degrees, so it's turned back a quarter turn per two folds to lie wide.
my $DRAGON_FOLDS = 8;

sub dragon_canvas {
    return grid_path_canvas([ map { rotate_quarter_turns($_, -$DRAGON_FOLDS / 2) } dragon_path($DRAGON_FOLDS) ], 6);
}

# Draws a path of [x, y] points on a whole-number grid as a thin glowing line,
# centered, with its hue running from one end to the other. A grid unit is
# $scale pixels across and half as many rows down, which is square since
# pixels are twice as tall as wide. $scale should be even: keeping it and the
# margins whole numbers puts every corner of the path on a pixel center.
# Otherwise a thin horizontal line can fall between two rows and vanish from
# both.
sub grid_path_canvas {
    my ($path, $scale) = @_;
    my @path = @$path;
    my ($pixel_cols, $pixel_rows) = (140, 48);
    my @xs = map { $_->[0] } @path;
    my @ys = map { $_->[1] } @path;
    my ($min_x, $max_x) = (List::Util::min(@xs), List::Util::max(@xs));
    my ($min_y, $max_y) = (List::Util::min(@ys), List::Util::max(@ys));
    my $left  = int(($pixel_cols - $scale * ($max_x - $min_x)) / 2);
    my $top   = int(($pixel_rows - $scale / 2 * ($max_y - $min_y)) / 2);

    # Several points per segment so the line has no gaps.
    my @points;
    for my $i (1 .. $#path) {
        my ($from, $to) = @path[ $i - 1, $i ];
        for my $step (0 .. 3) {
            my $x = $from->[0] + ($to->[0] - $from->[0]) * $step / 4;
            my $y = $from->[1] + ($to->[1] - $from->[1]) * $step / 4;
            push @points, [ $top + ($max_y - $y) * $scale / 2, $left + ($x - $min_x) * $scale, $i / $#path ];
        }
    }
    return glow_lines_canvas(\@points, \@ZETA_HUES, 0.5);
}

# Whether the binomial coefficient C(n, k) is odd. By Lucas's theorem it is
# exactly when every bit set in k is also set in n.
sub binomial_is_odd {
    my ($n, $k) = @_;
    return ($n & $k) == $k;
}

# Pascal's triangle with the odd entries lit and the even ones faint, which
# draws the Sierpinski triangle: holes inside holes, all the way down. Each
# entry is two pixels wide so it comes out square, and each row is shifted
# half an entry from the last so the triangle stays centered.
my @PASCAL_HUES = (
    [ 0,   120, 255, 255 ],
    [ 0.4, 60,  120, 255 ],
    [ 0.7, 160, 60,  255 ],
    [ 1,   255, 60,  180 ],
);

sub pascal_canvas {
    my ($pixel_cols, $rows) = (140, 48);
    my @palette = gradient_palette(\@PASCAL_HUES);
    my @pixels  = map { [ ($BLACK) x $pixel_cols ] } 1 .. $rows;
    for my $n (0 .. $rows - 1) {
        my $odd_color = nearest_color_in(\@palette, gradient_rgb(\@PASCAL_HUES, $n / ($rows - 1)));
        for my $k (0 .. $n) {
            my $col = $pixel_cols / 2 - 1 - $n + 2 * $k;
            @{ $pixels[$n] }[ $col, $col + 1 ] = (binomial_is_odd($n, $k) ? $odd_color : 90) x 2;
        }
    }
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0, 1, 'C(n, k) mod 2', 97);
    put_text($canvas, 1, 1, 'odd entries lit', 94);
    return $canvas;
}

# The Lorenz system, dx/dt = 10(y - x), dy/dt = x(28 - z) - y,
# dz/dt = xy - 8z/3: a simplified model of convection that never settles and
# never repeats, looping around two wings in an order nobody can predict.
sub lorenz_velocity {
    my ($x, $y, $z) = @_;
    return (10 * ($y - $x), $x * (28 - $z) - $y, $x * $y - 8 / 3 * $z);
}

# $count points along the attractor, as [x, y, z], by fourth-order
# Runge-Kutta. The steps are small enough that consecutive points land about a
# pixel apart in the drawing. The first stretch is dropped, because the start
# at (1, 1, 1) is a transient that isn't on the attractor yet.
sub lorenz_points {
    my ($count) = @_;
    my $dt     = 0.005;
    my $settle = 4000;
    my @p      = (1, 1, 1);
    my @points;
    for my $step (1 .. $settle + $count) {
        my @k1 = lorenz_velocity(@p);
        my @k2 = lorenz_velocity(map { $p[$_] + $dt / 2 * $k1[$_] } 0 .. 2);
        my @k3 = lorenz_velocity(map { $p[$_] + $dt / 2 * $k2[$_] } 0 .. 2);
        my @k4 = lorenz_velocity(map { $p[$_] + $dt * $k3[$_] } 0 .. 2);
        @p = map { $p[$_] + $dt / 6 * ($k1[$_] + 2 * $k2[$_] + 2 * $k3[$_] + $k4[$_]) } 0 .. 2;
        push @points, [@p] if $step > $settle;
    }
    return @points;
}

# Seen from the side (x across, z up) the attractor is a butterfly. The color
# follows time, from blue at the start to red at the end, so you can trace the
# path as it switches wings. Too long a path fills the wings solid, so it's
# only a dozen or so loops.
my @LORENZ_HUES = (
    [ 0,    0,   60,  255 ],
    [ 0.3,  0,   220, 255 ],
    [ 0.5,  255, 255, 255 ],
    [ 0.7,  255, 200, 0 ],
    [ 1,    255, 70,  0 ],
);

sub lorenz_canvas {
    my ($cols, $pixel_rows) = (70, 48);

    # z runs from about 0 to 50 up the full height; pixels are twice as tall
    # as wide.
    my $step = 50 / (2 * $pixel_rows);
    my @rgb  = map { [ map { [ 0, 0, 0 ] } 1 .. 2 * $cols ] } 1 .. $pixel_rows;
    my @path   = lorenz_points(3000);
    my @points = map {
        my ($x, undef, $z) = @{ $path[$_] };
        [ (50 - $z) / (2 * $step) - 0.5, $x / $step + $cols - 0.5, $_ / $#path ];
    } 0 .. $#path;
    draw_glow_curve(\@rgb, \@points, \@LORENZ_HUES);

    my $canvas = pixels_to_canvas([ map { [ map { nearest_color(@$_) } @$_ ] } @rgb ]);
    put_text($canvas, 21, 1, 'dx/dt = 10(y - x)',     95);
    put_text($canvas, 22, 1, 'dy/dt = x(28 - z) - y', 95);
    put_text($canvas, 23, 1, 'dz/dt = xy - 8z/3',     95);
    return $canvas;
}

# Follows z -> z^2 + c from the starting z given. If z runs away within
# $max_steps, returns how long it took; otherwise returns nothing. The step
# count is smoothed (the standard n + 1 - log2(log|z|) trick with a big escape
# radius) so colors blend instead of falling into bands.
#
# The Mandelbrot set starts every c from z = 0; a Julia set fixes c and starts
# from each point. With $fold set, z is folded into the first quadrant
# (|Re z| + i|Im z|) before squaring, which makes the Burning Ship. Folding only
# changes the sign of the 2xy term, so that's all it touches.
sub escape_time {
    my ($x, $y, $cx, $cy, $max_steps, $fold) = @_;

    # Bounded orbits settle into a cycle. We remember z at steps 1, 2, 4,
    # 8, ... and if z ever comes back to the remembered value, it's caught in a
    # loop and will never escape. Without this, every such point burns all
    # $max_steps.
    my ($seen_x, $seen_y, $next_check) = ($x, $y, 1);
    for my $step (1 .. $max_steps) {
        my $xy = $fold ? abs($x * $y) : $x * $y;
        ($x, $y) = ($x * $x - $y * $y + $cx, 2 * $xy + $cy);
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

sub mandelbrot_escape {
    my ($cx, $cy, $max_steps) = @_;

    # Points in the main cardioid and the big bulb to its left never escape,
    # and they're the slowest to check by iterating, so catch them up front.
    my $q = ($cx - 0.25)**2 + $cy**2;
    return if $q * ($q + $cx - 0.25) <= $cy**2 / 4;
    return if ($cx + 1)**2 + $cy**2 <= 1 / 16;

    return escape_time(0, 0, $cx, $cy, $max_steps);
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
    return escape_view(%view, glow => \@MANDELBROT_GLOW, escape => sub { mandelbrot_escape(@_, $view{max_steps}) });
}

# Draws any escape-time fractal. escape is called with a point's (x, y) and
# returns its escape time, or nothing if it stays bounded; glow is the gradient
# that escape times from glow_from to glow_to are spread over. Escape time goes
# through log so the glow brightens at a steady pace from the far field in.
sub escape_view {
    my (%view) = @_;
    my $glow_from = log $view{glow_from};
    my $glow_span = log($view{glow_to}) - $glow_from;
    return sampled_view(
        %view,
        palette => [ gradient_palette($view{glow}) ],
        blur    => 1,
        color   => sub {
            my ($steps) = $view{escape}->(@_);
            return defined $steps ? [ gradient_rgb($view{glow}, (log($steps) - $glow_from) / $glow_span) ] : undef;
        },
    );
}

# Draws a window onto the complex plane, given its center and half its height,
# by calling color with each sample point's (x, y). It returns an [r, g, b]
# color, or undef for points that belong to the black of a set.
#
# Each pixel takes a 3x3 grid of samples and is black when most of them are.
# Otherwise it's the average color of the rest, which smooths over detail
# finer than a pixel without mixing in black and going gray. Colors snap to
# the given palette.
#
# With blur on, each colored pixel is also averaged with its colored
# neighbors. Zoomed into a fractal, the boundary has detail far finer than a
# pixel and neighbors flicker between bright and dark, which is noise to the
# eye and costs a color code per flicker.
sub sampled_view {
    my (%view) = @_;
    my ($center_x, $center_y, $half_height) = @view{qw(center_x center_y half_height)};
    my $pixel_rows = 2 * $MANDELBROT_ROWS;
    my $pixel_cols = 2 * $MANDELBROT_COLS;
    my $step_y     = 2 * $half_height / $pixel_rows;

    # A quadrant pixel is half a cell wide and half a cell tall, and cells are
    # twice as tall as wide, so pixels are twice as tall as wide too.
    my $step_x = $step_y / 2;

    my @offsets = map { my $dy = $_; map { [ $_, $dy ] } 1 / 6, 1 / 2, 5 / 6 } 1 / 6, 1 / 2, 5 / 6;
    my @rgb;
    for my $r (0 .. $pixel_rows - 1) {
        push @rgb, [ map {
            my $c = $_;
            my @colors = grep { defined } map {
                my ($dx, $dy) = @$_;
                $view{color}->(
                    $center_x + ($c + $dx - $pixel_cols / 2) * $step_x,
                    $center_y + $half_height - ($r + $dy) * $step_y,
                );
            } @offsets;
            @colors * 2 <= @offsets ? undef : average_rgb(@colors);
        } 0 .. $pixel_cols - 1 ];
    }

    my @pixels;
    for my $r (0 .. $pixel_rows - 1) {
        push @pixels, [ map {
            my $c = $_;
            if (!$rgb[$r][$c]) {
                $BLACK;
            } elsif (!$view{blur}) {
                nearest_color_in($view{palette}, @{ $rgb[$r][$c] });
            } else {
                my @near = grep { $_ } map {
                    my $nr = $_;
                    map { $nr >= 0 && $nr < $pixel_rows && $_ >= 0 && $_ < $pixel_cols ? $rgb[$nr][$_] : undef } $c - 1 .. $c + 1;
                } $r - 1 .. $r + 1;
                nearest_color_in($view{palette}, @{ average_rgb(@near) });
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

# The Julia set for c = -0.123 + 0.745i, known as Douady's rabbit: a body with
# two ears at every scale, because the critical point cycles with period 3.
# It starts on palette color 25, a deep purple, because the blends between
# black and purple have no good match in the palette and land on gray.
my @JULIA_GLOW = (
    [ 0,    46,  0,   71 ],
    [ 0.35, 75,  0,   116 ],
    [ 0.6,  150, 30,  200 ],
    [ 0.8,  255, 120, 220 ],
    [ 0.92, 255, 230, 250 ],
    [ 1,    255, 255, 180 ],
);

sub julia_canvas {
    my ($cx, $cy) = (-0.123, 0.745);
    my $canvas = escape_view(
        center_x  => 0, center_y => 0, half_height => 1.15,
        glow_from => 2, glow_to  => 30, glow => \@JULIA_GLOW,
        escape    => sub { escape_time(@_, $cx, $cy, 300) },
    );
    put_text($canvas, 22, 1, "z -> z^2 + c, c = $cx + ${cy}i", 97);
    return $canvas;
}

our %PIECES = (
    mandelbrot => { draw => \&mandelbrot_canvas, about => 'the whole Mandelbrot set, glowing toward its edge' },
    seahorse   => { draw => \&seahorse_canvas,   about => 'a seahorse tail in Seahorse Valley, 600 times closer' },
    zeta       => { draw => \&zeta_canvas,       about => 'the path of zeta(1/2 + it) through its first three zeros' },
    julia      => { draw => \&julia_canvas,      about => 'the Julia set called Douady\'s rabbit, ears within ears' },
    lorenz     => { draw => \&lorenz_canvas,     about => 'the Lorenz attractor, the butterfly of chaos' },
    newton     => { draw => \&newton_canvas,     about => 'Newton\'s method on z^3 - 1, three basins with a fractal border' },
    ulam       => { draw => \&ulam_canvas,       about => 'the Ulam spiral, where the primes line up on diagonals' },
    burningship => { draw => \&burningship_canvas, about => 'the Burning Ship fractal, z^2 + c with the orbit folded' },
    dragon     => { draw => \&dragon_canvas,     about => 'the Heighway dragon, a strip of paper folded in half eight times' },
    piwalk     => { draw => \&piwalk_canvas,     about => 'a walk steered by the first thousand digits of pi' },
    phase      => { draw => \&phase_canvas,      about => 'a phase portrait: zeros and poles of a complex function as color pinwheels' },
    buddhabrot => { draw => \&buddhabrot_canvas, about => 'the Buddhabrot: the paths of every point that escapes the Mandelbrot set' },
    logistic   => { draw => \&logistic_canvas,   about => 'the logistic map doubling its period over and over until it turns to chaos' },
    apollonian => { draw => \&apollonian_canvas, about => 'the Apollonian gasket, every gap between circles filled with another circle' },
    collatz    => { draw => \&collatz_canvas,    about => 'the Collatz coral: every trip down to 1, bending left on even, right on odd' },
    timestable => { draw => \&timestable_canvas, about => 'times tables drawn on a circle, where a cardioid and a nephroid appear' },
    koch       => { draw => \&koch_canvas,       about => 'the Koch snowflake, an infinitely long edge around a finite area' },
    chladni    => { draw => \&chladni_canvas,    about => 'sand on a ringing metal plate, gathered on the lines that stand still' },
    harmonograph => { draw => \&harmonograph_canvas, about => 'two damped pendulums drawing on paper, spiraling in as they tire' },
    sunflower  => { draw => \&sunflower_canvas,  about => 'seeds placed by the golden angle, falling into Fibonacci spirals' },
    hilbert    => { draw => \&hilbert_canvas,    about => 'the Hilbert curve, one line through all 256 squares of a grid' },
    fern       => { draw => \&fern_canvas,       about => 'Barnsley\'s fern, grown from four random affine maps' },
    pascal     => { draw => \&pascal_canvas,     about => 'Pascal\'s triangle mod 2, which turns out to be Sierpinski\'s' },
);

sub piece_list { return join ' ', sort keys %PIECES }

sub piece_descriptions {
    my $width = 2 + List::Util::max(map { length } keys %PIECES);
    return map { sprintf '%-*s%s', $width, $_, $PIECES{$_}{about} } sort keys %PIECES;
}

my @USAGE = (
    'usage: /math              list the pieces',
    '       /math -l           list the pieces with what each one is',
    '       /math -h           show this help',
    '       /math <piece>      send a piece to this channel or query',
    '       /math -p <piece>   preview a piece here without sending it',
);

# Prints a line in the window the command came from, or in irssi's own
# window (usually the status window) when it didn't come from a channel or
# query.
sub show {
    my ($witem, $text, $level) = @_;
    $level //= MSGLEVEL_CLIENTCRAP;
    if ($witem) {
        $witem->print("math: $text", $level);
    } else {
        Irssi::print("math: $text", $level);
    }
}

# Drawing a piece can take seconds, and irssi would freeze for all of it, so it
# happens in a forked child that writes the finished lines back through a pipe.
# Each piece is drawn once per session and kept in %RENDERED. Anyone asking for
# a piece while it's being drawn waits in %drawing and gets it when it's done.
our %RENDERED;
my %drawing;

sub cmd_math {
    my ($data, $server, $witem) = @_;

    my $name = $data;
    $name =~ s/^\s+|\s+$//g;
    my $preview = $name =~ s/^-p\s+//;

    # Listing and help don't need a channel, so they work from any window,
    # the status window included.
    if ($name eq '') {
        show($witem, 'pieces: ' . piece_list());
        return;
    }
    if ($name eq '-l') {
        show($witem, $_) for piece_descriptions();
        return;
    }
    if ($name eq '-h') {
        show($witem, $_) for @USAGE;
        return;
    }
    if ($name =~ /^-/) {
        show($witem, qq{unknown option "$name"}, MSGLEVEL_CLIENTERROR);
        show($witem, $_) for @USAGE;
        return;
    }

    if (!$witem) {
        Irssi::print('math: not in a channel or query window', MSGLEVEL_CLIENTERROR);
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
        my @lines = eval { irc_lines($PIECES{$name}{draw}->()) };
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
