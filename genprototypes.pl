#! /usr/bin/perl

# \brief  Script que recebe um fonte .c e gera prototipos para todas as funcoes
#         estaticas.
# \date   10/6/2016
# \author Rubio Ribeiro Canario Terra <rubio.terra@aker.com.br>

use utf8;
use open qw(:std :utf8);
use Getopt::Long qw(:config posix_default bundling no_ignore_case);
use Term::ANSIColor;
use Test::More;

our ($run_tests, $max_column, $src_file);
our (@prototypes);

checkArgs();
#$max_column = 80;
main();

sub main {
  parseSrc(getFileTxt($src_file));

  print join "\n", @prototypes;
  print "\n\n";
}

sub checkArgs {
  die showHelp() unless $#ARGV >= 0;

  GetOptions(
    "--max-column|c=i" => \$max_column,
    "--run-tests|t"    => \$run_tests,
  );

  $src_file = $ARGV[$#ARGV];
}

sub showHelp {
  <<FIM;
Uso:
  $0 [opcoes] <header>

Opcoes:
  --max-columns=<N>, -c  Maximo de colunas por linha
  --run-tests, -t        Executar testes unitarios
FIM
}

sub parseSrc {
  my $code = shift;

  ## stripping comments
  $code =~ s%//.*?$%%mg;
  $code =~ s%/\*.*?\*/%%mg;

  my $reserved = qr/
    \b (?: return | if | while | for | do ) \b
  /x;

  my $identifier = qr/
    (?!$reserved)
    (?:
      \b\w+\b
    )/x;

  my $qualifier = qr/
    (?: (static|inline|__inline) )
  /x;

  my $params_list = qr/
    (?:
     \( \s*
        (?:
          [\w\s,*]+ |
          \[ [^\],()*]*? \] |
          \( [^\)]+ \)
        )*
        (?: \.\.\. )? \s*
     \)
    )
  /x;

  my $simple_type = qr/
    (?:
      (?: (const|unsigned|struct|enum|union) \s+ )*
      $identifier \s*
      [*\s]*
    )
  /x;

  my $function_ptr = qr/
    (?:
      $simple_type    \s*
      \(              \s*
         \*           \s*
         $identifier? \s*
      \)              \s*
      $params_list
    )
  /x;

  my $type = qr/ (?: $simple_type | $function_ptr ) /x;

  my $prototype = qr/
    ^                      \s*
      (?<qua>$qualifier )? \s*
      (?<ret>$type)        \s*
      (?<nam>$identifier)  \s*
      (?<par>$params_list) \s*
    (?<body> ; | \{)
  /mx;

  # TODO: Reconhecer protótipos com GCC flags (_THROW_, EXPORT, etc.)
  while ($code =~ /$prototype/g) {
    addPrototype($&, $+{qua}, $+{ret}, $+{nam}, $+{par}, $+{body});
  }
}

sub getFileTxt {
  open(SRC, shift) || die $!;
  my $txt = do { local $/; <SRC> };
  close SRC;

  $txt;
}

sub addPrototype {
  my ($proto, $qual, $ret, $name, $params_list, $body) = @_;

  $ret         =~ s/\s+(?=$|\*)//g;
  $name        =~ s/\s+$//g;
  $proto       =~ s/\s+/ /g;
  $proto       =~ s/^\s+|\s+\{$//g;
  $params_list =~ s/\n|  //g;
  $params_list =~ s/,(?! )/, /g;

  return # ignorando prototipos ja declarados
    unless $qual eq 'static' && $body eq '{';

  my $p = $max_column ? formatPrototype($qual, $ret, $name, $params_list)
                      : $proto;

  push @prototypes, $p;
}

sub formatPrototype {
  my ($qualifier, $return_type, $name, $params_list) = @_;
  my @params = splitParams($params_list);
  my $max_size; # tamanho do maior parametro

  map { $max_size = length($_) if length($_) > $max_size } @params;

  my $p = length($qualifier) ? "$qualifier " : "";
  $p .= "$return_type $name(";

  # calculando a indentacao com base no tamanho do maior parametro
  my $indent = ( length($p) + $max_size + length(");") ) > $max_column
                 ? 2
                 : length($p);

  my $line = $p;

  for my $i (0..$#params) {
    my $suffix     = $i == $#params ? ");" : ", ";
    my $next_param = $params[$i] . $suffix;

    if (length($line . $next_param) > $max_column) { # quebrar a linha?
      $p =~ s/ $//;
      $line = "\n" . (" " x $indent);
      $p .= $line
    }

    $p    .= $next_param;
    $line .= $next_param;
  }

  $p;
}

sub splitParams {
  my $params_list = shift;
  my @params = ();
  my $param = qr/
    \s*
    (?<param>
      (?:
        [\w\s*]+ |
        \[ [^\],()*]*? \] |
        \( [^\)]+ \) |
        \.\.\.
      )+
    )
    (?: , | $ )
  /x;
$params_list =~ s/^\((.*?)\)$/$1/;
  while ($params_list =~ /$param/g) {
    push @params, $+{param};
  }

  @params;
}
