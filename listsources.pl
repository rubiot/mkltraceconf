#! /usr/bin/env perl
# Utilitario que lista os fontes usados na compilacao de um binario de debug
use v5.18;

my $binary = $ARGV[0];

say "binary: $binary\n";

my @symbols = qx/nm -l $binary/;
my %sources = ();

foreach (@symbols) {
  next unless /(\S+):/;
  my $s = qx/realpath $1/;
  $sources{$s}++;
}

foreach (sort keys %sources) {
  print $_;
}
