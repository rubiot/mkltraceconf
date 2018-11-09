#!/usr/bin/env perl

use v5.10;
use Fcntl;
use Symbol;
use IO::Select;
use IPC::Open2;
use Term::ANSIColor;

our $DEBUG = 1;
our $anon = 0;          # sequencial for naming anonymous structs
our @typedefs = ();     # stores all typedefs to print at the end
our %typedefs_map = (); # used to avoid duplicate anonymous typedefs
our @prototypes = ();   # stores all prototypes to print at the end

our ($lib) = @ARGV;

# maps between C types and ltrace types
our %types = (
  'void'               => 'void',
  'int'                => 'int',
  'double'             => 'double',
  'float'              => 'float',
  'long'               => 'long',
  'char'               => 'char',
  'short'              => 'short',
  'long long'          => 'long',
  'unsigned'           => 'uint',
  'unsigned int'       => 'uint',
  'unsigned long'      => 'ulong',
  'unsigned char'      => 'uint',
  'unsigned short'     => 'ushort',
  'unsigned long long' => 'ulong',
  'void *'             => 'addr',
  'FILE *'             => 'file',
  'char *'             => 'string',
  'char*'              => 'string',

  # ignored structs
  #'xmlDocPtr',         => 'addr',
  #'xmlXPathContextPtr' => 'addr',
  #'pthread_mutex_t'    => 'addr',
  #'pthread_rwlock_t'   => 'addr',
  #'X509 *'             => 'addr',
  #'http_cache_params_' => 'addr',
  #'contexto_smtp'      => 'addr',
  #'ssl_applet_conf'    => 'addr',

  # ltrace types, used to end recursion
  'uint'               => 'uint',
  'ulong'              => 'ulong',
  'ushort'             => 'ushort',
  'addr'               => 'addr',
  'file'               => 'file',
  'string'             => 'string',
);

# setting up gdb session
$GDBIN  = gensym();
$GDBOUT = gensym();
our $pid = open2($GDBOUT, $GDBIN, "/usr/bin/gdb $lib");
our $sel = IO::Select->new($GDBOUT);
my $flags;
fcntl($GDBOUT, F_GETFL, $flags) || die $!;
fcntl($GDBOUT, F_SETFL, $flags | O_NONBLOCK) || die $!;
read_gdb();
gdb_run("set width 0");

######## DEBUG #########
#say check_param('struct _ak_common_3g_config');
#parse_signature(get_signature('add2a'));
#say for uniq(@typedefs);
#say for @prototypes;
#exit;
######## DEBUG #########

open(my $LIB, "nm -CD -f posix $lib |");
while (<$LIB>) {
  next unless / T /; # only defined symbols
  next if /::|[<&]/; # skipping C++ symbols
  my ($f) = /^(\w+)/;
  debug("$f");
  parse_signature(get_signature($f));
}
close $LIB;

# ending gdb session
print $GDBIN "quit\n";
waitpid($pid, 0);

# printing ltrace config
say for uniq(@typedefs);
say for @prototypes;

0;

sub uniq {
  my %seen;
  return grep { !$seen{$_}++ } @_;
}

sub debug {
  print STDERR "$_[0]\n" if $DEBUG;
}

sub parse_signature {
  my $code = shift;

  my $reserved = qr/
    \b (?: return | if | while | for | do ) \b
  /x;

  my $identifier = qr/
    (?!$reserved)
    (?:
      \b\w+\b
    )/x;

  my $qualifier = qr/
    (?: (static|inline) )
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
      (?<par>$params_list)
    $
  /mx;

  if ($code =~ /$prototype/) {
    debug(colored(['green'], "  $&"));
    my (undef, $ret, $id, $par) = ($+{qua}, $+{ret}, $+{nam}, $+{par});
    my @params = split_params($par);

    $ret = check_param($ret);
    foreach (keys @params) {
      $params[$_] = check_param($params[$_]);
    }

    my $result = sprintf("%s %s(%s);", $ret, $id, join(',', @params) // 'void');
    $result =~ s/string,format/format/; # printf-like functions
    push @prototypes, $result;
    debug($result);
  } else {
    debug(colored(['red'], "  unparsed prototype [$code]"));
  }
}

sub check_param {
  my $p = shift;

  # normalizing type
  $p =~ s/\s*\b(signed|const)\b\s*//g;
  $p =~ s/(^\s+|\s+$)//g;
  $p =~ s/ *\* */ \*/g;

  my $ret = "addr";

  debug("  ? $p");

  ##### typedef?
  if (exists $typedefs_map{$p}) {
    $ret = $typedefs_map{$p};
    goto RETURN;
  }

  ##### primitive type
  if (exists $types{$p}) {
    $ret = $types{$p};
    goto RETURN;
  }

  ##### pointer to type
  if ($p =~ /^(?<type>.*?) *\*$/) {
    $ret = check_param($+{type}).'*';
    goto RETURN;
  }

  ##### function pointer
  if ($p =~ /\(/) {
    $ret = "addr";
    goto RETURN;
  }

  ##### variadic parameter
  if ($p eq '...') {
    $ret = "format";
    goto RETURN;
  }

  ##### struct or union
  if ($p =~ /^(?<type>(?:struct|union) (?<id>\w+)?) ?\{(?<body>.*?)\}/) {
    my ($ptype, $id, $members) = ($+{type}, $+{id}, $+{body});

    if ($id) { # forward declaration to handle struct recursion
      push @typedefs, "typedef $id = struct;";
      $typedefs_map{$ptype} = $id;
      $typedefs_map{$p} = $id;
    }

    my @m = ();
    while ($members =~ /(?<type>((?:struct|union) \{.*?\}|(\w+ ?)+) (\*+ ?)?)\w+(?<array>\[\d+\])?;/g) {
      $mtype = check_param("$+{type}$+{array}");
      if ($mtype eq "$p *") { # recursion, we need to create a forward declaration
        debug("  !! struct recursion: $p");
        $mtype = "$id*";
      }
      push @m, $mtype;
    }
    my $struct = sprintf("struct(%s)", join(',', @m));
    $ret = make_typedef($id, $struct);
    goto RETURN;
  }

  ##### array
  if ($p =~ /^(?<type>.*?) \[(?<size>\d+)]$/) {
    if ($+{type} eq 'char') {
      $ret = "string[$+{size}]";
    } else {
      $ret = sprintf("array(%s,%d)", check_param($+{type}), $+{size});
    }
    goto RETURN;
  }

  ##### enum
  if ($p =~ /^enum (?<id>\w+)? ?\{(?<values>.*?)\}/) {
    my ($id, $v) = ($+{id}, $+{values});
    $v =~ s/ //g;
    $ret = make_typedef($id, "enum($v)");
    goto RETURN;

    #my $i = -1;
    #my @values;
    #while ($v =~ /(?<name>\w+)(?: = (?<value>\d+))?/g) {
    #  $i = $+{value} // ($i+1);
    #  push @values, "$+{name}=$i";
    #}
    #$ret = make_typedef($id, sprintf("enum(%s)", join(',', @values)));
    #goto RETURN;
  }

  ##### user type or typedef
  $ret = get_ptype($p);
  $ret = ($ret =~ /^$|^(?:struct|union).*\{\.{3}\}/) ? "addr"
                                                     : check_param($ret);

RETURN:
  $ret = $types{$ret} if (exists $types{$ret});
  debug("  $p -> $ret");
  $ret;
}

sub make_typedef {
  my ($id, $struct) = @_;

  if ($id) {
    push @typedefs, "typedef $id = $struct;";
    $typedefs_map{$struct} = $id;
    debug("    $typedefs[$#typedefs]");
    return $id;
  }

  return $typedefs_map{$struct}
    if exists $typedefs_map{$struct};

  $id = "anon" . ($anon++);
  push @typedefs, "typedef $id = $struct;";
  $typedefs_map{$struct} = $id;
  debug("    $typedefs[$#typedefs]");
  $id;
}

sub split_params {
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
    last if $+{param} eq 'void';
    my $p = $+{param};
    push @params, $p;
    #print colored(['green'], "  <$params[$#params]>", "\n");
  }

  @params;
}

sub read_gdb {
  my $out = "";

  while (1) {
    $sel->can_read(2);
    my @lines = <$GDBOUT>;
    foreach (@lines) {
      goto OUT if /^\(gdb\)/;
      $out .= $_;
    }
  }

  OUT:
  $out;
}

sub gdb_run {
  my $cmd = shift;

  print $GDBIN "$cmd\n";
  #say "$cmd";
  IO::Select->new($GDBOUT)->can_read();
  read_gdb();
}

sub get_sizeof {
  my $t = shift;

  $type = gdb_run("p sizeof($t)");
  $type =~ s/= (\d+)$//s;
  $type = $1;
  $type;
}

sub get_ptype {
  my $t = shift;

  $type = gdb_run("ptype $t");
  $type =~ s/type = (.*?)$/$1/s;
  $type =~ s/[\n ]+/ /sg;
  debug(colored(['red'], "unknow type: [$t]")) unless length($type);
  $type;
}

sub get_signature {
  my $f = shift;

  $sig = gdb_run("p $f");
  $sig =~ /\{(.*?)\}/;
  $sig = $1;
  $sig =~ s/\(/$f\(/;
  $sig;
}
