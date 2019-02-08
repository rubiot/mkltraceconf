#!/usr/bin/env perl6

#
# Utilitario que gera codigo para imprimir o conteudo de uma struct
#

use v6;
use lib './lib';
use C::Parser;
use C::AST;
use Terminal::ANSIColor;

our &inblue   := &colored.assuming(*, 'blue');
our &inyellow := &colored.assuming(*, 'yellow');
our &ingreen  := &colored.assuming(*, 'green');
our &inbold   := &colored.assuming(*, 'bold');

sub MAIN()
{
  #my $input = $*IN.slurp.chomp.subst(/ <!after ';'> $ /, ";");
  my $input = $*IN.slurp.chomp;
  C::Parser::Grammar.parse($input, :rule('struct-or-union-specifier'), :actions(C::Parser::Actions));
  die "Couldn't parse input" without $/;

  #say $/;

  die "sorry... ainda não estamos tratando unions" if $<struct-or-union> eq 'union';

  for $<struct-declaration-list><struct-declaration> -> $d {
    #say "type: [$d<specifier-qualifier-list>.trim()], var: [$d<struct-declarator-list>.trim()]";
    make-print($d<specifier-qualifier-list>.trim, $d<struct-declarator-list>.trim);
  }
}

multi make-print('int', Str $var!) {
  printf('printf("%s=%%d", x.%s)'~"\n", $var, $var)
}

multi make-print('char', Str $var!) {
  printf('printf("%s=%%c", x.%s)'~"\n", $var, $var)
}

multi make-print('bool', Str $var!) {
  printf('printf("%s=%%d", x.%s)'~"\n", $var, $var)
}

multi make-print('long', Str $var!) {
  printf('printf("%s=%%ld", x.%s)'~"\n", $var, $var)
}

multi make-print(Str $type!, Str $var!) {
  warn "sorry... ainda não implementamos o tratamento do tipo $type"
}

#｢struct x { int a; struct x *next; }｣
# struct-or-union => ｢struct｣
# identifier => ｢x｣
# struct-declaration-list => ｢int a; struct x *next; ｣
#  struct-declaration => ｢int a; ｣
#   specifier-qualifier-list => ｢int ｣
#    type-specifier => ｢int｣
#   struct-declarator-list => ｢a｣
#    struct-declarator => ｢a｣
#     declarator => ｢a｣
#      direct-declarator => ｢a｣
#       identifier => ｢a｣
#  struct-declaration => ｢struct x *next; ｣
#   specifier-qualifier-list => ｢struct x ｣
#    type-specifier => ｢struct x ｣
#     struct-or-union-specifier => ｢struct x ｣
#      struct-or-union => ｢struct｣
#      identifier => ｢x｣
#   struct-declarator-list => ｢*next｣
#    struct-declarator => ｢*next｣
#     declarator => ｢*next｣
#      pointer => ｢*｣
#      direct-declarator => ｢next｣
#       identifier => ｢next｣
#
