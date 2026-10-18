#!/usr/bin/perl
# Tests for src/mathascii.pl. Run with: prove tests/
#
# The script expects to run inside irssi, so this file supplies a minimal
# stand-in for the Irssi module plus fake server and window item objects. The
# fakes only record what the script asks irssi to do; the logic under test (the
# zeta function, plotting, color encoding, command handling) is the script's own.
use strict;
use warnings;

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

our ($ZETA_T_MAX, @ZETA_GRADIENT);
my $script = "$FindBin::Bin/../src/mathascii.pl";
do $script or die "could not load $script: " . ($@ || $!);

sub strip_colors {
    my ($line) = @_;
    $line =~ s/\x03\d\d,\d\d//g;
    return $line;
}

sub close_to {
    my ($got, $want, $name) = @_;
    ok abs($got - $want) < 1e-9, $name or diag "got $got, want $want";
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
    my @canvas = (
        [ [ 'a', 52, 88 ], [ 'b', 52, 88 ], [ 'c', 4, 88 ] ],
        [ [ '1', 98, 88 ], [ ' ', 98, 88 ], [ ' ', 98, 1 ] ],
    );
    is_deeply [ irc_lines(\@canvas) ],
        [ "\x0352,88ab\x0304,88c", "\x0398,881 \x0398,01 " ],
        'one code per run, always two digits for fg and bg';
};

subtest 'zeta piece' => sub {
    my @lines = render_zeta();
    ok @lines >= 10, 'has a body';

    my $width = length strip_colors($lines[0]);
    is_deeply [ grep { length strip_colors($_) != $width } @lines ], [],
        'every line is the same width, so the background forms a block';
    is_deeply [ grep { length($_) > 400 } @lines ], [],
        'every line fits in one IRC message';
    is_deeply [ grep { /[^\x03\x20-\x7e]/ } @lines ], [],
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
    is_deeply $item->{printed}, [ [ 'math: pieces: zeta', 'CLIENTCRAP' ] ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

subtest 'cmd_math sends the piece to the window' => sub {
    my $server = FakeServer->new;
    cmd_math(' zeta ', $server, FakeItem->new(name => '#math'));
    is_deeply $server->{sent}, [ map { "MSG #math $_" } render_zeta() ];
};

subtest 'cmd_math -p previews without sending' => sub {
    my $server = FakeServer->new;
    my $item   = FakeItem->new;
    cmd_math('-p zeta', $server, $item);
    is_deeply $item->{printed}, [ map { [ $_, 'CLIENTCRAP' ] } render_zeta() ];
    is_deeply $server->{sent}, [], 'nothing was sent';
};

subtest 'cmd_math refuses bad input' => sub {
    my $item = FakeItem->new;
    cmd_math('nope', FakeServer->new, $item);
    is_deeply $item->{printed}, [ [ 'math: no piece called "nope". pieces: zeta', 'CLIENTERROR' ] ],
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
