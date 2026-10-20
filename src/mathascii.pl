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
#        /math -r           sends a random piece (or --random)
#        /math -p -r        previews a random piece
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
#
# Points of a curve in 3D can carry a fourth number, how near the viewer they
# are. A strand clearly nearer than another takes over every pixel its glow
# reaches, so where it crosses in front, the one behind breaks off with a dark
# gap on either side, the way knots are drawn.
my $GLOW_DEPTH_MARGIN = 0.5;

sub draw_glow_curve {
    my ($rgb, $points, $hues, $width) = @_;
    $width //= 1;
    my $reach = $GLOW_REACH * $width;
    my ($rows, $cols) = (scalar @$rgb, scalar @{ $rgb->[0] });
    my (%distance, %position_at, %depth_at);
    for my $point (@$points) {
        my ($row, $col, $position, $depth) = @$point;
        $depth //= 0;
        for my $r (POSIX::ceil($row - $reach / 2) .. POSIX::floor($row + $reach / 2)) {
            next if $r < 0 || $r >= $rows;
            for my $c (POSIX::ceil($col - $reach) .. POSIX::floor($col + $reach)) {
                next if $c < 0 || $c >= $cols;
                my $d = sqrt(($c - $col)**2 + (2 * ($r - $row))**2) / $width;
                if (exists $distance{"$r,$c"}) {
                    my $nearer = $depth - $depth_at{"$r,$c"};
                    next if $nearer < -$GLOW_DEPTH_MARGIN || ($nearer <= $GLOW_DEPTH_MARGIN && $distance{"$r,$c"} <= $d);
                }
                $distance{"$r,$c"}    = $d;
                $position_at{"$r,$c"} = $position;
                $depth_at{"$r,$c"}    = $depth;
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

# Fills a convex polygon, its corners [row, col] in fractional pixels in
# order round it, with one RGB color on a grid of RGB pixels. A pixel is in
# when its center is on the inner side of every edge, or right on one.
sub fill_polygon {
    my ($rgb, $corners, $color) = @_;
    my ($rows, $cols) = (scalar @$rgb, scalar @{ $rgb->[0] });
    my $inside = sub {
        my ($r, $c) = @_;
        my @sides = map {
            my ($from, $to) = @$corners[ $_, ($_ + 1) % @$corners ];
            ($to->[1] - $from->[1]) * ($r - $from->[0]) - ($to->[0] - $from->[0]) * ($c - $from->[1]);
        } 0 .. $#$corners;
        return !(grep { $_ < 0 } @sides) || !(grep { $_ > 0 } @sides);
    };
    for my $r (POSIX::ceil(List::Util::min(map { $_->[0] } @$corners)) .. POSIX::floor(List::Util::max(map { $_->[0] } @$corners))) {
        next if $r < 0 || $r >= $rows;
        for my $c (POSIX::ceil(List::Util::min(map { $_->[1] } @$corners)) .. POSIX::floor(List::Util::max(map { $_->[1] } @$corners))) {
            next if $c < 0 || $c >= $cols;
            $rgb->[$r][$c] = [@$color] if $inside->($r, $c);
        }
    }
}

# Sets the pixel nearest each [row, col] point to one RGB color, for hard
# one-pixel lines such as borders.
sub paint_points {
    my ($rgb, $points, $color) = @_;
    my ($rows, $cols) = (scalar @$rgb, scalar @{ $rgb->[0] });
    for my $point (@$points) {
        my ($r, $c) = map { POSIX::floor($_ + 0.5) } @$point[ 0, 1 ];
        $rgb->[$r][$c] = [@$color] if $r >= 0 && $r < $rows && $c >= 0 && $c < $cols;
    }
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

# A Clifford attractor: x -> sin(a y) + c cos(a x), y -> sin(b x) + d cos(b y).
# The point never settles and never repeats, but it stays on a fine, folded
# veil, and piling up enough points draws the veil like smoke. Returns
# $count points [x, y], after letting it settle for a moment from (0, 0).
my ($CLIFFORD_A, $CLIFFORD_B, $CLIFFORD_C, $CLIFFORD_D) = (-1.4, 1.6, 1, 0.7);

sub clifford_points {
    my ($count) = @_;
    my ($x, $y) = (0, 0);
    my @points;
    for my $step (1 .. 100 + $count) {
        ($x, $y) = (sin($CLIFFORD_A * $y) + $CLIFFORD_C * cos($CLIFFORD_A * $x), sin($CLIFFORD_B * $x) + $CLIFFORD_D * cos($CLIFFORD_B * $y));
        push @points, [ $x, $y ] if $step > 100;
    }
    return @points;
}

# Colored by how often the point lands on each pixel, teal to white, with
# the stops on palette colors (22, 34, 46, 70, 98) so blends don't go gray.
my @CLIFFORD_GLOW = (
    [ 0,    0,   71,  71 ],
    [ 0.3,  0,   116, 116 ],
    [ 0.6,  0,   181, 181 ],
    [ 0.85, 109, 255, 255 ],
    [ 1,    255, 255, 255 ],
);

sub clifford_canvas {
    my %hits;
    for my $point (clifford_points(150_000)) {
        my ($row, $col) = @{ centered_pixel(@$point, 28) };
        $hits{ POSIX::floor($row + 0.5) . ',' . POSIX::floor($col + 0.5) }++;
    }
    return density_canvas(\%hits, \@CLIFFORD_GLOW, 0.98, 0.5);
}

sub gcd {
    my ($a, $b) = @_;
    ($a, $b) = ($b, $a % $b) while $b;
    return $a;
}

# A spirograph (a hypotrochoid): a gear of radius $r rolls round inside a ring
# of radius $R, and the pen sits $d from the gear's center. The gear is back
# where it started, facing the same way, after r / gcd(R, r) trips round the
# ring, so that's where the curve closes. Returns $steps + 1 points [x, y]
# evenly along the whole closed curve.
sub spirograph_points {
    my ($R, $r, $d, $steps) = @_;
    my $turns = 8 * atan2(1, 1) * $r / gcd($R, $r);
    return map {
        my $t = $turns * $_ / $steps;
        [ ($R - $r) * cos($t) + $d * cos(($R - $r) / $r * $t), ($R - $r) * sin($t) - $d * sin(($R - $r) / $r * $t) ];
    } 0 .. $steps;
}

# A gear of 5 in a ring of 8, drawn as a glowing line whose hue runs once
# round the rainbow over the whole curve. With the pen right at the gear's rim
# it's a sharp star; a little way in, the points open into loops.
sub spirograph_canvas {
    my ($R, $r, $d) = (8, 5, 3);
    my @path   = map { centered_pixel(@$_, 46 / ($R - $r + $d)) } spirograph_points($R, $r, $d, 3000);
    my @points = map { line_points(@path[ $_ - 1, $_ ], $_ / $#path) } 1 .. $#path;
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.5);
    put_text($canvas, 0, 1, "ring $R, gear $r, pen $d",            97);
    put_text($canvas, 1, 1, "closes after $r trips",              94);
    return $canvas;
}

# Conway's Game of Life on an unbounded board, kept as a hash of the live
# cells by "x,y". A live cell survives with two or three live neighbors, and
# a dead one comes alive with exactly three.
sub life_step {
    my ($alive) = @_;
    my %neighbors;
    for my $cell (keys %$alive) {
        my ($x, $y) = split /,/, $cell;
        for my $dx (-1 .. 1) {
            for my $dy (-1 .. 1) {
                $neighbors{ ($x + $dx) . ',' . ($y + $dy) }++ if $dx || $dy;
            }
        }
    }
    return { map { ($_ => 1) } grep { $neighbors{$_} == 3 || ($neighbors{$_} == 2 && $alive->{$_}) } keys %neighbors };
}

# Reads a pattern in RLE, the run-length format Life patterns are shared in:
# b is a dead cell, o a live one, $ ends a row, a number repeats what follows,
# and ! ends the pattern. Returns the live cells as [x, y], y counting down.
sub rle_cells {
    my ($rle) = @_;
    my ($x, $y) = (0, 0);
    my @cells;
    while ($rle =~ /(\d*)([bo\$!])/g) {
        my ($run, $what) = ($1 || 1, $2);
        last if $what eq '!';
        if ($what eq '$') {
            ($x, $y) = (0, $y + $run);
        } else {
            push @cells, map { [ $x + $_, $y ] } 0 .. $run - 1 if $what eq 'o';
            $x += $run;
        }
    }
    return @cells;
}

# Bill Gosper's glider gun, the first pattern found that grows forever: it
# fires a glider every 30 generations.
our $GOSPER_GUN = '24bo$22bobo$12b2o6b2o12b2o$11bo3bo4b2o12b2o$2o8bo5bo3b2o$2o8bo3bob2o4bobo$10bo5bo7bo$11bo3bo$12b2o!';

# The gun after a few hundred generations, with a stream of gliders heading
# off down the frame. Each cell is two pixels wide so it draws square, and
# cells leave a fading trail for the last few generations they were alive,
# so you can see which way everything is moving.
my @LIFE_TRAIL = (
    [ 0,   0,   0,   71 ],
    [ 0.5, 0,   99,  181 ],
    [ 0.8, 0,   255, 255 ],
    [ 1,   255, 255, 255 ],
);

sub life_canvas {
    my ($cols, $rows, $trail) = (70, 48, 8);
    my $alive = { map { (($_->[0] + 2) . ',' . ($_->[1] + 2) => 1) } rle_cells($GOSPER_GUN) };
    my %last_seen;
    for my $generation (1 .. 240) {
        $alive = life_step($alive);
        $last_seen{$_} = $generation for keys %$alive;
    }
    my @palette = gradient_palette(\@LIFE_TRAIL);
    my @pixels  = map {
        my $y = $_;
        [ map {
            my $age = 240 - ($last_seen{"$_,$y"} // -1000);
            ($age < $trail ? nearest_color_in(\@palette, gradient_rgb(\@LIFE_TRAIL, 1 - $age / $trail)) : $BLACK) x 2;
        } 0 .. $cols - 1 ];
    } 0 .. $rows - 1;
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 22, 1, "Gosper's glider gun:",         97);
    put_text($canvas, 23, 1, 'a glider every 30 generations', 94);
    return $canvas;
}

# The Abelian sandpile: any square holding four or more grains topples,
# sending one grain to each of its four neighbors, and grains pushed off the
# edge are lost. Topples $grid (a square list of rows of grain counts) in
# place until it settles. The order squares topple in never changes where it
# settles, which is why it's called Abelian, so we topple a whole stack of
# fours at a time.
sub topple {
    my ($grid) = @_;
    my $size  = @$grid;
    my @queue = grep { $grid->[ $_->[0] ][ $_->[1] ] > 3 } map { my $r = $_; map { [ $r, $_ ] } 0 .. $size - 1 } 0 .. $size - 1;
    while (my $square = shift @queue) {
        my ($r, $c) = @$square;
        my $falls = int($grid->[$r][$c] / 4) or next;
        $grid->[$r][$c] -= 4 * $falls;
        for ([ $r - 1, $c ], [ $r + 1, $c ], [ $r, $c - 1 ], [ $r, $c + 1 ]) {
            my ($nr, $nc) = @$_;
            next if $nr < 0 || $nc < 0 || $nr >= $size || $nc >= $size;
            push @queue, [ $nr, $nc ] if $grid->[$nr][$nc] < 4 && $grid->[$nr][$nc] + $falls > 3;
            $grid->[$nr][$nc] += $falls;
        }
    }
    return $grid;
}

# $grains dropped on the middle of a $size by $size grid, once it settles.
sub sandpile {
    my ($grains, $size) = @_;
    my @grid = map { [ (0) x $size ] } 1 .. $size;
    $grid[ int($size / 2) ][ int($size / 2) ] = $grains;
    return topple(\@grid);
}

# Every square of the settled pile colored by how many grains it holds, which
# draws a pattern of nested triangles and stripes nobody has fully explained.
# Each square is two pixels wide so it draws square, and squares no grain
# ever reached stay black. The grid has a middle square, so it's one row
# short of the frame, and the pile is small enough that no grain falls off.
my @SANDPILE_COLORS = (24, 47, 58, 54);
our ($SANDPILE_GRAINS, $SANDPILE_SIZE) = (3500, 47);

sub sandpile_canvas {
    my $pile   = sandpile($SANDPILE_GRAINS, $SANDPILE_SIZE);
    my $margin = (70 - $SANDPILE_SIZE + 1) / 2;
    my @pixels = map {
        my $row     = $pile->[$_];
        my @reached = grep { $row->[$_] } 0 .. $SANDPILE_SIZE - 1;
        [ map {
            my $c = $_ - $margin;
            (@reached && $c >= $reached[0] && $c <= $reached[-1] ? $SANDPILE_COLORS[ $row->[$c] ] : $BLACK) x 2;
        } 0 .. 69 ];
    } 0 .. $SANDPILE_SIZE - 1;
    push @pixels, [ ($BLACK) x 140 ];
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0,  1, "$SANDPILE_GRAINS grains of sand", 97);
    put_text($canvas, 1,  1, 'dropped on one square',    94);
    put_text($canvas, 22, 1, 'four in a pile topple',     94);
    put_text($canvas, 23, 1, 'one to each neighbor',      94);
    return $canvas;
}

# Langton's ant walks a grid of white squares: on a white square it turns
# right, on a black one left, and either way it flips the square's color and
# steps forward. Squares are "x,y" with y counting down the screen, and the
# heading counts quarter turns clockwise from up. Returns where the ant ends
# up after $steps, the black squares, and the step that last flipped each
# square.
my @ANT_MOVES = ([ 0, -1 ], [ 1, 0 ], [ 0, 1 ], [ -1, 0 ]);

sub langton_ant {
    my ($steps) = @_;
    my ($x, $y, $heading) = (0, 0, 0);
    my (%black, %painted);
    for my $step (1 .. $steps) {
        my $square = "$x,$y";
        if ($black{$square}) {
            $heading = ($heading + 3) % 4;
            delete $black{$square};
        } else {
            $heading = ($heading + 1) % 4;
            $black{$square} = 1;
        }
        $painted{$square} = $step;
        $x += $ANT_MOVES[$heading][0];
        $y += $ANT_MOVES[$heading][1];
    }
    return { x => $x, y => $y, heading => $heading, black => \%black, painted => \%painted };
}

# The ant's mess with the highway running out of it. Black squares are
# colored by how long ago the ant painted them, so the highway it's building
# now is brightest. Each square is two pixels wide so it draws square.
my @LANGTON_AGE = (
    [ 0,   46, 0,   71 ],
    [ 0.5, 117, 0,   181 ],
    [ 0.8, 255, 0,   152 ],
    [ 1,   255, 156, 211 ],
);

sub langton_canvas {
    my $steps   = 11_000;
    my $ant     = langton_ant($steps);
    my @palette = gradient_palette(\@LANGTON_AGE);
    my @squares = map { [ split /,/ ] } keys %{ $ant->{black} };
    my $left    = POSIX::floor((List::Util::min(map { $_->[0] } @squares) + List::Util::max(map { $_->[0] } @squares)) / 2) - 35;
    my $top     = POSIX::floor((List::Util::min(map { $_->[1] } @squares) + List::Util::max(map { $_->[1] } @squares)) / 2) - 24;
    my @pixels  = map {
        my $y = $top + $_;
        [ map {
            my $square = ($left + $_) . ",$y";
            ($ant->{black}{$square} ? nearest_color_in(\@palette, gradient_rgb(\@LANGTON_AGE, $ant->{painted}{$square} / $steps)) : $BLACK) x 2;
        } 0 .. 69 ];
    } 0 .. 47;
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0, 1, 'Langton\'s ant:', 97);
    put_text($canvas, 1, 1, 'white: turn right', 94);
    put_text($canvas, 2, 1, 'black: turn left', 94);
    put_text($canvas, 22, 1, 'after 10,000 steps', 94);
    put_text($canvas, 23, 1, 'it builds a highway', 94);
    return $canvas;
}

# The Lyapunov exponent of the logistic map x -> r x (1 - x) when r takes
# turns between two values: the letters of $sequence, repeated forever, say
# whether each step uses $a or $b. The exponent is the average log of how
# much each step stretches the gap between two nearby points, the slope
# r (1 - 2x). Below zero, nearby points get pulled together and the orbit
# settles into a cycle; above zero they get pushed apart, which is chaos. We
# skip the first steps so the orbit has time to settle, and start from 0.4
# because 0.5 lands on 1 and then 0 for good when r is 4.
my $LYAPUNOV_SETTLE = 300;

sub lyapunov_exponent {
    my ($sequence, $a, $b, $count) = @_;
    my @r = map { $_ eq 'A' ? $a : $b } split //, $sequence;
    my ($x, $total) = (0.4, 0);
    for my $step (0 .. $LYAPUNOV_SETTLE + $count - 1) {
        my $r = $r[ $step % @r ];
        # A slope of exactly zero would mean an exponent of minus infinity.
        $total += log(List::Util::max(abs($r * (1 - 2 * $x)), 1e-12)) if $step >= $LYAPUNOV_SETTLE;
        $x = $r * $x * (1 - $x);
    }
    return $total / $count;
}

# Mario Markus's picture: every pixel is a pair (a, b), gold where the orbit
# settles into a cycle, brighter the more firmly, and black where it's chaos.
# Orbits right at the edge of chaos have an exponent near zero, which shows
# up dark either way, so the edge doesn't sparkle.
my @LYAPUNOV_ORDER = (
    [ 0,    71,  33,  0 ],
    [ 0.2,  116, 58,  0 ],
    [ 0.4,  181, 99,  0 ],
    [ 0.6,  255, 140, 0 ],
    [ 0.85, 255, 255, 0 ],
    [ 1,    255, 255, 255 ],
);
sub lyapunov_canvas {
    my ($sequence, $a_min, $a_max, $b_min, $b_max) = ('AB', 2, 4, 2.6, 4);
    my @order = gradient_palette(\@LYAPUNOV_ORDER);
    my @pixels = map {
        my $b = $b_max - ($_ + 0.5) / 48 * ($b_max - $b_min);
        [ map {
            my $a = $a_min + ($_ + 0.5) / 140 * ($a_max - $a_min);
            my $exponent = lyapunov_exponent($sequence, $a, $b, 200);
            $exponent < 0
                ? nearest_color_in(\@order, gradient_rgb(\@LYAPUNOV_ORDER, -$exponent / 1.5))
                : $BLACK;
        } 0 .. 139 ];
    } 0 .. 47;
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 20, 56, 'x -> rx(1 - x)', 97);
    put_text($canvas, 21, 56, 'r: a,b,a,b,...', 94);
    put_text($canvas, 22, 56, 'gold: order',    94);
    put_text($canvas, 23, 56, 'black: chaos',   94);
    return $canvas;
}

# The fractions from 0/1 to 1/1 in lowest terms with denominators up to $n,
# in order, as [p, q]. Each one comes from the two before it: after a/b and
# c/d, the next is (kc - a)/(kd - b) with k = floor((n + b) / d).
sub farey {
    my ($n) = @_;
    my ($a, $b, $c, $d) = (0, 1, 1, $n);
    my @fractions = ([ $a, $b ]);
    while ($c <= $n) {
        push @fractions, [ $c, $d ];
        my $k = int(($n + $b) / $d);
        ($a, $b, $c, $d) = ($c, $d, $k * $c - $a, $k * $d - $b);
    }
    return @fractions;
}

# Lester Ford's circle for p/q: it sits on the number line at p/q with
# radius 1/(2q^2). Returns [x, y, radius] of its center.
sub ford_circle {
    my ($p, $q) = @_;
    my $radius = 1 / (2 * $q * $q);
    return [ $p / $q, $radius, $radius ];
}

# The fractions between 1/4 and 3/4 each get a circle, drawn as a glowing
# ring, the color running from blue for the big ones down to red for the
# dust along the line. Small denominators are rare and big ones common, so
# the color goes by the log of the denominator to spread the hues out.
# Denominators stop where the rings have shrunk to dots.
my @FORD_HUES = (
    [ 0,   0,   140, 255 ],
    [ 0.3, 0,   255, 255 ],
    [ 0.5, 0,   255, 0 ],
    [ 0.7, 255, 255, 0 ],
    [ 1,   255, 0,   0 ],
);

sub ford_canvas {
    my $most   = 24;
    my $scale  = 280;
    my $pixel  = sub { [ 46 - $_[1] * $scale / 2, ($_[0] - 0.25) * $scale - 0.5 ] };
    my @points;
    for my $fraction (farey($most)) {
        my ($x, $y, $radius) = @{ ford_circle(@$fraction) };
        my $hue   = log($fraction->[1]) / log($most);
        my $steps = List::Util::max(12, POSIX::ceil(4 * 3.14159 * $radius * $scale));
        my @ring  = map {
            my $angle = 8 * atan2(1, 1) * $_ / $steps;
            $pixel->($x + $radius * cos($angle), $y + $radius * sin($angle));
        } 0 .. $steps;
        push @points, map { line_points(@ring[ $_ - 1, $_ ], $hue) } 1 .. $#ring;
    }
    my $canvas = glow_lines_canvas(\@points, \@FORD_HUES, 0.5);
    put_text($canvas, 0, 1, 'Ford circles:',             97);
    put_text($canvas, 1, 1, 'one on every fraction p/q', 94);
    put_text($canvas, 2, 1, 'radius 1/(2q^2)',           94);
    put_text($canvas, 3, 1, 'neighbors always touch',    94);
    return $canvas;
}

# Fibonacci squares spiraling out: start with a unit square, then keep
# adding a square on the next side round (right, top, left, bottom, ...) of
# the rectangle so far, as long as that side. Each square holds a quarter
# circle centered on one of its corners, and together they make the golden
# spiral. Returns $count squares as {x, y, size} (bottom left corner, y up)
# with the quarter circle's center {cx, cy} and its angles {from, to}.
sub golden_squares {
    my ($count) = @_;
    my $quarter = 2 * atan2(1, 1);
    my ($left, $right, $bottom, $top) = (0, 1, 0, 1);
    my @squares = ({ x => 0, y => 0, size => 1 });
    for my $i (1 .. $count - 1) {
        my $side = ($i - 1) % 4;
        my $size = $side % 2 ? $right - $left : $top - $bottom;
        my ($x, $y) = $side == 0 ? ($right, $bottom) : $side == 1 ? ($left, $top) : $side == 2 ? ($left - $size, $bottom) : ($left, $bottom - $size);
        push @squares, { x => $x, y => $y, size => $size };
        ($left, $right, $bottom, $top) = (List::Util::min($left, $x), List::Util::max($right, $x + $size), List::Util::min($bottom, $y), List::Util::max($top, $y + $size));
    }
    # The first square counts as added on the bottom. A square added on the
    # right turns about its top left corner, on the top about its bottom left,
    # and so on round.
    for my $i (0 .. $#squares) {
        my $s    = $squares[$i];
        my $side = ($i + 3) % 4;
        my @corner = @{ ([ 0, 1 ], [ 0, 0 ], [ 1, 0 ], [ 1, 1 ])[$side] };
        @$s{qw(cx cy from to)} = ($s->{x} + $corner[0] * $s->{size}, $s->{y} + $corner[1] * $s->{size}, ($side - 1) * $quarter, $side * $quarter);
    }
    return @squares;
}

# The squares in deepening shades with the spiral glowing gold across them.
# Ten squares make an 89 wide by 55 tall rectangle, which just fits.
my @GOLDEN_SHADES = (18, 17, 16, 27, 26, 25, 24, 23, 22, 35);
my @GOLDEN_GLOW   = ([ 0, 255, 140, 0 ], [ 0.5, 255, 255, 0 ], [ 1, 255, 255, 255 ]);

sub golden_canvas {
    my @squares = golden_squares(10);
    my $scale   = 1.55;
    my $left    = List::Util::min(map { $_->{x} } @squares);
    my $bottom  = List::Util::min(map { $_->{y} } @squares);
    my $pixel   = sub { [ 45 - ($_[1] - $bottom) * $scale / 2, 0.5 + ($_[0] - $left) * $scale ] };
    my @rgb = map { [ map { [ 0, 0, 0 ] } 1 .. 140 ] } 1 .. 48;
    my $corners = sub {
        my ($s) = @_;
        return map { $pixel->(@$_) } [ $s->{x}, $s->{y} ], [ $s->{x} + $s->{size}, $s->{y} ], [ $s->{x} + $s->{size}, $s->{y} + $s->{size} ], [ $s->{x}, $s->{y} + $s->{size} ];
    };
    fill_polygon(\@rgb, [ $corners->($squares[$_]) ], [ rgb($GOLDEN_SHADES[$_]) ]) for 0 .. $#squares;
    for my $s (@squares) {
        my @square = $corners->($s);
        paint_points(\@rgb, [ map { line_points(@square[ $_ - 1, $_ ], 0) } 0 .. 3 ], [ 0, 0, 0 ]);
    }
    my @points;
    for my $i (0 .. $#squares) {
        my $s = $squares[$i];
        my @arc = map {
            my $angle = $s->{from} + ($s->{to} - $s->{from}) * $_ / 60;
            $pixel->($s->{cx} + $s->{size} * cos($angle), $s->{cy} + $s->{size} * sin($angle));
        } 0 .. 60;
        push @points, map { line_points(@arc[ $_ - 1, $_ ], $i / $#squares) } 1 .. $#arc;
    }
    draw_glow_curve(\@rgb, \@points, \@GOLDEN_GLOW, 0.5);
    my @palette = (@GOLDEN_SHADES, gradient_palette(\@GOLDEN_GLOW), $BLACK);
    my $canvas  = pixels_to_canvas([ map { [ map { nearest_color_in(\@palette, @$_) } @$_ ] } @rgb ]);
    put_text($canvas, 4, 30, 'the golden spiral',                 97);
    put_text($canvas, 5, 30, 'squares 1 1 2 3 5 8 13 21 34 55',   94);
    put_text($canvas, 6, 30, '55/34 = 1.6176..., phi = 1.6180...', 94);
    return $canvas;
}

# A Penrose tiling of thin and thick rhombs, built the way Jeff Preshing
# does it: each rhomb is two triangles [kind, A, B, C], A at the apex, kind
# 0 for half a thin rhomb (a golden triangle) and 1 for half a thick one (a
# golden gnomon). Start with a wheel of ten thin halves round the origin,
# then split every triangle into smaller ones of the same two shapes, $level
# times. Points are [x, y].
my $PHI = (1 + sqrt 5) / 2;

sub penrose_triangles {
    my ($level) = @_;
    my $between = sub { my ($from, $to, $f) = @_; [ map { $from->[$_] + $f * ($to->[$_] - $from->[$_]) } 0, 1 ] };
    my @triangles = map {
        my ($b, $c) = map { [ cos($_ * atan2(1, 1) / 2.5), sin($_ * atan2(1, 1) / 2.5) ] } 2 * $_ - 1, 2 * $_ + 1;
        ($b, $c) = ($c, $b) if $_ % 2 == 0;
        [ 0, [ 0, 0 ], $b, $c ];
    } 0 .. 9;
    for (1 .. $level) {
        @triangles = map {
            my ($kind, $a, $b, $c) = @$_;
            if ($kind == 0) {
                my $p = $between->($a, $b, 1 / $PHI);
                ([ 0, $c, $p, $b ], [ 1, $p, $c, $a ]);
            } else {
                my ($q, $r) = ($between->($b, $a, 1 / $PHI), $between->($b, $c, 1 / $PHI));
                ([ 1, $r, $c, $a ], [ 1, $q, $r, $b ], [ 0, $r, $q, $a ]);
            }
        } @triangles;
    }
    return @triangles;
}

# The tiling filled in, thick rhombs warm and thin ones cool, each getting
# lighter toward the middle, with dark edges between rhombs. The edge from
# B to C is the seam between a rhomb's two halves, so it's left undrawn.
my @PENROSE_THICK = ([ 0, 255, 140, 0 ], [ 1, 116, 0, 0 ]);
my @PENROSE_THIN  = ([ 0, 0, 255, 255 ], [ 1, 0, 0, 116 ]);

sub penrose_canvas {
    my $scale = 100;
    my @rgb   = map { [ map { [ 0, 0, 0 ] } 1 .. 140 ] } 1 .. 48;
    my $pixel = sub { centered_pixel(@{ $_[0] }, $scale) };
    my @edges;
    for my $triangle (penrose_triangles(4)) {
        my ($kind, @corners) = @$triangle;
        my @on_screen = map { $pixel->($_) } @corners;
        my $middle    = [ map { my $i = $_; List::Util::sum(map { $_->[$i] } @corners) / 3 } 0, 1 ];
        fill_polygon(\@rgb, \@on_screen, [ gradient_rgb($kind ? \@PENROSE_THICK : \@PENROSE_THIN, sqrt($middle->[0]**2 + $middle->[1]**2)) ]);
        push @edges, map { line_points(@on_screen[ @$_ ], 0) } [ 2, 0 ], [ 0, 1 ];
    }
    paint_points(\@rgb, \@edges, [ 0, 0, 0 ]);
    my @palette = (gradient_palette(\@PENROSE_THICK), gradient_palette(\@PENROSE_THIN), $BLACK);
    my $canvas  = pixels_to_canvas([ map { [ map { nearest_color_in(\@palette, @$_) } @$_ ] } @rgb ]);
    put_text($canvas, 23, 1, 'Penrose tiling: never repeats, thick:thin = phi', 97);
    return $canvas;
}

# Recamán's sequence: start at 0, and at step n go back n if that lands on a
# number that's above zero and hasn't come up yet, otherwise go forward n.
# Returns the first $count terms.
sub recaman_sequence {
    my ($count) = @_;
    my @terms = (0);
    my %seen  = (0 => 1);
    for my $n (1 .. $count - 1) {
        my $back = $terms[-1] - $n;
        push @terms, $back > 0 && !$seen{$back} ? $back : $terms[-1] + $n;
        $seen{ $terms[-1] } = 1;
    }
    return @terms;
}

# Each step drawn as a half circle from one term to the next, above the
# line and below it by turns, the hue moving along as the steps get longer.
sub recaman_canvas {
    my @terms = recaman_sequence(45);
    my $scale = 138 / List::Util::max(@terms);
    my $pi    = 4 * atan2(1, 1);
    my @points;
    for my $n (1 .. $#terms) {
        my ($middle, $radius) = (($terms[ $n - 1 ] + $terms[$n]) / 2, abs($terms[$n] - $terms[ $n - 1 ]) / 2);
        my $side  = $n % 2 ? 1 : -1;
        my $steps = POSIX::ceil(2 * $pi * $radius * $scale);
        my @arc = map {
            my $angle = $pi * $_ / $steps;
            [ 23.5 - $side * $radius * sin($angle) * $scale / 2, 1 + ($middle + $radius * cos($angle)) * $scale ];
        } 0 .. $steps;
        push @points, map { line_points(@arc[ $_ - 1, $_ ], $n / $#terms) } 1 .. $#arc;
    }
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.35);
    put_text($canvas, 0, 1, 'Recaman: 0 1 3 6 2 7 13 20 12 21 11 22 10 23 9 ...', 97);
    put_text($canvas, 1, 1, 'step n goes back if it can, otherwise forward',     94);
    return $canvas;
}

# The Pythagoras tree: a square, and on its top a right triangle whose two
# short sides each grow another square, and so on, $levels times. $angle is
# where the triangle's right angle sits, measured at its left corner. The
# two new squares together have the area of the one below them, by
# Pythagoras's theorem, so every level has the same area as the trunk.
# Returns [depth, A, B, C, D] squares, A to B the bottom and C, D the top,
# trunk first and each level after the one before.
sub pythagoras_tree {
    my ($levels, $angle) = @_;
    my @squares;
    my @to_grow = ([ 0, [ 0, 0 ], [ 1, 0 ] ]);
    while (my $base = shift @to_grow) {
        my ($depth, $a, $b) = @$base;
        my @side = ($b->[0] - $a->[0], $b->[1] - $a->[1]);
        my ($c, $d) = map { [ $_->[0] - $side[1], $_->[1] + $side[0] ] } $b, $a;
        push @squares, [ $depth, $a, $b, $c, $d ];
        next if $depth == $levels;
        my $apex = [
            $d->[0] + cos($angle) * (cos($angle) * $side[0] - sin($angle) * $side[1]),
            $d->[1] + cos($angle) * (sin($angle) * $side[0] + cos($angle) * $side[1]),
        ];
        push @to_grow, [ $depth + 1, $d, $apex ], [ $depth + 1, $apex, $c ];
    }
    return @squares;
}

# Eight levels, leaning a little, the color running from a brown trunk
# through green to blossom at the tips.
my @PYTHAGORAS_GROWTH = (
    [ 0,    116, 58,  0 ],
    [ 0.3,  181, 99,  0 ],
    [ 0.55, 0,   181, 0 ],
    [ 0.8,  111, 255, 111 ],
    [ 1,    255, 156, 255 ],
);

sub pythagoras_canvas {
    my $levels  = 8;
    my @squares = pythagoras_tree($levels, 0.66);
    my $pixel   = fit_to_frame([ map { @$_[ 1 .. 4 ] } @squares ]);
    my @rgb     = map { [ map { [ 0, 0, 0 ] } 1 .. 140 ] } 1 .. 48;
    for my $square (@squares) {
        my ($depth, @corners) = @$square;
        fill_polygon(\@rgb, [ map { $pixel->(@$_) } @corners ], [ gradient_rgb(\@PYTHAGORAS_GROWTH, $depth / $levels) ]);
    }
    my @palette = (gradient_palette(\@PYTHAGORAS_GROWTH), $BLACK);
    my $canvas  = pixels_to_canvas([ map { [ map { nearest_color_in(\@palette, @$_) } @$_ ] } @rgb ]);
    put_text($canvas, 0, 1, 'the Pythagoras tree:', 97);
    put_text($canvas, 1, 1, 'a^2 + b^2 = c^2',      94);
    return $canvas;
}

# A tiling of the hyperbolic plane by triangles with angles pi/p, pi/q and
# pi/2, drawn in the Poincaré disk, where straight lines are arcs that meet
# the edge at right angles. One triangle has its corners at the middle, on
# the x axis and on a line slanting up at pi/p; its third side is a circle
# centered on the x axis, which hyperbolic_mirror finds. Reflecting in the
# three sides over and over tiles the whole disk.
sub hyperbolic_mirror {
    my ($p, $q) = @_;
    my $pi     = 4 * atan2(1, 1);
    my $center = cos($pi / $q) / sqrt(cos($pi / $q)**2 - sin($pi / $p)**2);
    return ($center, sqrt($center**2 - 1));
}

# Reflection in a circle centered on the x axis, which in the disk is a
# reflection in a straight line.
sub hyperbolic_reflect {
    my ($x, $y, $center, $radius) = @_;
    my $f = $radius**2 / (($x - $center)**2 + $y**2);
    return ($center + ($x - $center) * $f, $y * $f);
}

# Reflects (x, y) in whichever side of the starting triangle it's beyond
# until it's inside. Returns where it lands and how many times that crossed
# the curved side. The 2p triangles round the middle make a p-sided tile, and
# its sides are all copies of the curved side, so that count is how many tile
# edges the point is from the middle tile. With an even q, an even number of
# edges meet at every corner, so its evenness colors the tiles like a
# chessboard.
sub hyperbolic_fold {
    my ($x, $y, $p, $q) = @_;
    my ($center, $radius) = hyperbolic_mirror($p, $q);
    my $slant = 4 * atan2(1, 1) / $p;
    my ($s, $c) = (sin(2 * $slant), cos(2 * $slant));
    my $crossings = 0;
    for (1 .. 500) {
        if ($y < 0) {
            $y = -$y;
        } elsif ($y * cos($slant) - $x * sin($slant) > 0) {
            ($x, $y) = ($x * $c + $y * $s, $x * $s - $y * $c);
        } elsif (($x - $center)**2 + $y**2 < $radius**2) {
            ($x, $y) = hyperbolic_reflect($x, $y, $center, $radius);
            $crossings++;
        } else {
            last;
        }
    }
    return ($x, $y, $crossings);
}

# The {5, 4} tiling: pentagons, four at every corner, though in flat space
# four pentagons can't meet at a point. They're all the same size; they only
# look smaller toward the edge of the disk. Each is shaded from bright in its
# middle to dark at its edges, the two colors alternating, and each pixel
# averages four samples so the shrinking tiles at the rim blend into the dark.
my @HYPERBOLIC_EVEN = ([ 0, 0, 0, 0 ], [ 0.3, 0, 116, 116 ], [ 0.7, 0, 255, 255 ], [ 1, 255, 255, 255 ]);
my @HYPERBOLIC_ODD  = ([ 0, 0, 0, 0 ], [ 0.3, 117, 0, 181 ], [ 0.7, 255, 0, 255 ], [ 1, 255, 156, 255 ]);

sub hyperbolic_canvas {
    my ($p, $q) = (5, 4);
    my ($center, $radius) = hyperbolic_mirror($p, $q);
    my @palette = (gradient_palette(\@HYPERBOLIC_EVEN), gradient_palette(\@HYPERBOLIC_ODD), $BLACK);
    my @pixels  = map {
        my $r = $_;
        [ map {
            my $c = $_;
            my @samples = map {
                my ($x, $y) = (($c - 69.75 + $_->[1]) / 47, (23.75 - $r - $_->[0]) * 2 / 47);
                if ($x**2 + $y**2 >= 1) {
                    [ 0, 0, 0 ];
                } else {
                    my ($fx, $fy, $crossings) = hyperbolic_fold($x, $y, $p, $q);
                    my $inside = (sqrt(($fx - $center)**2 + $fy**2) - $radius) / ($center - $radius);
                    [ gradient_rgb($crossings % 2 ? \@HYPERBOLIC_ODD : \@HYPERBOLIC_EVEN, $inside**0.5) ];
                }
            } [ 0, 0 ], [ 0, 0.5 ], [ 0.5, 0 ], [ 0.5, 0.5 ];
            nearest_color_in(\@palette, @{ average_rgb(@samples) });
        } 0 .. 139 ];
    } 0 .. 47;
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0, 1, 'the hyperbolic plane:', 97);
    put_text($canvas, 1, 1, 'pentagons, four to',    94);
    put_text($canvas, 2, 1, 'a corner, all the',     94);
    put_text($canvas, 3, 1, 'same size',             94);
    return $canvas;
}

# Two point sources dropping ripples into still water, $gap apart on the x
# axis, as cos(2 pi (r / wavelength - time)) from each, added together. Where
# one source is a whole number of waves further than the other the ripples
# add up; where it's a half number they cancel, along hyperbolas.
sub ripple_height {
    my ($x, $y, $gap, $wavelength, $time) = @_;
    my $pi = 4 * atan2(1, 1);
    return List::Util::sum(map {
        my $r = sqrt(($x - $_)**2 + $y**2);
        cos(2 * $pi * ($r / $wavelength - $time));
    } -$gap / 2, $gap / 2);
}

# The water in four shades from deep blue in the troughs to pale at the
# crests, the calm lines where the waves cancel staying mid teal. The
# sources are 2.5 waves apart, so along the line through them, outside the
# gap, they always cancel. Distances are in pixel widths.
my @RIPPLE_SHADES = (23, 35, 34, 46, 82);

sub ripples_canvas {
    my $wavelength = 14;
    my $gap        = 2.5 * $wavelength;
    my @pixels = map {
        my $y = (23.5 - $_) * 2;
        [ map {
            my $level = (ripple_height($_ - 69.5, $y, $gap, $wavelength, 0) + 2) / 4;
            $RIPPLE_SHADES[ List::Util::min($#RIPPLE_SHADES, int($level * @RIPPLE_SHADES)) ];
        } 0 .. 139 ];
    } 0 .. 47;
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 11, 1, 'calm wherever the', 97);
    put_text($canvas, 12, 1, 'two are half a wave', 97);
    put_text($canvas, 13, 1, 'out of step', 97);
    return $canvas;
}

# Weierstrass's function, the first $terms terms of the sum of
# a^n cos(b^n pi x). Every term is smooth, but each one wiggles b times faster
# and only a times smaller, so with a b over 1 the full sum has a corner at
# every point: continuous everywhere and smooth nowhere.
sub weierstrass {
    my ($x, $a, $b, $terms) = @_;
    my $pi = 4 * atan2(1, 1);
    return List::Util::sum(0, map { $a**$_ * cos($b**$_ * $pi * $x) } 0 .. $terms - 1);
}

# The function with a = 0.7 and b = 3 from -0.6 to 0.9, drawn as a mountain
# range under a night sky, snow on the peaks and forest at the foot. Past
# eight terms the wiggles are thinner than a pixel. Each column of pixels
# rises to the highest point the function reaches across that column, so
# wiggles too thin to see still show up as the jagged ridge. The bands are
# fractions of the way from the lowest ridge to the highest, and change only
# between text rows: a band edge through the middle of a row would put a
# half block in every cell, which blows the line's byte budget.
my @WEIERSTRASS_BANDS = ([ 0.8, 98 ], [ 0.6, 95 ], [ 0.4, 93 ], [ 0.15, 32 ], [ -9, 20 ]);
my $WEIERSTRASS_SKY   = 24;

sub weierstrass_canvas {
    my ($a, $b, $terms, $per_column, $from, $to) = (0.5, 3, 7, 40, -0.6, 0.9);
    my @ridges = map {
        my $c = $_;
        List::Util::max(map { weierstrass($from + ($to - $from) * ($c + $_ / $per_column) / 140, $a, $b, $terms) } 0 .. $per_column);
    } 0 .. 139;
    my ($low, $high) = (List::Util::min(@ridges), List::Util::max(@ridges));
    my @pixels = map { [ ($WEIERSTRASS_SKY) x 140 ] } 0 .. 47;
    for my $c (0 .. 139) {
        for my $r (0 .. 47) {
            my $height = $high - ($r - 4) * ($high - $low) / 36;
            next if $height > $ridges[$c];
            my $fraction = ($high - (2 * int($r / 2) - 4) * ($high - $low) / 36 - $low) / ($high - $low);
            $pixels[$r][$c] = (List::Util::first { $fraction > $_->[0] } @WEIERSTRASS_BANDS)->[1];
        }
    }
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0, 1, 'Weierstrass: continuous everywhere,', 97);
    put_text($canvas, 1, 1, 'smooth nowhere', 97);
    return $canvas;
}

# Which of the [x, y] seeds is nearest the point (x, y), and how much further
# away the next nearest one is. The gap closes to 0 on the borders between the
# seeds' cells.
sub nearest_seed {
    my ($seeds, $x, $y) = @_;
    my @distances = map { sqrt(($seeds->[$_][0] - $x)**2 + ($seeds->[$_][1] - $y)**2) } 0 .. $#$seeds;
    my @order     = sort { $distances[$a] <=> $distances[$b] } 0 .. $#distances;
    return ($order[0], $distances[ $order[1] ] - $distances[ $order[0] ]);
}

# The Voronoi diagram of a sunflower's seeds: every seed gets the patch of
# head nearer to it than to any other seed. Near the rim each seed touches
# the seeds 13, 21 and 34 along, so seeds 21 apart run along one of 21
# spirals. Seed n's spiral is n mod 21, and its neighbor 13 along sits on the
# next spiral round, so numbering the spirals 13 n mod 21 puts them in order
# round the head. We color them in seven bands of three, which makes a
# pinwheel of seven curved arms.
sub voronoi_canvas {
    my ($count, $spacing) = (90, 4.8);
    my @seeds  = sunflower_seeds($count, $spacing);
    my $radius = $spacing * sqrt($count + 0.5);
    my @hues   = (52, 53, 54, 56, 58, 60, 62);
    my @pixels = map {
        my $y = (23.5 - $_) * 2;
        [ map {
            my $x = $_ - 69.5;
            my ($seed, $gap) = nearest_seed(\@seeds, $x, $y);
            sqrt($x**2 + $y**2) > $radius || $gap < 1.2 ? $BLACK : $hues[ int(13 * ($seed + 1) % 21 * @hues / 21) ];
        } 0 .. 139 ];
    } 0 .. 47;
    return pixels_to_canvas(\@pixels);
}

# The Euler spiral, the curve that bends more the further along it you go:
# its curvature is the distance s along it, so it heads in the direction
# s^2 / 2. Railways and roads use a stretch of it to ease into a bend. Both
# ends wind in forever toward two eyes, at plus and minus (sqrt(pi)/2,
# sqrt(pi)/2). Returns 2 $steps + 1 points [x, y] from s = -$length to
# $length, adding up the direction a small step at a time.
sub euler_spiral {
    my ($length, $steps) = @_;
    my $ds = $length / $steps;
    my @half = ([ 0, 0 ]);
    for my $i (1 .. $steps) {
        my $heading = (($i - 0.5) * $ds)**2 / 2;
        push @half, [ $half[-1][0] + $ds * cos($heading), $half[-1][1] + $ds * sin($heading) ];
    }
    return ((map { [ -$_->[0], -$_->[1] ] } reverse @half[ 1 .. $#half ]), @half);
}

# The spiral as a glowing line from one eye to the other, its hue running
# along it.
sub clothoid_canvas {
    my ($length, $steps) = (5, 4000);
    my @spiral = euler_spiral($length, $steps);
    my $pixel  = fit_to_frame(\@spiral);
    my @points = map { [ @{ $pixel->(@{ $spiral[$_] }) }, $_ / $#spiral ] } 0 .. $#spiral;
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.7);
    put_text($canvas, 0, 1, 'the Euler spiral:', 97);
    put_text($canvas, 1, 1, 'it bends more the', 94);
    put_text($canvas, 2, 1, 'further it goes', 94);
    return $canvas;
}

# The Hopf fibration splits the sphere in four dimensions into circles, one
# over each point of the ordinary sphere, and every one of them is linked
# through every other. This is the circle over the point at polar angle
# $theta and longitude $phi, carried into our space by stereographic
# projection, as $steps + 1 points [x, y, z].
sub hopf_fiber {
    my ($theta, $phi, $steps) = @_;
    my ($c, $s) = (cos($theta / 2), sin($theta / 2));
    return map {
        my $psi = 8 * atan2(1, 1) * $_ / $steps;
        my @point = ($c * cos($psi), $c * sin($psi), $s * cos($psi + $phi), $s * sin($psi + $phi));
        [ map { $point[$_] / (1 - $point[3]) } 0 .. 2 ];
    } 0 .. $steps;
}

# The circles over a ring of points round the equator. They lie on one torus,
# each looping once round the hole and once round the tube, and each one
# passes through all the others. They're tipped toward the viewer, and the
# hue goes round with the longitude.
sub hopf_canvas {
    my ($fibers, $tilt, $steps) = (6, 0, 700);
    my $pi = 4 * atan2(1, 1);
    my @points;
    for my $i (0 .. $fibers - 1) {
        for my $point (hopf_fiber($pi / 2, 2 * $pi * $i / $fibers, $steps)) {
            my ($x, $y, $z) = @$point;
            my ($up, $near) = ($y * cos($tilt) - $z * sin($tilt), $y * sin($tilt) + $z * cos($tilt));
            push @points, [ @{ centered_pixel($x, $up, 17) }, $i / $fibers, $near ];
        }
    }
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.6);
    put_text($canvas, 0, 1, 'the Hopf fibration:', 97);
    put_text($canvas, 1, 1, 'every circle linked', 94);
    put_text($canvas, 2, 1, 'through every other', 94);
    return $canvas;
}

# The Cantor set: start with the line from 0 to 1 and keep cutting the middle
# third out of every piece. Returns the 2^$level pieces left after $level
# cuts, as [from, to].
sub cantor_intervals {
    my ($level) = @_;
    my @pieces = ([ 0, 1 ]);
    for (1 .. $level) {
        @pieces = map { my $third = ($_->[1] - $_->[0]) / 3; ([ $_->[0], $_->[0] + $third ], [ $_->[1] - $third, $_->[1] ]) } @pieces;
    }
    return @pieces;
}

# The Cantor function, the devil's staircase, read off $depth base 3 digits
# of x. It climbs from 0 to 1 but is flat across every middle third, so it
# does all its climbing on the Cantor set, which has no length at all. Read
# x in base 3: up to the first 1 digit, every 2 becomes a binary 1, and the
# 1 itself ends the number with a final binary 1.
sub cantor_function {
    my ($x, $depth) = @_;
    return 1 if $x >= 1;
    my ($value, $bit) = (0, 0.5);
    for (1 .. $depth) {
        $x *= 3;
        my $digit = int $x;
        return $value + $bit if $digit == 1;
        $value += $bit if $digit == 2;
        $x -= $digit;
        $bit /= 2;
    }
    return $value;
}

# The staircase as a glowing line, with the first five steps of the Cantor
# set lined up underneath it, one text row each, so every flat stretch sits
# over a gap.
sub cantor_canvas {
    my $samples = 4000;
    my @points  = map {
        my $x = $_ / $samples;
        my $y = cantor_function($x, 12);
        [ 35 - 33 * $y, 1.5 + 136 * $x, $y ];
    } 0 .. $samples;
    my @rgb = map { [ map { [ 0, 0, 0 ] } 1 .. 140 ] } 1 .. 48;
    draw_glow_curve(\@rgb, \@points, \@ZETA_HUES, 0.7);
    for my $level (0 .. 4) {
        my @color = gradient_rgb(\@ZETA_HUES, $level / 4);
        for my $piece (cantor_intervals($level)) {
            for my $c (0 .. 139) {
                next if $c + 0.5 < 2 + 136 * $piece->[0] || $c + 0.5 > 2 + 136 * $piece->[1];
                $rgb[ 38 + 2 * $level ][$c] = [@color];
                $rgb[ 39 + 2 * $level ][$c] = [@color];
            }
        }
    }
    my @palette = (gradient_palette(\@ZETA_HUES), $BLACK);
    my $canvas  = pixels_to_canvas([ map { [ map { nearest_color_in(\@palette, @$_) } @$_ ] } @rgb ]);
    put_text($canvas, 0, 1, 'the devil\'s staircase:', 97);
    put_text($canvas, 1, 1, 'it climbs only on the', 94);
    put_text($canvas, 2, 1, 'Cantor set below,', 94);
    put_text($canvas, 3, 1, 'which has no length', 94);
    return $canvas;
}

# The tesseract, the four dimensional cube: its corners are every point with
# coordinates of plus or minus 1, and its edges join corners that differ in
# just one coordinate.
sub tesseract_vertices {
    return map { my $n = $_; [ map { $n >> $_ & 1 ? 1 : -1 } 0 .. 3 ] } 0 .. 15;
}

sub tesseract_edges {
    return map { my $n = $_; map { [ $n, $n | 1 << $_ ] } grep { !($n >> $_ & 1) } 0 .. 3 } 0 .. 15;
}

# Turns a point by $angle in the plane of its coordinates $i and $j, leaving
# the others alone.
sub rotate_plane {
    my ($point, $i, $j, $angle) = @_;
    my @turned = @$point;
    @turned[ $i, $j ] = ($point->[$i] * cos($angle) - $point->[$j] * sin($angle), $point->[$i] * sin($angle) + $point->[$j] * cos($angle));
    return \@turned;
}

# The tesseract turned partway in two planes that reach into the fourth
# dimension, then seen in perspective from out along w, the way a cube is
# drawn as a square inside a square. The near cube comes out big and the far
# one small, with the other six cubes as the frustums joining them. Then we
# tip that view toward us. Edges are hued by how far along w they are, and
# nearer edges cross in front.
sub tesseract_canvas {
    my ($camera, $scale) = (3, 15);
    my @projected = map {
        my $point = rotate_plane(rotate_plane($_, 0, 3, 0.35), 1, 3, 0.25);
        my $w = $point->[3];
        my @seen = map { $_ * $camera / ($camera - $w) } @$point[ 0 .. 2 ];
        my $view = rotate_plane(rotate_plane(\@seen, 1, 2, 0.5), 0, 2, 0.4);
        [ @$view, ($w + 1.5) / 3 ];
    } tesseract_vertices();
    my @points;
    for my $edge (tesseract_edges()) {
        my ($from, $to) = @projected[@$edge];
        for my $step (0 .. 120) {
            my @at = map { $from->[$_] + ($to->[$_] - $from->[$_]) * $step / 120 } 0 .. 3;
            push @points, [ @{ centered_pixel($at[0], $at[1], $scale) }, $at[3], $at[2] ];
        }
    }
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.7);
    put_text($canvas, 0, 1, 'a tesseract:',          97);
    put_text($canvas, 1, 1, 'the cube in four',      94);
    put_text($canvas, 2, 1, 'dimensions, turning',   94);
    put_text($canvas, 3, 1, 'through the fourth',    94);
    return $canvas;
}

# Truchet tiles in Smith's style: each square tile has two quarter circle
# arcs round opposite corners, and is laid one of two ways. Returns rows of
# 0 (arcs round the top left and bottom right corners) or 1 (round the other
# two), picked by our own generator with a fixed seed.
sub truchet_tiles {
    my ($cols, $rows) = @_;
    my $seed = 20261019;
    return [ map { [ map { $seed = ($seed * 1103515245 + 12345) % 2147483648; $seed >= 1073741824 ? 1 : 0 } 1 .. $cols ] } 1 .. $rows ];
}

# Which side of the arcs the point (x, y) is on, in tiles across and down,
# as 0 or 1. The arcs join up into endless winding paths, and the regions
# between them can always be colored with two colors: flip the color for
# the corners, for tiles laid the other way, and from one checkerboard
# square to the next.
sub truchet_side {
    my ($tiles, $x, $y) = @_;
    my ($i, $j) = (POSIX::floor($x), POSIX::floor($y));
    my ($u, $v) = ($x - $i, $y - $j);
    my $turn    = $tiles->[$j][$i];
    my @corners = $turn ? ([ 1, 0 ], [ 0, 1 ]) : ([ 0, 0 ], [ 1, 1 ]);
    my $in_corner = grep { ($u - $_->[0])**2 + ($v - $_->[1])**2 < 0.25 } @corners;
    return ($in_corner ? 1 : 0) ^ $turn ^ (($i + $j) % 2);
}

# Tiles 10 pixels across and 5 down, which is square.
sub truchet_canvas {
    my $tiles  = truchet_tiles(14, 10);
    my @colors = (24, 53);
    my @pixels = map { my $r = $_; [ map { $colors[ truchet_side($tiles, ($_ + 0.5) / 10, ($r + 0.5) / 5) ] } 0 .. 139 ] } 0 .. 47;
    return pixels_to_canvas(\@pixels);
}

# sin of the complex number x + iy, as its real and imaginary parts.
sub complex_sin {
    my ($x, $y) = @_;
    return (sin($x) * POSIX::cosh($y), cos($x) * POSIX::sinh($y));
}

# A square grid carried through w = sin z. Maps like this one that have a
# complex derivative are conformal: they bend and stretch, but wherever two
# lines crossed at right angles, their images still do. The level lines
# become ellipses (warm) and the upright ones hyperbolas (cool), all sharing
# the same two foci at plus and minus 1.
sub conformal_canvas {
    my $pi = 4 * atan2(1, 1);
    my ($steps, @lines) = (800);
    for my $k (1 .. 4) {
        push @lines, [ map { [ complex_sin(-$pi + 2 * $pi * $_ / $steps, 0.1 + 0.3 * $k), 0.55 + 0.45 * $k / 4 ] } 0 .. $steps ];
    }
    for my $k (-3 .. 3) {
        push @lines, [ map { [ complex_sin($pi / 8 * $k, -1.3 + 2.6 * $_ / $steps), 0.4 * (1 - abs($k) / 4) ] } 0 .. $steps ];
    }
    my $pixel  = fit_to_frame([ map {@$_} @lines ]);
    my @points = map { [ @{ $pixel->(@$_[ 0, 1 ]) }, $_->[2] ] } map {@$_} @lines;
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.6);
    put_text($canvas, 0, 1, 'a square grid under', 97);
    put_text($canvas, 1, 1, 'w = sin z: still',    94);
    put_text($canvas, 2, 1, 'square at every',     94);
    put_text($canvas, 3, 1, 'crossing',            94);
    return $canvas;
}

# The (p, q) torus knot: a line wound round a doughnut, p times round the
# hole and q times round the tube, closing up after one trip. When p and q
# share no factor it's a single knotted loop. The tube has radius 1 and runs
# round a circle of radius 2. Returns $steps + 1 points [x, y, z] along it.
sub torus_knot_points {
    my ($p, $q, $steps) = @_;
    return map {
        my $t = 8 * atan2(1, 1) * $_ / $steps;
        my $out = 2 + cos($q * $t);
        [ $out * cos($p * $t), $out * sin($p * $t), sin($q * $t) ];
    } 0 .. $steps;
}

# The (2, 5) torus knot, tipped toward the viewer, its hue running once
# along the whole loop. Strands in front cut the ones behind, so every
# crossing shows which way it goes.
sub knot_canvas {
    my ($p, $q, $tilt, $steps) = (2, 5, 0.45, 8000);
    my @knot   = torus_knot_points($p, $q, $steps);
    my @points = map {
        my ($x, $y, $z) = @{ $knot[$_] };
        my ($up, $near) = ($y * cos($tilt) - $z * sin($tilt), $y * sin($tilt) + $z * cos($tilt));
        [ @{ centered_pixel($x, $up, 15) }, $_ / $steps, $near ];
    } 0 .. $steps;
    my $canvas = glow_lines_canvas(\@points, \@ZETA_HUES, 0.8);
    put_text($canvas, 0, 1, "the ($p,$q) torus knot:",   97);
    put_text($canvas, 1, 1, "$p times round the hole,",  94);
    put_text($canvas, 2, 1, "$q times round the tube",   94);
    return $canvas;
}

# The first $terms terms of the Fourier series of a square wave that's 1
# from 0 to pi and -1 from pi to 2 pi: (4/pi) (sin x + sin 3x / 3 + sin 5x / 5 + ...).
sub square_wave_sum {
    my ($x, $terms) = @_;
    my $sum = 0;
    $sum += sin((2 * $_ - 1) * $x) / (2 * $_ - 1) for 1 .. $terms;
    return $sum / atan2(1, 1);
}

# Sums with more and more terms drawn over each other, each in its own hue,
# closing in on the square wave from -pi to pi. The corners never quite come
# right: the overshoot next to each jump gets narrower but never lower. That's
# the Gibbs phenomenon.
my @FOURIER_TERMS = (1, 3, 10, 40);
my @FOURIER_HUES  = (
    [ 0,     165, 0,   255 ],
    [ 1 / 3, 0,   255, 255 ],
    [ 2 / 3, 255, 255, 0 ],
    [ 1,     255, 255, 255 ],
);

sub fourier_canvas {
    my $pi = 4 * atan2(1, 1);
    my @points;
    for my $i (0 .. $#FOURIER_TERMS) {
        my @path = map {
            my $x = -$pi + 2 * $pi * $_ / 1400;
            [ 23.5 - 16 * square_wave_sum($x, $FOURIER_TERMS[$i]), 69.5 + 68 * $x / $pi ];
        } 0 .. 1400;
        push @points, map { line_points(@path[ $_ - 1, $_ ], $i / $#FOURIER_TERMS) } 1 .. $#path;
    }
    my $canvas = glow_lines_canvas(\@points, \@FOURIER_HUES, 0.5);
    put_text($canvas, 0,  1, 'square wave = (4/pi)(sin x + sin 3x/3 + sin 5x/5 + ...)', 97);
    put_text($canvas, 1,  1, '1, 3, 10 and 40 terms',                                  94);
    put_text($canvas, 23, 1, 'the corners overshoot by 9% however many terms (Gibbs)', 94);
    return $canvas;
}

# An elementary cellular automaton: a row of cells, each on or off, where the
# next row's cell is decided by the cell above it and that cell's two
# neighbors. Those three make a number from 0 to 7, and that bit of the rule
# number says whether the new cell is on. Starts from one cell in the middle
# of a row $width wide, cells past the ends counting as off, and returns
# $count rows as lists of 0s and 1s.
sub automaton_rows {
    my ($rule, $width, $count) = @_;
    my @row = (0) x $width;
    $row[ int($width / 2) ] = 1;
    my @rows = ([@row]);
    while (@rows < $count) {
        @row = map {
            my $pattern = 4 * ($_ > 0 ? $row[ $_ - 1 ] : 0) + 2 * $row[$_] + ($_ < $width - 1 ? $row[ $_ + 1 ] : 0);
            ($rule >> $pattern) & 1;
        } 0 .. $width - 1;
        push @rows, [@row];
    }
    return @rows;
}

# Rule 30 from a single cell: one side settles into stripes and the other
# never settles at all; Mathematica used its middle column as a random number
# generator. Each cell is two pixels wide so it draws square. The pattern
# grows a cell each way per row, so it's worked out on a wider strip than the
# frame shows, so the edges don't bend it.
my @RULE30_HUES = (
    [ 0,   255, 255, 0 ],
    [ 0.4, 255, 140, 0 ],
    [ 0.7, 255, 0,   0 ],
    [ 1,   255, 0,   255 ],
);

sub rule30_canvas {
    my ($cols, $rows) = (70, 48);
    my $margin  = $rows;
    my @palette = gradient_palette(\@RULE30_HUES);
    my @lines   = automaton_rows(30, $cols + 2 * $margin, $rows);
    my @pixels  = map {
        my $r     = $_;
        my $color = nearest_color_in(\@palette, gradient_rgb(\@RULE30_HUES, $r / ($rows - 1)));
        [ map { ($lines[$r][ $margin + $_ ] ? $color : $BLACK) x 2 } 0 .. $cols - 1 ];
    } 0 .. $rows - 1;
    my $canvas = pixels_to_canvas(\@pixels);
    put_text($canvas, 0, 1, 'rule 30:', 97);
    put_text($canvas, 1, 1, 'new = left XOR', 94);
    put_text($canvas, 2, 1, '(middle OR right)', 94);
    return $canvas;
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
    weierstrass => { draw => \&weierstrass_canvas, about => 'the Weierstrass function: continuous everywhere, smooth nowhere' },
    voronoi    => { draw => \&voronoi_canvas,    about => 'a sunflower\'s seeds, each given the patch of head nearest it' },
    clothoid   => { draw => \&clothoid_canvas,   about => 'the Euler spiral, which bends more the further along it you go' },
    cantor     => { draw => \&cantor_canvas,     about => 'the devil\'s staircase, climbing only on the Cantor set' },
    tesseract  => { draw => \&tesseract_canvas,  about => 'a tesseract, the four dimensional cube, turned and seen in perspective' },
    truchet    => { draw => \&truchet_canvas,    about => 'Truchet tiles: quarter circles laid at random, joining into endless paths' },
    conformal  => { draw => \&conformal_canvas,  about => 'a square grid under w = sin z, bent but still square at every crossing' },
    hopf       => { draw => \&hopf_canvas,       about => 'the Hopf fibration: circles on a doughnut, every one linked through every other' },
    burningship => { draw => \&burningship_canvas, about => 'the Burning Ship fractal, z^2 + c with the orbit folded' },
    dragon     => { draw => \&dragon_canvas,     about => 'the Heighway dragon, a strip of paper folded in half eight times' },
    spirograph => { draw => \&spirograph_canvas, about => 'a spirograph: a gear rolling inside a ring, drawing loops' },
    clifford   => { draw => \&clifford_canvas,   about => 'a Clifford strange attractor, drawn like smoke' },
    life       => { draw => \&life_canvas,       about => 'Conway\'s Game of Life: a glider gun firing gliders, with trails' },
    rule30     => { draw => \&rule30_canvas,     about => 'Wolfram\'s rule 30, one cell growing into chaos' },
    ford       => { draw => \&ford_canvas,       about => 'Ford circles: a circle on every fraction, and neighbors always touch' },
    fourier    => { draw => \&fourier_canvas,    about => 'a square wave built from sine waves, overshooting at every corner' },
    penrose    => { draw => \&penrose_canvas,    about => 'a Penrose tiling: two rhombs covering the plane without ever repeating' },
    knot       => { draw => \&knot_canvas,      about => 'a torus knot: a line wound round a doughnut, twice one way and five times the other' },
    recaman    => { draw => \&recaman_canvas,    about => 'Recaman\'s sequence: hop back if you can, forward if you can\'t, drawn as arcs' },
    pythagoras => { draw => \&pythagoras_canvas, about => 'the Pythagoras tree: squares on the sides of right triangles, branching forever' },
    hyperbolic => { draw => \&hyperbolic_canvas, about => 'the hyperbolic plane in a disk, tiled by same-size pentagons, four to a corner' },
    ripples    => { draw => \&ripples_canvas,    about => 'ripples from two stones meeting, calm wherever they cancel' },
    golden     => { draw => \&golden_canvas,    about => 'the golden spiral, drawn through squares whose sides are the Fibonacci numbers' },
    langton    => { draw => \&langton_canvas,    about => 'Langton\'s ant: ten thousand steps of mess, then out of nowhere a highway' },
    lyapunov   => { draw => \&lyapunov_canvas,   about => 'a Lyapunov fractal: where a logistic map flipping between two rates settles or turns to chaos' },
    sandpile   => { draw => \&sandpile_canvas,   about => 'the Abelian sandpile: grains dropped on one square, toppling in fours' },
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
    '       /math -r           send a random piece (--random works too)',
    '       /math -p -r        preview a random piece',
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
    if ($name eq '-r' || $name eq '--random') {
        my @names = sort keys %PIECES;
        $name = $names[ int rand @names ];
        show($witem, "random piece: $name") if $witem;
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
