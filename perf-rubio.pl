#!/usr/bin/env perl
#
# Author: Rubio R. C. Terra <rubio.terra@ogasec.com>
#

use v5.10;
use Term::ANSIColor;
use Data::Dumper;

our %multiplier = (
	''  => 1,
	'K' => 1000,
	'M' => 1000000,
	'G' => 1000000000,
);

our $max_error_rate = 2; # taxa de erro maxima tolerada

die &help if $#ARGV < 2;
our ($duration, $genome, $ports) = @ARGV;
&main();

sub main {
	my %params = (
		burst => 1,
		sleep => 0,
	);

	say colored("gerando estatisticas de controle...", 'yellow');
	%control = run($duration, $genome, $ports, $params{burst}, $params{sleep});

	if (error_rates_under_threshold(\%control)) {
		tweak_burst(\%control, \%params);
	} else {
		%control = ( throughput => '0 b/s', throughput_bytes => 0 );
		tweak_sleep(\%control, \%params);
	}

	say '=' x 80;
	say colored("Melhores resultados obtidos com burst = $params{burst} e sleep = $params{sleep}", 'blue');
	say colored("            throughput: $control{throughput}", 'blue');
	say colored("   taxa de erros local: $control{local}%", 'blue');
	say colored("  taxa de erros remota: $control{remote}%", 'blue');
}

sub tweak_sleep {
	my ($control, $params, $level) = @_;
	my %my_params  = %$params;
	my %best_result = %$control;

	say '│ ' x $level++, '┌─', colored("tentando reduzir a taxa de erros para superar o throughput de $$control{throughput}...", 'yellow');
	while (1) {
		my %result = run($duration, $genome, $ports, $my_params{burst}, ++$my_params{sleep}, $level);
		last if $result{throughput_bytes} < $best_result{throughput_bytes};
		if (error_rates_under_threshold(\%result)) {
			%best_result = %result;
			last;
		}
	}

	if ($best_result{throughput_bytes} > $$control{throughput_bytes}) {
		say '│ ' x --$level, '└─', colored("throughput aumentado para $best_result{throughput}!", 'green');
		%$control = %best_result;
		%$params  = %my_params;
		return tweak_burst($control, $params, $level);
	}

	say '│ ' x --$level, '└─', colored("nao foi possivel superar o throughput de $$control{throughput}", 'red');
	0;
}

sub tweak_burst {
	my ($control, $params, $level) = @_;
	my %my_params  = %$params;
	my %best_result = %$control;

	say '│ ' x $level++, '┌─', colored("tentando aumentar o burst para superar o throughput de $$control{throughput}...", 'yellow');
	while (1) {
		my %result = run($duration, $genome, $ports, $my_params{burst} + 1, $my_params{sleep}, $level);
		unless (error_rates_under_threshold(\%result)) {
			# vamos tentar aumentar o sleep para manter o burst atual
			$my_params{burst}++;
			unless (tweak_sleep(\%best_result, \%my_params, $level)) {
				# nao funcionou, voltemos ao burst anterior
				$my_params{burst}--;
				last;
			}
			%result = %best_result;
		}
		last if $result{throughput_bytes} < $best_result{throughput_bytes};
		%best_result = %result;
		$my_params{burst}++;
	}

	if ($best_result{throughput_bytes} > $$control{throughput_bytes}) {
		say '│ ' x --$level, '└─', colored("throughput aumentado para $best_result{throughput}!", 'green');
		%$control = %best_result;
		%$params  = %my_params;
		return 1;
		#return tweak_sleep($control, $params); 
	}

	say '│ ' x --$level, '└─', colored("nao foi possivel superar o throughput de $$control{throughput}", 'red');
	0;
}

sub error_rates_under_threshold {
	my $current = shift;

	$$current{local} <= $max_error_rate && $$current{remote} <= $max_error_rate;
}

sub run {
	my ($duration, $genome, $ports, $burst, $sleep, $level) = @_;
	$level //= 0;
	print '│ ' x $level, "burst $burst, sleep $sleep... ";

	my $output = qx{./perf_imix.sh $duration $genome $ports $burst $sleep};

	$output =~ /Em pacotes: (?<local>\d+(\.\d+)?).*?Em pacotes: (?<remote>\d+(\.\d+)?).*Throughput: (?<throughput>\d+(\.\d+)?) (?<unit>[KMG]?)b\/s/s;

	my %result = (
		local            => $+{local}+0, 
		remote           => $+{remote}+0,
		throughput       => "$+{throughput} $+{unit}b/s",
		throughput_bytes => $+{throughput} * $multiplier{$+{unit}}
	);

	#say Dumper(\%result);
	#print $output . "\n\n";

	say "throughput $result{throughput}," .
	    " erro local "  . colored("$result{local}\%", $result{local} > $max_error_rate ? 'red' : 'green') . "," .
	    " erro remoto " . colored("$result{remote}\%", $result{remote} > $max_error_rate ? 'red' : 'green');

	%result;
}

sub help {
	qq~$0 <tempo do teste em segundos> <genoma IMIX> <# de portas>
~;
}
