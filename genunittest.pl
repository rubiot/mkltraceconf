#!/usr/bin/perl
# \brief Script que recebe um fonte .c e gera um modulo de testes unitarios
#        com mocks para todas as dependencias externas (exceto chamadas de
#        sistema.
# \date   13/1/2016
# \author Rubio Ribeiro Canario Terra <rubio.terra@aker.com.br>

use utf8;
use open qw(:std :utf8);
use POSIX qw(strftime);
use File::Basename;
use File::Spec;
use Getopt::Long qw(:config posix_default bundling no_ignore_case);
no warnings "experimental::autoderef";

our $nocolor = "\e[0m";
our $red     = "\e[0;31m";
our $green   = "\e[0;32m";
our $yellow  = "\e[0;33m";
our $purple  = "\e[0;35m";

our (
      $unit_path,   # módulo .c que deve ser testado
      $unit,        # nome do módulo sem o .c
      $unit_c,      # nome do módulo com extensão e sem path
      $unit_txt     # conteúdo do módulo
    );
our (
      %unit_incs,   # includes do .c
      %extra_incs,  # includes dos includes do .c
      @tst_funcs
    );
our %typedef;       # typedefs para ponteiros para função
our (@vpath, @vobjs);
our ($fake_mocks, $real_mocks);
our (%undefined, %functions);
our $proj_root;      # raiz do projeto
our $ignore_pattern; # arquivos/diretórios que devem ser ignorados
our @extra_paths;    # diretórios informados pelo usuário para uso no CFLAGS
our ($overwrite, $integration_tests, $interactive);
our %inspected_incs = (); # arquivos já inspecionados por findAllDeps()

main();

sub main {
  checkParams();
  loadProjFiles();
  resolveDeps();
  genMocks();
  writeMakeFile();
  resolveAllDeps() if $integration_tests;

  print "\nProcessamento bem sucedido! Use o comando a seguir para compilar ".
        "sua nova unidade de testes:\n";
  print "  ${yellow}make -f ${\makeMakefileName()} ".
                           "${\makeUnitTestTarget()}$nocolor\n";
  print "  ${yellow}make -f ${\makeMakefileName()} ".
                           "${\makeIntTestTarget()}$nocolor\n"
    if $integration_tests;
}

sub genMocks {
  unless (gatherUndefined(runGcc())) {
    my $cc = getGccCmd();
    die qq~${red}
Nenhuma funcao indefinida foi encontrada no modulo $unit_c. Ou o modulo nao tem
dependencias externas ou ele contem erros. Se ele contiver erros de compilacao,
por favor corrija-os antes de rodar este script novamente. Use o comando abaixo
para compila-lo:${nocolor}

${yellow}$cc${nocolor}
~;
  }

  genFakeMocks();
  gatherSignatures();
  genRealMocks();
}

sub genRealMocks {
  $real_mocks = join "\n", sort {length($a) <=> length($b)}
                                map {$functions{$_}{mock}} keys %functions;
  writeUnitTestFile();
}

sub genFakeMocks {
  $fake_mocks = join("\n", map { "FAKE_VALUE_FUNC(int, $_, int, FILE, FILE);" }
                               sort keys %undefined);
  writeUnitTestFile();
}

#sub fileSubst {
#  my ($from, $to) = @_;
#  my $cpptmp = makeUnitTestUnitName().".tmp";
#
#  open(my $cppin,  '<', makeUnitTestUnitName()) or die $!;
#  open(my $cppout, '>:utf8', $cpptmp) or die $!;
#
#  while (<$cppin>) {
#    if (m§^\Q$from\E$§) {
#      print $cppout $to or die $!;
#    } else {
#      print $cppout $_ or die $!;
#    }
#  }
#
#  close $cppin or die $!;
#  close $cppout or die $!;
#  rename $cpptmp, makeUnitTestUnitName() or die $!;
#}

sub getFuncPtrType {
  my $type = shift;

  unless (exists $typedef{$type}) {
    my $id = scalar(keys %typedef) + 1;
    my $name = "functionptr$id";
    my $definition = "typedef $type;";
    $definition =~ s/(\(\*+)(\))/$1$name$2/;

    $typedef{$type}{name} = "functionptr$id";
    $typedef{$type}{definition} = $definition;
  }

  return $typedef{$type}{name};
}

sub handleParams {
  my $params = shift;
  my @new_params = ();

  # fff.h não aceita ponteiros para função diretamente, é preciso usar typedefs
  foreach my $p (split /\s*,\s*/, $params) {
    next              # Função variádica, eliminando o parâmetro ... gera mocks
      if $p eq '...'; # válidos para o fff.h, embora nem todas as funcionalidades
                      # estarão disponíveis.
    push @new_params, $p =~ /\(\*/ ? getFuncPtrType($p) : $p;
  }

  join ', ', @new_params;
}

sub gatherSignatures {
  my $output = runGcc();
  my $sig = 0;

  printp("\nprocurando assinaturas...");
  while ($output =~ /declaration of C function ‘(?<sig>(?<ret>.*?) (?<fn>\w+)\((?<par>.*?)\))’/g) {
    my ($f, $ret, $par) = ($+{fn}, $+{ret}, $+{par});
    my $void = $ret eq 'void';

    $functions{$f}{isvoid} = $void;
    $functions{$f}{params} = handleParams($par);
    $functions{$f}{ret}    = $ret;
    $functions{$f}{fake}   = makeMockName($f);
    $functions{$f}{mock}   = makeMock($f);
    print "  $functions{$f}{mock}\n";

    $sig++;
  }

  # Ex: :27:76: error: conflicting declaration of C function ‘int ak_wi...)’
  if ($interactive &&
      $output =~ /:\d+:\d+: error: (?!conflicting declaration of C function)/) {
    my $cmd = getGccCmd();
    print "O GCC encontrou outros erros alem dos erros de funcao indefinida. ".
          "Voce pode tentar corrigi-los manualmente antes de continuar. Use o".
          " comando a seguir para testar a compilacao, depois volte e pressio".
          "ne ENTER para continuar.\n".
          "  $yellow$cmd 2>&1 | less -R -p ': error: '$nocolor";
    scalar <STDIN>;
  }

  die "${red}Nenhuma assinatura encontrada${nocolor}\n\t".getGccCmd()."\n" unless $sig;
}

sub gatherUndefined {
  my $output = shift;
  my $found = 0;

  printp("\nprocurando funcoes indefinidas...");

  while ($output =~ /undefined reference to `(.*?)(\(.*?\))?'/g) {
    my $f = $1;
    # saltando funcoes C++, e funções internas (aparecem quando existe ao menos
    # um teste vazio).
    next if $f =~ /::|\s|__cxa_pure_virtual|__gxx_personality_v0/;
    next if $f eq 'main'; # main nao nos interessa
    print "  $1\n" unless $undefined{$1};
    $undefined{$f}++;
    $found++;
  }

  $found;
}

sub writeUnitTestFile {
  open(my $outh, '>:utf8', makeUnitTestUnitName()) or die $!;
  print $outh getUnitTest() or die $!;
  close $outh or die $!;
}

sub writeIntTestFile {
  open(my $outh, '>:utf8', makeIntTestUnitName()) or die $!;
  print $outh getIntTest() or die $!;
  close $outh or die $!;
}

sub checkParams {
  die showHelp() unless $#ARGV >= 0 && $ARGV[$#ARGV] !~ '^-';

  my @ignore;
  my $extra_paths_;

  GetOptions("exclude|x=s" => \@ignore,
             "test-funcs|f=s", \@tst_funcs,
             "overwrite|o", \$overwrite,
             "int-tests|i", \$integration_tests,
             "path|p=s", \$extra_paths_,
             "interactive|n", \$interactive,
            );

  @ignore = split /,/, join(',', @ignore);
  $ignore_pattern = join '|', @ignore;

  @tst_funcs = split /,/, join(',', @tst_funcs);
  $unit_path = $ARGV[$#ARGV];

  @extra_paths = split /,/, $extra_paths_;

  print "    tst_funcs:\n\t". join "\n\t", @tst_funcs;
  print "\n     ignore:\n\t". join "\n\t", @ignore;
  print "\n  unit_path: $unit_path\n";
  print "\n  overwrite: $overwrite\n";
  print "\ninteractive: $interactive\n";
  print "\n      paths:\n\t". join "\n\t", @extra_paths;
  print "\n";

  my ($name, $path, $suffix) = fileparse($unit_path, qr/\..*?$/);
  ($unit, $unit_c) = ($name, $name.$suffix);

  die "${red}Arquivo de testes ja' existe! (".makeUnitTestUnitName()."). Use a ".
      "opcao -o ou --overwrite se quiser sobrescreve-lo.${nocolor}"
    if !$overwrite && -e makeUnitTestUnitName();

  die "${red}Fonte $unit_path nao encontrado${nocolor}"
    unless -e $unit_path;

  die "${red}Somente fontes .c sao tratados por enquanto${nocolor}"
    if $unit_path !~ /\.c$/;

  open(SRC, $unit_path) or die $!;
  $unit_txt = do { local $/; <SRC> };
  close SRC;

  #  if (length($_tst_funcs)) {
  #    open(FUNCS, $_tst_funcs) or die $!;
  #    @tst_funcs = <FUNCS>;
  #    close FUNCS;
  #  }

  $proj_root = getProjectRoot();
  #exit;
}

sub showHelp {
qq~GenUnitTest

Script que recebe um fonte .c e cria um modulo de testes unitarios e um Makefile
para compila-lo. Sao gerados mocks para todas as funcoes externas ao modulo
(exceto chamadas de sistema). O script deve ser executado no mesmo diretorio do
modulo .c a ser testado e deve existir um diretorio tests/.

O script foi feito para ser usado dentro de um repositorio git. As dependencias
precisam estar versionadas ou nao serao encontradas. O script tambem depende do
ag (https://github.com/ggreer/the_silver_searcher).

Uso:
  $0 [opcoes] -- <fonte .c>

  --exclude=<pattern> Use para excluir arquivos/diretorios com o padroes indi-
         -x <pattern> cados.

  --test-func=<funcs> Lista das funcoes do modulo para as quais deve-se gerar
           -f <funcs> casos de teste.

       --path=<paths> Use para incluir diretorios extra para localizar headers.
           -p <paths>

          --overwrite Se o modulo de testes unitarios ja' existir, sobrescreve-lo.
                   -o O padrao nesse caso e' abortar.

          --int-tests Tentar gerar tambem o modulo de testes de integracao.
                   -i

        --interactive Use para ativar o modo interativo, em que voce podera' to-
                   -n mar decisoes durante o processamento.

~;
}


sub getProjectRoot {
  my $dir = qx/git rev-parse --show-toplevel/;
  chomp $dir;
  File::Spec->abs2rel($dir);
}

sub loadProjFiles {
  @proj_files = qx§ git ls-files -- $proj_root | grep \.h\$ §;
  @proj_files = map { chomp; $_ } @proj_files;

  @proj_files = grep { !/$ignore_pattern/ } @proj_files
    if length($ignore_pattern);
}

sub getGitAuthor {
  my $out = qx§git config --global --list | grep '^user\.'§;
  my ($name)  = $out =~ m§user\.name=(.*?)\n§s;
  my ($email) = $out =~ m§user\.email=(.*?)\n§s;

  "$name <$email>";
}

sub makeUnitTestUnitName {
  "tests/${unit}_unit_test.cpp"
}

sub makeIntTestUnitName {
  "tests/${unit}_int_test.cpp"
}

sub makeUnitTestClassName {
  my $c = $unit;
  $c =~ s/_([a-z])/\U\1/g;
  ucfirst "${c}UnitTest";
}

sub makeIntTestClassName {
  my $c = $unit;
  $c =~ s/_([a-z])/\U\1/g;
  ucfirst "${c}IntTest";
}

sub getGccCmd {
  "gcc -o ${unit}_unit_test "
     .getCFlags()." "
     .getLDFlags(). " "
     .makeUnitTestUnitName()." "
  ;
}

sub getCFlags {
  getGccInc();
}

sub getLDFlags {
  #'/usr/lib/libgtest.a /usr/lib/libgmock.a'
}

sub getGccInc {
  my @incs = ('./', '/usr/src/gtest', '/usr/src/gmock');

  push @incs, map {  $unit_incs{$_}{dir} } keys %unit_incs;
  push @incs, map { $extra_incs{$_}{dir} } keys %extra_incs;
  push @incs, @extra_paths;

  @incs = uniq(@incs);         # eliminando duplicatas
  @incs = grep { /\S/ } @incs; # eliminando brancos (TODO: fix!)
  @incs = sort { length($a) <=> length($b) } @incs;

  #print "gccinc::::\n";
  #print join "\n", @incs;

  join "\\\n  ", map{ "-I$_" } @incs;
}

sub getIncludes {
  my $file = shift;
  my %inc;

  open(SRC, $file) or die $!;
  while (<SRC>) {
    if (/#include\s+"(.*?)"/g) {
      my $header = $1;
      my $path = findHeaderPath($header);
      #printp("include found: $1");
      $inc{"$path$header"}++;
    }
  }
  close SRC;
  #printp(join("\n", sort keys %inc));

  sort keys %inc;
}

sub runGcc {
  my $cmd = getGccCmd();
  #print "$cmd\n";
  scalar qx§$cmd 2>&1§;
}

sub runMake {
  my $cmd = sprintf("make -f %s %s", makeMakefileName(), makeIntTestTarget());
  writeMakeFile();
  scalar qx§$cmd 2>&1§;
}

sub gatherObjDeps {
  my %_vpath;
  my %_objs;

  print "\nprocurando as dependencias de objetos...\n";
  foreach my $f (keys %undefined) {
    print "$yellow  funcao $f()...$nocolor\n";
    my @modules = findFuncDefinition($f);
    my $module = "";

    unless (scalar(@modules)) {
      warning("  Funcao $f() nao encontrada.");
      next;
    }

    if (scalar(@modules) > 1) {
      warning("  A funcao $f() esta' definida em mais de um fonte! Use a opcao ".
              "--exclude ou -x para ignorar os fontes indesejados.");
      my $i = 0;
      foreach my $m (@modules) {
        print "    ".($interactive ? $i : "")." $m\n";
        $i++;
      }
      if ($interactive) {
        print "Informe qual dos fontes deve ser utilizado: ";
        $i = <STDIN>;
        $i =~ s/\D//g;
        $i = 0 if $i < 0 || $i > $#modules;
        $module = $modules[$i];
      }
    }

    $module ||= shift @modules; # usando o primeiro por padrao

    my ($name, $path, $suffix) = fileparse($module, qr/\..*?$/);
    chomp $name, $path;
    $_vpath{$path}++;
    $_objs{"${name}.o"}++;

    findAllDeps($module, 1);
  }

  push @vpath, sort keys %_vpath;
  push @vobjs, sort keys %_objs;

  print "\nvpath:\n  ".join "\n  ", sort keys %_vpath;
  print "\n\nobjs:\n  ".join "\n  ", sort keys %_objs;
  print "\n";
}

sub gatherIncludeDeps {
  my $gcc_output = shift;
  my $deps = 0;

  while ($gcc_output =~ /fatal error: (.*?): No such file or directory/g) {
    my $header = $1;
    print "  $header\n";
    my $path = findHeaderPath($header);

    next unless length($path);

    $extra_incs{$header}{dir} = $path;
    $extra_incs{$header}{file} = $path.$header;

    $deps++;
  }

  $deps;
}

sub resolveDeps {
  printp("mapeando dependencias...");

  my $fff = findHeaderPath("fff.h")."fff.h";
  foreach my $path (getIncludes($unit_c), $fff) {
    $path =~ m§^(?<dir>.*?/)?(?<file>[^\/]+\.h)$§;
    die "path invalido: $path" unless length $+{file};
    $unit_incs{$+{file}}{dir} = $+{dir} || './';
    $unit_incs{$+{file}}{file} = $path;
  }

  writeUnitTestFile();

  my $gcc_output;
  do {
    $gcc_output = runGcc();
  } while gatherIncludeDeps($gcc_output);
}

sub addExtraPath {
  my $header = shift;

  my ($file, $dir) = fileparse($header);
  return if $file !~ /\.h$/ || exists $extra_incs{$file};

  $extra_incs{$file}{dir} = $dir;
  $extra_incs{$file}{file} = $header;

  #print "$green novo header: $header$nocolor\n";
}

sub findAllDeps {
  my ($file, $level) = @_;

  return if exists $inspected_incs{$file};
  $inspected_incs{$file}++;

  return unless -e $file;

  #  if ($file =~ /akhwsig\.h$/) {
  #    print "bingo!";
  #  }

  #  print ('+' x $level);
  #  print " $file\n";

  addExtraPath($file);

  foreach my $include (getIncludes($file)) {
    addExtraPath($include);
    findAllDeps($include, ++$level);
  }
}

sub resolveAllDeps {
  printp("mapeando dependencias adicionais...");

  writeIntTestFile();

  foreach my $include (keys %unit_incs) {
    findAllDeps($unit_incs{$include}{file}, 1);
  }

  #writeMakeFile();

  print "localizando funcoes indefinidas (2a vez)...\n";
  %undefined = ();
  do {
    gatherObjDeps();
  } while gatherUndefined(runMake());
}

sub findFuncDefinition {
  my $func = shift;
  return undef if $func eq 'main';

  # usando o ag, pois o git-grep so' faz match linha a linha
  my $cmd = "ag --cc --cpp -l ".
            "'\\b(\\Q$func\\E)\\s*\\([^;{()]*\\)\\s*\\{' ".
            "$proj_root";
  my @files = qx/$cmd/;

  #print "$cmd\n";

  @files = map { chomp; $_ } @files;
  @files = grep { !/$ignore_pattern/ } @files
    if length($ignore_pattern);

  @files;
}

sub findHeaderPath {
  my $_header = shift;
  my $header;
  my @header_path = grep { /\b$_header$/ } @proj_files;

  if (scalar(@header_path) > 1) {
    warning("  Multiplas ocorrencias para $_header. Use a opcao --exclude ou -x ".
            "para excluir os diretorios/arquivos indesejados.$nocolor\n");
    my $i = 0;
    foreach my $h (@header_path) {
      print "   ".($interactive ? $i : "")." $h\n";
      $i++;
    }
    if ($interactive) {
      print "Informe qual dos headers deve ser utilizado: ";
      $i = <STDIN>;
      $i =~ s/\D//g;
      $i = 0 if $i < 0 || $i > $#header_path;
      $header = $header_path[$i];
    }
  }

  $header ||= shift @header_path; # usando o primeiro por padrao
  chomp $header;

  unless ($header) {
    warning("Header nao encontrado: \"$_header\".");
    return "";
  }

  my ($name, $path) = fileparse($header);

  $path;
}

# nome atribuido ao mock
sub makeMockName {
  my $f = shift;
  "${f}0";
}

sub makeMock {
  my $f = shift;

  sprintf("FAKE_%s_FUNC(%s%s%s%s);",
    $functions{$f}{isvoid} ? 'VOID': 'VALUE',
    $functions{$f}{isvoid} ? '' : "$functions{$f}{ret}, ",
    $functions{$f}{fake},
    $functions{$f}{params} ? ', ' : '',
    $functions{$f}{params});
}

sub makeResetMacro {
  my $f = shift;
  "  FAKE($functions{$f}{fake})\\\n";
}

sub makeInjectMacro {
  my ($f, $maxlen) = @_;
  sprintf("#define %s%s%s\n", $f,
                              ' ' x ($maxlen-length($f)+1),
                              $functions{$f}{fake});
}

sub makeCustom
{
  my $f = shift;

  return '' if $functions{$f}{isvoid}; # nao faz sentido para funcoes void

  my $i;
  my $args = join ', ',
             map { $i++; "$_ arg$i" } split(/\s*,\s*/, $functions{$_}{params});
  $i = 0;
  my $pars = join ', ',
             map { $i++; "arg$i" } split(/\s*,\s*/, $functions{$_}{params});

qq~$functions{$f}{ret} ${f}_callreal_custom($args)
{
  if ($functions{$f}{fake}_fake.return_val)
    return $functions{$f}{fake}_fake.return_val;
  return $f($pars);
}

~;
}

sub getUnitTest {
  my $class_name = makeUnitTestClassName();
  my $header = makeModuleHeader(makeUnitTestUnitName());

  my $typedefs = join "\n", map { $typedef{$_}{definition} } sort keys %typedef;
  my $includes;
  my $mocks = $real_mocks || $fake_mocks;
  my $resets = "#define FFF_FAKES_LIST(FAKE)\\\n";
  my $injects;
  my $customs;
  my $maxlen;

  map { $maxlen = length($_) if length($_) > $maxlen } keys %functions;

  foreach my $f (sort {length($a) <=> length($b)} keys %functions) {
    $resets  .= makeResetMacro($f);
    $injects .= makeInjectMacro($f, $maxlen);
    $customs .= makeCustom($f);
  };

  $includes = join "\n", map { "#include \"$_\"" }
                             sort {length($a) <=> length($b)} keys %unit_incs
    if length($real_mocks);
  $includes ||= '#include "fff.h"'; # header obrigatório

qq§$header

#include "gmock/gmock.h"
#include "gtest/gtest.h"
$includes

using namespace std;
using namespace testing;

DEFINE_FFF_GLOBALS;

$typedefs

$mocks

$resets
$injects
#include "$unit_c"

class $class_name: public testing::Test
{
protected:
  virtual void SetUp()
  {
    FFF_FAKES_LIST(RESET_FAKE);
    FFF_RESET_HISTORY();
  }

  virtual void TearDown()
  {

  }
};

TEST_F($class_name, function_scenario_expectation)
{

}

§;
}

sub makeModuleHeader {
  my $unit_name = shift;
  my $date = strftime("%d/%m/%Y %H:%M:%S", localtime(time));
  my $author = getGitAuthor();

  $unit_name =~ s/^tests\///;

  $header =
qq§/*!
 * \\file   $unit_name
 * \\brief  Testes do modulo $unit_c
 * \\date   $date
 * \\author $author
 */§;

  $header =~ s§[ /]\*[!/]?§##§g if $unit_name =~ /GNUmakefile/;

  $header;
}

sub getIntTest {
  my $class_name = makeIntTestClassName();
  my $header = makeModuleHeader(makeIntTestUnitName());

  my $includes;

  $includes = join "\n", map { "#include \"$_\"" } @unit_headers
    if length($real_mocks);

qq§$header

#include "gmock/gmock.h"
#include "gtest/gtest.h"

using namespace std;
using namespace testing;

$includes

#include "$unit_c"

class $class_name: public testing::Test
{
protected:
  virtual void SetUp()

  {

  }

  virtual void TearDown()
  {

  }
};

§;
}

sub uniq {
  keys { map { $_ => 1 } @_ };
}

sub getVPath {
  join "\\\n  ", sort { length($a) <=> length($b) }
                      uniq( findHeaderPath("fff.h"), './tests', @vpath );
}

sub getVObjs {
  join "\\\n  ", sort { length($a) <=> length($b) } uniq(@vobjs);
}

sub makeMakefileName {
  "GNUmakefile.$unit";
}

sub makeUnitTestTarget {
  "${unit}_unit_test";
}

sub makeIntTestTarget {
  "${unit}_int_test";
}

sub writeMakeFile {
  open(my $outh, '>:utf8', makeMakefileName()) or die $!;
  print $outh genMakeFile() or die $!;
  close $outh or die $!;
}

sub genMakeFile {
  my $target_tu = makeUnitTestTarget();
  my $target_ti = makeIntTestTarget();

#######################
# unit tests
#######################
my $txt =
qq~${\makeModuleHeader(makeMakefileName())}

GTEST_ROOT = /usr/src/gtest
GMOCK_ROOT = /usr/src/gmock
GTEST_LIB = /usr/lib/libgtest.a
GMOCK_LIB = /usr/lib/libgmock.a
VPATH_TEST = \$\{GTEST_ROOT\}/src \$\{GMOCK_ROOT\}/src
CFLAGS_TEST = -I\$\{GTEST_ROOT\}/include -I\$\{GMOCK_ROOT\}/include
LFLAGS_TEST = -I\$\{GTEST_ROOT\}/include -I\$\{GMOCK_ROOT\}/include
GCOVR_XML=coverage_unit.junit.xml

TEST_UNIT_FILES= $target_tu

CFLAGS = -Wall -O0 -g -fprofile-arcs -ftest-coverage -fPIC
CFLAGS += ${\getCFlags()}

VFLAGS = --leak-check=full --leak-resolution=high --track-origins=yes

$target_tu: CFLAGS += \$\{CFLAGS_TEST\}
$target_tu: LFLAGS += \$\{LFLAGS_TEST\}

VPATH += \\
  \$\{VPATH_TEST\}\\
  ${\getVPath()}

CXXFLAGS=\$(CFLAGS)

check:
\tmake clean && make check_unit && make clean && make check_int

check_unit: \$(TEST_UNIT_FILES)
\tfor tst in \$^;\\
\tdo\\
\t\tvalgrind \$(VFLAGS) ./\$\$tst --gtest_output=xml:\$\{GCOVR_XML\} &&\\
\t\t\tgcovr -r . -e '.*/tests/';\\
\tdone

check_int: \$(TEST_INT_FILES)
\tfor tst in \$^;\\
\tdo\\
\t\tvalgrind \$(VFLAGS) ./\$\$tst;\\
\tdone

clean:
\trm -f *.\{o,gcda,gcno\} \$(OBJS) \$(TEST_UNIT_FILES) \$(TEST_INT_FILES) \$(GCOVR_XML)

$target_tu: \\
  gmock_main.cc\\
  $target_tu.o
\t\$(CXX) \$(CFLAGS) -lpthread -lgcov -o \$\@ \$^ \$\{GTEST_LIB\} \$\{GMOCK_LIB\}
~;

#######################
# integration tests
#######################
$txt .= qq~
TEST_INT_FILES= $target_ti

$target_ti: CFLAGS += \$\{CFLAGS_TEST\}
$target_ti: LFLAGS += \$\{LFLAGS_TEST\}

$target_ti: \\
  gmock_main.cc\\
  $target_ti.o\\
  ${\getVObjs()}
\t\$(CXX) \$(CFLAGS) -lpthread -o \$\@ \$^ \$\{GTEST_LIB\}
~
  if $integration_tests;

  $txt;
}

sub printp {
  print "$_[0]\n";
}

sub warning {
  print "${purple}$_[0]${nocolor}\n";
}

sub error {
  print "${red}$_[0]${nocolor}\n";
}
