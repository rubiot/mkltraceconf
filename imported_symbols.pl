#! /usr/bin/env perl

use Term::ANSIColor;

my ($bin) = @ARGV;
my @imported;
my %exported;
my %opts = (
    omit_not_found => 0,
    demangle_cplusplus_symbols => 1,
);

$opts{demangle_cplusplus_symbols} = 0 # nao tem c++filt?
  unless qx/c++filt --version/;

main();

sub main {
  getExportedFunctions();
  getImportedFunctions();

  my %libs;
  foreach my $i (@imported) {
    my $what = whatExports($i);
    next if $what eq 'not found' && $opts{omit_not_found};
    push @{$libs{$what}}, $i;
  }

  foreach my $l (sort keys %libs) {
    print colored($l, 'bold')."\n";
    foreach my $i (sort @{$libs{$l}}) {
      $i = qx/c++filt $i/ if $i =~ /^_/ && $opts{demangle_cplusplus_symbols};
      chomp $i;
      print colored("  $i\n", 'yellow');
    }
  }
}

sub getExportedFunctions {
  die colored($bin, 'bold')." not found\n"
    unless -e $bin;

  foreach $lib (qx/ldd $bin/) {
    next unless $lib =~ /=>\s+(?<lib>\S+)/;
    $lib = $+{lib};
    foreach (qx/nm -D $lib/) {
      next unless /\bT\s+(?<exp>\w+)/;
      $exported{$+{exp}} = $lib;
    }
  }
}

sub getImportedFunctions {
  foreach (qx/nm -D $bin/) {
    next unless /\bU\s+(\w+)/;
    push @imported, $1;
  }
}

sub whatExports {
  my $f = shift;
  exists $exported{$f} ? $exported{$f} : "not found"
}
