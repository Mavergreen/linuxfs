#!/usr/bin/perl
# platform: macOS-only -- a stand-in for root's mount daemon (tools/mountd.c), for fs-test.sh's ask: cases
#   usage: mountd-stub.pl SOCKET LOG STEP...
# Listens on SOCKET (as whoever runs it), writes SOCKET.ready, and serves one connection by its STEPs, in order:
#   say:TEXT   write TEXT and a newline (\t in TEXT is a tab)
#   read       read one line; logs "got: LINE" (tabs as \t), or "got-eof"
#   peek       logs "early N": how many bytes the client had sent before this step (0: nothing yet)
#   sleep:N    sleep N seconds (fractions allowed)
#   drain      read until EOF; logs "drained N" and the bytes as "bytes: ..." (tabs as \t, newlines as \n)
#   close      close the connection
# Two STEPs replace serving: full (listen with a backlog of one, fill it with its own connects until one is refused, and
# never accept: a full backlog, so a connect is refused, ECONNREFUSED) and stale (bind, then exit: a socket file nothing
# listens on). Every accept is logged as "connected". The whole run is bounded at 30 s.
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;
use Time::HiRes qw(sleep);

my ($path, $logf, @steps) = @ARGV;
alarm 30;
$SIG{PIPE} = 'IGNORE';	# a client that left: writes fail, and the steps go on
unlink $path;
open(my $log, '>>', $logf) or die "log: $!";
$log->autoflush(1);
sub ready { open(my $r, '>', "$path.ready") or die; close $r; }
sub shown { my $s = shift; $s =~ s/\t/\\t/g; $s =~ s/\n/\\n/g; return $s; }
if (@steps && $steps[0] eq 'stale') {
	my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path) or die "bind: $!";
	close $s;
	ready();
	exit 0;
}
my $l = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $path, Listen => 1) or die "listen: $!";
ready() unless @steps && $steps[0] eq 'full';
if (@steps && $steps[0] eq 'full') {
	my @held;
	for (1 .. 64) {
		my $h = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $path) or last;
		push @held, $h;
	}
	print $log 'full after ' . scalar(@held) . "\n";
	ready();
	sleep 1 while 1;
}
my $c = $l->accept() or exit 1;
print $log "connected\n";
for my $step (@steps) {
	if ($step =~ /^say:(.*)$/s) {
		my $t = $1;
		$t =~ s/\\t/\t/g;
		print $c "$t\n";
		$c->flush;
	} elsif ($step eq 'read') {
		my $line = <$c>;
		if (defined $line) { chomp $line; print $log 'got: ' . shown($line) . "\n"; }
		else { print $log "got-eof\n"; }
	} elsif ($step eq 'peek') {
		my $n = 0;
		if (IO::Select->new($c)->can_read(0)) {
			my $buf = '';
			$n = sysread($c, $buf, 4096, 0) || 0;
			print $log 'early-bytes: ' . shown($buf) . "\n" if $n;
		}
		print $log "early $n\n";
	} elsif ($step =~ /^sleep:([0-9.]+)$/) {
		sleep $1;
	} elsif ($step eq 'drain') {
		my ($all, $buf) = ('', '');
		while (sysread($c, $buf, 4096)) { $all .= $buf; }
		print $log 'drained ' . length($all) . "\n";
		print $log 'bytes: ' . shown($all) . "\n";
	} elsif ($step eq 'close') {
		close $c;
	} else {
		die "unknown step $step";
	}
}
exit 0;
