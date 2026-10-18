use strict;
use warnings;

use Irssi;

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

# Turns a canvas into IRC lines, writing a color code only where the colors
# change. Codes are always two digits each so that art starting with a digit
# isn't read as part of the code.
sub irc_lines {
    my ($canvas) = @_;
    my @lines;
    for my $row (@$canvas) {
        my ($line, $current) = ('', '');
        for my $cell (@$row) {
            my ($char, $fg, $bg) = @$cell;
            my $colors = sprintf "\x03%02d,%02d", $fg, $bg;
            $line .= $colors if $colors ne $current;
            $line .= $char;
            $current = $colors;
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

sub render_zeta { return irc_lines(zeta_canvas()) }

my %PIECES = (zeta => \&render_zeta);

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
    my $render = $PIECES{$name};
    if (!$render) {
        $witem->print(qq{math: no piece called "$name". pieces: } . piece_list(), MSGLEVEL_CLIENTERROR);
        return;
    }

    if ($preview) {
        $witem->print($_, MSGLEVEL_CLIENTCRAP) for $render->();
        return;
    }
    if (!$server || !$server->{connected}) {
        Irssi::print('math: not connected to a server', MSGLEVEL_CLIENTERROR);
        return;
    }
    $server->command("MSG $witem->{name} $_") for $render->();
}

Irssi::command_bind('math', 'cmd_math');
