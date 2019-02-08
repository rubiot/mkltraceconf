#! /usr/bin/env perl
use v5.10;
use Socket;

my ($start, $count) = @ARGV;
#say "start=$start";
#say "count=$count";
my $first = unpack "N", inet_aton($start);

foreach $ip ($first..($first + $count - 1)) {
  say join '.', unpack 'C4', pack 'N', $ip;
}
