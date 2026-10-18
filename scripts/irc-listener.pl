#!/usr/bin/perl
# Joins a channel and writes the text of every PRIVMSG it sees there to a file,
# one per line, bytes untouched. Used by scripts/e2e.sh to capture exactly what
# a piece looks like on the wire.
#
# Usage: scripts/irc-listener.pl <host> <port> <nick> <channel> <outfile>
#
# Runs until killed. Writes "joined" to <outfile>.ready once it is in the
# channel, so callers know when it is safe to start sending.
use strict;
use warnings;

use IO::Handle;
use IO::Socket::INET;

@ARGV == 5 or die "usage: $0 <host> <port> <nick> <channel> <outfile>\n";
my ($host, $port, $nick, $channel, $outfile) = @ARGV;

my $irc = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port)
    or die "irc-listener: cannot connect to $host:$port: $!\n";
binmode $irc;
open my $out, '>:raw', $outfile or die "irc-listener: cannot write $outfile: $!\n";
$out->autoflush(1);

print $irc "NICK $nick\r\nUSER $nick 0 * :$nick\r\n";

while (my $line = <$irc>) {
    $line =~ s/\r?\n$//;
    if ($line =~ /^PING (.*)/) {
        print $irc "PONG $1\r\n";
    } elsif ($line =~ /^:\S+ 001 /) {
        print $irc "JOIN $channel\r\n";
    } elsif ($line =~ /^:\Q$nick\E!\S+ JOIN :?\Q$channel\E$/i) {
        open my $ready, '>', "$outfile.ready" or die "irc-listener: cannot write $outfile.ready: $!\n";
        print $ready "joined\n";
        close $ready;
    } elsif ($line =~ /^:\S+ PRIVMSG \Q$channel\E :(.*)$/i) {
        print $out "$1\n";
    } elsif ($line =~ /^ERROR /) {
        die "irc-listener: server said $line\n";
    }
}
